#!/bin/bash
# 使用本机 Swift 工具链离线构建 arm64 应用包，并进行本地临时签名。
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$project_root" -c release --disable-automatic-resolution --product Niuma
binary_dir="$(swift build --package-path "$project_root" -c release --show-bin-path)"
app_dir="$project_root/build/牛马上班.app"
install -d "$app_dir/Contents/MacOS"
install -m 755 "$binary_dir/Niuma" "$app_dir/Contents/MacOS/Niuma"
install -m 644 "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
source_hash="$(python3 - "$project_root" <<'PY'
from pathlib import Path
from hashlib import sha256
import sys
root = Path(sys.argv[1])
digest = sha256()
for path in sorted((root / 'Sources').rglob('*.swift')) + [root / 'Package.swift', root / 'Resources/Info.plist']:
    digest.update(str(path.relative_to(root)).encode('utf-8'))
    digest.update(path.read_bytes())
print(digest.hexdigest())
PY
)"
/usr/libexec/PlistBuddy -c "Set :NiumaSourceHash $source_hash" "$app_dir/Contents/Info.plist"
codesign --force --sign - --identifier com.hcxgrassstar.niuma "$app_dir"
codesign --verify --strict "$app_dir"
printf '已构建：%s\n' "$app_dir"
