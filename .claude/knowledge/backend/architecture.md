# 后端架构规范

> 后端 /impl、/review、/design 时加载此文件。
> 按本项目实际架构模式，保留对应段落，删除不适用的段落。

## DDD 六模块结构（按需保留）

```
项目名/
├── client/          # DTO、VO、枚举、常量（对外暴露的数据结构）
├── domain/          # 业务规则、实体、Gateway 接口（不依赖 infrastructure）
├── infrastructure/  # Gateway 实现、数据库访问、第三方 SDK 调用
├── application/     # Service 编排（不写业务规则，只做调度）
├── adapter/         # Controller、定时任务、消息监听（入口层）
└── start/           # 启动类、配置
```

### DDD 分层规则
- 业务规则不得写在 application 层，application 只做编排调度
- domain 层不得依赖 infrastructure，所有外部访问必须通过 Gateway 接口
- DTO/VO 必须放在 client 模块
- adapter 层的 Controller 不得包含业务逻辑
- 代码输出按模块顺序：client → domain → infrastructure → application → adapter

## MVC 结构（按需保留）

```
项目名/
├── controller/      # 接口入口
├── service/         # 业务逻辑
├── repository/      # 数据访问
├── model/           # 实体和 DTO
└── config/          # 配置类
```

## 基础架构预留设计

根据项目需要选择预留：
- 多租户：核心 Collection 预留 tenant_id，Repository 统一注入租户过滤
- 用量计数：AI 生成/API 调用记录 UsageRecord
- 事件驱动：领域事件解耦异步操作，MVP 用 Spring Event
- 外部服务抽象：所有第三方通过 Gateway 接口隔离
- 认证方式抽象：User + UserAuth 分离
- 软删除：deleted_at 字段 + Repository 默认过滤
- API 版本化：Controller 按版本包组织
- Feature Flag：简单功能开关，支持按租户控制
