#!/usr/bin/env bash
#
# Project Harness Template 升级脚本（2026-04 新增 /adversarial-review、/metrics、tasks.yaml）
#
# 用法：
#   1. 进入已安装 harness 的项目根目录（必须已有 .claude/commands/ 和 CLAUDE.md）
#   2. 运行：bash /path/to/project-harness-template/upgrade.sh [--safe]
#
# 默认行为（直接覆盖 + 自动备份）：
#   - 新文件、新目录：直接添加（已存在则跳过）
#   - 已有但内容变更的命令文件（impl.md / iterate.md / run-tasks.md / review.md）
#     → 先备份为 {name}.bak.{timestamp}，然后覆盖为新版
#   - 完全不动 CLAUDE.md / HARNESS_PHILOSOPHY.md（如存在）/ knowledge/ / project.yaml /
#     docs/baseline / docs/design 等你的真实工作产物
#   - 想回滚某个命令：mv {name}.bak.{timestamp} {name}
#
# --safe 模式（保守，适合你自己改过命令文件的情况）：
#   - 已有且内容变更的命令文件生成 {name}.new 旁注，由你 diff 合并
#
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

CURRENT_DIR=$(pwd)
TEMPLATES_DIR="$(cd "$(dirname "$0")" && pwd)"
FORCE_REPLACE=1   # 默认直接覆盖（带自动备份）
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

for arg in "$@"; do
  case "$arg" in
    --safe) FORCE_REPLACE=0 ;;
    --force-replace) FORCE_REPLACE=1 ;;  # 兼容旧参数
    -h|--help)
      head -20 "$0" | sed 's/^# //; s/^#$//'
      exit 0
      ;;
  esac
done

echo -e "${GREEN}=== Project Harness Template 升级脚本 ===${NC}"
echo ""

# ----- 前置检查 -----
if [ ! -d ".git" ]; then
  echo -e "${RED}错误：当前目录不是 Git 仓库${NC}"
  exit 1
fi

if [ ! -d "./.claude/commands" ] || [ ! -f "./CLAUDE.md" ]; then
  echo -e "${RED}错误：看起来这个项目还没安装 harness${NC}"
  echo "请改用首次安装脚本：bash $TEMPLATES_DIR/setup.sh"
  exit 1
fi

if [ "$CURRENT_DIR" = "$TEMPLATES_DIR" ]; then
  echo -e "${RED}错误：不能在模板目录本身运行${NC}"
  exit 1
fi

# ----- Git 清洁检查 -----
if [ -n "$(git status --porcelain)" ]; then
  echo -e "${YELLOW}⚠️  检测到未提交改动。建议先 commit/stash 再升级，便于回滚。${NC}"
  read -p "继续？(y/N): " C
  [ "$C" != "y" ] && [ "$C" != "Y" ] && exit 0
  echo ""
fi

echo -e "${GREEN}[1/4] 目标项目：${CURRENT_DIR}${NC}"
if [ $FORCE_REPLACE -eq 1 ]; then
  echo -e "${YELLOW}  模式：覆盖（改过的命令文件会被备份为 .bak.${TIMESTAMP}）${NC}"
else
  echo -e "${YELLOW}  模式：--safe（改过的命令文件只生成 .new 不覆盖）${NC}"
fi
echo ""

# ----- 工具函数 -----
ADDED=()
SKIPPED=()
UPDATED=()
BACKED_UP=()
NEW_SIDECAR=()

# 只在目标不存在时复制
copy_if_missing() {
  local src="$1"
  local dst="$2"
  if [ ! -e "$dst" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    ADDED+=("$dst")
  else
    SKIPPED+=("$dst（已存在，保留原文件）")
  fi
}

# 命令文件：默认直接覆盖（带 .bak.{timestamp} 备份）；--safe 时生成 .new 旁注
copy_command() {
  local src="$1"
  local dst="$2"
  if [ ! -e "$dst" ]; then
    cp "$src" "$dst"
    ADDED+=("$dst")
  elif [ $FORCE_REPLACE -eq 1 ]; then
    if ! cmp -s "$src" "$dst"; then
      # 先备份旧版本再覆盖
      cp "$dst" "${dst}.bak.${TIMESTAMP}"
      BACKED_UP+=("${dst}.bak.${TIMESTAMP}")
      cp "$src" "$dst"
      UPDATED+=("$dst")
    else
      SKIPPED+=("$dst（内容相同）")
    fi
  else
    if ! cmp -s "$src" "$dst"; then
      cp "$src" "${dst}.new"
      NEW_SIDECAR+=("${dst}.new（请 diff 对比后手动合并）")
    else
      SKIPPED+=("$dst（内容相同）")
    fi
  fi
}

# ----- Step 1: 新文件：HARNESS_PHILOSOPHY.md -----
echo -e "${GREEN}[2/4] 添加新文件${NC}"
copy_if_missing "$TEMPLATES_DIR/HARNESS_PHILOSOPHY.md" "./HARNESS_PHILOSOPHY.md"

# ----- Step 2: 命令文件 -----
# 新增命令：adversarial-review.md, metrics.md, dashboard.md — copy_if_missing 足矣
# 已有命令但我们改过：iterate.md, impl.md, run-tasks.md, review.md — 用 copy_command
for cmd_file in "$TEMPLATES_DIR/.claude/commands/"*.md; do
  name=$(basename "$cmd_file")
  dst=".claude/commands/$name"
  case "$name" in
    adversarial-review.md|metrics.md|dashboard.md|command-feedback.md)
      copy_if_missing "$cmd_file" "$dst"
      ;;
    impl.md|iterate.md|run-tasks.md|review.md)
      copy_command "$cmd_file" "$dst"
      ;;
    *)
      # 其他命令不动，保留用户现状
      SKIPPED+=(".claude/commands/$name（不在升级范围）")
      ;;
  esac
done

# ----- Step 3: 事件流目录 -----
echo ""
echo -e "${GREEN}[3/4] 创建事件流目录（/metrics 数据源）${NC}"
for sub in impl adversarial run-tasks knowledge-hits snapshots command-feedback; do
  dir="docs/workspace/.harness-metrics/$sub"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    touch "$dir/.gitkeep"
    ADDED+=("$dir/")
  else
    SKIPPED+=("$dir/（已存在）")
  fi
done

# ----- Step 3.5: 安装 /dashboard 脚本 + 注册本项目 -----
echo ""
echo -e "${GREEN}[3.5/4] 安装 /dashboard 看板 + 注册本项目${NC}"

# 聚合脚本（全局共享，装到 ~/.claude/harness-dashboard/）
if [ -f "$TEMPLATES_DIR/dashboard/build.py" ]; then
  mkdir -p "$HOME/.claude/harness-dashboard"
  if [ ! -f "$HOME/.claude/harness-dashboard/build.py" ] || ! cmp -s "$TEMPLATES_DIR/dashboard/build.py" "$HOME/.claude/harness-dashboard/build.py"; then
    cp "$TEMPLATES_DIR/dashboard/build.py" "$HOME/.claude/harness-dashboard/build.py"
    ADDED+=("~/.claude/harness-dashboard/build.py")
  else
    SKIPPED+=("~/.claude/harness-dashboard/build.py（内容相同）")
  fi
fi

# 注册本项目
HARNESS_YAML="$HOME/.claude/harness-projects.yaml"
if [ ! -f "$HARNESS_YAML" ]; then
  cat > "$HARNESS_YAML" <<YAML
version: 1
projects:
YAML
fi
PROJECT_NAME=$(basename "$CURRENT_DIR")
TODAY=$(date +%Y-%m-%d)
if grep -F -q "    path: $CURRENT_DIR" "$HARNESS_YAML" 2>/dev/null; then
  SKIPPED+=("~/.claude/harness-projects.yaml（本项目已注册）")
else
  cat >> "$HARNESS_YAML" <<YAML
  - name: $PROJECT_NAME
    path: $CURRENT_DIR
    type: project-harness-template
    registered_at: $TODAY
YAML
  ADDED+=("~/.claude/harness-projects.yaml（注册 $PROJECT_NAME）")
fi

# ----- Step 4: 汇总报告 -----
echo ""
echo -e "${GREEN}[4/4] 升级结果${NC}"
echo ""

if [ ${#ADDED[@]} -gt 0 ]; then
  echo -e "${GREEN}✅ 新增（${#ADDED[@]}）：${NC}"
  for f in "${ADDED[@]}"; do echo "  + $f"; done
  echo ""
fi

if [ ${#UPDATED[@]} -gt 0 ]; then
  echo -e "${BLUE}🔁 覆盖更新（${#UPDATED[@]}）：${NC}"
  for f in "${UPDATED[@]}"; do echo "  ~ $f"; done
  echo ""
fi

if [ ${#BACKED_UP[@]} -gt 0 ]; then
  echo -e "${BLUE}📦 旧版本已备份（${#BACKED_UP[@]}）：${NC}"
  for f in "${BACKED_UP[@]}"; do echo "  · $f"; done
  echo ""
  echo -e "${BLUE}  回滚单个文件：mv <文件>.bak.${TIMESTAMP} <文件>${NC}"
  echo -e "${BLUE}  确认无问题后清理：find .claude/commands -name '*.bak.*' -delete${NC}"
  echo ""
fi

if [ ${#NEW_SIDECAR[@]} -gt 0 ]; then
  echo -e "${YELLOW}⚠️  待手动合并（${#NEW_SIDECAR[@]}）：${NC}"
  for f in "${NEW_SIDECAR[@]}"; do echo "  ? $f"; done
  echo ""
  echo -e "${YELLOW}对比命令：${NC}"
  for f in "${NEW_SIDECAR[@]}"; do
    orig="${f%.new*}"
    [[ "$f" == *"$orig.new"* ]] && echo "  diff $orig $orig.new"
  done | head -5
  [ ${#NEW_SIDECAR[@]} -gt 5 ] && echo "  ..."
  echo ""
  echo "  确认无冲突后用 \`mv <file>.new <file>\` 替换；"
  echo "  或下次升级去掉 --safe 直接覆盖（会自动备份）。"
  echo ""
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo -e "保留未动（${#SKIPPED[@]}）：主要是 knowledge/、CLAUDE.md、已存在的目录等"
  echo ""
fi

# ----- 提醒 -----
cat <<EOF
${BLUE}下一步建议：${NC}
  1. 通读新增的 HARNESS_PHILOSOPHY.md 理解 /adversarial-review、/metrics、/dashboard 的设计意图
  2. 如有 .new 文件，逐个 diff 后合并（或去掉 --safe 让脚本自动覆盖 + 备份）
  3. 可能需要手动更新的内容（本脚本不会自动动）：
     - CLAUDE.md：参考模板版加上 /adversarial-review、/metrics、/dashboard 到命令表
     - 已有 sprint 的 checklist.md 如需配合新流程，建议重新跑一次 /iterate --refresh-checklist 生成 tasks.yaml
  4. 提交：git add -A && git commit -m "harness: upgrade to 2026-04 (adversarial-review + metrics + dashboard + tasks.yaml)"

${BLUE}验证安装：${NC}
  在项目里打开 Claude Code：
  - 项目内应看到 /adversarial-review、/metrics、/dashboard
  - 随时用 /dashboard --open 打开跨项目看板（所有注册项目的指标一屏汇总）
EOF
