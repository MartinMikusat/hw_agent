#!/usr/bin/env python3
"""Verify that every pinned sibling checkout matches dependencies.lock."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

COLLECTIONS = ("hw_odin_native_update", "hw_odin_devlog")
REQUIRED = set(COLLECTIONS)


def git(path, *arguments):
    result = subprocess.run(
        ["git", "-C", str(path), *arguments], capture_output=True, text=True, timeout=15
    )
    if result.returncode:
        raise ValueError("A pinned dependency is not an available Git checkout")
    return result.stdout.strip()


def unique_pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("Duplicate dependency-lock field")
        value[key] = item
    return value


def check(root, mode):
    lock = json.loads((root / "dependencies.lock").read_text(), object_pairs_hook=unique_pairs)
    if (
        not isinstance(lock, dict)
        or set(lock) != {"schema", "repositories"}
        or type(lock["schema"]) is not int
        or lock["schema"] != 1
        or not isinstance(lock["repositories"], list)
    ):
        raise ValueError("Invalid dependency-lock schema")
    names = set()
    for item in lock["repositories"]:
        if not isinstance(item, dict) or set(item) != {"name", "path", "url", "revision"}:
            raise ValueError("Invalid dependency-lock entry")
        if any(not isinstance(item[field], str) or not item[field] for field in item):
            raise ValueError("Invalid dependency-lock value")
        name = item["name"]
        if name in names or name not in REQUIRED:
            raise ValueError("Unexpected or duplicate dependency")
        names.add(name)
        path = (root / item["path"]).resolve()
        expected = root.parent / "odin_libraries" / name if name in COLLECTIONS else root.parent / name
        if path != expected.resolve():
            raise ValueError(f"{name}: dependency path does not match the build collection")
        if name in COLLECTIONS and os.environ.get("ODIN_LIBS"):
            libraries = Path(os.environ["ODIN_LIBS"]).resolve()
            path = libraries / name
        if Path(git(path, "rev-parse", "--show-toplevel")).resolve() != path:
            raise ValueError(f"{name}: dependency path is not its repository root")
        url = urlsplit(item["url"])
        if url.scheme == "file":
            if url.netloc or url.query or url.fragment or Path(unquote(url.path)).resolve() != path:
                raise ValueError(f"{name}: local Git URL does not identify the pinned checkout")
        else:
            if url.scheme not in {"https", "ssh"} or url.password or url.scheme == "https" and url.username:
                raise ValueError(f"{name}: dependency URL is not a supported credential-free origin")
            if git(path, "remote", "get-url", "origin") != item["url"]:
                raise ValueError(f"{name}: origin differs from its pin")
        if not re.fullmatch(r"[0-9a-f]{40}", item["revision"]) or git(path, "rev-parse", "HEAD") != item["revision"]:
            raise ValueError(f"{name}: revision differs from its tested pin")
        if mode == "release" and git(path, "status", "--porcelain"):
            raise ValueError(f"{name}: release requires a clean dependency checkout")
    if names != REQUIRED:
        raise ValueError("Required native dependencies are not all pinned")


if __name__ == "__main__":
    try:
        check(Path(__file__).resolve().parents[1], sys.argv[1] if len(sys.argv) > 1 else "debug")
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Dependency check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
