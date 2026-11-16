# Qoder CN 开发交接 · 2026-11-16

直接使用当前 main 工作区，未提交的修改和新增文件都是开发现场。面板在 frontend/src，钥匙串和签名在 native，浏览器扩展在 browser。网站账号是一种记录，可包含密码、TOTP 和多个 Passkey，也可只有 Passkey。

开发面板时先运行 `./scripts/preview.sh`：使用演示数据，改动即时显示。运行 `./scripts/update.sh --check` 做回归；需要在真实 Codex 面板验收时再运行 `./scripts/update.sh` 安装，然后从新的 Codex 聊天打开面板。预览不能验证真实钥匙串。

最近一次从已安装的 Codex 插件 0.1.0+local.bd83eca7a7b4 回读：按测试 Passkey 用户名能找到 webauthn.io（1 个通行密钥）；密码与动态码测试账号也能找到。下一步从新聊天目视确认「网站账号」分类及搜索结果。浏览器扩展 0.2.0 与 Codex 插件独立安装。

浏览器实测证据见 [验收记录](browser-acceptance.md)。Chrome 已通过导入后签名登录；Codex 内置浏览器的扩展密码和 TOTP 填充已通过，本机 Passkey 未通过。手机扫码使用的是 Apple 密码。最终目标仍是在同一个已登录的内置标签页标注控制台元素并由 Codex 定位；此项待验收。
