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
    /// 稳定模式：检测到「切换格式后设备掉线」时自动进入，停止写设备
    @Published var passiveMode = false
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
    /// 估算声压超过阈值的边沿回调（触发系统通知与图标变色）
    var onLoudChange: ((Bool) -> Void)?

    // MARK: - 听力保护

    /// 听力保护开关（估算声压超阈值时提醒）
    @Published var hearingEnabled: Bool =
        (UserDefaults.standard.object(forKey: "mds.hearing.enabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(hearingEnabled, forKey: "mds.hearing.enabled") }
    }
    /// 耳机灵敏度（dB/mW）
    @Published var sensDB: Double = AppModel.dblDefault("mds.hearing.sens", 108) {
        didSet {
            UserDefaults.standard.set(sensDB, forKey: "mds.hearing.sens")
            syncProfileParams()
        }
    }
    /// 耳机阻抗（Ω）
    @Published var impOhm: Double = AppModel.dblDefault("mds.hearing.imp", 32) {
        didSet {
            UserDefaults.standard.set(impOhm, forKey: "mds.hearing.imp")
            syncProfileParams()
        }
    }
    /// 输出口满幅电压（Vrms）
    @Published var maxVrms: Double = AppModel.dblDefault("mds.hearing.vrms", 2.0) {
        didSet {
            UserDefaults.standard.set(maxVrms, forKey: "mds.hearing.vrms")
            syncProfileParams()
        }
    }
    /// 告警阈值（dB SPL，平均口径）
    @Published var thresholdDB: Double = AppModel.dblDefault("mds.hearing.threshold", 85) {
        didSet { UserDefaults.standard.set(thresholdDB, forKey: "mds.hearing.threshold") }
    }
    /// 音乐峰值因子（dB）：峰值与平均 RMS 之差，流行 ~12 / 古典 ~18 / 纯音 0
    @Published var crestDB: Double = AppModel.dblDefault("mds.hearing.crest", 12) {
        didSet { UserDefaults.standard.set(crestDB, forKey: "mds.hearing.crest") }
    }
    /// 机身音量旋钮衰减（dB，负值）：DAC 旋钮不联动系统音量（读数恒 0dB）时的
    /// 手动补偿；0 = 机身全开，系统读数即全部衰减。屏显无 dB 时按听感粗校准
    @Published var attenDB: Double = AppModel.dblDefault("mds.hearing.atten", 0) {
        didSet {
            UserDefaults.standard.set(attenDB, forKey: "mds.hearing.atten")
            syncProfileParams()
        }
    }

    // MARK: - 耳机档案（按输出设备切换参数组合）

    /// 档案列表（持久化 JSON；首次预置常用组合）
    @Published var profiles: [HearingProfile] = AppModel.loadProfiles() {
        didSet { persistProfiles() }
    }
    /// 输出设备切换时按设备名自动套用匹配档案
    @Published var autoProfile: Bool =
        (UserDefaults.standard.object(forKey: "mds.hearing.autoprofile") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoProfile, forKey: "mds.hearing.autoprofile") }
    }
    /// 当前生效档案（nil = 手动参数）
    @Published var activeProfileID: UUID? =
        UserDefaults.standard.string(forKey: "mds.hearing.profile").flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(activeProfileID?.uuidString, forKey: "mds.hearing.profile") }
    }
    /// selectProfile 批量赋值参数时抑制字段 didSet 回写档案
    private var applyingProfile = false

    /// 当前档案（无选中为 nil，用于界面显示）
    var activeProfile: HearingProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    private static func loadProfiles() -> [HearingProfile] {
        if let data = UserDefaults.standard.data(forKey: "mds.hearing.profiles"),
           let ps = try? JSONDecoder().decode([HearingProfile].self, from: data),
           !ps.isEmpty {
            // 迁移：早期预置按「满幅 ≈110 dB + 数字音量衰减」建模 HDB 630，
            // 实测证伪——耳机自身还有一道 mac 不可见的音量，估算会把整晚
            // 虚记成满幅声压（一度周剂量虚标 300%）。强制改为不估算
            // （maxVrms=0 → estimatedSPL 返回 nil，不显示不累计剂量）。
            // 仅修正旧预置的两套 HDB 档案；用户手动建的其他档案不动
            var migrated = ps
            let hdbKeys: Set<String> = ["hdb 630", "hdb630", "btd 700", "btd700"]
            func isHDB(_ p: HearingProfile) -> Bool {
                Set(p.matchKeywords.map { $0.lowercased() }).intersection(hdbKeys).isEmpty == false
            }
            if migrated.contains(where: { isHDB($0) && $0.maxVrms > 0 }) {
                for i in migrated.indices where isHDB(migrated[i]) && migrated[i].maxVrms > 0 {
                    migrated[i].maxVrms = 0
                }
                // 编码失败时宁可不动存量：set(nil) 会把 key 整个删掉
                if let data = try? JSONEncoder().encode(migrated) {
                    UserDefaults.standard.set(data, forKey: "mds.hearing.profiles")
                }
            }
            return migrated
        }
        // 预置三套常用组合。HDB 630 为纯数字主动耳机（无模拟输入），
        // 且自带一道 mac 不可见的音量——电压/灵敏度模型无从校准，
        // 置为不估算（maxVrms=0）：不显示声压、不累计剂量，宁缺毋错
        return [
            HearingProfile(name: "TP55 · 彼岸银翼", matchKeywords: ["tp55"],
                           sensDB: 105, impOhm: 40, maxVrms: 2.1, attenDB: 0),
            HearingProfile(name: "HDB 630 有线 USB-C", matchKeywords: ["hdb 630", "hdb630"],
                           sensDB: 80, impOhm: 1, maxVrms: 0, attenDB: 0),
            HearingProfile(name: "HDB 630 · BTD 700", matchKeywords: ["btd 700", "btd700"],
                           sensDB: 80, impOhm: 1, maxVrms: 0, attenDB: 0),
        ]
    }

    private func persistProfiles() {
        // 编码失败时不动存量（set(nil) 等于删 key，会把档案全部丢掉）
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "mds.hearing.profiles")
        }
    }

    /// 选用档案：载入参数（阈值/峰值因子为全局策略，不随档案）
    func selectProfile(_ id: UUID?) {
        activeProfileID = id
        guard let p = profiles.first(where: { $0.id == id }) else { return }
        applyingProfile = true
        defer { applyingProfile = false }
        sensDB = p.sensDB
        impOhm = p.impOhm
        maxVrms = p.maxVrms
        attenDB = p.attenDB
    }

    /// 参数字段被手动编辑时回写当前档案（下次切回即生效）
    private func syncProfileParams() {
        guard !applyingProfile, let id = activeProfileID,
              let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles[i].sensDB != sensDB || profiles[i].impOhm != impOhm
                || profiles[i].maxVrms != maxVrms || profiles[i].attenDB != attenDB else { return }
        profiles[i].sensDB = sensDB
        profiles[i].impOhm = impOhm
        profiles[i].maxVrms = maxVrms
        profiles[i].attenDB = attenDB
    }

    /// 输出设备变化时自动跟随档案（仅设备名变化那一刻触发，
    /// 避免覆盖用户手动选择）
    private func autoFollowProfile(deviceName: String) {
        guard autoProfile,
              let hit = HearingProfile.match(profiles, deviceName: deviceName),
              hit.id != activeProfileID else { return }
        log("🎧 输出设备「\(deviceName)」→ 自动套用档案「\(hit.name)」")
        selectProfile(hit.id)
    }
    /// 当前有效衰减（dB，mac 读数 + 机身衰减，如 "-41.5 dB"；静音显示"静音"；无属性为 nil）
    @Published var volumeDBText: String?
    /// 峰值口径估算声压（满幅正弦等效，如 "≤ 93 dB SPL"；无法估算为 nil）
    @Published var peakSPLText: String?
    /// 平均口径估算声压（≈ LAeq，告警依据，如 "≈ 81 dB SPL"；无法估算为 nil）
    @Published var avgSPLText: String?
    /// 当前曲目实测平均电平（如 "曲电平 −15.2 dBFS"；不可测/未播放为 nil）
    @Published var trackLevelText: String?
    /// 估算声压当前是否超过阈值（平均口径）
    @Published var loud = false
    /// 当前曲目实测平均电平（dBFS，负值，TrackLevelAnalyzer 后台产出）
    private var trackRMS: Double?
    /// 已分析（或分析中）的曲目路径，同曲不重复分析
    private var trackAnalyzedPath: String?
    /// 当前曲目完整分析结果（分段表在此）
    private var trackLevelResult: TrackLevelAnalyzer.Result?
    /// 此刻播放位置的段落电平（dBFS）：随 offset 每 4s 刷新
    private var instantRMSDB: Double?
    /// 此刻声压（如 "此刻 ≈76 dB"；停止播放显示 "0 dB"）
    @Published var liveSPLText = "0 dB"
    /// 暴露历史（周剂量数据源）
    private let hearingLog = HearingLog()
    /// 滚动 7 天听力剂量（如 "近 7 天 12% · 等效 4.9h/40h @80dB"；无记录为 nil）
    @Published var weeklyDoseText: String?
    /// 剩余额度（如 "剩余 88% · 当前 ≈72 dB 下约可再听 999+ 小时"；无记录为 nil）
    @Published var doseRemainText: String?
    /// 实时消耗速率（如 "实时 0.20 %/h · ≈69 dB"；无有效声压为 nil）。
    /// 随音量与曲目电平每 2s 刷新，无需剂量历史
    @Published var burnRateText: String?
    private var lastDose: HearingLog.Dose?
    private var lastAvgSPL: Double?

    var hearingParams: HearingGuard.Params {
        HearingGuard.Params(sensitivity: sensDB, impedance: impOhm,
                            maxVrms: maxVrms, threshold: thresholdDB,
                            crestDB: crestDB, deviceAttenuationDB: attenDB)
    }

    private static func dblDefault(_ key: String, _ def: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil
            ? def : UserDefaults.standard.double(forKey: key)
    }

    /// 面板数值输入格式（无千分位，最多 1 位小数）
    static let numFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()

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

    struct RateRow: Identifiable, Equatable {
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
    private var pendingLogs: [String] = []
    private var logFlush: DispatchWorkItem?
    private var refreshing = false
    private var refreshAgain = false
    private var uiRefreshDebounce: DispatchWorkItem?

    // MARK: - 生命周期

    init() {
        // init 内赋值不触发 didSet，不会写回持久化
        selectedUID = UserDefaults.standard.string(forKey: "mds.selectedDeviceUID")
        LogSink.handler = { [weak self] line in
            // 批量合并（0.5s）：事件风暴时不逐条打爆主线程
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingLogs.append(line)
                guard self.logFlush == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let batch = self.pendingLogs
                    self.pendingLogs.removeAll()
                    self.logFlush = nil
                    self.logs.append(contentsOf: batch)
                    if self.logs.count > 300 { self.logs.removeFirst(self.logs.count - 300) }
                    self.appendFileLog(batch)
                }
                self.logFlush = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
    }

    func start() {
        rebuildWatcher()
        // 周剂量：启动加载历史，之后每次桶落盘（5 分钟粒度）重算
        hearingLog.onFlush = { [weak self] in self?.reloadWeeklyDose() }
        reloadWeeklyDose()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(includeDevices: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    /// 后台重算滚动 7 天听力剂量并更新展示
    private func reloadWeeklyDose() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let dose = HearingLog.weeklyDose()
            let histAvg = HearingLog.windowAverageSPL() // 近 7 天播放均值（与剂量同窗）
            DispatchQueue.main.async {
                self?.historyAvgSPL = histAvg
                self?.updateDoseText(dose)
            }
        }
    }

    /// 近 7 天所有播放的时长加权均值声压（历史音量/时间口径）；
    /// nil（无播放历史）时面板均值回退瞬时估算
    @Published var historyAvgSPL: Double?

    private func updateDoseText(_ dose: HearingLog.Dose?) {
        lastDose = dose
        let text = dose.map {
            let eq = $0.equivalentHours < 1
                ? String(format: "%.0f 分钟", $0.equivalentHours * 60)
                : String(format: "%.1fh", $0.equivalentHours)
            return String(format: "近 7 天 %.1f%% · 等效 %@ / %.0fh @80dB · 实际聆听 %.1fh",
                          min($0.percent, 999), eq, HearingLog.referenceHours,
                          $0.activeHours)
        }
        if weeklyDoseText != text { weeklyDoseText = text }
        updateDoseRemainText()
    }

    /// 剩余额度：按当前声压反解还能听多久（每 2s 随读数刷新）。
    /// 低音量下时长按 3dB 一倍放大，超过 999h 显示 999+。
    private func updateDoseRemainText() {
        guard let dose = lastDose else {
            if doseRemainText != nil { doseRemainText = nil }
            return
        }
        let remainPct = max(0, 100 - dose.percent)
        guard let h = HearingLog.remainingHours(dose: dose, avgSPL: lastAvgSPL) else { return }
        let hText = h >= 999 ? "999+ 小时" : String(format: "%.0f 小时", h)
        let text: String
        if let avg = lastAvgSPL {
            text = String(format: "剩余 %.1f%% · 当前 ≈%.0f dB 下约可再听 %@",
                          remainPct, avg, hText)
        } else {
            text = String(format: "剩余 %.1f%%（80 dB 下 %@）", remainPct, hText)
        }
        if doseRemainText != text { doseRemainText = text }
    }

    /// 面板是否可见：呼吸灯等常驻动画只在可见时运行
    /// （SwiftUI repeatForever 动画挂在 display link 上，面板隐藏后
    ///  仍按刷新率求值，实测常驻 ~10% CPU）
    @Published var popoverVisible = false

    func popoverDidOpen() {
        popoverVisible = true
        refresh()
    }

    func popoverDidClose() {
        popoverVisible = false
    }

    // MARK: - 设备

    func selectDevice(_ uid: String?) {
        selectedUID = uid
        rebuildWatcher()
        refresh()
    }

    private func rebuildWatcher() {
        watcher?.stop()
        passiveMode = false // 新 watcher 从正常模式开始
        let w = DeviceWatcher(deviceQuery: selectedUID, controller: controller)
        w.onEvent = { [weak self] _ in self?.scheduleUIRefresh() }
        w.onPassiveChange = { [weak self] on in
            DispatchQueue.main.async { self?.passiveMode = on }
        }
        w.onPlayingProbe = { [weak self] probe in
            DispatchQueue.main.async { self?.handlePlayingProbe(probe) }
        }
        watcher = w
        w.start()
    }

    /// 源探测到正在播放的文件（主线程）：后台解码实测曲目电平（含 10s 分段表），
    /// 供听力保护的平均口径折算与「此刻声压」按播放位置取段。
    /// 切歌重分析（组 key+mtime 缓存）；同曲每 4s 跟随 offset 刷新此刻段。
    /// Sony 等播放器把曲库切成 ~10s 编号分片（<曲目ID>/001.flac…）：
    /// 分析按分片组聚合成整曲电平与分段表，播放位置换算全局偏移取段
    /// （否则"平均"退化为 10 秒片电平、「此刻」恒等于「平均」）；
    /// 同曲判定用归一化组标识——分片前进不触发重分析。
    /// 探测靠 1.3s 双快照的读取偏移前进识别播放——播放器预读缓冲饱和时
    /// 偏移短暂不动，会间歇误报"无播放"；短暂 nil（≤12s ≈ 3 个探测周期）
    /// 保留曲目状态不清空，避免「此刻声压/曲电平」在可测与归零间摇摆。
    private var probeNilSince: Date?

    /// 最近一次探测到「正在播放的文件」的时刻。设备 runningSomewhere 只说明
    /// 有进程占着音频 IO（浏览器残留会话也会亮），不等于在听——剂量累计
    /// 需二者联判（isRunning 且距最近播放探测 ≤12s，宽限同曲目状态口径，
    /// 防预读饱和的间歇误报漏记；网页流媒体无文件可探，宁漏记不错记）
    private var probeLastActiveAt: Date?

    private func handlePlayingProbe(_ probe: SourceProbe.Probe?) {
        guard let probe else {
            if probeNilSince == nil {
                probeNilSince = Date()
            } else if Date().timeIntervalSince(probeNilSince!) > 12 {
                probeNilSince = nil
                trackAnalyzedPath = nil
                trackLevelResult = nil
                instantRMSDB = nil
                if trackRMS != nil { trackRMS = nil }
                if trackLevelText != nil { trackLevelText = nil }
            }
            return
        }
        probeNilSince = nil
        probeLastActiveAt = Date()
        let key = TrackLevelAnalyzer.canonicalPath(probe.path)
        let globalOffset = TrackLevelAnalyzer.globalOffsetBytes(path: probe.path,
                                                                offsetBytes: probe.offset)
        if key == trackAnalyzedPath {
            // 同曲：只随全局 offset 前进更新「此刻」段
            if let cached = trackLevelResult {
                instantRMSDB = TrackLevelAnalyzer.segmentRMS(cached, offsetBytes: globalOffset)
            }
            return
        }
        trackAnalyzedPath = key
        let path = probe.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let level = TrackLevelAnalyzer.analyze(path: path) // 分片组内自动聚合
            DispatchQueue.main.async {
                guard let self, self.trackAnalyzedPath == key else { return } // 已切歌，丢弃
                self.trackLevelResult = level
                self.trackRMS = level?.rmsDB
                self.instantRMSDB = level.flatMap {
                    TrackLevelAnalyzer.segmentRMS($0, offsetBytes: globalOffset)
                }
                let text = level.map { String(format: "曲电平 %.1f dBFS", $0.rmsDB) }
                if self.trackLevelText != text { self.trackLevelText = text }
                self.refresh(includeDevices: false) // 立即用新电平刷新估算
            }
        }
    }

    /// 解除稳定模式（用户确认设备已稳定后）
    func resetPassiveMode() {
        watcher?.resetPassive()
    }

    /// 日志落盘（~/Library/Logs/MusicDacSwitcher.log）：用于排查设备掉线等现场问题
    private func appendFileLog(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        let url = dir.appendingPathComponent("MusicDacSwitcher.log")
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
           size.intValue > 2_000_000 {
            try? "".write(to: url, atomically: true, encoding: .utf8) // 超过 2MB 从头记录
        }
        let text = lines.joined(separator: "\n") + "\n"
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(Data(text.utf8))
            try? fh.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    /// watcher 事件触发的 UI 刷新：0.4s 合并。
    /// 设备反复插拔时事件可达每秒数十条，逐条直刷主线程会把 UI 打死。
    func scheduleUIRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.uiRefreshDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refresh(includeDevices: false) }
            self.uiRefreshDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
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

    /// CoreAudio 查询全部在后台线程执行（设备抖动时 IPC 往返可能很慢，
    /// 放主线程会冻结 UI）；主线程只写 @Published。防重入，堆积的请求合并续刷。
    func refresh(includeDevices: Bool = true) {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let query = selectedUID
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let id = AudioDevice.findDevice(matching: query) ?? AudioDevice.defaultOutputDeviceID()
            guard let id else {
                DispatchQueue.main.async { self?.refreshDone(snap: nil, rows: nil, choices: nil, vol: nil) }
                return
            }
            let snap = AudioDevice.snapshot(deviceID: id)
            let rows = snap.streams.first.map { AppModel.group($0.available, current: $0.physical) }
            let vol = AudioDevice.volumeInfo(deviceID: id)
            let choices = includeDevices
                ? AudioDevice.outputDeviceSnapshots().map { ($0.uid, $0.name) }
                : nil
            DispatchQueue.main.async { self?.refreshDone(snap: snap, rows: rows, choices: choices, vol: vol) }
        }
    }

    @MainActor private func refreshDone(snap: DeviceSnapshot?,
                                        rows: [RateRow]?,
                                        choices: [(uid: String, name: String)]?,
                                        vol: AudioDevice.VolumeInfo?) {
        defer {
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                refresh(includeDevices: choices != nil)
            }
        }
        guard let snap else {
            if deviceName != "未找到输出设备" { deviceName = "未找到输出设备" }
            updateHearing(vol: nil)
            return
        }
        // 值变化才赋值：@Published 每次赋值都会触发 objectWillChange
        // 并引发整棵 SwiftUI 树 diff，高频刷新时必须避免无效赋值
        if isRunning != snap.runningSomewhere {
            isRunning = snap.runningSomewhere
            onRunningChange?(isRunning)
        }
        if deviceName != snap.name {
            deviceName = snap.name
            autoFollowProfile(deviceName: snap.name)
        }
        let hogged = (snap.hogPID ?? -1) != -1
        if isHogged != hogged { isHogged = hogged }
        if let cur = snap.streams.first?.physical {
            let bits = Int(cur.mBitsPerChannel)
            let isFloat = cur.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let chs = Int(cur.mChannelsPerFrame)
            let label = hz(cur.mSampleRate)
            if currentBits != bits { currentBits = bits }
            if currentIsFloat != isFloat { currentIsFloat = isFloat }
            if currentChannels != chs { currentChannels = chs }
            if currentRateLabel != label { currentRateLabel = label }
        }
        if let rows, rows != rateRows { rateRows = rows }
        if let choices, choices.map(\.uid) != deviceChoices.map(\.uid) { deviceChoices = choices }
        updateHearing(vol: vol)
    }

    /// 更新音量读数与听力保护状态（在主线程，2s 轮询驱动）。
    /// 超阈值的「边沿」触发 onLoudChange（系统通知 + 图标变色）；
    /// 持续超阈值不重复打扰，回落再越过才重新提醒。
    private func updateHearing(vol: AudioDevice.VolumeInfo?) {
        guard let vol, let db = vol.decibels else {
            if volumeDBText != nil { volumeDBText = nil }
            if peakSPLText != nil { peakSPLText = nil }
            if avgSPLText != nil { avgSPLText = nil }
            if loud { loud = false; onLoudChange?(false) }
            return
        }
        // 读数显示有效衰减（mac 读数 + 机身衰减）：mac 拉满、机身旋钮控音量时
        // 系统读数恒 0dB，读数即机身衰减的估计值
        let newText = vol.muted ? "静音" : String(format: "%.1f dB", db + attenDB)
        if volumeDBText != newText { volumeDBText = newText }

        let params = hearingParams
        let peak = vol.muted ? nil : HearingGuard.estimatedSPL(volumeDB: db, params: params)
        let peakText = peak.map { String(format: "≤ %.0f dB SPL", $0) }
        if peakSPLText != peakText { peakSPLText = peakText }
        let avg = HearingGuard.averageSPL(peakSPL: peak, params: params, trackRMSDB: trackRMS)
        // 均值显示：近 7 天播放的时长加权均值（历史音量/时间口径，
        // 随剂量节奏刷新）；无播放历史回退当前音量的瞬时估算
        let avgText: String?
        if let h = historyAvgSPL {
            avgText = String(format: "≈ %.0f dB · 7天均值", h)
        } else {
            avgText = avg.map { String(format: "≈ %.0f dB SPL", $0) }
        }
        if avgSPLText != avgText { avgSPLText = avgText }
        // 此刻声压：播放中随当前乐段电平起伏；停止归 0；播放中但曲目解不了
        // （网易云 .uc! 等加密缓存、流媒体）显示"不可测"而非误导性的 0。
        // 行首恒以「此刻」锚定，便于辨认。停止以 CoreAudio 播放状态为准
        // （即时），不受探测宽限期的残留分段影响
        let live = isRunning
            ? HearingGuard.instantSPL(peakSPL: peak, instantRMSDB: instantRMSDB) : nil
        let liveText: String
        if vol.muted {
            liveText = "此刻 0 dB（静音）"
        } else if let live {
            liveText = String(format: "此刻 ≈%.0f dB", live)
        } else if peak == nil {
            // 音量读得到但估不出声压：档案不估算（如 HDB 630，耳机自控
            // 音量 mac 不可见）——区别于曲目不可测，避免误导
            liveText = "此刻 —（档案不估算）"
        } else if isRunning {
            liveText = "此刻 —（曲目不可测）"
        } else {
            liveText = "此刻 0 dB"
        }
        if liveSPLText != liveText { liveSPLText = liveText }
        let isLoud = hearingEnabled && HearingGuard.exceedsThreshold(spl: peak, params: params,
                                                                     trackRMSDB: trackRMS)
        if isLoud != loud {
            loud = isLoud
            if isLoud {
                let instAvg = avg.map { String(format: "≈ %.0f", $0) } ?? "?"
                log("⚠️ 当前估算声压 \(instAvg) dB（峰值 \(peakText ?? "")）已超过 \(Int(thresholdDB)) dB 阈值，建议调低音量（估算值，非实测）")
            }
            onLoudChange?(isLoud)
        }
        // 暴露历史：设备在跑且探测近期确认在播文件才累计（周剂量数据源）。
        // 单看 isRunning 会被残留音频会话虚记——实测一夜虚记数小时满幅
        // 声压，周剂量虚标 300%；宁漏记（网页流媒体无文件可探）不错记
        let probeActive = probeLastActiveAt.map { Date().timeIntervalSince($0) <= 12 } ?? false
        hearingLog.record(avgSPL: avg, playing: isRunning && probeActive)
        if lastAvgSPL != avg {
            lastAvgSPL = avg
            updateDoseRemainText() // 剩余时长随当前声压实时刷新
            updateBurnRateText()
        }
    }

    /// 实时消耗速率（% 额度/小时）：随当前声压每 2s 跳动
    private func updateBurnRateText() {
        let text = HearingLog.burnRate(avgSPL: lastAvgSPL).map { rate -> String in
            let avg = lastAvgSPL!
            let rateText = rate < 0.1 ? String(format: "%.3f", rate)
                : (rate < 10 ? String(format: "%.2f", rate) : String(format: "%.1f", rate))
            return "实时 \(rateText) %/h · 当前 ≈\(Int(avg.rounded())) dB"
        }
        if burnRateText != text { burnRateText = text }
    }

    /// 能力列表 → 按采样率分组的矩阵行（降序）
    /// nonisolated：后台线程刷新时也要调用
    nonisolated static func group(_ entries: [PhysicalFormatEntry],
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

    /// 立即优化格式（仅在设备空闲时执行）
    func optimizeNow() {
        guard let id = currentDeviceID else { return }
        guard !AudioDevice.isRunningSomewhere(id) else {
            // 播放中由源探测按源采样率/位深实时匹配（与「音频 MIDI 设置」一致）；
            // 手动优化拿不到源位深，只会按当前位深策略执行，因此留到空闲时
            log("播放中已由源探测实时匹配；手动优化按位深策略执行，请在暂停/停止后点击")
            return
        }
        Task.detached { [controller] in
            controller.evaluateAndApply(deviceID: id, context: "手动优化（空闲，完整）")
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
