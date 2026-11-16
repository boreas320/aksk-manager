# 网站账号验收（2026-11-16）

测试环境：macOS 27.3，Codex 26.1111.21308，内置测试页报告 Chromium 157，外部 Google Chrome 157.0.8103.51。内置标签页的登录后标注流程尚未通过。

| 验收项 | Codex 内置浏览器 | Chrome 对照 |
| --- | --- | --- |
| 扩展入口 | 用户已在内置浏览器加载 AKSK Manager 0.2.0，并通过工具栏弹窗完成下列两项填充 | 通过：在桌面 Chrome 157 和 Chrome for Testing 156 的临时配置中加载原版 MV3 扩展，并触发工具栏操作，弹窗成功连接已签名的宿主 |
| 密码填充（扩展弹窗） | 通过：在扩展弹窗点「密码」，用户看到「已填写并核对一致」 | 通过：弹窗展示同站两个真实钥匙串测试条目，选择指定条目后在同一标签页分步填入用户名及密码；与预期值一致 |
| TOTP 填充（扩展弹窗） | 通过：在扩展弹窗点「验证码」，用户看到「已填写并核对一致」 | 通过：已加载的扩展将当期动态码填入验证码输入框，与独立计算的 TOTP 一致 |
| AKSK Manager Passkey | 本机未通过。20:35:52，网站已返回认证选项（HTTP 200），macOS AuthenticationServicesAgent 报 “Client is missing web browser entitlement.”；本次无 AKSKProvider 请求或签名日志。检查已安装副本：Chrome 带有 com.apple.developer.web-browser.public-key-credential，ChatGPT 主程序及检查到的 Codex 浏览器 helper 都没有该项。 | 已通过：Apple「密码」导出的测试 Passkey 已落库；Chrome 选择 AKSK Manager，设备验证后扩展记录签名完成，WebAuthn.io 显示对应账号已登录。 |
| 手机扫码登录 | 已通过：用户确认用手机扫码并选择 Apple「密码」。同一内置标签页的 /authentication/verification 和 /profile 均返回 200，页面显示已登录及正确的测试用户名。此结果不验证 Mac 本机的 AKSK Manager。 | 未测试此路径 |
| 同标签页登录后标注 | 之前收到了阿里云登录错误元素的标注；密码后仍要求 Passkey 并显示超时或取消。未收到已登录控制台的标注 | 外部 Chrome 的登录结果不能替代此项 |

在 [WebAuthn.io](https://webauthn.io/) 的内置标签页点击 Authenticate（未指定用户名）后，页面返回 “The operation either timed out or was not allowed.”。同站外部 Chrome 使用临时配置执行相同操作，18 秒观察窗口内没有看到成功或错误消息。这两次没有预置该站的测试凭据，也没有确认系统选中了哪个提供方，因此不能据此断定内置浏览器不支持任何 Passkey。

本机已构建签名 helper 并注册 Chrome Native Messaging 宿主。自动化验证通过 64 项后端/原生测试及 20 项 Chrome 页面测试；覆盖合成 Apple 交换条目的重复导入、多个凭据归属、断言验签和动态码向量。

追加端到端实测：首次钥匙串测试返回 KEYCHAIN_LOCKED，本次复验成功。Google Chrome 157.0.8103.51 和 Chrome for Testing 156.0.8078.4 均完成上述三字段填充。测试仅模拟 HTTPS 页面的表单响应，Chrome 的弹窗、activeTab 授权、Native Messaging、签名 helper 与钥匙串均为真实组件。测试使用随机独立站点，结束后清理两个测试条目和临时浏览器配置；没有改动日常 Chrome 配置中的扩展。该测试不验证云站会话、Passkey 或内置浏览器。签名安装再次尝试后，接收 App 和扩展仍同时报告 No Accounts 和缺少 AutoFill Credential Provider capability。

登录 Xcode 后重试：两个 target 均返回 `PLA Update available`。Apple 要求在开发者账号中接受最新的 Program License Agreement 才能访问会员资源；现有通配描述文件仍不含 AutoFill 权限。此次签名失败，未安装接收 App，未执行真实 Passkey 导入或 Chrome 登录。

## 安装和复验

内置浏览器扩展弹窗复验：在 React Verification Input 演示页，Codex 观察到密码框（`type=password`）和验证码框（`autocomplete=one-time-code`）从空变为非空。用户重新加载扩展，对同一测试账号分别点「密码」和「验证码」，确认两次都看到「已填写并核对一致」。此提示表示扩展在写入并触发页面事件后，已将该字段值与本次从 AKSK Manager 取得的值逐项比对。两项均通过；未提交表单。

单独测试系统自动填充时，仅聚焦密码框或验证码框并展开候选，两项均未见 AKSK Manager 建议，也未填入。

日常 Chrome 验收：在 Default 配置通过「加载未打包的扩展程序」安装 AKSK Manager 0.2.0（ID `bfpjiopkopocgkcjnocobemofkkjopgf`），配置回读路径指向仓库的 browser 目录且无禁用原因。分别在登录和 OTP 测试页打开实际工具栏弹窗，核对匹配的临时账号后点击「密码」「验证码」，两次均返回「已填写」；未提交表单。

内置浏览器指定测试账号复验（2026-11-16 20:32:40–20:33:01，本机时间）：在新的 Codex 内置标签页向 WebAuthn.io 提交与 Chrome 对照相同的用户名并点击 Authenticate。页面返回 “The operation either timed out or was not allowed.”，仍在登录表单。同期 AKSKProvider 的 credential-request 日志无请求或签名记录。此次未建立内置会话，无法验收登录后标注；网页报错本身不能定位具体原因。

最终 Chrome 验收（2026-11-16）：AKSKProvider 在 20:30:26 和 20:30:55 记录 `Passkey assertion signed; submitting to system`。随后从原 Chrome 标签页读回 “You're logged in!” 及 “Credentials for aksk-import-test-7ea4c1”。这些证据验证了导入后使用 AKSK Manager 在 Chrome 登录；没有据此推断 Codex 内置浏览器兼容性。

协议接受后在本机再次签名成功。接收 App 已安装在 `~/Applications/AKSK Manager.app`；主程序和内嵌扩展均通过 codesign 校验，签名与描述文件均包含 AutoFill 权限，两者的钥匙串组一致，pluginkit 已列出提供方。此项只证明安装和注册；测试条目导入及由该提供方完成 Chrome 登录仍需独立验证。

真实 Apple 导入复测：重启已安装的 AppKit 接收器，使用 Apple「密码」的单条导出，回执为新增 1、更新 0、跳过 0、失败 0。签名 helper 从活动钥匙串独立读回一个 Passkey，用户名与测试账号一致，RP 为 `webauthn.io`。随后尝试 Chrome 登录；macOS「自动填充与密码」显示 AKSK Manager 开关关闭。已证实导入，尚未证实该提供方完成登录。

1. 运行 `scripts/build-native.sh`，再运行 `python3 scripts/install-browser.py` 注册 Chrome Native Messaging。Chrome 扩展管理打开开发者模式，加载仓库的 `browser/`。宿主绑定签名 helper 的绝对路径，移动仓库后需重新注册。
2. 在 Xcode 配置开发团队。接收 App 和嵌入的凭据扩展都需要包含 AutoFill Credential Provider 和共享钥匙串组的描述文件。macOS 26 或以上运行 `sh scripts/install-exchange.sh`，在系统的自动填充设置启用 AKSK Manager，并打开接收 App。
3. 在 Apple「密码」中对测试账号执行「将所选项目导出至 App」，选择 AKSK Manager。核对条目、多个 Passkey 和重复导入计数。当前签名实现限于 P-256/ES256；没有实现新建 Passkey。
4. 钥匙串可用时运行 `PLAYWRIGHT_CHANNEL=chrome uv run python scripts/smoke-browser.py --extension` 在已安装的 Google Chrome 复验弹窗填充（先在 frontend 目录执行 npm ci）。去掉 `--extension` 可单独测试签名 helper 的消息协议。之后在 HTTPS 测试站用 Apple「密码」和 AKSK Manager 分别执行 Passkey 登录，核对系统选择的提供方、服务端是否接受签名及登录后的会话。
5. 在 Codex 内置标签页重复测试；记录是否出现选择器、选择的提供方、服务端结果。在该标签页标注登录后才可见的元素，确认 Codex 收到并定位，再用阿里云 OSS 验证。每一步应保留版本和结果，不记录私钥、设置密钥、验证码或会话值。
