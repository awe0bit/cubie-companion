# Security policy

CoreNest 仍在开发预览阶段，尚未完成独立安全审计，不应当成通用生产级主机面板。

## 当前边界

- API 只监听主板 loopback；公网连接必须经过独立 HTTPS hostname、Cloudflare Access 和设备 Bearer 令牌双重限制。
- 查看 / 管理令牌分离，服务端只保存高熵令牌摘要；0.3 Docker 版扫码签发每手机独立凭据，支持逐个撤销。原 systemd 版的旧共享令牌仍需单独轮换。
- 配对 ticket 与网页批准秘密分离，五分钟过期、一次申请、浏览器六位码核对批准；二维码不携带长期 API 或 Cloudflare 密钥。扫码不绕过 Cloudflare Access。
- Docker 默认 loopback 发布、非 root、只读根文件系统、capabilities 全部移除；不挂载 Docker socket。真实主板指标经低权限宿主机导出桥读取，失效明确报错。
- iOS 使用本机 Keychain、正常 TLS 验证、不跟随带凭据请求的重定向、不上传第三方统计。
- 控制默认关闭；root broker 未启用，校园网、Tunnel、SSH 和网络管理器不是控制白名单。
- 保留现有验证码暂停、频率预算、认证目录权限及会话，不因 UI 更新改变它们。
- 隐私清单声明应用私有 UserDefaults 的使用；连接到用户配置的服务时，Cloudflare/目标服务仍可能记录连接信息。
- Debug 截图模式不读取保存的凭据、不联网；Release 中不可用。

## 报告问题

通过私有仓库联系维护者，提交最小复现、版本及经过脱敏的错误类型。不要提交实际 Authorization、API/Access Token、校园网密码、完整 cookies 或未脱敏日志。凭据暴露后应在服务端撤销/轮换，删除手机本地数据并不足够。

校园网完全离线、需要验证码、设备断电时，本 App 无法保证自动恢复或发出离线推送。底层 Debian/Python 的维护周期和 24×7 散热可靠性需独立规划，不因 App 成功构建而获得保证。

## OTA 与构建工具链

远程 OTA 默认关闭；独立 Expo 项目授权是另一个代码发布边界，不得与其他应用共用 Token。当前未配置端到端更新签名证书；启用前需要单独评估签名与生产通道审批。原生桥不会向页面运行时提供长期凭据、任意网络请求或 shell 方法。

2026-10-26 检查的 Expo 57 锁定工具链含上游公告：构建工具的 `node-forge` 1.4.0 存在 [RSA 验签问题](https://github.com/advisories/GHSA-86w9-cpqp-85rv)，公告当时无已修复版本；Expo CLI 的 `zod` 3.x 受 [集合验证资源消耗问题](https://github.com/advisories/GHSA-mrhx-c7xc-m3w5) 影响。它们是 Node 构建／开发工具依赖，不因测试通过而消失。不要对公网开放 Metro 或把不可信证书／输入交给构建进程，不使用会把 Expo 降到不兼容旧版的 `npm audit fix --force`。这不是“依赖无漏洞”的版本，启用正式远程分发前仍需复核工具链和签名方案。
