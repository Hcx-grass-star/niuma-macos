#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

/// 桌面程序入口；业务逻辑位于共享前端模块，平台逻辑位于 lib.rs。
fn main() {
    niuma_lib::run();
}
