# /impl — 唯一的任务入口

## 用法

```
/impl "{描述你要做的事}"
```

示例：
```
/impl "修复：客户列表分页参数错误导致第二页数据重复"
/impl "模板列表增加按创建时间排序"
/impl "新增模板场景标签体系，支持按场景筛选和多级分类"
```

可选参数：
```
/impl "{描述}" --developer {名字}    # 首次需要，之后自动记住
/impl "{描述}" --confirm             # 强制在编码前暂停确认计划（默认不暂停）
```

---

## 核心原则

**默认自主执行，只在真正需要人的时候才暂停。**

开发者输入描述后，AI 自动完成全部流程：评估复杂度 → 侦察 → 编码 → 写测试 → 跑测试 → 自愈修复 → 回归验证 → git commit → 写 journal。整个过程不需要人确认，除非遇到明确定义的暂停条件。

---

## 执行流程

### Step 1：复杂度评估（自动路由，不暂停）

分析任务描述 + 代码结构，自动判定走哪条路。

**判定为小任务（直接执行 /impl）：**
- 修复 bug
- 改动在 1-2 个模块内
- 不需要新增 API 接口
- 不需要新增/删除数据库实体
- 有 code-review-graph 时：blast radius ≤ 10 个文件

**判定为大任务（转入 /iterate）：**
- 涉及 3 个以上模块
- 需要新增 2 个以上 API 接口
- 需要新增数据库实体或重构实体关系
- 有 code-review-graph 时：blast radius > 10 个文件
- 描述含"新增功能体系"、"重构"、"新模块"等关键词

小任务输出（不暂停）：
```
📋 小任务，直接执行
→ 侦察中...
```

大任务输出（**唯一主动暂停点**）：
```
📋 大任务，建议走 /iterate

原因：{涉及多模块 / 新增接口 / 新增实体 / blast radius 大}

转入 /iterate？(Y / 强制 /impl)
```

**确认 Y 后的流程（交接给 /iterate）：**

```
/iterate 自动执行：
  ├── 影响分析（模块 / API / 数据 / 冲突）
  ├── 生成迭代共识文档：docs/tasks/{sprint}/iterate-consensus.md
  ├── 生成 checklist.md（人类视角，可勾选）
  └── 生成 tasks.yaml（机器视角，含 verify 断言）✅ 一定产出

→ 提示：检查 checklist + tasks.yaml，确认后执行 /run-tasks {role}
```

**为什么大任务不直接自动写代码？** 大任务的完成标准必须**先**被写成 `tasks.yaml` 的断言（cmd / file_contains / http / sql / e2e / regression），否则就是在没有合约的情况下"开干"——这正是 Anthropic 研究指出的 *premature closure* 风险。/iterate 产出的 tasks.yaml 是大任务的合约，/run-tasks 循环执行断言直到全绿才算完成。

**"强制 /impl" 会怎样？** 跳过 /iterate 的影响分析和 tasks.yaml 生成，直接按小任务流程走。只在你**非常确定**任务边界很小、AI 判错的情况下用；否则高概率会漏掉对其他模块的回归影响。

### Step 2：侦察（自动，不暂停）

1. 读取 `docs/project.yaml` 判断项目栈类型
2. 按栈类型加载对应 Knowledge（只加载相关的，不全量）
3. 读取相关详细设计 + 基线文档
4. 读取 workspace journal 最近 5 条（按月切片倒序读：先 `journal-{当月 YYYY-MM}.md` 末尾，不足再补 `journal-{上月}.md` 末尾，仍兼容旧 `journal.md`）
5. 代码结构分析：
   - 有 code-review-graph MCP → `query_graph_tool` 查依赖链和测试覆盖
   - 无 → 扫描相关模块代码

**每加载一个 knowledge 文件，追加一条命中事件**到 `docs/workspace/.harness-metrics/knowledge-hits/{YYYY-MM}.jsonl`（供 `/metrics` 统计 Top/零命中）：

```jsonl
{"time":"2026-04-22T15:30:00Z","command":"/impl","file":"backend/api-conventions.md","bytes_loaded":2450}
```

```
📂 侦察完成：{N} 个相关文件，{M} 个 Knowledge 已加载
→ 编码中...
```

### Step 3：生成计划 + 直接编码（自动，不暂停）

生成实现计划并**立即开始编码**：

```
📝 计划：{N} 个文件（{X} 新增 / {Y} 修改）
→ 编码中...
```

如果 journal 有相关遗留问题，自动覆盖进计划。

> 传了 `--confirm` 参数时才在此暂停。默认不暂停。

编码规则：
- 遵循已加载的 Knowledge 中的技术栈规范和红线
- DDD 项目按模块顺序：client → domain → infrastructure → application → adapter
- 使用框架工具类，不重复造轮子

### Step 4：验证循环（TDD 自愈，自动，不暂停）

#### 4.1 静态检查

- 编译（`mvn compile` / `npm run build`）
- 红线扫描 + 设计对齐 + Knowledge 合规

失败 → 自动修复 → 重新检查。不暂停。

#### 4.2 生成测试

基于任务描述 + 验证标准（如有 checklist）+ 设计文档自动生成：

| 层级 | Mock 策略 |
|------|----------|
| Domain 层（纯业务逻辑） | 可以 Mock |
| Repository / DAO 层 | **禁止 Mock 数据库**，写入→查询→验证→清理 |
| Service / Application 层 | **禁止 Mock 数据库**，第三方服务可 Mock |
| Controller / API 层 | SpringBootTest + 真实数据库，完整链路 |

前端：React Testing Library + Mock API

#### 4.3 运行测试 + 自愈

```
运行测试 → 全部通过？
├── 是 → 进入回归验证（4.4）
└── 否 → 分析错误堆栈 → 修复代码 → 重新运行
         （最多 3 轮，不暂停不询问）
         （3 轮后仍失败 → 暂停请人）
```

自愈过程 AI 完全自主——分析、定位、修复、重跑。不询问修复方向。

```
🔧 自愈 1/3：testCreateTemplate 失败 → DTO 映射遗漏 → 已修复 → ✅
🔧 自愈 1/3：testListByScene 失败 → @Field 注解错误 → 已修复 → ✅
```

#### 4.4 回归验证

- 有 code-review-graph → `get_impact_radius_tool` 只跑 blast radius 内测试
- 无 graph → 跑全量测试

回归失败 → 自愈循环（最多 3 轮）。

### Step 5：Git Commit（自动，不暂停；业务代码独立于 knowledge 沉淀）

验证全部通过后**先提交业务变更**（不含 knowledge），然后在 Step 6.6.b 单独提交 knowledge 沉淀。理由：让 `git log -- .claude/knowledge/` 一眼看清知识演化史，review 知识不必在业务 diff 里大海捞针；出问题可以 `git revert {knowledge-commit-hash}` 干净。

```bash
# 业务 + 测试（不含 .claude/knowledge/）
git add {业务文件 + 测试文件}
git commit -m "{project}: {任务描述}

变更：
- {文件列表}

测试：
- 新增 {M} 个测试，全部通过
- 回归 {N} 个测试，全部通过
- 自愈 {K} 轮"
```

knowledge 的变更（如 6.2 自动追加）**不进这次 commit**，留到 Step 6.6.b。

### Step 6：Record Session（自动，commit 后立即触发）

commit 完成后自动执行完整的会话记录，不需要手动触发 `/record-session`。

**6.1 Journal 记录（按月切片）：**

写入路径：`docs/workspace/{developer}/journal-{YYYY-MM}.md`

- 按月切片避免单文件无限增长（一年下来轻松几十 MB，git diff/blame 都拖累）
- 老的 `journal.md`（如存在）仍兼容读，但**新条目只写当月切片**
- Step 2（侦察）读取最近 5 条时按时间倒序读："当月切片末尾 → 上月切片末尾"，覆盖跨月场景
- 切换月份时不需要任何手工动作，自动按 `date +%Y-%m` 生成文件名

```markdown
---
## {YYYY-MM-DD HH:MM} — {任务简述}

### 做了什么
- {改动概要}

### 文件变更
- {file1}（新增/修改）
- {file2}（新增/修改）

### 测试
- 新增 {N} 个，自愈 {K} 轮，回归通过

### Commit
- {hash} on {branch}

### 遗留
- {如有，下次 /impl 会自动读取}
```

**6.2 Knowledge 自动更新（默认开）：**

发现 knowledge 未覆盖的模式 → **追加到目标文件末尾的"自动追加区"**，不停下问。开发者通过 `git log -- .claude/knowledge/` 事后审查（每次知识变更都是独立 commit，见 6.6.b），必要时 `git revert`。

**追加判定（任一命中才动手）**：

- 框架隐藏行为：本次踩到的、knowledge 没写的"框架边角"
- 业务约束：本次发现的、knowledge 没写的项目特定规则
- 编码模式：本次摸索出的、值得复用的最佳实践

**追加规则**（机械可执行，避免 AI 自由发挥）：

1. **只追加到自动追加区**，永不修改既有人写的内容。每个 knowledge 文件末尾约定一个 section：
   ```markdown
   ## 自动追加区（/impl 沉淀，待团队 review）

   <!-- 以下条目由 /impl 自动追加，每条独立 commit，团队周期性 review 后挪到正式章节 -->
   ```
   如目标文件还没有这个 section，追加前先创建。
2. 每条不超过 3 行：一句"做什么 + 为什么"。
3. 必须带来源标记：`<!-- by /impl on YYYY-MM-DD ({slug}): commit {short-hash} -->`
4. 在 6.1 journal 的 `### Knowledge 建议` 段列出本次追加项（路径 + 一句话）。
5. **冲突保守化**：追加内容若与既有人写章节有相似关键词（grep 命中既有 section 的标题或前 3 行），停下问开发者，不直接追加。这是机械检测，不让 AI 主观判断"是否冲突"——AI 偏向于宣称"不冲突"。
6. `red-lines.md` 永远不自动追加（红线变更必须走团队评审）。

**显式关闭**：用 `/impl --no-knowledge-update "..."` 关掉自动追加，恢复"提示开发者确认后再写"的旧行为。

**理由（待数据校准）**：默认追加 + 事后审查的假设是"询问式更新会因为开发者懒得点 Y 而错过大部分沉淀机会"。这是假设不是结论——本次起在 metrics 加 `knowledge_suggestions` 字段同时记录"建议过 / 实际追加 / 开发者 revert"三个事实，2-4 周后用 `/metrics --knowledge-flow` 验证：

- 若实际 revert 率 > 30%：自动追加在制造噪音，应回到 Y/N
- 若 revert 率 < 5% 且追加增长稳定：自动追加是对的
- 中间区间：保留默认开 + 审视判定规则的精度

不让"我们觉得 90% 会被错过"变成永久政策，让数据说话。

**6.3 Checklist 更新（如有）：**

`docs/tasks/` 下有 checklist.md → 自动勾选完成项。
如 `tasks.yaml` 存在且本次对应某个 task id → 把该 task 的 `status` 字段标为 `done`。

**6.4 补写 ad-hoc tasks.yaml（小任务专用，必做）：**

只在 Step 1 判定为**小任务**时执行；大任务由 `/iterate` 已经写过 `tasks.yaml`，跳过本步。

**目的**：为后续 `/adversarial-review` 提供客观判据。`/adversarial-review` 的 Step 3「机械化执行 tasks.yaml 的 verify 断言」是防 *premature closure* 的强约束，没有 tasks.yaml 这一步就失效。小任务不能因为绕过 /iterate 就豁免客观判据。

**写入位置**：`docs/tasks/ad-hoc/{YYYY-MM-DD}-{slug}/tasks.yaml`

- `{slug}` 规则：任务描述转小写短横线，截 40 字符；中文直接取 commit message 第一行的 `{scope}`；两者都拿不到就用 `IMPL-{HHmmss}`
- 同一天同一 slug 已存在时，追加 `-2` / `-3` 后缀
- 单独目录避免小任务互相覆盖

**内容模板**：

```yaml
# 由 /impl 自动生成（小任务路径）
# 目的：为 /adversarial-review 提供 verify 断言
sprint: ad-hoc
source: /impl
generated_at: 2026-04-22T15:30:00Z
role: backend          # 自动判断：backend | frontend | testing
branch: {当前分支名}
commit: {short-hash}   # Step 5 刚生成的 commit

tasks:
  - id: IMPL-{YYYYMMDD-HHmmss}
    desc: "{原始 /impl 描述}"
    status: done
    files_changed:
      - {file 1 from git diff --name-only HEAD~1..HEAD}
      - {file 2}
    verify:
      # 必须填：Step 4.3 实际跑过且 exit 0 的测试命令
      # 多模块 maven 项目：从仓库根目录跑 + -pl <module> -am（见下方"填写规则"硬约束）
      - type: cmd
        cmd: "JAVA_HOME=... mvn -pl <module-path> -am -DfailIfNoTests=false -Dtest='OrderServiceTest' test"
      # 必须填：本次主要改动文件的关键行（新方法签名 / 新字段 / 新路由）
      - type: file_contains
        file: "{主要改动文件路径}"
        pattern: "{关键标识，如方法签名、注解、路由路径}"
      # 若 Step 4.4 跑过回归测试，也带上
      - type: regression
        scope: "{blast radius 模块名 或 'full'}"
```

**填写规则**：
- `verify.cmd` **必须**是 Step 4.3 已经绿过的命令，不要写"未来应该跑"的命令
- `verify.file_contains.pattern` 要选**本次 /impl 新增或关键修改**的标识（新方法名、新字段、新路由），不要选"本来就有"的行
- 至少 1 条 `cmd` + 1 条 `file_contains`；如果 Step 4.4 回归验证跑了，再加 1 条 `regression`
- 不许写"跳过"占位符——宁可少一条也不许假数据

**多模块 maven 项目硬约束（pl/am）：**

如果项目是**多模块 maven**（根 pom 有 `<modules>` 列表，且本次改动涉及子模块），verify cmd 必须满足：
1. **从仓库根目录跑**，不要 `cd <module> && mvn test`
2. 必须带 `-pl <module-path>`（projects-list，限定要测的子模块）
3. 必须带 `-am`（also-make，自动按依赖序构建上游模块）

正确：
```
JAVA_HOME=... mvn -pl chatlabs-marketing-business/xxx-ability \
  -am -DfailIfNoTests=false -Dtest='EventDictionaryBizServiceImplBatchUpdateTest' test
```

错误（会让 /adversarial-review 复跑命中 stale jar）：
```
cd chatlabs-marketing-business/xxx-ability && mvn -Dtest='...' test
```

**为什么硬约束**：`cd <module> && mvn test` 不会重新构建上游（common 等），而是直接从本地 `~/.m2` 拿上游 jar。如果本次 /impl 同时改了 common 模块（新增 DTO 字段的 getter/setter）但没主动 `mvn install` 到 .m2，运行期就会抛 `NoSuchMethodError`。CI fresh build 永远绿（每次从根 pom 起按依赖序全量编译），所以**这个问题只在本地复跑、对抗 evaluator、其他人 checkout 后跑时暴露**——属于 harness 假阳/假阴的系统性来源。`-pl ... -am` 让 maven 永远先构建当前 source 的上游再跑测试，绕过 .m2 stale jar。

**不适用场景**（直接照原样写常规命令即可）：
- 单模块 maven 项目（根 pom 没 `<modules>`）
- gradle / npm / pnpm / cargo / go 等非 maven 项目
- python pytest / unittest 等

**后续使用**：

```
🧪 本次若需对抗评估，执行（在当前 session 即可，命令会 Task spawn 独立 Evaluator subagent）：
  /adversarial-review --sprint ad-hoc/{YYYY-MM-DD}-{slug}
                  或
  /adversarial-review --branch {当前分支}
                  （后者会自动回查对应 ad-hoc/tasks.yaml）

  想再加一层物理隔离（手动新开 Claude Code 进程）：加 --new-session
```

**6.5 回写 metrics 事件（必做）：**

追加一条 impl 事件到 `docs/workspace/.harness-metrics/impl/{YYYY-MM}.jsonl`（按月滚动），供 `/metrics` 聚合：

```jsonl
{"time":"2026-04-22T15:30:00Z","developer":"{dev}","task_desc":"{任务简述}","task_size":"small","role":"backend|frontend|test","files_changed":3,"tests_added":2,"heal_cycles":1,"first_pass":false,"human_intervention":false,"intervention_reason":null,"commit_hash":"{short-hash}","duration_minutes":12,"knowledge_loaded":["backend/api-conventions.md","red-lines.md"],"knowledge_updated":["backend/sxp-framework.md"],"red_lines_triggered":[],"tasks_yaml_path":"docs/tasks/ad-hoc/2026-04-22-fix-pagination/tasks.yaml"}
```

字段说明：
- `task_size`：本次走的分支——`small`（直接 /impl）或 `large`（转 /iterate）
- `heal_cycles`：Step 4.3 和 4.4 的自愈轮次之和
- `first_pass`：`heal_cycles == 0 && 无人工介入`
- `human_intervention`：本次是否暂停过请人
- `intervention_reason`：若暂停过，取值 `3_rounds_failed` / `env_issue` / `manual_op` / `spec_issue` / `large_task`；否则 `null`
- `knowledge_loaded`：Step 2 实际读到的 knowledge 文件相对路径列表
- `knowledge_suggestions`：Step 6.2 触发的所有 knowledge 沉淀建议，每条 `{file, snippet, action}`，`action` 取值：
  - `appended`：自动追加到目标文件的"自动追加区"（默认行为）
  - `skipped_conflict`：检测到与既有 section 关键词冲突，跳过追加，提示开发者
  - `skipped_user`：跑了 `--no-knowledge-update`
  - `skipped_red_lines`：涉及 `red-lines.md`，按硬约束跳过
- `knowledge_commit`：Step 6.6.b 单独 commit 的 hash（仅 action=appended 时有值，便于事后审查/回滚和度量"自动追加被 revert 的比例"）
- `red_lines_triggered`：Step 4.1 红线扫描发现并自修的条目（自修完成的也要记，体现红线"拦住了"什么）
- `tasks_yaml_path`：`small` 任务为 Step 6.4 刚写的 ad-hoc tasks.yaml 路径；`large` 任务为 `/iterate` 产出的 sprint tasks.yaml 路径。**必填**，`/adversarial-review` 和 `/dashboard` 依赖该字段定位断言源。

如果本次因失败或人工介入提前终止，也要写一条 impl 事件（字段据实填写、`human_intervention: true`），不要因为"没完成"就不记——`/metrics` 的"人工介入率"靠这部分数据。

**6.6.a 完成输出：**

```
✅ {任务描述}

{N} 个文件 · {M} 个测试 · 自愈 {K} 轮
Commits（按顺序）：
  1) {业务-hash}    业务 + 测试
  2) {knowledge-hash}（如有）  knowledge: append from /impl ({slug})
  3) {tracking-hash} tracking: /impl ad-hoc artifacts ({slug})

Journal（月切片）：docs/workspace/{dev}/journal-{YYYY-MM}.md
Knowledge：{已追加 N 条 / 无}
Tasks.yaml（ad-hoc）：docs/tasks/ad-hoc/{YYYY-MM-DD}-{slug}/tasks.yaml
Metrics：docs/workspace/.harness-metrics/impl/{YYYY-MM}.jsonl

如需对抗评估：/adversarial-review --sprint ad-hoc/{YYYY-MM-DD}-{slug}（Task spawn 独立 Evaluator）
如需回滚业务变更：git revert {业务-hash}（不会动 knowledge / tracking）
如需回滚 knowledge 沉淀：git revert {knowledge-hash}
```

**6.6.b Knowledge 单独 commit（仅当本次有 `appended` 沉淀时）：**

```bash
# 上一步 6.6.a 输出后，把 .claude/knowledge/ 下的变更单独提交
git add .claude/knowledge/
git commit -m "knowledge: append from /impl ({slug})

来源：commit {业务-hash}（{任务描述}）
追加：
- {file1}：{一句概要}
- {file2}：{一句概要}

事后审查：git log -- .claude/knowledge/
回滚：git revert HEAD"
```

把 6.6.b 的 commit hash 回填到 6.5 的 `knowledge_commit` 字段。如果本次 `knowledge_suggestions` 全是 `skipped_*` 没有 `appended`，跳过 6.6.b，`knowledge_commit` 留 null。

**6.6.c Tracking files commit（必做）：**

把 Step 6.4 写的 `docs/tasks/ad-hoc/{slug}/tasks.yaml` 和 Step 6.5 追加的 `docs/workspace/.harness-metrics/**/*.jsonl` 一起提交（这些文件没进 Step 5 的业务 commit，要单独跟进 git，否则 `git status` 会永远残留未跟踪文件）：

```bash
git add docs/tasks/ad-hoc/{slug}/ docs/workspace/.harness-metrics/
git commit -m "tracking: /impl ad-hoc artifacts ({slug})

来源：commit {业务-hash}（{任务描述}）
追加：
- docs/tasks/ad-hoc/{slug}/tasks.yaml
- docs/workspace/.harness-metrics/impl/{YYYY-MM}.jsonl
- docs/workspace/.harness-metrics/knowledge-hits/{YYYY-MM}.jsonl
- docs/workspace/{developer}/journal-{YYYY-MM}.md   # 6.1 写的月切片
"
```

**为什么不并到业务 commit**：tasks.yaml 在业务 commit 后才生成（断言指向业务-hash）；metrics jsonl 是 commit 后才知道结果。强行塞进业务 commit 会让"业务"和"跟踪"两个语义混在一起，git log 难看。

**为什么不放进 .gitignore**：这些文件是 `/adversarial-review` 和 `/metrics` 的事实源，必须进 repo（否则其他开发者跑命令拿不到）。

如果某次 /impl 由于失败提前终止，6.4 / 6.5 仍写一条记录（"human_intervention: true"），6.6.c 也要 commit—— `/metrics` 的失败统计依赖这部分数据。

### Step 7：Jenkins 构建（可选，需询问）

**触发条件**：

- `.mcp.json` 中存在 `jenkins` server（没配就跳过本步，不打扰）
- Step 5 已完成 commit（如未 commit 则跳过）
- `docs/project.yaml` 的 `jenkins.prompt` 字段不为 `skip`（见下方"项目级关闭"）

**配置文件**：`.claude/jenkins.yaml`（参考 `.claude/jenkins.yaml.example`）。
不存在该文件时退化为询问开发者输入单个 job 名。

**项目级关闭** — 在 `docs/project.yaml` 加：

```yaml
jenkins:
  prompt: skip          # 取值：ask（默认，每次问 y/N）/ skip（永远跳过）/ auto（永远 Y，仅 sandbox/staging 用）
```

设置成 `skip` 后，/impl Step 7 整段不再询问，metrics 的 `jenkins` 字段记 `{"mode":"skipped_by_project_yaml"}`。每次都问一遍 Y/N 久了会麻木，团队可一次性收敛。

#### 7.1 询问开发者（**默认 N，避免误触发生产部署**）

```
🔨 当前已 commit ({short-hash})。是否触发 Jenkins 构建？(y/N):
```

选 N → 在 Step 6.5 写入的 impl 事件 `jenkins` 字段记 `null`，跳到"暂停条件"段。
如 `project.yaml.jenkins.prompt == auto`，跳过本步直接走 7.2。

#### 7.2 加载 .claude/jenkins.yaml 判定模式

```
if 文件不存在:
    询问 job 名 → 走 "单 job 模式"
elif 含 default_job 字段:
    走 "单 job 模式"，job=default_job
elif 含 stages: 数组:
    走 "多 Freestyle 串行模式"
else:
    报错：jenkins.yaml 既无 default_job 也无 stages，跳过本步
```

#### 7.3 占位符解析

| 占位符 | 取值 |
|---|---|
| `${git.branch}` | `git rev-parse --abbrev-ref HEAD` |
| `${git.commit}` | `git rev-parse --short HEAD`（7 位） |
| `${git.author}` | `git log -1 --format=%an` |
| `${stages.X.build_number}` | 已执行阶段 X 的 build number |
| `${stages.X.url}` | 已执行阶段 X 的 build URL |
| `${stages.X.status}` | 已执行阶段 X 的 status |

引用**未执行 / 未来 / 不存在**的阶段 → 报错退出，不假数据。

#### 7.4 单 job 模式

```
build_number, build_url = mcp__jenkins__build_job(default_job, parameters)
if wait（默认 true）:
    每 poll_interval_seconds（默认 30s）轮询 mcp__jenkins__get_build_status
    直到终态（SUCCESS / FAILURE / ABORTED / UNSTABLE）或超时（timeout_minutes 默认 30）
    超时记 status=TIMEOUT
```

#### 7.5 多 Freestyle 串行模式（你当前的场景：package → deploy）

```python
stages_result = {}   # name -> {build_number, url, status}
overall = "SUCCESS"

for stage in stages:
    params = resolve_placeholders(stage.parameters, stages_result)
    build_number, url = mcp__jenkins__build_job(stage.job, params)
    stages_result[stage.name] = {"build_number": ..., "url": ..., "status": "TRIGGERED"}

    if stage.wait:
        # 轮询直到终态或超时
        status = poll_until_terminal(stage.job, build_number,
                                     poll_interval_seconds, timeout_minutes)
        stages_result[stage.name]["status"] = status
        if status != "SUCCESS":
            overall = status
            if stage.on_failure == "stop":
                break  # 后续阶段全标 SKIPPED
    # wait: false → status 保持 TRIGGERED，进下一阶段
```

**为何 deploy 通常 `wait: false`**：deploy job 可能跑很久（升级、健康检查等），阻塞 /impl 体验差。触发完拿到 URL 即可，开发者后续自己看。

#### 7.6 输出格式

```
🔨 Jenkins 构建结果

✓ package: SUCCESS (#42, https://jenkins.../package/42/)  [waited 3m12s]
✓ deploy:  TRIGGERED (#15, https://jenkins.../deploy/15/) [no wait]

整体: SUCCESS（package 通过，deploy 已触发不等待）
```

失败示例：
```
✗ package: FAILURE (#43, https://jenkins.../package/43/)  [waited 1m22s]
- deploy:  SKIPPED（上游失败 + on_failure=stop）

整体: FAILURE
失败日志（前 30 行）：
{粘贴 mcp__jenkins__get_console_output 截取的关键行}
```

#### 7.7 写回 metrics 事件

把每阶段结果聚合到 Step 6.5 写入的 impl 事件的 `jenkins` 字段（**追加，不写新事件**）：

```jsonl
{..., "jenkins": {
  "mode": "freestyle_chain",
  "stages": [
    {"name":"package","job":"order-service-package","build":42,"status":"SUCCESS","url":"...","duration_seconds":192},
    {"name":"deploy","job":"order-service-deploy","build":15,"status":"TRIGGERED","url":"..."}
  ],
  "overall": "SUCCESS"
}}
```

`overall` 规则：所有 wait: true 阶段都 SUCCESS（含未触发到的 SKIPPED 不算 SUCCESS） → SUCCESS；否则取第一个非 SUCCESS 的 status。

未触发或 7.1 选 N → `jenkins: null`。

#### 7.8 硬约束

- **默认 N，不主动触发** —— 防误触发生产部署
- **Jenkins 不可达 / 凭据错** → 提示检查 `JENKINS_URL` / `JENKINS_USER` / `JENKINS_API_TOKEN`，**不重试不假装成功**
- **构建失败 ≠ /impl 失败** —— commit 已落，Jenkins 失败只是部署侧问题
- **占位符引用未执行阶段** → 报错退出
- **wait: true 超时**（默认 30min）→ 记 status=TIMEOUT，按 on_failure 处理
- **deploy 阶段默认 `wait: false`**（红线 26）

---

## 暂停条件（只有这些情况才打断开发者）

| 条件 | 输出 |
|------|------|
| 大任务需确认走 /iterate | "大任务，转 /iterate？" |
| 数据库/服务连不上 | "请检查 {具体信息}" |
| 自愈 3 轮失败 | "修了 3 次没解决，尝试了 {方法}，请看一下" |
| 需要人工操作 | "请执行 {具体命令}" |
| 设计文档有问题 | "测试与设计预期不符：{差异}" |

**除此之外的所有步骤都自动执行，不暂停，不询问。**

---

## 整体流程图

```
/impl "{描述}"
  │
  ├── [自动] 复杂度评估
  │       ├── 大 → 暂停确认 → /iterate → checklist.md + tasks.yaml → 人工跑 /run-tasks
  │       └── 小 → 继续下面的小任务全自动流程
  │
  ├── [自动] 侦察
  ├── [自动] 计划 + 编码
  ├── [自动] 静态检查 → 失败自动修
  ├── [自动] 生成测试（真实DB，禁止Mock）
  ├── [自动] 运行测试 → 失败自愈（≤3轮）
  ├── [自动] 回归验证 → 失败自愈（≤3轮）
  ├── [自动] git commit
  ├── [自动] 小任务补写 ad-hoc tasks.yaml（给 /adversarial-review 用）
  ├── [自动] record-session（journal + knowledge + checklist + 回写 metrics）
  │
  └── ✅ 完成（含 ad-hoc tasks.yaml 路径 + 回滚指引 + /adversarial-review 指引）

  🛑 暂停 = 环境问题 / 3轮修不好 / 需人操作 / 设计问题 / 大任务确认
  其余一切自动。
```
