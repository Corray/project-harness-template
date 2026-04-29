#!/usr/bin/env bash
# evaluator-marker.sh — /adversarial-review 守卫期 marker 管理
#
# 给 /adversarial-review 父 session 用：在每次 Task spawn 独立 Evaluator 之前
# 写 marker，spawn 完成后清 marker。marker 期间内会让 evaluator-context-guard
# hook 拦截 Read 工具对 journal / backend|frontend knowledge 的访问。
#
# 用法：
#   bash .claude/scripts/evaluator-marker.sh on  [--ttl 1800] [--reason "..."]
#   bash .claude/scripts/evaluator-marker.sh off
#   bash .claude/scripts/evaluator-marker.sh status
#
# 默认 TTL 30 分钟（防止父 session 崩溃留下永久守卫）。

set -eo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MARKER_DIR="$REPO_ROOT/.claude/.hooks"
MARKER_PATH="$MARKER_DIR/evaluator-active.json"

action="${1:-status}"
shift || true

ttl=1800
reason="adversarial-review"
while [ $# -gt 0 ]; do
  case "$1" in
    --ttl)    ttl="$2"; shift 2;;
    --reason) reason="$2"; shift 2;;
    *) echo "未知参数: $1" >&2; exit 2;;
  esac
done

case "$action" in
  on)
    mkdir -p "$MARKER_DIR"
    python3 - "$MARKER_PATH" "$ttl" "$reason" <<'PY'
import datetime as d
import json
import sys

marker_path, ttl, reason = sys.argv[1], int(sys.argv[2]), sys.argv[3]
now = d.datetime.now(d.timezone.utc)
exp = now + d.timedelta(seconds=ttl)
data = {
    "active": True,
    "created_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "expires_at": exp.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ttl_seconds": ttl,
    "spawned_by": reason,
}
with open(marker_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print(f"✓ Evaluator 守卫已开启（TTL {ttl}s，到期 {data['expires_at']}）")
PY
    ;;
  off)
    rm -f "$MARKER_PATH"
    echo "✓ Evaluator 守卫已关闭"
    ;;
  status)
    if [ -f "$MARKER_PATH" ]; then
      echo "marker 存在："
      cat "$MARKER_PATH"
    else
      echo "marker 不存在（守卫未激活）"
    fi
    ;;
  *)
    echo "用法: $0 {on|off|status} [--ttl N] [--reason ...]" >&2
    exit 2
    ;;
esac
