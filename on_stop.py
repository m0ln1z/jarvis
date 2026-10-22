#!/usr/bin/env python3
"""Claude Code Stop hook: Jarvis reads out a short summary of Claude's last answer."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAX_CHARS = 220


def last_answer(data):
    if data.get("last_assistant_message"):
        return data["last_assistant_message"]
    text = ""
    try:
        with open(data["transcript_path"], encoding="utf-8") as f:
            for line in f:
                e = json.loads(line)
                if e.get("type") != "assistant":
                    continue
                parts = [c.get("text", "") for c in e.get("message", {}).get("content", []) if c.get("type") == "text"]
                if any(parts):
                    text = "\n".join(parts)
    except Exception:
        pass
    return text


def short(text):
    text = re.sub(r"```.*?```", " ", text, flags=re.S)  # code blocks
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # links
    text = re.sub(r"[#*_>|]+", " ", text)
    text = re.sub(r"^\s*[-•]\s*", "", text, flags=re.M)
    text = re.sub(r"\s+", " ", text).strip()
    out = ""
    for s in re.split(r"(?<=[.!?])\s+", text):  # whole sentences up to the limit
        if out and len(out) + len(s) > MAX_CHARS:
            break
        out = f"{out} {s}".strip()
    return out[:MAX_CHARS + 80]


def main():
    data = json.load(sys.stdin)
    if data.get("stop_hook_active"):
        return
    project = Path(data.get("cwd") or os.getcwd()).name
    summary = re.sub(r"^(Готово|Сделано)[.!,:]?\s*", "", short(last_answer(data)))
    phrase = f"Сэр, по проекту {re.sub(r'[-_]+', ' ', project)} готово. {summary}"
    with open(HERE / "hook.log", "a", encoding="utf-8") as f:
        f.write(phrase + "\n")
    subprocess.Popen([str(HERE / ".venv/bin/python"), str(HERE / "jarvis.py"), "--say", phrase],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


if __name__ == "__main__":
    main()
