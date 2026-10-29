# AKSK Manager

在 Codex「更多工具」中管理 AK/SK、API Token 和数据库连接配置，让 Codex 通过引用执行本地命令。
没有主密码、Passkey 或自建加密文件库。生产数据仅使用可通过 iCloud 同步的 Apple 钥匙串条目。

## 当前状态

界面、Swift 核心、Python MCP、安装与打包脚本已实现。
**本机签名和真实钥匙串读写、引用执行已验证；双机同步仍待第二台 Mac 独立验收。**
详见 [验收记录](docs/verification.md)。`docs/ui-*.png` 为合成数据的界面测试截图，不是实际密钥库。

## 使用

从 Codex「更多工具 → AKSK Manager」打开界面。录入密钥后，可以在对话中要求：

> 用“生产账单只读”的 AWS 凭据运行 `aws sts get-caller-identity`。

Codex 先查找条目 ID，再调用 `run_with_secrets`。密钥由本地组件注入命令环境，不通过模型可见的工具结果返回。
需要增加或更新密钥时，在界面中录入，不要粘贴到聊天中。回收站中的密钥不能用于启动新任务。
执行中的任务已取得凭据，移入回收站不会撤销正在进行的任务或云厂商上的密钥。

界面可以显式显示明文或复制到系统剪贴板；明文显示 30 秒后自动隐藏。剪贴板由系统管理，不自动清空。
元数据（包括备注）可以供 Codex 查询，请将秘密值填写在凭据字段。

添加时选择「数据库连接」，填写数据库类型、主机，以及可选的端口、数据库名、用户名、密码和 TLS 模式。
支持 PostgreSQL、MySQL、SQL Server、Oracle、MongoDB、Redis 等连接配置的保存；不会自动连接或安装数据库客户端。
连接字段全部保存在钥匙串中，列表和 Codex 查询只返回字段名称；详情默认遮盖，编辑默认保留现有连接配置。
Codex 可通过字段引用注入客户端支持的环境变量，例如 PostgreSQL 的 `PGHOST`、`PGUSER`、`PGPASSWORD`。
实际连接和查询需要本机已有相应客户端及网络访问权限；保存成功不代表连接测试通过。

## 日常开发

在仓库根目录运行：

```sh
./scripts/preview.sh
```

打开 **http://127.0.0.1:5173/preview.html**。预览直接加载正式 React 界面，保存代码后自动更新，
不需要签名、Python 服务或重新安装插件。首次启动会按锁文件安装前端依赖；后续依赖不变时复用。
端口被占用时明确报错，可用 `./scripts/preview.sh --port 5180` 指定其他端口。按 Ctrl+C 停止。

预览包含 AK/SK、API Token、数据库连接三类无效演示凭据，支持搜索、新增、编辑、显示、复制和回收站操作。
顶部可以切换桌面/平板/手机尺寸、浅色/深色主题，以及空列表、组件不可用、编辑冲突状态。
「重置演示数据」恢复初始列表。数据只在当前页面内存中，整页刷新会重置；请勿输入真实密钥。
**这里的保存与同步提示属于模拟界面，不会读写真实钥匙串，也不会执行本地命令。**
预览宿主与界面测试共用 `frontend/preview/host.ts`，不编入发布用的单文件 HTML。

效果确认后，一条命令更新本机插件：

```sh
./scripts/update.sh
```

依次安装锁定依赖、运行静态检查及后端/界面测试、构建前端、更新 MCP 契约，
然后检查签名组件、验证真实服务、安装本地插件、验证已安装版本，最后输出 ZIP 和 SHA-256。
任一步失败都会停止后续步骤；不会提交或推送 Git。
首次运行建立签名构建缓存；之后原生源码、构建脚本、团队及签名组件内容未变化时复用组件，
无需每次重新签名。重建后自动进行合成凭据的真实钥匙串测试，并清理测试条目。
依赖缓存与构建指纹存放在忽略的 `.build/dev/` 下。

```sh
./scripts/update.sh --check   # 仅测试与前端构建，不签名、不安装
./scripts/update.sh --native  # 强制重建签名组件，例如更新描述文件
```

预览要求 Node 22.12+、npm/npx、Python 3（仅用于启动脚本）。完整更新另外要求 macOS 14+、Xcode、
有效 Apple 开发签名与 Mac 配置描述文件、`uv`、Codex CLI。
界面测试优先使用已安装的 Google Chrome；否则安装 Playwright Chromium。
可通过 `PLAYWRIGHT_CHANNEL` 指定已有的浏览器通道。

## 首次安装与签名

先在 [Apple Developer 账户](https://developer.apple.com/account/) 接受尚未处理的开发者协议，
并在 Xcode → Settings → Accounts 确认开发团队可用，然后执行 `./scripts/update.sh`。
运行时由 `uv` 按 `uv.lock` 安装 Python 3.12 和依赖；发布插件不依赖前端开发服务器。

当前个人构建默认团队为 `XHD2S8GC8Q`。如有意构建另一套独立密钥库，可设置 `AKSK_DEVELOPMENT_TEAM`；
**改变团队或钥匙串访问组会改变可访问的条目集合，不是原密钥库的升级方式。**
`build-native.sh` 通过 Xcode 自动申请正确的 Mac 配置描述文件，并构建 arm64/x86_64 通用组件。
不要使用 iOS 描述文件、临时签名或关闭系统签名校验来代替。

安装脚本从允许的文件列表生成带内容版本标记的独立目录，再使用 Codex 支持的本地 marketplace 流程，排除开发缓存。缺少签名组件时仍可安装诊断界面，
但密钥读写和执行会明确报错，不会退回明文或测试存储。
如果当前聊天尚未加载新 MCP 服务，在 Codex 中新开聊天后验证。

## 另一台 Mac 与升级

1. 登录同一 Apple 账户，在系统设置中开启 iCloud 的“密码与钥匙串”同步。
2. 安装同一团队、同一应用标识和访问组签名的组件及插件。
3. 开发签名依赖设备登记和配置描述文件的设备范围、有效期。若第二台 Mac 不在范围内，需先登记设备并重新生成描述文件；它不是可任意分发的公证安装包。
4. 打开插件并刷新。显示的是本机读到的状态，不能据此认定其他设备已收到。

密钥保存与删除由系统同步，插件不声称知道完整同步进度。不要在两台离线 Mac 上同时编辑同一条目；
系统可能选定其中一份更新，首版没有跨设备冲突历史或合并界面。
本机多聊天并发编辑用文件锁和修订检查避免已知的过期表单覆盖。

升级需保留应用 ID `com.boreas.aksk-manager.helper`、钥匙串访问组后缀 `com.boreas.aksk-manager`、
服务名称和签名团队。重新构建后重新运行安装脚本；新开聊天使新服务版本生效。卸载插件不会主动清除钥匙串。

## 测试与打包

```sh
uv run pytest -q
uv run ruff check src tests scripts
cd frontend
npx --yes npm@10 run build
# 使用已安装的 Chrome；或安装 Playwright Chromium 后省略环境变量
PLAYWRIGHT_CHANNEL=chrome npx --yes npm@10 test
cd ..
uv run python scripts/export-contract.py
uv run python scripts/package.py
```

Swift 逻辑测试将 `TESTING` 编译到独立可执行文件，只使用合成数据和内存存储。
这不证明生产钥匙串授权或 iCloud 同步。`smoke-keychain.py` 才会通过正式组件创建、使用并清理一条合成测试凭据。
跨设备验收步骤见 [verification.md](docs/verification.md)。

有经过验证的签名组件时输出完整插件包；否则输出明确带 `-source` 后缀的源码包。
包中不含私钥、开发账户令牌、真实密钥、测试存储或依赖缓存。包含签名 app 时必须保留其内嵌配置描述文件。

## 访问边界

- iCloud 钥匙串保护存储，插件不读取 Apple 账户密码，不另建秘密缓存。
- 解锁且系统授权可用时，不增加命令白名单或逐次确认；Codex 自身的授权规则仍然适用。
- 子进程能够接触注入的密钥，可能写文件或访问网络；这不是对任意程序的防泄露沙箱。
- 已知秘密原文在输出中被遮盖；编码、切分、变换后的内容不能保证被识别。
- 任务输出只保留在本次 MCP 会话内存，最多保留 64 个任务；每项 stdout/stderr 各最多 512 KiB。
- 默认任务超时 600 秒，可设 0.1–3600 秒；最多同时运行 8 个任务。正常关闭会话会终止本组件仍管理的任务。
- 发布插件的本地组件通讯通过私有 stdin/stdout 管道；没有 HTTP 监听端口、云端代理或后台上传。开发预览只在 127.0.0.1 提供前端文件与模拟宿主。

接口说明见 [API 文档](docs/api.md)，生成的 MCP 契约见 [mcp-contract.json](docs/mcp-contract.json)。
