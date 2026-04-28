#!/usr/bin/env bash
#
# 远程日志查询工具（per-project，按需手跑或由 Claude 通过 Bash 工具调用）
#
# 设计：
#   · 直接用 IP / hostname + 用户 + 端口 + 私钥接入，不依赖 ~/.ssh/config
#   · 可选 bastion（ProxyJump）字段，自动通过跳板访问内网机器
#   · 只构造 read-only 命令（tail / grep / cat / zcat / ls），永不写
#   · 不缓存日志到本地，每次现拉（敏感信息不落盘）
#   · 配置在 .claude/logs.yaml（每项目独立）
#
# 用法：
#   bash .claude/scripts/log-query.sh --list                # 列已配 target
#   bash .claude/scripts/log-query.sh --add                 # 交互式新增 target
#   bash .claude/scripts/log-query.sh --remove NAME         # 删 target
#   bash .claude/scripts/log-query.sh --files NAME          # 列该 target 的日志文件（不取内容）
#
#   # 查询主用法
#   bash .claude/scripts/log-query.sh --target NAME [选项]
#     --tail N            最后 N 行（默认 200）
#     --grep PATTERN      过滤模式（可重复，多个 AND）
#     --grep-v PATTERN    排除模式（可重复，多个 AND）
#     --context N         匹配行的前后 N 行上下文（grep -C N）
#     --paths P1 P2 ...   一次性覆盖 logs.yaml 里的 paths（不写回）
#     --raw               不带 grep，纯 tail 输出
#
# 示例：
#   bash .claude/scripts/log-query.sh --list
#   bash .claude/scripts/log-query.sh --target prod-app --tail 500
#   bash .claude/scripts/log-query.sh --target prod-app --grep "OutOfMemory" --context 10
#   bash .claude/scripts/log-query.sh --target prod-app --grep "ERROR" --grep-v "expected"
#   bash .claude/scripts/log-query.sh --target prod-app --paths /var/log/nginx/access.log --grep " 5\d\d "
#
# logs.yaml 格式（参考 .claude/logs.yaml.example）：
#   targets:
#     prod-app:
#       host: 10.0.5.10            # 必填，IP 或 hostname
#       user: deploy               # 必填，远端用户
#       port: 22                   # 可选，默认 22
#       key: ~/.ssh/id_rsa         # 可选，私钥路径
#       bastion: corray@10.0.0.1:22  # 可选，ProxyJump 跳板（含 user@host[:port]）
#       paths:                     # 必填，至少 1 个日志文件路径
#         - /var/log/app/error.log
#       default_grep_v:            # 可选，默认排除的噪音模式
#         - "DEBUG"
#
# 安全：
#   · ssh 远端只跑 tail / grep / cat / zcat / ls，不接受任意命令
#   · path / pattern 经严格字符校验，防注入
#   · 不存任何凭据，全靠你已有的 SSH 私钥
#
# 依赖：
#   · python3 + PyYAML（pip install pyyaml --break-system-packages）
#   · ssh（POSIX 标准）

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOGS_YAML=".claude/logs.yaml"

# ─── 参数解析 ──────────────────────────────────────────────────────────
ACTION="query"
TARGET=""
TAIL_N=""
CONTEXT_N=""
GREP_PATTERNS=()
GREP_V_PATTERNS=()
PATHS_OVERRIDE=()
RAW=0

usage() {
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^#[ ]?/,""); print; next} {exit}' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list) ACTION="list"; shift ;;
    --add) ACTION="add"; shift ;;
    --remove)
      ACTION="remove"
      [ -z "$2" ] && { echo "错误：--remove 需要 target 名"; exit 1; }
      TARGET="$2"; shift 2 ;;
    --files)
      ACTION="files"
      [ -z "$2" ] && { echo "错误：--files 需要 target 名"; exit 1; }
      TARGET="$2"; shift 2 ;;
    --target)
      [ -z "$2" ] && { echo "错误：--target 需要值"; exit 1; }
      TARGET="$2"; shift 2 ;;
    --tail)
      [ -z "$2" ] && { echo "错误：--tail 需要数字"; exit 1; }
      TAIL_N="$2"; shift 2 ;;
    --context|-C)
      [ -z "$2" ] && { echo "错误：--context 需要数字"; exit 1; }
      CONTEXT_N="$2"; shift 2 ;;
    --grep)
      [ -z "$2" ] && { echo "错误：--grep 需要 pattern"; exit 1; }
      GREP_PATTERNS+=("$2"); shift 2 ;;
    --grep-v)
      [ -z "$2" ] && { echo "错误：--grep-v 需要 pattern"; exit 1; }
      GREP_V_PATTERNS+=("$2"); shift 2 ;;
    --paths)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        PATHS_OVERRIDE+=("$1"); shift
      done ;;
    --raw) RAW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "未识别的参数: $1"
      echo "用 -h 看用法"
      exit 1 ;;
  esac
done

# ─── 依赖检查 ──────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
  echo -e "${RED}错误：需要 python3${NC}"
  exit 2
fi
if ! python3 -c "import yaml" 2>/dev/null; then
  echo -e "${RED}错误：需要 PyYAML${NC}"
  echo "  安装：pip install pyyaml --break-system-packages"
  echo "  或：pip install pyyaml --user"
  exit 2
fi
if ! command -v ssh >/dev/null 2>&1; then
  echo -e "${RED}错误：需要 ssh 命令${NC}"
  exit 2
fi

# ─── 子命令实现 ───────────────────────────────────────────────────────

action_list() {
  if [ ! -f "$LOGS_YAML" ]; then
    echo -e "${YELLOW}（$LOGS_YAML 不存在，先用 --add 创建）${NC}"
    exit 0
  fi
  python3 - "$LOGS_YAML" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
targets = cfg.get('targets', {}) or {}
if not targets:
    print("（logs.yaml 里没有 targets）")
    sys.exit(0)
print(f"{'名字':<20} {'用户@主机:端口':<32} {'路径数':<8} {'跳板':<6}")
print("-" * 75)
for name, t in targets.items():
    host = t.get('host', '?')
    user = t.get('user', '?')
    port = t.get('port', 22)
    paths = t.get('paths', []) or []
    bastion = "Y" if t.get('bastion') else "-"
    addr = f"{user}@{host}:{port}"
    print(f"{name:<20} {addr:<32} {len(paths):<8} {bastion:<6}")
PY
}

action_add() {
  if [ ! -f "$LOGS_YAML" ]; then
    mkdir -p "$(dirname "$LOGS_YAML")"
    cat > "$LOGS_YAML" <<'YAML'
# 远程日志查询配置（log-query.sh 读这个文件）
# 格式见 .claude/logs.yaml.example
targets: {}
YAML
    echo -e "  ${GREEN}✓${NC} 创建 $LOGS_YAML"
  fi

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  添加日志 target${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

  local name host user port key bastion
  while true; do
    read -p "名字（如 prod-app / staging-mysql）: " name
    if [ -z "$name" ]; then
      echo "  名字不能为空"; continue
    fi
    if echo "$name" | grep -E -v '^[a-z0-9][a-z0-9-]*$' >/dev/null; then
      echo "  只能小写字母/数字/连字符"; continue
    fi
    break
  done

  read -p "服务器 IP 或 hostname: " host
  [ -z "$host" ] && { echo "  host 不能为空"; exit 1; }

  read -p "远端用户名（默认 $USER）: " user
  [ -z "$user" ] && user="$USER"

  read -p "SSH 端口（默认 22）: " port
  [ -z "$port" ] && port="22"

  read -p "私钥路径（回车=用 ssh-agent 或默认 ~/.ssh/id_rsa）: " key

  echo ""
  echo "如果该机器在内网需走跳板，输入 bastion（格式 user@host[:port]），不需要回车："
  read -p "Bastion: " bastion

  echo ""
  echo "日志文件路径（一行一个，支持 glob，回车空行结束）"
  echo "  例：/var/log/app/error.log"
  echo "  例：/var/log/app/*.log"
  local -a paths=()
  while true; do
    read -p "  > " p
    [ -z "$p" ] && break
    paths+=("$p")
  done
  if [ ${#paths[@]} -eq 0 ]; then
    echo "  至少要 1 个路径"; exit 1
  fi

  python3 - "$LOGS_YAML" "$name" "$host" "$user" "$port" "$key" "$bastion" "${paths[@]}" <<'PY'
import sys, yaml
yaml_path, name, host, user, port, key, bastion = sys.argv[1:8]
paths = sys.argv[8:]
with open(yaml_path) as f:
    cfg = yaml.safe_load(f) or {}
cfg.setdefault('targets', {})
existed = name in cfg['targets']
entry = {
    'host': host,
    'user': user,
    'paths': paths,
}
if port and port != "22":
    entry['port'] = int(port)
if key:
    entry['key'] = key
if bastion:
    entry['bastion'] = bastion
cfg['targets'][name] = entry
with open(yaml_path, 'w') as f:
    yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
print(("更新" if existed else "新增") + f" target: {name}")
PY
  echo ""
  echo -e "${GREEN}✓ 完成${NC}"
  echo "下一步：bash $0 --target $name --tail 100   # 试一下能否拉到日志"
}

action_remove() {
  if [ ! -f "$LOGS_YAML" ]; then
    echo "（$LOGS_YAML 不存在，无可删）"
    exit 0
  fi
  python3 - "$LOGS_YAML" "$TARGET" <<'PY'
import sys, yaml
path, name = sys.argv[1:]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
targets = cfg.get('targets', {}) or {}
if name not in targets:
    print(f"（{name} 不在 logs.yaml 里，跳过）")
    sys.exit(0)
del targets[name]
cfg['targets'] = targets
with open(path, 'w') as f:
    yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
print(f"已删除 target: {name}")
PY
}

# 解析 target 配置（输出 JSON 到 stdout：{host, user, port, key, bastion, paths[], default_grep_v[]}）
resolve_target() {
  python3 - "$LOGS_YAML" "$TARGET" <<'PY'
import sys, json, yaml, os
path, name = sys.argv[1:]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
targets = cfg.get('targets', {}) or {}
if name not in targets:
    print(f"错误：target '{name}' 不在 {path}", file=sys.stderr)
    available = list(targets.keys())
    if available:
        print(f"  可用 target: {', '.join(available)}", file=sys.stderr)
    else:
        print(f"  （logs.yaml 是空的，先 --add）", file=sys.stderr)
    sys.exit(2)
t = targets[name]

# v1 字段校验
host = t.get('host')
user = t.get('user')
if not host or not user:
    print(f"错误：target '{name}' 缺 host 或 user 字段", file=sys.stderr)
    sys.exit(2)

key = t.get('key', '')
if key:
    key = os.path.expanduser(key)

print(json.dumps({
    'host': host,
    'user': user,
    'port': int(t.get('port', 22)),
    'key': key,
    'bastion': t.get('bastion', ''),
    'paths': t.get('paths', []) or [],
    'default_grep_v': t.get('default_grep_v', []) or [],
}, ensure_ascii=False))
PY
}

# 把 target JSON 转成 ssh 调用所需的 args 数组（不含远端命令）
# 输出到 stdout：每行一个 arg
build_ssh_args() {
  local target_json="$1"
  python3 - "$target_json" <<'PY'
import sys, json
t = json.loads(sys.argv[1])
args = ["-o", "BatchMode=yes"]
if t.get('port') and t['port'] != 22:
    args += ["-p", str(t['port'])]
if t.get('key'):
    args += ["-i", t['key']]
if t.get('bastion'):
    args += ["-J", t['bastion']]
args.append(f"{t['user']}@{t['host']}")
for a in args:
    print(a)
PY
}

action_files() {
  local target_json
  target_json=$(resolve_target) || exit 2

  local paths_str
  paths_str=$(echo "$target_json" | python3 -c "import sys,json,shlex;print(' '.join(shlex.quote(p) for p in json.load(sys.stdin)['paths']))")

  if [ -z "$paths_str" ]; then
    echo "错误：该 target 没有配置 paths"
    exit 2
  fi

  # ssh args
  local -a ssh_args=()
  while IFS= read -r line; do
    [ -n "$line" ] && ssh_args+=("$line")
  done < <(build_ssh_args "$target_json")

  local remote_cmd="ls -la $paths_str 2>/dev/null || true"
  echo -e "${BLUE}>>> ssh ${ssh_args[*]} '$remote_cmd'${NC}"
  ssh "${ssh_args[@]}" "$remote_cmd"
}

action_query() {
  local target_json
  target_json=$(resolve_target) || exit 2

  # 用 Python 构建带正确 shlex 转义的远端命令
  local remote_cmd
  remote_cmd=$(python3 - "$target_json" "$TAIL_N" "$CONTEXT_N" "$RAW" \
    "${#PATHS_OVERRIDE[@]}" "${PATHS_OVERRIDE[@]}" \
    "${#GREP_PATTERNS[@]}" "${GREP_PATTERNS[@]}" \
    "${#GREP_V_PATTERNS[@]}" "${GREP_V_PATTERNS[@]}" <<'PY'
import sys, json, shlex, re
target_json = sys.argv[1]
tail_n = sys.argv[2] or "200"
context_n = sys.argv[3]
raw = sys.argv[4] == "1"
i = 5
n_paths_override = int(sys.argv[i]); i += 1
paths_override = sys.argv[i:i+n_paths_override]; i += n_paths_override
n_grep = int(sys.argv[i]); i += 1
greps = sys.argv[i:i+n_grep]; i += n_grep
n_grep_v = int(sys.argv[i]); i += 1
grep_vs = sys.argv[i:i+n_grep_v]

t = json.loads(target_json)
paths = paths_override if paths_override else t['paths']
default_grep_v = t.get('default_grep_v') or []
all_grep_v = list(default_grep_v) + list(grep_vs)

if not paths:
    print("ERR: 没有 paths（target 配置为空且未传 --paths）", file=sys.stderr)
    sys.exit(2)

# 安全检查：禁止 path / pattern 含 shell metachar
def safe_pattern(p):
    bad = [';', '&', '`', '$(', '\n', '\r']
    for b in bad:
        if b in p:
            return False
    return True

def safe_path(p):
    return re.match(r'^[A-Za-z0-9_./\-*?+\[\]@~]+$', p) is not None

for p in paths:
    if not safe_path(p):
        print(f"ERR: path 含非法字符：{p}", file=sys.stderr)
        sys.exit(2)
for p in greps + all_grep_v:
    if not safe_pattern(p):
        print(f"ERR: pattern 含 shell metachar：{p}", file=sys.stderr)
        sys.exit(2)

# 验证 tail / context 是数字
try:
    tail_n_i = int(tail_n)
    if tail_n_i < 1 or tail_n_i > 1000000:
        raise ValueError
except ValueError:
    print(f"ERR: --tail 必须是 1..1000000 的整数：{tail_n}", file=sys.stderr)
    sys.exit(2)

if context_n:
    try:
        ctx_i = int(context_n)
        if ctx_i < 0 or ctx_i > 1000:
            raise ValueError
    except ValueError:
        print(f"ERR: --context 必须是 0..1000 的整数：{context_n}", file=sys.stderr)
        sys.exit(2)

# 构造命令：tail -n N <files> | grep -v ... | grep ...
parts = []
quoted_paths = " ".join(shlex.quote(p) for p in paths)
parts.append(f"tail -n {tail_n_i} {quoted_paths} 2>/dev/null")

for pat in all_grep_v:
    parts.append(f"grep -v -E {shlex.quote(pat)}")

ctx_args = f"-C {int(context_n)} " if context_n else ""
for pat in greps:
    parts.append(f"grep {ctx_args}-E {shlex.quote(pat)}")

if raw:
    cmd = parts[0]
else:
    cmd = " | ".join(parts)

print(cmd)
PY
)
  if [ -z "$remote_cmd" ]; then
    exit 2
  fi

  # ssh args
  local -a ssh_args=()
  while IFS= read -r line; do
    [ -n "$line" ] && ssh_args+=("$line")
  done < <(build_ssh_args "$target_json")

  echo -e "${BLUE}>>> ssh ${ssh_args[*]} '$remote_cmd'${NC}"
  echo "─────────────────────────────────────────────────────"
  ssh "${ssh_args[@]}" "$remote_cmd"
}

# ─── 主入口 ────────────────────────────────────────────────────────────

case "$ACTION" in
  list) action_list ;;
  add) action_add ;;
  remove)
    [ -z "$TARGET" ] && { echo "错误：--remove 需要 target 名"; exit 1; }
    action_remove ;;
  files)
    [ -z "$TARGET" ] && { echo "错误：--files 需要 target 名"; exit 1; }
    action_files ;;
  query)
    if [ -z "$TARGET" ]; then
      echo "错误：query 模式需要 --target NAME"
      echo "  跑 --list 看可用 target，或 --add 加新 target"
      exit 1
    fi
    if [ ! -f "$LOGS_YAML" ]; then
      echo "错误：$LOGS_YAML 不存在，先用 --add 创建"
      exit 1
    fi
    action_query ;;
esac
