# 多 Agent 并行协作

> **所有角色共享**。`/impl` / `/run-tasks` / `/review` / `/design` / `/preflight` 默认加载。
>
> 背景：当多个 agent（主-子 agent 派生、人手同时开多个 Claude Code 窗口、同一工作区同分支的应急协作）共享同一 git 工作区时，任意一方的 `git stash` / `git checkout .` / `git reset --hard` 会把对方未提交的 WIP 误伤掉。历史事故显示这种情况经常被误判为"环境坏了"，引发破坏性操作，丢掉对方数小时工作。本文件定义**识别信号 + 启动前自检 + 事故处置规范 + 隔离姿势选择**。

---

## 三层隔离（任一层都有用）

| 层 | 强度 | 成本 |
|---|---|---|
| 物理工作区（独立 git worktree） | 最强，根本不可能互相看见 | 一份磁盘 |
| 分支（独立 feature 分支） | 次强，stash/push 不互通但工作树仍共享 | 零 |
| 身份（独立 developer 名字） | 最弱，但 journal / checklist 分文件 | 零 |

`/run-tasks --parallel N` 默认走第一层；人手开多窗口必须手动建 worktree（见下方"④ 两个 CLI 窗口同时跑同一项目"）。

---

## 识别信号（出现任一现象，先怀疑"另一 agent 在并行"，再怀疑"环境坏了"）

1. **`git reflog` 出现无来源的 `reset: moving to HEAD`**——自己没执行过 reset 但历史里有，是对方 agent 的 reset / stash 操作
2. **`git stash list` 出现陌生 stash message**——不是你起过的 stash，message 内容也跟你当前任务无关
3. **构建或保存文件后，工作树突然"浮现"一堆非本任务改动**——对方 agent 在同一时间窗口落盘
4. **编译错误指向 `grep` 不到的类 / 方法 / 符号**——该符号在对方未 commit 的改动里，`grep` 只能看到已 commit 的状态

---

## 启动前自检（新 session / `/impl` 侦察阶段 / `/run-tasks` Step 1.5）

三条命令各跑一遍：

```bash
git status --porcelain   # 有非本任务的未提交改动？
git stash list           # 有非本 session 的 stash？
git reflog -n 10         # 最近有无来源的 reset / checkout / stash？
```

任一命中异常 → **暂停问人**：

> 检测到可能有另一 agent 在并行操作此工作区（信号：{哪条命中}）。是否启动独立 worktree？（Y / 已知情继续 / 查清再说）

**并行模式下的例外**：`/run-tasks --parallel N` 的 Worker 在自己的 `.worktrees/{task.id}` 里自检。主 checkout 的自检只需确认"没有人手工在主 checkout 里改东西"。

---

## 事故发生后的处置

| 场景 | 错误做法 | 正确做法 |
|---|---|---|
| 工作树有陌生 WIP | `git checkout .` / `git clean -fd` 丢掉 | `git stash push -m "others-wip-possibly-from-agent-X"` 带标识暂存，**不合并到本次提交** |
| 编译错误指向陌生符号 | 去"补齐"缺失的类 / 方法 | 先 `git stash list` + `git log --all --oneline` 确认是不是对方未 commit 的改动；**不是自己的坑不替别人填** |
| 改完代码想验证再 commit | "先跑完全套测试再 commit" | **改完立即 commit**（小原子单位）。降低"未 commit 窗口被对方污染"的概率 |
| 同分支 push 有冲突 | `git push --force` | `git pull --rebase`，冲突 per-hunk 判断是否对方的工作 |

---

## 最佳隔离姿势（按成本从低到高）

### ① 单 agent 场景（绝大多数）

什么都不用做。当前机制（feature 分支 + 逐任务 commit）已够。

### ② 主 agent 起子 agent（Agent 工具派生）

**默认传 `isolation: "worktree"`**：

```
Agent({
  description: "...",
  isolation: "worktree",
  prompt: "..."
})
```

子 agent 在独立 worktree + 独立分支里跑，完工后返回分支名 / 路径，主 agent 负责合并。

**适用**：子任务边界清晰（T001 / T002 / T003 独立 sub-feature）、需要并行加速。

### ③ `/run-tasks --parallel N`（机器批量并行）

harness 自动建 `.worktrees/{task.id}/` + 独立分支 + 按 `depends_on` 分波 + ff-only 拓扑序合并。此种场景下**隔离是内建的**，无需额外操作。合并冲突必须走自愈循环，禁止 `--no-ff` 盖住。

### ④ 两个 Claude Code CLI 窗口同时跑同一项目（人手并行）

**开工前手动建 worktree**：

```bash
cd /path/to/workspace
git -C your-project worktree add \
    ../your-project-B \
    -b feature-xxx-agent-b

# 窗口 A：cd your-project          --developer agent-a
# 窗口 B：cd your-project-B        --developer agent-b
```

developer 名字分开 → journal 自然分为 `docs/workspace/agent-a/journal.md` 和 `docs/workspace/agent-b/journal.md`，互不污染。

### ⑤ 共享工作区同分支的应急情况（最差的姿势，能不用就不用）

如果**确实**只能同工作区同分支（比如磁盘不够、只是简单 hotfix），至少做到：

- 每个 agent 明确自己的"责任文件集"，开工前 `grep -r` 扫一遍确认没被对方改
- commit 前 `git status` 再扫一遍，**只 `git add <具体文件>`，绝对不 `git add .`**
- commit message 带 agent 标识（如 `[agent-a]` 前缀），事后能对账

---

## 反面教训

**不要**因为怀疑"环境坏了"就：

- `rm -rf .git`
- `git reset --hard HEAD`
- `git clean -fd`
- `git checkout .`

如果那些"异常"是对方 agent 的正常 WIP，破坏性操作会**直接毁掉对方几小时的工作**。先 `git stash push -m "..."` 带标识暂存、先查 reflog，再决定下一步。这条是 red-lines.md 的硬约束，不是建议。
