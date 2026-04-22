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
4. 读取 workspace journal 最近 5 条
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

### Step 5：Git Commit（自动，不暂停）

验证全部通过后立即提交：

```bash
git add {所有变更文件 + 测试文件}
git commit -m "{project}: {任务描述}

变更：
- {文件列表}

测试：
- 新增 {M} 个测试，全部通过
- 回归 {N} 个测试，全部通过
- 自愈 {K} 轮"
```

### Step 6：Record Session（自动，commit 后立即触发）

commit 完成后自动执行完整的会话记录，不需要手动触发 `/record-session`。

**6.1 Journal 记录：**

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

**6.2 Knowledge 自动更新：**

发现 Knowledge 未覆盖的技术点 → 默认自动追加到对应文件。开发者可事后 `git diff` 审查。

**6.3 Checklist 更新（如有）：**

`docs/tasks/` 下有 checklist.md → 自动勾选完成项。
如 `tasks.yaml` 存在且本次对应某个 task id → 把该 task 的 `status` 字段标为 `done`。

**6.4 回写 metrics 事件（必做）：**

追加一条 impl 事件到 `docs/workspace/.harness-metrics/impl/{YYYY-MM}.jsonl`（按月滚动），供 `/metrics` 聚合：

```jsonl
{"time":"2026-04-22T15:30:00Z","developer":"{dev}","task_desc":"{任务简述}","task_size":"small","role":"backend|frontend|test","files_changed":3,"tests_added":2,"heal_cycles":1,"first_pass":false,"human_intervention":false,"intervention_reason":null,"commit_hash":"{short-hash}","duration_minutes":12,"knowledge_loaded":["backend/api-conventions.md","red-lines.md"],"knowledge_updated":["backend/sxp-framework.md"],"red_lines_triggered":[]}
```

字段说明：
- `task_size`：本次走的分支——`small`（直接 /impl）或 `large`（转 /iterate）
- `heal_cycles`：Step 4.3 和 4.4 的自愈轮次之和
- `first_pass`：`heal_cycles == 0 && 无人工介入`
- `human_intervention`：本次是否暂停过请人
- `intervention_reason`：若暂停过，取值 `3_rounds_failed` / `env_issue` / `manual_op` / `spec_issue` / `large_task`；否则 `null`
- `knowledge_loaded`：Step 2 实际读到的 knowledge 文件相对路径列表
- `knowledge_updated`：Step 6.2 本次追加/修改的 knowledge 文件
- `red_lines_triggered`：Step 4.1 红线扫描发现并自修的条目（自修完成的也要记，体现红线"拦住了"什么）

如果本次因失败或人工介入提前终止，也要写一条 impl 事件（字段据实填写、`human_intervention: true`），不要因为"没完成"就不记——`/metrics` 的"人工介入率"靠这部分数据。

**6.5 完成输出：**

```
✅ {任务描述}

{N} 个文件 · {M} 个测试 · 自愈 {K} 轮 · commit {hash}
Journal 已更新 · Knowledge {已更新/无更新} · Checklist {已勾选/无} · Metrics 已记录

如需回滚：git revert {hash}
```

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
  ├── [自动] record-session（journal + knowledge + checklist + 回写 metrics）
  │
  └── ✅ 完成（含回滚指引）

  🛑 暂停 = 环境问题 / 3轮修不好 / 需人操作 / 设计问题 / 大任务确认
  其余一切自动。
```
