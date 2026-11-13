# 第一期：中国节假日与调休验证

日期：2026-11-05
分支：`codex/phase1-china-holidays`

## 已实现范围

- 设置开关默认关闭，旧配置缺少字段时按关闭读取。
- 内置 2026 年国务院办公厅安排；2027 年没有官方调休通知，开启后显示缺失提示并按每周排班回退。
- 明确休息日覆盖每周排班并取消班次，明确补班日创建班次；普通日期沿用每周排班。
- 当前班次、本年预估收入和月薪自动折算共用调整后的有效排班日数；固定折算天数保持不变。
- 原生 Swift 和 Tauri 共享实现等价，界面显示“节假日休息”“调休上班”或缺失年份回退依据。

## 官方数据

2026 年安排来源：国务院办公厅《关于 2026 年部分节假日安排的通知》（国办发明电〔2025〕7 号）。

来源：[政府门户转载的通知全文](https://www.beijing.gov.cn/zhengce/zhengcefagui/202511/t20251104_4258873.html)

年度数据唯一维护源为 `shared/china-holidays.json`；`npm run sync:frontend` 生成普通 ES 数据模块并同步 Swift 资源与前端副本。后续发现 JSON import assertion 不被当前 Chromium 支持，已改用生成的普通 ES 模块。原生打包脚本同步携带 SwiftPM 资源 bundle。

## 验证结果

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 共享收入核心 | PASS | `npm run test:core`；覆盖 2026 放假日、补班日、2027 缺失回退、开关关闭回归 |
| Swift 原生收入集成 | PASS | `swift run --disable-automatic-resolution NiumaIntegrationTests`；11 组全部通过 |
| 2026 年 1 月自动折算 | PASS | 周一至周五配置从 22 个有效日调整为 21 个，补班日纳入计算 |
| 固定折算 | PASS | 既有 Swift/Node 固定折算回归继续通过 |
| Tauri 前端资源同步 | PASS | `npm run sync:frontend` 完成，前端核心与年度 JSON 已更新 |

## 未验证

- 尚未在正式 `.app` 或 Windows Tauri 安装包中完成 UI 实机验收。
- 2027 年官方安排发布后，需要更新年度 JSON、重新同步前端并重跑两套核心测试。
