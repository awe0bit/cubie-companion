# Changelog

## 0.9.1 — Hidden developer tools and OTA-first delivery

- Long-press the system Settings tab for 0.65 seconds to open developer tools,
  following Tempo's interaction without adding a second tab bar or changing tap behavior.
- OTA-capable developer content shows real update state/progress, runtime,
  channel, page source/ID and read-only session counts. No endpoint or token viewer.
- Native entry requires one package update; compatibility runtime remains 0.9.0.
- Page-only changes publish compatible OTA after checks; native changes build
  IPA, server changes build Docker, test/doc-only changes publish neither.
- Successful runs stop uploading redundant debug archives; failures retain diagnostics.

## 0.9.0 — Calmer trends and focused navigation

- Overview replaces rapidly changing digits with CPU, temperature, memory and
  network trend tabs. Curves use one-second source samples; numeric readings
  update every five seconds, without rolling animations.
- Two-minute in-memory history deduplicates samples, splits missing/outage
  segments and resets on binding changes. No history is fabricated for demos.
- Native left/right toolbar actions replace persistent search/filter rows and
  duplicate dashboard controls. Search opens an actual native results sheet.
- Docker lives under Services, hardware/LEDs under Devices, updates under Settings.
- Add the SDK-matched SVG renderer; native runtime 0.9.0 requires a new IPA.
- CI pins Ubuntu 24.04 and verified Node 24 Action commits instead of deprecated
  Node 20 Action revisions. macOS runner capacity remains outside app control.

## 0.8.0 — Live dashboard and native settings

- Foreground authenticated SSE snapshots with one-second host performance sampling;
  services/control inventory refresh every five seconds, hardware every ten seconds.
- Two bounded event streams leave four HTTP workers for normal and control requests;
  revocation is rechecked per event, background cancellation and reconnect backoff are native.
- Changed numeric values slide up/out and in from below; Reduce Motion disables transitions.
- Compact responsive metrics and shorter service rows retain accessible large-text layouts.
- Fourth system-owned Settings tab links to QR binding and real update screens.
- Native runtime 0.8.0 requires a new IPA; no credentials or deployment addresses are embedded.

## 0.7.1 — OTA commissioning

- Manual pull-to-refresh has one acknowledged spinner; background polling stays
  silent and duplicate pulls join the current refresh. One snapshot request replaces
  six tunnel requests, and LED writes use a separate transport without a full-page wait.
- Service search uses a native search field; JavaScript receives only the query,
  not ownership of keyboard input or cursor state.
- LED operations use a per-light 200 ms debounce, separate from the unchanged 10 s
  service/Docker/reboot cooldown. Confirmed sysfs readback updates the UI immediately
  and cannot be overwritten by the previous host sample.
- Independent OTA project is supplied through repository configuration, not source.
- About displays embedded/OTA launch source, update ID and emergency recovery state.
- Publish with an explicit SDK 57 environment and suppress account-bearing CLI logs.
- Native compatibility runtime remains 0.7.0; first OTA enablement requires this new IPA.

## 0.7.0 — Compact management

- Compact overview and searchable Docker/system service groups.
- Native Liquid Glass only; a single native-to-embedded bottom safe-area handoff.
- Confirmed LED modes and allowlisted Docker actions through a fixed-operation host
  broker, without exposing Docker socket, shell or credentials to embedded pages.
- Existing read-only deployments require explicit operator authorization for control.

## 0.3.1 — Access 扫码接入

- 扫码支持短期 Access bootstrap；批准后交付该手机独立服务凭据，不把账户管理密钥放进二维码。
- 临时交接副本在首次 API 接收确认后清除，拒绝、撤销及启动时过期清理；SQLite 启用安全删除。
- 仅从私有 stdin 接收交接配置，不在参数、日志或镜像中嵌入实际配置。

## 0.3.0 — Docker 与扫码绑定（开发预览）

- 明确 Server / iOS 两组件，新增非 root、只读 Docker Compose 与低权限宿主机指标桥。
- 新增跨架构真实容器测试与 ARM64 / AMD64 可导入镜像产物，不需要 GHCR 管理密钥。
- 新增电脑部署器、SSH 本机转发与自动打开配对浏览器。
- 原生 iPhone 相机扫码、HTTPS 域名确认、五分钟 ticket、双方六位码及浏览器批准。
- 手机本地生成独立 Token，服务端只保存摘要，可分别撤销并持久保留绑定。
- 保留原生液态玻璃导航、手动高级接入与旧 bundle/钥匙串兼容。
- 本轮未切换主板线上服务；Cloudflare Access 的手机专用接入尚需单独验收，扫码不绕过网关。

## 0.2.0 — 栖核 CoreNest

- 新增产品名、原创矢量图标、light / dark / tinted 图标资源及可复现生成脚本。
- 新增首次使用引导、显式演示入口、关于/隐私说明、读取 Bundle 的版本信息。
- iOS 26 使用原生液态玻璃标签栏，旧系统保留原生兼容分支。
- 避免每秒重建整个导航树，仅局部更新连接时效提示。
- 改善大字号下的温度与指标布局；新增 UIKit 原生标签栏 UI 自动化和真实截图导出。
- 云端改用 Xcode 26.3；同时测试 iOS 26 和旧系统分支。
- 保留 bundle ID、主板 API、校园认证及现有服务配置；本版本没有新增真实控制权限。

构建和截图的实际结果以 Actions 和本次验收记录为准；此版本仍为开发预览。

## 0.1.0 — 原型

- 原生概览、服务、网络、设置。
- 主板低权限只读 API、受限控制协议、状态最小化导出。
- 云端 iPhoneOS ARM64 未签 IPA 构建，7 项原生测试及 46 项 Python 测试通过。
