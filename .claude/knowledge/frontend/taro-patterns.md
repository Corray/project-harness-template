# Taro + Vant 微信小程序规范

> 小程序项目 /impl、/review 时加载。Web 项目加载 react-patterns.md。

## 技术栈
- Taro 3.x + TypeScript
- UI 组件库：Vant Weapp
- 路由：Taro.navigateTo / Taro.redirectTo
- 存储：Taro.setStorage / Taro.getStorage

## 关键约束
- 不得使用 Web DOM API（document、window 等），必须使用 Taro 跨端 API
- Vant 组件按需引入，不得全量引入
- 必须考虑包体积控制和分包加载策略
- 涉及用户授权必须说明授权流程和拒绝后的降级方案
- 涉及支付必须说明支付流程和异常处理
