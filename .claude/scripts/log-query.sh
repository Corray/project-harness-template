#!/usr/bin/env bash
#
# 远程日志查询 —— bash 薄壳，实际逻辑在 log-query.py（paramiko 实现）。
#
# 保留这个 .sh 是为了兼容 "bash .claude/scripts/log-query.sh ..." 的旧用法。
# 直接调 python3 .claude/scripts/log-query.py ... 也完全等价。
#
# 详细用法：bash .claude/scripts/log-query.sh -h
exec python3 "$(cd "$(dirname "$0")" && pwd)/log-query.py" "$@"
