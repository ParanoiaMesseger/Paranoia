#!/usr/bin/env python3
"""Проверка native Codex с временным профилем и локальным Responses API."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time


class Backend(http.server.BaseHTTPRequestHandler):
    requests = 0

    def log_message(self, *_args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        Backend.requests += 1
        item = {"type": "message", "id": "msg_fixture", "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": "ok", "annotations": []}]}
        events = [{"type": "response.created", "response": {"id": "resp_fixture"}},
                  {"type": "response.output_item.done", "output_index": 0, "item": item},
                  {"type": "response.completed", "response": {"id": "resp_fixture", "status": "completed",
                   "output": [item], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}}]
        body = "".join("data: " + json.dumps(event) + "\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    module = Path(__file__).resolve().parents[1]
    backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="paranoia-native-test-") as scratch:
            root = Path(scratch)
            socket = root / "codex.sock"
            env = os.environ.copy()
            env["CODEX_HOME"] = str(root)
            env["XDG_CONFIG_HOME"] = str(root / "config")
            env["XDG_DATA_HOME"] = str(root / "data")
            env["PARANOIA_CODEX_TEST_SOCKET"] = str(socket)
            provider = ('model_providers.fixture={name="fixture",base_url="http://127.0.0.1:'
                        + str(backend.server_port) + '/v1",wire_api="responses",request_max_retries=0,stream_max_retries=0}')
            with (root / "server.log").open("wb") as log:
                server = subprocess.Popen(["codex", "app-server", "--listen", "unix://" + str(socket),
                                           "-c", 'model_provider="fixture"', "-c", provider,
                                           "-c", 'model="fixture-model"'], env=env, stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 10
                    while not socket.exists():
                        if server.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError("Не запустился изолированный Codex")
                        time.sleep(0.05)
                    subprocess.run(["cargo", "test", "--offline", "--locked", "-j", "8",
                                    "native_lost_ack_recovers_once", "--", "--ignored", "--nocapture"],
                                   cwd=module, env=env, check=True)
                    if Backend.requests != 30:
                        raise AssertionError(f"Локальный backend: {Backend.requests} запросов, ожидалось 30")
                    print("Локальный Responses API: 30 запросов, реальные аккаунты не использованы")
                finally:
                    server.terminate()
                    server.wait(timeout=10)
    finally:
        backend.shutdown()


if __name__ == "__main__":
    main()
