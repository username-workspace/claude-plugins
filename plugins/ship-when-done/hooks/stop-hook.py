#!/usr/bin/env python3
"""Stop-hook plumbing: read the Stop payload, derive goal / last message / TodoWrite state from the
transcript, and hand off to ship.py engage."""
import json, os, subprocess, sys


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def resolve(script, cwd, transcript="", command=""):
    try:
        r = subprocess.run([sys.executable, script, "resolve", "--cwd", cwd or "",
                            "--transcript", transcript or "", "--command", command or ""],
                           timeout=15, capture_output=True, text=True)
        return r.stdout.strip()
    except Exception:
        return ""


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    if payload.get("stop_hook_active"):
        return
    cwd = payload.get("cwd") or os.getcwd()
    session = payload.get("session_id") or ""
    tp = payload.get("transcript_path")
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "ship-when-done", "scripts", "ship.py")
    repo = resolve(script, cwd, tp or "")
    if not repo:
        return
    goal, last, todos = "", "", None
    if tp and os.path.isfile(tp):
        try:
            for line in open(tp, errors="ignore"):
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                t = d.get("type")
                if t == "user" and not d.get("isSidechain"):
                    txt = text_of((d.get("message") or {}).get("content")).strip()
                    if txt and not txt.startswith("<") and not goal:
                        goal = txt[:2000]
                elif t == "assistant":
                    content = (d.get("message") or {}).get("content")
                    txt = text_of(content).strip()
                    if txt:
                        last = txt
                    if isinstance(content, list):
                        for b in content:
                            if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "TodoWrite":
                                todos = (b.get("input") or {}).get("todos")
        except Exception:
            pass
    todos_done = bool(todos) and all((it or {}).get("status") == "completed" for it in todos)
    cmd = [sys.executable, script, "engage", "--repo", repo, "--goal", goal, "--last-message", last,
           "--session", session]
    if todos_done:
        cmd.append("--todos-done")
    try:
        subprocess.run(cmd, timeout=180)
    except Exception:
        pass


if __name__ == "__main__":
    main()
