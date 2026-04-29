# /iterate — 基于基线生成迭代共识文档 + 任务清单

## 用法

三种输入模式：

### 模式一：从 TAPD 获取需求
```
/iterate tapd "{需求简述}" --ticket {TAPD需求ID，逗号分隔}
```

### 模式二：从 GitHub Issue 获取需求
```
/iterate github "{需求简述}" --issue {Issue编号，逗号分隔}
```

### 模式三：手动描述需求
```
/iterate manual "{需求简述}"
```

---

## 执行步骤

### Step 1：加载项目上下文

1. 读取 `docs/project.yaml`
2. 读取 `docs/baseline/` 下的最新基线文档（必须存在，否则提示先 `/init-baseline`）
3. 按栈类型加载对应 Knowledge（按需，不全量）
4. 检查 `docs/consensus/` 下是否有已有文档（了解历史上下文）

### Step 2：获取需求详情

**TAPD 模式：** 通过 TAPD MCP 读取 ticket 标题、描述、验收标准、关联关系
**GitHub 模式：** 通过 GitHub MCP 读取 Issue 标题、正文、评论、标签
**Manual 模式：** 提示粘贴需求内容

### Step 3：影响分析（核心）

**如果 code-review-graph MCP 可用：**
- 调用 `get_impact_radius_tool` 获取需求涉及文件的精确 blast radius
- 调用 `detect_changes_tool` 获取风险评分
- 用 graph 数据作为影响分析的基础，再结合基线文档补充业务层面的判断

**如果不可用，退回基线文档推断（现有方式）。**

逐项分析：
- 模块影响：哪些现有模块被修改/新增
- API 影响：哪些接口修改/新增/废弃，是否 breaking change
- 数据模型影响：哪些实体加字段/改字段/新增，是否需要数据迁移
- 外部依赖影响：是否需要对接新服务
- 冲突检测：新需求与现有设计/已知约束是否矛盾

### Step 4：生成迭代共识文档（7 项）

1. 迭代范围（需求清单 + 明确排除项）
2. 影响分析（受影响/不受影响的模块）
3. 接口变更（修改/新增/废弃，标注 breaking change）
4. 数据模型变更（字段变更 + 数据迁移方案）
5. 冲突检测（发现的冲突 + 约束触碰提醒）
6. 风险点和产品确认
7. 基线更新建议

### Step 5：自动生成任务清单（Task Checklist）

从迭代共识文档中自动提取可执行的任务项，按角色分组。**每个任务必须附带可机械执行的验证断言（assertions）**，这些断言会被 `/run-tasks` 在 Step E（验证循环）中实际执行，全部通过才能勾选完成。

**生成两份文件，同一份任务的两种视角：**

#### 5.1 `checklist.md`（人类阅读视角）

```markdown
# 迭代任务清单
基于：{迭代共识文档文件名}
生成日期：{YYYY-MM-DD}
配套机器文件：./tasks.yaml（由 /run-tasks 解析执行）

## 后端
- [ ] T001 {任务描述}
  - 角色：backend
  - 描述：{具体到实体/接口的改动}
  - 验证摘要：{一句话概括验证口径，详见 tasks.yaml#T001}

- [ ] T002 {任务描述}
  - 角色：backend
  ...

## 前端
- [ ] T101 {任务描述}
  - 角色：frontend
  ...

## 测试
- [ ] T201 {任务描述}
  - 角色：test
  ...

## 产品确认（阻塞项）
- [ ] Q1: {问题}
- [ ] Q2: ...
```

#### 5.2 `tasks.yaml`（机器执行视角，核心）

```yaml
sprint: "{sprint-name}"
generated_at: "{YYYY-MM-DD}"
baseline_commit: "{commit-hash}"

tasks:
  - id: T001
    role: backend
    desc: "新增订单状态字段并暴露到查询接口"
    depends_on: []           # 同 sprint 内其他任务 ID，/run-tasks 按拓扑排序执行
    verify:
      # 1) 命令类断言：实际执行一条 shell 命令，检查 exit code
      - kind: cmd
        run: "mvn test -Dtest=OrderServiceTest"
        expect_exit: 0
      - kind: cmd
        run: "mvn compile"
        expect_exit: 0

      # 2) 文件内容类断言：检查文件是否包含某段文本/正则
      - kind: file_contains
        path: "order-domain/src/main/java/com/acme/order/Order.java"
        text: "private OrderStatus status"
      - kind: file_matches
        path: "order-adapter/src/main/resources/openapi.yaml"
        regex: "status:\\s*type:\\s*string"

      # 3) 接口类断言：启动服务后实际调一次接口
      - kind: http
        method: GET
        url: "http://localhost:8080/api/v1/orders/1"
        expect_status: 200
        expect_jsonpath:
          "$.status": "*"     # 通配符表示字段存在即可

      # 4) 数据库类断言（可选，需真实数据库）
      - kind: sql
        datasource: "test"
        query: "SELECT column_name FROM information_schema.columns WHERE table_name='orders' AND column_name='status'"
        expect_rows: ">=1"

      # 5) 回归断言：必须包含,保证不破坏现有功能
      - kind: regression
        scope: "order-module"   # 跑该模块或整项目的已有测试
        expect: all_pass

  - id: T002
    role: backend
    desc: "..."
    depends_on: [T001]         # T002 依赖 T001 完成
    verify: [...]

  - id: T101
    role: frontend
    desc: "订单列表页展示状态列"
    depends_on: [T001]
    verify:
      - kind: cmd
        run: "npm run build"
        expect_exit: 0
      - kind: cmd
        run: "npm test -- OrderList.test.tsx"
        expect_exit: 0
      # 前端任务建议至少一条 E2E 断言（需 Playwright MCP）
      - kind: e2e
        script: "tests/e2e/order-list.spec.ts"
        screenshot: true        # 截图附到 commit message
        assertions:
          - "page has element [data-testid='order-status']"
          - "first row shows 'PENDING' or 'PAID'"

product_confirmations:
  - id: Q1
    question: "取消状态是否需要二次确认弹窗？"
    blocks: [T101]              # 未确认则阻塞的任务
  - id: Q2
    question: "..."
    blocks: []
```

#### 验证断言的写法规则（硬约束）

1. **必须可机械验证**：禁止出现"看起来正确"、"符合预期"、"实现合理"这种无法自动判定的措辞
2. **每个任务至少 2 条断言**：1 条编译/构建类 + 1 条功能验证类
3. **涉及接口的任务必须有 `http` 或 `e2e` 断言**：不能只靠单测
4. **涉及数据库变更的任务必须有 `sql` 断言**：确认 schema 落地
5. **必须包含一条 `regression` 断言**：防止改坏已有功能
6. **前端任务必须至少一条 E2E 断言**：单测和 build 不足以证明 UI 可用
7. **不允许用 `kind: manual`**：如果一个任务无法机械验证，说明它该拆分或者不该进 checklist

#### 断言种类快速参考表

| kind | 用途 | 必填字段 |
|------|------|---------|
| `cmd` | 执行 shell 命令看 exit code | `run`, `expect_exit` |
| `file_contains` | 文件含指定文本 | `path`, `text` |
| `file_matches` | 文件匹配正则 | `path`, `regex` |
| `http` | 调用 HTTP 接口 | `method`, `url`, `expect_status` |
| `sql` | 查询数据库 | `datasource`, `query`, `expect_rows` 或 `expect_value` |
| `e2e` | Playwright 端到端测试 | `script`, `assertions` |
| `regression` | 跑现有测试不破 | `scope`, `expect: all_pass` |

### Step 6：展示并等待确认

```
迭代共识文档 + 任务清单已生成，请检查：
1. 影响分析是否准确？
2. Breaking Change 标注是否正确？
3. 任务拆分粒度是否合适？
4. 产品确认事项是否完整？

确认后保存。
```

### Step 7：保存文件

创建任务目录：
```
docs/tasks/{YYYY-MM}-{需求关键词}/
├── iterate-consensus.md    # 迭代共识文档
├── checklist.md            # 任务清单（人类视角）
└── tasks.yaml              # 任务清单（机器视角，/run-tasks 解析）
```

同时在 `docs/consensus/` 下保存一份迭代共识文档的链接或副本。

**两份任务文件的约定**：
- 两者的 Task ID 必须一一对应（T001 ↔ T001）
- `/run-tasks` 以 `tasks.yaml` 为唯一事实源执行验证
- 人工勾选 `checklist.md` 时，`/run-tasks` 会同步 `tasks.yaml` 的 `status` 字段
- `tasks.yaml` 被修改后必须重跑 `/iterate --refresh-checklist` 同步 `checklist.md`

### Step 8：输出完成提示 + 询问是否立即接 /design

```
已保存：
- 迭代共识：docs/tasks/{目录}/iterate-consensus.md
- 任务清单：docs/tasks/{目录}/checklist.md
- 任务断言：docs/tasks/{目录}/tasks.yaml

任务统计：后端 {N} 项 / 前端 {M} 项 / 测试 {K} 项 / 产品确认 {L} 项
Breaking Change：{有/无}
```

**自动衔接 /design**（默认 Y，开发者趁热打铁）：

```
是否立即生成详细设计文档？
  Y / [回车]    → 继续跑 /design（如同时有 backend 和 frontend 任务，依次跑）
  backend       → 只跑 /design backend
  frontend      → 只跑 /design frontend
  N             → 不跑，开发者后续手动 /design
```

**为什么默认 Y**：开发者刚走完影响分析，迭代上下文还热。让人手动切去敲 /design 容易漏，或者改天才记起来。如果发现共识本身有问题，N 后回去改 iterate-consensus.md，再手动跑 /design 也来得及。

**有产品确认事项时**（Step 6 输出 `产品确认 > 0`）：默认改成 N，并提示"建议先同步 PM 确认 {产品确认事项摘要}，再回来跑 /design"——产品确认未结的设计文档容易白写。
