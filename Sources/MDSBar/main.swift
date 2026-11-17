// MDSBar — MusicDacSwitcher 菜单栏图形界面
// 纯菜单栏应用（LSUIElement）：无 Dock 图标，常驻状态栏。

import AppKit
import Darwin

// ── 单实例保护 ──────────────────────────────────────────────
// 文件锁保证任意来源（/Applications、build 目录、裸二进制、LaunchAgent）
// 同时只有一个实例；重复启动时激活现有实例后退出。

func acquireSingleInstanceLock() -> Bool {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/com.musicdacswitcher")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lockURL = dir.appendingPathComponent("single-instance.lock")
    let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true } // 锁文件异常时放行，不阻断启动
    return flock(fd, LOCK_EX | LOCK_NB) == 0
}

if !acquireSingleInstanceLock() {
    let others = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.musicdacswitcher.app")
    if let running = others.first {
        running.activate()
    }
    FileHandle.standardError.write(
        Data("MusicDacSwitcher 已在运行，已激活现有实例。\n".utf8))
    exit(0)
}

// ── 启动 ────────────────────────────────────────────────────
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
