# API 设计约定

> 后端 /impl、/review 时加载。

## 响应格式

### DDD 项目
必须使用 Response 类：
```json
{
  "traceId": "xxx",
  "statusCode": 200,
  "path": "/api/v1/xxx",
  "message": "success",
  "data": {}
}
```
禁止使用 JsonResult 或自建响应类。

### MVC 项目
使用统一 Result 包装：
```json
{
  "code": 0,
  "message": "success",
  "data": {}
}
```

## 异常处理
- 业务异常使用 BizException
- 禁止直接抛出 RuntimeException
- GlobalExceptionHandler 使用 @Order(97)

## 参数校验
- 所有对外接口必须有参数校验
- 使用 Bean Validation 注解

## 路由规范
- 必须带版本前缀：/api/v1/
- RESTful 风格
- 列表接口统一分页参数
