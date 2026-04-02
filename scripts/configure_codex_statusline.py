#!/usr/bin/env python3
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

CONFIG_PATH = Path.home() / ".codex" / "config.toml"
STATUS_LINE = (
    'status_line = [ "model-name", "context-used", "context-window-size", '
    '"project-root", "git-branch", "five-hour-limit", "weekly-limit" ]'
)


def upsert_tui_status_line(text: str) -> str:
    lines = text.splitlines()
    out: list[str] = []
    in_tui = False
    replaced = False

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_tui and not replaced:
                out.append(STATUS_LINE)
                replaced = True
            in_tui = stripped == "[tui]"
            out.append(line)
            continue

        if in_tui and stripped.startswith("status_line"):
            if not replaced:
                out.append(STATUS_LINE)
                replaced = True
            continue

        out.append(line)

    if in_tui and not replaced:
        out.append(STATUS_LINE)

    if not any(line.strip() == "[tui]" for line in out):
        if out and out[-1].strip():
            out.append("")
        out.extend(["[tui]", STATUS_LINE])

    return "\n".join(out) + "\n"


def main() -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    original = CONFIG_PATH.read_text() if CONFIG_PATH.exists() else ""
    updated = upsert_tui_status_line(original)

    if CONFIG_PATH.exists() and original != updated:
        backup = CONFIG_PATH.with_name(
            f"config.toml.bak-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
        )
        backup.write_text(original)
        print(f"backup {backup}")

    CONFIG_PATH.write_text(updated)
    print(f"updated {CONFIG_PATH}")


if __name__ == "__main__":
    main()
