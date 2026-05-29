#!/usr/bin/env python3
import argparse
import datetime as dt
import re
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path


def project_version(cmake_lists: Path) -> str:
    text = cmake_lists.read_text(encoding="utf-8")
    match = re.search(r"project\s*\([^)]*\bVERSION\s+([0-9]+(?:\.[0-9]+){0,3})", text, re.S)
    if not match:
        raise SystemExit(f"Cannot read project VERSION from {cmake_lists}")
    parts = match.group(1).split(".")
    while len(parts) < 4:
        parts.append("0")
    return ".".join(parts[:4])


def copy_installer_tree(source: Path, output: Path) -> None:
    if output.exists():
        shutil.rmtree(output)

    def ignore_data_dirs(path: str, names: list[str]) -> set[str]:
        current = Path(path)
        if current.name == "app.paranoia.client" and "data" in names:
            return {"data"}
        return set()

    shutil.copytree(source, output, ignore=ignore_data_dirs)


def set_child_text(root: ET.Element, name: str, value: str) -> None:
    child = root.find(name)
    if child is None:
        child = ET.SubElement(root, name)
    child.text = value


def update_xml(path: Path, version: str, release_date: str | None) -> None:
    tree = ET.parse(path)
    root = tree.getroot()
    set_child_text(root, "Version", version)
    if release_date is not None:
        set_child_text(root, "ReleaseDate", release_date)
    ET.indent(tree, space="    ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Prepare Qt Installer Framework metadata for CI packaging.")
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--project", required=True, type=Path)
    args = parser.parse_args()

    version = project_version(args.project)
    # dt.timezone.utc вместо dt.UTC — последний появился только в Python 3.11,
    # а на Ubuntu 22.04 системный Python 3.10 (CI-образ под 22.04).
    release_date = dt.datetime.now(dt.timezone.utc).date().isoformat()
    copy_installer_tree(args.source, args.output)

    for config in (args.output / "config").glob("config*.xml"):
        update_xml(config, version, None)
    update_xml(args.output / "packages" / "app.paranoia.client" / "meta" / "package.xml", version, release_date)

    print(f"Prepared IFW metadata: version={version}, release_date={release_date}, output={args.output}")


if __name__ == "__main__":
    main()
