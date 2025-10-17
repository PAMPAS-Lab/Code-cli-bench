#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Claude Code Stop/SubagentStop hook:
- 将 "<id> DONE\n" 写入 FIFO: /tmp/agent-done/claude.fifo
"""

import sys, os, json, re

FIFO_DIR = os.environ.get("FIFO_DIR", "/tmp/agent-done")
FIFO_PATH = os.path.join(FIFO_DIR, "claude.fifo")
CASE_RE = re.compile(r"CASE_ID=([^\s\"']+)")

def ensure_fifo():
    os.makedirs(FIFO_DIR, exist_ok=True)
    if not os.path.exists(FIFO_PATH):
        os.mkfifo(FIFO_PATH)

def extract_case_id_from_transcript(path: str) -> str:
    last_case = None
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if "CASE_ID=" not in line:
                    continue
                m = CASE_RE.search(line)
                if m:
                    last_case = m.group(1)
    except Exception:
        pass
    return last_case or "UNKNOWN"

def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except Exception:
        data = {}

    transcript_path = (
        data.get("transcript_path")
        or data.get("transcriptPath")
        or (data.get("transcript") or {}).get("path")
    )

    if not transcript_path or not os.path.exists(transcript_path):
        case_id = "UNKNOWN"
    else:
        case_id = extract_case_id_from_transcript(transcript_path)

    ensure_fifo()
    try:
        with open(FIFO_PATH, "w", encoding="utf-8") as w:
            w.write(f"{case_id} DONE\n")
    except Exception:
        pass

if __name__ == "__main__":
    main()

