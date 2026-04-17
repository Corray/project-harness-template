# Project Harness Template

项目仓库的 AI 辅助开发 Harness 模板。集成了分层 Knowledge、Workspace Journal、Task Checklist 和 Spec 自迭代机制。

## 快速开始

```bash
# 1. 将模板文件复制到你的项目仓库
cp -r .claude/ CLAUDE.md docs/ your-project-repo/

# 2. 初始化基线（会自动填充 knowledge 和 project.yaml）
cd your-project-repo && claude
/init-baseline "你的产品简介"

# 3. 补充 project.yaml 和 knowledge 中的人工字段
# 4. 提交
git add CLAUDE.md .claude/ docs/
git commit -m "harness: init project harness"
```

## 命令速查

**日常只需记住一个命令：`/impl "{描述}"`**

AI 自动判断复杂度：小任务直接做完（编码→测试→commit），大任务自动转 /iterate。

| 命令 | 用途 | 触发方式 |
|------|------|---------|
| `/impl` | **唯一入口** — AI 自动评估 + 全自动执行 | 开发者手动 |
| `/iterate` | 大任务影响分析 + 任务清单 | /impl 自动触发 |
| `/design` | 生成详细设计 | /iterate 后手动 |
| `/run-tasks` | 批量循环执行 checklist | /iterate 后手动 |
| `/init-baseline` | 首次接入，生成基线 | 手动（一次性） |
| `/review` | 结构化校验 | /run-tasks 自动触发 |
| `/preflight` | 提交前检查 | 手动 |
| `/record-session` | 会话记录 | /run-tasks 自动触发 |
| `/spec-feedback` | 记录设计问题 | 手动 |

## 与 ai-workflow 的关系

```
ai-workflow（集中式）                 项目仓库（分散式）
├── 0-1 新项目共识文档                ├── /init-baseline 基线 + knowledge 初始化
├── 规则优化 eval/update-rules        ├── /iterate 迭代共识 + 任务清单
└── Knowledge 源文件                  ├── /design 详细设计（按需加载 knowledge）
                                      ├── /impl + /review（journal + spec 自迭代）
                                      ├── /test-gen + /preflight
                                      └── /record-session 会话记录
```
