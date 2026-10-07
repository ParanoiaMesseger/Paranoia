#!/usr/bin/env python3
"""Подготовить user-unit для одной сессии Codex, не запуская приемник."""

import argparse
import os
from pathlib import Path
import shlex
import sys
import uuid


def unit_quote(value):
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return '"' + escaped.replace("%", "%%") + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread", type=uuid.UUID, default=os.environ.get("CODEX_THREAD_ID"))
    parser.add_argument("--topic", required=True)
    parser.add_argument("--after-message", required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")))
    parser.add_argument("--server", default="paranoia-cli")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    if args.thread is None:
        parser.error("Нужен --thread или CODEX_THREAD_ID текущей сессии")
    if not args.topic.strip():
        parser.error("Нужна непустая тема")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("Не найден release-бинарь приемника")

    launcher = Path(__file__).resolve().with_name("codex-channel.py")
    command = [sys.executable, launcher, "--codex-home", args.codex_home.resolve(),
               "--server", args.server, "--binary", binary, "--thread", args.thread,
               "--topic", args.topic, "--after-message", args.after_message]
    content = "\n".join([
        "[Unit]", "Description=Paranoia channel for Codex", "", "[Service]",
        "Type=simple",
        "ExecStart=:" + " ".join(map(unit_quote, command)),
        "Restart=on-failure", "RestartSec=5", "", "[Install]",
        "WantedBy=default.target", "",
    ])
    directory = args.output_dir.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    unit = directory / ("paranoia-codex-" + str(args.thread) + ".service")
    with unit.open("x", encoding="utf-8") as stream:
        stream.write(content)
    print("Подготовлен unit; приемник не запущен:", unit)
    print("systemctl --user enable --now " + shlex.quote(str(unit)))
    print("Отключение: systemctl --user disable --now " + unit.name)


if __name__ == "__main__":
    main()
