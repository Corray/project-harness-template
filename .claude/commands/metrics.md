# /metrics — Harness 运行指标聚合（驾驶舱）

> 把"AI 在我们仓库干得怎么样"从感觉变成数字。
> 这是 Harness Engineer 角色最核心的工具——没有度量就没有改进。

## 为什么需要

日常你会感觉"最近 AI 变笨了"或"这个 knowledge 好像没用"，但**感觉不可靠**。真正的 Harness Engineering 需要回答：

- 过去 30 天 `/impl` 任务平均自愈几轮？有没有变多？
- 哪些 knowledge 文件被引用最频繁？（= 真正有价值）
- 哪些 knowledge 文件几乎没命中过？（= 该删或该重写）
- 哪些红线被最常触发？（= 可能要提到更上游）
- Evaluator 的平均评分是涨还是跌？
- 哪些任务类型的首次通过率最低？（= 该增强哪块 knowledge）

`/metrics` 聚合 `journal.md` + `.harness-metrics/` 下的结构化日志，回答这些问题。

## 用法

```
/metrics                                  # 默认：过去 30 天全员汇总
/metrics --days 7                         # 过去 7 天
/metrics --since 2026-03-01               # 指定起始日期
/metrics --developer alice                # 单个开发者视角
/metrics --sprint 2026-04-scene-type      # 单个 sprint 视角
/metrics --format csv                     # 导出 CSV（默认 markdown 表格）
/metrics --format json > metrics.json     # 导出 JSON
/metrics --compare "30d vs previous 30d"  # 环比对照
```

## 数据来源

```
docs/workspace/
├── {developer}/journal.md                # /impl 完成时追加的结构化条目
└── .harness-metrics/                     # 机器可读的事件流（推荐新写入用这里）
    ├── impl/                             # /impl 事件
    │   └── 2026-04-*.jsonl
    ├── adversarial/                      # /adversarial-review 事件
    │   └── 2026-04-*.jsonl
    ├── run-tasks/                        # /run-tasks 事件
    │   └── 2026-04-*.jsonl
    └── knowledge-hits/                   # knowledge 加载命中记录
        └── 2026-04-*.jsonl
```

**过渡策略**：老的 journal.md 仍可被解析（从 "### 做了什么"、"### 测试"、"### Commit" 等小节提取），新写入的命令应同时写 `.harness-metrics/` 的 jsonl 以获得更精确的数据。

## 事件 schema（新命令应写入的格式）

### impl 事件（每次 /impl 完成写一条）

```jsonl
{
  "time": "2026-04-22T15:30:00Z",
  "developer": "alice",
  "task_desc": "修复订单列表分页重复",
  "task_size": "small",             // small | large(→iterate)
  "role": "backend",
  "files_changed": 3,
  "tests_added": 2,
  "heal_cycles": 1,                 // 自愈轮次
  "first_pass": false,              // 是否一次通过
  "human_intervention": false,      // 是否被打断
  "intervention_reason": null,      // 3_rounds_failed | env_issue | manual_op | spec_issue | large_task
  "commit_hash": "abc1234",
  "duration_minutes": 12,
  "knowledge_loaded": ["backend/api-conventions.md", "red-lines.md"],
  "knowledge_updated": ["backend/sxp-framework.md"],
  "red_lines_triggered": []
}
```

### adversarial-review 事件

```jsonl
{"time":"...","sprint":"...","score":78,"dim_a":24,"dim_b":20,"dim_c":22,"dim_d":12,"assertions_total":7,"assertions_failed":1,"must_fix":2,"should_fix":2,"verdict":"approve-with-fix"}
```

### run-tasks 事件（每批循环写一条汇总）

```jsonl
{"time":"...","sprint":"...","role":"backend","tasks_total":5,"tasks_completed":5,"tasks_skipped":0,"total_heal_cycles":3,"branch":"feature/...","commits":5,"duration_minutes":47}
```

### knowledge-hits 事件（每次命令加载 knowledge 写一条）

```jsonl
{"time":"...","command":"/impl","file":"backend/api-conventions.md","bytes_loaded":2450}
```

## 执行流程

### Step 1：确定时间窗口

从参数解析 `--days / --since / --sprint`，缺省过去 30 天。

### Step 2：收集数据

1. 优先读 `.harness-metrics/*/*.jsonl`（结构化，快）
2. 对于时间窗口内 jsonl 未覆盖的部分，fallback 到解析 `journal.md`：
   - 按 `## YYYY-MM-DD HH:MM — {任务简述}` 切分条目
   - 提取"文件变更"、"测试"、"自愈 N 轮"、"Commit"、"遗留"
   - 尽力而为，无法解析的字段留 null

### Step 3：计算指标

#### 3.1 吞吐量

| 指标 | 计算 |
|------|------|
| 完成任务总数 | impl events count |
| 总 commit 数 | 去重 commit_hash |
| 文件变更总数 | sum(files_changed) |
| 新增测试总数 | sum(tests_added) |
| 人均任务 | 按 developer 分组 |

#### 3.2 质量

| 指标 | 计算 | 健康区间 |
|------|------|---------|
| 首次通过率 | `first_pass=true` / total | >60% |
| 平均自愈轮次 | mean(heal_cycles) | <1.2 |
| 自愈 3 轮失败率 | `intervention_reason=3_rounds_failed` / total | <5% |
| 人工介入率 | `human_intervention=true` / total | <15% |
| Evaluator 平均分 | mean(adversarial.score) | >80 |
| Evaluator 否决率 | `verdict=reject` / total | <5% |

#### 3.3 Knowledge 有效性

| 指标 | 说明 |
|------|------|
| Top 10 命中 knowledge | 按文件降序 |
| 零命中 knowledge | 整个窗口内 0 次命中（建议删除或重写） |
| knowledge 更新频率 | 每周新增/修改的 knowledge 条目 |
| 同一坑被重复指出 | adversarial 报告中相似扣分理由出现 ≥3 次 |

#### 3.4 红线

| 指标 | 说明 |
|------|------|
| 红线触发 TOP 5 | 哪些规则最容易被违反 |
| 红线触发下降趋势 | 周环比变化 |

#### 3.5 分布分析

- 任务 size 分布（small / large 比例）
- 按 role 分布（backend / frontend / test）
- 自愈轮次直方图
- 人工介入原因分布

### Step 4：输出报告

默认 markdown 格式，结构化展示：

```markdown
# Harness Metrics 报告

**窗口**：2026-03-23 ~ 2026-04-22（30 天）
**开发者**：alice, bob, charlie（3 人）
**Sprint**：2026-04-scene-type, 2026-04-template-refactor（2 个）

---

## 一、吞吐量概览

| 指标 | 数值 | 环比（vs 前 30 天） |
|------|-----|-------------------|
| 完成任务 | 127 | ↑ 18% |
| 总 commit | 134 | ↑ 12% |
| 人均任务/周 | 10.6 | ↑ 0.8 |
| 平均任务耗时 | 14 min | ↓ 2 min |

## 二、质量指标

| 指标 | 本期 | 上期 | 健康区间 | 状态 |
|------|-----|-----|---------|------|
| 首次通过率 | 67% | 61% | >60% | ✅ 正常 |
| 平均自愈轮次 | 0.9 | 1.3 | <1.2 | ✅ 改善 |
| 人工介入率 | 11% | 14% | <15% | ✅ 正常 |
| Evaluator 平均分 | 82 | 79 | >80 | ✅ 正常 |
| Evaluator 否决率 | 3% | 4% | <5% | ✅ 正常 |

## 三、Knowledge 有效性

### 🏆 TOP 10 最有价值 knowledge（命中次数）

1. `red-lines.md` — 127 次（100% 命令加载）
2. `backend/api-conventions.md` — 45 次
3. `backend/sxp-framework.md` — 38 次
4. `backend/architecture.md` — 34 次
5. ...

### 🚮 建议删除或重写（零命中）

- `frontend/taro-patterns.md` — 30 天内 0 次命中
  → 可能：项目不用 Taro / 命令加载规则错了 / 内容过时

### 🔁 重复痛点（adversarial 多次指出）

- **"OrderService 并发问题"** — 在 4 次 adversarial 报告中被指出
  → 建议：追加到 `knowledge/backend/concurrency-patterns.md`
- **"Repository 层 Mock 过度"** — 在 3 次 adversarial 报告中被指出
  → 建议：在 `knowledge/testing/standards.md` 补充示例

## 四、红线触发

### 本期触发 TOP 5

| 红线 | 触发次数 | vs 上期 |
|------|---------|--------|
| 硬编码魔法值 | 12 | ↓ 5 |
| tenant_id 字段缺失 | 8 | ↑ 3 |
| API 未带版本前缀 | 5 | ↓ 2 |
| ...

**⚠️ 值得关注**：tenant_id 字段缺失上升 3 次 —— 建议在 `/design` 的检查清单中加入显式核对。

## 五、分布分析

### 任务 size 分布
- small（/impl 直接执行）：91 个（72%）
- large（转入 /iterate）：36 个（28%）

### 人工介入原因
- 环境问题：8 次（57%）
- 自愈 3 轮失败：4 次（29%）
- 需人工操作：2 次（14%）
- 设计问题：0 次 ✅

## 六、本期要点和建议

基于数据，自动生成的行动项（按价值排序）：

1. 🔴 **删除零命中 knowledge**：`frontend/taro-patterns.md`（30 天 0 次命中）
2. 🟡 **沉淀重复痛点**：把"OrderService 并发"和"Repository Mock 过度"写入对应 knowledge
3. 🟡 **核对 tenant_id 红线执行**：最近 8 次触发，环比上升
4. 🟢 **继续关注首次通过率**：67% 已达标但离业界 75% 还有空间
```

### Step 5：写入历史快照

把本次报告存档到 `docs/workspace/.harness-metrics/snapshots/{YYYY-MM-DD}.md`，便于未来做长周期趋势分析。

## 实现注意事项

1. **journal 解析要容错**：旧 journal 格式不完全规整，无法解析的字段用 `null`，不要因为一条坏数据中断整个报告
2. **knowledge 命中统计**：需要 `/impl`、`/review`、`/design` 等命令在加载 knowledge 时主动写 `knowledge-hits/` 事件。过渡期没有这部分数据时，标注"数据不足，建议在新版命令中启用事件写入"
3. **Evaluator 数据**：依赖 `/adversarial-review` 写入 `.harness-metrics/adversarial/`。如果团队还没开始用 adversarial-review，这部分指标会标注"未启用"
4. **多 developer 聚合**：默认全员聚合但会输出"按人分组"的次级 section（可选，用 `--by-developer` 触发）

## 硬约束

1. **只读，不改代码**：`/metrics` 仅生成报告，任何建议都是建议，不自动执行
2. **数据为空不伪造**：任何指标缺数据时明确标注"数据不足"，禁止用估算填充
3. **不做诊断结论**：只列数据 + 可能解读方向，最终判断交给 Harness Engineer

---

## 整体流程图

```
/metrics [--days N | --sprint X | --developer Y]
  │
  ├── 收集 .harness-metrics/*.jsonl（优先）
  ├── fallback 解析 journal.md
  │
  ├── 计算：吞吐量 / 质量 / Knowledge 有效性 / 红线 / 分布
  │
  ├── 输出 markdown 报告（含环比、健康区间标注）
  │
  └── 存档到 .harness-metrics/snapshots/
```
