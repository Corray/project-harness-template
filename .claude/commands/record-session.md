# /record-session — 记录会话成果

## 用法

```
/record-session
```

在一次 Claude Code 会话结束前执行。如果只做了单个 `/impl` 任务，`/impl` 已经自动写了 journal，不需要再跑此命令。此命令适用于一次会话中做了多件事的情况。

---

## 执行步骤

### Step 1：回顾本次会话

扫描本次会话中的所有操作，自动汇总：
- 执行了哪些命令（/impl、/review、/design 等）
- 创建/修改了哪些文件
- 遇到了哪些问题、做了哪些决策

### Step 2：更新 Journal（月切片）

写入路径：`docs/workspace/{developer}/journal-{YYYY-MM}.md`（按当前日期取月份）。
旧的 `journal.md`（如存在）保留向后兼容只读，不再追加。

在当月切片末尾追加完整的会话记录：

```markdown
---

## {YYYY-MM-DD HH:MM} — 会话记录

### 本次会话概要
- {一段话概括这次会话做了什么}

### 执行的命令
1. /impl "xxx" — {结果概要}
2. /review "xxx" — {通过/未通过}
3. ...

### 文件变更汇总
- 新增：{N} 个文件
- 修改：{M} 个文件
- 关键变更：{列出最重要的 3-5 个文件}

### 决策记录
- {如果会话中做了什么设计决策，记录下来}

### 遗留问题
- {未完成的事项}

### 下次继续
- {建议下次 session 的起点}
```

### Step 3：更新 Task Checklist

如果 `docs/tasks/` 下有当前迭代的 checklist，根据本次会话完成的工作自动更新勾选状态。

### Step 4：Knowledge 更新建议（Spec 自迭代）

回顾本次会话，如果发现了任何值得沉淀的技术点：

```
💡 本次会话发现的可沉淀知识：

1. {技术点描述}
   → 建议追加到：.claude/knowledge/{文件路径}

2. {技术点描述}
   → 建议追加到：.claude/knowledge/{文件路径}

是否逐条更新？(Y/N/选择编号)
```

这是 Knowledge 持续进化的关键机制——一个开发者踩过的坑，通过更新 knowledge 文件，所有团队成员的下次 `/impl` 都能自动获得这个知识。

### Step 5：输出会话总结

```
📝 会话记录已保存

Journal：docs/workspace/{developer}/journal.md
任务清单：{更新了 / 无需更新}
Knowledge：{更新了 N 条 / 无更新建议}

本次会话：{时间跨度}，{N} 个命令，{M} 个文件变更

下次启动时，/impl 会自动读取今天的 journal 作为上下文。
```
