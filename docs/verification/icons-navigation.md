# 图标与原型导航修正

2026-11-12，原生macOS开发版。根据用户选定的A「微笑小牛」及导航截图反馈实施。

后续0.4.0发布前复验及焦点诊断见 [0.4.0验收](release-0.4.0.md)，以下失败和指纹保留为历史记录。

后续木鱼页已改为独立木槌和鱼身的动态敲击，最新交互与构建验证见 [木鱼动态交互](woodfish-interaction.md)。下文指纹保留为本轮图标修正的历史记录。

## 修改

- 应用图标使用 `Resources/Artwork/AppIcon.svg`，同步导出 `Resources/AppIcon.png`、多尺寸ICNS及面板用PNG。
- 菜单栏使用 `Resources/Artwork/MenuBarCow.svg` 的单色模板，面板标题使用彩色小牛。图稿通过已有核心资源Bundle打包，不依赖外部路径或网络。
- 木鱼使用新稿 `Resources/Artwork/Woodfish.svg`：木质渐变、弧形开口、鱼眼与木槌。首页小图标和敲击页共用同一资源，替代Emoji和原先的椭圆加直线。
- 导航替换系统NSSegmentedControl。浅色轨道精确使用原型 `#f2f6ef`，选中项 `#ffffff`，主文字 `#263c32`，次要文字 `#708078`。白色选中项无系统渐变、无竖分隔线；实体底色避免被玻璃染色影响。深色模式采用原型对应的深色语义值。
- 原生NSButton保留点击和键盘操作；四页按钮显式公开辅助功能子元素。没有改工资计薪、愿望数据规则、失焦收起策略或用户外观配置。
- 构建源码指纹现在包含所有核心资源文件，PNG变更也会反映到包内NiumaSourceHash。

## 检查结果

- `bash scripts/test-cheer-ui.sh`：通过。新增四页导航点击/单选及辅助功能子元素检查，三种图稿打包加载检查；原有愿望管理、隐私、木鱼自动暂停、应用协调器和写入失败回滚检查通过。
- 原生截图已更新：`cheer-native/cheer-home.png`、`cheer-woodfish.png`、`cheer-wishes.png`、`cheer-report.png`。已人工检查导航为浅底白色选中项，以及木鱼图稿正确显示。
- CUA实际查看了重启后的开发版：确认彩色小牛和浅底导航在用户当前玻璃面板下已生效。
- `bash scripts/build-app.sh`：通用开发包构建及签名检查通过；未发布。
- `git diff --check`：通过。

## 尚未闭合的回归

`bash scripts/test-native-ui.sh --panel-regression` 本轮两次失败：第一次未取得面板焦点；带事件日志重跑后，首次展开成功，但第二次展开后立即收到DidResignKey并关闭。原因尚未锁定，不宣称完整后台焦点回归通过，也没有为视觉修正改变失焦策略。最后一次事件日志保留为 `cheer-native/icon-focus-regression.log`。

实际开发包可以打开并显示新图标和导航；这一观察不代替后台焦点自动用例。未做Intel/macOS13真机、音效听验、完整性能或8小时验证。

最终开发包源码与资源指纹：`e935416ae09b3320f3726fc5775b129c309b809a56ae8c11e282b6d625327c39`，重算与包内值一致。已再次重启到此开发包。
