# CoreNest Server + iOS · 0.3 开发预览

## 两个交付组件

| 组件 | 部署位置 | 产物 |
| --- | --- | --- |
| CoreNest Server | 主板 ARM64 Docker | `CoreNest-Docker-arm64`，可 `docker load` 的镜像及 SHA256 |
| CoreNest iOS | iPhone / iPad | `CoreNest-unsigned-ipa`，需要自己有效签名 |

同仓维护协议、测试和文档。另有 AMD64 容器用于测试与复用，**不要在主板误装 AMD64 镜像**。CI 在真实 Docker 中分别验证两种架构，不只检查 Dockerfile 文本。

## 首次部署

先保证正常散热、SSH 稳定、Docker Compose 可用；保留原来校园网守护、Cloudflare、SSH、1Panel 和 Beszel。不要把原 SSH hostname 改成 HTTP 服务。

从电脑运行 `python tools/deploy_docker.py --ssh 你的SSH别名 --endpoint https://你的API域名`。会传送白名单文件到独立临时目录，开 SSH 终端由你本地输入 sudo 密码；密码不由 Python 收集、不写入文件。主板安装到 `/opt/corenest`，若已有安装则拒绝覆盖。源码部署会构建镜像；网络条件不好时，可从云端下载 ARM64 产物、校验 SHA256 后 `docker load -i CoreNest-server-arm64.tar.gz`，再按审核过的步骤安装桥接服务与 Compose。

主板本地部署也可在仓库根目录执行：

```sh
sudo sh deploy/install-docker.sh
```

Docker 启动不可能直接打开远方电脑上的浏览器；桌面部署器在安装、健康检查和 HTTPS 验证后打开**运行部署器的电脑**浏览器。主板无桌面时，回到电脑运行：

```powershell
python tools/pair_device.py --ssh board --endpoint https://你的API域名
```

维持终端运行到手机配对完成。浏览器链接的 fragment 是临时管理秘密，不要分享、写进工单或截图地址栏。页面加载后会移除地址栏 fragment；刷新需重新生成二维码。首次打开失败时输出私有链接；SSH 转发仅监听电脑 `127.0.0.1`。用户退出终端会关闭此次转发，不会停止主板服务。

## 安全配对

1. 操作者通过已有 SSH 权限创建五分钟 ticket（256 位随机秘密），另生成不同的 browser manager secret。
2. 页面在本机生成真实二维码，无第三方二维码 API / CDN；二维码没有长期 API Token，也没有 manager secret。
3. iOS 本机识别二维码并验证类型、版本、HTTPS 根域名、过期时间。用户确认域名后才发起网络请求。凭据不会随 HTTP 重定向发送。
4. iPhone 安全随机生成自己的 Token，只上传 SHA256 摘要。服务端锁定一次申请，显示双方相同的六位核对码；此时仍无 API 权限。
5. 浏览器核对后批准，才激活该手机的独立凭据。管理权限须生成时显式指定 `--role admin`，且操作仍受主板功能开关限制。默认 viewer 不可重启。
6. iPhone 验证 capabilities 成功后将凭据保存本机 Keychain；不覆盖尚未验证的新连接。相机帧不保存/上传，无后台常驻扫码。

只有抢到二维码还不能访问设备，必须得到浏览器确认。配对请求有持久的分钟预算，失败不无限重试；过期、拒绝、关闭手机页面会停止等待。新二维码作废所有旧的未完成请求，不撤销已经绑定的设备。

查看/撤销（主板管理员终端）：

```sh
cd /opt/corenest
docker compose exec -T server python /app/pairing.py list
docker compose exec -T server python /app/pairing.py revoke 设备ID
```

列表不返回 Token 或摘要；撤销对下一次 API 请求立即生效。手机删除本地连接不等于撤销服务端凭据。手机退出配对或网络失败发生在批准之后时，可能留下未保存的有效凭据，需用以上命令撤销后重新配对。

## Docker 与主板数据的边界

默认只发布 `127.0.0.1:18766`，独立于原 systemd API 的 `18765`。现有 API 不自动停用或覆盖。容器固定非 root UID10001、只读根文件系统、所有 capabilities 删除、禁止提权、128MiB 内存限制、64 PID、轮转日志。

**不挂载 Docker socket、系统 D-Bus、根分区、校园网账号目录或 SSH/Cloudflare 凭据**，不使用 privileged/host network。`/data` 独立命名 volume 持久保留配对摘要、撤销状态与动作账本；不要 `docker compose down -v`，否则会删除设备绑定。

为了测量真实主板，附带一个低权限、只读的 `corenest-host.service`，由安装器安装，与容器一起属于 Server 交付包。它导出有限的主板 CPU/内存/根分区/温度/网速/六个 systemd 状态，以及已脱敏的校园网状态。容器仅只读挂载 `/run/corenest-host`；过期或缺失返回503，不显示容器数据冒充主板。没有原校园网安全导出器时，校园网状态显示未知，不尝试读取其私有账号。

**本容器版暂不提供 systemd 控制和原始/生命周期日志导出。**控制项默认关闭，保留原有服务与协议，不为了开启按钮获取宿主机 root 权限。

正常 `docker compose restart` / 主板重启会保留绑定。Docker restart policy 与 host bridge enable 配合恢复；校园网认证/隧道完全离线时无法保证手机可达。升级前备份 volume、记录镜像摘要与单位文件；当前安装器不会自动覆盖已有版本。

## HTTPS 与 Cloudflare Access 仍是独立验收项

配对不是网络穿透。要从手机互联网访问，需独立 HTTPS hostname 指向 `http://127.0.0.1:18766`。不能填 `ssh.example.com`，不能把 loopback URL 直接拿给异地手机，不开放校园网入站。

公网 API 保留 Cloudflare Access。0.3.1 支持由操作者从私有 stdin 提供短期 bootstrap 与独立手机服务凭据：`pairing.py create --access-stdin`。二维码只携带短期 bootstrap，不包含长期手机凭据或账户管理密钥；手机扫码后通过 Access 发起配对，浏览器批准后才经 HTTPS 获取该手机长期凭据。手机首次正常 API 请求确认收取后，服务端清除临时交接副本；拒绝、撤销和重启发现过期时也清除副本。

临时交接数据位于受保护的配对数据库，启用 SQLite secure_delete；不应将运行时数据库或真实 QR 上传。账户管理密钥留在操作者电脑，不复制到主板。操作者负责签发、过期/失败清理及 Access 策略；默认通用部署器不会接管 Cloudflare 账户。不要复用电脑 SSH token，不配置 Everyone/Bypass。

## 测试范围

本地单元测试覆盖配对流程、权限、单次并发、过期、撤销、重启后数据库恢复和容器采集失效。GitHub Actions 编译真实 iOS26/旧版系统 UI 并构建未签 IPA；另外构建运行 AMD64/ARM64 容器验证注册 → 批准 → API → 重启 → 撤销。

模拟器测试不能替代 iPhone 摄像头和互联网联网验收；容器集成测试中的主板数据是明确标记的 fixture。未成功连接主板或尚未配置 HTTPS/Access 时，不能声称已部署或手机已连通。
