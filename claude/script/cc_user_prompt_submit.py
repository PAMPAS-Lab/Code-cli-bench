#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
- 若用户输入形如 "CASE_ID=xxx"：
  - 将 xxx 记录到一个会话级文件：/tmp/agent-done/session_cases/<session_id>.case
  - 告诉 Claude Code：取消这次提交（优先）或把提交内容改成一个无害占位以避免模型困惑
- 否则：原样通过（不改动）
"""

import os, sys, json, re
from pathlib import Path

FIFO_BASE = Path(os.environ.get("FIFO_DIR", "/tmp/agent-done"))
CASE_DIR  = FIFO_BASE / "session_cases"
CASE_DIR.mkdir(parents=True, exist_ok=True)

PROMPT_KEYS_IN = ("prompt", "user_prompt", "userPrompt")

OUTPUT_SUPPORTS_CANCEL = True   

CASE_RE = re.compile(r"^CASE_ID=([^\s\"']+)\s*$", re.IGNORECASE)

def parse_stdin_json():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except Exception:
        data = {}
    return data

def extract_prompt(data: dict) -> str:
    for k in PROMPT_KEYS_IN:
        if isinstance(data.get(k), str):
            return data[k]
    if isinstance(data.get("input"), dict):
        for k in PROMPT_KEYS_IN:
            v = data["input"].get(k)
            if isinstance(v, str):
                return v
    return ""

def extract_session_id(data: dict) -> str:
    for k in ("session_id", "sessionId", "sessionID", "sid"):
        v = data.get(k)
        if isinstance(v, str) and v:
            return v
    if isinstance(data.get("session"), dict):
        sid = data["session"].get("id")
        if isinstance(sid, str) and sid:
            return sid
    return f"pid_{os.getpid()}"

def write_session_case(session_id: str, case_id: str):
    path = CASE_DIR / f"{session_id}.case"
    try:
        path.write_text(case_id + "\n", encoding="utf-8")
    except Exception:
        pass

def main():
    data = parse_stdin_json()
    prompt = extract_prompt(data)
    session_id = extract_session_id(data)

    m = CASE_RE.match(prompt or "")
    if not m:
        return 0

    case_id = m.group(1)
    write_session_case(session_id, case_id)
    print("⚠️ 只记录CASE_ID,不进入上下文.", file=sys.stderr)
    sys.exit(2)

if __name__ == "__main__":
    main()

