#!/bin/bash
# 使用锁定依赖及真实 AppKit 视图执行隔离集成检查，不读取或修改用户工资配置。
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
swift build -c release --disable-automatic-resolution --product Niuma
binary_dir="$(swift build -c release --show-bin-path)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/niuma-ui-check.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
app_dir="$probe_dir/MemoryProbe.app/Contents"
mkdir -p "$app_dir/MacOS" "$app_dir/Resources"
/usr/bin/ditto "$binary_dir/Niuma_NiumaCore.bundle" "$app_dir/Resources/Niuma_NiumaCore.bundle"
python3 - "$app_dir/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'CFBundleIdentifier': 'com.hcxgrassstar.niuma.ui-check', 'CFBundleExecutable': 'MemoryProbe', 'CFBundleName': '牛马上班（测试版）', 'CFBundleDisplayName': '牛马上班（测试版）', 'NiumaBuildChannel': 'test', 'CFBundleShortVersionString': '0.3.1', 'LSUIElement': True}, output)
PY
sources=()
for source in Sources/Niuma/*.swift; do
    [ "$source" = "Sources/Niuma/main.swift" ] || sources+=("$source")
done
swiftc -swift-version 6 -O -parse-as-library "${sources[@]}" Tests/NiumaUITests/IncomePanelIntegrationTests.swift \
    -I "$binary_dir" "$binary_dir/NiumaCore.o" "$binary_dir/NiumaInstallation.o" \
    -F "$binary_dir" -framework Sparkle -Xlinker -rpath -Xlinker "$binary_dir" \
    -o "$app_dir/MacOS/MemoryProbe"
"$app_dir/MacOS/MemoryProbe" "$@"
