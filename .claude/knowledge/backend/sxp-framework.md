# sxp-framework / sxp-component 使用规范

> 使用 sxp 内部框架的项目加载此文件。不使用的项目可删除。

## sxp-framework 提供的能力（直接使用，不要重复实现）
- Response 类（统一响应）
- BizException（业务异常）
- AccountContext.currentAccount()（获取当前租户）
- @NotNeedLogin（跳过登录校验）

## sxp-component 提供的工具类
- JsonUtils、StringUtils、MDCUtil 等

## 注意事项
- GlobalExceptionHandler 使用 @Order(97) 优先于 sxp-component-web 的 @Order(99)
- 新增异常处理写在项目自己的 Handler 中
- 获取当前租户信息必须使用 AccountContext，禁止从 HttpServletRequest 手动解析
