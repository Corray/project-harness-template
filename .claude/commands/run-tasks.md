# /run-tasks — 按角色半自动循环执行任务

## 用法

```
/run-tasks {role}
```

role: backend / frontend / test

示例：
```
/run-tasks backend
/run-tasks frontend
```

可选参数：
```
/run-tasks backend --developer {名字}    # 首次需要，之后自动记住
/run-tasks backend --from 3              # 从第 3 个任务开始（跳过已完成的）
/run-tasks backend --only 2,4            # 只执行第 2 和第 4 个任务
/run-tasks backend --parallel 4          # 并行 Worker 模式（见下）
/run-tasks backend --parallel 4 --max-parallel-fail 2
/run-tasks backend --tasks-file fix-tasks.yaml   # 改用指定任务文件
```

### --parallel N（并行 Worker 模式）

同一"波"内最多 N 个独立任务并行跑，每个任务跑在独立的 `git worktree` 里（`.worktrees/{task.id}/`），完成后按 `depends_on` 拓扑序 `ff-only` 合并回 feature 分支。

- N=1（默认）：退化为串行，行为与今天一致
- N≥2：并行；`--auto-confirm` 默认开启（无法每任务交互确认）
- 失败隔离：单任务失败不影响同波独立任务；失败数 ≥ `--max-parallel-fail`（默认 `ceil(N/2)`）才停 dispatch 新任务
- 硬约束：`.worktrees/` 必须在 `.gitignore`；并发 N 超过 CPU*2 要求用户确认；合并顺序 = 拓扑序（不是完成顺序）

---

## 前提条件

- `docs/tasks/` 下有当前迭代的 `checklist.md`（由 `/iterate` 生成）
- `docs/design/` 下有对应角色的详细设计（由 `/design` 生成）
- 如果没有 checklist，提示：`请先执行 /iterate 生成迭代共识和任务清单`
- 如果没有详细设计，提示：`请先执行 /design {role} 生成详细设计`

---

## 执行步骤

### Step 1：加载上下文

1. 读取 `docs/tasks/` 下最新的 `checklist.md`
2. 过滤出 `{role}` 分组下的任务列表
3. 识别已完成（✅）和未完成（☐）的任务
4. 读取 `docs/design/` 下对应角色的详细设计
5. 按角色加载分层 Knowledge（与 /impl 相同策略）
6. 读取 workspace journal 最近 5 条

### Step 1.5：启动前自检 + Git 分支管理

#### 1.5.1 并发冲突自检（多 agent 协作保护）

**在动任何分支前，先跑三条命令探测是否有另一 agent / 另一 Claude Code 窗口在并行操作此工作区：**

```bash
git status --porcelain   # 有非本任务的未提交改动？
git stash list           # 有非本 session 的 stash？
git reflog -n 10         # 最近有无来源的 reset / checkout / stash？
```

**异常信号匹配规则**（详见 `knowledge/collaboration.md`）：

| 检查项 | 异常判定 |
|---|---|
| `git status --porcelain` 有输出 | 存在未提交改动；若改动的文件**不属于本 sprint 的责任范围**，判定异常 |
| `git stash list` 有非本 session 的条目 | 陌生 stash message（不是你起过的、与当前任务无关） |
| `git reflog -n 10` 出现无来源的 `reset: moving to HEAD` / `checkout: moving from X to Y` | 自己没执行过但历史里有，可能是对方 agent 操作 |

**任一命中 → 暂停问人**，不要自作主张 `checkout .` / `reset --hard` / `clean -fd`：

```
⚠️ 检测到可能有另一 agent 在并行操作此工作区：
  · 信号：{git status / git stash list / git reflog 里具体哪一条}
  · 具体内容：{stash message / reflog 条目 / 陌生文件列表}

如何处理？
1. Y，启动独立 worktree（推荐，见 knowledge/collaboration.md 的 ④ 档）
2. 已知情，继续（另一 agent 的工作已确认归属）
3. 暂停，我自己先查清（退出 /run-tasks）
```

**并行模式下的例外**（`--parallel N>1`）：Worker 在自己的 `.worktrees/{task.id}` 里各自跑这套自检。主 checkout 的自检只需确认"没有人在主 checkout 里手工改东西"。

**硬约束**（red-lines.md 编号 19）：无论是否有人在并行，都**禁止**用 `git checkout .` / `git clean -fd` / `git reset --hard` 丢掉陌生 WIP；应当 `git stash push -m "others-wip-possibly-from-agent-X"` 带标识暂存。

#### 1.5.2 Git 分支管理

**检查当前 git 状态：**

1. 如果当前在 `main` / `master` 分支上：
   - 自动创建并切换到 feature 分支
   - 分支命名规则：`feature/{sprint名}-{role}`
   - 例如：`feature/2026-04-scene-type-backend`
   ```
   🔀 当前在 main 分支，将创建 feature 分支：
   feature/{sprint名}-{role}
   确认？（Y / 自定义分支名）
   ```

2. 如果已经在 feature 分支上（上次中断恢复的情况）：
   ```
   🔀 当前已在 feature 分支：feature/{分支名}
   将在此分支上继续。
   ```

3. 如果有未提交的改动（且 1.5.1 自检判定为"本 session 合法 WIP"）：
   ```
   ⚠️ 检测到未提交的改动（{N} 个文件，已确认归属本 session）。
   建议先处理：
   1. 提交当前改动（git add + commit）
   2. 暂存（git stash push -m "pre-run-tasks-{sprint}"）
   3. 忽略，继续执行
   ```

**等待确认后继续。**

### Step 2：展示任务计划并确认

```
📋 {role} 任务清单（来自 {checklist 文件名}）

已完成（{N} 项）：
  ✅ 1. {任务描述}
  ✅ 2. {任务描述}

待执行（{M} 项）：
  ☐ 3. {任务描述}
     验证：{验证标准}
  ☐ 4. {任务描述}
     验证：{验证标准}
  ☐ 5. {任务描述}
     验证：{验证标准}

计划按顺序执行第 3 → 4 → 5 项。
每个任务完成后按验证标准逐项检查，全部通过自动继续下一个。
验证未通过会暂停等你决定。

确认开始？（Y / 调整顺序 / 选择特定任务）
```

**等待开发者确认后开始。**

### Step 3：任务循环

#### 3.0 串行 vs 并行的分叉

- `--parallel 1`（默认）：按顺序一个个跑，工作在当前 checkout 上进行（下面 3.1~3.3 的老流程，不变）
- `--parallel N`（N≥2）：进入 **并行 Worker 模式**，先拓扑分波，每波并行启动 N 个 Worker，见下方 3.0a

#### 3.0a 并行调度（仅 `--parallel N>1`）

**前置**：

1. 检测 CPU 核数（`nproc` / `sysctl hw.ncpu`），N > cores*2 给警告并让用户确认
2. 按 `tasks.yaml` 的 `depends_on` 拓扑排序切成若干波；同波任务互不依赖
3. 确保 `.worktrees/` 在 `.gitignore`（缺则追加并提示 commit）
4. 清理 `.worktrees/` 下的历史残留
5. 让开发者确认一次："将开启 N 个并行 Worker，创建临时 worktree 于 .worktrees/，开始？(Y/N)"

**每一波的执行**：

```
═════════════════════════
🌊 Wave {i}/{total_waves}：{K} 个独立任务并行
   并发上限：{N}；失败阈值：{max-parallel-fail}
═════════════════════════

启动 Worker（git worktree add 隔离）：
  [Worker-1] T003 → .worktrees/T003/  (feature/{sprint}-{role}/T003)
  [Worker-2] T004 → .worktrees/T004/  (feature/{sprint}-{role}/T004)
  [Worker-3] T007 → .worktrees/T007/  (feature/{sprint}-{role}/T007)
```

每个 Worker 在子 shell 里：
```bash
cd .worktrees/{task.id}
# 执行 3.1 /impl 全流程（--auto-confirm 强制开启）
# 执行 verify 断言循环（≤3 轮自愈）
# git commit 到 feature/{sprint}-{role}/{task.id} 子分支
# 把结果写到 .worktrees/{task.id}/.worker-status.json
```

**实时反馈**（每 10-30 秒刷一次）：
```
🟢 T003 [Step D 生成代码]
🟢 T004 [verify 2/4 通过]
🟡 T007 [自愈第 2 轮]
✅ T003 完成，commit c4d5e6f
```

**失败处理**：
- 单 Worker 失败 → 标 `verdict: failed`，不影响同波其他独立任务
- 失败数 ≥ `--max-parallel-fail` → 停止 dispatch 新任务，等正在跑的 Worker 收尾后汇总暂停
- 下游依赖失败任务的 task → 自动标 `verdict: skipped-dep-failed`，不启动 Worker

**一波结束后的合并**（主 checkout 上，按拓扑序而非完成顺序）：

```
🔀 合并 Wave {i} 的成功任务到 feature/{sprint}-{role}：
  git merge --ff-only feature/{sprint}-{role}/T003  → ✅
  git merge --ff-only feature/{sprint}-{role}/T004  → ✅
  git merge --ff-only feature/{sprint}-{role}/T007  → ⚠️ non-ff（冲突）
     → 冲突自愈循环（≤3 轮；仍不行则 stash 到 feature/conflict-T007 暂停请人）
git worktree remove .worktrees/T003 T004 T007
```

合并完进入下一波。

**硬约束（并行专属）**：
1. `.worktrees/` 必须被 gitignore，严禁 worktree 目录进主分支
2. 每任务一 branch：`feature/{sprint}-{role}/{task.id}`
3. 拓扑依赖不可跨波：依赖未合并完的任务禁止启动 Worker
4. 并发 N > CPU*2 必须开发者显式确认
5. ff-only 失败时不许直接 `--no-ff`，先试 3 轮自愈
6. 清理必须用 `git worktree remove`，禁止 `rm -rf`

#### 3.1 每任务内部的完整流程（串行 + 并行通用）

对每个任务（在 `.worktrees/{task.id}/` 或主 checkout 内）：

```
═══════════════════════════════════════
📌 任务 {序号}/{总数}：{任务描述}
   验证标准：{从 checklist 中读取的验证标准}
   模式：{串行 / 并行 Worker-N / worktree=.worktrees/{task.id}}
═══════════════════════════════════════
```

##### 3.1.a 自动执行 /impl 流程（含 TDD 自愈循环）

每个任务内部的完整流程：
- Step A：侦察（加载设计 + journal + 扫描代码）
- Step B：生成实现计划
- Step C：**等待开发者确认计划**（唯一的人工确认点）
- Step D：生成代码
- Step E：**验证循环（TDD 自愈）**
  - 静态检查（编译 + 红线）→ 失败自动修复
  - 生成该任务的测试用例（数据库操作必须用真实数据库，禁止 Mock）
  - 运行测试 → 失败 → 分析 → 自动修复 → 重新测试（最多 3 轮）
  - 回归测试（跑全量现有测试，确保没破坏）
- Step F：写 journal + git commit
- Step G：Knowledge 更新建议
- Step H：更新 checklist

**Agent 自主处理，只在以下情况暂停请人：**
- 环境连接失败（数据库/服务连不上）→ 告诉人需要做什么
- 自愈 3 轮还没修好 → 说明尝试了什么、为什么没成功
- 需要人工操作（配置密钥、手动创建资源等）→ 给出具体命令
- 发现是设计问题不是代码问题 → 建议 /spec-feedback

##### 3.1.b 任务完成 → 自动 commit → 继续

**验证循环全部通过（测试绿了 + 回归绿了）：**
```
✅ 任务 {序号} 完成：{任务描述}

验证：静态检查 ✅ → 新增测试 {M} 个 ✅ → 回归 {N} 个 ✅
自愈修复：{0/1/2} 轮
文件变更：{K} 个（含测试文件）
```

自动 git commit：
```bash
git add {本任务涉及的文件 + 测试文件}
git commit -m "{project}: {任务描述} [#{序号}]

变更：
- {文件列表}

测试：
- 新增 {M} 个测试，全部通过
- 回归 {N} 个测试，全部通过
- 自愈修复 {K} 轮"
```

```
📦 已提交：{hash} — {任务描述}
→ 自动继续下一个任务...
```

**需要人工介入：**
```
🛑 任务 {序号} 需要人工介入：

{具体原因和需要人做什么}

解决后告诉我继续，或：
1. 跳过此任务，继续下一个
2. 停止循环
```

##### 3.1.c 任务间的连续性

每个任务完成后，下一个任务的侦察步骤会自动读取：
- 前一个任务刚写入的 journal 条目
- 前一个任务修改的文件列表
- 前一个任务新增的测试（下一个任务的回归测试会包含）
- 这确保后续任务能感知到前面的改动，避免冲突

### Step 4：循环结束 — 统一 Review + 集成测试

所有任务完成（或开发者选择停止）后：

```
═══════════════════════════════════════
📊 任务循环完成
═══════════════════════════════════════

执行结果：
  ✅ 完成：{X} 个任务（每个任务已通过各自的测试 + 回归）
  🛑 人工介入：{Y} 个任务（已跳过）
  ☐ 未执行：{Z} 个任务

Git 提交记录（feature/{分支名}）：
  {hash1} {project}: {任务1描述} [#3]
  {hash2} {project}: {任务2描述} [#4]
  {hash3} {project}: {任务3描述} [#5]

文件变更汇总：{总计 N} 个文件（{A} 新增 / {B} 修改）
新增测试汇总：{M} 个测试用例

→ 开始统一 Review + 集成测试...
```

**不再询问是否 Review，直接执行。** 因为每个任务已经各自测试通过了，这一步是确认整体集成没问题。

#### 4.1 统一 Review

自动执行 `/review`，范围为本次循环所有改动的文件：
- 契约对齐（跨任务的接口一致性）
- 架构规范（DDD 分层没有被打破）
- 红线检查

Review 发现问题 → 自动修复 → 重新 Review（自愈循环，最多 3 轮）。
3 轮修不好 → 暂停请人。

#### 4.2 全量集成测试

Review 通过后，跑一遍项目的全部测试（不只是本次新增的）：

```bash
# 后端
mvn test

# 前端
npm test
```

```
🧪 全量集成测试：
  总计 {N} 个测试（含本次新增 {M} 个）
  ✅ 全部通过
或
  ✗ {K} 个失败：
  - {测试名}：{错误概要}
  → 进入自愈循环...
```

集成测试失败 → 分析 → 自动修复 → 重新跑全量测试（最多 3 轮）。
修复后自动 commit（message 带 `fix: integration` 前缀）。

### Step 5：Push + PR

**Review + 集成测试全部通过后：**

自动执行：
```bash
git push origin feature/{分支名}
```

```
🚀 已推送到远程：feature/{分支名}
   包含 {X} 个 commit（每个任务一个 + 修复 commit）

创建 PR：
  标题：{sprint名}：{迭代描述}
  分支：feature/{分支名} → main
  
  建议 PR 描述（已复制到剪贴板）：
  ## 迭代内容
  基于：{迭代共识文档文件名}
  
  ## 任务清单
  - ✅ {hash1} {任务1}
  - ✅ {hash2} {任务2}
  - ✅ {hash3} {任务3}
  
  ## 回滚指南
  如需回滚单个任务：git revert {对应commit hash}
  如需回滚整个迭代：git revert {hash1}..{hash3}
```

### Step 6：Record Session

循环结束后自动触发 `/record-session` 的精简版：

- 写入 journal：本次循环执行了哪些任务、结果如何、每个任务的 commit hash
- Knowledge 更新建议：整个循环过程中发现的可沉淀知识点
- 更新 checklist 最终状态
- metrics：追加一条到 `docs/workspace/.harness-metrics/impl/{YYYY-MM}.jsonl`，并行模式下额外写一条**波汇总**到 `docs/workspace/.harness-metrics/run-tasks/parallel-{YYYY-MM}.jsonl`：

```jsonl
{"time":"...","sprint":"...","role":"...","wave":1,"total_waves":3,"dispatched":5,"succeeded":4,"failed":1,"skipped_dep_failed":0,"concurrent_peak":5,"merge_conflicts":0,"duration_minutes":12}
```

每条 impl 事件额外补 `"parallel":{N},"wave":{i},"worktree":".worktrees/{task.id}"` 三个字段。

```
📝 会话记录已保存

本次循环：
- 执行了 {X} 个 {role} 任务
- Git：feature/{分支名}，{X} 个 commit
- Journal 已更新：docs/workspace/{developer}/journal.md
- Checklist 已更新：docs/tasks/{sprint}/checklist.md
- Knowledge 更新：{更新了 N 条 / 无更新}

剩余工作：
- {role} 未通过任务：{列出}
- 其他角色任务：后端 {N} 项 / 前端 {M} 项 / 测试 {K} 项

下一步：
- /preflight → git push → 创建 PR
- /run-tasks {其他角色} — 如果你也负责其他角色的任务
```

### Step 7：Jenkins 构建（可选，需询问）

**触发条件**：

- `.mcp.json` 中存在 `jenkins` server（没配就跳过）
- 本次 PR 已成功 push 到 origin

**配置文件**：`.claude/jenkins.yaml`（参考 `.claude/jenkins.yaml.example`）。
解析逻辑、占位符、模式判定、metrics 写回结构均与 **/impl Step 7 完全一致**，只在以下细节不同：

#### 7.1 询问语境

```
🔨 PR 已创建（{PR URL}）。是否触发 Jenkins 构建？(y/N):
```

默认 N。选 N → run-tasks 事件 `jenkins` 字段记 `null`。

#### 7.2 默认分支

参数解析时 `${git.branch}` 取刚 push 的 `feature/{sprint}-{role}` 分支（不取本地 HEAD）。

#### 7.3 模式 / 占位符 / 串行 / 输出 / metrics

完全照抄 /impl Step 7.2–7.7 的实现。同一份 `.claude/jenkins.yaml` → 相同行为。

#### 7.4 与 /impl Step 7 的区别

- **入口节点不同**：/impl 是单任务 commit 完触发；/run-tasks 是 sprint 全部 push + PR 后触发一次（不是每个任务都触发）
- **metrics 写到的事件不同**：写到 Step 6 的 `run-tasks/{YYYY-MM}.jsonl` 而非 `impl/{YYYY-MM}.jsonl`
- **构建失败 ≠ PR 失败** —— PR 是开发者的产物，Jenkins 是部署的产物，两者状态独立

#### 7.5 硬约束

同 /impl Step 7.8（默认 N / 凭据错不重试 / 构建失败不影响 commit / 占位符严校验 / wait timeout / deploy 默认 wait: false）。

---

## 注意事项

### 任务粒度

`/run-tasks` 依赖 checklist 中的任务粒度。如果 `/iterate` 生成的任务太大（如"实现整个用户管理模块"），循环效果不好。理想粒度是：
- 一个任务 = 一个接口 + 相关的 entity 改动
- 或一个任务 = 一个页面 + 相关的组件
- 每个任务的 /impl 应该在 10-30 分钟内完成

如果发现任务太大，可以在 Step 2 确认时要求 Claude 拆细。

### 跨角色依赖

如果后端任务和前端任务有依赖关系（如"前端任务 3 依赖后端任务 2 的接口"），应该先跑完后端的，再跑前端的。`/run-tasks` 不会自动处理跨角色依赖，这需要开发者自己判断执行顺序。

### 中断恢复

如果循环中途因为任何原因中断（如 Claude Code 断连、开发者需要离开）：
- 已完成的任务**已经 commit 到 feature 分支**，代码不会丢失
- checklist 已自动勾选，journal 已记录
- 下次执行 `/run-tasks {role}` 会自动跳过已完成的任务，从未完成的继续
- 可以用 `git log --oneline` 快速确认做到了哪里

### 回滚

如果某个任务的 commit 需要撤回：
```bash
# 回滚单个任务（精准）
git revert {该任务的 commit hash}

# 回滚到某个任务之前的状态
git reset --soft {上一个好的 commit hash}
```

因为每个任务一个 commit，回滚不会影响其他任务的代码。这就是逐任务 commit 的核心价值。

### Git 分支策略

```
main ─────────────────────────────────────────── main
       \                                    /
        feature/2026-04-scene-type-backend ─ PR merge（保留逐任务 commit）
            │       │       │       │
          task1   task2   task3   fix:review
```

- 所有开发在 feature 分支上进行，main 保持干净
- 每个任务一个 commit，commit message 包含验证标准结果
- Review 修复的 commit 用 `fix:` 前缀标注
- PR merge 时建议保留逐任务 commit（不 squash），方便精准回滚

### 并行 Worker 模式（`--parallel N`）

```
main ───────────────────────────────────────── main
       \                                /
        feature/{sprint}-{role} ────────  PR merge
         │       ↑       ↑       ↑
         │       │       │       │（拓扑序 ff-only）
         │       │       │       └─ feature/{sprint}-{role}/T007 (Worker-3, worktree)
         │       │       └────────── feature/{sprint}-{role}/T004 (Worker-2, worktree)
         │       └────────────────── feature/{sprint}-{role}/T003 (Worker-1, worktree)
         └─ 主 checkout（最终合并产物）
```

**什么时候开并行**：
- 任务之间大多独立（depends_on 疏松），但整体任务数 ≥ 4
- CI 慢 + 任务多，串行要跑 2h+
- 夜里批处理

**什么时候不要开并行**：
- 任务互相紧耦合（一个改了基础设施，后面全受影响）
- 任务粒度太细（单任务 5 分钟以内，并行的 worktree 开销反而拖慢）
- 本地机器资源紧张（CPU 少、内存小、测试是吞内存大户）

**中断恢复**：并行模式中途被打断，下次 `/run-tasks --parallel N`：
- 已合并到 feature 分支的任务 → 跳过（checklist 已勾选）
- 子分支 `feature/{sprint}-{role}/{task.id}` 存在但未合并 → 提示是否直接 ff-only 合并
- `.worktrees/{task.id}/` 残留 → 先清理再重建

**中断清理脚本**：
```bash
git worktree list | grep .worktrees/ | awk '{print $1}' | xargs -I{} git worktree remove {} --force
git branch --list 'feature/*/*' | xargs -I{} git branch -D {}   # 谨慎，务必先确认已合并
```
