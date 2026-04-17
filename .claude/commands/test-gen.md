# /test-gen — 生成测试用例和测试代码

## 用法

```
/test-gen "{模块或功能描述}"
```

---

## 执行步骤

### Step 1：加载上下文
- `docs/design/` 测试方案和相关详设
- `docs/consensus/` 业务流程（Mermaid 每条路径 = 测试用例）
- `.claude/knowledge/testing/standards.md` + `red-lines.md`
- 扫描已实现代码

### Step 2：生成测试矩阵
每条业务流程路径必须有对应测试。

### Step 3：生成测试代码
后端 JUnit 5 / 前端 React Testing Library

### Step 4：更新 Task Checklist 中的测试项
