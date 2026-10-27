# iOS 页面更新与安装包更新

栖核参考 Tempo 的原生壳／热更新内容层边界，独立实现运行时，不复制其他项目的账户配置。基于 [Expo Brownfield 独立集成](https://docs.expo.dev/brownfield/isolated-approach/) 与 [Expo Updates](https://docs.expo.dev/versions/latest/sdk/updates/)。

## 当前边界

- SwiftUI 拥有四项原生导航、隐藏入口、详情跳转、扫码、相机、Keychain、API 客户端与所有操作确认。
- TypeScript 拥有概览、服务、设备一级页面和开发者工具内容。只有真实字段才展示，不增加虚假服务按钮。
- 原生桥只接受 ready、refresh 与固定的详情导航；ID 必须存在于当下快照。没有通用 URL、任意网络、任意文件、shell、令牌读取或服务控制方法。
- 主板地址、API Token、Cloudflare Access 凭据不传入 JS，不发送给 Expo。
- Swift、原生依赖和权限变化不能 OTA，需新 IPA；只有不兼容的原生依赖或桥接变化才切换 `runtime/runtime-version.txt`，兼容的原生界面变更不必更换 runtime。
- 运行时版本与应用市场版本分离；纯页面变更保持运行时版本不变。

## 自动分流与产物

`tools/change_scope.py` 依据 Git 差异决定路径；无法确认差异时保守执行完整检查。

- 只改 `runtime/src/` 或资源：通过隐私、TypeScript、测试和导出后，调用独立 OTA 工作流发布 production；不打 IPA、Docker 包或模拟器归档。
- 改原生代码、依赖、权限或桥接：才运行 Xcode 和模拟器、生成 IPA；不把新原生能力投递给旧宿主。
- 改服务端生产代码：才构建并验证 Docker；混合 API 与页面更新不自动推送 OTA，需确认兼容性后手动发布。
- 仅改测试、文档和 CI：不发布页面或生成安装包。手动执行安装包工作流仍可全量验收。
- 成功构建不再上传多份调试日志；失败时保留诊断。原生运行时包是 CI 内部依赖，不是用户需要安装的文件。

日常页面更新不要顺手改原生安装版本、`package.json` 或 runtime；OTA 页面以更新 ID 区分。
0.9.1 补充底部“设置”长按约 0.65 秒的原生入口，需要覆盖安装一次；开发者内容使用既有模块，保持 runtime 0.9.0。

## 首次授权（后续操作，不假装已完成）

1. 在自己的 Expo 账户中创建专供栖核使用的项目，公开 Project ID 放入本仓库 Actions Variable `CORENEST_EXPO_PROJECT_ID`。
2. CI 专用访问令牌只放入本仓库 Actions Secret `EXPO_TOKEN`，不要写入源码、聊天或日志。不要复制 Tempo 的 Token。
3. 首次初始化／核实项目 owner、slug 与渠道映射应在可信本机通过 Expo/EAS 交互完成。确保 preview、production 渠道映射到同名 branch。
4. 重新构建并有效签名安装一次新版 IPA。更新 URL 和 native runtime 需要被嵌入二进制；已安装的“OTA 未配置”旧包不会凭空启用远程更新。
5. 使用 `CoreNest iOS OTA` 工作流，先选择 preview。在隔离测试包验证后再选择 production。生产包固定 production 渠道。

没有 Project ID 时 `updates.enabled=false`，始终有完整的随包内置界面；发布工作流缺少授权时明确失败且不发布。CI 不会自动创建账户、复用其他项目或把一次 TypeScript 导出称为发布成功。

## 验证与发布

发布使用独立的 Developer 机器人令牌，不复用个人登录会话或其他应用的令牌；它没有
账户管理/付费权限。机器人权限范围仍是其所属 Expo 账户，并非项目级隔离。
`tools/publish_ota.py` 捕获 EAS CLI 原始输出，只公开校验后的更新 ID、分组 ID、渠道、
runtime 和源码提交，不把账户名或控制台链接写入公开 CI 日志。SDK 57 发布显式选择
与渠道同名的 EAS environment；发布结果不确定时不自动重试。

0.7.1 的原生兼容 runtime 仍为 0.7.0。更新地址首次被嵌入的新安装包需要重装一次；
之后“关于栖核”会分别显示页面来源与页面 ID，可核实下载是否真正于冷启动后生效。

0.8.0 使用新的原生兼容 runtime 0.8.0，新增原生设置标签和前台事件流连接，
因此需要先安装新版 IPA，不能靠旧 runtime 的 OTA 增加原生标签或网络能力。
后续页面更新仍在独立项目的 production / preview 通道发布。

0.9.0 的 SVG 趋势图和原生工具栏搜索使用 runtime 0.9.0；请先安装新版 IPA。
旧运行时不会收到不兼容的图表更新。

正常 IPA 工作流先检查隐私、TypeScript、OTA 生命周期，然后在 macOS 构建真实 Brownfield Package；新旧 iOS 模拟器运行交互测试，最后打包 arm64 iPhoneOS 未签 IPA。

```sh
cd runtime
npm ci
npm test
npm run typecheck
npm run export:ios
# 下面两步需要 macOS 与 Xcode
npm run prebuild:ios
npm run build:ios
```

应用只在前台检查／下载，自动检查至少间隔一小时；多个标签共享一个更新任务。检查失败保留当前界面。下载成功只标记待应用，下次冷启动由 expo-updates 启用；不在页面树调用强制重载。恢复依赖 Expo 的兼容缓存／内置 bundle 机制；这不是远程恢复原生代码的能力。

发布前可在 GitHub Environments 设置 `ota-production` 的审批保护。通过 EAS 发布的 JS 是可执行内容，Expo 项目访问权限也是代码发布权限。首次启用前按 [Expo 代码签名文档](https://docs.expo.dev/eas-update/code-signing/) 评估端到端更新签名，私钥不得进入仓库。当前默认配置尚未设置自持更新签名证书，不声称已经端到端签名。

## 回退

先查明最后验证通过的提交及其 runtime，选择该 ref 再运行 OTA 工作流。不能把使用新桥接协议的 JS 发布给旧 runtime，不能用改 runtime 字符串冒充兼容。发布后在真实设备验证；模拟器成功不等于生产下载、回退和长期稳定性已验收。

若运行时启动八秒仍未报告 ready，栖核会显示原生备用页面，原有绑定继续可用。原生进程级崩溃不在这一 UI 超时回退的保证范围内。

## 新版安装包

“关于与更新”独立检查 GitHub Releases，按数值版本比较，忽略草稿、预发布、没有 iOS IPA 或 SHA256SUMS 的条目。只打开本仓库的 HTTPS 发布链接。未签 IPA 必须在下载后校验、重新签名安装，不支持免签静默替换。

`Build CoreNest unsigned IPA` 手动触发时选择 `publish_release=true`，只有全部构建与测试通过才会发布，已有同名版本拒绝覆盖。不得把未验证构建上传为正式更新。
