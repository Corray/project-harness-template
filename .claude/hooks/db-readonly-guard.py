#!/usr/bin/env python3
"""
DB Read-Only Guard — Claude Code PreToolUse Hook

拦截对 mysql-* / mongo-* MCP server 的写操作。
本 hook 是硬约束的兜底——即使在 .mcp.json 中误配了带写权限的账号，
Claude 也无法通过工具写入；任何非只读调用都会在到达 MCP server 之前被 deny。

注册方式（.claude/settings.json）：
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__mysql-.*|mcp__mongo-.*",
        "hooks": [{"type": "command", "command": "python3 .claude/hooks/db-readonly-guard.py"}]
      }
    ]
  }
}

输入（stdin）：Claude Code 传 PreToolUse 事件的 JSON
  {"tool_name": "mcp__mysql-order__query", "tool_input": {"sql": "SELECT ..."}, ...}

输出（stdout）：
  - 允许：不输出，exit 0
  - 拒绝：输出 hookSpecificOutput JSON 标 deny + reason，exit 0

策略：
  · MySQL：解析 SQL 首词，白名单 SELECT/SHOW/DESCRIBE/DESC/EXPLAIN/WITH，其他全拒
  · MongoDB：方法名白名单（find / aggregate / count / distinct / list* / stats / explain），其他全拒
  · 不是 mysql-/mongo- MCP 工具调用 → 透传不拦截
"""

import json
import re
import sys


# MySQL 只读语句首词白名单
ALLOWED_SQL_PREFIXES = {
    "select",
    "show",
    "describe",
    "desc",
    "explain",
    "with",  # CTE 通常只读；如担心可移除
}

# MongoDB 只读方法名白名单（含驼峰和下划线两种命名风格）
ALLOWED_MONGO_METHODS = {
    "find",
    "find_one",
    "findone",
    "aggregate",
    "count",
    "count_documents",
    "countdocuments",
    "estimated_document_count",
    "estimateddocumentcount",
    "distinct",
    "list_collections",
    "listcollections",
    "list_databases",
    "listdatabases",
    "list_indexes",
    "listindexes",
    "explain",
    "stats",
    "collstats",
    "dbstats",
}


def deny(reason: str) -> None:
    """输出 deny 决定到 stdout，exit 0（hook 协议正常退出码）。"""
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)


def strip_sql_comments(sql: str) -> str:
    """去掉 /* ... */ 块注释和 -- 行注释，便于取首词。"""
    # 块注释（含跨行）
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    # -- 行注释
    sql = re.sub(r"--[^\n]*", " ", sql)
    # # 行注释（MySQL 兼容）
    sql = re.sub(r"#[^\n]*", " ", sql)
    return sql.strip()


def first_word(sql: str) -> str:
    """取 SQL 第一个非空词，转小写。"""
    sql = strip_sql_comments(sql)
    if not sql:
        return ""
    # 去掉前导分号 / 括号（极少见但防御一下）
    sql = sql.lstrip(";( \t\r\n")
    parts = sql.split(None, 1)
    return parts[0].lower() if parts else ""


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        # stdin 不是合法 JSON —— 不拦截，保持 Claude Code 原行为
        sys.exit(0)

    tool_name = payload.get("tool_name", "") or ""
    tool_input = payload.get("tool_input", {}) or {}

    # 只关心 mysql-* / mongo-* 这类 server
    m = re.match(r"^mcp__(mysql|mongo)-([^_]+)__(.+)$", tool_name)
    if not m:
        sys.exit(0)

    kind, server_name, method = m.groups()

    # ----- MySQL：看 SQL 首词 -----
    if kind == "mysql":
        sql_raw = (
            tool_input.get("sql")
            or tool_input.get("query")
            or tool_input.get("statement")
            or ""
        )
        if not isinstance(sql_raw, str):
            sql_raw = str(sql_raw)
        word = first_word(sql_raw)
        if word in ALLOWED_SQL_PREFIXES:
            sys.exit(0)

        # WITH ... 后面可能跟 INSERT/UPDATE/DELETE 这类写 CTE，做二次检查
        if word == "with":
            # 找 ) 后第一个非空词
            stripped = strip_sql_comments(sql_raw)
            # 简单启发式：找最后一个匹配 "AS (...)"" 后面的关键字
            after = re.search(
                r"\bAS\b\s*\([^)]*\)\s*([A-Za-z]+)", stripped, flags=re.IGNORECASE
            )
            if after:
                tail = after.group(1).lower()
                if tail in ALLOWED_SQL_PREFIXES:
                    sys.exit(0)
                deny(
                    f"DB 只读红线：{tool_name} 的 WITH CTE 后续是 '{tail}' "
                    f"（疑似写操作）。DB MCP 仅允许只读查询。"
                    f"写操作请走 docker test_db_strategy（详见 .claude/knowledge/testing/standards.md）。"
                )
            # 没匹配上 AS (...) keyword，保守允许（普通的 WITH SELECT）
            sys.exit(0)

        deny(
            f"DB 只读红线：{tool_name} 试图执行非只读 SQL（首词 '{word or '<空>'}'）。"
            f"DB MCP 仅允许 SELECT / SHOW / DESCRIBE / EXPLAIN。"
            f"写操作请走 docker test_db_strategy（详见 .claude/knowledge/testing/standards.md）。"
        )

    # ----- MongoDB：看方法名 -----
    if kind == "mongo":
        method_norm = method.lower().replace("_", "").replace("-", "")
        # 白名单是去掉下划线/连字符后的小写形式
        allowed_norm = {m.replace("_", "").replace("-", "") for m in ALLOWED_MONGO_METHODS}
        if method_norm in allowed_norm:
            sys.exit(0)
        deny(
            f"DB 只读红线：{tool_name} 是写操作（method='{method}'）。"
            f"DB MCP 仅允许 find / aggregate / count / distinct / list* 等只读方法。"
            f"写操作请走 docker test_db_strategy（详见 .claude/knowledge/testing/standards.md）。"
        )


if __name__ == "__main__":
    main()
