$ErrorActionPreference = "Stop"

# 在 Windows 开发机上构建 NSIS 与 MSI 安装包，并先验证共享收入核心。
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "未找到 Rust/Cargo，请先安装 rustup 与 MSVC 工具链。"
}
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "未找到 npm，请先安装 Node.js 20。"
}

npm ci
npm run test:core
npm run tauri:build

Write-Host "Windows 安装包位于 src-tauri/target/release/bundle/nsis 与 msi。"
