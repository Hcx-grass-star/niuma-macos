#!/usr/bin/env python3
"""用隔离身份、目录和真实 AppKit 进程验证手动升级，绝不使用正式应用身份。"""
from pathlib import Path
import json
import os
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid
import sys

project = Path(__file__).resolve().parent.parent
workspace = Path(tempfile.mkdtemp(prefix='niuma-manual-qa-')).resolve()
token = uuid.uuid4().hex
identifier = 'com.niuma.installqa.' + token
app_name = 'NiumaQA-' + token + '.app'
tauri_mode = '--tauri' in sys.argv
receipt = workspace / 'ready.json'
apps = workspace / 'Applications'
downloads = workspace / 'Downloads/stage'
canonical = apps / app_name
incoming = downloads / app_name
package = workspace / 'package'


def run(arguments, **options):
    """固定参数调用工具，失败立即停止，不通过 shell 拼接测试路径。"""
    return subprocess.run(arguments, check=True, **options)


def stop_owned_processes():
    """仅结束命令行指向本次随机测试目录的应用及助手，不按正式应用名匹配。"""
    for line in subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and str(workspace) in fields[1] and '/Contents/' in fields[1]:
            try:
                os.kill(int(fields[0]), signal.SIGTERM)
            except ProcessLookupError:
                pass


def wait_for(predicate, label, timeout=50):
    """以可观察状态等待，不把固定延迟或 open 命令成功当作安装成功。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except (FileNotFoundError, json.JSONDecodeError, ProcessLookupError):
            pass
        time.sleep(0.1)
    debug = workspace / 'helper-error.json'
    entry = workspace / 'entry.json'
    raise RuntimeError(label + ('; ' + debug.read_text(encoding='utf-8') if debug.exists() else '') + ('; ' + entry.read_text(encoding='utf-8') if entry.exists() else ''))


def read_receipt():
    """只读取本次测试应用写入的启动回执。"""
    return json.loads(receipt.read_text(encoding='utf-8'))


def fixture(path, version, crashing=False):
    """安装包包含实际原生入口和助手，仅替换测试身份、安装目录及应用委托。"""
    (path / 'Contents/MacOS').mkdir(parents=True)
    (path / 'Contents/Helpers').mkdir()
    shutil.copy2(tauri_binary if tauri_mode else binary / 'FixtureApp', path / 'Contents/MacOS/FixtureApp')
    (path / 'Contents/Resources').mkdir()
    if tauri_mode:
        (path / 'Contents/Resources/qa-version').write_text(version, encoding='utf-8')
        if crashing:
            (path / 'Contents/Resources/qa-crash').touch()
    helper = path / ('Contents/Resources/NiumaInstaller' if tauri_mode else 'Contents/Helpers/NiumaInstaller')
    shutil.copy2(binary / 'FixtureHelper', helper)
    info = dict(CFBundleIdentifier=identifier, CFBundleName=path.stem, CFBundleExecutable='FixtureApp',
                CFBundlePackageType='APPL', CFBundleShortVersionString=version, CFBundleVersion=version,
                LSUIElement=True, LSMultipleInstancesProhibited=False, NiumaInstallOnLaunch=True,
                CrashOnInstalledLaunch=crashing)
    (path / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run(['codesign', '--force', '--sign', '-', '--identifier', identifier + '.installer', str(helper)], stderr=subprocess.DEVNULL)
    run(['codesign', '--force', '--sign', '-', str(path)], stderr=subprocess.DEVNULL)


try:
    apps.mkdir()
    downloads.mkdir(parents=True)
    for name in ['NiumaCore', 'NiumaInstallation', 'FixtureApp', 'FixtureHelper']:
        (package / 'Sources' / name).mkdir(parents=True)
    shutil.copy2(project / 'Sources/NiumaCore/UpdateService.swift', package / 'Sources/NiumaCore/UpdateService.swift')
    shutil.copy2(project / 'Sources/NiumaInstallation/BundleReplacement.swift', package / 'Sources/NiumaInstallation/BundleReplacement.swift')
    source = (project / 'Sources/NiumaInstallation/ManagedInstallation.swift').read_text(encoding='utf-8')
    source = source.replace('"com.hcxgrassstar.niuma"', json.dumps(identifier)).replace('"牛马上班.app"', json.dumps(app_name))
    source = source.replace('"/Applications"', json.dumps(str(apps))).replace('"/Applications/"', json.dumps(str(apps) + '/'))
    source = source.replace('FileManager.default.homeDirectoryForCurrentUser', 'URL(fileURLWithPath: ' + json.dumps(str(workspace)) + ')')
    source = source.replace('manager.homeDirectoryForCurrentUser', 'URL(fileURLWithPath: ' + json.dumps(str(workspace)) + ')')
    source = source.replace('niuma-installation.lock', 'niuma-qa-' + token + '.lock')
    (package / 'Sources/NiumaInstallation/ManagedInstallation.swift').write_text(source, encoding='utf-8')
    entry_source = (project / 'Sources/Niuma/main.swift').read_text(encoding='utf-8')
    trace = 'try! JSONSerialization.data(withJSONObject: ["bundle": Bundle.main.bundleURL.absoluteString, "path": Bundle.main.bundleURL.standardizedFileURL.path, "name": ManagedInstallation.applicationName, "id": ManagedInstallation.identifier, "canonical": CANONICAL, "shouldInstall": ManagedInstallation.shouldInstall(Bundle.main.bundleURL), "pid": ProcessInfo.processInfo.processIdentifier]).write(to: URL(fileURLWithPath: ENTRY))\n'.replace('CANONICAL', json.dumps(str(canonical))).replace('ENTRY', json.dumps(str(workspace / 'entry.json')))
    entry_source = entry_source.replace('// 正式包先完成归位', trace + '// 正式包先完成归位')
    (package / 'Sources/FixtureApp/main.swift').write_text(entry_source, encoding='utf-8')
    delegate = '''import AppKit
import NiumaInstallation
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static let identifier = ManagedInstallation.identifier
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "CrashOnInstalledLaunch") as? Bool == true { exit(73) }
        try! ManagedInstallation.confirmStartup()
        let result: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String, "path": Bundle.main.bundleURL.path, "pid": ProcessInfo.processInfo.processIdentifier]
        try! JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: RECEIPT), options: .atomic)
    }
}
'''.replace('RECEIPT', json.dumps(str(receipt)))
    (package / 'Sources/FixtureApp/Delegate.swift').write_text(delegate, encoding='utf-8')
    helper = (project / 'Sources/NiumaInstaller/main.swift').read_text(encoding='utf-8')
    helper_debug = '''
        let parent = arguments.count > 3 ? Int32(arguments[3]).flatMap { NSRunningApplication(processIdentifier: $0) } : nil
        let details: [String: String] = ["error": error.localizedDescription, "source": arguments.count > 2 ? arguments[2] : "", "parentURL": parent?.bundleURL?.absoluteString ?? "nil", "parentExecutable": parent?.executableURL?.absoluteString ?? "nil", "parentID": parent?.bundleIdentifier ?? "nil"]
        try? JSONSerialization.data(withJSONObject: details).write(to: URL(fileURLWithPath: DEBUG_PATH))
'''.replace('DEBUG_PATH', json.dumps(str(workspace / 'helper-error.json')))
    helper = helper.replace('} catch {\n        if !handedOff', '} catch {\n' + helper_debug + '\n        if !handedOff')
    timer = '''
// 只关闭本测试助手自己的失败提示，不操作其他进程窗口。
@MainActor func closeTestAlert(_ view: NSView) {
    if let button = view as? NSButton, button.title == "好" { button.performClick(nil) }
    for child in view.subviews { closeTestAlert(child) }
}
let dismiss = Timer(timeInterval: 0.3, repeats: true) { _ in
    MainActor.assumeIsolated { for window in NSApp.windows { if let view = window.contentView { closeTestAlert(view) } } }
}
RunLoop.main.add(dismiss, forMode: .common)
RunLoop.main.add(dismiss, forMode: .modalPanel)
'''
    helper = helper.replace('app.run()', timer + '\napp.run()')
    (package / 'Sources/FixtureHelper/main.swift').write_text(helper, encoding='utf-8')
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "InstallationQA", platforms: [.macOS("13.0")], targets: [
    .target(name: "NiumaCore"), .target(name: "NiumaInstallation", dependencies: ["NiumaCore"]),
    .executableTarget(name: "FixtureApp", dependencies: ["NiumaCore", "NiumaInstallation"]),
    .executableTarget(name: "FixtureHelper", dependencies: ["NiumaInstallation"])
])
''', encoding='utf-8')
    for product in ['FixtureApp', 'FixtureHelper']:
        run(['swift', 'build', '-c', 'release', '--product', product, '--disable-automatic-resolution'], cwd=package)
    binary = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=package, text=True).strip())
    if tauri_mode:
        rust = workspace / 'rust'
        rust.mkdir()
        for name in ['Cargo.toml', 'Cargo.lock', 'build.rs']:
            shutil.copy2(project / 'src-tauri' / name, rust / name)
        for name in ['src', 'icons', 'capabilities']:
            shutil.copytree(project / 'src-tauri' / name, rust / name)
        config = json.loads((project / 'src-tauri/tauri.conf.json').read_text(encoding='utf-8'))
        config['identifier'] = identifier
        config['productName'] = 'NiumaQA-' + token
        config['build']['frontendDist'] = str(project / 'frontend')
        (rust / 'tauri.conf.json').write_text(json.dumps(config), encoding='utf-8')
        lib = (rust / 'src/lib.rs').read_text(encoding='utf-8')
        anchor = '            let income = MenuItem::with_id'
        probe = r'''            // 仅隔离测试副本写入回执，正式源码无测试开关。
            let qa_resources = macos_bundle_path()?.join("Contents/Resources");
            if qa_resources.join("qa-crash").exists() { std::process::exit(73); }
            let qa_version = std::fs::read_to_string(qa_resources.join("qa-version"))?;
            std::fs::write(RECEIPT, serde_json::to_vec(&serde_json::json!({"version": qa_version, "path": macos_bundle_path()?.to_string_lossy(), "pid": std::process::id()}))?)?;
'''.replace('RECEIPT', json.dumps(str(receipt)))
        lib = lib.replace(anchor, probe + anchor)
        (rust / 'src/lib.rs').write_text(lib, encoding='utf-8')
        cargo = shutil.which('cargo')
        if not cargo:
            raise RuntimeError('Tauri 进程验收需要配置本地 Cargo 工具链和依赖缓存。')
        env = dict(os.environ, CARGO_TARGET_DIR=str(project / 'src-tauri/target'))
        run([str(cargo), 'build', '--release', '--locked', '--offline'], cwd=rust, env=env)
        tauri_binary = project / 'src-tauri/target/release/niuma'
    wages = workspace / 'salary-settings.json'
    wages.write_text('{"salary":21000,"schedule":"09:00-18:00"}', encoding='utf-8')
    original_data = wages.read_bytes()
    for crashing in [False, True]:
        stop_owned_processes()
        for app in [canonical, incoming]:
            if app.exists():
                shutil.rmtree(app)
        receipt.unlink(missing_ok=True)
        fixture(canonical, '0.2.1')
        plan = subprocess.run([str(canonical / ('Contents/Resources/NiumaInstaller' if tauri_mode else 'Contents/Helpers/NiumaInstaller')), 'plan', str(canonical)])
        if plan.returncode != 0:
            raise RuntimeError('测试正式目录未被安装助手识别，避免继续等待应用启动。')
        run(['open', '-n', '-g', str(canonical)])
        wait_for(lambda: read_receipt()['version'] == '0.2.1', '旧测试应用未启动')
        old_pid = read_receipt()['pid']
        receipt.unlink()
        fixture(incoming, '0.3.0', crashing)
        run(['open', '-n', '-g', str(incoming)])
        expected = '0.2.1' if crashing else '0.3.0'
        wait_for(lambda: read_receipt()['version'] == expected and read_receipt()['pid'] != old_pid, '未完成启动交接或失败回滚')
        if crashing:
            assert incoming.exists(), '失败时下载源不应被清理'
            assert plistlib.loads((canonical / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'] == '0.2.1'
            print('PASS: 新版启动失败，恢复并重启旧版，保留下载源。', flush=True)
        else:
            wait_for(lambda: not incoming.exists(), '启动成功后未清理下载副本')
            assert read_receipt()['path'] == str(canonical)
            print('PASS: 手动打开新版 -> 退出旧进程 -> 归位覆盖 -> 新版启动 -> 回收旧包及下载副本。', flush=True)
        assert wages.read_bytes() == original_data
    print('PASS: 两种真实进程场景中工资及排班配置均保持原样。', flush=True)
finally:
    stop_owned_processes()
    for app in [canonical, incoming]:
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    trash = Path.home() / '.Trash'
    for app in trash.glob('*.app'):
        if not (app.name.startswith('NiumaQA-' + token) or app.name.startswith('.niuma-previous-')):
            continue
        try:
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            if info.get('CFBundleIdentifier') == identifier:
                shutil.rmtree(app)
        except (OSError, ValueError):
            pass
    (Path(tempfile.gettempdir()) / ('niuma-qa-' + token + '.lock')).unlink(missing_ok=True)
    for parent in ['Library/Application Support', 'Library/Caches', 'Library/WebKit', 'Library/HTTPStorages']:
        own_data = Path.home() / parent / identifier
        if own_data.is_dir():
            shutil.rmtree(own_data)
    (Path.home() / 'Library/Preferences' / (identifier + '.plist')).unlink(missing_ok=True)
    shutil.rmtree(workspace)
