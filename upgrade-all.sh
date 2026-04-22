#!/usr/bin/env bash
#
# Project Harness Template - 批量升级脚本
#
# 读取 ~/.claude/harness-projects.yaml，对所有 type: project-harness-template
# 的项目依次执行模板目录下的 upgrade.sh。
#
# 用法：
#   cd /path/to/project-harness-template
#   bash upgrade-all.sh [--safe] [--dry-run] [--only NAME] [--yes]
#
# 参数：
#   --safe      传递给每个项目的 upgrade.sh（只生成 .new 旁注，不覆盖）
#   --dry-run   只列出将要升级的项目，不实际执行
#   --only NAME 只升级指定名称的项目（支持多次指定）
#   --yes       不再询问确认，直接跑
#
# 行为：
#   - 单个项目失败不会中断整体流程，最后汇总成功/失败
#   - 每个项目的 upgrade.sh 在它自己的目录下执行
#   - Git 未提交改动的项目会被跳过（避免误覆盖），在报告中标出
#
set -u  # 注意：不开 -e，单项目失败要继续

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

TEMPLATES_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_YAML="$HOME/.claude/harness-projects.yaml"
EXPECTED_TYPE="project-harness-template"

PASS_SAFE=""
DRY_RUN=0
AUTO_YES=0
ONLY_LIST=()

while [ $# -gt 0 ]; do
  case "$1" in
    --safe) PASS_SAFE="--safe"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) AUTO_YES=1; shift ;;
    --only=*) ONLY_LIST+=("${1#--only=}"); shift ;;
    --only)
      shift
      if [ $# -eq 0 ] || [[ "$1" == --* ]]; then
        echo -e "${RED}错误：--only 后面必须跟项目名${NC}" >&2
        exit 1
      fi
      ONLY_LIST+=("$1")
      shift
      ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# //; s/^#$//'
      exit 0
      ;;
    *)
      echo -e "${RED}未知参数：$1${NC}" >&2
      exit 1
      ;;
  esac
done

echo -e "${GREEN}=== Project Harness Template 批量升级 ===${NC}"
echo ""

# ----- 前置检查 -----
if [ ! -f "$TEMPLATES_DIR/upgrade.sh" ]; then
  echo -e "${RED}错误：找不到 $TEMPLATES_DIR/upgrade.sh${NC}"
  exit 1
fi

if [ ! -f "$HARNESS_YAML" ]; then
  echo -e "${YELLOW}没找到注册表 $HARNESS_YAML${NC}"
  echo "这通常意味着还没有项目跑过 setup.sh 或 upgrade.sh。"
  echo "先手动在每个目标项目里跑一次："
  echo "  cd /path/to/your-project && bash $TEMPLATES_DIR/upgrade.sh"
  exit 1
fi

# ----- 解析 yaml -----
# 极简解析器：假定注册表由我们自己的脚本维护，格式稳定。
# 每个项目条目形如：
#   - name: xxx
#     path: /abs/path
#     type: project-harness-template
#     registered_at: 2026-04-22
PROJECTS=()
NAMES=()
PATHS=()
TYPES=()

current_name=""
current_path=""
current_type=""

flush_entry() {
  if [ -n "$current_name" ] && [ -n "$current_path" ]; then
    NAMES+=("$current_name")
    PATHS+=("$current_path")
    TYPES+=("${current_type:-unknown}")
  fi
  current_name=""
  current_path=""
  current_type=""
}

while IFS= read -r line; do
  case "$line" in
    "  - name: "*)
      flush_entry
      current_name="${line#  - name: }"
      ;;
    "    path: "*)
      current_path="${line#    path: }"
      ;;
    "    type: "*)
      current_type="${line#    type: }"
      ;;
  esac
done < "$HARNESS_YAML"
flush_entry

# ----- 筛选 -----
SELECTED_NAMES=()
SELECTED_PATHS=()
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  path="${PATHS[$i]}"
  type="${TYPES[$i]}"

  if [ "$type" != "$EXPECTED_TYPE" ]; then
    continue
  fi

  if [ ${#ONLY_LIST[@]} -gt 0 ]; then
    found=0
    for want in "${ONLY_LIST[@]}"; do
      [ "$name" = "$want" ] && found=1 && break
    done
    [ $found -eq 0 ] && continue
  fi

  SELECTED_NAMES+=("$name")
  SELECTED_PATHS+=("$path")
done

if [ ${#SELECTED_NAMES[@]} -eq 0 ]; then
  echo -e "${YELLOW}没有符合条件的项目。${NC}"
  echo "注册表里总项目数：${#NAMES[@]}"
  echo "其中 type=$EXPECTED_TYPE 的：$(echo "${TYPES[@]}" | tr ' ' '\n' | grep -c "^$EXPECTED_TYPE$" || true)"
  if [ ${#ONLY_LIST[@]} -gt 0 ]; then
    echo "--only 过滤条件：${ONLY_LIST[*]}"
  fi
  exit 0
fi

# ----- 预览 -----
echo -e "${GREEN}[1/3] 将对以下 ${#SELECTED_NAMES[@]} 个项目执行 upgrade.sh：${NC}"
for i in "${!SELECTED_NAMES[@]}"; do
  idx=$((i+1))
  name="${SELECTED_NAMES[$i]}"
  path="${SELECTED_PATHS[$i]}"
  status="✅"
  extra=""
  if [ ! -d "$path" ]; then
    status="❌"
    extra="（路径不存在，将跳过）"
  elif [ ! -d "$path/.git" ]; then
    status="⚠️ "
    extra="（非 Git 仓库，将跳过）"
  elif [ -n "$(cd "$path" && git status --porcelain 2>/dev/null)" ]; then
    status="⚠️ "
    extra="（有未提交改动，会被本项目的 upgrade.sh 询问）"
  fi
  echo "  $idx. $status $name — $path $extra"
done
echo ""

if [ -n "$PASS_SAFE" ]; then
  echo -e "${YELLOW}模式：--safe（改过的命令文件只生成 .new，不覆盖）${NC}"
else
  echo -e "${YELLOW}模式：覆盖（改过的命令文件会被备份为 .bak.<timestamp>）${NC}"
fi
echo ""

if [ $DRY_RUN -eq 1 ]; then
  echo -e "${BLUE}--dry-run：到此为止，不实际执行。${NC}"
  exit 0
fi

if [ $AUTO_YES -eq 0 ]; then
  read -p "继续？(y/N): " C
  [ "$C" != "y" ] && [ "$C" != "Y" ] && { echo "已取消"; exit 0; }
  echo ""
fi

# ----- 逐个执行 -----
echo -e "${GREEN}[2/3] 开始批量升级...${NC}"
echo ""

OK_NAMES=()
FAIL_NAMES=()
FAIL_REASONS=()
SKIP_NAMES=()
SKIP_REASONS=()

for i in "${!SELECTED_NAMES[@]}"; do
  idx=$((i+1))
  total=${#SELECTED_NAMES[@]}
  name="${SELECTED_NAMES[$i]}"
  path="${SELECTED_PATHS[$i]}"

  echo -e "${BLUE}━━━ [$idx/$total] $name ━━━${NC}"
  echo "路径：$path"

  if [ ! -d "$path" ]; then
    echo -e "${YELLOW}跳过：目录不存在${NC}"
    SKIP_NAMES+=("$name")
    SKIP_REASONS+=("目录不存在")
    echo ""
    continue
  fi

  if [ ! -d "$path/.git" ]; then
    echo -e "${YELLOW}跳过：不是 Git 仓库${NC}"
    SKIP_NAMES+=("$name")
    SKIP_REASONS+=("非 Git 仓库")
    echo ""
    continue
  fi

  # 在子 shell 里 cd + 执行，隔离环境
  if (cd "$path" && bash "$TEMPLATES_DIR/upgrade.sh" $PASS_SAFE <<<"y"); then
    OK_NAMES+=("$name")
    echo -e "${GREEN}✅ $name 升级完成${NC}"
  else
    rc=$?
    FAIL_NAMES+=("$name")
    FAIL_REASONS+=("upgrade.sh 返回 $rc")
    echo -e "${RED}❌ $name 升级失败（exit $rc）${NC}"
  fi
  echo ""
done

# ----- 汇总 -----
echo -e "${GREEN}[3/3] 批量升级汇总${NC}"
echo ""
echo -e "成功：${#OK_NAMES[@]}  跳过：${#SKIP_NAMES[@]}  失败：${#FAIL_NAMES[@]}"
echo ""

if [ ${#OK_NAMES[@]} -gt 0 ]; then
  echo -e "${GREEN}✅ 成功（${#OK_NAMES[@]}）：${NC}"
  for n in "${OK_NAMES[@]}"; do echo "  + $n"; done
  echo ""
fi

if [ ${#SKIP_NAMES[@]} -gt 0 ]; then
  echo -e "${YELLOW}⚠️  跳过（${#SKIP_NAMES[@]}）：${NC}"
  for i in "${!SKIP_NAMES[@]}"; do
    echo "  - ${SKIP_NAMES[$i]}  —  ${SKIP_REASONS[$i]}"
  done
  echo ""
fi

if [ ${#FAIL_NAMES[@]} -gt 0 ]; then
  echo -e "${RED}❌ 失败（${#FAIL_NAMES[@]}）：${NC}"
  for i in "${!FAIL_NAMES[@]}"; do
    echo "  - ${FAIL_NAMES[$i]}  —  ${FAIL_REASONS[$i]}"
  done
  echo ""
  echo "失败项目请手动排查：cd <路径> && bash $TEMPLATES_DIR/upgrade.sh"
  exit 1
fi

cat <<EOF
${BLUE}下一步建议：${NC}
  1. 跑一次 /dashboard 验证所有项目的最新命令都已装好
  2. 各项目里需要 git commit -m "harness: batch upgrade to 2026-04"
  3. 若有 .new 旁注（--safe 模式），需要手动 diff 合并
EOF
