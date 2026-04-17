# 质量红线

> 所有角色通用。/impl、/review、/preflight 均加载此文件。
> 可根据项目实际情况微调，但核心红线不建议放松。

## 数据库红线

### MongoDB
- 必须明确 Collection 的文档结构
- 必须明确索引策略
- 必须说明嵌套 vs 引用的设计决策理由

### MySQL
- 必须考虑索引
- 必须有 created_at 和 updated_at 字段
- 大表设计需考虑分页和慢查询优化

### Elasticsearch
- 必须明确 Index 的 Mapping 设计
- 必须明确分词器选择

## 基础架构红线

- 所有核心实体必须包含 tenant_id 字段（即使 MVP 阶段只有默认租户）
- 所有核心实体必须包含 deleted_at 字段用于软删除
- 所有核心实体必须包含 created_at 和 updated_at 字段
- 所有第三方服务调用必须通过 Gateway 接口，禁止直接调用第三方 SDK
- 所有异步业务操作必须通过领域事件发布
- API 路由必须带版本前缀（如 /api/v1/）
- User 和 UserAuth 必须分离存储

## 通用编码红线

- 不允许硬编码魔法值，必须使用常量或枚举
- JDK 11 项目不得使用 JDK 11 以上语法特性
- JDK 21 项目优先使用现代语法
- 所有对外接口必须考虑异常处理和错误码定义
- API 必须考虑参数校验、权限控制、幂等性

## 前端通用红线

- TypeScript 项目不允许使用 any
- Taro 项目不得使用 Web DOM API
- 严格使用对应产品形态的 UI 组件库，不得混用
- 组件库已提供的组件不得自行重写
