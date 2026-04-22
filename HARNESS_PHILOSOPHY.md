# Harness Philosophy — 为什么这个 Harness 长这个样

> 这份文档不是"怎么用"，是"为什么这么设计"。
> 看完它你会更容易决定：哪些规则可以改，哪些不能动；哪些新命令该加，哪些其实是伪需求。

---

## 一、Harness Engineering 是什么

2026 年初 Anthropic 在 *Effective harnesses for long-running agents* 里明确提出一个观点：

> "AI 能力的瓶颈越来越不是模型本身，而是模型外面那层壳——也就是 harness（马具）。"

**Harness 就是你给 AI 套上的那套工作环境**：上下文加载规则、工具清单、执行流程、验证标准、记忆机制、错误处理。

这个观察与 OpenAI 2026 的 *GAN-style agent loops*、Martin Fowler 的 *The AI agent workflow we found that works*、Red Hat 的 *Multi-agent engineering for real codebases* 等多家研究指向同一个结论：

**同样的模型，harness 做得好 vs 做得差，输出质量可以差一个数量级。**

于是诞生了一个新的工程角色：**Harness Engineer**——不是写业务代码的人，而是设计 AI 工作环境的人。他的 KPI 不是"今天写了多少行代码"，而是"团队的 AI 平均自愈轮次、首次通过率、Evaluator 评分有没有提升"。

本仓库就是朝着"让项目里任何一个开发者都能把 Claude 当成一位懂规矩的 Harness Engineer"而设计的。

---

## 二、三条核心信念

所有命令、所有约束、所有文件布局，都源自下面三条。拿不准要不要加新规则时，先问它们。

### 信念一：AI 是"有边界的实习生"，不是"资深工程师"

一位聪明但刚入职第三天的实习生：
- 你给他**越清楚的规矩**、**越严格的检查清单**、**越明确的"不许做什么"**，他干得越好。
- 你给他"自由发挥空间"，他会**把半个模块重构掉**。

推论：
- `CLAUDE.md` 要写"不许做什么"，而不只是"推荐做什么"。
- `red-lines.md` 必须是一等公民，不是建议。
- 每条验证必须**可机械执行**，"看起来没问题"不算通过。
- 完成判定用**客观断言**（tasks.yaml 的 `verify`），不是"你觉得做完了吗"。

### 信念二：红线（硬约束）不可协商

一个 harness 里最危险的东西不是"bug"，是"**漏掉的红线**"。
- 一个被默许的 `catch (Exception e) {}` 最终会变成线上半夜起床查问题的那次事故。
- 一次被放行的"硬编码魔法值"最终会变成 6 个月后没人敢改的屎山。

推论：
- 红线**不是口头文化**，必须落到文件里（`red-lines.md`）。
- 红线不是"review 时才检查"，必须在 `/impl`、`/review`、`/preflight`、`/adversarial-review` 四道闸口都检查。
- 红线违反**直接 Reject**，不进入"扣分讨论"。

### 信念三：个人经验必须流回，变成团队资产

一个人踩过的坑，三天后另一个人不能再踩。否则 AI 再强也帮不了这个团队——它不知道你们踩过什么。

推论：
- `journal.md` 是**跨 session** 的工作记忆（一个人跟自己接力）。
- `knowledge/` 是**跨开发者**的团队记忆（个人经验沉淀成规则）。
- "Spec 自迭代"是强需求：`/impl` 和 `/review` 发现没覆盖的知识点必须**主动建议追加**。
- `/metrics` 是**Harness Engineer 的驾驶舱**——没有数字，无从判断 knowledge 在不在起作用。

---

## 三、三个角色的心智模型

Anthropic 的研究把多 agent 系统拆成三个角色：**Planner / Generator / Evaluator**。本 harness 的命令都能对应到某一个角色：

```
Planner（拆解任务）       Generator（落实代码）      Evaluator（挑毛病）
├── /iterate              ├── /impl                   ├── /review
├── /design               ├── /run-tasks              ├── /adversarial-review
└── /init-baseline                                    └── /preflight
                                          
                           （跨角色观测）
                               ↓
                           /metrics
```

为什么要分三个？因为 **AI 对自己的输出有偏爱**。

让同一个 agent 既写又审，它会倾向于认为"我写的是对的"——这是 Anthropic 研究里反复强调的 self-rating bias。所以本 harness 强制：

- `/review` = Generator 的自审（同 context，发现浅层问题）
- `/adversarial-review` = **独立 Evaluator**（新 session、不加载 journal、不加载实现 knowledge、默认怀疑、不许满分）

这不是加一个命令，是把"代码是不是真的好"这件事**从主观感觉变成结构化过程**。

---

## 四、几个非显然的设计决定

### 为什么要有 `tasks.yaml`？checklist.md 不够吗？

checklist.md 是给人看的（打勾、讨论、交接）；
tasks.yaml 是给机器执行的（`verify` 断言跑一次看 exit code）。

只有 checklist.md 时，"完成"这个状态是人类主观判断的（"我觉得做完了"），这正是 Anthropic 研究指出的 *premature closure*（过早宣称完成）。
加了 tasks.yaml 之后，完成必须满足 `cmd / file_contains / http / sql / e2e / regression` 全部返回绿，才算真的完成——**完成标准从自觉变成合约**。

### 为什么 `/impl` 是唯一入口？

因为开发者不应该被命令表拷问。大任务/小任务的边界由 AI 自己判断（自动转入 `/iterate` 或直接执行），人只管描述要做什么。
这让新人上手成本从"学 10 个命令"变成"学一个 `/impl`"。

### 为什么 `/adversarial-review` 必须新开 session？

因为 context 一旦被 Generator 的思路污染（journal、中间讨论、实现选择），Evaluator 会自动**继承这些思路**，哪怕你嘴上要它怀疑。
解决办法不是"更聪明的 prompt"，是**物理隔离**——开新 session，只加载 diff + design + red-lines + tasks.yaml 的 `verify`。

### 为什么 knowledge 要分层按需加载？

上下文窗口是最稀缺的资源。当 `/impl` 处理后端任务时，前端知识（比如 Taro 小程序规范）**不仅没用，还会诱导 AI 产生幻觉**（写出"综合"了两端风格的奇怪代码）。
所以 `.claude/knowledge/` 分层，每个命令按角色只加载需要的那部分。这是"给 AI 聚焦"的第一性原理。

### 为什么 `/metrics` 要进硬约束的报告格式，而不是让 AI 自由总结？

"AI 最近变笨了没？"这个问题是 vibes-based。
`/metrics` 要回答的是"首次通过率从 61% 升到 67%"、"taro-patterns.md 30 天零命中"、"OrderService 并发问题被 Evaluator 指出 4 次"——**数字，不是感觉**。
没有数字，就没法决定"这条 knowledge 是不是该删"、"这个红线执行得好不好"、"这个 sprint 的 harness 有没有进步"。

---

## 五、这套 Harness **不追求**的事情

同样重要：知道不该做什么。

- **不追求"AI 能完全自主完成任何任务"**：
  真实世界里总有 5-15% 的任务需要人介入（环境问题、产品决策、设计冲突）。Harness 的目标是"**降低**人工介入率"，不是"消灭"。
  拒绝"全自动"的空头承诺，是对团队的诚实。

- **不追求"命令越多越好"**：
  每多一个命令都是认知负担。只有在"这件事如果不固化成命令，就会反复出错"时才加命令。
  最近一次加命令的动机是 *adversarial self-rating bias*，是**来自研究的刚需**，不是"好像很酷"。

- **不追求"一套 harness 适用所有项目"**：
  DDD 后端的红线和一个纯前端小程序的红线完全不同。`red-lines.md`、`knowledge/` 应该在每个项目独立进化。
  Harness **是可演化的活文档**，不是固定的框架。

- **不追求"Evaluator 完美打分"**：
  Evaluator 只负责"挑出必须修的问题"。它不是质量的**终审法官**，是"在交付前再筛一次的滤网"。
  真正的终审永远是线上用户。

---

## 六、可演化方向

这套 harness 的当前版本覆盖了：
- ✅ 上下文分层加载
- ✅ 机器可验证的完成标准（tasks.yaml）
- ✅ 独立 Evaluator（adversarial-review）
- ✅ 跨 session 记忆（journal）
- ✅ 知识沉淀闭环（spec 自迭代）
- ✅ 可观测性（metrics、/dashboard）
- ✅ **并行 Worker**（`/run-tasks --parallel N`）——见下方 6.1
- ✅ **Oracle 模式**（`/adversarial-review --oracle`）——见下方 6.2

接下来值得探索的方向（未实现、留给后续迭代）：
- **基于 code-review-graph 的精确回归**：只跑受影响的测试（blast radius），而不是全量
- **Harness A/B**：同一任务在两套 knowledge 下各跑一次，看哪套产出更好，用数据优化 knowledge
- **Oracle 的 N>2 推广**：当三个 Evaluator 也有用时引入 majority-of-3（目前 strict-AND 更合适，等有数据支持再说）

### 6.1 并行 Worker 的设计权衡

**为什么用 git worktree 而不是多个 Claude Code session**：
- worktree 真正隔离文件系统和 git index，多个 Worker `git add/commit` 不会互相踩
- 同一个 repo 的 `.git/` 目录是共享的，节省磁盘 + 加速
- 每个 Worker 是子 shell 进程，失败/超时不会拖累其他

**为什么按 `depends_on` 分波，不是直接 N 并发**：
- 违反依赖关系的并发会导致上游未完成时下游已经基于过时代码开工
- 分波后"同一波内的任务互不依赖"这个不变式最简单，也最容易验证
- 代价：任务 DAG 扁平的项目收益最大，线性依赖的项目几乎退化为串行

**为什么合并用 ff-only 而不是 merge commit**：
- ff-only 保持线性历史，方便 `git revert` 单任务精准回滚（这是 Harness 的核心价值之一）
- 如果 ff-only 失败（意味着下游 worker 的 diff 和上游冲突），**必须进入自愈循环**——冲突本身就是设计问题的信号，不能用 `--no-ff` 盖住
- 合并顺序 = 拓扑序 ≠ 完成顺序，保证最终 commit 序列有意义

**并行 Worker 不解决的问题**：
- 不解决"任务粒度太粗"——大任务拆不动就是拆不动，并行只放大串行瓶颈
- 不解决"测试互相污染"——共享 DB 的测试并行跑仍会炸；如果你的测试有 `@DirtiesContext`，并行 N 要按项目可承受的并发上限调低
- 不替代 `/iterate` 的影响分析——影响分析是给人看的"这次改会动到哪"，并行 Worker 是给机器用的"怎么调度这些任务"

### 6.2 Oracle 模式的 strict-AND

**为什么 strict-AND 而不是 majority / OR**：
- OR（任一 Approve 即过）会让模型的"给过偏好"被放大——两 Evaluator 中有一个被骗就过
- majority-of-2 没有意义（2 个里多数就是 2 个，等价于 AND）
- AND（两个都 Approve 才过）天然抑制 false-positive，代价是偶尔 false-negative（会误拒），这对关键路径是**正确的倾向**

**为什么要差异化 Evaluator 人格**：
- 如果两个 Evaluator 系统提示词一样，它们大概率会给高度相关的分——本质上还是同一个 Evaluator 跑两遍
- 差异化（A 偏规范、B 偏反例）让两者的盲区错开，AND 的信号才真实
- 人格差异不是重新定义评分标准，4 维度权重保持一致，只调"看问题的切入点"

**为什么分差 > 15 要标 disagreement 而不是自动再找个第三方**：
- 引入第三方会让 strict-AND 退化为 2/3 majority，**失去严格性**
- 分差大本身就是重要信号——真正的价值是告诉人类"这里两个独立视角意见不一，值得你亲自看一眼"
- Harness 的核心价值不是替代人类，是**让人类把注意力放在真正需要的地方**

**Oracle 不解决的问题**：
- 不能让"烂代码变好"——两个 Evaluator 都漏掉的问题 Oracle 一样漏
- 不能补救"tasks.yaml 断言不足"——断言缺失的功能维度，评分再准也抓不出来
- 不是质量的终审——线上用户才是，Oracle 只是最后一层滤网

---

## 七、一句话总结

> **这个 harness 的核心不是"AI 工具集"，是"让团队经验和质量标准变成可执行代码"。**
>
> AI 是执行引擎，harness 才是规则。规则越清晰，AI 越能干。
> 而规则本身是可演化的——这才是 Harness Engineering 真正的工作。

---

## 参考

- Anthropic, *Effective harnesses for long-running agents*, 2026
- OpenAI, *GAN-style agent loops for code generation*, 2026
- Martin Fowler, *The AI agent workflow we found that works*, 2026-03
- Red Hat Research, *Multi-agent engineering for real codebases*, 2026
- Anthropic, *2026 Trends in Software Development With AI*
