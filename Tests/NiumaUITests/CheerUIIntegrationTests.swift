import AppKit
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import NiumaCore

/// 真实原生控件、真实独立文件与计时器生命周期的集成验证。
@main @MainActor
struct CheerUIIntegrationTests {
    /// 使用唯一临时目录，禁止读取或更改用户工资及愿望。
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-cheer-ui-" + UUID().uuidString)
    /// 遍历真实视图树，供按钮、文本及控件断言复用。
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    /// 按标题定位原生操作按钮，失败立即暴露缺失入口。
    static func button(_ title: String, in root: NSView) -> NSButton {
        views(root).compactMap { $0 as? NSButton }.first { $0.title == title }!
    }
    /// 用实际标识查找输入框，不依赖布局或子视图顺序。
    static func field(_ id: String, in root: NSView) -> NSTextField {
        views(root).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == id }!
    }
    /// 获取可见文本，不把隐藏页当作可见交互结果。
    static func labels(_ root: NSView) -> [String] {
        views(root).compactMap { view in (view as? NSTextField).flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : $0.stringValue } }
    }
    /// 在主线程运行计时器，验证自动木鱼没有残留任务。
    static func pump(_ seconds: TimeInterval) {
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    /// 分段计薪涉及循环小数，按远高于分的精度容差比较，不把Decimal尾差误判为重复结算。
    static func sameAmount(_ lhs: Decimal, _ rhs: Decimal) -> Bool {
        abs(lhs - rhs) < Decimal(string: "0.00000001")!
    }
    /// 可选保存真实原生视图渲染，用于视觉检查；不捕获用户桌面内容。
    static func capture(_ controller: IncomeViewController, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["NIUMA_UI_ARTIFACTS"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        controller.view.layoutSubtreeIfNeeded()
        let brand = views(controller.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == AppBuildChannel.current.displayName }!
        let box = brand.convert(brand.bounds, to: controller.view)
        let background = controller.view as! IncomePanelBackgroundView
        precondition(background.contentView.bounds.size == controller.view.bounds.size, "内容容器尺寸应同步")
        precondition(controller.view.bounds.insetBy(dx: 0, dy: 0).contains(box), "标题不可被面板边缘裁切")
        let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)!
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
        print("原生面板尺寸 \(name)：\(controller.preferredContentSize)")
    }
    /// 单独保存用户要求还原的首页区域，便于直接对照原型的愿望行和双列卡片。
    static func captureHomeSection(_ controller: IncomeViewController) throws {
        guard let path = ProcessInfo.processInfo.environment["NIUMA_UI_ARTIFACTS"] else { return }
        let section = views(controller.view).first { $0 is CheerContentView }!
        let frame = section.convert(section.bounds, to: controller.view).insetBy(dx: -18, dy: 0)
        let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: frame)!
        controller.view.cacheDisplay(in: frame, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent("home-prototype-alignment.png"))
    }
    /// 保存正在显示的图层姿态，避免静态视图截图遗漏木槌和鱼身的实际运动。
    static func captureStrike(_ button: NSButton, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["NIUMA_UI_ARTIFACTS"],
              let display = button.layer?.presentation() else { return }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(button.bounds.width * 2), pixelsHigh: Int(button.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor); context.fill(button.bounds)
        display.render(in: context)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
    }
    /// 录制真实呈现图层的一次敲击，导出可直接回看的动画证据。
    static func captureStrikeDemo(_ button: NSButton) throws {
        guard let path = ProcessInfo.processInfo.environment["NIUMA_UI_ARTIFACTS"] else { return }
        let url = URL(fileURLWithPath: path).appendingPathComponent("woodfish-interaction.gif")
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 27, nil)!
        CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        button.performClick(nil)
        for index in 0..<27 {
            pump(0.025)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(button.bounds.width * 2), pixelsHigh: Int(button.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
            context.scaleBy(x: 2, y: 2)
            context.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor); context.fill(button.bounds)
            button.layer!.presentation()!.render(in: context)
            CGImageDestinationAddImage(output, bitmap.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: index == 26 ? 0.7 : 0.035]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(output), "交互动画证据应能导出")
    }
    /// 读取隔离应用内部状态作集成断言，不修改私有状态或测试正式数据。
    static func value<T>(_ object: Any, _ name: String) -> T? {
        Mirror(reflecting: object).children.first { $0.label == name }?.value as? T
    }
    /// 用真实应用委托和可控时间验证事件、调薪和原子保存失败回滚。
    static func verifyCoordinator() throws {
        let folder = directory.appendingPathComponent("coordinator")
        let salaryStore = SettingsStore(directory: folder); let store = CheerStore(directory: folder)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .autoupdatingCurrent
        var clock = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 10))!
        var work = WorkSettings(); work.payMode = .daily; work.salary = 500
        try salaryStore.save(work)
        var preferences = CheerPreferences()
        preferences.reportsEnabled = true; preferences.notificationsEnabled = false
        preferences = try preferences.settled(at: clock, work: work, engine: IncomeEngine(calendar: calendar))
        preferences.wishes = [CheerWish(name: "测试愿望", target: 1000, seed: 0, baseline: 0)]
        try store.save(preferences)
        let domain = "niuma-cheer-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!; defaults.set(false, forKey: "updates.enabled")
        defer { defaults.removePersistentDomain(forName: domain) }
        let delegate = AppDelegate(store: salaryStore, updates: UpdateController(defaults: defaults), clock: { clock })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            if let item: NSStatusItem = value(delegate, "statusItem") { NSStatusBar.system.removeStatusItem(item) }
        }
        delegate.perform(NSSelectorFromString("cheerLeft:"), with: Notification(name: Notification.Name("com.apple.screenIsLocked")))
        clock += 60
        delegate.perform(NSSelectorFromString("cheerLeft:"), with: Notification(name: NSWorkspace.willSleepNotification))
        clock += 14 * 60
        delegate.perform(NSSelectorFromString("cheerReturned:"), with: Notification(name: NSWorkspace.didWakeNotification))
        let pending: BreakReport? = value(delegate, "breakReport"); precondition(pending == nil)
        delegate.perform(NSSelectorFromString("cheerReturned:"), with: Notification(name: Notification.Name("com.apple.screenIsUnlocked")))
        let report: BreakReport = value(delegate, "breakReport")!
        print("协调器战报：\(report.amount)")
        precondition(sameAmount(report.amount, Decimal(string: "15.625")!), "真实协调器只生成一条15分钟战报")
        NSApp.mainMenu!.items[0].submenu!.performActionForItem(at: 1)
        let editor: SettingsWindowController = value(delegate, "settingsWindow")!
        let save: (WorkSettings) throws -> Void = value(editor, "onSave")!
        work.salary = 1000
        try save(work)
        let saved = try store.load()
        print("调薪保存累计：\(saved.earned)，新工资：\(String(describing: saved.work?.salary))")
        precondition(sameAmount(saved.earned, report.amount) && saved.work?.salary == 1000, "调薪前先按旧工资结算")
        clock += 15 * 60
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let settled = try store.load()
        print("调薪后累计：\(settled.earned)")
        precondition(sameAmount(settled.earned, Decimal(string: "46.875")!), "调薪后15分钟按新工资计薪")
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        work.salary = 2000
        do { try save(work); preconditionFailure("写入失败必须拒绝发布新工资") }
        catch { let restored = try salaryStore.load(); precondition(restored?.salary == 1000) }
        try FileManager.default.removeItem(at: store.fileURL); try store.save(settled)
        editor.onClose = nil; editor.close()
        print("PASS: 真实应用事件去重、战报、调薪生效区间及写入失败工资回滚")
    }
    /// 按原生真实控件执行新增、校验、编辑、删除、隐私与木鱼生命周期。
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CheerStore(directory: directory)
        var work = WorkSettings(); work.payMode = .daily; work.salary = 500
        let engine = IncomeEngine()
        let now = Calendar.autoupdatingCurrent.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15))!
        let snapshot = try engine.evaluate(work, at: now)
        var preferences = try CheerPreferences().settled(at: now, work: work, engine: engine)
        let controller = IncomeViewController()
        let panel = IncomePanel(); panel.contentViewController = controller
        var merit = 0
        controller.onStrike = { merit += 1; return merit }
        controller.onSaveCheer = { value in try store.save(value); preferences = value }
        controller.onCheerPageChange = {
            controller.render(snapshot, settings: work)
            controller.renderCheer(preferences, report: nil, hidden: work.hideAmounts, phase: .working, away: false, merit: merit, error: nil)
        }
        controller.render(snapshot, settings: work)
        controller.renderCheer(preferences, report: nil, hidden: false, phase: .working, away: false, merit: 0, error: nil)
        panel.setContentSize(controller.preferredContentSize); panel.orderFrontRegardless()
        let navigation = views(controller.view).compactMap { $0 as? PrototypeTabs }.first!
        let tabs = views(navigation).compactMap { $0 as? NSButton }
        precondition(tabs.count == 4 && navigation.accessibilityChildren()?.count == 4)
        tabs[2].performClick(nil)
        precondition(navigation.selectedSegment == 2 && tabs.filter { $0.state == .on }.count == 1)
        tabs[0].performClick(nil)
        precondition(navigation.selectedSegment == 0)
        for asset in ArtworkAsset.allCases { precondition(NSImage(contentsOf: asset.url) != nil, "打包图稿必须可读取") }
        print("PASS: 四页原型导航点击及图稿资源打包加载")
        controller.selectCheerPage(2)
        button("＋", in: controller.view).performClick(nil)
        field("wishNameInput", in: controller.view).stringValue = "周末去海边"
        field("wishTargetInput", in: controller.view).stringValue = "0"
        button("保存愿望", in: controller.view).performClick(nil)
        precondition(preferences.wishes.isEmpty, "零目标不保存，保留输入")
        field("wishTargetInput", in: controller.view).stringValue = "30"
        button("保存愿望", in: controller.view).performClick(nil)
        let created = try store.load(); precondition(created.wishes.first?.name == "周末去海边")
        precondition(labels(controller.view).contains("¥0.00 / ¥30.00"))
        button("编辑", in: controller.view).performClick(nil)
        field("wishSeedInput", in: controller.view).stringValue = "31.25"
        button("保存愿望", in: controller.view).performClick(nil)
        precondition(labels(controller.view).contains("已达成 ✓ · 奖励由你决定"))
        precondition(!labels(controller.view).contains(where: { $0.contains("各愿望独立展示") }), "去掉红框里的说明文字")
        try capture(controller, name: "cheer-wishes")
        controller.selectCheerPage(0)
        let cards = views(controller.view).compactMap { $0 as? HomeShortcutButton }
        precondition(cards.count == 2 && abs(cards[0].frame.width - cards[1].frame.width) < 0.1 && cards.allSatisfy { $0.bounds.height == 98 }, "首页双列卡片等宽且保留完整高度")
        let left = cards[0].convert(cards[0].bounds, to: controller.view)
        let right = cards[1].convert(cards[1].bounds, to: controller.view)
        precondition(abs(right.minX - left.maxX - 12) < 0.1, "卡片间距沿用原型12点")
        precondition(labels(controller.view).contains("给自己充个电") && !labels(controller.view).contains(where: { $0.hasPrefix("还差 ") }), "首页展示精简摘要及分组标题")
        var preview = preferences
        preview.wishes[0].name = "一副降噪耳机"; preview.wishes[0].target = 3299; preview.wishes[0].seed = Decimal(string: "2712.50")!
        controller.renderCheer(preview, report: nil, hidden: false, phase: .working, away: false, merit: 0, error: nil)
        try capture(controller, name: "cheer-home"); try captureHomeSection(controller)
        button("管理愿望 ↗", in: controller.view).performClick(nil)
        precondition(navigation.selectedSegment == 2, "管理愿望文字入口可点击")
        controller.selectCheerPage(0)
        button("我的小盼头", in: controller.view).performClick(nil)
        precondition(navigation.selectedSegment == 2, "横向愿望整行可点击")
        controller.selectCheerPage(0)
        button("摸鱼战报", in: controller.view).performClick(nil)
        precondition(navigation.selectedSegment == 1, "战报整卡可点击")
        controller.selectCheerPage(0)
        button("敲敲木鱼", in: controller.view).performClick(nil)
        precondition(navigation.selectedSegment == 3, "木鱼整卡可点击")
        controller.selectCheerPage(0); work.hideAmounts = true; controller.onCheerPageChange?()
        let hiddenPreview = button("我的小盼头", in: controller.view)
        precondition(hiddenPreview.accessibilityValue() as? String == "愿望进度已隐藏" && hiddenPreview.toolTip?.contains("31.25") == false, "首页摘要及辅助功能共同隐藏金额")
        work.hideAmounts = false; controller.onCheerPageChange?()
        print("PASS: 原型首页横向愿望、双列卡片布局、四个入口跳转及隐私")
        controller.selectCheerPage(1); try capture(controller, name: "cheer-report")
        controller.selectCheerPage(2)
        work.hideAmounts = true
        controller.onCheerPageChange?()
        precondition(labels(controller.view).contains("•••• / ••••"))
        precondition(!labels(controller.view).contains(where: { $0.contains("31.25") || $0.contains("30.00") }))
        button("编辑", in: controller.view).performClick(nil)
        precondition(labels(controller.view).contains("请先显示金额，再添加或编辑愿望。"))
        work.hideAmounts = false; controller.onCheerPageChange?()
        button("删除", in: controller.view).performClick(nil)
        precondition(preferences.wishes.count == 1, "删除需确认")
        button("取消", in: controller.view).performClick(nil)
        precondition(preferences.wishes.count == 1)
        button("删除", in: controller.view).performClick(nil)
        button("确认删除", in: controller.view).performClick(nil)
        let deleted = try store.load(); precondition(deleted.wishes.isEmpty)
        controller.selectCheerPage(0)
        precondition(button("我的小盼头", in: controller.view).accessibilityValue() as? String == "添加第一个愿望", "无愿望时保留原型的添加入口")
        print("PASS: 原生愿望新增、非法输入、文件回读、编辑达成、隐私及删除确认")

        controller.selectCheerPage(3)
        let wood = button("敲木鱼", in: controller.view) as! WoodfishButton
        controller.view.layoutSubtreeIfNeeded(); pump(0.05)
        let scene = wood.layer!.sublayers!.first { $0.name == "woodfish.scene" }!
        let mallet = scene.sublayers!.first { $0.name == "woodfish.mallet" }!
        let body = scene.sublayers!.first { $0.name == "woodfish.body" }!
        try captureStrike(wood, name: "woodfish-0-idle")
        wood.performClick(nil)
        precondition(merit == 0, "落槌前不能提前记功德")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            pump(0.07)
            let raised = mallet.presentation()!.transform
            try captureStrike(wood, name: "woodfish-1-swing")
            pump(0.11)
            precondition(!CATransform3DEqualToTransform(mallet.presentation()!.transform, raised), "木槌必须移动而非整图缩放")
            precondition(body.animationKeys()?.isEmpty == false, "命中后鱼身独立轻震")
            try captureStrike(wood, name: "woodfish-2-impact")
            pump(0.10); try captureStrike(wood, name: "woodfish-3-rebound")
        } else { pump(0.03) }
        precondition(merit == 1, "一次接触只计数一次")
        pump(0.75)
        let feedback = scene.sublayers!.first { $0.name == "woodfish.feedback" }!
        let finalAngle = (mallet.presentation()!.value(forKeyPath: "transform.rotation.z") as! NSNumber).doubleValue
        let restAngle = (mallet.value(forKeyPath: "transform.rotation.z") as! NSNumber).doubleValue
        print("动画收尾：木槌角度=\(finalAngle)，静止角度=\(restAngle)，浮字透明度=\(feedback.presentation()!.opacity)")
        precondition(abs(finalAngle - restAngle) < 0.001 && feedback.presentation()!.opacity < 0.001, "木槌回到静止姿态且浮字消失")
        try captureStrike(wood, name: "woodfish-4-rest")
        wood.performClick(nil)
        for _ in 0..<10 { wood.sendAction(wood.action, to: wood.target) }
        pump(0.18); precondition(merit == 2, "落槌前连续输入合并，不排队追加计数")
        wood.performClick(nil); controller.selectCheerPage(0)
        pump(0.2); precondition(merit == 2, "切页取消未接触敲击")
        precondition(scene.sublayers!.allSatisfy { $0.animationKeys()?.isEmpty != false }, "切页清除回弹与浮字")
        controller.selectCheerPage(3)
        try captureStrikeDemo(button("敲木鱼", in: controller.view))
        try capture(controller, name: "cheer-woodfish")
        button("上班自动敲", in: controller.view).performClick(nil)
        controller.onCheerPageChange?()
        let beforeAutomatic = merit
        pump(1.8); precondition(merit == beforeAutomatic + 1, "工作中自动敲击完整落槌并记一次功德")
        controller.selectCheerPage(0)
        let stopped = merit; pump(1.7); precondition(merit == stopped, "切页后自动停止")
        controller.selectCheerPage(3)
        button("敲木鱼", in: controller.view).performClick(nil)
        controller.renderCheer(preferences, report: nil, hidden: false, phase: .resting, away: false, merit: merit, error: nil)
        let resting = merit; pump(1.7); precondition(merit == resting, "午休暂停")
        button("敲木鱼", in: controller.view).performClick(nil)
        controller.renderCheer(preferences, report: nil, hidden: false, phase: .working, away: true, merit: merit, error: nil)
        pump(1.7); precondition(merit == resting, "离开期间暂停")
        controller.renderCheer(preferences, report: nil, hidden: false, phase: .working, away: false, merit: merit, error: nil)
        button("敲木鱼", in: controller.view).performClick(nil)
        controller.stopCheer(); panel.close()
        let closed = merit; pump(1.7); precondition(merit == closed, "关闭后不残留自动敲击")
        controller.onCheerPageChange = nil
        print("PASS: 原生手动木鱼、自动模式、切页/午休/离开/关闭暂停")
        try verifyCoordinator()
    }
}
