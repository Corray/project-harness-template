# Project Harness

本项目已接入 project-harness-template 的 AI 辅助开发 Harness。所有命令、规则、约束、目录结构都遵循下文。

> 想了解"为什么这么设计"：看模板仓的 [HARNESS_PHILOSOPHY.md](https://github.com/Corray/project-harness-template/blob/main/HARNESS_PHILOSOPHY.md)（不分发到下游，单一真相源——避免下游副本随模板演化而漂移）。

## 任务入口：/impl

`/impl` 是唯一的任务入口——描述要做什么，AI 自动评估复杂度并执行：

```
/impl "{描述}"
  ├── 小任务 → 自动编码 → 测试 → 自愈 → commit（全自动）
  └── 大任务 → 自动转入 /iterate → 影响分析 → 任务清单 → /run-tasks
```

默认不暂停，只在环境问题、修不好、需要人操作时才打断。

**同 session 内发现问题**：直接对话说，不必再起 `/impl`——Claude 已有完整上下文。**新 session 继续上次工作**：用 `/impl "继续上次的 xxx"`，会自动读 journal 恢复上下文。

## 命令清单

| 命令 | 用途 | 谁触发 |
|------|------|--------|
| `/impl` | **唯一入口** — 描述任务，AI 自动评估复杂度并执行 | 开发者手动 |
| `/iterate` | 大任务的影响分析 + 任务清单生成 | 由 /impl 自动触发，或手动 |
| `/design` | 生成详细设计 | 由 /iterate 后手动触发 |
| `/run-tasks` | 批量循环执行 tasks.yaml；支持 `--parallel N` 并行 Worker（git worktree 隔离 + `depends_on` 分波 + ff-only 拓扑序合并） | 由 /iterate 后手动触发 |
| `/init-baseline` | 旧项目首次接入，生成基线 + 初始化 knowledge | 手动（一次性） |
| `/review` | 结构化代码校验（Generator 自审） | 由 /run-tasks 自动触发，或手动 |
| `/adversarial-review` | **独立 Evaluator** 对抗式评估（默认 Task tool spawn 独立 subagent + hook 硬拦 journal / 实现 knowledge；fallback `--new-session`）；`--oracle` 双 Evaluator strict-AND；`tasks.yaml` 缺失时自动降级 no-contract（D 权重 20→40） | 手动 |
| `/test-gen` | 基于设计契约单独生成测试 | 手动（/impl 已内置测试生成） |
| `/preflight` | 提交前全面检查 | 手动 |
| `/metrics` | Harness 运行指标聚合（首次通过率、Evaluator 分数、knowledge 命中等） | 手动（每周或 sprint 结束） |
| `/dashboard` | 跨项目看板 — 一屏看所有注册项目的指标 / 对抗评估 / Knowledge 命中 / 时间线 | 手动（随时） |
| `/record-session` | 会话记录（journal + knowledge + checklist） | 由 /impl 和 /run-tasks 自动触发 |
| `/spec-feedback` | 记录设计文档问题 | 手动 |
| `/command-feedback` | 记录对 slash 命令本身的修改建议（`--collect` 聚合跨项目反馈） | 手动 |

**典型工作流：**

```
小任务：       /impl "修复 xxx" → 全自动 → ✅
大任务：       /impl "新增 xxx 体系" → AI 判定大 → /iterate → /design → /run-tasks → ✅
已有 checklist：/run-tasks backend
夜跑批处理：    /run-tasks backend --parallel 4 → 同波 worktree 并行 → ff-only 按拓扑序合并
PR 合并前：    /adversarial-review --branch feature/xxx
关键路径双评审：/adversarial-review --branch feature/xxx --oracle  （支付/鉴权/资产/schema 迁移）
小任务也评审：  /adversarial-review --sprint ad-hoc/{YYYY-MM-DD}-{slug}
每周复盘：     /metrics --days 7  /  /dashboard --open
反馈命令本身：  /command-feedback impl "Step 5 没进自愈直接退出"
```

## 三角色模型（决定何时走哪条命令）

```
Planner（拆解任务）       Generator（落实代码）      Evaluator（挑毛病）
├── /iterate              ├── /impl                   ├── /review
├── /design               ├── /run-tasks              ├── /adversarial-review
└── /init-baseline                                    └── /preflight
```

**为什么分三个**：AI 对自己的输出有偏爱（self-rating bias）。让同一 agent 既写又审，会倾向于"我写的是对的"。所以：

- `/review` = Generator 自审（同 context，发现浅层问题）
- `/adversarial-review` = **独立 Evaluator**（subagent + `evaluator-context-guard` hook 在工具层硬拦 journal / 实现 knowledge 的 Read，默认怀疑，不许满分）

## 文档结构

```
docs/
├── baseline/              # 项目基线（/init-baseline 生成）
├── consensus/             # 迭代共识文档（/iterate 生成）
├── design/                # 详细设计（/design 生成）
├── tasks/                 # 任务追踪
│   ├── {sprint}/                     # 大任务：/iterate 产出
│   │   ├── iterate-consensus.md
│   │   ├── checklist.md              # 人类视角，可勾选
│   │   ├── tasks.yaml                # 机器视角，verify 断言
│   │   └── fix-tasks.yaml            # 可选：/adversarial-review Must-Fix
│   └── ad-hoc/{YYYY-MM-DD}-{slug}/   # 小任务：/impl 直走时自动
│       └── tasks.yaml
├── feedback/              # Spec 反馈
├── workspace/
│   ├── {developer-name}/journal-{YYYY-MM}.md   # 跨 session 工作日志（按月切片）
│   └── .harness-metrics/                       # 结构化事件流（/metrics 数据源）
└── project.yaml           # 项目元信息
```

## Knowledge 分层加载

`.claude/knowledge/` 按领域分目录，命令**按需加载**——只加载当前任务相关的部分，不浪费上下文窗口。

```
.claude/knowledge/
├── backend/{architecture,api-conventions,sxp-framework}.md
├── frontend/{react-patterns,taro-patterns}.md
├── testing/standards.md
├── collaboration.md          # 多 agent 并发共用工作区规范（识别信号 + 自检 + 隔离姿势）
└── red-lines.md              # 质量红线（所有角色通用）
```

**加载规则：**

| 命令 | 后端 | 前端 | 测试 |
|------|------|------|------|
| `/impl` | `backend/*` + `collaboration.md` + `red-lines.md` | `frontend/*` + 同 | `testing/*` + 同 |
| `/review` | `backend/*` + `collaboration.md` + `red-lines.md` | `frontend/*` + 同 | — |
| `/design` | `backend/*` + `red-lines.md` | `frontend/*` + 同 | `testing/*` + 同 |
| `/preflight` / `/run-tasks` | `collaboration.md` + `red-lines.md` | 同 | 同 |
| `/adversarial-review` | **仅** `red-lines.md` + design + diff + tasks.yaml | 同 | 同 |

**为什么 `collaboration.md` 多个命令都加载？** 描述的是"多 agent / 多窗口并发共用工作区"时的识别信号和应急规范，所有**直接操作工作区**的命令（写代码 / 校验 / 批量执行 / 提交前检查）都可能触发。`/design` 和 `/adversarial-review` 不直接动工作区，所以不加载。

**为什么 `/adversarial-review` 加载特别窄？** 它是独立 Evaluator，加载 backend / frontend 的 knowledge 反而会让它"帮 Generator 找理由过稿"。

无法自动判断当前任务栈类型时，询问开发者。

## 需求来源

- **TAPD**：通过 TAPD MCP 读取需求卡片和 Bug 单
- **GitHub Issue**：通过 GitHub MCP 读取 Issue 及评论
- **手动输入**：开发者直接描述需求

## MCP 配置

见 `.mcp.json`：

- **GitHub MCP** — 读取 Issue、PR
- **TAPD MCP** — 读取需求卡片（如使用 TAPD）
- **Jenkins MCP** — `/impl` Step 7、`/run-tasks` Step 7 询问后可选触发构建（默认 N）；多 Freestyle job 串行编排见 `.claude/jenkins.yaml.example`；deploy 阶段默认 `wait: false`（红线 26）
- **MySQL / MongoDB MCP**（可选）— 真实数据库测试。每实例对应一个独立 server（`mysql-{name}` / `mongo-{name}`），用 `bash .claude/scripts/db-config.sh` 维护，**不要手改 .mcp.json**

### DB 强制只读（双层防护）

`.claude/hooks/db-readonly-guard.py` 是 PreToolUse hook，匹配所有 `mcp__mysql-*__*` 和 `mcp__mongo-*__*`：MySQL 只放行 SELECT/SHOW/DESCRIBE/EXPLAIN/WITH，MongoDB 只放行 find/aggregate/count/distinct/list_collections 等只读方法，其他全 deny。**第二层**：`.mcp.json` 引用的账号也必须是只读账号（red-lines.md 第 22-25 条）。

需要写测试时设 `test_db_strategy: docker` 走 docker-compose 起本地 DB。多启动类项目编辑 `.claude/dbs.yaml` 维护"启动类→DB"映射，详见 `.claude/knowledge/testing/standards.md`。

DB MCP 配置 / SSH 隧道 / 后台服务安装等运维操作，跑 `bash .claude/scripts/db-config.sh`（脚本自身有 `--list` / `--remove` 等子命令）。

## 远程日志查询

排查线上问题用 `.claude/scripts/log-query.py`（**只读**，paramiko + 用户名密码鉴权）。配置见 `.claude/logs.yaml.example`，密码通过 env var **间接引用**（`logs.yaml` 只存 env var 名字，实际密码在 `~/.zshrc`，logs.yaml 可 commit）。

脚本只构造 `tail/grep/cat/zcat/ls` 这类 read-only 命令，path/pattern 走白名单防注入。详细 flag 见 `python3 .claude/scripts/log-query.py --help`。

## Workspace Journal（跨 session 记忆）

`docs/workspace/{developer-name}/journal-{YYYY-MM}.md`：
- `/impl` 完成时自动追加（按月切片避免单文件膨胀）
- 新 session 的 `/impl` Step 1 自动读最近 5 条（按月倒序：当月末尾 → 上月末尾）
- append-only，每个开发者独立

首次使用告诉 Claude 你的名字，自动创建对应目录。

## Spec 自迭代（Knowledge 默认追加）

`/impl` 在会话结束时**默认自动追加**新发现的技术点到对应 knowledge 文件的"自动追加区"——不停下问，每次变更独立 commit，开发者通过 `git log -- .claude/knowledge/` 事后审查，必要时 `git revert`。

追加判定 / 冲突保守化（grep 命中既有标题就停下问）/ `red-lines.md` 永不自动追加 等机械规则详见 `.claude/commands/impl.md` Step 6.2。

显式关闭：`/impl --no-knowledge-update "..."`。

## Code Review Graph（可选增强）

如果配置了 [code-review-graph](https://github.com/tirth8205/code-review-graph) MCP，以下命令应**优先使用 graph** 而不是直接扫描代码：

| 命令 | graph 工具（带 MCP 前缀） |
|------|--------------------------|
| `/iterate` 影响分析 | `mcp__Code-review-gragh__get_impact_radius_tool` 精确 blast radius |
| `/iterate` 风险评估 | `mcp__Code-review-gragh__detect_changes_tool` 风险评分 |
| `/impl` Step 1 侦察 | `mcp__Code-review-gragh__query_graph_tool` 查调用关系、依赖、测试覆盖 |
| `/impl` Step 4.4 回归 | `mcp__Code-review-gragh__get_impact_radius_tool` 只跑受影响测试，不全量回归 |
| `/review` 校验范围 | `mcp__Code-review-gragh__detect_changes_tool` 风险评分 + 受影响但未改文件 |
| `/init-baseline` 架构 | `mcp__Code-review-gragh__get_architecture_overview_tool` 精确架构图 |

### 工具命名约定（重要）

- **MCP server 名是 `Code-review-gragh`**（"gragh" 不是笔误，是上游 server 的实际拼写——参见 [tirth8205/code-review-graph](https://github.com/tirth8205/code-review-graph)）
- 所有 graph 工具**必须**带 `mcp__Code-review-gragh__` 前缀调用，例如 `mcp__Code-review-gragh__query_graph_tool`
- 直接调用裸名（如 `query_graph_tool`）会因工具列表里没有该名字而失败，触发不必要的 fallback

### 使用规则（强制）

每个上表里的命令在进入扫描代码 / 读基线之前，**必须先做主动探针**：

1. **探针**：调用 `mcp__Code-review-gragh__list_repos_tool`（返回当前 graph 中已索引的仓库列表）
2. **判定**：
   - 探针**返回非空且包含当前项目** → 视为可用，**优先用 graph 工具**采集数据，**再**结合 knowledge 和基线
   - 探针成功但**当前项目不在列表** → 提示开发者需要先 `code-review-graph build`，本次降级到代码扫描
   - 探针失败（工具不存在 / 调用报错） → 静默降级到代码扫描，**不报错**
3. **冲突仲裁**：graph 数据和基线文档冲突时**以 graph 为准**（graph 实时计算，基线可能过时）

**为什么强制探针**："如果可用就用"是 opt-in 措辞，Claude 实际不会主动验证可用性，导致 graph 装了但永远走不到——硬性要求先调一次探针才能避免。探针成本极低（一次工具调用），但能让 graph 真正发挥作用。

安装步骤见模板仓 README 的「Code Review Graph」章节。

## 关键原则

- **完成标准是合约**：`tasks.yaml` 的 `verify` 断言必须全绿才算做完（防 *premature closure*）。大任务由 `/iterate` 产出；小任务走 /impl 直达时自动写 `docs/tasks/ad-hoc/{date}-{slug}/tasks.yaml`——两条路径都有客观判据
- **红线违反直接 Reject**：`/review`、`/adversarial-review`、`/preflight` 的红线检查是强制关卡，不是建议
- **独立 Evaluator 对抗自迭代**：同一 agent 既写既审有偏见。`/adversarial-review` 默认 spawn 独立 subagent + `evaluator-context-guard` hook 硬拦 journal / 实现 knowledge
- **并行不破坏依赖**：`/run-tasks --parallel N` 按 `depends_on` 分波，同波各自 worktree，合并严格 ff-only 拓扑序（冲突走自愈循环，不允许 `--no-ff` 盖住）
- **Knowledge 持续进化 + 靠数字决策**：开发中沉淀新知识；定期跑 `/metrics` 看首次通过率、Evaluator 分数、零命中 knowledge——不靠感觉判断 harness 有没有进步
