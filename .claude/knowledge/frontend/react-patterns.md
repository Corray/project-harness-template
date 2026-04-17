# React + antd Web 管理后台规范

> 前端 Web 项目 /impl、/review 时加载。小程序项目加载 taro-patterns.md。

## 技术栈
- React + TypeScript
- UI 组件库：Ant Design (antd)
- 路由：React Router
- 状态管理：{项目实际使用的方案，如 Zustand / Redux}

## 组件规范
- 使用 TypeScript，禁止 any
- 组件库已提供的组件不得自行重写
- 自定义样式基于 antd 主题定制机制，不直接覆盖内部 class

## 项目结构
```
src/
├── pages/          # 页面组件
├── components/     # 公共组件
├── hooks/          # 自定义 Hooks
├── stores/         # 状态管理
├── api/            # API 调用
├── types/          # TypeScript 类型定义
└── utils/          # 工具函数
```
