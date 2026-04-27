# 质量红线

> 所有角色通用。/impl、/review、/preflight 均加载此文件。
> 可根据项目实际情况微调，但核心红线不建议放松。

## 数据库红线

### MongoDB
- 必须明确 Collection 的文档结构
- 必须明确索引策略
- 必须说明嵌套 vs 引用的设计决策理由

### MySQL
- 必须考虑索引
- 必须有 created_at 和 updated_at 字段
- 大表设计需考虑分页和慢查询优化

### Elasticsearch
- 必须明确 Index 的 Mapping 设计
- 必须明确分词器选择

## 基础架构红线

- 所有核心实体必须包含 tenant_id 字段（即使 MVP 阶段只有默认租户）
- 所有核心实体必须包含 deleted_at 字段用于软删除
- 所有核心实体必须包含 created_at 和 updated_at 字段
- 所有第三方服务调用必须通过 Gateway 接口，禁止直接调用第三方 SDK
- 所有异步业务操作必须通过领域事件发布
- API 路由必须带版本前缀（如 /api/v1/）
- User 和 UserAuth 必须分离存储

## 通用编码红线

- 不允许硬编码魔法值，必须使用常量或枚举
- JDK 11 项目不得使用 JDK 11 以上语法特性
- JDK 21 项目优先使用现代语法
- 所有对外接口必须考虑异常处理和错误码定义
- API 必须考虑参数校验、权限控制、幂等性

## 前端通用红线

- TypeScript 项目不允许使用 any
- Taro 项目不得使用 Web DOM API
- 严格使用对应产品形态的 UI 组件库，不得混用
- 组件库已提供的组件不得自行重写

## 多 Agent 协作红线

> 详细规范见 `collaboration.md`。以下为**硬约束**，触发即 Reject。

**19. 禁止用破坏性命令清理陌生 WIP**
碰到工作树里陌生的未提交改动、陌生的 stash、来源不明的 reflog 条目，**禁止**：
- `git checkout .` / `git checkout -- <file>` 丢改动
- `git clean -fd` / `git clean -fdx`
- `git reset --hard HEAD`
- `rm -rf .git` / `rm -rf <任何看起来"脏"的目录>`

**正确做法**：`git stash push -m "others-wip-possibly-from-agent-X"` 带标识暂存，再查 reflog / 联系人 / 开 worktree 隔离。破坏性操作会直接毁掉对方 agent 数小时的工作。

**20. 改完立即 commit（小原子单位）**
不追求"先跑完全套测试再 commit"。每个小原子改动改完立即 commit，理由：
- 缩短"未 commit 窗口"——这个窗口是多 agent 协作时最容易被对方误伤的时段
- commit 本身就是 checkpoint，测试失败时 `git reset --soft HEAD^` 比"从未 commit 状态恢复"安全得多
- 符合 `/run-tasks` 和 `/impl` 的"每任务一 commit"节奏

**21. 启动任何工作前跑并发冲突自检**
新 session / `/impl` 侦察 / `/run-tasks` Step B 必须跑：
```bash
git status --porcelain
git stash list
git reflog -n 10
```
任一命中异常信号必须暂停问人，不得自作主张处理。

## 数据库 MCP 红线

> 真实 DB 通过 MCP 连接（`mysql-*` / `mongo-*`）时强制只读。`.claude/hooks/db-readonly-guard.py` 是 PreToolUse hook，写操作在到达 MCP 之前就被 deny。**该 hook 是硬约束的兜底，不可禁用。**

**22. DB MCP 凭据必须是只读账号** — `.mcp.json` 里 `mysql-*` / `mongo-*` server 引用的 env var 必须指向只读账号（MySQL: 仅 SELECT；MongoDB: 仅 read role）。即使 hook 拦了写操作，如果账号本身有写权限，也属于配置违规，PR review 直接 Reject。

**23. db-readonly-guard.py 不可禁用 / 修改放行规则** — 任何尝试在 `.claude/settings.json` 移除该 hook、或在 hook 脚本里把 INSERT/UPDATE/DELETE 等加进白名单的 PR，必须 Reject。

**24. 写测试只能走 docker** — 测试需要写 DB 时，`.claude/dbs.yaml` 里 `test_db_strategy` 必须是 `docker`（用 docker-compose 起本地一次性 DB），**不能**走真实 DB MCP。强行走 MCP 会被 hook 拦死。

**25. 绕过 hook 的尝试视为红线违反** — 直接 shell 调 `mysql` / `mongosh` 命令绕过 MCP 进行写操作，等同于绕过红线，PR Reject。如确实需要写真实库，由人手动操作并在 journal 中显式记录。

## Jenkins 构建红线

> `.claude/jenkins.yaml` 是 /impl Step 7 和 /run-tasks Step 7 的输入。配置不当会让 Claude 误触发生产部署或 hang 住等待。

**26. deploy 阶段默认 `wait: false`** — `.claude/jenkins.yaml` 的 stages 中，名字含 deploy / publish / release / push 等部署语义的阶段必须 `wait: false`（触发完就走，不等结果）。强制同步等待 deploy 会导致 /impl 长时间 hang，严重影响开发体感。如确需同步，必须在 PR 描述中显式说明原因。

**27. Jenkins MCP 凭据 token 必须最小权限** — `JENKINS_API_TOKEN` 对应的 Jenkins 用户只需要本项目相关 job 的 Build / Read 权限，禁止给 Administer 或 RunScripts。

**28. 占位符不允许填空字符串假装通过** — `${stages.X.build_number}` 等引用必须能解析到真实值；引用未执行 / 未来 / 不存在的阶段一律报错退出，不允许填 `""` 或 `0` 假装继续。

**29. Jenkins 失败不能掩盖 commit / metrics 写入失败** — 即使 Step 7 整体失败，Step 5 (commit) / Step 6 (record-session) / Step 6.5 (metrics) 必须已经写完。Jenkins 是 commit 之后的副作用，不可逆向影响 commit 决策。
