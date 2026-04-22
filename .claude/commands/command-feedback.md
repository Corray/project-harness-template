---
name: command-feedback
description: 记录对某条 slash 命令（如 /impl、/review）的修改建议，供团队/模板仓库沉淀
---

# /command-feedback

## 你是谁

你在帮开发者**记录对某条 slash 命令本身的反馈**。和 `/spec-feedback` 不同：
- `/spec-feedback` → 针对"设计文档/共识文档"
- `/command-feedback` → 针对"命令本身的 prompt 和流程"（例如 /impl 步骤少了一步、/review 有个 false positive 的规则）

这些反馈最终会被聚合到 `~/.claude/command-feedback-inbox/`，可以一次性 PR 回模板仓库（project-harness-template）。

## 用法

```
/command-feedback <command-name> "<简短问题描述>"
/command-feedback --list          # 列出本项目已有的反馈
/command-feedback --collect       # 把所有项目的反馈聚合到 ~/.claude/command-feedback-inbox/
/command-feedback --aggregate     # 同 --collect
```

支持的命令名（触发自动建议）：impl, iterate, design, run-tasks, review, adversarial-review, test-gen, preflight, metrics, record-session, spec-feedback, init-baseline, dashboard

## 执行步骤

### 模式 1：记录新反馈（默认）

**Step 1 — 解析参数**
- 参数 1：command-name（必须是 `.claude/commands/` 下真实存在的一个 .md）
- 参数 2：一句话概述
- 如果参数缺失，用 AskUserQuestion 询问

**Step 2 — 收集细节（用 AskUserQuestion，多题一次发）**
问这些问题（只问开发者没在参数里说清的部分，不要冗余）：
1. "什么情况下触发的？" → 比如 "执行 /impl 实现新增 feature 时"
2. "实际观察到的问题？" → 比如 "Step 5 测试跑了但失败没有自愈就退出了"
3. "期望行为？" → 比如 "失败时应进入自愈循环 3 次后再报告"
4. "建议改动指向哪一步？" → 比如 "impl.md 的 Step 5 应增加 retry 逻辑"
5. "影响面" → 选择 blocker / painful / minor / nice-to-have

**Step 3 — 写入反馈文件**
- 路径：`docs/feedback/commands/{command-name}-{YYYYMMDD-HHMMSS}.md`
- 开发者名从 `docs/workspace/` 下已有目录推断（最近修改的那个），推不出来就问一次
- 文件内容（YAML frontmatter + markdown）：

```markdown
---
command: {command-name}
developer: {developer-name}
created_at: {ISO-8601}
project_path: {CWD 绝对路径}
project_name: {CWD basename}
severity: {blocker|painful|minor|nice-to-have}
status: open
---

# {command-name} 命令反馈：{一句话概述}

## 触发场景
{Step 2.1 的答案}

## 观察到的问题
{Step 2.2 的答案}

## 期望行为
{Step 2.3 的答案}

## 建议改动
{Step 2.4 的答案}

## 相关上下文
- 本次 session 任务：{如可从 journal 推断}
- 相关文件：{如涉及 /impl 步骤 5，给出 .claude/commands/impl.md 的锚点}
- 相关事件：{docs/workspace/.harness-metrics/*/ 下最近一条相关 jsonl 的 id，如有}

## 本地临时绕行
{如果开发者当前 session 已手动绕过这个问题，记录怎么绕的，帮未来读者}
```

**Step 4 — 回写索引**
- 追加一条 JSONL 到 `docs/workspace/.harness-metrics/command-feedback/events.jsonl`：
  ```json
  {"ts":"...","command":"...","severity":"...","developer":"...","file":"docs/feedback/commands/xxx.md"}
  ```
- 这条事件流会被 `/dashboard` 读取，用于展示 "命令反馈计数"。

**Step 5 — 回显**
```
✅ 已记录 /{command-name} 的反馈（severity: {severity}）
  文件：docs/feedback/commands/{command-name}-{timestamp}.md

下一步你可以：
  1. 同一 session 继续开发（这只是记录，不改动命令）
  2. 有空时在本仓库跑：/command-feedback --collect
     → 把所有项目的反馈聚合到 ~/.claude/command-feedback-inbox/
  3. 到 project-harness-template 仓库把 inbox 的反馈做 PR，更新命令模板
```

---

### 模式 2：--list

列出本项目 `docs/feedback/commands/*.md`，按 severity 排序，每条一行：
```
[severity] {command} {created_at} — {标题}
```

---

### 模式 3：--collect（或 --aggregate）

**目的**：把所有注册项目的命令反馈汇总到一个地方，方便一次性 PR 回模板仓库。

**Step 1** — 读取 `~/.claude/harness-projects.yaml`，遍历所有项目。
**Step 2** — 对每个项目的路径，读 `{path}/docs/feedback/commands/*.md`。
**Step 3** — 按 `command` 分组，合并到 `~/.claude/command-feedback-inbox/{command}.md`：

文件格式：
```markdown
# {command} 命令反馈汇总

_由 /command-feedback --collect 自动生成，不要手工编辑。_
_生成时间：{now}_
_来源项目数：{n}_

## blocker ({count})

### [{project-name}] {标题}
- severity: blocker
- developer: {name}
- created_at: {ts}
- source: {project}/docs/feedback/commands/xxx.md

{正文全文}

---

## painful ({count})
...
```

**Step 4** — 回显：
```
✅ 已聚合 N 个项目、M 条反馈到 ~/.claude/command-feedback-inbox/
  - impl.md    (12 条，1 blocker, 5 painful, ...)
  - review.md  (3 条，...)
  ...

下一步：
  cd /path/to/project-harness-template
  # 人工或用 AI 把 inbox 里的建议吸收到 .claude/commands/*.md
  # 然后 PR
```

---

## 红线

- ❌ **不要**直接修改 `.claude/commands/*.md`。本命令只记录不改动；修改命令是模板仓库的 PR 流程。
- ❌ **不要**把反馈写到 `docs/feedback/`（那是给 /spec-feedback 的）。必须在 `docs/feedback/commands/` 子目录。
- ❌ **不要**在 `--collect` 时删除原项目里的反馈文件（除非开发者明确要求）。聚合是复制，不是剪切。

## 使用提示

- 反馈最有用的时机：**刚踩完坑，上下文还热的时候**。等 session 结束再来写，细节会流失。
- 写完一条反馈不需要立刻去 PR 模板仓库；让反馈在项目里堆积一段时间，`--collect` 一次批量处理更高效。
- 如果反馈其实是 knowledge 缺失（比如 backend/sxp-framework.md 没讲清楚某个模式），用 knowledge 更新建议流程（/impl 结束时会问）更合适；`/command-feedback` 只针对命令 prompt 本身。
