# 验收记录

日期：2026-10-29，Asia/Shanghai。所有测试凭据均为本次生成的合成数据，没有导入真实 AK/SK 或 Token。

## 已完成

- **原生逻辑与 MCP：38 项自动测试通过。** 覆盖 CRUD、类型和字段校验、保留原凭据、修订冲突、回收站/恢复/彻底删除、密钥组合注入、退出码、超时、取消进程组、最小继承环境、输出跨块脱敏、截断边界、短密钥和无效 UTF-8 的输出上限、错误保密和 app-only 结果隔离；新增数据库字段保密、端口校验、可选字段、类型转换、配置保留和多个字段引用执行。
- **界面：10 项 Playwright 测试通过。** 使用模拟 MCP 宿主和合成数据，覆盖搜索/筛选、添加、编辑保留原凭据、回收站恢复、显式显示和自动隐藏、缺失签名诊断、冲突表单保留、375/768/1440 像素布局及暗色主题；新增数据库表单保存、类型筛选、密码遮盖、编辑保留和不发送模型上下文检查。
- **数据库配置真实本机验证：** 重新构建并签名的组件通过合成 PostgreSQL 配置的新增、更新、过期修订拒绝、回收站、恢复、独立进程读回、七个连接字段的环境注入及输出脱敏。临时条目已彻底删除并独立确认不存在。没有连接真实数据库；数据库表单在真实 Codex 宿主中的端到端验收仍待完成。
- **依赖和静态检查：** TypeScript/Vite 构建通过，Ruff 检查通过，npm 依赖审计为 0 个已知漏洞；对 MCP Extensions 的 Zod 依赖使用已修复版本并锁定。
- **签名：** Apple Development 签名验证通过；包含 Mac 配置描述文件和 arm64/x86_64 通用二进制。稳定应用 ID 为 `com.boreas.aksk-manager.helper`，团队为 `XHD2S8GC8Q`。关闭调试附加 entitlement。
- **真实本机钥匙串：** 通过正式签名组件完成合成条目的新增、更新、过期修订拒绝、回收站、恢复；另一独立进程读回确认保存结果。
- **真实引用执行：** 本地组件把合成 Token 注入子进程环境，返回输出为 `[REDACTED]`；测试期间不打印密钥原文。
- **清理：** 合成条目彻底删除后，由独立进程读取确认 `NOT_FOUND`。
- **Codex 注册：** 本地 marketplace 插件安装启用。入口声明为 `thread`，界面使用 `ui://aksk-manager/vault`；后续修改通过安装脚本生成带内容版本标记的缓存版本，不直接修改 Codex 缓存。

## 验收边界

- 上述本机写入使用 `kSecAttrSynchronizable=true`，不等于已经验证第二台 Mac 收到数据。
- 尚未进行第二台 Mac 的真实 iCloud 同步验收，也未在 Intel Mac 上执行通用二进制。
- 电脑控制工具禁止自动操作 Codex 主窗口，因此没有自动点击“更多工具”菜单。用户手动展开 MCP App 后，真实界面控制已成功读取添加表单并切换到 API Token。
- 2026-10-29 真实新聊天已发现 6 个模型可用工具，`aksk.open` 与元数据查询实际调用成功。后续填表时自动化连接超时；DOM 读取等待 60 秒、同一面板截图等待 15 秒均超时。不能据此断定应用本身卡死，真实宿主的保存、引用执行、脱敏、删除与恢复仍未完成验收。模拟宿主测试和单独 stdio 测试不替代此项。
- 本次真实界面测试没有输入 Token、没有执行保存；通过当前聊天的 `list_secrets` 查询唯一测试名称 `codex-synthetic-20261029-01a18721-e2e` 为空，无测试条目需要清理，未读取或修改真实密钥。
- 修复了宿主拒绝加载的问题：Agent Plugins stdio command 不接受绝对路径 `/bin/sh`，应写 `sh`。桌面版 `plugin/read` 已确认识别 `aksk-manager` 服务；单独启动脚本成功不能替代该解析检查。`smoke-plugin.py` 现读取实际 `mcp.json` 并检查命令形式。
- 此包为个人开发签名，非 Developer ID 公证发行包。第二台 Mac 需要在该团队的开发设备范围中，描述文件与证书也必须有效。

## 双机验收步骤（待执行）

1. 两台 Mac 登录同一 Apple 账户并开启“密码与钥匙串”同步；安装同一团队、应用 ID、钥匙串访问组签名的插件。
2. Mac A 在界面创建名称明显为测试用途的合成 Token；Mac B 刷新，核对名称、账号、环境与字段。
3. Mac B 修改备注并保存；Mac A 刷新确认。确认不存在“所有设备已同步”的无依据成功提示。
4. Mac A 移入回收站；Mac B 确认条目不可执行、出现在回收站；恢复后再次核对。
5. Mac A 断网修改一个独立条目，恢复网络后在 Mac B 核对；避免同时编辑同一条目，因为系统同步不提供本产品可控的全局修订锁。
6. 两台 Mac 分别使用同一引用执行只返回布尔验证结果的合成测试命令；不打印秘密值。
7. 彻底删除测试条目，在两台 Mac 分别确认条目不存在，记录实际观察时间。

## 重现命令

```sh
uv run pytest -q
uv run ruff check src tests scripts
cd frontend
npx --yes npm@10 run build
PLAYWRIGHT_CHANNEL=chrome npx --yes npm@10 test
cd ..
uv run python scripts/smoke-keychain.py
uv run python scripts/smoke-keychain.py --kind database
uv run python scripts/smoke-plugin.py --root <已安装插件根目录>
```

`smoke-keychain.py` 只创建和清理其自己生成的唯一测试条目。
`smoke-plugin.py` 只验证实际 stdio 协议、工具发现、入口资源和钥匙串可读状态，不修改密钥。
