# /init-baseline — 从代码生成项目基线文档

## 用法

```
/init-baseline "{产品简介}"
```

示例：
```
/init-baseline "客户运营 CRM 平台，服务于奢侈品牌在中国市场的客户管理"
```

可选参数：
```
/init-baseline "{产品简介}"
  --consensus /path/to/consensus.md    # 已有共识文档（0-1 项目转迭代时）
  --refresh                            # 刷新模式：基于已有基线更新
```

---

## 执行步骤

### Step 1：判断项目栈类型

扫描当前仓库根目录自动判断：
- pom.xml / build.gradle → Java 后端
- package.json + react/vue/taro → 前端
- 两者都有 → 询问用户

### Step 2：检查已有上下文

- 如果提供了 `--consensus`，读取作为业务理解的补充
- 如果已有基线且未 `--refresh`，提示是覆盖还是刷新

### Step 3：扫描代码仓库

**graph 优先**——见 CLAUDE.md「Code Review Graph」节的命名约定和探针规则。

1. **探针**：调 `mcp__Code-review-gragh__list_repos_tool` 验证可用性
2. **探针成功且包含当前项目**（推荐）：
   - `mcp__Code-review-gragh__get_architecture_overview_tool` 获取精确的架构概览（社区检测、模块耦合度）
   - `mcp__Code-review-gragh__list_communities_tool` 获取代码社区划分
   - `mcp__Code-review-gragh__get_hub_nodes_tool` 识别核心节点（最关键的类/函数）
   - `mcp__Code-review-gragh__get_knowledge_gaps_tool` 发现未测试的热点
   - 用 graph 数据补充和验证下面的文件系统扫描结果
3. **探针成功但当前项目未索引**：提示开发者先在项目根目录跑 `code-review-graph build`，本次降级到纯文件扫描
4. **探针失败**：静默降级到纯文件扫描（不报错）

**同时扫描本地文件系统**（graph 数据和文件扫描互补，graph 与文件冲突时以 graph 为准）：

**Java 后端扫描：**
1. 技术栈（pom.xml/build.gradle → JDK、Spring Boot、主要依赖、sxp-framework）
2. 架构模式（包结构 → DDD 六模块 / MVC）
3. 模块划分（Maven modules 或包结构）
4. API 清单（Controller/Adapter 类 → 路径、方法、参数、返回类型）
5. 数据模型（Entity/Aggregate → 字段、关联关系）
6. 外部服务（Gateway 接口 / RestTemplate / Feign）
7. 配置概览（application.yml 关键配置，不暴露密码）

**前端扫描：**
1. 技术栈（package.json → 框架、UI 库、状态管理）
2. 产品形态（antd→Web / Vant→小程序 / antd-mobile→H5）
3. 路由结构
4. 组件结构
5. API 调用清单
6. 状态管理

### Step 4：生成基线文档

输出结构化基线文档，包含：产品简介、技术栈、模块结构、API 概要、数据模型、外部依赖、已知约束（需人工补充）。

如果提供了共识文档，额外输出"实现状态"对照表。

### Step 5：初始化 Knowledge 文件

根据扫描结果，**自动填充** `.claude/knowledge/` 下对应的模板文件：
- 后端项目 → 填充 `backend/architecture.md` 中的架构模式段落（保留适用的，删除不适用的）
- 填充 `backend/sxp-framework.md`（如果检测到 sxp 依赖）
- 前端项目 → 填充 `frontend/` 下对应的文件

```
Knowledge 文件已初始化：
- .claude/knowledge/backend/architecture.md — 已填入 DDD 六模块结构
- .claude/knowledge/backend/sxp-framework.md — 已填入 sxp-framework 2.x 规范
- .claude/knowledge/red-lines.md — 通用红线（请根据项目调整）

⚠️ 请人工检查并补充 knowledge 文件中标注 {需补充} 的部分
```

### Step 6：保存文件 + 创建 project.yaml

基线保存到 `docs/baseline/{PROJECT}-baseline-{date}.md`

project.yaml 记录项目元信息（栈类型、架构、repo、基线 commit 等）。

### Step 7：输出完成提示

```
项目基线已生成：docs/baseline/{文件名}
Knowledge 已初始化：{列出已填充的文件}

⚠️ 请人工补充：
- docs/baseline/ 中的"已知约束和技术债"
- docs/project.yaml 中的 tapd_project_id / github_issue_repo
- .claude/knowledge/ 中标注 {需补充} 的部分

git add docs/ .claude/knowledge/
git commit -m "harness: init baseline + knowledge"

后续迭代请使用：/iterate "{需求简述}"
```
