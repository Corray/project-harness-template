# Project Harness

## 这个配置是什么

这是项目仓库的 AI 辅助开发 Harness。通过 Claude Code 的自定义命令，将项目基线管理、迭代分析、详细设计、编码实现、代码校验、测试生成、对抗式评估和经验沉淀结构化。

**读这个仓库前先看：[HARNESS_PHILOSOPHY.md](./HARNESS_PHILOSOPHY.md)** —— 它解释"为什么这么设计"，帮助你判断哪些规则可以改、哪些是骨架。

## 日常使用

**`/impl` 是唯一的任务入口。** 不需要判断该用哪个命令——描述你要做什么，AI 自动决定走哪条路：

```
/impl "{描述}"
  ├── 小任务 → 自动编码 → 测试 → 自愈 → commit（全自动）
  └── 大任务 → 自动转入 /iterate → 影响分析 → 任务清单 → /run-tasks
```

整个过程**默认不暂停**，只在环境问题、修不好、需要人操作时才打断你。

## 所有命令

| 命令 | 用途 | 谁触发 |
|------|------|--------|
| `/impl` | **唯一入口** — 描述任务，AI 自动评估复杂度并执行 | 开发者手动 |
| `/iterate` | 大任务的影响分析 + 任务清单生成 | 由 /impl 自动触发，或手动 |
| `/design` | 生成详细设计 | 由 /iterate 后手动触发 |
| `/run-tasks` | 批量循环执行 checklist 中的任务；支持 **`--parallel N`** 并行 Worker（git worktree 隔离，按 `depends_on` 分波） | 由 /iterate 后手动触发 |
| `/init-baseline` | 旧项目首次接入，生成基线 + 初始化 knowledge | 手动（一次性） |
| `/review` | 结构化代码校验（Generator 自审） | 由 /run-tasks 自动触发，或手动 |
| `/adversarial-review` | **独立 Evaluator** 对抗式评估（默认 Task tool spawn 独立 subagent + hook 硬拦 journal / 实现 knowledge；fallback `--new-session`）；关键路径用 **`--oracle`** 双 Evaluator strict-AND | 手动 |
| `/test-gen` | 基于设计契约单独生成测试 | 手动（/impl 已内置测试生成） |
| `/preflight` | 提交前全面检查 | 手动 |
| `/metrics` | Harness 运行指标聚合（首次通过率、Evaluator 分数、knowledge 命中等） | 手动（建议每周或 sprint 结束时） |
| `/dashboard` | **跨项目看板** — 一屏看所有注册项目的指标 / 对抗评估 / Knowledge 命中 / 时间线 | 手动（随时） |
| `/record-session` | 会话记录（journal + knowledge + checklist） | 由 /impl 和 /run-tasks 自动触发，通常不需要手动 |
| `/spec-feedback` | 记录设计文档问题 | 手动 |
| `/command-feedback` | **记录对 slash 命令本身的修改建议**（支持 `--collect` 聚合跨项目反馈） | 手动（踩到命令设计的坑时） |

**典型工作流：**

```
小任务（bug/小需求）：
  /impl "修复 xxx" → 全自动完成 → ✅

大任务（新功能/跨模块）：
  /impl "新增 xxx 体系" → AI 判定大 → /iterate → /design → /run-tasks → ✅

已有 checklist：
  /run-tasks backend → 循环执行 → ✅

并行批处理（夜里跑大 sprint）：
  /run-tasks backend --parallel 4 → 同波 4 个 worktree 并行 → ff-only 按拓扑序合并 → ✅

PR / Sprint 合并前（推荐）：
  /adversarial-review --branch feature/xxx
    → 父 session Task spawn 独立 Evaluator subagent（hook 硬拦 journal / 实现 knowledge）
    → 独立打分 → 必要时 fix-tasks.yaml
    → 加 --new-session 走 fallback（手动新开 Claude Code 进程）

小任务（/impl 直走路径）也要评审时：
  /adversarial-review --sprint ad-hoc/{YYYY-MM-DD}-{slug}
    → /impl 完成时已自动写好 ad-hoc tasks.yaml，直接作为判据输入

关键路径双评审（支付/鉴权/资产/schema 迁移）：
  /adversarial-review --branch feature/xxx --oracle
    → 父 session Task spawn 三个独立 subagent：Evaluator-A（严格规范型）+ Evaluator-B（对抗反例型）+ Aggregator（仲裁）
    → strict-AND：两者都 Approve 才算过；分差 >15 标 disagreement 请人亲审
    → 父 session 不参与仲裁（自己是 Generator，避免 self-rating bias）

每周或 sprint 结束：
  /metrics --days 7 → 看首次通过率、Evaluator 平均分、零命中 knowledge

跨项目/整体趋势：
  /dashboard --open → 浏览器打开单页 HTML，一屏对比所有注册项目

反馈 harness 本身：
  /command-feedback impl "Step 5 测试失败没进自愈就退出了"
    → 记录到本项目 docs/feedback/commands/，在 /dashboard 的"命令反馈"Tab 可见

一次性升级所有注册项目（harness 本身版本更新时）：
  cd /path/to/project-harness-template
  bash upgrade-all.sh --dry-run       # 预览会更新哪些项目
  bash upgrade-all.sh                 # 执行（默认覆盖 + 自动 .bak 备份）
  bash upgrade-all.sh --safe          # 改过命令的项目只生成 .new 旁注
  bash upgrade-all.sh --only my-proj  # 只升级某个项目
```

**使用提示：完成后发现问题怎么办？**

| 情况 | 做法 |
|------|------|
| 同一个 session，刚做完的任务发现问题 | **直接对话**，不需要再输 `/impl`。Claude 已有完整上下文，直接说问题即可。 |
| 同一个 session，开始一个新的不相关任务 | 输入 `/impl "新任务描述"` |
| 新 session，继续上次未完成的工作 | 输入 `/impl "继续上次的 xxx"`，会自动读 journal 恢复上下文 |

例如 `/impl` 完成后你自己测试发现问题，直接说：
```
"我测试了一下，创建模板时 sceneType 传 null 也能创建成功，应该校验非空"
```
Claude 会直接定位代码 → 修复 → 重新测试 → commit。

## 文档结构

```
docs/
├── baseline/              # 项目基线（由 /init-baseline 生成）
├── consensus/             # 共识文档（从 ai-workflow 同步）或迭代共识文档（由 /iterate 生成）
├── design/                # 详细设计（由 /design 生成）
├── tasks/                 # 任务追踪（由 /iterate 自动生成双视图）
│   ├── {sprint-name}/                # 大任务：/iterate 产出
│   │   ├── iterate-consensus.md      # 迭代共识文档
│   │   ├── checklist.md              # 任务清单（人类视角，可勾选）
│   │   ├── tasks.yaml                # 任务清单（机器视角，verify 断言 /run-tasks 执行）
│   │   └── fix-tasks.yaml            # 可选：/adversarial-review 判定 Must-Fix 时自动生成
│   └── ad-hoc/                       # 小任务：/impl 直走时自动生成
│       └── {YYYY-MM-DD}-{slug}/
│           └── tasks.yaml            # 供 /adversarial-review 做客观判据
├── feedback/              # Spec 反馈（开发过程中发现的设计问题）
├── workspace/             # 开发者工作日志 + 指标事件
│   ├── {developer-name}/
│   │   └── journal.md     # 滚动更新的工作日志（跨 session 记忆）
│   └── .harness-metrics/  # 结构化事件流（/metrics 聚合数据源）
│       ├── impl/              *.jsonl
│       ├── adversarial/       *.jsonl
│       ├── run-tasks/         *.jsonl
│       └── knowledge-hits/    *.jsonl
└── project.yaml           # 项目元信息
```

## Knowledge 分层加载

`.claude/knowledge/` 按领域分目录，命令执行时**按需加载**——只加载当前任务相关的 knowledge，不浪费上下文窗口。

```
.claude/knowledge/
├── backend/
│   ├── architecture.md       # DDD/MVC 架构规范
│   ├── api-conventions.md    # API 设计约定
│   └── sxp-framework.md      # sxp-framework/sxp-component 使用规范
├── frontend/
│   ├── react-patterns.md     # React + antd Web 管理后台规范
│   └── taro-patterns.md      # Taro + Vant 小程序规范
├── testing/
│   └── standards.md          # 测试标准和覆盖要求
├── collaboration.md          # 多 agent 并行协作规范（识别信号 + 自检 + 隔离姿势）
└── red-lines.md              # 质量红线（所有角色通用）
```

**加载规则：**

| 命令 | 后端任务加载 | 前端任务加载 | 测试任务加载 |
|------|------------|------------|------------|
| `/impl` | `backend/*` + `collaboration.md` + `red-lines.md` | `frontend/*` + `collaboration.md` + `red-lines.md` | `testing/*` + `collaboration.md` + `red-lines.md` |
| `/review` | `backend/*` + `collaboration.md` + `red-lines.md` | `frontend/*` + `collaboration.md` + `red-lines.md` | — |
| `/design` | `backend/*` + `red-lines.md` | `frontend/*` + `red-lines.md` | `testing/*` + `red-lines.md` |
| `/preflight` | `collaboration.md` + `red-lines.md`（全量扫描） | `collaboration.md` + `red-lines.md` | `collaboration.md` + `red-lines.md` |
| `/run-tasks` | `collaboration.md` + `red-lines.md`（启动前自检时加载） | 同左 | 同左 |
| `/adversarial-review` | **仅** `red-lines.md` + design + diff + tasks.yaml | 同左 | 同左 |

**为什么 `collaboration.md` 要在多个命令里加载？** 它描述的是"多 agent / 多窗口并发共用工作区"时的识别信号和应急规范，所有**直接操作工作区**的命令（写代码 / 校验 / 批量执行 / 提交前检查）都可能触发相关情况。`/design` 和 `/adversarial-review` 不直接动工作区，所以不加载。

如果 Claude 无法自动判断当前任务是后端/前端/测试，会询问开发者。

**为什么 `/adversarial-review` 加载规则特别严格？** 它是独立 Evaluator，加载 backend/frontend 的 knowledge 反而会让它"帮 Generator 找理由过稿"。详见 [HARNESS_PHILOSOPHY.md](./HARNESS_PHILOSOPHY.md) 的三角色模型。

## 需求来源

- **TAPD**：通过 TAPD MCP 读取需求卡片和 Bug 单（默认本地已配置 TAPD MCP 连接）
- **GitHub Issue**：通过 GitHub MCP 读取 Issue 及评论
- **手动输入**：开发者直接描述需求或粘贴内容

## MCP 配置

见 `.mcp.json`：

- **GitHub MCP** — 读取 Issue、PR
- **TAPD MCP** — 读取需求卡片（如使用 TAPD）
- **Jenkins MCP** — `/impl` Step 7、`/run-tasks` Step 7 询问后可选触发构建（默认 N，避免误触发）。多 Freestyle job 串行（package → deploy）通过 `.claude/jenkins.yaml` 编排，详见 `.claude/jenkins.yaml.example`。占位符 `${git.branch}` / `${stages.X.build_number}` 由命令解析填充。deploy 阶段默认 `wait: false`（红线 26）
- **MySQL / MongoDB MCP**（可选）— 真实数据库测试。每个 DB 实例对应一个独立 server（`mysql-{name}` / `mongo-{name}`），用 `bash .claude/scripts/db-config.sh` 维护，**不要手改 .mcp.json**

### DB 只读硬约束（Hook 拦截）

`.claude/hooks/db-readonly-guard.py` 是 PreToolUse hook，匹配所有 `mcp__mysql-*__*` 和 `mcp__mongo-*__*` 工具调用，在请求到达 MCP server 之前就 deny 写操作：

- **MySQL**：只放行 SELECT / SHOW / DESCRIBE / EXPLAIN / WITH（CTE 还会二次检查内部是否含写）
- **MongoDB**：白名单 find / aggregate / count / distinct / list_collections 等只读方法

任何 INSERT / UPDATE / DELETE / DROP / insertOne / updateOne 等都会被拦截，错误信息提示开发者改用 `test_db_strategy: docker`。

**双层防护**：即使 hook 被绕过，`.mcp.json` 里引用的账号也必须是只读账号（红线 22-25 条）。

### 数据库 MCP 工作流

```bash
# 一次性配置（per-project，幂等可重跑）
bash .claude/scripts/db-config.sh             # 交互式新增/修改
bash .claude/scripts/db-config.sh --list      # 查看已配
bash .claude/scripts/db-config.sh --remove mysql-order
```

走 SSH 隧道的 DB 自动合并写入 `~/.ssh/config` 的 `Host db-tunnel` 段，可选装 launchd（mac）/ systemd-user（linux）后台服务。

### 多启动类映射

如果项目里多个 Application 各连不同 DB，编辑 `.claude/dbs.yaml` 把启动类映射到对应 server。详见 `.claude/knowledge/testing/standards.md` 的"多启动类 / 多数据源场景"章节。

## 远程日志查询（log-query.py）

排查线上问题时，Claude 可以通过 `.claude/scripts/log-query.py` 拉取远程服务器日志（**只读**，不依赖 MCP）。**用 paramiko + 用户名密码鉴权**，匹配项目里 `login_consum.py` 的接入方式：

```bash
python3 .claude/scripts/log-query.py --add                        # 交互式新增 target
python3 .claude/scripts/log-query.py --list                       # 列已配 target（含密码 env var 设置状态）
python3 .claude/scripts/log-query.py --target prod-app --tail 200 # 拉最后 200 行
python3 .claude/scripts/log-query.py --target prod-app --grep "OutOfMemory" --context 10
python3 .claude/scripts/log-query.py --target prod-app --grep "ERROR" --grep-v "expected"
python3 .claude/scripts/log-query.py --files prod-app             # 只列日志文件，不取内容

# 兼容旧用法（bash 薄壳，内部 exec python3 log-query.py）
bash .claude/scripts/log-query.sh --target prod-app --tail 200
```

配置在 `.claude/logs.yaml`（参考 `.claude/logs.yaml.example`），含 host / user / port / **password_env**（密码所在 env var 名，不是密码本身）/ paths / 可选 default_grep_v。

**密码管理**：
- `logs.yaml` 只存 env var **名字**（如 `PROD_APP_SSH_PWD`），文件可 commit 到 Git
- 实际密码在 `~/.zshrc`：`export PROD_APP_SSH_PWD="..."`
- 多台同密码服务器可以共用同一个 env var（在 logs.yaml 里多个 target 引用相同 password_env）

**安全**：脚本只构造 `tail / grep / cat / zcat / ls` 这类 read-only 命令；path 走白名单字符，pattern 黑名单 shell metachar 防注入；密码只在内存中传给 paramiko，不写文件不进日志。

**依赖**：paramiko + PyYAML（首次跑会检测，缺则提示 `pip install paramiko pyyaml --break-system-packages`）。

## Workspace Journal（会话记忆）

`docs/workspace/{developer-name}/journal.md` 是跨 session 的工作记忆：

- `/impl` 完成时自动追加一条记录（做了什么、改了哪些文件、遗留问题）
- `/record-session` 可在任意时刻手动触发，记录当前会话的完整成果
- 新 session 的 `/impl` Step 1（侦察）自动读取最近 5 条 journal 作为上下文
- journal 是 append-only 的，不会被覆盖
- 每个开发者有自己的 journal，互不干扰

首次使用时，告诉 Claude 你的名字，它会自动创建 `docs/workspace/{你的名字}/journal.md`。

## Spec 自迭代

Knowledge 文件不是一成不变的。当 `/impl` 或 `/review` 过程中发现了 knowledge 里没覆盖的技术点（比如 sxp-framework 的一个新使用模式、一个容易踩的坑），Claude 会在会话结束时建议更新对应的 knowledge 文件：

```
💡 Knowledge 更新建议：
发现 sxp-framework 的 GlobalExceptionHandler 需要用 @Order(97)，
但 backend/sxp-framework.md 中未提及。
建议追加到 sxp-framework.md 的"注意事项"章节。
是否立即更新？(Y/N)
```

确认后自动更新，下次其他开发者用 `/impl` 时就能自动获得这个知识。

## Code Review Graph（可选增强）

如果项目安装了 [code-review-graph](https://github.com/tirth8205/code-review-graph)（通过 MCP 接入），以下命令会自动获得精确的代码结构分析能力：

| 命令环节 | 无 Graph（现有方式） | 有 Graph（增强方式） |
|---------|-------------------|-------------------|
| `/iterate` 影响分析 | 对照基线文档推断 | 调用 `get_impact_radius_tool` 精确计算 blast radius |
| `/impl` Step A 侦察 | 扫描目录和文件 | 调用 `query_graph_tool` 查询调用关系、依赖、测试覆盖 |
| `/impl` Step 5 回归测试 | 跑全量测试 | 调用 `get_impact_radius_tool` 只跑受影响的测试 |
| `/review` 校验范围 | 只看改动的文件 | 调用 `detect_changes_tool` 获取风险评分 + 受影响但未改的文件 |
| `/init-baseline` 架构分析 | 扫描包结构推断 | 调用 `get_architecture_overview_tool` 获取精确架构图 |

**使用规则：**
- 命令执行时，先检查 code-review-graph MCP 是否可用
- 如果可用，优先使用 graph 工具获取精确数据，再结合 Knowledge 和基线文档
- 如果不可用，退回到现有方式（基线文档 + 代码扫描），不报错
- graph 数据和基线文档有冲突时，**以 graph 为准**（graph 是从代码实时计算的，基线可能过时）

**首次使用：**
```bash
# 全局安装（一次）
pip install code-review-graph

# 全局 MCP 配置（~/.claude/settings.json，一次）
{
  "mcpServers": {
    "code-review-graph": {
      "command": "uvx",
      "args": ["code-review-graph", "serve"]
    }
  }
}

# 每个项目首次构建图（一次，之后自动增量更新）
cd your-project
code-review-graph build
```

## 关键原则

- **基线是真相源**：`/iterate` 和 `/design` 都依赖基线来理解现有系统，基线过时了及时 `/init-baseline --refresh`
- **影响分析先于编码**：功能迭代先跑 `/iterate` 看清影响范围，再动手写代码
- **完成标准是合约，不是感觉**：`tasks.yaml` 的 `verify` 断言必须全绿才算做完（防止 *premature closure*）。大任务由 `/iterate` 产出 `docs/tasks/{sprint}/tasks.yaml`；小任务走 `/impl` 直达路径时自动写 `docs/tasks/ad-hoc/{YYYY-MM-DD}-{slug}/tasks.yaml`——两条路径统一都有客观判据，`/adversarial-review` 才跑得起来
- **约束是强制的**：`/review`、`/adversarial-review` 和 `/preflight` 的检查项不是建议，是必须通过的关卡；红线违反直接 Reject
- **独立 Evaluator 对抗自迭代**：同一 agent 既写代码又审代码有偏见，所以 `/adversarial-review` 默认用 Task tool spawn 独立 subagent + `evaluator-context-guard` hook 硬拦 journal / 实现 knowledge；关键路径用 `--oracle` 两个差异化 Evaluator + 独立 Aggregator subagent strict-AND 通过
- **并行不破坏依赖**：`/run-tasks --parallel N` 按 `depends_on` 分波，同波任务在各自 git worktree 里跑，合并时严格走 ff-only 拓扑序（冲突走自愈循环，不允许 `--no-ff` 盖住）
- **反馈要结构化**：开发过程中发现设计有问题，用 `/spec-feedback` 记录到 `docs/feedback/`
- **按需加载上下文**：Knowledge 按领域分层，命令只加载相关的文件，不浪费上下文窗口
- **每次会话留下痕迹**：journal 记录做了什么，下次不用从头解释
- **Knowledge 持续进化**：开发中发现的新知识沉淀回 knowledge 文件，一个人的经验变成团队的资产
- **靠数字做 Harness 决策**：定期跑 `/metrics` 看首次通过率、Evaluator 分数、零命中 knowledge——不靠感觉判断 harness 有没有进步

更深入的设计哲学见 [HARNESS_PHILOSOPHY.md](./HARNESS_PHILOSOPHY.md)。
