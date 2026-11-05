#!/bin/bash
# 使用锁定的本地依赖构建通用应用及安装助手，复制并签名 Sparkle 运行时。
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# 同时产出 Apple Silicon 与 Intel 切片，最低系统版本由 Package.swift 与 Info.plist 决定。
arch_flags=(--arch arm64 --arch x86_64)
# 嵌套沙箱等受限环境下 SwiftPM 自身的 sandbox-exec 可能不可用，可显式关闭。
sandbox_flag=()
[ "${NIUMA_SWIFT_NO_SANDBOX:-0}" = "1" ] && sandbox_flag=(--disable-sandbox)
swift build --package-path "$project_root" -c release --disable-automatic-resolution \
    --product Niuma "${arch_flags[@]}" ${sandbox_flag[@]+"${sandbox_flag[@]}"}
swift build --package-path "$project_root" -c release --disable-automatic-resolution \
    --product NiumaInstaller "${arch_flags[@]}" ${sandbox_flag[@]+"${sandbox_flag[@]}"}
binary_dir="$(swift build --package-path "$project_root" -c release --show-bin-path "${arch_flags[@]}")"
app_dir="$project_root/build/牛马上班.app"
install -d "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers" "$app_dir/Contents/Frameworks"
install -m 755 "$binary_dir/Niuma" "$app_dir/Contents/MacOS/Niuma"
install -m 755 "$binary_dir/NiumaInstaller" "$app_dir/Contents/Helpers/NiumaInstaller"
install -m 644 "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
# SwiftPM 的日历资源必须随 .app 携带，避免独立运行时找不到 Bundle.module。
/usr/bin/ditto "$binary_dir/Niuma_NiumaCore.bundle" "$app_dir/Contents/Resources/Niuma_NiumaCore.bundle"
# 图标随应用包一同签名，供系统设置与 Finder 读取。
install -m 644 "$project_root/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
# 由 SwiftPM 校验过的固定版本框架；ditto 保留框架链接和帮助程序执行权限。
sparkle_framework="$(python3 - "$project_root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
matches = list((root / '.build/artifacts').glob('**/macos-arm64_x86_64/Sparkle.framework'))
if len(matches) != 1:
    raise SystemExit('未找到唯一 Sparkle 框架，请先运行 swift package resolve。')
print(matches[0])
PY
)"
/usr/bin/ditto "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
if [ "${NIUMA_DISTRIBUTION:-0}" = "1" ]; then
    /usr/libexec/PlistBuddy -c "Set :NiumaInstallOnLaunch true" "$app_dir/Contents/Info.plist"
fi
source_hash="$(python3 - "$project_root" <<'PY'
from pathlib import Path
from hashlib import sha256
import os, sys
root = Path(sys.argv[1])
digest = sha256()
# 图标参与构建指纹，区分同一份代码使用不同图标的应用包。
for path in sorted((root / 'Sources').rglob('*.swift')) + sorted((root / 'Sources/NiumaCore/Resources').rglob('*.json')) + [root / 'Package.swift', root / 'Package.resolved', root / 'Resources/Info.plist', root / 'Resources/AppIcon.icns']:
    digest.update(str(path.relative_to(root)).encode('utf-8'))
    digest.update(path.read_bytes())
digest.update(('distribution=' + os.environ.get('NIUMA_DISTRIBUTION', '0')).encode('utf-8'))
print(digest.hexdigest())
PY
)"
/usr/libexec/PlistBuddy -c "Set :NiumaSourceHash $source_hash" "$app_dir/Contents/Info.plist"
signing_identity="${DEVELOPER_ID_APP:--}"
sparkle_dir="$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B"
# 从内到外逐项签名，保留官方帮助程序需要的权限；不使用 --deep 进行签名。
for item in "$sparkle_dir/XPCServices/Installer.xpc" "$sparkle_dir/XPCServices/Downloader.xpc" "$sparkle_dir/Autoupdate" "$sparkle_dir/Updater.app"; do
    codesign --force --sign "$signing_identity" --preserve-metadata=entitlements,flags "$item"
done
codesign --force --sign "$signing_identity" "$app_dir/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$signing_identity" --identifier com.hcxgrassstar.niuma.installer "$app_dir/Contents/Helpers/NiumaInstaller"
codesign --force --sign "$signing_identity" --identifier com.hcxgrassstar.niuma "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '已构建：%s（%s）\n' "$app_dir" "$(lipo -archs "$app_dir/Contents/MacOS/Niuma")"
