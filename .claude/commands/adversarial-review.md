# /adversarial-review — 对抗式评估（独立 Evaluator Agent）

> 这不是 `/review` 的升级版，而是它的**搭档**。
> `/review` 是 Generator 的自审，`/adversarial-review` 是来自另一个 context 的怀疑型审查者。

## 为什么存在这个命令

AI 模型对自己的输出有强烈的偏爱倾向（self-rating bias）。Anthropic 在 *Effective harnesses for long-running agents* 的研究表明，让**同一个 agent 既写代码又审代码**会让审查流于形式——它会倾向于认为"自己写的是对的"。

解决办法是引入一个**独立的 Evaluator Agent**，它：
- 不看实现过程（不加载 journal、不加载 `/impl` 的中间日志）
- 只拿到三样东西：**设计契约 + 代码 diff + 红线**
- 默认立场是**怀疑**，不是帮忙找理由通过
- 用 Anthropic 推荐的四维度打分（功能性 / 代码质量 / 设计契合度 / 原创性）

这是业界目前最成熟的 GAN-style harness 思路：Generator 负责产出，Evaluator 负责挑毛病，二者对抗才能真正收敛到高质量。

## 用法

```
/adversarial-review "{范围描述或 PR/分支}"
```

示例：
```
/adversarial-review --branch feature/2026-04-scene-type-backend
/adversarial-review --commits HEAD~3..HEAD
/adversarial-review --pr 127
/adversarial-review --sprint 2026-04-scene-type    # 本 sprint 所有 commit
```

可选参数：
```
--strict              使用更严格的评分权重（默认已经严格）
--load-design {path}  指定 design 文件（默认自动从 sprint 解析）
--skip-e2e            跳过 Playwright 端到端检查（不推荐）

--oracle                    Oracle 模式（双 Evaluator，strict-AND 仲裁；详见下方"Oracle 模式"章节）
--oracle-paths "x/**,y/**"  只在 diff 涉及这些路径时触发 Oracle（可在 project.yaml.oracle_paths 配置默认）
--new-session               fallback：要求开发者手动新开 Claude Code session 跑命令（用于 Task tool 不可用的场景）
--evaluator A|B|aggregate   Oracle 子角色（仅 --new-session fallback 路径用）
--oracle-serial             同一 session 内先后扮演 A/B 再仲裁（已不推荐）
--arbiter-approve "理由"    人类 override Oracle 的 Reject 判定（会永久标橙色保留记录）
```

## 执行原则（与 `/review` 的关键区别）

| 维度 | `/review` | `/adversarial-review` |
|------|-----------|----------------------|
| 加载的上下文 | 完整（含 journal、含实现讨论） | **只有 diff + design + red-lines** |
| 默认立场 | "帮开发者过稿" | "假设有问题，我来找" |
| 可否给满分 | 可以 | **不允许**（至少列出 1 个改进建议） |
| 触发频率 | 每次 `/impl` 完成时 | `/run-tasks` 结束时，或 PR 创建前 |
| 运行方式 | 同 Agent 继续跑 | **Task tool spawn 独立 subagent**（fallback：新开 session） |

## 执行步骤

### Step 1：用 Task tool spawn 独立 Evaluator subagent（默认路径）

不再要求开发者手动新开 session。父 session 用 **Task tool** spawn 一个独立 subagent 来扮演 Evaluator —— subagent 拥有独立的 context window，不继承父 session 的：

- `docs/workspace/*/journal.md`（Generator 实现思路）
- `.claude/knowledge/backend/*` 和 `frontend/*`（"怎么写"的规范，会让 evaluator 帮过稿）
- 父 session 的对话历史（最关键的隔离）

**Task 调用模板**（伪代码）：

```
Task({
  description: "Adversarial review for {range}",
  subagent_type: "general-purpose",
  prompt: """
你是独立 Evaluator，对以下代码改动做对抗式评估。

强制约束（不可违反）：
  · 不得读 docs/workspace/*/journal.md
  · 不得读 .claude/knowledge/backend/* 或 frontend/*
  · 只读：
    - docs/design/{feature}.md
    - docs/consensus/（如存在）
    - docs/tasks/{sprint}/tasks.yaml 的 verify 断言
    - .claude/knowledge/red-lines.md
    - git diff {range}
    - 改动文件的当前内容

执行步骤（严格顺序）：
  1. 机械跑 tasks.yaml 的 verify 断言（任一失败 → 直接 Reject，不进主观评分）
  2. 四维度评分（功能性 30 / 代码质量 25 / 设计契合度 25 / 原创性 20），
     每维度至少列出 1 项扣分（不许满分）
  3. 输出 Markdown 报告到 docs/feedback/adversarial/{sprint}-{timestamp}.md
  4. 写 metrics 事件到 docs/workspace/.harness-metrics/adversarial/{YYYY-MM}.jsonl

详细评分规则、Must-Fix / Should-Fix 阈值、knowledge 沉淀建议
请严格按 .claude/commands/adversarial-review.md 的 Step 4-7 执行。

完成后返回报告路径 + 整体判定（Approve / Reject / Conditional）+ 关键扣分项。
"""
})
```

父 session 拿到 subagent 返回值后：
1. 把报告路径展示给开发者
2. 如果是 Reject，把 Must-Fix 项列出来
3. 不复述 subagent 的内部推理（避免污染）

### Step 1b：Fallback —— 显式新开 session（仅 `--new-session` 触发）

如果 Task tool 在当前环境不可用，或开发者明确要求 "完全独立的 Claude Code 进程"（如做严格的安全 review），加 `--new-session`：

```
⚠️ Task tool 不可用，回退到新 session 路径。
请新开 Claude Code 对话后执行：
  /adversarial-review --branch {branch}

本命令在当前 session 已完成准备工作（diff 缓存、tasks.yaml 检查），
开发者直接跑即可。
```

**这条路径开发者操作成本高（切 terminal、新开 Claude、cd、再输命令）**，所以新版默认不走它。Task subagent 已经能满足"独立 context"要求。

### Step 2：最小化加载

**只加载这些**，不加载其他：

1. `docs/design/` 下对应的设计文件
2. `docs/consensus/` 下的契约文档
3. `docs/tasks/{sprint}/tasks.yaml` 的 verify 断言（作为客观判据）
4. `.claude/knowledge/red-lines.md`
5. 本次评估范围的代码 diff（`git diff {range}`）
6. 本次评估范围涉及文件的当前内容（只读最新版）

**显式禁止加载**：
- `docs/workspace/*/journal.md`（会泄露实现思路，污染评估）
- `.claude/knowledge/backend/*`、`frontend/*`（那些是"怎么写"的规范，Evaluator 要的是"该怎么判"的标准）
- 任何来自 `/impl` 的中间输出

### Step 3：机械化执行 tasks.yaml 的验证断言

在打分之前，先**实际跑一遍** `tasks.yaml` 里的每条 `verify` 断言：

```
🧪 断言执行：
  T001 / mvn test -Dtest=OrderServiceTest       → ✅ exit 0
  T001 / file_contains: Order.java              → ✅ 命中
  T001 / http GET /api/v1/orders/1              → ✅ 200, $.status 存在
  T001 / regression: order-module               → ✅ 全通过
  T101 / e2e: order-list.spec.ts                → ✗ 失败（截图见附件）
     └─ 原因："订单状态列不可见" / element not found
```

任何断言失败 **直接判定为 Reject**，不进入主观评分。这是 "feature list as JSON prevents premature closure" 原则的强约束实现。

### Step 4：四维度对抗式评分（总分 100）

所有断言通过后，进行主观评分。每一维都必须**至少列出 1 项扣分**（不允许满分）：

#### A. 功能性（30 分）

- 是否完整覆盖 tasks.yaml 中声明的 desc？
- 边界条件是否处理？（空值、溢出、并发、鉴权失败）
- 错误路径是否有合理响应？
- 是否存在"走捷径"（比如用硬编码绕过真实逻辑）？

**怀疑式追问**：
- 这个 if 分支在什么输入下不会进入？进不去会怎样？
- 这个新字段为 null 时的行为在哪里定义？

#### B. 代码质量（25 分）

- 是否违反红线（`red-lines.md`）？
- 是否存在重复代码、过长方法、圈复杂度过高？
- 命名是否自解释？
- 是否引入未使用的导入、死代码？

**怀疑式追问**：
- 如果半年后新人接手，这段代码 10 分钟内能看懂吗？
- 这里为什么不复用已有的 XxxUtil？是没发现，还是刻意不用？

#### C. 设计契合度（25 分）

- 改动是否和 `docs/design/` 对齐？
- API 路径/参数/返回值是否严格符合契约？
- 分层是否正确？（DDD 项目：client/domain/infrastructure/application/adapter）
- 是否引入了契约外的新概念？

**怀疑式追问**：
- 设计文档说返回 `OrderDTO`，实际返回的是哪个类？字段是否完全一致？
- 这次改动有没有悄悄扩大了接口的行为，超出设计的范围？

#### D. 原创性 / 避免捷径（20 分）

这是**最容易被 Generator 偷懒的维度**，也是 Evaluator 最该盯的：

- 是否真的解决了问题，还是只在测试里打了补丁让它过？
- 是否有 `@Ignore` / `skip()` / try-catch 吞异常掩盖问题的痕迹？
- 是否有"为了测试通过而写"的特殊分支？
- 是否用了无关的 mock 绕开了真实逻辑？
- 测试覆盖是否**实际运行了新增的逻辑**（不是只覆盖了行数）？

**怀疑式追问**：
- 如果删掉这条 mock，测试还能过吗？
- 被测试的方法，它的核心分支都有断言吗？

### Step 5：输出对抗式评估报告

格式严格遵守以下模板：

```markdown
# 对抗式评估报告

**范围**：{branch / commits / PR}
**Evaluator**：独立 context（session id: {xxx}）
**执行时间**：{YYYY-MM-DD HH:MM}

## 一、断言执行结果

| 任务 | 断言数 | 通过 | 失败 | 判定 |
|------|-------|------|------|------|
| T001 | 4 | 4 | 0 | ✅ |
| T101 | 3 | 2 | 1 | ✗ |

{若有失败断言，直接判 Reject，停止后续评分}

## 二、四维度评分

| 维度 | 满分 | 得分 | 关键扣分项 |
|------|-----|-----|----------|
| A 功能性 | 30 | 24 | 订单金额为负数未校验 / 并发更新 status 无锁 |
| B 代码质量 | 25 | 20 | OrderService 有 80 行重复逻辑 / 3 处 any 类型 |
| C 设计契合度 | 25 | 22 | API 返回字段 createdTime，设计文档写的是 createdAt |
| D 原创性 | 20 | 12 | OrderServiceTest 的 3 个用例全部 mock 了 Repository，未验证真实查询 |
| **总计** | **100** | **78** | |

## 三、必须修复项（Must-Fix）

阻断合并，必须处理：

1. **[A]** `OrderService#updateStatus` 未处理并发更新场景
   - 位置：`order-domain/.../OrderService.java:142`
   - 建议：加乐观锁或分布式锁

2. **[C]** API 返回字段名与设计契约不一致
   - 实际：`createdTime`
   - 契约：`createdAt`（见 `docs/design/order-api.md#L23`）
   - 后果：前端按 `createdAt` 读取会拿到 undefined

## 四、建议改进项（Should-Fix）

不阻断合并，但下次迭代前应处理：

1. **[D]** `OrderServiceTest` 的 mock 过度，没有验证真实 SQL 行为——建议拆出一个 `OrderRepositoryIT` 用真实数据库覆盖
2. **[B]** `OrderController` 中 3 个 handler 的参数校验逻辑重复，建议抽取 `@Valid` 注解

## 五、总体判定

- [ ] ✅ Approve（90+ 分且无 Must-Fix）
- [x] ⚠️ Approve with Must-Fix（≥70 分，修完 Must-Fix 后自动通过）
- [ ] ✗ Reject（<70 分，或断言失败，或存在红线违反）

## 六、Generator 应该反思的模式（传递给 knowledge 自迭代）

{如发现可沉淀为 knowledge 的模式，列在这里}

- 订单类实体的并发更新场景在本项目内反复出现，建议追加到 `knowledge/backend/concurrency-patterns.md`
- OrderServiceTest 的过度 mock 是本次第 3 次被指出，建议在 `knowledge/testing/standards.md` 补充"Repository 层禁止 Mock"的示例
```

### Step 6：根据判定结果执行后续动作

**Approve** → 输出通过通知，不改动任何文件。

**Approve with Must-Fix** → 自动生成一个 `fix-tasks.yaml` 附加到当前 sprint 目录，内容是每个 Must-Fix 项对应的修复任务（含 verify 断言）：

```
📋 已生成 {sprint}/fix-tasks.yaml，包含 {N} 个 Must-Fix 任务。
下一步：
  /run-tasks {role} --tasks-file fix-tasks.yaml
```

**Reject** → 不生成 fix-tasks.yaml（问题太严重，需要人工决策）。输出：

```
✗ 本次 Evaluator 判定 Reject。
总分 {N}/100，断言失败 {M} 条。
建议动作：
  1. 查看完整报告：{报告路径}
  2. 与开发者讨论根因（不是简单改一下就能过的问题）
  3. 可能需要回到 /design 阶段重新确认设计
```

## Step 7：回写 metrics（供 /metrics 聚合）

在 `docs/workspace/.harness-metrics/adversarial/{YYYY-MM}.jsonl` 下追加：

**单 Evaluator（默认）：**
```jsonl
{"time":"2026-04-22T15:30:00Z","sprint":"...","branch":"feature/...","score":78,"assertions_total":7,"assertions_failed":1,"must_fix":2,"should_fix":2,"verdict":"approve-with-fix","oracle":false,"evaluator":"solo"}
```

**Oracle 模式（下一章节）：**
```jsonl
{"time":"...","oracle":true,"evaluator":"A","score":78,"verdict":"approve-with-fix","peer":"B","peer_score":71,"agreement_delta":7,"disagreement":false}
{"time":"...","oracle":true,"evaluator":"B","score":71,"verdict":"reject","peer":"A","peer_score":78,"agreement_delta":7,"disagreement":true}
{"time":"...","oracle":true,"evaluator":"aggregate","final_verdict":"reject","rule":"strict-AND","must_fix_union":4,"a_score":78,"b_score":71,"disagreement":true}
```

`/metrics` 和 `/dashboard` 会读取这些记录，产出"Evaluator 否决率"、"Oracle 分歧率"、"平均分趋势"等指标。

---

## Oracle 模式（`--oracle`）

### 为什么需要 Oracle

单 Evaluator 也有偏见：遇到陌生框架/业务时倾向于"看起来对就过"，识别"走捷径（D 维度）"尤其吃经验。同样的 diff 跑两次分差可能 10+ 分——模型的内在偏好有随机性。

Oracle 模式用**两个视角错开、上下文完全独立**的 Evaluator 收敛到更高可信度：

- **Evaluator-A（严格规范型）**：重点盯契约对齐（C）、代码质量（B）
- **Evaluator-B（对抗反例型）**：重点盯原创性/捷径（D）、边界条件（A）
- 两人都跑满 4 维度，但视角提示词不同，扣分倾向错开
- **strict-AND 仲裁**：都 Approve 才过；任一 Reject 即 Reject；分差 >15 标 `disagreement`

这是业界 dual-critic 模式的最小实现，目的**不是提升通过率**，而是让关键模块被**更严格地盯**。

### 何时开 Oracle

**强烈推荐**：
- 支付、结算、鉴权、用户资产、外部订单同步等关键路径
- 安全敏感：密钥、加密、外部 API 对接
- 不可回滚的 schema 迁移、数据清洗脚本

**不推荐**（单 Evaluator 足够）：
- 日常 CRUD
- 前端样式微调、文案
- 仅测试文件的改动（除非改到了测试框架本身）

配置方式（任选）：
1. **显式 flag**：`/adversarial-review --oracle ...`
2. **按路径自动**：`/adversarial-review --oracle-paths "order-domain/**,payment/**" ...`
3. **全局配置**：`project.yaml` 里加入
   ```yaml
   oracle_paths:
     - order-domain/**
     - payment/**
     - auth/**
   ```
   当改动涉及任一路径时自动升级 Oracle 模式。

### Oracle 执行流程

**默认方式：两个 Task subagent + 父 session 仲裁（context 隔离 + 零操作成本）**

父 session 调度：

```
1. Task spawn Evaluator-A subagent（带"严格规范型"提示词）
   → 输出报告 oracle/{sprint}-A.json
2. Task spawn Evaluator-B subagent（带"对抗反例型"提示词，独立 context）
   → 输出报告 oracle/{sprint}-B.json
3. 父 session 读两份报告，按仲裁规则出最终结论（Aggregator 角色）
```

两个 subagent 各自独立 context，互相看不到对方的报告。仲裁阶段父 session 只读两份 JSON，不读任何 evaluator 内部推理过程。

**Fallback：三个新 session**（仅 Task tool 不可用时，加 `--new-session`）：

```
session-1（Evaluator-A）→ /adversarial-review --oracle --new-session --evaluator A --branch {...}
session-2（Evaluator-B）→ /adversarial-review --oracle --new-session --evaluator B --branch {...}
session-3（Aggregator） → /adversarial-review --oracle --new-session --evaluator aggregate --branch {...}
```

前两个 session 跑完分别把报告写到 `docs/workspace/.harness-metrics/adversarial/oracle/{sprint}-A.json` 和 `...-B.json`。第三个 session 读两份报告，按仲裁规则出最终结论。

三个 session 必须是**完全独立的对话**，否则 Oracle 退化为"换个马甲还是同一个 Evaluator"。

**已不推荐：`--oracle-serial`（同 session 内）**

```
/adversarial-review --oracle --oracle-serial --branch {...}
```

Agent 在同一 session 内：
1. 扮演 Evaluator-A，跑完 Step 1-5，把报告存到 `.../oracle/{sprint}-A.json`
2. **强制清空内部短期记忆**（重新加载 Step 2 的最小化上下文，不带任何 A 的结论）
3. 扮演 Evaluator-B，跑完 Step 1-5，存到 `.../oracle/{sprint}-B.json`
4. 以 Aggregator 身份读两份报告，按仲裁规则输出最终

⚠️ `--oracle-serial` 在 Aggregate 报告顶部会标 "serial-emulated; context isolation weaker than three-session mode"，不建议用于真正关键路径。

### Evaluator 人格差异化

两人共用 4 维度评分（A/B/C/D 总分 100），但视角提示不同：

**Evaluator-A 的附加系统指令**：
```
你是合规严格的代码 Evaluator。重点：
1. API 路径、参数、返回字段是否**逐字**符合设计契约
2. 代码是否遵循红线和 knowledge 架构规范
3. 命名、分层、重复代码是否值得挑出
4. 功能性上重点关注"是否完整覆盖 tasks.yaml 的 desc"

扣分倾向：C（设计契合度）和 B（代码质量）更严格——看到不一致或规范问题直接扣，不给"大致对"留空间。
```

**Evaluator-B 的附加系统指令**：
```
你是怀疑一切的对抗型 Evaluator。重点：
1. 这段代码"看起来过了"是不是因为 mock/skip/try-catch 偷懒？
2. 测试里删掉某条 mock 还能通过吗？
3. 所有 if 分支、边界条件都被真实验证过吗？（null、溢出、并发、鉴权失败）
4. 有没有"为测试通过而写"的特殊分支？

扣分倾向：D（原创性/避免捷径）和 A（边界条件）更严格——只要嗅到"走捷径"的气味，就往狠里扣。
```

两人的报告**在 Aggregate 之前不得互相引用**。

### 仲裁规则（strict-AND）

Aggregator 读 A 和 B 的报告后：

| A 判定 | B 判定 | 最终判定 | Must-Fix |
|-------|-------|---------|---------|
| Approve | Approve | ✅ Approve | 无 |
| Approve-with-Fix | Approve | ⚠️ Approve-with-Fix | = A.must_fix |
| Approve | Approve-with-Fix | ⚠️ Approve-with-Fix | = B.must_fix |
| Approve-with-Fix | Approve-with-Fix | ⚠️ Approve-with-Fix | A.must_fix **∪** B.must_fix（去重） |
| Approve* | Reject | ✗ Reject | = B.must_fix + should_fix |
| Reject | Approve* | ✗ Reject | = A.must_fix + should_fix |
| Reject | Reject | ✗ Reject | 并集 |

附加规则：
- **分差 > 15**（`|a_score - b_score| > 15`）→ 标 `disagreement: true`，在 `/dashboard` 的对抗评估页用红色徽章高亮
- **维度分差 > 10**（任一 A/B/C/D 维度两 Evaluator 分差超过 10）→ 在 Aggregate 报告的"分歧详情"中列出
- **`--arbiter-approve "理由"`**：人类可 override strict-AND 的 Reject 判定，但必须留 override 记录（写入 metrics 的 `override_by` 和 `override_reason`），/dashboard 会永久标橙色

### Aggregate 报告模板

```markdown
# 对抗式评估报告（Oracle 模式）

**范围**：{branch / commits}
**仲裁规则**：strict-AND
**执行方式**：{three-session | serial-emulated}

## 一、两个 Evaluator 的独立结论

| Evaluator | 总分 | 判定 | Must-Fix | Should-Fix |
|-----------|-----|------|---------|-----------|
| A（严格规范型） | 78 | Approve-with-Fix | 2 | 2 |
| B（对抗反例型） | 71 | Reject | 4 | 1 |

分差：|78-71| = 7 → 一致性：**较好**（≤15）

维度分差：
  - A 维度（功能性）：A=24 / B=18 → 分歧 6
  - D 维度（原创性）：A=14 / B=8  → 分歧 6（B 发现了更多捷径）

## 二、最终判定

✗ **Reject**（strict-AND 触发；B 给出 Reject）

## 三、合并 Must-Fix 清单（A ∪ B，去重）

1. [A.1] [C] API 返回字段名与设计契约不一致（来自 A）
2. [B.1] [D] OrderServiceTest 的 3 个 mock 删除后测试即崩（来自 B）
3. [B.2] [D] 并发场景无乐观锁，测试用单线程 mock 绕过（来自 B）

## 四、分歧详情（给人类 reviewer）

- A 认为 OrderService.updateStatus 的原创性 OK（14/20），B 给 8/20
  - B 的依据：所有测试都 mock 了 Repository，没有真实 SQL 行为
  - 人工复核建议：如果确实另有 IT 测试 cover 真实行为，A 对；否则 B 对

## 五、可沉淀 knowledge

- B 发现"通过 mock 绕开并发验证"被 A 漏了 → 建议 `knowledge/testing/standards.md` 加一条"Repository 层禁止 Mock"
```

### Oracle 硬约束

1. **三 session 是推荐，`--oracle-serial` 是妥协**：关键路径强制三 session
2. **A/B 报告在 Aggregate 前不得互相引用**：破坏这一条 Oracle 就退化
3. **strict-AND 不得松为 OR / majority**：任一 Reject 即 Reject，除非人类 `--arbiter-approve` 并记录理由
4. **分差 > 15 必须标 disagreement**：不允许主观仲裁
5. **Aggregator 不得重跑断言**：断言由 A/B 各自跑过，Aggregator 只仲裁，不做第三次评判

---

## 硬约束（红线）

1. **禁止加载 journal / 实现 knowledge**：破坏 Evaluator 独立性
2. **禁止满分**：任何维度都必须至少 1 条扣分项，否则说明你没在认真看
3. **断言失败直接 Reject**：不要为失败断言找借口
4. **红线违反直接 Reject**：`red-lines.md` 里的规则不可协商
5. **同一 Generator 跑过的 context 不得同时承担 Evaluator 角色**：必须新开 session
6. **Oracle 模式下，两 Evaluator 必须独立**：三 session 推荐，serial 有限适用
7. **Oracle 仲裁用 strict-AND**：不得松为 majority / OR

---

## 整体流程图

### 单 Evaluator（默认）

```
/adversarial-review "{range}"
  │
  ├── [检查] context 是否独立 → 否则建议新开 session
  ├── [加载] design + tasks.yaml + red-lines + diff  （只读这些！）
  ├── [执行] tasks.yaml 中的 verify 断言
  │       ├── 全通过 → 进入评分
  │       └── 有失败 → 直接 Reject
  ├── [评分] A功能性 + B代码质量 + C设计契合度 + D原创性（总分 100）
  │       └── 每维必须至少 1 条扣分
  ├── [输出] 对抗式评估报告
  ├── [判定] Approve / Approve-with-Fix / Reject
  │       └── 若 Approve-with-Fix → 自动生成 fix-tasks.yaml
  └── [记录] 写入 .harness-metrics/adversarial/
```

### Oracle 模式（`--oracle`）

```
session-1（独立 context）          session-2（独立 context）
  /adv-review --oracle              /adv-review --oracle
    --evaluator A                    --evaluator B
      │                                 │
      ├── 扮演严格规范型 Evaluator        ├── 扮演对抗反例型 Evaluator
      ├── 跑 Step 1-5 全流程             ├── 跑 Step 1-5 全流程
      └── 写 oracle/{sprint}-A.json     └── 写 oracle/{sprint}-B.json
             ↓                                ↓
             └──────────→ session-3 ←────────┘
                        /adv-review --oracle
                          --evaluator aggregate
                             │
                             ├── 读 A/B 两份报告
                             ├── 按 strict-AND 仲裁
                             ├── 计算分差 + 维度分差
                             ├── 输出 Aggregate 报告（含分歧详情）
                             └── 写 3 条 adversarial/ 记录（A, B, aggregate）
```

简化版（同 session）：`--oracle-serial` 串行扮演 A→B→aggregate，在 Aggregate 报告顶部标 `serial-emulated`。
