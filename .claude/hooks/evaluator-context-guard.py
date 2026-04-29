#!/usr/bin/env python3
"""
Evaluator Context Guard — Claude Code PreToolUse Hook

在 /adversarial-review 跑起来期间，硬拦 Read 工具对 Generator 上下文（journal /
backend/frontend knowledge）的访问。这是 prompt 层"强制约束"措辞的工具层兜底——
Evaluator subagent 即便想读，Read 调用也会在到达文件系统前被 deny。

设计要点：
  · 用文件系统 marker 决定是否进入"Evaluator 守卫期"——避免依赖环境变量
    （subagent 是 Task tool spawn 的子进程，env 共享但 marker 更显式）
  · Marker 路径：.claude/.hooks/evaluator-active.json，含 expires_at 自我熔断
  · 父 session 在每次 Task spawn 前写 marker，spawn 完成后删 marker
  · Marker 不存在 / 已过期 → 透传，不影响日常 Read

注册方式（.claude/settings.json）：
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read",
        "hooks": [{"type": "command", "command": "python3 .claude/hooks/evaluator-context-guard.py"}]
      }
    ]
  }
}

输入（stdin）：PreToolUse 事件 JSON
  {"tool_name": "Read", "tool_input": {"file_path": "..."}, "cwd": "...", ...}

输出：
  · 允许：不输出，exit 0
  · 拒绝：输出 hookSpecificOutput JSON 标 deny，exit 0
"""

import datetime as dt
import fnmatch
import json
import os
import sys


MARKER_PATH = ".claude/.hooks/evaluator-active.json"

# 被守卫的路径模式（fnmatch 风格，相对于仓库根）
FORBIDDEN_PATTERNS = [
    "docs/workspace/*/journal.md",
    "docs/workspace/*/journal-*.md",       # 月切片后的命名
    ".claude/knowledge/backend/*",
    ".claude/knowledge/backend/**/*",
    ".claude/knowledge/frontend/*",
    ".claude/knowledge/frontend/**/*",
]


def deny(reason: str) -> None:
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)


def marker_active(cwd: str) -> bool:
    """检查 marker 是否存在且未过期。"""
    path = os.path.join(cwd, MARKER_PATH)
    if not os.path.isfile(path):
        return False
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        # marker 损坏：保守按未激活处理（守卫不上）；写 marker 的人自己负责
        return False

    if not data.get("active", False):
        return False

    expires_at = data.get("expires_at")
    if expires_at:
        try:
            exp = dt.datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
            now = dt.datetime.now(dt.timezone.utc)
            if exp < now:
                # 过期 → 自动失效，避免父 session 崩溃留下永久守卫
                return False
        except Exception:
            return False

    return True


def is_forbidden(file_path: str, cwd: str) -> bool:
    """判断 file_path 是否命中守卫路径。支持绝对/相对路径。"""
    if not file_path:
        return False

    # 归一化为相对仓库根的路径
    abs_path = os.path.abspath(file_path)
    abs_cwd = os.path.abspath(cwd)
    try:
        rel = os.path.relpath(abs_path, abs_cwd)
    except ValueError:
        # Windows 跨盘等情况，保守不拦
        return False

    # 反向遍历也拦不住——必须在 cwd 范围内才有意义
    if rel.startswith(".."):
        return False

    rel = rel.replace(os.sep, "/")

    for pat in FORBIDDEN_PATTERNS:
        if fnmatch.fnmatchcase(rel, pat):
            return True
        # 简单支持 ** 通配（fnmatch 不天然支持）
        if "**" in pat:
            head, tail = pat.split("**", 1)
            head = head.rstrip("/")
            tail = tail.lstrip("/")
            if rel.startswith(head + "/") and (not tail or fnmatch.fnmatchcase(rel.split("/")[-1], tail)):
                return True

    return False


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    tool_name = payload.get("tool_name", "") or ""
    if tool_name != "Read":
        sys.exit(0)

    cwd = payload.get("cwd") or os.getcwd()

    if not marker_active(cwd):
        sys.exit(0)

    tool_input = payload.get("tool_input", {}) or {}
    file_path = tool_input.get("file_path", "") or ""

    if not is_forbidden(file_path, cwd):
        sys.exit(0)

    deny(
        f"Evaluator 守卫红线：当前在 /adversarial-review 守卫期，禁止读 '{file_path}'。"
        f" Generator 的 journal 和 backend/frontend knowledge 会污染 Evaluator 判断。"
        f" 只允许读 docs/design/、docs/consensus/、docs/tasks/{{sprint}}/tasks.yaml、"
        f".claude/knowledge/red-lines.md、git diff、改动文件本体。"
    )


if __name__ == "__main__":
    main()
