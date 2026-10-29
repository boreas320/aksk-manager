# MCP 接口契约

传输为本地 stdio MCP。接口真源是 `src/aksk_manager/server.py` 的工具定义；
`scripts/export-contract.py` 导出完整 JSON Schema 到 `docs/mcp-contract.json`。
不引入无关的 REST API、OpenAPI 或远端 Postman 工作区；契约、合成用例和测试均随源码保存。

## 模型可见

| 工具 | 输入 | 输出 / 效果 |
| --- | --- | --- |
| `aksk.open` | 无 | 打开会话内容面板，始终可显示安装诊断 |
| `list_secrets` | `query`，默认空字符串 | 搜索未删除条目的元数据 |
| `get_secret_metadata` | `secret_id` | 单条元数据，包括 revision、fields 和删除状态 |
| `run_with_secrets` | `argv`、绝对 `cwd`、`bindings`、可选 `timeout_seconds` | 启动真实命令并返回任务 ID；有本地和远端副作用 |
| `get_run` | `run_id` | 会话内任务状态及完成后的脱敏输出 |
| `cancel_run` | `run_id` | 取消任务的进程组 |

模型结果统一为 `{ "ok": true, "data": ... }` 或 `{ "ok": false, "error": { "code", "message" } }`。
任务状态为 `running`、`completed`、`failed`、`timed_out`、`cancelled`；终止输出带 `exit_code` 和 `truncated`。
命令不会自动 shell 展开。需要 shell 的用户授权任务须显式调用 shell；不要把秘密值放进参数。
继承环境只包含 PATH、HOME、TMPDIR、USER、LOGNAME、LANG、LC_ALL、SHELL，再加入所需密钥字段。

```json
{
  "argv": ["aws", "sts", "get-caller-identity"],
  "cwd": "/Users/example/project",
  "bindings": {
    "AWS_ACCESS_KEY_ID": {"secret_id": "<从 list_secrets 获得>", "field": "access_key"},
    "AWS_SECRET_ACCESS_KEY": {"secret_id": "<相同 ID>", "field": "secret_key"}
  },
  "timeout_seconds": 600
}
```

元数据包含 `id`、`revision`、`kind`、`name`、`provider`、`account`、`environment`、`tags`、`notes`、
`expiresAt`、`updatedAt`、`deletedAt` 和字段名称 `fields`。`expiresAt` 作为旧数据兼容字段保留，界面不再显示或提供编辑，不自动轮换或撤销。

## 仅应用可见

`list_secrets(query)` 搜索全部公开元数据：名称、厂商、账号、环境、标签、备注、类型、字段名称、ID 和日期。
`ui_list(trash=false, query="")` 支持全部字段，包括数据库连接信息、密码、Access Key、Secret Key、Session Token 和 API Token 的值；
匹配在本地组件内完成，只返回匹配条目的元数据，不返回连接字段或搜索索引。
两者均忽略大小写、全半角与重音；空白分隔的关键词必须全部匹配，可以跨字段匹配。
密钥值搜索仅开放给管理界面；模型的 `list_secrets` 仍仅匹配公开元数据，不支持通过密钥值探测条目。

`ui_status`、`ui_list`、`ui_save`、`ui_reveal`、`ui_trash`、`ui_restore`、`ui_purge`
均声明 `ui.visibility: ["app"]`。
结果位于 `_meta.private`，不放入 `content` 或 `structuredContent`。明文只通过 `ui_reveal` 返回给界面。
界面不调用 `ui/update-model-context` 或 `ui/message`，不把秘密持久化到浏览器存储。

`ui_save(record)` 创建时省略 ID，更新时提交 ID 和期望 revision；更新时省略 values 保留同类型旧凭据。
切换 kind 必须提供全套新凭据。AK/SK 字段为 `access_key`、`secret_key`、可选 `session_token`；Token 为 `token`。
数据库配置使用 `kind: "database"`，values 必填 `engine`（如 PostgreSQL、MySQL）和 `host`；
可选 `port`（1–65535 的十进制字符串）、`database`、`username`、`password`、`ssl_mode`。
省略端口表示交给调用方/数据库客户端选择默认值；不自动拼接连接串、不连接或探测数据库。
全部连接字段均保存在 values 中，普通元数据接口只返回字段名称，不返回主机、用户名或密码等值。
编辑时默认保留全部连接字段；选择更新连接配置后需要重新填写必填字段，空的可选字段会移除。
`run_with_secrets` 可引用任一已保存的数据库字段，例如 PostgreSQL 的 `PGHOST → host`、
`PGPORT → port`、`PGDATABASE → database`、`PGUSER → username`、`PGPASSWORD → password`、
`PGSSLMODE → ssl_mode`；仅映射存在的字段，其他数据库按客户端实际支持的环境变量使用。
`ui_reveal` 和变更操作均检查 revision。永久删除要求条目已经处于回收站。
所有字段在一个钥匙串 value 中整体保存。修订检查仅避免本机已经观察到的冲突，不构成跨设备事务。

## 错误和重试

| 错误码 | 处理 |
| --- | --- |
| `HELPER_MISSING` / `SIGNING_REQUIRED` / `SIGNATURE_INVALID` | 安装或重新构建签名组件 |
| `MISSING_ENTITLEMENT` / `HELPER_STOPPED` | 检查 Mac 配置描述文件、团队和钥匙串权限 |
| `KEYCHAIN_LOCKED` / `ACCESS_DENIED` | 解锁系统或处理系统授权；不重试循环弹窗 |
| `CONFLICT` | 刷新并重新打开编辑，保留用户尚未提交的表单 |
| `TRASHED` / `NOT_TRASHED` / `NOT_FOUND` | 核对条目当前状态 |
| `FIELD_NOT_FOUND` / `INVALID_INPUT` | 修正字段引用或参数 |
| `COMMAND_NOT_FOUND` / `EXEC_FAILED` | 检查可执行文件、工作目录和权限 |
| `BUSY` | 等待现有任务完成 |
| `RUN_NOT_FOUND` | 不同会话或已被清理，不能据此重新执行有副作用命令 |
| `HELPER_UNAVAILABLE` | 结果未知；先检查实际效果，不自动重复提交 |

取消和超时通过该任务专属进程组终止程序。主动逃离进程组的程序不在保证范围内。
输出按原始密钥原文脱敏，并处理跨读取块、截断边界。其保障不包括程序主动变换或外传密钥。
