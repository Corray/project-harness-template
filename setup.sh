#!/usr/bin/env bash
#
# Project Harness Template 安装脚本
# 用法：
#   1. 进入要接入的项目目录（必须是 Git 仓库）
#   2. 运行：bash /path/to/project-harness-template/setup.sh
#
# 安装内容：
# - 根目录 CLAUDE.md
# - .claude/commands/（10 个命令）
# - .claude/knowledge/（backend / frontend / testing / red-lines.md）
# - docs/ 目录骨架（baseline / consensus / design / feedback / tasks / workspace）
# - docs/project.yaml 占位模板（由 /init-baseline 填充）
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

# ----- Step 2: 覆盖确认 -----
CONFLICTS=()
[ -f "./CLAUDE.md" ] && CONFLICTS+=("CLAUDE.md")
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
cp -r "$TEMPLATES_DIR/.claude/commands" ./.claude/
cp -r "$TEMPLATES_DIR/.claude/knowledge" ./.claude/
cp -r "$TEMPLATES_DIR/docs/." ./docs/

COMMAND_COUNT=$(find "$TEMPLATES_DIR/.claude/commands" -maxdepth 1 -name "*.md" | wc -l | tr -d ' ')
echo "  - CLAUDE.md 已就位"
echo "  - ${COMMAND_COUNT} 个命令文件已就位（.claude/commands/）"
echo "  - knowledge 分层已就位（.claude/knowledge/{backend,frontend,testing,red-lines.md}）"
echo "  - docs/ 已就位（baseline / consensus / design / feedback / tasks / workspace，含 .gitkeep）"
echo "  - docs/project.yaml 占位模板已就位"
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
echo ""
echo -e "${YELLOW}TAPD MCP 依赖 uv（Python 工具运行器），如未安装请先执行：${NC}"
echo '  curl -LsSf https://astral.sh/uv/install.sh | sh'
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
echo "  5. 提交：git add CLAUDE.md .claude/ docs/ && git commit -m \"harness: init project harness\""
echo ""
