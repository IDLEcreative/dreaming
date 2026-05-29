#!/usr/bin/env python3
"""
openai_tool_loop.py — a minimal agentic tool-use loop against any
OpenAI-compatible chat-completions endpoint. Powers both the openai and
ollama dreaming adapters (Ollama serves an OpenAI-compatible API at
http://localhost:11434/v1).

Unlike the claude/codex/gemini CLIs — which bring OS-level sandboxing — this
shim implements a BEST-EFFORT sandbox in Python:
  • write_file is path-checked: writes outside the workspace are rejected.
  • run_command runs with cwd=workspace and a network-egress denylist
    (curl/wget/nc/ssh/... are refused) so the model cannot exfiltrate memory.
  • reads are unrestricted (reading config like CLAUDE.md is benign; the
    exfil risk is network + out-of-tree writes, both closed above).

For hard isolation prefer the claude/codex/gemini adapters. This shim is for
endpoints that have no sandboxed CLI of their own.

Usage:
  openai_tool_loop.py --workspace DIR --prompt-file FILE --base-url URL \
      --model NAME [--api-key-env OPENAI_API_KEY] [--max-iterations 60]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

NETWORK_DENYLIST = re.compile(
    r"\b(curl|wget|nc|ncat|netcat|ssh|scp|sftp|telnet|ftp|rsync)\b"
    r"|https?://|ftp://|\bnslookup\b|\bdig\b"
)

TOOLS = [
    {"type": "function", "function": {
        "name": "read_file",
        "description": "Read a UTF-8 text file. Absolute paths allowed (reads are unrestricted).",
        "parameters": {"type": "object",
                       "properties": {"path": {"type": "string"}},
                       "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "write_file",
        "description": "Write a UTF-8 text file. The path MUST be inside the workspace.",
        "parameters": {"type": "object",
                       "properties": {"path": {"type": "string"},
                                      "content": {"type": "string"}},
                       "required": ["path", "content"]}}},
    {"type": "function", "function": {
        "name": "list_dir",
        "description": "List entries in a directory.",
        "parameters": {"type": "object",
                       "properties": {"path": {"type": "string"}},
                       "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "run_command",
        "description": "Run a read-only shell command (grep/jq/find/awk/sed/etc). "
                       "cwd is the workspace. Network commands are refused.",
        "parameters": {"type": "object",
                       "properties": {"command": {"type": "string"}},
                       "required": ["command"]}}},
]


def in_workspace(workspace, path):
    full = os.path.realpath(os.path.join(workspace, path))
    ws = os.path.realpath(workspace)
    return full == ws or full.startswith(ws + os.sep), full


def tool_read_file(workspace, args):
    path = args["path"]
    full = os.path.realpath(os.path.join(workspace, path))
    try:
        with open(full, encoding="utf-8", errors="replace") as f:
            data = f.read(200_000)  # cap to keep token budget sane
        return data
    except OSError as e:
        return f"ERROR: {e}"


def tool_write_file(workspace, args):
    ok, full = in_workspace(workspace, args["path"])
    if not ok:
        return f"ERROR: refused — path escapes workspace: {args['path']}"
    try:
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(args["content"])
        return f"wrote {len(args['content'])} bytes to {full}"
    except OSError as e:
        return f"ERROR: {e}"


def tool_list_dir(workspace, args):
    full = os.path.realpath(os.path.join(workspace, args["path"]))
    try:
        return "\n".join(sorted(os.listdir(full))) or "(empty)"
    except OSError as e:
        return f"ERROR: {e}"


def tool_run_command(workspace, args):
    cmd = args["command"]
    if NETWORK_DENYLIST.search(cmd):
        return "ERROR: refused — command matches network-egress denylist"
    try:
        out = subprocess.run(
            cmd, shell=True, cwd=workspace, capture_output=True,
            text=True, timeout=120,
        )
        result = out.stdout
        if out.stderr:
            result += f"\n[stderr]\n{out.stderr}"
        return result[:100_000] or "(no output)"
    except subprocess.TimeoutExpired:
        return "ERROR: command timed out (120s)"
    except Exception as e:  # noqa: BLE001
        return f"ERROR: {e}"


DISPATCH = {
    "read_file": tool_read_file,
    "write_file": tool_write_file,
    "list_dir": tool_list_dir,
    "run_command": tool_run_command,
}


def call_api(base_url, api_key, model, messages):
    body = json.dumps({
        "model": model,
        "messages": messages,
        "tools": TOOLS,
        "tool_choice": "auto",
    }).encode()
    req = urllib.request.Request(
        base_url.rstrip("/") + "/chat/completions",
        data=body, method="POST",
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {api_key}"} if api_key else {})},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--prompt-file", required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--api-key-env", default="")
    ap.add_argument("--max-iterations", type=int, default=60)
    a = ap.parse_args()

    api_key = os.environ.get(a.api_key_env, "") if a.api_key_env else ""
    with open(a.prompt_file, encoding="utf-8") as f:
        prompt = f.read()

    messages = [{"role": "user", "content": prompt}]

    for i in range(a.max_iterations):
        try:
            resp = call_api(a.base_url, api_key, a.model, messages)
        except urllib.error.HTTPError as e:
            print(f"ERROR: HTTP {e.code}: {e.read().decode(errors='replace')[:500]}",
                  file=sys.stderr)
            return 1
        except Exception as e:  # noqa: BLE001
            print(f"ERROR: {e}", file=sys.stderr)
            return 1

        choice = resp["choices"][0]
        msg = choice["message"]
        messages.append(msg)

        if msg.get("content"):
            print(msg["content"])

        tool_calls = msg.get("tool_calls") or []
        if not tool_calls:
            return 0  # model finished

        for tc in tool_calls:
            fn = tc["function"]["name"]
            try:
                fn_args = json.loads(tc["function"]["arguments"] or "{}")
            except json.JSONDecodeError:
                fn_args = {}
            handler = DISPATCH.get(fn)
            result = handler(a.workspace, fn_args) if handler else f"ERROR: unknown tool {fn}"
            messages.append({"role": "tool", "tool_call_id": tc["id"], "content": str(result)})

    print(f"ERROR: hit max-iterations ({a.max_iterations}) without finishing", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
