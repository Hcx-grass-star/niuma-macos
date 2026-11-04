# 牛马上班（macOS）

以当前收入提供上班鼓励的轻量菜单栏工具，适配 Apple Silicon 与 Intel 机型，最低 macOS 13。

## 原生开发版

当前已有 Swift + AppKit 原生工程，无第三方运行依赖。已在本机 M5、macOS 27.2、Swift 6.4.2 命令行工具链上构建，尚未完成正式发布验收。

```bash
# 构建通用（arm64 + x86_64）应用包，并验证本地临时签名。
bash scripts/build-app.sh

# 打开应用；首次使用需要填写自己的工资，程序不会生成示例工资。
open build/牛马上班.app

# 运行真实文件保存、重载和收入计算的集成验证。
swift run --disable-automatic-resolution NiumaIntegrationTests
```

可运行的开发包位于 `build/牛马上班.app`。构建产物不纳入 Git。当前采用本机临时签名，尚未进行 Developer ID 签名或公证，不作为公开分发包。

## 打包分享

```bash
# 生成 dist/牛马上班-<版本>-macOS-universal.zip，内含 .app 与「安装说明.txt」。
bash scripts/package-release.sh
```

默认走 ad-hoc 临时签名，对方解压后首次打开需在「系统设置 → 隐私与安全性」点「仍要打开」，或先执行一次 `xattr -dr com.apple.quarantine`。

配置 Developer ID 后，同一脚本会自动签名、公证并装订，接收方双击即可打开，不再需要放行步骤：

```bash
xcrun notarytool store-credentials niuma-notary --apple-id <账号> --team-id <团队ID> --password <专用密码>
DEVELOPER_ID_APP="Developer ID Application: 名字 (团队ID)" NOTARY_PROFILE=niuma-notary bash scripts/package-release.sh
```

兼容范围：最低 macOS 13 Ventura，最高跟随构建 SDK；打包为 arm64 + x86_64 通用二进制，Apple Silicon 与 Intel 均为原生运行。版本下限由 `Package.swift` 的 `platforms` 与 `Info.plist` 的 `LSMinimumSystemVersion` 共同决定，两者须保持一致。低于 macOS 13 的系统会提示版本不足。

macOS 13/14 上使用 `if #available` 回退：无参 `NSApp.activate()` 与 `NSApplication.activate()` 自 macOS 14 起提供，旧系统改走 `ignoringOtherApps` 等价调用；`NSViewController.loadViewIfNeeded()` 需 macOS 14，改为访问 `view` 触发按需加载。登录启动依赖 macOS 13 起的 `SMAppService`，构成版本下限的技术原因。

首次启动会打开设置；保存后返回当前收入面板。后续启动默认只保留菜单栏叶子图标，点击展开。隐藏金额会同时隐藏设置页工资。原生快捷键：`⌘I` 查看收入、`⌘,` 打开设置、`⌘Q` 退出（应用处于激活状态时）。

## 当前内容

- [需求文档](docs/需求文档.md)：当前版本 v0.4，包含首版规则、M5 资源预算和 34 个验收场景。
- [交互原型](prototype/index.html)：可直接在浏览器打开，体验当前收入、工资作息设置和工作状态预览。
- [原型源片段](prototype/niuma-income.fragment.html)：用于维护交互原型；`index.html` 是供浏览器打开的导出版。
- `Sources/NiumaCore`：工资排班校验、跨夜收入计算和原子配置存储。
- `Sources/Niuma`：原生菜单栏、收入面板、设置和按需刷新。
- `Tests/NiumaCoreTests`：不依赖 XCTest 的集成验证程序，适用于当前命令行 SDK。
- [本机验证记录](docs/verification/native-baseline.md)：记录实际检查、资源基线和未验证项目。

## 使用说明

双击 `prototype/index.html`，或将其拖入浏览器。默认使用示例日期和演示时钟；工资和作息仅用于本页演示，不代表原生应用已实现配置保存、系统菜单栏或后台运行。

修改原型时，以 `prototype/niuma-income.fragment.html` 为源文件，并同步重新导出 `index.html`。

## 当前阶段

原生开发版已实现工资作息设置、月薪与日薪计算、多段休息、跨夜跨月、本地保存、金额隐藏、菜单栏收入和退出。面板隐藏且仅显示图标时停止收入刷新；面板打开或菜单栏需要显示增长中的金额时才按秒更新。

登录启动已接入系统服务并展示实际状态，但尚未完成安装后的注册与真实重新登录验收。休眠恢复、完整资源窗口和连续运行 8 小时等项目仍需验证，不能将开发包视为已通过全部验收。

## 配置、重置与卸载

应用只使用以下配置文件，不保存收入历史，不建立专用缓存或文件日志：

```text
~/Library/Application Support/com.hcxgrassstar.niuma/settings.json
```

“清除设置并重置”会先关闭应用管理的自动启动，再移除自己的配置文件；不删除目录中的未知文件。若关闭启动或删除文件失败，界面说明原因并保留恢复入口。

本机安装时将 `.app` 复制到“应用程序”后打开。卸载前先关闭自动启动，按需要执行重置，再退出并移除 `.app`。只删除 `.app` 不代表已经清除配置。

## 资源检查

资源采样工具只读取内核的 physical footprint 和 CPU 累计时间，不读取工资数据。测量时保持被测界面状态不变，正式验收须预热 60 秒，并按需求执行 600 秒稳定采样。

```bash
# 用应用的实际 PID 替换 12345；采样工具不属于被测应用进程。
xcrun swift scripts/measure-resources.swift 12345 600 build/resource-check.json
```

本次记录属于短时开发基线，不能代替四种显示模式的完整窗口或 8 小时稳定性验收。

需求文档和原型文件统一存放在本项目，旧位置的兼容链接已删除。请使用本项目中的文档和原型入口；之前会话中引用旧路径的链接或预览可能失效。
