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
--new-session               fallback：手动新开 Claude Code 进程跑命令（Task tool 不可用、严格安全审查、想再加一层物理隔离时用）
--evaluator A|B|aggregate   Oracle 子角色（仅 --new-session fallback 路径用；默认路径下父 session 自动 spawn 三个 subagent）
--force-same-context        逃生口：明确接受 context 污染风险，在父 session 直接扮演 Evaluator（仅用于调试 prompt / 排查 evaluator 漏检）。报告顶部会标污染警告。
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

**双层防护**：除了 prompt 里的"强制约束"措辞外，还有 PreToolUse hook `evaluator-context-guard.py` 在工具调用层硬拦——subagent 即便想读 journal / 实现 knowledge，Read 工具会被 deny 返回。这是物理隔离，不是约定。

**Marker 管理**（守卫开关）：父 session 在 Task spawn 之前/之后用 `.claude/scripts/evaluator-marker.sh` 切换守卫期：

```bash
bash .claude/scripts/evaluator-marker.sh on --ttl 1800 --reason "adversarial-review {sprint}"
# Task spawn ... （subagent 跑期间 hook 生效）
bash .claude/scripts/evaluator-marker.sh off
```

marker 自带 30 分钟 TTL（默认）自动失效，避免父 session 异常退出留下永久守卫。

> **强制约束**：父 session **必须**在每次 Task spawn 之前调 `marker on`，spawn 完成后调 `marker off`。漏掉 `on` 会让 hook 退化为不生效，"双层防护"塌成单层 prompt 约束（评估等价于回到改造前）。漏掉 `off` 不致命（TTL 兜底），但下一次 /impl 在 30 分钟内会被错误拦截。

**调用模板**（伪代码，注意 marker 的开/关时序）：

```
# 1. 开守卫
Bash("bash .claude/scripts/evaluator-marker.sh on --ttl 1800 --reason 'adv-review {sprint}'")

# 2. spawn 独立 evaluator subagent（hook 此时生效）
Task({
  description: "Adversarial review for {range}",
  subagent_type: "general-purpose",
  prompt: """
你是独立 Evaluator，对以下代码改动做对抗式评估。
环境标记：CLAUDE_EVALUATOR_CONTEXT=1（hook 据此拦截 journal / 实现 knowledge 的 Read 调用）

只读以下文件，不要尝试读其他：
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
  3. 红线判定按 red-lines.md 顶部说明的严重度分级：
     · BLOCKER 违反 → 直接 Reject
     · MAJOR 违反 → 进 Must-Fix
     · MINOR 违反 → 进 Should-Fix
  4. 输出 Markdown 报告到 docs/feedback/adversarial/{sprint}-{timestamp}.md
  5. 写 metrics 事件到 docs/workspace/.harness-metrics/adversarial/{YYYY-MM}.jsonl

详细评分规则、Must-Fix / Should-Fix 阈值、knowledge 沉淀建议
请严格按 .claude/commands/adversarial-review.md 的 Step 4-7 执行。

完成后返回报告路径 + 整体判定（Approve / Approve-with-Fix / Reject）+ 关键扣分项。
"""
})

# 3. 关守卫（即使 Task 抛错，也必须在 finally / try-except 里关）
Bash("bash .claude/scripts/evaluator-marker.sh off")
```

> ⚠️ marker on/off 必须成对。Task 异常时父 session 仍要兜底调一次 `off`（marker TTL 30min 兜底，但应显式关）。

父 session 拿到 subagent 返回值后：
1. 把报告路径展示给开发者
2. 如果是 Reject，把 Must-Fix 项列出来
3. 不复述 subagent 的内部推理（避免污染）
4. 不"代为修订"判定（即便父 session 觉得 evaluator 太严了——那是 self-rating bias 在说话）

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

**默认方式：三个独立 Task subagent（A / B / Aggregator 全部 spawn，父 session 不参与仲裁）**

父 session 调度（顺序执行；**每次 spawn 都用 marker 包夹**）：

```
0. Bash: evaluator-marker.sh on  --ttl 1800 --reason "oracle/A {sprint}"
1. Task spawn Evaluator-A subagent（"严格规范型"提示词，独立 context）
   → 写入 docs/workspace/.harness-metrics/adversarial/oracle/{sprint}-A.json
   → 返回 {report_path, score, verdict}
2. Bash: evaluator-marker.sh off

3. Bash: evaluator-marker.sh on  --ttl 1800 --reason "oracle/B {sprint}"
4. Task spawn Evaluator-B subagent（"对抗反例型"提示词，独立 context）
   → 写入 .../oracle/{sprint}-B.json
   → 返回 {report_path, score, verdict}
5. Bash: evaluator-marker.sh off

6. Bash: evaluator-marker.sh on  --ttl 1800 --reason "oracle/aggregate {sprint}"
7. Task spawn Aggregator subagent（独立 context；prompt 仅含 A.json + B.json 路径 + 仲裁规则）
   → 读两份 JSON（这两份在守卫期不在 forbidden 列表里，hook 放行）
   → 跑 strict-AND，输出 Aggregate 报告
   → 写入 .../oracle/{sprint}-aggregate.md
   → 返回 {final_verdict, must_fix_union, disagreement_flag}
8. Bash: evaluator-marker.sh off
```

> 三段 marker 也可以合并成一个长守卫期（步骤 0 开 → 步骤 8 关），代价是中间任一阶段崩溃时守卫期会长一些。**严禁**全程不开守卫——会让三个 subagent 都退化为单层 prompt 约束。

**为什么 Aggregator 也必须是独立 subagent**：父 session 是 Generator session（开发者刚跑完 `/impl` 那个）。让父 session 读两份报告做仲裁，等价于让被审者自己宣布判决——self-rating bias 会再钻进来。Aggregator subagent 拿到的只有两份 JSON 报告 + strict-AND 规则，不见 Generator 的任何思路，仲裁才独立。

父 session 的角色严格限制为：调度三个 Task 调用 → 拿到 Aggregator 返回值 → 把报告路径和最终判定原样转给开发者。**不复述、不修订、不"我觉得 B 太严格了所以..."**。

**Fallback：三个新 session**（仅 Task tool 不可用时，加 `--new-session`）：

```
session-1（Evaluator-A）→ /adversarial-review --oracle --new-session --evaluator A --branch {...}
session-2（Evaluator-B）→ /adversarial-review --oracle --new-session --evaluator B --branch {...}
session-3（Aggregator） → /adversarial-review --oracle --new-session --evaluator aggregate --branch {...}
```

前两个 session 跑完分别把报告写到 `docs/workspace/.harness-metrics/adversarial/oracle/{sprint}-A.json` 和 `...-B.json`。第三个 session 读两份报告，按仲裁规则出最终结论。

三个 session 必须是**完全独立的对话**，否则 Oracle 退化为"换个马甲还是同一个 Evaluator"。

> **已废弃**：`--oracle-serial`（同 session 内串行扮演 A/B/Aggregator）已移除。同一 session 内"清空短期记忆再切角色"在工程上不可验证，破坏 Oracle 的核心价值。需要简化操作就走默认路径（Task subagent），需要最强隔离就走 `--new-session`。

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

1. **禁止加载 journal / 实现 knowledge**：破坏 Evaluator 独立性。除 prompt 约束外，`evaluator-context-guard.py` PreToolUse hook 在工具层硬拦 Read 对 `docs/workspace/*/journal.md` 和 `.claude/knowledge/{backend,frontend}/*` 的访问。
2. **禁止满分**：任何维度都必须至少 1 条扣分项，否则说明你没在认真看
3. **断言失败直接 Reject**：不要为失败断言找借口
4. **红线违反直接 Reject**：`red-lines.md` 里的规则不可协商（红线本身有严重度分级，BLOCKER / MAJOR / MINOR 见 `red-lines.md` 顶部说明）
5. **Generator 不得直接担任 Evaluator**：必须用 Task tool spawn 独立 subagent（默认）或新开 session（`--new-session` fallback）。父 session 拿到 subagent 返回值后只展示，不"代为修订"。
6. **Oracle 模式下，三个角色（A / B / Aggregator）都必须是独立 subagent**：Aggregator 不能跑在父 session（父 session 是 Generator，会引入新的 self-rating bias）
7. **Oracle 仲裁用 strict-AND**：不得松为 majority / OR

---

## 整体流程图

### 单 Evaluator（默认）

```
/adversarial-review "{range}"  ← 父 session（即 Generator session，仅做调度）
  │
  ├── [Task spawn] Evaluator subagent（独立 context，hook 硬拦 journal/实现 knowledge）
  │       ├── [加载] design + tasks.yaml + red-lines + diff  （只读这些）
  │       ├── [执行] tasks.yaml 中的 verify 断言
  │       │       ├── 全通过 → 进入评分
  │       │       └── 有失败 → 直接 Reject
  │       ├── [评分] A功能性 + B代码质量 + C设计契合度 + D原创性（总分 100）
  │       │       └── 每维必须至少 1 条扣分
  │       ├── [输出] 对抗式评估报告（写到 docs/feedback/adversarial/）
  │       ├── [判定] Approve / Approve-with-Fix / Reject
  │       │       └── 若 Approve-with-Fix → 自动生成 fix-tasks.yaml
  │       └── [记录] 写入 .harness-metrics/adversarial/
  └── 父 session 拿到返回值：展示报告路径 + 判定 + 关键扣分（不复述推理过程）

Fallback：加 --new-session → 父 session 不 spawn，提示开发者手动开新 Claude Code 进程跑命令
```

### Oracle 模式（`--oracle`）

```
父 session（Generator session，仅做调度，不参与仲裁）
  │
  ├── [Task spawn] Evaluator-A subagent（"严格规范型"提示词，独立 context）
  │       └── 写 oracle/{sprint}-A.json
  ├── [Task spawn] Evaluator-B subagent（"对抗反例型"提示词，独立 context）
  │       └── 写 oracle/{sprint}-B.json
  ├── [Task spawn] Aggregator subagent（独立 context，prompt 中只挂 A.json + B.json + 仲裁规则）
  │       ├── 读 A/B 两份报告
  │       ├── 按 strict-AND 仲裁
  │       ├── 计算分差 + 维度分差
  │       ├── 输出 Aggregate 报告（含分歧详情）
  │       └── 写 3 条 adversarial/ 记录（A, B, aggregate）
  └── 父 session 展示 Aggregate 报告路径 + 最终判定（不"代为修订"仲裁结论）

Fallback：加 --new-session → 三个独立 Claude Code 进程跑（A / B / Aggregator）
```

> `--oracle-serial`（同 session 串行扮演 A→B→aggregate）已废弃，见下方"废弃 flag"段。
