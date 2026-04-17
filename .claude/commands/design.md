# /design — 生成详细设计文档

## 用法

```
/design {role}
```

role: backend / frontend / test

技术栈参数从 `docs/project.yaml` 自动读取。

---

## 执行步骤

### Step 1：加载项目上下文

1. `docs/project.yaml` → 技术栈
2. `docs/baseline/` → 现有系统（迭代场景必须有）
3. `docs/consensus/` 或 `docs/tasks/*/iterate-consensus.md` → 最新共识/迭代文档

### Step 2：按需加载 Knowledge

| 角色 | 加载 |
|------|------|
| backend | `.claude/knowledge/backend/*` + `red-lines.md` |
| frontend | `.claude/knowledge/frontend/*` + `red-lines.md` |
| test | `.claude/knowledge/testing/*` + `red-lines.md` |

### Step 3：生成详细设计

严格基于共识/迭代文档展开。迭代场景只覆盖变更部分，标注：新增/修改/改前改后。

发现契约冲突时提示先更新共识文档。

### Step 4：保存到 `docs/design/`

### Step 5：输出完成提示 + 建议下一步
