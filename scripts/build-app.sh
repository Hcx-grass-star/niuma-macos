#!/bin/bash
# 使用本机 Swift 工具链离线构建通用（arm64 + x86_64）应用包，并进行本地临时签名。
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# 同时产出 Apple Silicon 与 Intel 切片，最低系统版本由 Package.swift 与 Info.plist 决定。
arch_flags=(--arch arm64 --arch x86_64)
# 嵌套沙箱等受限环境下 SwiftPM 自身的 sandbox-exec 可能不可用，可显式关闭。
sandbox_flag=()
[ "${NIUMA_SWIFT_NO_SANDBOX:-0}" = "1" ] && sandbox_flag=(--disable-sandbox)
swift build --package-path "$project_root" -c release --disable-automatic-resolution \
    --product Niuma "${arch_flags[@]}" ${sandbox_flag[@]+"${sandbox_flag[@]}"}
binary_dir="$(swift build --package-path "$project_root" -c release --show-bin-path "${arch_flags[@]}")"
app_dir="$project_root/build/牛马上班.app"
install -d "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
install -m 755 "$binary_dir/Niuma" "$app_dir/Contents/MacOS/Niuma"
install -m 644 "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
# 图标随应用包一同签名，供系统设置与 Finder 读取。
install -m 644 "$project_root/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
source_hash="$(python3 - "$project_root" <<'PY'
from pathlib import Path
from hashlib import sha256
import sys
root = Path(sys.argv[1])
digest = sha256()
# 图标参与构建指纹，区分同一份代码使用不同图标的应用包。
for path in sorted((root / 'Sources').rglob('*.swift')) + [root / 'Package.swift', root / 'Resources/Info.plist', root / 'Resources/AppIcon.icns']:
    digest.update(str(path.relative_to(root)).encode('utf-8'))
    digest.update(path.read_bytes())
print(digest.hexdigest())
PY
)"
/usr/libexec/PlistBuddy -c "Set :NiumaSourceHash $source_hash" "$app_dir/Contents/Info.plist"
codesign --force --sign - --identifier com.hcxgrassstar.niuma "$app_dir"
codesign --verify --strict "$app_dir"
printf '已构建：%s（%s）\n' "$app_dir" "$(lipo -archs "$app_dir/Contents/MacOS/Niuma")"
