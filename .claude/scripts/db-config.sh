#!/usr/bin/env bash
#
# Per-project 数据库 MCP 配置工具
#
# 这个脚本只动当前项目的 .mcp.json + 全局 ~/.ssh/config（合并模式）
# 不会动其他项目的配置。重跑安全（幂等）。
#
# 用法：
#   bash .claude/scripts/db-config.sh              # 交互式新增/修改 DB
#   bash .claude/scripts/db-config.sh --list       # 列当前已配的 DB
#   bash .claude/scripts/db-config.sh --remove NAME  # 删某个 DB
#   bash .claude/scripts/db-config.sh -h           # 帮助
#
# 它做的事：
#   1. 在项目 .mcp.json 中新增/更新 MCP server 条目（mysql-{name} / mongo-{name}）
#   2. 如果该 DB 选了 SSH 隧道，在 ~/.ssh/config 中追加 LocalForward
#   3. 第一次配 SSH 时可选装后台隧道服务（macOS launchd / Linux systemd-user）
#   4. 在 .claude/dbs.yaml 中追加新 DB（用于启动类映射）
#   5. 打印 env var 清单，让你复制到 ~/.zshrc
#
# 不动的内容：
#   - .mcp.json 中的其他 MCP server（github / tapd / jenkins / 其他 db）
#   - 项目的代码、文档、共识文件等

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ----- 参数解析 -----
ACTION="add"     # add / list / remove
REMOVE_NAME=""

prev=""
for arg in "$@"; do
  case "$arg" in
    --list) ACTION="list" ;;
    --remove) ACTION="remove" ;;
    --remove=*) ACTION="remove"; REMOVE_NAME="${arg#--remove=}" ;;
    -h|--help)
      awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^#[ ]?/,""); print; next} {exit}' "$0"
      exit 0
      ;;
  esac
  [ "$prev" = "--remove" ] && REMOVE_NAME="$arg"
  prev="$arg"
done

# ----- 前置检查 -----
if [ ! -f ".mcp.json" ]; then
  echo -e "${RED}错误：当前目录没有 .mcp.json${NC}"
  echo "  请在项目根目录执行（先跑过 setup.sh 或 upgrade.sh）"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo -e "${RED}错误：需要 python3 来安全地编辑 JSON${NC}"
  exit 1
fi

OS=$(uname -s)
SSH_CONFIG="$HOME/.ssh/config"

# ----- JSON 操作（用内嵌 Python，比 jq 更通用） -----

# 列出所有 mysql-* / mongo-* 的 server
list_dbs() {
  python3 <<'PY'
import json, sys
try:
    cfg = json.load(open(".mcp.json"))
except Exception as e:
    print(f"读取 .mcp.json 失败：{e}")
    sys.exit(1)
servers = cfg.get("mcpServers", {})
dbs = [(name, s) for name, s in servers.items()
       if name.startswith("mysql-") or name.startswith("mongo-")]
if not dbs:
    print("（当前项目没有配置任何 DB MCP）")
    sys.exit(0)
print(f"{'名字':<20} {'类型':<8} {'主机':<20} {'端口':<8} {'走 SSH':<8}")
print("-" * 70)
for name, s in dbs:
    env = s.get("env", {})
    if name.startswith("mysql-"):
        kind = "mysql"
        host = env.get("MYSQL_HOST", "?")
        port = env.get("MYSQL_PORT", "?")
    else:
        kind = "mongo"
        uri = env.get("MONGODB_URI", "")
        host = "127.0.0.1" if "@127.0.0.1:" in uri or "@localhost:" in uri else "(嵌在 URI 中)"
        port = "(嵌在 URI 中)"
    is_local = host in ("127.0.0.1", "localhost")
    print(f"{name:<20} {kind:<8} {host:<20} {str(port):<8} {'Y' if is_local else 'N':<8}")
PY
}

# 删除一个 server
remove_db() {
  local name="$1"
  if [ -z "$name" ]; then
    echo -e "${RED}错误：--remove 需要 server 名字${NC}"
    exit 1
  fi
  python3 - "$name" <<'PY'
import json, sys
name = sys.argv[1]
cfg = json.load(open(".mcp.json"))
servers = cfg.get("mcpServers", {})
if name not in servers:
    print(f"（{name} 不在 .mcp.json 里，跳过）")
    sys.exit(0)
del servers[name]
json.dump(cfg, open(".mcp.json", "w"), indent=2, ensure_ascii=False)
print(f"已从 .mcp.json 删除 {name}")
print("提示：~/.ssh/config 的 LocalForward 行没动；如果不再需要可以手动清理")
PY
}

# 把一个 server 写入 .mcp.json（覆盖同名条目）
upsert_server() {
  local name="$1"
  local server_json="$2"
  python3 - "$name" "$server_json" <<'PY'
import json, sys
name = sys.argv[1]
server = json.loads(sys.argv[2])
cfg = json.load(open(".mcp.json"))
cfg.setdefault("mcpServers", {})
existed = name in cfg["mcpServers"]
cfg["mcpServers"][name] = server
json.dump(cfg, open(".mcp.json", "w"), indent=2, ensure_ascii=False)
print(("更新" if existed else "新增") + f" .mcp.json: {name}")
PY
}

# ----- SSH config 操作 -----

# 找一个本地未占用的端口（扫已有 ssh config 里的 LocalForward）
next_free_port() {
  local start="$1"
  local current="$start"
  while grep -E "^\s*LocalForward\s+$current\s+" "$SSH_CONFIG" >/dev/null 2>&1; do
    current=$((current + 1))
  done
  echo "$current"
}

# 追加 LocalForward 到 ~/.ssh/config 的 db-tunnel 段
# 如果 db-tunnel Host 段不存在，整段创建
# 已存在的 LocalForward 行不重复添加
ensure_ssh_tunnel() {
  local local_port="$1"
  local remote_host="$2"
  local remote_port="$3"
  local bastion_host="$4"
  local bastion_user="$5"
  local ssh_key="$6"

  mkdir -p "$(dirname "$SSH_CONFIG")"
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"

  if ! grep -E "^\s*Host\s+db-tunnel\b" "$SSH_CONFIG" >/dev/null 2>&1; then
    # 创建 db-tunnel Host 段
    cat >> "$SSH_CONFIG" <<EOF

# === harness db-tunnel (managed by db-config.sh) ===
Host db-tunnel
  HostName $bastion_host
  User $bastion_user
  IdentityFile $ssh_key
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ExitOnForwardFailure yes
  LocalForward $local_port $remote_host:$remote_port
EOF
    echo -e "  ${GREEN}✓${NC} 在 $SSH_CONFIG 创建了 db-tunnel Host 段"
  else
    # 段已存在，只追加 LocalForward 行（如果还没有）
    if grep -E "^\s*LocalForward\s+$local_port\s+$remote_host:$remote_port\s*$" "$SSH_CONFIG" >/dev/null 2>&1; then
      echo -e "  · LocalForward $local_port → $remote_host:$remote_port 已存在，跳过"
    else
      # 在 db-tunnel Host 段最后一行后插入
      python3 - "$SSH_CONFIG" "$local_port" "$remote_host" "$remote_port" <<'PY'
import sys, re
path, lp, rh, rp = sys.argv[1:]
with open(path) as f:
    lines = f.readlines()
out = []
i = 0
in_section = False
last_section_line = -1
for idx, line in enumerate(lines):
    if re.match(r"^\s*Host\s+db-tunnel\b", line):
        in_section = True
    elif in_section and re.match(r"^\s*Host\s+\S+", line):
        in_section = False
    if in_section:
        last_section_line = idx
new_line = f"  LocalForward {lp} {rh}:{rp}\n"
if last_section_line >= 0:
    lines.insert(last_section_line + 1, new_line)
with open(path, "w") as f:
    f.writelines(lines)
PY
      echo -e "  ${GREEN}✓${NC} 在 $SSH_CONFIG 的 db-tunnel 段追加：LocalForward $local_port $remote_host:$remote_port"
    fi
  fi
}

# 安装后台隧道服务（macOS launchd / Linux systemd-user）
install_tunnel_service() {
  case "$OS" in
    Darwin)
      install_tunnel_launchd
      ;;
    Linux)
      install_tunnel_systemd
      ;;
    *)
      echo -e "  ${YELLOW}⚠${NC} 不支持的 OS：$OS，请手动启动 \`autossh -M 0 -N db-tunnel\`"
      ;;
  esac
}

install_tunnel_launchd() {
  local plist="$HOME/Library/LaunchAgents/com.harness.db-tunnel.plist"
  if [ -f "$plist" ]; then
    echo -e "  · launchd 服务已存在（$plist），跳过安装"
    echo "    重启服务：launchctl unload \"$plist\" && launchctl load \"$plist\""
    return
  fi

  if ! command -v autossh >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⚠${NC} 没装 autossh"
    echo "    建议：brew install autossh"
    echo "    然后再跑一次：bash .claude/scripts/db-config.sh"
    return
  fi

  local autossh_path
  autossh_path=$(command -v autossh)
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.harness.db-tunnel</string>
  <key>ProgramArguments</key>
  <array>
    <string>$autossh_path</string>
    <string>-M</string>
    <string>0</string>
    <string>-N</string>
    <string>db-tunnel</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AUTOSSH_GATETIME</key>
    <string>0</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/harness-db-tunnel.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/harness-db-tunnel.err</string>
</dict>
</plist>
PLIST
  launchctl load "$plist" 2>/dev/null || true
  echo -e "  ${GREEN}✓${NC} 装好 launchd 后台服务（开机自启 + 自动重连）"
  echo "    日志：tail -f /tmp/harness-db-tunnel.log"
  echo "    手动停：launchctl unload \"$plist\""
}

install_tunnel_systemd() {
  local svcdir="$HOME/.config/systemd/user"
  local svc="$svcdir/db-tunnel.service"
  if [ -f "$svc" ]; then
    echo -e "  · systemd-user 服务已存在（$svc），跳过安装"
    echo "    重启：systemctl --user restart db-tunnel"
    return
  fi

  if ! command -v autossh >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⚠${NC} 没装 autossh"
    echo "    Debian/Ubuntu: sudo apt install autossh"
    echo "    Fedora/RHEL  : sudo dnf install autossh"
    return
  fi

  mkdir -p "$svcdir"
  local autossh_path
  autossh_path=$(command -v autossh)
  cat > "$svc" <<UNIT
[Unit]
Description=Harness DB SSH Tunnel
After=network-online.target

[Service]
ExecStart=$autossh_path -M 0 -N db-tunnel
Environment=AUTOSSH_GATETIME=0
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now db-tunnel.service 2>/dev/null || true
  echo -e "  ${GREEN}✓${NC} 装好 systemd-user 服务（开机自启 + 自动重连）"
  echo "    状态：systemctl --user status db-tunnel"
  echo "    日志：journalctl --user -u db-tunnel -f"
  echo "    手动停：systemctl --user stop db-tunnel"
}

# ----- dbs.yaml 操作 -----

ensure_dbs_yaml() {
  local dbfile=".claude/dbs.yaml"
  if [ ! -f "$dbfile" ]; then
    mkdir -p .claude
    cat > "$dbfile" <<'YAML'
# 启动类 → 数据源映射
# Claude 在 /impl、/test-gen、/run-tasks 处理某个启动类时，
# 会按本表找到对应的 MCP server 名（如 mysql-order）。
#
# 单库项目可以不填 applications:，Claude 会按 .mcp.json 里第一个匹配类型的 server 走。
#
# 测试策略 test_db_strategy:
#   shared          - 直接连配置的 DB（共享，要小心写操作）
#   schema-isolated - 用独立 schema/database 名前缀做隔离
#   docker          - 测试时用 docker-compose 起本地 DB（推荐做集成测试）

applications:
  # ExampleApplication:
  #   main_class: com.example.ExampleApplication
  #   module: example-service
  #   databases:
  #     mysql: mysql-example      # 引用 .mcp.json 里的 server 名
  #     mongo: mongo-example      # 选填
  #   test_db_strategy: schema-isolated

# 由 db-config.sh 自动追加的 DB 清单（仅作记录，启动类映射靠你手填）
discovered_dbs:
YAML
    echo -e "  ${GREEN}✓${NC} 创建 $dbfile（请手填启动类映射）"
  fi
}

# 在 dbs.yaml 的 discovered_dbs 段追加一条
record_db_in_yaml() {
  local name="$1"
  local kind="$2"
  local target="$3"
  local dbfile=".claude/dbs.yaml"
  if grep -E "^\s*-\s*name:\s*$name\s*$" "$dbfile" >/dev/null 2>&1; then
    return
  fi
  cat >> "$dbfile" <<EOF
  - name: $name
    type: $kind
    target: $target
EOF
}

# ----- 交互式添加流程 -----

interactive_add() {
  local SSH_USED=0
  local BASTION_HOST=""
  local BASTION_USER=""
  local SSH_KEY=""
  local -a ENV_HINTS=()

  while true; do
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  添加数据库${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

    # 类型
    local kind
    while true; do
      read -p "类型 (mysql/mongo): " kind
      [ "$kind" = "mysql" ] || [ "$kind" = "mongo" ] && break
      echo -e "  ${RED}请输入 mysql 或 mongo${NC}"
    done

    # 名字
    local name
    while true; do
      read -p "名字（用于 MCP server 名，例如 order / billing）: " name
      [ -z "$name" ] && { echo -e "  ${RED}名字不能为空${NC}"; continue; }
      if echo "$name" | grep -E -v '^[a-z0-9][a-z0-9-]*$' >/dev/null; then
        echo -e "  ${RED}只能小写字母/数字/连字符，且必须以字母数字开头${NC}"
        continue
      fi
      break
    done
    local server_name="${kind}-${name}"

    # 主机/IP
    local host
    read -p "数据库内网主机/IP: " host
    [ -z "$host" ] && { echo -e "  ${RED}主机不能为空${NC}"; continue; }

    # 远端端口（默认按类型）
    local default_remote_port
    if [ "$kind" = "mysql" ]; then default_remote_port=3306; else default_remote_port=27017; fi
    local remote_port
    read -p "数据库端口（默认 $default_remote_port）: " remote_port
    [ -z "$remote_port" ] && remote_port=$default_remote_port

    # 库名（mysql 必填，mongo 选填）
    local dbname
    if [ "$kind" = "mysql" ]; then
      read -p "库名（database）: " dbname
      [ -z "$dbname" ] && { echo -e "  ${RED}库名不能为空${NC}"; continue; }
    else
      read -p "库名（默认 admin）: " dbname
      [ -z "$dbname" ] && dbname="admin"
    fi

    # SSH 选择
    local use_ssh
    read -p "需要 SSH 隧道吗？(Y/n): " use_ssh
    use_ssh=${use_ssh:-Y}

    local effective_host="$host"
    local effective_port="$remote_port"

    if [ "$use_ssh" = "y" ] || [ "$use_ssh" = "Y" ]; then
      SSH_USED=1
      # bastion 信息只问一次
      if [ -z "$BASTION_HOST" ]; then
        # 检测已有 db-tunnel 段
        if grep -E "^\s*Host\s+db-tunnel\b" "$SSH_CONFIG" >/dev/null 2>&1; then
          BASTION_HOST=$(awk '/^\s*Host\s+db-tunnel\s*$/,/^\s*Host\s+/' "$SSH_CONFIG" | grep -E "^\s*HostName\s+" | head -1 | awk '{print $2}')
          BASTION_USER=$(awk '/^\s*Host\s+db-tunnel\s*$/,/^\s*Host\s+/' "$SSH_CONFIG" | grep -E "^\s*User\s+" | head -1 | awk '{print $2}')
          SSH_KEY=$(awk '/^\s*Host\s+db-tunnel\s*$/,/^\s*Host\s+/' "$SSH_CONFIG" | grep -E "^\s*IdentityFile\s+" | head -1 | awk '{print $2}')
          echo -e "  · 复用已有 db-tunnel：$BASTION_USER@$BASTION_HOST"
        else
          read -p "Bastion 主机（如 bastion.your-company.com）: " BASTION_HOST
          read -p "Bastion 用户（如 $USER）: " BASTION_USER
          [ -z "$BASTION_USER" ] && BASTION_USER="$USER"
          read -p "SSH 私钥路径（默认 ~/.ssh/id_rsa）: " SSH_KEY
          [ -z "$SSH_KEY" ] && SSH_KEY="~/.ssh/id_rsa"
        fi
      fi

      # 本地端口分配
      local local_port
      read -p "本地映射端口（回车=自动分配，从 $default_remote_port 起找）: " local_port
      [ -z "$local_port" ] && local_port=$(next_free_port "$default_remote_port")

      ensure_ssh_tunnel "$local_port" "$host" "$remote_port" "$BASTION_HOST" "$BASTION_USER" "$SSH_KEY"

      effective_host="127.0.0.1"
      effective_port="$local_port"
    fi

    # 凭据 env var 名
    local user_env pwd_env
    local upper_name
    upper_name=$(echo "$name" | tr 'a-z-' 'A-Z_')
    if [ "$kind" = "mysql" ]; then
      user_env="MYSQL_${upper_name}_USER"
      pwd_env="MYSQL_${upper_name}_PASSWORD"
    else
      user_env="MONGO_${upper_name}_USER"
      pwd_env="MONGO_${upper_name}_PASSWORD"
    fi
    echo -e "  · env var 名：${CYAN}\$$user_env${NC} / ${CYAN}\$$pwd_env${NC}"

    # 构造 server JSON
    local server_json
    if [ "$kind" = "mysql" ]; then
      server_json=$(python3 - "$effective_host" "$effective_port" "$user_env" "$pwd_env" "$dbname" <<'PY'
import json, sys
host, port, ue, pe, db = sys.argv[1:]
print(json.dumps({
    "command": "npx",
    "args": ["-y", "@executeautomation/mcp-server-mysql"],
    "env": {
        "MYSQL_HOST": host,
        "MYSQL_PORT": str(port),
        "MYSQL_USER": "${" + ue + "}",
        "MYSQL_PASSWORD": "${" + pe + "}",
        "MYSQL_DATABASE": db
    }
}))
PY
)
    else
      server_json=$(python3 - "$effective_host" "$effective_port" "$user_env" "$pwd_env" "$dbname" <<'PY'
import json, sys
host, port, ue, pe, db = sys.argv[1:]
uri = "mongodb://${" + ue + "}:${" + pe + "}@" + host + ":" + str(port) + "/" + db
print(json.dumps({
    "command": "npx",
    "args": ["-y", "mongodb-mcp-server"],
    "env": {
        "MONGODB_URI": uri
    }
}))
PY
)
    fi

    upsert_server "$server_name" "$server_json"
    ensure_dbs_yaml
    record_db_in_yaml "$server_name" "$kind" "$host:$remote_port"
    ENV_HINTS+=("$user_env" "$pwd_env")

    echo -e "  ${GREEN}✓${NC} $server_name 配置完成"

    # 继续？
    local more
    read -p $'\n继续添加下一个数据库？(y/N): ' more
    [ "$more" != "y" ] && [ "$more" != "Y" ] && break
  done

  # SSH 后台服务（如有任何 DB 用了 SSH）
  if [ $SSH_USED -eq 1 ]; then
    echo ""
    local svc
    read -p "装后台 SSH 隧道服务（开机自启 + 自动重连）？(Y/n): " svc
    svc=${svc:-Y}
    if [ "$svc" = "y" ] || [ "$svc" = "Y" ]; then
      install_tunnel_service
    else
      echo -e "  · 跳过。手动启动隧道：${CYAN}ssh -N db-tunnel${NC}"
    fi
  fi

  # 环境变量提示
  if [ ${#ENV_HINTS[@]} -gt 0 ]; then
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  请把以下环境变量加到 ~/.zshrc 或 ~/.bashrc${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    local i=0
    while [ $i -lt ${#ENV_HINTS[@]} ]; do
      echo "  export ${ENV_HINTS[$i]}=\"...\""
      i=$((i + 1))
    done
    echo ""
    echo "  改完后：source ~/.zshrc"
  fi

  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  完成${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  echo ""
  echo "下一步："
  echo "  1. 配好 env var 后 source"
  echo "  2. 编辑 .claude/dbs.yaml 把启动类映射填上"
  echo "  3. 在 Claude 里尝试调用：mcp__mysql-{name}__query 等工具"
}

# ----- 主入口 -----

case "$ACTION" in
  list)
    list_dbs
    ;;
  remove)
    remove_db "$REMOVE_NAME"
    ;;
  add)
    interactive_add
    ;;
esac
