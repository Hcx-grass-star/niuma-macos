# 牛马上班应用图标

2026-11-12：当前图标采用用户确认的「奶油小牛」手绘矢量稿：短圆脸、小牛角、可可色斑纹、浅焦糖鼻口和米色底。源文件为 `Artwork/AppIcon.svg`，确认稿与组合预览保存在 `../docs/design/round-cow/`。`AppIcon.png`（1024×1024）与 `AppIcon.icns` 均由该源稿导出；面板使用 `../Sources/NiumaCore/Resources/AppIcon.png`（128×128）。菜单栏源稿为 `Artwork/MenuBarCow.svg`，导出透明黑色 PNG（72×72），沿用程序中的 18 点模板显示。木鱼仍使用 `Artwork/Woodfish.svg`。

导出使用本机 Sharp / librsvg 渲染，保留真实透明通道；应用图先按两倍分辨率渲染再缩至 1024 像素，随后以 Lanczos 缩放生成标准及 Retina 尺寸，使用系统 `iconutil` 打包 ICNS。以下为旧版钱币图标的历史生成说明，不代表当前资源。

## 旧版生成记录

使用内置 `image_gen` 工具生成，透明背景；原始生成图通过系统 `sips` 缩放为 1024 × 1024 PNG，再使用 `iconutil` 打包为包含标准与 Retina 尺寸的 ICNS。以下保留最终生成提示词，便于后续调整图标。

```text
Use case: logo-brand
Asset type: production macOS app icon, square 1024x1024 pixels with genuine transparent outer margins
Primary request: Create one beautiful memorable macOS application icon for “牛马上班”, a small income-progress companion for people working at their Mac.
Subject: A single bold warm-gold coin standing upright, with a simple raised ivory yuan currency symbol ¥, and a small mint-green two-leaf sprout growing from the top of the coin. This is one compact iconic composition: money quietly growing with time.
Style/medium: premium native macOS app icon, softly sculpted satin 3D relief, restrained material depth, precise silhouette, contemporary friendly visual craft.
Composition/framing: front-facing, centered, no perspective tilt. The coin and sprout form a large simple high-contrast emblem inside a deep forest-green rounded-square app tile. Tile occupies about 84 percent of the square canvas, with balanced transparent padding on all sides and fully transparent outside corners. Emblem occupies about 70 percent of tile height. Generous space around emblem inside tile.
Color palette: forest green #173E30 tile, warm pale gold #EAC878 coin, mint #B6E4BF leaves, ivory #FFF4D9 symbol. A very subtle green gradient and soft top-left lighting.
Constraints: exactly one icon, actual transparency outside the rounded square, no surrounding scene, no promotional cover, no device mockup, no caption, no application name, no tiny details, no clocks, no bar chart, no border around the canvas, no watermark. Only the single ¥ mark is allowed. Prioritize clear recognition at 32px and 64px. No painted checkerboard.
```
