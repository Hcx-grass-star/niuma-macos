# 0.4.0 发布前验收

日期：2026-11-12。范围：原生 Swift/AppKit macOS；Windows 新功能未移植，本次不交付 Windows 包。源码以 `v0.4.0` 标签为准，归档分支 `release/0.4.0`，原生构建号11。

## 已执行

| 检查 | 结果 |
| --- | --- |
| `npm run test:core` | 收入与倒计时共享逻辑通过 |
| `npm run test:updates` | JavaScript 与 Swift 实际 HTTP 主备更新源、版本、URL、平台及异常检查通过；Swift 18组集成检查通过 |
| `swift run --disable-automatic-resolution NiumaIntegrationTests` | 18组收入、战报、愿望、持久化、倒计时和更新检查通过 |
| `bash scripts/test-native-ui.sh --panel-regression` | 带焦点和输入时序日志连续两轮通过：后台展开、反复切换、隐私、系统失焦、Esc、设置及释放 |
| `bash scripts/test-native-ui.sh --appearance-config` | 保存/取消/重载、玻璃、主题、染色、尺寸和释放通过 |
| `bash scripts/test-countdown-ui.sh` | 到期调度、编辑保存、隐藏期间删除及回读通过 |
| `bash scripts/test-cheer-ui.sh` | 愿望管理、首页卡片几何及点击、隐私、木鱼实际呈现变化/命中计数/归位/暂停、调薪与失败回滚通过 |
| `npm run test:installation` | 安装文件覆盖、回滚、身份/降级/篡改/符号链接拒绝及限定清理通过 |
| `python3 scripts/test-macos-installation.py` | 隔离真实进程手动归位升级、启动失败恢复旧版、工资配置保留通过 |
| `python3 scripts/test-sparkle-installation.py` | 真实 Sparkle 下载、损坏签名拒绝、正确签名替换与重启、配置保留通过 |

所有测试使用独立配置和临时身份，不读取、覆盖或清理用户正式工资与愿望。依赖沿用本地锁定文件和缓存。

## 焦点失败与测试修正

最初后台展开检查发生过取得焦点后收起的失败，随后两次完整后台回归通过。追加只读诊断后，外观测试明确记录到 AccessClient 取得前台、应用收到失焦通知、面板按设计收起，再于两秒后触发旧断言失败；不能据此修改产品关闭策略。

外观测试现在紧跟保存时排入的返回面板任务，检查真实键盘焦点、落盘配置、材质、颜色和尺寸，再主动关闭，由后续阶段确认释放；另以计数断言保证两次检查均已执行，未删除原有验证要求。修改后整套外观流程通过。早期失败日志一并保留，不推断已经证明所有失焦失败均由外部输入造成。

## 视觉核对

本次新生成的隔离原生截图及27帧木鱼动图保存在 [release-0.4.0](release-0.4.0/)。已目视检查横向愿望摘要、双列卡片、原型配色、说明移除及木鱼外观。几何、导航、金额隐藏和动画状态另由真实控件断言验证。

## 未验收范围

未完成 Intel/macOS13 真机、实际锁屏/睡眠系统信号及通知到达、重新登录启动、音效听验、8小时运行与 Windows 新功能移植。本次通用包的编译和签名检查不代替上述真机验收。

安装包签名、公开附件、源码归档引用和更新源的一致性在发布时另外回读；最终结果写入本机 `dist/release-0.4.0-verification.json`，不移动已发布标签。
