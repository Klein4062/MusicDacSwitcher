// AppModel.swift — GUI 状态管理：设备状态刷新、格式矩阵、自动切换控制、日志收集

import Combine
import CoreAudio
import Foundation
import MDSKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: - 界面状态

    @Published var deviceName = "未找到输出设备"
    @Published var deviceChoices: [(uid: String, name: String)] = []
    /// nil = 跟随系统默认输出设备；选择会持久化（重启保留）
    @Published var selectedUID: String? {
        didSet {
            guard selectedUID != oldValue else { return }
            if let uid = selectedUID {
                UserDefaults.standard.set(uid, forKey: "mds.selectedDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "mds.selectedDeviceUID")
            }
        }
    }
    @Published var currentBits = 0
    @Published var currentIsFloat = false
    @Published var currentChannels = 0
    @Published var currentRateLabel = "—"
    @Published var isRunning = false
    @Published var isHogged = false
    @Published var autoSwitch = true {
        didSet { controller.enabled = autoSwitch }
    }
    /// 源探测：扫描正在播放的本地音频文件自动匹配格式
    @Published var probeEnabled = true {
        didSet { watcher?.probeEnabled = probeEnabled }
    }
    @Published var bitDepthMode: BitDepthMode = .highest {
        didSet { controller.policy = bitDepthMode.policy }
    }
    @Published var rateRows: [RateRow] = []
    /// 当前悬停的格式行（采样率）；hover 状态集中管理以规避 SwiftUI @State 宏依赖
    @Published var hoveredRate: Float64?
    @Published var logs: [String] = []
    @Published var launchAtLogin = LaunchAgent.isInstalled {
        didSet { guard launchAtLogin != LaunchAgent.isInstalled else { return }
            do {
                if launchAtLogin { try LaunchAgent.install() } else { try LaunchAgent.uninstall() }
            } catch {
                log("开机自启设置失败: \(error.localizedDescription)")
                launchAtLogin.toggle() // 回滚
            }
        }
    }

    var onRunningChange: ((Bool) -> Void)?

    // MARK: - 位深策略

    enum BitDepthMode: String, CaseIterable, Identifiable {
        case highest = "最高"
        case b16 = "16"
        case b24 = "24"
        case b32 = "32"

        var id: String { rawValue }

        var policy: BitDepthPolicy {
            switch self {
            case .highest: return .highest
            case .b16: return .fixed(16)
            case .b24: return .fixed(24)
            case .b32: return .fixed(32)
            }
        }

        static func from(policy: BitDepthPolicy) -> BitDepthMode {
            switch policy {
            case .fixed(16): return .b16
            case .fixed(24): return .b24
            case .fixed(32): return .b32
            default: return .highest
            }
        }
    }

    // MARK: - 格式矩阵行

    struct RateRow: Identifiable {
        var id: Float64 { rate }
        var rate: Float64
        var label: String
        var intBits: [Int]
        var floatBits: [Int]
        var isCurrent: Bool
        var currentBits: Int?
    }

    // MARK: - 私有

    let controller = FormatController(policy: .highest, verbose: true)
    private var watcher: DeviceWatcher?
    private var timer: Timer?

    // MARK: - 生命周期

    init() {
        // init 内赋值不触发 didSet，不会写回持久化
        selectedUID = UserDefaults.standard.string(forKey: "mds.selectedDeviceUID")
        LogSink.handler = { [weak self] line in
            DispatchQueue.main.async {
                guard let self else { return }
                self.logs.append(line)
                if self.logs.count > 300 { self.logs.removeFirst(self.logs.count - 300) }
            }
        }
    }

    func start() {
        rebuildWatcher()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(includeDevices: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func popoverDidOpen() {
        refresh()
    }

    // MARK: - 设备

    func selectDevice(_ uid: String?) {
        selectedUID = uid
        rebuildWatcher()
        refresh()
    }

    private func rebuildWatcher() {
        watcher?.stop()
        let w = DeviceWatcher(deviceQuery: selectedUID, controller: controller)
        w.onEvent = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(includeDevices: false) }
        }
        watcher = w
        w.start()
    }

    private var currentDeviceID: AudioObjectID? {
        AudioDevice.findDevice(matching: selectedUID) ?? AudioDevice.defaultOutputDeviceID()
    }

    /// 监听模式徽章：面板头部显示软件当前在盯哪台设备
    var listenModeBadge: String? {
        guard selectedUID != nil else { return "跟随默认" }
        return "固定监听"
    }

    // MARK: - 刷新

    func refresh(includeDevices: Bool = true) {
        guard let id = currentDeviceID else {
            deviceName = "未找到输出设备"
            return
        }
        let snap = AudioDevice.snapshot(deviceID: id)
        if deviceName != snap.name || isRunning != snap.runningSomewhere {
            isRunning = snap.runningSomewhere
            onRunningChange?(isRunning)
        } else {
            isRunning = snap.runningSomewhere
        }
        deviceName = snap.name
        isHogged = (snap.hogPID ?? -1) != -1
        if let cur = snap.streams.first?.physical {
            currentBits = Int(cur.mBitsPerChannel)
            currentIsFloat = cur.mFormatFlags & kAudioFormatFlagIsFloat != 0
            currentChannels = Int(cur.mChannelsPerFrame)
            currentRateLabel = hz(cur.mSampleRate)
        }
        if let stream = snap.streams.first {
            rateRows = Self.group(stream.available, current: stream.physical)
        }
        if includeDevices {
            deviceChoices = AudioDevice.outputDeviceSnapshots().map { ($0.uid, $0.name) }
        }
    }

    /// 能力列表 → 按采样率分组的矩阵行（降序）
    static func group(_ entries: [PhysicalFormatEntry],
                      current: AudioStreamBasicDescription?) -> [RateRow] {
        struct Key: Hashable { let min: Float64; let max: Float64 }
        var groups: [Key: (ints: Set<Int>, floats: Set<Int>)] = [:]
        var order: [Key] = []
        for e in entries {
            let k = Key(min: e.rateMin, max: e.rateMax)
            if groups[k] == nil { order.append(k) }
            if e.isFloat { groups[k, default: ([], [])].floats.insert(e.bits) }
            else { groups[k, default: ([], [])].ints.insert(e.bits) }
        }
        let curRate = current?.mSampleRate
        return order.compactMap { k -> RateRow? in
            guard let g = groups[k] else { return nil }
            let label = k.min == k.max ? hz(k.min) : "\(Int(k.min / 1000))–\(Int(k.max / 1000))k"
            let isCurrent = curRate.map { k.min <= $0 && $0 <= k.max } ?? false
            let curBits: Int? = (isCurrent && current != nil) ? Int(current!.mBitsPerChannel) : nil
            return RateRow(rate: k.min, label: label,
                           intBits: g.ints.sorted(), floatBits: g.floats.sorted(),
                           isCurrent: isCurrent, currentBits: curBits)
        }
        .sorted { $0.rate > $1.rate }
    }

    func setHovered(_ rate: Float64?) {
        hoveredRate = rate
    }

    // MARK: - 手动操作

    /// 手动切换到指定采样率的最佳格式
    func apply(rate: Float64) {
        guard let id = currentDeviceID, let sid = AudioDevice.outputStreams(id).first else { return }
        let rateLabel = hz(rate)
        watcher?.suppressProbe(seconds: 60) // 手动优先，60 秒内不被探测覆盖
        Task.detached { [controller] in
            _ = controller.applyBestFormat(deviceID: id, streamID: sid,
                                           desiredRate: rate, context: "手动切换 \(rateLabel)")
            await MainActor.run { self.refresh(includeDevices: false) }
        }
    }

    /// 立即按当前标称采样率优化位深
    func optimizeNow() {
        guard let id = currentDeviceID else { return }
        Task.detached { [controller] in
            controller.evaluateAndApply(deviceID: id, context: "手动优化")
            await MainActor.run { self.refresh(includeDevices: false) }
        }
    }
}

// MARK: - 开机自启（LaunchAgent）

enum LaunchAgent {
    static let label = "com.musicdacswitcher.gui"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func executablePath() -> String {
        if Bundle.main.bundleURL.pathExtension == "app",
           let exe = Bundle.main.executableURL {
            return exe.path
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
    }

    static func install() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath()],
            "RunAtLoad": true,
        ]
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try? unload()
        try data.write(to: plistURL)
        try launchctl("load", plistURL.path)
    }

    static func uninstall() throws {
        try? unload()
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func unload() throws {
        try launchctl("unload", plistURL.path)
    }

    private static func launchctl(_ subcommand: String, _ path: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = [subcommand, path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "LaunchAgent", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl \(subcommand) 失败"])
        }
    }
}
