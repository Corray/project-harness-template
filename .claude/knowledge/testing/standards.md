# 测试标准

> /test-gen、/impl（Step 5 验证循环）、/design test 时加载。

## 核心原则：真实数据库，禁止 Mock 数据层

涉及数据库读写的测试，**必须连接真实数据库**。Mock 通过但真实环境失败的 bug 是最浪费时间的。

## 测试分层

| 层级 | 测试方式 | Mock 策略 |
|------|---------|----------|
| Domain 层（纯业务逻辑） | 单元测试 | 可以 Mock，不涉及 DB |
| Repository / DAO 层 | 集成测试 | **禁止 Mock 数据库**。写入→查询→验证→清理 |
| Service / Application 层 | 集成测试 | **禁止 Mock 数据库**。第三方服务可以 Mock |
| Controller / API 层 | API 测试 | SpringBootTest + 真实数据库。完整链路验证 |

## 数据库测试环境

| 数据库 | 推荐方案 |
|--------|---------|
| MongoDB | Testcontainers（推荐）或 de.flapdoodle.embed.mongo |
| MySQL | Testcontainers（推荐）或 H2 兼容模式 |
| Elasticsearch | Testcontainers |

**环境是人的职责**：如果数据库连不上，直接告诉开发者需要做什么，不要自己尝试修复环境问题。

## 测试数据管理

- 每个测试方法**开始前**准备数据，**结束后**清理数据
- 使用 Builder 模式构建测试数据
- 测试之间不依赖共享数据状态
- 禁止依赖数据库中已有的数据

## 覆盖要求

- 每条业务流程路径（正常 + 异常分支）必须有对应测试
- 每个 API 至少覆盖：正常请求、参数缺失、参数非法、权限不足
- 涉及状态流转的必须测试每个状态转换
- 数据库操作至少覆盖：创建、查询（含条件过滤）、更新、删除（软删除）

## 前端测试

- 组件渲染：React Testing Library
- API 调用：Mock API 响应验证组件行为（前端可以 Mock API，因为后端已有真实 DB 测试覆盖）
- 关键交互：模拟用户操作验证状态变更

## 自愈修复规则

- 测试失败时，先分析错误堆栈定位问题
- 优先修复业务代码（而非修改测试来让它通过）
- 如果测试本身写错了（验证条件不对），才修改测试
- 最多自愈 3 轮，修不好就暂停请人

## 多启动类 / 多数据源场景

如果项目里有多个 Spring Boot Application（每个连不同 DB），按以下流程：

### 1. 配置 DB MCP

每个 DB 实例对应 `.mcp.json` 中的一个独立 MCP server，**用 `.claude/scripts/db-config.sh` 维护**（不要手改 .mcp.json）：

```bash
cd 项目根
bash .claude/scripts/db-config.sh         # 交互式新增/修改（per-project，幂等）
bash .claude/scripts/db-config.sh --list  # 查看当前已配的 DB
bash .claude/scripts/db-config.sh --remove mysql-order
```

它会自动维护 `.mcp.json`，并在选了 SSH 隧道时合并写入 `~/.ssh/config` 的 `Host db-tunnel` 段。

### 2. 启动类 → DB 映射

编辑 `.claude/dbs.yaml`（不存在时 db-config.sh 会建好骨架）：

```yaml
applications:
  OrderApplication:
    main_class: com.example.order.OrderApplication
    module: order-service
    databases:
      mysql: mysql-order      # 引用 .mcp.json 里的 server 名
      mongo: mongo-events
    test_db_strategy: schema-isolated

  UserApplication:
    main_class: com.example.user.UserApplication
    module: user-service
    databases:
      mysql: mysql-user
    test_db_strategy: shared
```

### 3. 测试时找正确的 DB

`/test-gen` 和 `/impl` Step 4（验证）按以下顺序解析：

1. 读 `.claude/dbs.yaml`，找当前测试的启动类
2. 拿到对应 server 名（如 `mysql-order`）
3. 调用 `mcp__mysql-order__query`、`mcp__mongo-events__find` 等工具

**单库项目**可以不写 dbs.yaml —— Claude 会按 `.mcp.json` 里第一个匹配类型的 server 走。

### 4. 测试策略选择

| `test_db_strategy` | 含义 | 适合 |
|---|---|---|
| `shared` | 直连配置的 DB | 只读测试 |
| `schema-isolated` | 用前缀隔离 schema/database 名（如 `test_${branch}_${user}`） | 写测试 + 多人并行 |
| `docker` | 跑测试时起 docker-compose 的本地 DB（不走 SSH 隧道） | 集成测试，最干净 |

### 5. 红线

- **跨启动类共享同一 DB 写操作时必须显式标注**（防一个 application 的测试污染另一个 application 的数据）
- **test_db_strategy 是 `shared` 的库，写测试必须用 Tx 回滚或用独立 schema**（绝不允许提交到主库）
- **新增启动类时同步更新 `.claude/dbs.yaml`**，否则下次 /test-gen 找不到对应 DB
