# Contributing

提交前启用 `git config core.hooksPath .githooks` 并执行 `python tools/privacy_check.py --staged`。不得提交真实部署记录、个人域名/账号、本机路径、用户截图、实际二维码或认证数据；`.gitignore` 不能清除已存在的 Git 历史。源码打包器只读取受版本控制且通过隐私检查的文件。

本仓库当前为私有开发项目；此文档规范维护方式，不代表已对外开放贡献或授予开源许可。

1. 保留 bundle ID 和现有设备身份，UI 品牌名与内部 target 不必一致。
2. 修改图标先改 `brand/identity.json`，重新生成资源并提交矢量和 PNG 导出；不要只改一张位图。
3. iOS 代码用 Xcode 26.3 构建，最低支持 iOS 17。新 API 必须有 availability 分支及旧系统测试。
4. 不自绘系统导航栏，不强制修改系统透明度/动态效果偏好。
5. 每次变更执行 Python 测试、原生 XCTest、UI 自动化；视觉变更必须检查真实浅/深色截图。
6. 禁止提交账号密码、Cloudflare 凭据、签名证书、描述文件、实际设备令牌、浏览器状态或真实认证日志。
7. 前端能力以 `/v1/capabilities` 为准；未启用的控制不可通过 UI 绕过，失败的写请求不自动重试。
8. 不能把示例数据、语法解析、编译成功或模拟器测试分别当成真实设备联网、长期稳定或生产安全验收。

私有凭据、`.venv`、`.stage`、生成的 IPA、构建缓存不进入 Git。CI 不需要 Apple 账号、校园网账号或主板凭据。
