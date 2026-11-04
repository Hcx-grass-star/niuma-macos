#!/bin/bash
# 打包可分享给他人使用的分发包（zip，内含 .app 与安装说明）。
#
# 默认路径：ad-hoc 临时签名，接收方需手动放行一次。
#   用法：bash scripts/package-release.sh
#
# 公证路径：配置好 Developer ID 后自动签名 + 公证 + 装订，接收方双击即可打开。
#   用法：
#     export DEVELOPER_ID_APP="Developer ID Application: 你的名字 (TEAMID)"
#     export NOTARY_PROFILE="niuma-notary"   # 先执行一次 notarytool store-credentials 创建
#     bash scripts/package-release.sh
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="牛马上班"
info_plist="$project_root/Resources/Info.plist"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist")"
app_dir="$project_root/build/$app_name.app"
dist_dir="$project_root/dist"
stage_dir="$dist_dir/stage"
zip_path="$dist_dir/$app_name-$version-macOS-arm64.zip"

# 1. 构建并做基础校验（复用现有构建脚本，保证包内哈希与源码一致）。
bash "$project_root/scripts/build-app.sh"

if [ -n "${DEVELOPER_ID_APP:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    mode="notarized"
    echo "== 使用 Developer ID 签名并公证 =="
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APP" --identifier com.hcxgrassstar.niuma "$app_dir"
    codesign --verify --strict --verbose=2 "$app_dir"
    tmp_zip="$dist_dir/notarize-upload.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$tmp_zip"
    xcrun notarytool submit "$tmp_zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app_dir"
    xcrun stapler validate "$app_dir"
    rm -f "$tmp_zip"
else
    mode="adhoc"
    echo "== 使用 ad-hoc 临时签名（接收方需手动放行一次）=="
fi

# 2. 组装分发目录：应用 + 安装说明。
rm -rf "$stage_dir"
install -d "$stage_dir"
/usr/bin/ditto "$app_dir" "$stage_dir/$app_name.app"
cat > "$stage_dir/安装说明.txt" <<EOF
$app_name $version
========================================

运行要求
  · Apple Silicon 机型（M1 / M2 / M3 / M4 / M5）
  · macOS 27.2 或更高版本

安装
  1. 解压后，把「$app_name.app」拖进「应用程序」文件夹。
  2. 首次打开（二选一）：
     a) 打开「系统设置 → 隐私与安全性」，向下滚动到底部，
        在安全提示处点「仍要打开」，再确认一次。
     b) 打开「终端」，执行下面一行，然后正常双击打开：
        xattr -dr com.apple.quarantine "/Applications/$app_name.app"
  3. 启动后会自动弹出设置窗口，填入自己的月薪与上下班时间即可。

$([ "$mode" = "adhoc" ] && printf '%s\n' "为什么要多这一步
  这个版本是个人构建、未经 Apple 公证的独立应用，系统无法验证发布者身份，
  所以 Gatekeeper 默认拦截。上面两步只是解除「来源未知」的隔离标记，
  不改变应用本身的任何行为。")

使用与卸载
  · 菜单栏图标即入口；快捷键 ⌘I 查看收入、⌘, 打开设置、⌘Q 退出。
  · 配置只保存在一个文件：
      ~/Library/Application Support/com.hcxgrassstar.niuma/settings.json
  · 卸载：先在设置里关闭「登录时启动」，退出应用，再删除 .app。
    若想彻底清除，请先点「清除设置并重置」，再删除 .app。
EOF

# 3. 打 zip（保留扩展属性与符号链接，避免解压后签名失效）。
install -d "$dist_dir"
rm -f "$zip_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$stage_dir" "$zip_path"

printf '\n已生成分发包：\n  %s\n  模式：%s\n  大小：%s\n  SHA256：%s\n' \
    "$zip_path" "$mode" "$(du -h "$zip_path" | cut -f1)" \
    "$(shasum -a 256 "$zip_path" | cut -d' ' -f1)"
printf '\n把该 zip 发给对方即可。对方解压后若提示「无法验证开发者」，参考包内「安装说明.txt」。\n'
