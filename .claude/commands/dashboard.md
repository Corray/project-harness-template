# /dashboard — 跨项目 Harness 看板

聚合 `~/.claude/harness-projects.yaml` 里所有注册项目的 metrics 与 adversarial-review 数据，生成单页 HTML 看板，左侧列项目、右侧切换四个 Tab（指标 / Knowledge / 对抗评估 / 最近 impl）。

## 用法

```
/dashboard                    # 生成后打印路径
/dashboard --open             # 生成后用浏览器打开
/dashboard --days 60          # 指标窗口默认 30 天，可自定义
```

## 执行步骤

### Step 1：检查前置条件

1. `~/.claude/harness-projects.yaml` 存在？不存在则提示：
   > 还没有注册任何项目。在项目根目录跑一次 `setup.sh` 或 `upgrade.sh` 会自动注册。
2. `~/.claude/harness-dashboard/build.py` 存在？不存在则报错并提示：
   > build.py 未安装。从模板仓库跑一次 `setup.sh` / `upgrade.sh` 即可安装。

### Step 2：运行聚合脚本

```bash
python3 ~/.claude/harness-dashboard/build.py
```

加 `--open` 时追加 `--open`。

脚本会打印每个项目的概览（impl 数量或"路径不存在"）。遇到 Python 不可用的话退化到提示用户装 Python 3。

### Step 3：打印结果

```
✅ Dashboard 已生成：~/.claude/harness-dashboard/dashboard.html
   项目数：{N}
   · {项目1}：impl(30d)={M}
   · {项目2}：⚠️ 项目路径不存在：...

用浏览器打开：open ~/.claude/harness-dashboard/dashboard.html
或重跑：/dashboard --open
```

### Step 4（可选）：项目路径失效提示

如果聚合脚本返回了"路径不存在"的项目，主动询问：
> 检测到 {N} 个注册项目的路径已失效，是否从 `~/.claude/harness-projects.yaml` 中移除？

开发者确认 Y 后：
1. 读取 yaml
2. 过滤掉 `path` 不存在的条目
3. 写回 yaml
4. 提示已清理

---

## 数据源

看板从每个项目的以下位置聚合数据（`docs/workspace/.harness-metrics/` 就是 `/metrics` 和 `/impl` 回写的事件流）：

| 文件 | 来源命令 | 用途 |
|------|---------|------|
| `impl/*.jsonl` | `/impl`、`/run-tasks` 子任务 | 首次通过率、自愈轮次、人工介入率、14 天趋势、最近事件时间线 |
| `adversarial/*.jsonl` | `/adversarial-review` | 对抗评估分数、Must-Fix 数、Reject 原因 |
| `run-tasks/*.jsonl` | `/run-tasks` | 时间线合并 |
| `knowledge-hits/*.jsonl` | `/impl` Step A、`/review` 加载 knowledge 时 | Top 15 命中、30 天零命中清单 |

项目列表来源：`~/.claude/harness-projects.yaml`，结构：

```yaml
version: 1
projects:
  - name: my-backend
    path: /Users/you/workspace/my-backend
    type: harness-workflow          # 或 project-harness-template
    registered_at: 2026-04-22
  - name: my-frontend
    path: /Users/you/workspace/my-frontend
    type: project-harness-template
    registered_at: 2026-04-23
```

## 看板内容

**指标 Tab：**
- 30 天 impl 总数
- 首次通过率（健康 >60%）
- 平均自愈轮次（健康 <1.2）
- 人工介入率（健康 <15%）
- 14 天首次通过率趋势折线图（Chart.js）

**Knowledge Tab：**
- 30 天命中 Top 15（横向柱状图）
- 30 天零命中清单（删除候选 / 迁移候选）

**对抗评估 Tab：**
- 时间倒序列出每次 `/adversarial-review`：分支、总分、Must-Fix、结论（approve/conditional/reject）、Reject 原因

**最近 impl Tab：**
- 最近 50 条 impl 事件：时间、开发者、任务描述、大小、角色、自愈轮次、耗时、commit 短哈希、红线触发标记

## 失败处理

- 项目路径不存在 → 项目卡片显示 ⚠️，其他项目正常显示
- 某个 jsonl 格式损坏 → 脚本跳过损坏行，不整体失败
- 没有任何数据 → 卡片显示"暂无数据"而非报错
