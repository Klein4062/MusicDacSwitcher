// StatusBarController.swift — 状态栏图标 + Popover 面板

import AppKit
import SwiftUI
import UserNotifications
import MDSKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var bar: StatusBarController?
    /// 通知前台呈现（应用激活时横幅仍显示）+ 首次授权请求
    private let notifDelegate = NotifDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = notifDelegate
        if AppModel.shared.hearingEnabled {
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        bar = StatusBarController()
    }
}

final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
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

        model.onRunningChange = { [weak self] _ in self?.updateIcon() }
        model.onLoudChange = { [weak self] loud in
            guard let self else { return }
            self.updateIcon()
            guard loud else { return }
            self.notifyLoud()
        }
        model.start()
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MusicDacSwitcher") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            button.image = image.withSymbolConfiguration(cfg)
            // 优先级：听力告警(橙) > 播放中(绿) > 默认
            if model.loud && model.hearingEnabled {
                button.contentTintColor = .systemOrange
            } else if model.isRunning {
                button.contentTintColor = .systemGreen
            } else {
                button.contentTintColor = nil
            }
        }
    }

    /// 估算声压超阈值 → 系统通知。持续超阈值期间 5 分钟内不重复打扰。
    private func notifyLoud() {
        if let last = lastLoudNotify, Date().timeIntervalSince(last) < 300 { return }
        lastLoudNotify = Date()
        let model = self.model
        let content = UNMutableNotificationContent()
        content.title = "MusicDacSwitcher 听力保护"
        content.body = "当前估算声压 \(model.estSPLText ?? "")，已超过 \(Int(model.thresholdDB)) dB 阈值，建议调低音量"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "mds.hearing.loud", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private var lastLoudNotify: Date?

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
        model.popoverDidClose()
    }
}
