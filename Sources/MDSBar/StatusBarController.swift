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
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel.shared
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
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            model.popoverDidOpen()
        }
    }
}
