#!/usr/bin/env python3
"""
Paranoia Easy CLI — MCP server (zero-dependency, stdlib only).

Тонкая обёртка над бинарём `paranoia-easy-cli`, дающая структурированные
инструменты вместо ручного парсинга логов. Реализует MCP поверх stdio как
newline-delimited JSON-RPC 2.0 (без внешних зависимостей — чтобы всегда
стартовать, без venv/pip).

Курсор «прочитанного» уже живёт в локальной paranoia.db (receive() двигает
last_pulled_seq), поэтому `receive`/`wait` отдают только НОВЫЕ сообщения и не
теряют их: курсор двигается транзакционно в CLI, а не в этом сервере.

Надёжность (почему сервер «не отваливается» и не теряет сообщения):
  • КОНКУРЕНТНОСТЬ. Каждый tools/call обрабатывается в отдельном потоке, а
    главный цикл продолжает читать stdin и отвечать на `ping`/`tools/list`.
    Иначе долгий `wait` (до 25 мин) блокировал бы весь сервер, MCP-клиент не
    получал ответа на ping и мог счесть сервер мёртвым → перезапуск/обрыв
    ровно посреди ожидания (а это и есть «отваливается»).
  • DURABLE-ЛОГ. receive/wait двигают курсор в БД ДЕСТРУКТИВНО: если результат
    не доедет до клиента (обрыв/рестарт), сообщение пропало бы навсегда.
    Поэтому КАЖДОЕ вытянутое сообщение дописывается (append+fsync, дедуп по id)
    в PARANOIA_MCP_LOG ещё ДО возврата. Даже «съеденное» восстановимо через
    инструмент `history` — курсор он не трогает.

Конфигурация — через переменные окружения (задаются в .mcp.json):
  PARANOIA_MCP_BIN       путь к бинарю paranoia-easy-cli (обязателен)
  PARANOIA_MCP_SERVER    --server-url (обязателен)
  PARANOIA_MCP_PIN       значение PARANOIA_CLI_PIN для расшифровки ключа подписи
  PARANOIA_MCP_DB        --db-path (по умолчанию paranoia.db в рабочей папке)
  PARANOIA_MCP_WORKDIR   рабочая папка CLI: используется как cwd И как HOME
                         подпроцесса, чтобы ВСЁ состояние CLI (cwd-relative
                         .paranoia-cli-data/, DEVICE_KEY, paranoia.db и
                         home-relative .paranoia_dialogues.json) лежало в ней.
  PARANOIA_MCP_LOG       durable-лог входящих (по умолчанию WORKDIR/messages.jsonl)
  PARANOIA_MCP_USERNAME  username (server_id) профиля по умолчанию
  PARANOIA_MCP_PEER      peer по умолчанию (имя/идентификатор собеседника)
  PARANOIA_MCP_SELF_HASH sender-хеш собственных сообщений (для метки "me");
                         если не задан — берётся равным USERNAME.
"""

import json
import os
import re
import subprocess
import sys
import threading
import time

SERVER_NAME = "paranoia-cli"
SERVER_VERSION = "0.3.0"
DEFAULT_PROTOCOL = "2025-06-18"

BIN = os.environ.get("PARANOIA_MCP_BIN", "")
SERVER_URL = os.environ.get("PARANOIA_MCP_SERVER", "")
PIN = os.environ.get("PARANOIA_MCP_PIN", "")
DB_PATH = os.environ.get("PARANOIA_MCP_DB", "paranoia.db")
WORKDIR = os.environ.get("PARANOIA_MCP_WORKDIR", "") or None
DEF_USER = os.environ.get("PARANOIA_MCP_USERNAME", "")
DEF_PEER = os.environ.get("PARANOIA_MCP_PEER", "")
SELF_HASH = os.environ.get("PARANOIA_MCP_SELF_HASH", "") or DEF_USER
LOG_PATH = os.environ.get("PARANOIA_MCP_LOG", "") or os.path.join(
    WORKDIR or ".", "messages.jsonl"
)

# Строка нового сообщения в выводе `receive`/`watch`:
#   [2026-06-11 02:48:16.913 UTC] id=<uuid> <sender-hex>: <text...>
# (текст может быть многострочным — продолжения не матчатся и клеятся к msg).
MSG_RE = re.compile(
    r"^\[(?P<ts>\d{4}-\d{2}-\d{2} [0-9:.]+ UTC)\] "
    r"id=(?P<id>[0-9a-fA-F-]{8,}) "
    r"(?P<sender>[0-9a-fA-F]{8,}): "
    r"(?P<rest>.*)$"
)
SENT_RE = re.compile(r"Sent: id=(?P<id>\S+) seq=(?P<seq>\S+)")


def log(msg):
    print(f"[paranoia-mcp] {msg}", file=sys.stderr, flush=True)


def run_cli(args, timeout=90):
    """Запустить CLI с общими флагами; вернуть (rc, stdout, stderr)."""
    if not BIN:
        return 127, "", "PARANOIA_MCP_BIN не задан"
    cmd = [BIN, "--server-url", SERVER_URL, "--db-path", DB_PATH] + args
    env = dict(os.environ)
    if PIN:
        env["PARANOIA_CLI_PIN"] = PIN
    if WORKDIR:
        # CLI хранит vault/.paranoia-cli-data и DEVICE_KEY относительно cwd, а
        # dialogue-store относительно HOME — сводим оба в WORKDIR.
        env["HOME"] = WORKDIR
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, env=env,
            cwd=WORKDIR,
        )
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s"
    except Exception as e:  # noqa: BLE001
        return 1, "", f"{type(e).__name__}: {e}"


def classify_kind(rest):
    """Грубая классификация контента по Debug-выводу не-текстовых сообщений."""
    head = rest.lstrip()[:24].lower()
    for k in ("image", "file", "audio", "video", "voice", "attachment", "sticker"):
        if head.startswith(k):
            return k
    return "text"


def parse_messages(stdout):
    """Распарсить вывод receive/watch в список структурированных сообщений.

    Многострочный текст: строки, не начинающиеся с шапки `[ts] id=...`,
    приклеиваются к тексту предыдущего сообщения.
    """
    messages = []
    cur = None
    for line in stdout.splitlines():
        m = MSG_RE.match(line)
        if m:
            sender = m.group("sender")
            cur = {
                "id": m.group("id"),
                "ts": m.group("ts"),
                "sender": sender,
                "from": "me" if (SELF_HASH and sender == SELF_HASH) else "peer",
                "kind": classify_kind(m.group("rest")),
                "text": m.group("rest"),
            }
            messages.append(cur)
        elif cur is not None:
            cur["text"] += "\n" + line
    return messages


# ─────────────────────────── durable message log ────────────────────────────
# Каждое вытянутое из БД сообщение дописывается сюда (append + fsync, дедуп по
# id) ДО возврата клиенту. Курсор в paranoia.db деструктивен — если результат
# tools/call не доедет (обрыв/рестарт сервера посреди wait), сообщение иначе
# пропало бы. Лог — страховка: `history` отдаёт его, не трогая курсор.

_log_lock = threading.Lock()
_seen_ids = set()
_seen_loaded = False


def _load_seen():
    global _seen_loaded
    if _seen_loaded:
        return
    _seen_loaded = True
    try:
        with open(LOG_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("id"):
                    _seen_ids.add(obj["id"])
    except FileNotFoundError:
        pass
    except Exception as e:  # noqa: BLE001
        log(f"log load error: {e}")


def persist(messages):
    """Дописать новые (по id) сообщения в durable-лог. Идемпотентно: уже
    записанные id пропускаются, поэтому повторные receive/wait не дублируют."""
    if not messages:
        return
    with _log_lock:
        _load_seen()
        new = [m for m in messages if m.get("id") and m["id"] not in _seen_ids]
        if not new:
            return
        stamp = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                for m in new:
                    rec = dict(m)
                    rec["pulled_at"] = stamp
                    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                f.flush()
                os.fsync(f.fileno())
            for m in new:
                _seen_ids.add(m["id"])
        except Exception as e:  # noqa: BLE001
            log(f"persist error: {e}")


def read_log():
    rows = []
    try:
        with open(LOG_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        pass
    except Exception as e:  # noqa: BLE001
        log(f"log read error: {e}")
    return rows


# ─────────────────────────── tool implementations ───────────────────────────

def tool_send(a):
    peer = a.get("peer") or DEF_PEER
    user = a.get("username") or DEF_USER
    text = a.get("text", "")
    if not text:
        raise ValueError("text обязателен")
    rc, out, err = run_cli(
        ["send", "--username", user, "--peer", peer, "--text", text]
    )
    if rc != 0:
        raise RuntimeError(err.strip() or f"send rc={rc}")
    m = SENT_RE.search(out)
    res = {"ok": True, "peer": peer}
    if m:
        res["id"] = m.group("id")
        seq = m.group("seq")
        sm = re.search(r"\d+", seq)
        res["seq"] = int(sm.group()) if sm else None
    return res


def tool_receive(a):
    peer = a.get("peer") or DEF_PEER
    user = a.get("username") or DEF_USER
    rc, out, err = run_cli(["receive", "--username", user, "--peer", peer])
    if rc != 0:
        raise RuntimeError(err.strip() or f"receive rc={rc}")
    msgs = parse_messages(out)
    persist(msgs)  # durable-страховка ДО фильтрации/возврата
    if not a.get("include_own", False):
        msgs = [m for m in msgs if m["from"] != "me"]
    return {"peer": peer, "count": len(msgs), "messages": msgs,
            "warnings": err.strip() or None}


def tool_wait(a):
    """Ждать сообщение ОТ peer (long-poll). Каждый `receive` идёт с
    `--long-poll-ms`: сервер ДЕРЖИТ запрос до нового сообщения или своего потолка
    (~25с), поэтому доставка near-real-time, а не раз в interval. Если сервер не
    поддерживает long-poll (старый/CDN режет удержание) — receive вернётся сразу,
    и мы падаем на короткий поллинг с паузой `poll_interval` (авто-деградация).
    Все вычитанные сообщения возвращаются и пишутся в durable-лог — не теряются."""
    peer = a.get("peer") or DEF_PEER
    user = a.get("username") or DEF_USER
    timeout = int(a.get("timeout_seconds", 1500))
    interval = max(5, int(a.get("poll_interval", 20)))
    # 0 → короткий поллинг (для CDN с белыми списками, режущими долгие запросы).
    long_poll_ms = int(a.get("long_poll_ms", 25000))
    include_own = a.get("include_own", False)
    deadline = time.monotonic() + timeout
    collected = []
    polls = 0
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return {"peer": peer, "timed_out": True, "polls": polls,
                    "count": len(collected), "messages": collected}
        args = ["receive", "--username", user, "--peer", peer]
        hold = 0
        if long_poll_ms > 0:
            hold = min(long_poll_ms, int(remaining * 1000))
            args += ["--long-poll-ms", str(hold)]
        # CLI-таймаут с запасом над удержанием сервера (иначе убьём свой же long-poll).
        call_t0 = time.monotonic()
        rc, out, err = run_cli(args, timeout=max(90, hold // 1000 + 30))
        polls += 1
        if rc == 0:
            batch = parse_messages(out)
            persist(batch)  # durable-страховка на КАЖДОМ поллинге
            keep = batch if include_own else [m for m in batch if m["from"] != "me"]
            collected.extend(keep)
            from_peer = [m for m in collected if m["from"] == "peer"]
            if from_peer:
                return {"peer": peer, "timed_out": False, "polls": polls,
                        "count": len(collected), "messages": collected}
        else:
            log(f"wait poll rc={rc}: {(err or '').strip()[:160]}")
        if time.monotonic() >= deadline:
            return {"peer": peer, "timed_out": True, "polls": polls,
                    "count": len(collected), "messages": collected}
        # Если запрос вернулся БЫСТРО (long-poll не сработал — короткий ответ),
        # выдержать паузу, чтобы не молотить сервер. Если же он держался (long-poll
        # отработал), паузу не нужно — сразу перевзводим.
        elapsed = time.monotonic() - call_t0
        if elapsed < 2.0:
            time.sleep(min(interval, max(1, deadline - time.monotonic())))


def tool_send_file(a):
    peer = a.get("peer") or DEF_PEER
    user = a.get("username") or DEF_USER
    path = a.get("path", "")
    if not path:
        raise ValueError("path обязателен")
    rc, out, err = run_cli(
        ["send-file", "--username", user, "--peer", peer, "--path", path],
        timeout=300,
    )
    if rc != 0:
        raise RuntimeError(err.strip() or f"send-file rc={rc}")
    return {"ok": True, "peer": peer, "raw": out.strip()}


def tool_download(a):
    peer = a.get("peer") or DEF_PEER
    user = a.get("username") or DEF_USER
    mid = a.get("message_id", "")
    out_path = a.get("out", "")
    if not mid or not out_path:
        raise ValueError("message_id и out обязательны")
    rc, out, err = run_cli(
        ["download", "--username", user, "--peer", peer,
         "--message-id", mid, "--out", out_path],
        timeout=300,
    )
    if rc != 0:
        raise RuntimeError(err.strip() or f"download rc={rc}")
    return {"ok": True, "path": out_path, "raw": out.strip()}


def tool_list_peers(a):
    rc, out, err = run_cli(["list"])
    if rc != 0:
        raise RuntimeError(err.strip() or f"list rc={rc}")
    return {"raw": out.strip()}


def tool_history(a):
    """Прочитать durable-лог входящих БЕЗ движения курсора БД. Для восстановления
    сообщений, если результат receive/wait не доехал (обрыв/рестарт сервера)."""
    limit = int(a.get("limit", 50))
    only = a.get("from")
    rows = read_log()
    if only in ("peer", "me"):
        rows = [r for r in rows if r.get("from") == only]
    if limit > 0:
        rows = rows[-limit:]
    return {"count": len(rows), "log": LOG_PATH, "messages": rows}


TOOLS = {
    "send": {
        "fn": tool_send,
        "description": "Отправить текстовое сообщение собеседнику (peer) от профиля username. По умолчанию — настроенному в env (Иванов).",
        "schema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Текст сообщения"},
                "peer": {"type": "string", "description": "Получатель (по умолчанию из env)"},
                "username": {"type": "string", "description": "Профиль-отправитель (по умолчанию из env)"},
            },
            "required": ["text"],
        },
    },
    "receive": {
        "fn": tool_receive,
        "description": "Получить НОВЫЕ сообщения диалога (курсор двигается в БД). По умолчанию возвращает только сообщения от собеседника (не свои эхо).",
        "schema": {
            "type": "object",
            "properties": {
                "peer": {"type": "string"},
                "username": {"type": "string"},
                "include_own": {"type": "boolean", "description": "Включать собственные отправленные (эхо). По умолчанию false."},
            },
        },
    },
    "wait": {
        "fn": tool_wait,
        "description": "Заблокироваться и ждать новое сообщение ОТ собеседника (long-poll). Возвращается, как только peer написал, либо по timeout_seconds. Заменяет ручной bash-поллер: ничего не теряется, парсинг логов не нужен.",
        "schema": {
            "type": "object",
            "properties": {
                "peer": {"type": "string"},
                "username": {"type": "string"},
                "timeout_seconds": {"type": "integer", "description": "Макс. ожидание (по умолчанию 1500)"},
                "poll_interval": {"type": "integer", "description": "Пауза между опросами в режиме короткого поллинга, сек (мин 5, по умолчанию 20). В long-poll режиме почти не используется — сервер сам держит запрос."},
                "long_poll_ms": {"type": "integer", "description": "Удержание long-poll на сервере, мс (по умолчанию 25000). 0 = короткий поллинг (для CDN, режущих долгие запросы). Сервер капает своим потолком."},
                "include_own": {"type": "boolean"},
            },
        },
    },
    "send_file": {
        "fn": tool_send_file,
        "description": "Отправить файл/картинку с диска (image/* по расширению — как картинку).",
        "schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Путь к файлу на диске"},
                "peer": {"type": "string"},
                "username": {"type": "string"},
            },
            "required": ["path"],
        },
    },
    "download": {
        "fn": tool_download,
        "description": "Скачать вложение сообщения по message_id в файл out (сообщение должно быть уже получено через receive/wait тем же профилем).",
        "schema": {
            "type": "object",
            "properties": {
                "message_id": {"type": "string"},
                "out": {"type": "string", "description": "Путь назначения"},
                "peer": {"type": "string"},
                "username": {"type": "string"},
            },
            "required": ["message_id", "out"],
        },
    },
    "list_peers": {
        "fn": tool_list_peers,
        "description": "Показать импортированные профили и их диалоги (username/peer/число ключей).",
        "schema": {"type": "object", "properties": {}},
    },
    "history": {
        "fn": tool_history,
        "description": "Прочитать durable-лог полученных сообщений (НЕ двигает курсор БД). Для восстановления, если результат receive/wait не доехал. from=peer|me фильтрует.",
        "schema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "Сколько последних записей (по умолчанию 50; 0 = все)"},
                "from": {"type": "string", "description": "Фильтр: 'peer' (от собеседника) или 'me' (свои)"},
            },
        },
    },
}


# ─────────────────────────────── JSON-RPC ───────────────────────────────────

_out_lock = threading.Lock()


def send_msg(obj):
    # Под локом: ответы из потоков tools/call и из главного цикла (ping и т.п.)
    # не должны перемешать строки в stdout.
    data = json.dumps(obj) + "\n"
    with _out_lock:
        sys.stdout.write(data)
        sys.stdout.flush()


def reply(rid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": rid}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    send_msg(msg)


def handle_tools_call(rid, params):
    name = params.get("name")
    args = params.get("arguments") or {}
    tool = TOOLS.get(name)
    if not tool:
        reply(rid, error={"code": -32602, "message": f"unknown tool: {name}"})
        return
    try:
        result = tool["fn"](args)
        reply(rid, result={
            "content": [{"type": "text",
                         "text": json.dumps(result, ensure_ascii=False, indent=2)}],
        })
    except Exception as e:  # noqa: BLE001
        log(f"tool {name} error: {e}")
        reply(rid, result={
            "content": [{"type": "text", "text": f"ERROR: {e}"}],
            "isError": True,
        })


def handle(req):
    method = req.get("method")
    rid = req.get("id")
    params = req.get("params") or {}

    if method == "initialize":
        proto = params.get("protocolVersion", DEFAULT_PROTOCOL)
        reply(rid, result={
            "protocolVersion": proto,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    elif method == "notifications/initialized":
        pass  # notification — без ответа
    elif method == "tools/list":
        reply(rid, result={
            "tools": [
                {"name": n, "description": t["description"], "inputSchema": t["schema"]}
                for n, t in TOOLS.items()
            ]
        })
    elif method == "tools/call":
        # В ОТДЕЛЬНОМ потоке: долгий `wait` (до 25 мин) не должен блокировать
        # главный цикл — иначе сервер перестаёт отвечать на ping и MCP-клиент
        # рвёт соединение посреди ожидания. Ответ уйдёт по rid из потока.
        threading.Thread(
            target=handle_tools_call, args=(rid, params), daemon=True
        ).start()
    elif method == "ping":
        reply(rid, result={})
    elif rid is not None:
        reply(rid, error={"code": -32601, "message": f"method not found: {method}"})
    # прочие нотификации игнорируем молча


def main():
    if not BIN or not SERVER_URL:
        log("WARNING: PARANOIA_MCP_BIN/PARANOIA_MCP_SERVER не заданы — инструменты вернут ошибку")
    log(f"started v{SERVER_VERSION}; bin={BIN or '?'} db={DB_PATH} "
        f"peer={DEF_PEER or '?'} log={LOG_PATH}")
    # readline() в цикле (а НЕ `for line in sys.stdin`): итератор файла делает
    # внутренний read-ahead и может задержать доставку строк — тогда ping не
    # обработается вовремя, пока выполняется tools/call в другом потоке.
    while True:
        line = sys.stdin.readline()
        if not line:  # EOF — клиент закрыл stdin
            break
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(req, list):  # батч
            for r in req:
                handle(r)
        else:
            handle(req)


if __name__ == "__main__":
    main()
