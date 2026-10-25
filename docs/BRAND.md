# 栖核 CoreNest

让设备与服务，各归其位。

产品定位：开发板服务的原生控制台。当前支持单台 Radxa Cubie A7S；不把未实现的多设备、容器管理和自动部署能力写成卖点。

## 名称与识别

- 中文名：栖核。
- 英文名：CoreNest，大小写固定。
- 显示名称：主屏幕显示“栖核”；欢迎页和关于页显示“栖核 CoreNest”。
- 这是本项目的产品名称，不表示已做商标注册或全市场名称清查。
- 内部 target 为 `Cubie`，通用示例 Bundle ID 为 `org.corenest.app`；不在源码硬编码操作者的域名或仓库账户。正式签名请配置自己的标识，更换标识会改变应用的安装身份。

图形由开放的 C 形巢、中心核心及连接节点组成。使用墨绿、薄荷与克制的留白。图标是原创确定性矢量几何，不依赖远程图片、生成服务、第三方字体或 SF Symbols 拼贴。

## 资源

- 单一源数据：`brand/identity.json`。
- 矢量导出：`brand/exports/*.svg`。
- App Icon：1024×1024、RGB、不带透明通道的 light / dark / tinted 三套。
- 应用内标记：透明的浅/深色 PNG。
- 生成工具：`python tools/generate_brand.py`，需 Pillow；提交导出文件，终端用户和 CI 无需安装 Pillow。
- `brand/exports/manifest.json` 和 Python 测试校验图标尺寸、通道、三种外观及哈希。

## 界面原则

- 内容区域使用系统语义色、标准 SF 字体和可伸缩文字，不把整个屏幕铺满玻璃材质。
- iOS 26+：用 Xcode 26 SDK 编译的原生 `TabView` / `Tab`，由系统绘制 Liquid Glass；向下滚动时允许系统缩小标签栏。
- iOS 17–25：原生旧标签栏；不覆盖 UIKit appearance，不画仿制的玻璃胶囊。
- 系统负责“降低透明度”“减少动态效果”等辅助功能适配；不强行覆盖这些偏好。
- 首次使用先说明用途与安全边界；演示要显式标记，不能伪装实时数据。
- 截图来自真实模拟器，截图模式只存在于 Debug，使用演示数据且跳过钥匙串和联网。

官方依据：[Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)、[tabBarMinimizeBehavior](https://developer.apple.com/documentation/swiftui/tabbarminimizebehavior)。
