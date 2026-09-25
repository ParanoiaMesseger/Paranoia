#!/usr/bin/env python3
"""Запуск приемника с существующим MCP-профилем Codex без вывода секретов."""

import argparse
import os
from pathlib import Path
import tomllib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")))
    parser.add_argument("--server", default="paranoia-cli")
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--thread", required=True)
    parser.add_argument("--topic", required=True)
    parser.add_argument("--after-message")
    args = parser.parse_args()
    binary = args.binary.resolve()
    with (args.codex_home / "config.toml").open("rb") as config:
        server = tomllib.load(config)["mcp_servers"][args.server]
    command = list(server.get("args", []))
    if not command or command[-1] != "mcp":
        parser.error("Профиль должен запускать EasyCli с последним аргументом mcp")
    env = os.environ.copy()
    for name in server.get("env_vars", []):
        if name not in env:
            parser.error("Не задана переменная окружения профиля")
    env.update(server.get("env", {}))
    command += ["codex-channel", "--socket", str(args.codex_home.resolve() / "app-server-control/app-server-control.sock"),
                "--thread", args.thread, "--topic", args.topic]
    if args.after_message:
        command += ["--after-message", args.after_message]
    if server.get("cwd"):
        os.chdir(server["cwd"])
    os.execve(binary, [str(binary), *command], env)


if __name__ == "__main__":
    main()
