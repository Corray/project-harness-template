#!/usr/bin/env bash
# 自检：被 sh / dash 调用时强制重启为 bash（防止解析失败）
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
#
# Project Harness Template 安装脚本
# 用法：
#   1. 进入要接入的项目目录（必须是 Git 仓库）
#   2. 运行：bash /path/to/project-harness-template/setup.sh
#
# 安装内容：
# - 根目录 CLAUDE.md + HARNESS_PHILOSOPHY.md
# - .claude/commands/（14 个命令，含 /adversarial-review、/metrics、/dashboard、/command-feedback）
# - .claude/knowledge/（backend / frontend / testing / red-lines.md）
# - docs/ 目录骨架（baseline / consensus / design / feedback / tasks / workspace）
# - docs/workspace/.harness-metrics/（impl / adversarial / run-tasks / knowledge-hits / snapshots，/metrics 数据源）
# - docs/project.yaml 占位模板（由 /init-baseline 填充）
# - ~/.claude/harness-dashboard/build.py（/dashboard 聚合脚本，跨项目共享）
# - ~/.claude/harness-projects.yaml 注册本项目（/dashboard 项目列表数据源）
#
set -e

# ----- 颜色定义 -----
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ----- 参数 -----
CURRENT_DIR=$(pwd)
TEMPLATES_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${GREEN}=== Project Harness Template 安装脚本 ===${NC}"
echo ""

# ----- Step 1: 检查当前目录是否为 Git 仓库 -----
if [ ! -d ".git" ]; then
  echo -e "${RED}错误：当前目录不是 Git 仓库。${NC}"
  echo "请在项目根目录运行此脚本。"
  exit 1
fi

if [ "$CURRENT_DIR" = "$TEMPLATES_DIR" ]; then
  echo -e "${RED}错误：不能在模板目录本身运行安装脚本。${NC}"
  echo "请切换到要接入的项目目录后再运行。"
  exit 1
fi

echo -e "${GREEN}[1/4] 检测到目标项目：${CURRENT_DIR}${NC}"
echo ""

# ----- 公用函数：注册项目到 ~/.claude/harness-projects.yaml（幂等）-----
register_project() {
  local proj_name="$1"
  local proj_path="$2"
  local proj_type="$3"
  local today
  today=$(date +%Y-%m-%d)
  local yaml="$HOME/.claude/harness-projects.yaml"
  mkdir -p "$(dirname "$yaml")"

  if [ ! -f "$yaml" ]; then
    cat > "$yaml" <<YAML
version: 1
projects:
YAML
  fi

  # 按 path 精确匹配已注册则跳过
  if grep -F -q "    path: $proj_path" "$yaml" 2>/dev/null; then
    echo "  - ~/.claude/harness-projects.yaml：已注册，跳过"
    return 0
  fi

  cat >> "$yaml" <<YAML
  - name: $proj_name
    path: $proj_path
    type: $proj_type
    registered_at: $today
YAML
  echo "  - ~/.claude/harness-projects.yaml：已注册 $proj_name"
}

# ----- 公用函数：安装 /dashboard 聚合脚本（全局共享）-----
install_dashboard() {
  local src="$TEMPLATES_DIR/dashboard/build.py"
  if [ ! -f "$src" ]; then
    return 0
  fi
  mkdir -p "$HOME/.claude/harness-dashboard"
  cp "$src" "$HOME/.claude/harness-dashboard/build.py"
  echo "  - ~/.claude/harness-dashboard/build.py 已就位（/dashboard 聚合脚本）"
}

# ----- Step 2: 覆盖确认 -----
CONFLICTS=()
[ -f "./CLAUDE.md" ] && CONFLICTS+=("CLAUDE.md")
[ -f "./HARNESS_PHILOSOPHY.md" ] && CONFLICTS+=("HARNESS_PHILOSOPHY.md")
[ -d "./.claude/commands" ] && CONFLICTS+=(".claude/commands/")
[ -d "./.claude/knowledge" ] && CONFLICTS+=(".claude/knowledge/")
[ -f "./docs/project.yaml" ] && CONFLICTS+=("docs/project.yaml")

if [ ${#CONFLICTS[@]} -gt 0 ]; then
  echo -e "${YELLOW}以下文件/目录已存在，继续将被覆盖：${NC}"
  for item in "${CONFLICTS[@]}"; do
    echo "  - $item"
  done
  read -p "确认覆盖？(y/N): " CONFIRM
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo -e "${YELLOW}已取消安装${NC}"
    exit 0
  fi
  echo ""
fi

# ----- Step 3: 安装模板文件 -----
# 对齐 README 快速开始的 `cp -r .claude/ CLAUDE.md docs/ your-project-repo/`：
# 整目录复制以保留 docs/*/.gitkeep（否则空目录无法被 git 追踪）
echo -e "${GREEN}[2/4] 复制模板文件${NC}"

mkdir -p .claude docs

cp "$TEMPLATES_DIR/CLAUDE.md" ./CLAUDE.md
cp "$TEMPLATES_DIR/HARNESS_PHILOSOPHY.md" ./HARNESS_PHILOSOPHY.md
cp -r "$TEMPLATES_DIR/.claude/commands" ./.claude/
cp -r "$TEMPLATES_DIR/.claude/knowledge" ./.claude/
# 复制 .claude/scripts/ 和 .claude/hooks/ 全目录（整目录拷贝避免硬编码列表漏拷）
# rsync --exclude 比 cp -r 更稳，能精准排除 __pycache__/；rsync 不在时退到 cp -r 后清理
mkdir -p .claude/scripts .claude/hooks
copy_template_dir() {
  local rel_dir="$1"
  local src="$TEMPLATES_DIR/$rel_dir"
  local dst="./$rel_dir"
  [ -d "$src" ] || return 0
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='__pycache__' --exclude='*.pyc' "$src/" "$dst/"
  else
    cp -r "$src/." "$dst/"
    find "$dst" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null
    find "$dst" -type f -name "*.pyc" -delete 2>/dev/null
  fi
  find "$dst" -type f \( -name "*.sh" -o -name "*.py" \) -exec chmod +x {} \;
}
copy_template_dir ".claude/scripts"
copy_template_dir ".claude/hooks"
# 复制 dbs.yaml.example（启动类→DB 映射模板）
cp "$TEMPLATES_DIR/.claude/dbs.yaml.example" ./.claude/dbs.yaml.example 2>/dev/null || true
# 复制 jenkins.yaml.example（Jenkins 构建编排模板）
cp "$TEMPLATES_DIR/.claude/jenkins.yaml.example" ./.claude/jenkins.yaml.example 2>/dev/null || true
# 复制 logs.yaml.example（远程日志查询配置模板）
cp "$TEMPLATES_DIR/.claude/logs.yaml.example" ./.claude/logs.yaml.example 2>/dev/null || true
# settings.json 合并 hook 注册（见下文 python merge）
if [ ! -f "./.claude/settings.json" ]; then
  cp "$TEMPLATES_DIR/.claude/settings.json" ./.claude/settings.json
else
  python3 - "$TEMPLATES_DIR/.claude/settings.json" "./.claude/settings.json" <<'PY'
import json, sys
tpl_path, dst_path = sys.argv[1:]
tpl = json.load(open(tpl_path))
try:
    dst = json.load(open(dst_path))
except Exception:
    dst = {}
dst.setdefault("hooks", {}).setdefault("PreToolUse", [])
existing = dst["hooks"]["PreToolUse"]
for new_entry in tpl.get("hooks", {}).get("PreToolUse", []):
    matcher = new_entry.get("matcher")
    if not any(e.get("matcher") == matcher for e in existing):
        existing.append(new_entry)
json.dump(dst, open(dst_path, "w"), indent=2, ensure_ascii=False)
PY
fi
# 复制 .mcp.json（含 github / tapd / jenkins 模板）
if [ ! -f ".mcp.json" ]; then
  cp "$TEMPLATES_DIR/.mcp.json" ./.mcp.json
fi
cp -r "$TEMPLATES_DIR/docs/." ./docs/

# 创建 /metrics 事件流目录骨架（/impl、/run-tasks、/adversarial-review 会往这里写 jsonl）
for sub in impl adversarial run-tasks knowledge-hits snapshots command-feedback; do
  mkdir -p "docs/workspace/.harness-metrics/$sub"
  touch "docs/workspace/.harness-metrics/$sub/.gitkeep"
done
mkdir -p docs/feedback/commands
touch docs/feedback/commands/.gitkeep

COMMAND_COUNT=$(find "$TEMPLATES_DIR/.claude/commands" -maxdepth 1 -name "*.md" | wc -l | tr -d ' ')
echo "  - CLAUDE.md 已就位"
echo "  - HARNESS_PHILOSOPHY.md 已就位（设计哲学，建议通读）"
echo "  - ${COMMAND_COUNT} 个命令文件已就位（.claude/commands/，含 /adversarial-review、/metrics、/dashboard、/command-feedback）"
echo "  - knowledge 分层已就位（.claude/knowledge/{backend,frontend,testing,red-lines.md}）"
echo "  - .claude/scripts/ 已就位（db-config / log-query / evaluator-marker 等，按需手跑）"
echo "  - .claude/dbs.yaml.example 已就位（启动类→DB 映射模板）"
echo "  - .claude/jenkins.yaml.example 已就位（Jenkins 构建编排模板）"
echo "  - .claude/logs.yaml.example 已就位（日志查询 target 模板）"
echo "  - .claude/hooks/ 已就位（db-readonly-guard / evaluator-context-guard 等 PreToolUse hook）"
echo "  - .claude/settings.json 已就位（hook 注册）"
echo "  - .mcp.json 已就位（github / tapd / jenkins 三个 MCP server）"
echo "  - docs/ 已就位（baseline / consensus / design / feedback / tasks / workspace，含 .gitkeep）"
echo "  - docs/workspace/.harness-metrics/ 事件流目录骨架已就位（/metrics 数据源）"
echo "  - docs/project.yaml 占位模板已就位"

# 全局：安装 /dashboard 聚合脚本 + 注册本项目
install_dashboard
PROJECT_NAME=$(basename "$CURRENT_DIR")
register_project "$PROJECT_NAME" "$CURRENT_DIR" "project-harness-template"
echo ""

# ----- Step 4: MCP 环境变量提示 -----
echo -e "${GREEN}[3/4] MCP 环境变量配置${NC}"
echo ""
echo -e "${YELLOW}请在 ~/.zshrc 或 ~/.bashrc 中添加（按需）：${NC}"
echo ""
echo '  export TAPD_ACCESS_TOKEN="xxx"         # TAPD 需求/Bug 读取'
echo '  export GITHUB_TOKEN="ghp_xxx"          # GitHub Issue/PR 读取'
echo '  export FIGMA_API_KEY="figd_xxx"        # 如使用 Figma'
echo '  export LANHU_TOKEN="xxx"               # 如使用蓝湖'
echo '  export JENKINS_URL="https://jenkins.your-company.com"  # 如使用 Jenkins 自动构建'
echo '  export JENKINS_USER="your-user"'
echo '  export JENKINS_API_TOKEN="xxx"          # Jenkins → User → Configure → API Token'
echo ""
echo -e "${YELLOW}TAPD MCP 依赖 uv（Python 工具运行器），如未安装请先执行：${NC}"
echo '  curl -LsSf https://astral.sh/uv/install.sh | sh'
echo ""

# ----- 数据库 MCP 配置（可选） -----
read -p "现在配置数据库 MCP（mysql/mongo + 可选 SSH 隧道）吗？(y/N): " DBNOW
if [ "$DBNOW" = "y" ] || [ "$DBNOW" = "Y" ]; then
  bash ./.claude/scripts/db-config.sh
else
  echo -e "${YELLOW}已跳过。需要时随时执行：${NC}"
  echo "  bash .claude/scripts/db-config.sh"
fi
echo ""

# ----- 完成 -----
echo -e "${GREEN}[4/4] 安装完成${NC}"
echo ""
echo "下一步："
echo "  1. 配置上述环境变量并 source"
echo "  2. 在项目仓库运行：claude"
echo "  3. 首次接入执行：/init-baseline \"你的产品简介\""
echo "     （会自动填充 knowledge 和 docs/project.yaml 的基线字段）"
echo "  4. 补充 docs/project.yaml 中 [人工] 标注的字段"
echo "  5. 提交：git add CLAUDE.md HARNESS_PHILOSOPHY.md .claude/ docs/ && git commit -m \"harness: init project harness\""
echo ""
echo "日常工作流："
echo "  - 日常任务：/impl \"{描述}\"（小任务全自动；大任务自动转 /iterate 产出 tasks.yaml）"
echo "  - PR / Sprint 合并前：【新开 session】/adversarial-review --branch feature/xxx"
echo "  - 每周 / Sprint 结束：/metrics --days 7 看首次通过率、Evaluator 分数、零命中 knowledge"
echo "  - 跨项目看板：/dashboard --open （所有注册项目的指标 + 对抗评估 + 时间线）"
echo "  - 踩到某条命令的坑：/command-feedback <命令名> \"<问题描述>\"（记录到 docs/feedback/commands/）"
echo "  - 批量升级所有注册项目：bash $TEMPLATES_DIR/upgrade-all.sh [--safe|--dry-run|--only NAME]"
echo ""
echo "想理解设计理念 → 读 HARNESS_PHILOSOPHY.md"
echo ""
