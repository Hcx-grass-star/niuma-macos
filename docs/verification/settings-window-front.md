# 设置窗口前置修复验证

日期：2026-11-05。范围：原生 macOS 应用点击设置后被其他普通应用遮挡的问题。

## 问题与修复

原显示流程先调用 `showWindow`，再使用 macOS 14 及以上的 `NSApp.activate()` 请求协作激活。本机 SDK 明确说明该请求不保证立即激活，甚至可能不激活；应用未激活时，普通窗口显示操作未将设置窗口排到另一个应用之前。

仅调整 `AppDelegate.showSettings`：针对打开设置这一明确操作，使用带 `ignoringOtherApps: true` 的激活调用，随后显式设置键盘焦点并调用 `orderFrontRegardless`。窗口仍为普通层级，复用已有设置窗口，收入面板的激活方式不变。

参考：本机 SDK 的 `NSApplication.h`、`NSWindowController.h` 和 [Apple 协作激活说明](https://developer.apple.com/de/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation)。DeepWiki 本次返回安全校验页面，没有作为技术证据。

## 同对象 RED / GREEN

使用临时 `FocusHost` 和 `FocusCover` 两个真实 AppKit 应用进程。Host 使用项目实际 AppDelegate、设置窗口和收入面板；只替换测试应用标识及配置目录，使用隔离示例工资，并关闭更新请求。Cover 是可覆盖设置页的独立普通应用。

每次先激活 Cover，再通过 Host 的实际设置动作打开设置；等待 300ms 后，仅采集这两个测试进程的普通窗口排序、Host 激活状态、设置窗口焦点及数量，不保存其他应用的标题或图像。

| 场景 | 修复前 | 修复后 |
| --- | --- | --- |
| 从非激活状态首次打开设置 | Cover 在前；Host 未激活、设置无键盘焦点 | Host 设置在前，应用激活且设置获得键盘焦点 |
| 设置已打开后再次打开 | Cover 仍在前，设置无焦点 | 设置在前且有焦点；窗口数量 1、窗口编号保持一致 |
| 从收入弹出面板点击设置按钮 | Cover 仍在前，设置无焦点 | 设置在前且有焦点；复用同一窗口 |

另验证切换回 Cover 后，其他应用可以正常覆盖设置窗口；关闭设置后窗口数量为 0，重新打开后创建单一新窗口并再次前置和获得焦点。

## 构建与边界

使用本地 Swift 工具链重建通用应用并验证临时签名；本次未改变工资配置，也未关闭用户原先运行的应用进程。

以上是本机普通窗口、同一工作桌面下的两进程验证。未声明 macOS 13/Intel 实机、多显示器、全屏应用或跨 Space 场景全部通过。测试进程、示例配置和临时脚本验证完成后清理。
