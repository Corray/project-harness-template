# Project Harness Template

> Claude Code 驱动的 AI 辅助开发 Harness，开箱即用。基于 Anthropic / OpenAI 2026 年 Harness Engineering 研究实现。

将分层 Knowledge、结构化工作流、会话记忆、机器可验证的完成标准、独立 Evaluator 对抗式评估和运行指标观测集成到任意项目仓库。开发者只需记住一个命令 `/impl`，AI 自动评估复杂度并执行——小任务全自动化，大任务结构化推进。

📖 想理解设计理念？先看 **[HARNESS_PHILOSOPHY.md](./HARNESS_PHILOSOPHY.md)**（为什么这么设计）。

## 快速开始

```bash
# 方式一：安装脚本（推荐）
cd your-project-repo
bash /path/to/project-harness-template/setup.sh

# 方式二：手动复制（注意：HARNESS_PHILOSOPHY.md 不分发到下游，留模板仓做单一真相源）
cp -r project-harness-template/.claude project-harness-template/CLAUDE.md project-harness-template/docs/ your-project-repo/
```

安装完成后：

```bash
cd your-project-repo
claude
/init-baseline "你的产品简介"
```

`/init-baseline` 会扫描项目生成基线文档、填充 knowledge 和 `docs/project.yaml`。之后补充 `project.yaml` 中 `[人工]` 标注的字段，提交即可。

首次 `setup.sh` 会同时：
- 把本项目注册到 `~/.claude/harness-projects.yaml`
- 把 `/dashboard` 聚合脚本安装到 `~/.claude/harness-dashboard/build.py`（跨项目共享）
- 创建 `docs/workspace/.harness-metrics/` 事件流骨架（`/metrics` 和 `/dashboard` 的数据源）

## 升级 / 批量维护

模板仓库更新后，同步到所有已接入项目有两种方式：

```bash
# 单项目升级（默认覆盖 + 自动 .bak 备份；--safe 改用 .new 旁注让你手动 diff）
cd your-project-repo
bash /path/to/project-harness-template/upgrade.sh [--safe]

# 一次性升级所有注册项目（读 ~/.claude/harness-projects.yaml 筛选 type: project-harness-template）
cd /path/to/project-harness-template
bash upgrade-all.sh --dry-run            # 先预览
bash upgrade-all.sh                      # 执行（默认覆盖 + 自动备份）
bash upgrade-all.sh --safe               # 改过的命令只生成 .new
bash upgrade-all.sh --only proj-alpha    # 只升级某个项目
```

`upgrade.sh` 只动命令文件和事件流目录，完全不碰你的 `CLAUDE.md` / `knowledge/` / `docs/baseline/` / `docs/design/` 等真实工作产物。`upgrade-all.sh` 单个项目失败不中断整体流程，最后给出成功/跳过/失败的汇总。

> **HARNESS_PHILOSOPHY.md 不分发到下游**——它是设计哲学的单一真相源，留在本模板仓维护即可。下游项目历史上若有遗留副本，`upgrade.sh` 会在结尾提示建议手动 `rm` 清理（不强删，避免误删本地修改）。

## 命令速查

日常只需记住 **`/impl "{描述}"`**：

```
/impl "修复 xxx"       → 小任务自动编码→测试→commit
/impl "新增 xxx 体系"  → 大任务自动转入 /iterate → /design → /run-tasks
```

| 命令 | 用途 | 触发方式 |
|------|------|---------|
| `/impl` | **唯一入口** — 自动评估复杂度并执行 | 手动 |
| `/iterate` | 大任务影响分析 + 任务清单（含 `tasks.yaml` 机器断言） | /impl 自动触发 |
| `/design` | 生成详细设计文档 | 手动 |
| `/run-tasks` | 批量循环执行 `tasks.yaml` 的验证断言；支持 **`--parallel N`** 并行 Worker（git worktree 隔离 + 按 `depends_on` 分波 + ff-only 拓扑序合并） | 手动 |
| `/init-baseline` | 首次接入，生成项目基线 | 手动（一次性） |
| `/review` | 结构化代码校验（Generator 自审） | /run-tasks 自动触发 |
| **`/adversarial-review`** | **独立 Evaluator 对抗式评估**（默认用 Task tool spawn 独立 subagent + hook 硬拦 journal/实现 knowledge；fallback `--new-session`）；关键路径用 **`--oracle`** 双 Evaluator strict-AND（两个都 Approve 才过，人格差异化避免盲区重叠）；`tasks.yaml` 缺失时自动降级 **no-contract** 模式（D 维度权重翻倍至 40 + 通用质量门 + 3 条 D 加强追问） | PR / Sprint 合并前手动 |
| `/test-gen` | 基于设计契约生成测试 | 手动 |
| `/preflight` | 提交前全面检查 | 手动 |
| **`/metrics`** | **Harness 运行指标聚合**（首次通过率、Evaluator 分数、knowledge 命中） | 每周 / sprint 结束手动 |
| **`/dashboard`** | **跨项目看板** — 一屏对比所有注册项目的指标、对抗评估、Knowledge 更新、命令反馈 | 随时手动（全局命令） |
| `/record-session` | 会话成果记录（journal + knowledge） | 自动触发 |
| `/spec-feedback` | 记录设计文档问题 | 手动 |
| **`/command-feedback`** | **记录对 slash 命令本身的修改建议**（`--collect` 可聚合跨项目反馈回 PR 模板仓库） | 踩到命令设计的坑时手动 |

## 核心机制

### 机器可验证的完成标准（`tasks.yaml`）

`/iterate` 生成任务清单时同时产出两份文件：
- `checklist.md`（人类视角）：打勾、讨论、交接用
- `tasks.yaml`（机器视角）：每个任务附带 `verify` 断言（`cmd` / `file_contains` / `http` / `sql` / `e2e` / `regression`），`/run-tasks` 和 `/adversarial-review` 实际执行

完成标准是合约，不是自觉——防止 *premature closure*（AI 过早宣称完成）。

### 独立 Evaluator 对抗式评估（`/adversarial-review`）

同一 agent 既写代码又审代码有偏见（self-rating bias）。本 harness 让 `/review`（Generator 自审）和 `/adversarial-review`（独立 Evaluator）分工：
- `/adversarial-review` 默认用 **Task tool spawn 独立 Evaluator subagent**（独立 context window），配合 `evaluator-context-guard.py` PreToolUse hook 在工具层硬拦 journal / backend / frontend knowledge 的访问；`--new-session` fallback 用于 Task tool 不可用或想再加一层物理隔离的场景
- 只看 design + diff + red-lines + tasks.yaml 的 verify
- 按四维度打分（功能性 30 / 代码质量 25 / 设计契合度 25 / 原创性 20），**不许满分**
- 断言失败或红线违反直接 Reject；Must-Fix 自动生成 `fix-tasks.yaml`

### Oracle 模式（`/adversarial-review --oracle`）

关键路径（支付 / 鉴权 / 资产 / schema 迁移）可启用 Oracle 双 Evaluator 模式：

```
/adversarial-review --branch feature/payment-refactor --oracle
```

- **3 个独立 session**：Evaluator-A（严格规范型，偏设计契合度 + 代码质量） + Evaluator-B（对抗反例型，偏原创性 + 边界条件） + Aggregator
- **Strict-AND 裁决**：两个 Evaluator 都 Approve 才算过；任一 Reject → 最终 Reject
- **人格差异化**：A/B 用不同系统提示切入点，让盲区错开（而不是同一 Evaluator 跑两遍）
- **分差 >15 标 disagreement**：不自动引入第三方（会退化为 2/3 majority），而是**请人亲眼看一眼**
- 也可通过 `project.yaml` 的 `oracle_paths` glob 自动在关键路径触发，或用 `--oracle-serial` 单 session 弱隔离模式
- `/dashboard` 会把 Oracle 记录单独建表，显示 A/B 各自打分 + disagreement badge + Reject override 详情

### 并行 Worker（`/run-tasks --parallel N`）

大 sprint 想夜里批处理？用并行 Worker：

```
/run-tasks backend --parallel 4 --max-parallel-fail 2
```

- **git worktree 隔离**：每个 Worker 一个 `.worktrees/{task.id}` 检出 + 独立分支，各自 `git add/commit` 不会互踩
- **按 `depends_on` 分波**：同波任务互不依赖，一波跑完再开下一波，保证"上游已合并才开下游"这个不变式
- **ff-only 拓扑序合并**：完成顺序 ≠ 合并顺序，按拓扑排序 ff-only 到集成分支，保持线性历史便于 `git revert` 单任务回滚
- **失败隔离**：`--max-parallel-fail K` 超阈值即熔断；依赖失败任务的下游自动 skip 并记账
- **冲突走自愈循环**：ff-only 失败必须修原因（设计/接口对齐），**禁止用 `--no-ff` 盖住**
- `/dashboard` 会显示 30 天并行波次数、调度成功率、合并冲突率、最近波次明细

### 运行指标观测（`/metrics`）

`docs/workspace/.harness-metrics/` 记录 `/impl`、`/adversarial-review`、`/run-tasks`、`/command-feedback` 的结构化事件流。`/metrics` 按时间窗口聚合，输出首次通过率、自愈轮次分布、Evaluator 平均分、Top 10 命中 / 零命中 knowledge、红线触发排行等——**用数字判断 harness 是不是在进步**。

### 跨项目看板（`/dashboard`）

首次跑 `setup.sh` 或 `upgrade.sh` 时，本项目会自动注册到 `~/.claude/harness-projects.yaml`，并安装全局的 `/dashboard` 聚合脚本。之后随时跑：

```
/dashboard --open
```

会生成单文件 HTML，一屏对比所有注册项目的四类数据：

- **指标 Tab**：30 天 impl 总数、首次通过率、平均自愈轮次、人工介入率 + 14 天趋势图
- **Knowledge Tab**：30 天命中 Top 15 / 零命中清单 + **最近 Knowledge 更新表**（git log 追踪的 A/M/D 和 impl 事件建议的 S=Suggested）
- **对抗评估 Tab**：`/adversarial-review` 历次打分和 Must-Fix 汇总
- **最近 impl Tab**：最近 50 条 impl + run-tasks 事件流
- **命令反馈 Tab**：`/command-feedback` 汇总，按 severity（blocker/painful/minor/nice-to-have）和命令分布

零外部依赖（纯 Python stdlib + CDN Chart.js），数据来源是每个注册项目的 `docs/workspace/.harness-metrics/` + `docs/feedback/commands/`。

### 命令反馈回路（`/command-feedback`）

当你踩到某条命令本身的坑（比如 `/impl` 的 Step 5 自愈逻辑不对）：

```
/command-feedback impl "Step 5 测试失败没进自愈直接退出"
```

会用 AskUserQuestion 问清触发场景/期望行为/严重性，写到 `docs/feedback/commands/impl-<ts>.md`（YAML frontmatter + 正文），同时打一条事件流供 `/dashboard` 展示。和 `/spec-feedback`（针对设计文档）互补——后者改 docs/design，前者改 `.claude/commands/*.md`。

在模板仓库跑 `/command-feedback --collect`，会扫所有注册项目的反馈，按命令聚合到 `~/.claude/command-feedback-inbox/{command}.md`，方便一次性 PR 回模板仓库。

### Knowledge 分层加载

`.claude/knowledge/` 按领域分目录，命令执行时按需加载，不浪费上下文窗口：

```
.claude/knowledge/
├── backend/          # DDD/MVC 架构、API 约定、sxp-framework
├── frontend/         # React+antd、Taro+Vant
├── testing/          # 测试标准和覆盖要求
└── red-lines.md      # 质量红线（通用）
```

### Workspace Journal

`docs/workspace/{developer}/journal.md` 是跨 session 的工作记忆——`/impl` 完成时自动追加，新 session 自动读取最近记录，无需重复解释上下文。

### Spec 自迭代

开发中发现 knowledge 未覆盖的技术点时，Claude 会在会话结束前建议更新对应的 knowledge 文件，将个人经验沉淀为团队资产。

### 需求来源

- **TAPD**：通过 MCP 读取需求卡片和 Bug 单
- **GitHub Issue**：通过 MCP 读取 Issue 及评论
- **手动输入**：直接描述需求

### 数据库 / Jenkins MCP（可选）

`.mcp.json` 包含 GitHub / TAPD / Jenkins 三个默认 MCP server。需要数据库测试或自动构建时：

- **数据库 MCP**：跑 `bash .claude/scripts/db-config.sh` 交互式新增 mysql/mongo server。每个 DB 实例独立配置（per-project），可选 SSH 隧道（每个 DB 独立选）。多启动类项目编辑 `.claude/dbs.yaml` 维护"启动类→DB"映射。
- **DB 强制只读**：`.claude/hooks/db-readonly-guard.py` 是 PreToolUse hook，所有 `mcp__mysql-*__*` 和 `mcp__mongo-*__*` 工具调用都会被拦截 —— MySQL 只放行 SELECT/SHOW/DESCRIBE/EXPLAIN，MongoDB 只放行 find/aggregate/count/distinct/list*，其他全 deny。**双层防护**：MCP 凭据本身也必须是只读账号（红线 22）。需要写测试时设 `test_db_strategy: docker` 走 docker-compose 起本地 DB。详见 `.claude/knowledge/testing/standards.md` 和 `red-lines.md` 第 22-25 条。
- **Jenkins**：在 `~/.zshrc` 配 `JENKINS_URL` / `JENKINS_USER` / `JENKINS_API_TOKEN` 即可。`/impl` Step 7 和 `/run-tasks` Step 7 完成后会询问"是否触发构建（默认 N）"，避免误触发生产部署。

## 文档结构

```
docs/
├── baseline/          # 项目基线（/init-baseline 生成）
├── consensus/         # 迭代共识文档（/iterate 生成）
├── design/            # 详细设计（/design 生成）
├── tasks/             # 任务追踪
│   └── {sprint}/
│       ├── iterate-consensus.md
│       ├── checklist.md      # 人类视角
│       ├── tasks.yaml        # 机器视角（verify 断言）
│       └── fix-tasks.yaml    # /adversarial-review Must-Fix 自动生成（可选）
├── feedback/          # 设计文档反馈
│   └── commands/      # /command-feedback 写入的命令反馈
├── workspace/
│   ├── {name}/journal.md          # 开发者工作日志（跨 session 记忆）
│   └── .harness-metrics/          # /metrics + /dashboard 数据源（结构化事件流）
│       ├── impl/                  # /impl 事件 jsonl
│       ├── adversarial/           # /adversarial-review 事件 jsonl
│       ├── run-tasks/             # /run-tasks 事件 jsonl
│       ├── knowledge-hits/        # knowledge 加载命中记录
│       └── command-feedback/      # /command-feedback 事件流
└── project.yaml       # 项目元信息
```

## 与 ai-workflow 的关系

```
ai-workflow（集中式）                 项目仓库（分散式）
├── 0-1 新项目共识文档                ├── /init-baseline 基线 + knowledge 初始化
├── 规则优化 eval/update-rules        ├── /iterate 迭代共识 + 任务清单
└── Knowledge 源文件                  ├── /design 详细设计（按需加载 knowledge）
                                      ├── /impl + /review（journal + spec 自迭代）
                                      ├── /test-gen + /preflight
                                      └── /record-session 会话记录
```

## 可选增强

### Code Review Graph

安装 [code-review-graph](https://github.com/tirth8205/code-review-graph) 后，`/iterate`、`/impl`、`/review` 等命令自动获得精确的代码结构分析（blast radius 计算、调用链追踪、风险评分），不可用时退回基线文档 + 代码扫描。

```bash
pip install code-review-graph
# 在 ~/.claude/settings.json 中配置 MCP
cd your-project && code-review-graph build
```

### 环境变量

按需配置以下环境变量以启用对应集成：

```bash
export TAPD_ACCESS_TOKEN="xxx"       # TAPD 需求/Bug
export GITHUB_TOKEN="ghp_xxx"        # GitHub Issue/PR
export FIGMA_API_KEY="figd_xxx"      # Figma 设计稿
```

## 模板内容

本仓库包含以下可安装到目标项目的文件：

```
project-harness-template/
├── CLAUDE.md                # AI 行为指令（项目级；setup/upgrade 会复制到下游）
├── HARNESS_PHILOSOPHY.md    # 设计哲学（为什么这么设计；只留模板仓，不分发）
├── setup.sh                 # 首次安装脚本（单项目）
├── upgrade.sh               # 升级脚本（单项目，带自动备份）
├── upgrade-all.sh           # 批量升级脚本（读注册表一次性升所有项目）
├── dashboard/
│   └── build.py             # /dashboard 聚合脚本（安装时复制到 ~/.claude/harness-dashboard/）
├── docs/
│   ├── project.yaml         # 项目元信息模板
│   └── */.gitkeep           # 目录骨架
└── .claude/
    ├── commands/                   # 14 个自定义命令
    │   ├── impl.md                 # 唯一任务入口
    │   ├── iterate.md              # 迭代影响分析 + tasks.yaml
    │   ├── design.md               # 详细设计
    │   ├── run-tasks.md            # 批量任务执行
    │   ├── init-baseline.md        # 基线初始化
    │   ├── review.md               # 代码校验（Generator 自审）
    │   ├── adversarial-review.md   # 独立 Evaluator 对抗式评估
    │   ├── test-gen.md             # 测试生成
    │   ├── preflight.md            # 提交前检查
    │   ├── metrics.md              # Harness 运行指标聚合
    │   ├── dashboard.md            # 跨项目看板（调用 ~/.claude/harness-dashboard/build.py）
    │   ├── record-session.md       # 会话记录
    │   ├── spec-feedback.md        # 设计文档反馈
    │   └── command-feedback.md     # 对 slash 命令本身的反馈（支持 --collect 跨项目聚合）
    └── knowledge/                  # 分层知识库模板
        ├── backend/                # 后端架构规范
        ├── frontend/               # 前端开发规范
        ├── testing/                # 测试标准
        └── red-lines.md            # 质量红线
```

## 相关阅读

- **[HARNESS_PHILOSOPHY.md](./HARNESS_PHILOSOPHY.md)** — 设计哲学（三条核心信念、Planner/Generator/Evaluator 角色模型、几个非显然的设计决定）
- Anthropic, *Effective harnesses for long-running agents* (2026)
- OpenAI, *GAN-style agent loops for code generation* (2026)
