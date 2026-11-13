# 收入面板显示选择验证

日期：2026-11-05；分支：`codex/month-income-menubar`。

## 改动

- 移除收入面板底部左侧状态文字，保留设置、退出和顶部工作状态；节假日休息、调休上班的依据在顶部呈现。
- 设置新增“收入面板显示”：当前已赚、本月预估已赚、本年预估已赚可以独立勾选。取消时连同该金额的标题及说明整体收起。
- 原生面板随可见内容调整高度；允许三项全部关闭，仍可查看状态、进入设置和退出。
- 新字段 `showCurrentIncome`、`showMonthlyIncome`、`showYearlyIncome` 默认 `true`，旧配置缺失字段时继续全部显示。保存后重启保留选择，取消修改不改变已生效配置。
- 此选择控制面板展示，不改变收入计算、全局金额隐藏或菜单栏所选指标。

## 实测结果

| 项目 | 结果 |
| --- | --- |
| Swift 真实文件集成 | 13 组通过；新显示偏好的 8 种组合保存重载一致，旧配置默认全部开启，收入和菜单栏金额不变 |
| AppKit 视图 | 同一实际控制器验证 8 种组合后重新全部显示，标题与金额整体隐藏/恢复；底部状态文本不存在 |
| 原生面板高度 | 全部显示 438pt，仅本月 256pt，全关 202pt；其他组合均能正常排布 |
| 原生设置操作 | 实际按钮点击关闭当前/本年，保存回调写入隔离目录；重新加载和重开窗口后勾选仍为仅本月 |
| 浏览器设置操作 | ego-browser 实际操作 8 种组合，整块可见状态一致；刷新和重新打开设置后恢复仅本月；菜单栏选择保持 month |
| 隐私回归 | 原生和浏览器隐藏金额后，已显示金额均遮蔽 |
| JS 核心与静态检查 | `npm run test:core`、`node --check frontend/app.js`、`git diff --check` 通过 |
| 原生应用包 | `bash scripts/build-app.sh` 成功；arm64 + x86_64 通用包，临时签名验证通过 |

AppKit 验证使用隔离测试配置和受控时刻（2026-11-04 14:00，Asia/Shanghai），不修改用户实际配置或系统时钟。浏览器使用测试工资和浏览器当时的时钟。Tauri 原生构建与系统托盘实机行为仍未验证。

## 截图

- [原生设置选项](income-visibility-settings.png)
- [原生全部显示](income-visibility-7.png)
- [原生仅本月](income-visibility-2.png)
- [原生全部关闭](income-visibility-0.png)
- [前端设置选项](income-visibility-web-settings.png)
- [前端仅本月](income-visibility-web-month.png)
