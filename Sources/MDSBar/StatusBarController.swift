// StatusBarController.swift — 状态栏图标 + Popover 面板

import AppKit
import SwiftUI
import MDSKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var bar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        bar = StatusBarController()
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel.shared
    /// 点击其他应用/桌面时关闭面板。LSUIElement 应用在未激活状态下
    /// NSPopover 的 .transient 不会自动关闭，需要全局事件监听兜底。
    private var eventMonitor: Any?

    override init() {
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform",
                                    accessibilityDescription: "MusicDacSwitcher")
            button.toolTip = "MusicDacSwitcher"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 396, height: 660)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView().environmentObject(model))

        model.onRunningChange = { [weak self] running in
            self?.updateIcon(running: running)
        }
        model.start()
        updateIcon(running: model.isRunning)
    }

    private func updateIcon(running: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = running ? "waveform" : "waveform"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MusicDacSwitcher") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            button.image = image.withSymbolConfiguration(cfg)
            button.contentTintColor = running ? .systemGreen : nil
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // 激活后 .transient 才能在点击其他应用时正常关闭
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            installOutsideClickMonitor()
            model.popoverDidOpen()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.closePopover()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }
}
