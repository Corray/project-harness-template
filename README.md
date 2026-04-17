# Project Harness Template

> Claude Code 驱动的 AI 辅助开发 Harness，开箱即用。

将分层 Knowledge、结构化工作流、会话记忆和知识自迭代集成到任意项目仓库。开发者只需记住一个命令 `/impl`，AI 自动评估复杂度并执行——小任务全自动化，大任务结构化推进。

## 快速开始

```bash
# 方式一：安装脚本（推荐）
cd your-project-repo
bash /path/to/project-harness-template/setup.sh

# 方式二：手动复制
cp -r project-harness-template/.claude project-harness-template/CLAUDE.md project-harness-template/docs/ your-project-repo/
```

安装完成后：

```bash
cd your-project-repo
claude
/init-baseline "你的产品简介"
```

`/init-baseline` 会扫描项目生成基线文档、填充 knowledge 和 `docs/project.yaml`。之后补充 `project.yaml` 中 `[人工]` 标注的字段，提交即可。

## 命令速查

日常只需记住 **`/impl "{描述}"`**：

```
/impl "修复 xxx"       → 小任务自动编码→测试→commit
/impl "新增 xxx 体系"  → 大任务自动转入 /iterate → /design → /run-tasks
```

| 命令 | 用途 | 触发方式 |
|------|------|---------|
| `/impl` | **唯一入口** — 自动评估复杂度并执行 | 手动 |
| `/iterate` | 大任务影响分析 + 任务清单 | /impl 自动触发 |
| `/design` | 生成详细设计文档 | 手动 |
| `/run-tasks` | 批量循环执行 checklist 任务 | 手动 |
| `/init-baseline` | 首次接入，生成项目基线 | 手动（一次性） |
| `/review` | 结构化代码校验 | /run-tasks 自动触发 |
| `/test-gen` | 基于设计契约生成测试 | 手动 |
| `/preflight` | 提交前全面检查 | 手动 |
| `/record-session` | 会话成果记录（journal + knowledge） | 自动触发 |
| `/spec-feedback` | 记录设计文档问题 | 手动 |

## 核心机制

### Knowledge 分层加载

`.claude/knowledge/` 按领域分目录，命令执行时按需加载，不浪费上下文窗口：

```
.claude/knowledge/
├── backend/          # DDD/MVC 架构、API 约定、sxp-framework
├── frontend/         # React+antd、Taro+Vant
├── testing/          # 测试标准和覆盖要求
└── red-lines.md      # 质量红线（通用）
```

### Workspace Journal

`docs/workspace/{developer}/journal.md` 是跨 session 的工作记忆——`/impl` 完成时自动追加，新 session 自动读取最近记录，无需重复解释上下文。

### Spec 自迭代

开发中发现 knowledge 未覆盖的技术点时，Claude 会在会话结束前建议更新对应的 knowledge 文件，将个人经验沉淀为团队资产。

### 需求来源

- **TAPD**：通过 MCP 读取需求卡片和 Bug 单
- **GitHub Issue**：通过 MCP 读取 Issue 及评论
- **手动输入**：直接描述需求

## 文档结构

```
docs/
├── baseline/          # 项目基线（/init-baseline 生成）
├── consensus/         # 迭代共识文档（/iterate 生成）
├── design/            # 详细设计（/design 生成）
├── tasks/             # 任务追踪
│   └── {sprint}/
│       ├── iterate-consensus.md
│       └── checklist.md
├── feedback/          # 设计文档反馈
├── workspace/         # 开发者工作日志（按人隔离）
│   └── {name}/journal.md
└── project.yaml       # 项目元信息
```

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

## 可选增强

### Code Review Graph

安装 [code-review-graph](https://github.com/tirth8205/code-review-graph) 后，`/iterate`、`/impl`、`/review` 等命令自动获得精确的代码结构分析（blast radius 计算、调用链追踪、风险评分），不可用时退回基线文档 + 代码扫描。

```bash
pip install code-review-graph
# 在 ~/.claude/settings.json 中配置 MCP
cd your-project && code-review-graph build
```

### 环境变量

按需配置以下环境变量以启用对应集成：

```bash
export TAPD_ACCESS_TOKEN="xxx"       # TAPD 需求/Bug
export GITHUB_TOKEN="ghp_xxx"        # GitHub Issue/PR
export FIGMA_API_KEY="figd_xxx"      # Figma 设计稿
```

## 模板内容

本仓库包含以下可安装到目标项目的文件：

```
project-harness-template/
├── CLAUDE.md                # AI 行为指令（项目级）
├── setup.sh                 # 一键安装脚本
├── docs/
│   ├── project.yaml         # 项目元信息模板
│   └── */.gitkeep           # 目录骨架
└── .claude/
    ├── commands/             # 10 个自定义命令
    │   ├── impl.md           # 唯一任务入口
    │   ├── iterate.md        # 迭代影响分析
    │   ├── design.md         # 详细设计
    │   ├── run-tasks.md      # 批量任务执行
    │   ├── init-baseline.md  # 基线初始化
    │   ├── review.md         # 代码校验
    │   ├── test-gen.md       # 测试生成
    │   ├── preflight.md      # 提交前检查
    │   ├── record-session.md # 会话记录
    │   └── spec-feedback.md  # 设计反馈
    └── knowledge/            # 分层知识库模板
        ├── backend/          # 后端架构规范
        ├── frontend/         # 前端开发规范
        ├── testing/          # 测试标准
        └── red-lines.md      # 质量红线
```
