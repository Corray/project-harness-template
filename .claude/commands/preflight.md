# /preflight — 提交前全面检查

## 用法

```
/preflight
```

无参数，自动检查所有未提交变更。

---

## 执行步骤

1. `git diff` 获取变更文件
2. 编译检查
3. 运行测试 + 覆盖率
4. **红线扫描**（`red-lines.md`，按严重度分级）：
   - **[BLOCKER]** 命中 → preflight 直接 ❌ 不通过，列出具体行号 + 红线条款编号
   - **[MAJOR]** 命中 → preflight ⚠ 警告通过（开发者可继续提交，但 PR review 会被 Reject）
   - **[MINOR]** 命中 → ℹ 仅提示，不阻塞
   - 未带级别的条款 → 当作 MAJOR 处理
5. 设计对齐（变更接口 vs 设计文档）
6. 输出：
   - 全部通过 / 仅 MINOR → ✅ 可提交
   - 有 MAJOR → ⚠ 可提交但 PR 会被打回，列具体修复指导
   - 有 BLOCKER → ❌ 禁止提交，先修
