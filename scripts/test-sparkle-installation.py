#!/usr/bin/env python3
"""以隔离应用和临时密钥验证真实 Sparkle 下载、签名拒绝、覆盖与重启。"""
from pathlib import Path
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import functools
import json
import os
import plistlib
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid

project = Path(__file__).resolve().parent.parent
workspace = Path(tempfile.mkdtemp(prefix='niuma-sparkle-qa-')).resolve()
identifier = 'com.niuma.sparkleqa.' + uuid.uuid4().hex
framework = project / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
signer = project / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
receipt = workspace / 'ready.json'
error_file = workspace / 'error.json'
app = workspace / 'Applications/UpdateQA.app'
source = workspace / 'download/UpdateQA.app'
server = None


def run(arguments, **options):
    """固定参数调用真实编译、签名和应用启动工具。"""
    return subprocess.run(list(map(str, arguments)), check=True, **options)


def wait_for(predicate, label, timeout=50):
    """只以真实版本、启动回执和错误事件判断结果。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.1)
    diagnostics = {p.name: p.read_text(encoding='utf-8') for p in [receipt, error_file, workspace / 'buttons.json'] if p.exists()}
    raise RuntimeError(label + ': ' + json.dumps(diagnostics, ensure_ascii=False))


def stop_owned_processes():
    """仅终止本次隔离应用及其 Sparkle 安装器。"""
    for line in subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and str(workspace) in fields[1] and '/Contents/' in fields[1]:
            try:
                os.kill(int(fields[0]), signal.SIGTERM)
            except ProcessLookupError:
                pass


def make_app(path, version):
    """两版使用同一真实框架，身份、数据和更新源只属于本次测试。"""
    (path / 'Contents/MacOS').mkdir(parents=True)
    (path / 'Contents/Frameworks').mkdir()
    shutil.copy2(workspace / 'Fixture', path / 'Contents/MacOS/Fixture')
    run(['ditto', framework, path / 'Contents/Frameworks/Sparkle.framework'])
    info = dict(CFBundleIdentifier=identifier, CFBundleExecutable='Fixture', CFBundleName='UpdateQA',
                CFBundlePackageType='APPL', CFBundleShortVersionString=version,
                CFBundleVersion='4' if version == '0.3.0' else '3', LSUIElement=True,
                LSMultipleInstancesProhibited=False, SUPublicEDKey=public,
                SUFeedURL=base_url + '/appcast.xml', SUEnableAutomaticChecks=False,
                SUEnableSystemProfiling=False, SUVerifyUpdateBeforeExtraction=True,
                NSAppTransportSecurity=dict(NSAllowsLocalNetworking=True))
    (path / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    nested = path / 'Contents/Frameworks/Sparkle.framework/Versions/B'
    for name in ['XPCServices/Installer.xpc', 'XPCServices/Downloader.xpc', 'Autoupdate', 'Updater.app']:
        run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements,flags', nested / name], stderr=subprocess.DEVNULL)
    run(['codesign', '--force', '--sign', '-', path / 'Contents/Frameworks/Sparkle.framework'], stderr=subprocess.DEVNULL)
    run(['codesign', '--force', '--sign', '-', path], stderr=subprocess.DEVNULL)


try:
    (workspace / 'Applications').mkdir()
    (workspace / 'download').mkdir()
    key_source = workspace / 'keys.swift'
    key_source.write_text('''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
''', encoding='utf-8')
    private, public = subprocess.check_output(['swift', str(key_source)], text=True).splitlines()
    key = workspace / 'private.key'
    key.write_text(private, encoding='utf-8')
    key.chmod(0o600)
    del private
    handler = functools.partial(SimpleHTTPRequestHandler, directory=str(workspace))
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_url = 'http://127.0.0.1:' + str(server.server_port)
    swift_source = '''import AppKit
import Sparkle
@MainActor final class Delegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    var updater: SPUStandardUpdaterController?
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        try! JSONSerialization.data(withJSONObject: ["version": version, "pid": ProcessInfo.processInfo.processIdentifier]).write(to: URL(fileURLWithPath: RECEIPT), options: .atomic)
        guard version == "0.2.1" else { return }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                var titles: [String] = []
                @MainActor func visit(_ view: NSView) {
                    if let button = view as? NSButton {
                        titles.append(button.title)
                        if button.isEnabled && ["Install Update", "Install and Relaunch", "安装更新", "安装并重新启动", "安装并重启"].contains(button.title) { button.performClick(nil) }
                    }
                    for child in view.subviews { visit(child) }
                }
                for window in NSApp.windows { if let content = window.contentView { visit(content) } }
                try? JSONSerialization.data(withJSONObject: titles).write(to: URL(fileURLWithPath: BUTTONS))
            }
        }
        DispatchQueue.main.async { self.updater?.checkForUpdates(nil) }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let value = error as NSError
        try? JSONSerialization.data(withJSONObject: ["code": value.code, "domain": value.domain, "message": value.localizedDescription, "details": String(describing: value.userInfo)]).write(to: URL(fileURLWithPath: ERROR))
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
'''.replace('RECEIPT', json.dumps(str(receipt))).replace('ERROR', json.dumps(str(error_file))).replace('BUTTONS', json.dumps(str(workspace / 'buttons.json')))
    (workspace / 'main.swift').write_text(swift_source, encoding='utf-8')
    run(['swiftc', '-swift-version', '6', workspace / 'main.swift', '-F', framework.parent, '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks', '-o', workspace / 'Fixture'])
    make_app(source, '0.3.0')
    archive = workspace / 'update.zip'
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', source, archive])
    signature = subprocess.check_output([str(signer), '--ed-key-file', str(key), '-p', str(archive)], text=True).strip()
    sentinel = workspace / 'settings.json'
    sentinel.write_text('{"salary":21000,"schedule":"09:00-18:00"}', encoding='utf-8')
    original_data = sentinel.read_bytes()
    for corrupt in [True, False]:
        stop_owned_processes()
        if app.exists():
            shutil.rmtree(app)
        receipt.unlink(missing_ok=True)
        error_file.unlink(missing_ok=True)
        make_app(app, '0.2.1')
        signed = ('A' if signature[0] != 'A' else 'B') + signature[1:] if corrupt else signature
        feed = f'''<?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>QA</title><item><title>0.3.0</title><sparkle:version>4</sparkle:version><sparkle:shortVersionString>0.3.0</sparkle:shortVersionString><enclosure url="{base_url}/update.zip" sparkle:edSignature="{signed}" length="{archive.stat().st_size}" type="application/octet-stream"/></item></channel></rss>'''
        (workspace / 'appcast.xml').write_text(feed, encoding='utf-8')
        run(['open', '-n', '-g', app])
        if corrupt:
            wait_for(error_file.exists, '没有观察到损坏签名拒绝事件')
            error = json.loads(error_file.read_text(encoding='utf-8'))
            assert error['domain'] == 'SUSparkleErrorDomain' and error['code'] == 4005 and 'Code=3002' in error['details'], error  # 解压前验证失败及底层签名不符
            assert plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'] == '0.2.1'
            print('PASS: 真实更新下载因 Ed25519 签名不符被拒绝，旧应用保持完整。', flush=True)
        else:
            wait_for(lambda: json.loads(receipt.read_text(encoding='utf-8'))['version'] == '0.3.0', '真实签名更新没有覆盖并重启新版', 90)
            assert plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'] == '0.3.0'
            run(['codesign', '--verify', '--deep', '--strict', app])
            print('PASS: 真实 Sparkle 标准更新窗口完成下载、校验、原位替换与新版重启。', flush=True)
        assert sentinel.read_bytes() == original_data
    print('PASS: 两种签名场景中配置保持原样。', flush=True)
finally:
    stop_owned_processes()
    if server:
        server.shutdown()
        server.server_close()
    register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    for item in [app, source]:
        subprocess.run([register, '-u', str(item)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for directory in [Path.home() / 'Library/Caches' / identifier, Path.home() / 'Library/Preferences' / (identifier + '.plist')]:
        if directory.is_dir():
            shutil.rmtree(directory)
        elif directory.is_file():
            directory.unlink()
    shutil.rmtree(workspace)
