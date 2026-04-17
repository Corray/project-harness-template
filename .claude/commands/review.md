# /review — 结构化代码校验

## 用法

```
/review "{范围描述或文件路径}"
```

---

## 执行步骤

### Step 1：确定校验范围并加载依据

**如果 code-review-graph MCP 可用：**
- 调用 `detect_changes_tool` 获取变更文件的风险评分和影响范围
- 调用 `get_impact_radius_tool` 发现"受影响但未修改的文件"——这些文件可能需要同步修改
- 校验范围 = 改动文件 + graph 标出的受影响文件

**如果不可用：** 校验范围 = 改动文件

按栈类型加载对应 Knowledge：
- 后端 → `backend/*` + `red-lines.md`
- 前端 → `frontend/*` + `red-lines.md`
- 加载 `docs/design/` 和 `docs/consensus/` 中的契约

### Step 2：逐项校验

**契约对齐：** API 路径、参数、响应、数据字段是否与设计一致
**架构规范：** DDD 分层、模块依赖、Response 类使用（按 knowledge 检查）
**质量红线：** 魔法值、异常处理、参数校验、tenant_id/deleted_at 等
**前端规范：** 组件库使用、TypeScript 类型、跨平台 API

### Step 3：输出校验报告（通过/未通过 + 具体问题）

### Step 4：Knowledge 更新建议（Spec 自迭代）

如果 review 过程中发现 knowledge 未覆盖的模式或踩坑点：
```
💡 Knowledge 更新建议：
{描述发现的新知识点}
建议追加到 {对应 knowledge 文件}。
是否立即更新？(Y/N)
```
