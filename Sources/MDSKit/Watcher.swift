// Watcher.swift — 设备属性监听与自动切换调度
//
// 监听（均为 CoreAudio 官方属性）：
//   · 系统默认输出设备变化          → 重新绑定
//   · 设备标称采样率变化            → macOS 播放时会把设备切到音源采样率，此时优化位深
//   · 设备任意 IO 启停              → 播放开始/结束时重新评估
//   · 设备物理格式变化              → 播放器独占结束/外部修改后的善后
//
// 防抖：系统切换采样率、我们设置物理格式等都会引发连锁事件，
//       统一 debounce 0.35s 合并；切换是幂等的（已是目标格式则不动作）。

import CoreAudio
import Foundation
import Dispatch

/// 单个属性的监听器（持有 block 以便移除）
final class PropertyListener {
    private let objectID: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue = DispatchQueue(label: "mds.prop.listener")
    private var block: AudioObjectPropertyListenerBlock?

    init?(objectID: AudioObjectID,
          selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          handler: @escaping () -> Void) {
        self.objectID = objectID
        var addr = caAddress(selector, scope)
        guard AudioObjectHasProperty(objectID, &addr) else { return nil }
        self.address = addr

        let b: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        self.block = b
        let st = AudioObjectAddPropertyListenerBlock(objectID, &addr, queue, b)
        guard st == noErr else {
            self.block = nil
            return nil
        }
    }

    func remove() {
        guard let b = block else { return }
        var addr = address
        AudioObjectRemovePropertyListenerBlock(objectID, &addr, queue, b)
        block = nil
    }

    deinit { remove() }
}

public final class DeviceWatcher {
    /// nil = 跟随系统默认输出设备；否则为 UID/名称查询串
    public let deviceQuery: String?
    public let controller: FormatController
    /// 每次设备事件（无论是否执行切换）回调，供 UI 刷新状态
    public var onEvent: ((String) -> Void)?
    /// 空闲（无任何 IO）超过约 4 秒后恢复到的采样率；nil 表示不恢复
    public let restoreRate: Float64?
    /// 源探测轮询间隔（秒）
    public var probeInterval: Double = 4
    /// 源探测开关（GUI 可切换）
    public var probeEnabled = true
    /// 设备（重新）绑定后的稳定期（秒）：期间不修改设备格式。
    /// USB DAC 刚枚举完成时立即改格式，部分设备会因带宽重新协商失败而掉线。
    public var settleSeconds: Double = 8
    /// 熔断窗口（秒）：写入格式后设备在此窗口内消失，判定为「切换导致掉线」
    public var writeFaultWindow: Double = 20
    /// 连续故障次数达到该值 → 进入稳定（只读）模式
    public var faultThreshold = 2
    /// 起播稳定期（秒）：播放刚开始时播放器自己也在配置设备，
    /// 此时再写格式容易冲突导致设备复位，先等播放器配置完成
    public var playbackSettleSeconds: Double = 3
    /// 稳定模式变化回调（GUI 显示徽章/警告）
    public var onPassiveChange: ((Bool) -> Void)?
    /// 源探测结果回调（watch 串行队列）：正在播放的文件，无播放/未探测到为 nil。
    /// 与写格式解耦——供听力保护做实测曲目电平，hog/稳定期/自动切换关闭时同样有效
    public var onPlayingProbe: ((SourceProbe.Probe?) -> Void)?

    private let queue = DispatchQueue(label: "mds.watch")
    private var listeners: [PropertyListener] = []
    private var currentDevice: AudioObjectID = 0
    private var debounce: DispatchWorkItem?
    private var restoreWork: DispatchWorkItem?
    private var probeTimer: DispatchSourceTimer?
    private var lastProbeKey: String?
    private var lastProbeDate: Date?
    /// 播放中写入失败的文件 key 与时间：30 秒内不重复重试，
    /// 避免驱动拒绝某个位深时每 4 秒暂停/恢复一次 IO
    private var lastFailedKey: String?
    private var lastFailedAt: Date?
    private var manualOverrideDeadline = Date.distantPast
    private var probeBusy = false
    private var nilStreak = 0
    private var rebindDebounce: DispatchWorkItem?
    private var stopped = false
    /// 稳定期 + 写后掉线熔断（纯逻辑，自测覆盖）
    private var writeGuard = DeviceWriteGuard()
    /// 当前绑定的设备 UID（用于检测设备是否从系统消失）
    private var boundUID: String?
    /// 上一次观测到的播放状态（用于识别「起播」时刻）
    private var lastRunning = false
    /// 起播稳定期截止时间
    private var playSettleUntil = Date.distantPast
    /// 设备开始空闲（无任何音频 IO）的时刻
    private var idleSince = Date()
    /// 播放中探测到、但尚未成功应用的目标采样率（写失败时的兜底）
    private var pendingRate: Float64?
    /// 待应用目标的源位深（自动模式下按源匹配）
    private var pendingBits: Int?
    /// 待应用目标的来源描述（日志用）
    private var pendingSource: String?
    /// 设备连续空闲多少秒后才允许在空闲期写格式：
    /// 播放列表切歌的间隙很短，此时写格式可能与下一曲起播抢设备
    private let idleApplyDelay: Double = 4

    public init(deviceQuery: String?, controller: FormatController, restoreRate: Float64? = nil,
                probeEnabled: Bool = true, probeInterval: Double = 4) {
        self.deviceQuery = deviceQuery
        self.controller = controller
        self.restoreRate = restoreRate
        self.probeEnabled = probeEnabled
        self.probeInterval = probeInterval
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.writeGuard = DeviceWriteGuard(settleSeconds: self.settleSeconds,
                                               faultWindow: self.writeFaultWindow,
                                               faultThreshold: self.faultThreshold)
            self.rebind(reason: "启动")
            self.startProbeTimer()
        }
    }

    /// 停止监听（设备切换/退出时）
    public func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.listeners.forEach { $0.remove() }
            self?.listeners.removeAll()
            self?.debounce?.cancel()
            self?.restoreWork?.cancel()
            self?.probeTimer?.cancel()
            self?.probeTimer = nil
            self?.currentDevice = 0
        }
    }

    /// 手动切换后抑制源探测覆盖（秒）
    public func suppressProbe(seconds: Double) {
        queue.async { self.manualOverrideDeadline = Date().addingTimeInterval(seconds) }
    }

    /// 解除稳定模式，恢复自动修改格式（GUI「重新启用」）
    public func resetPassive() {
        queue.async { [weak self] in
            guard let self else { return }
            self.writeGuard.reset(at: Date())
            self.onPassiveChange?(false)
            log("稳定模式已解除 · \(Int(self.settleSeconds)) 秒稳定期后恢复自动切换")
        }
    }

    private func startProbeTimer() {
        probeTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: max(probeInterval, 1.5))
        t.setEventHandler { [weak self] in self?.probeTick() }
        t.resume()
        probeTimer = t
    }

    // MARK: - 绑定

    private func rebind(reason: String) {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
        currentDevice = 0

        // 之前绑定的设备若已从系统消失：若发生在写入格式后不久，记一次故障
        if let uid = boundUID, AudioDevice.findDevice(matching: uid) == nil {
            noteDeviceVanished()
        }
        boundUID = nil

        guard !stopped else { return }
        guard let deviceID = AudioDevice.findDevice(matching: deviceQuery) else {
            log("未找到匹配的输出设备（\(deviceQuery ?? "默认")），5 秒后重试 · \(reason)")
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.rebind(reason: "重试")
            }
            return
        }
        currentDevice = deviceID
        let snap = AudioDevice.snapshot(deviceID: deviceID)
        boundUID = snap.uid
        // 稳定期：设备刚（重新）出现/刚成为默认输出，先不做任何写操作，
        // 给 USB 枚举、时钟同步留出时间
        writeGuard.noteBound(at: Date())
        log("监听设备：「\(snap.name)」 uid=\(snap.uid) · nominal=\(snap.nominalRate.map(hz) ?? "?") · \(reason)")
        if let cur = snap.streams.first?.physical {
            log("  当前格式：\(describe(cur))")
        }
        controller.logV("稳定期 \(Int(settleSeconds))s：期间不修改格式")

        // 设备级监听
        if let l = PropertyListener(objectID: deviceID, selector: kAudioDevicePropertyNominalSampleRate,
                                    handler: { [weak self] in self?.scheduleEvaluate("采样率变化") }) {
            listeners.append(l)
        }
        if let l = PropertyListener(objectID: deviceID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                    handler: { [weak self] in self?.scheduleEvaluate("播放状态变化") }) {
            listeners.append(l)
        }
        // 每个输出流：物理格式变化（外部播放器/系统修改后的善后）
        for streamID in AudioDevice.outputStreams(deviceID) {
            if let l = PropertyListener(objectID: streamID, selector: kAudioStreamPropertyPhysicalFormat,
                                        handler: { [weak self] in self?.scheduleEvaluate("物理格式变化") }) {
                listeners.append(l)
            }
        }
        // 跟随默认设备：系统级监听
        if deviceQuery == nil,
           let l = PropertyListener(objectID: AudioObjectID(kAudioObjectSystemObject),
                                    selector: kAudioHardwarePropertyDefaultOutputDevice,
                                    handler: { [weak self] in
                                        self?.scheduleRebind(reason: "默认输出设备变化")
                                    }) {
            listeners.append(l)
        }

        scheduleEvaluate("初始评估")
    }

    /// 设备在写入格式后不久从系统消失 → 记一次故障；
    /// 连续达到阈值即进入稳定（只读）模式，不再把设备打掉
    private func noteDeviceVanished() {
        let faultsBefore = writeGuard.faults
        if writeGuard.noteVanished(at: Date()) {
            log("⚠️ 格式切换后设备掉线（第 \(writeGuard.faults) 次）→ 已进入稳定模式：不再自动修改设备格式。"
                + "如需恢复，请在面板中点「重新启用自动切换」。")
            onPassiveChange?(true)
        } else if writeGuard.faults > faultsBefore {
            log("⚠️ 格式切换后设备掉线（第 \(writeGuard.faults) 次），继续观察")
        }
    }

    /// 每次轮询检查绑定是否仍然有效：设备消失、或对象 ID 变化都触发重绑。
    ///
    /// HAL 的 AudioObjectID 是临时的：USB 短暂重枚举（如端口复位、睡眠唤醒）
    /// 后设备会拿到新 ID。若重枚举恰好落在两次探测（4s）之间，旧 ID 上的
    /// 属性监听器从此不再回调、读旧 ID 也拿不到真实状态——只查 uid 是否
    /// 存在会漏判，Watcher 会变成永远「查无播放」的僵尸（且日志毫无异常）。
    /// 因此必须比对解析出的 ID 与当前绑定是否一致。
    private func deviceStillPresent() -> Bool {
        guard let uid = boundUID else { return true }
        guard let id = AudioDevice.findDevice(matching: uid) else {
            log("⚠️ 设备已从系统消失（uid=\(uid)）")
            noteDeviceVanished()
            currentDevice = 0
            boundUID = nil
            scheduleRebind(reason: "设备消失")
            return false
        }
        if id != currentDevice {
            log("设备已重新枚举（HAL 对象 ID 变化），重新绑定监听 · uid=\(uid)")
            currentDevice = 0
            boundUID = nil
            scheduleRebind(reason: "设备对象更新")
            return false
        }
        return true
    }

    /// 观测播放状态并维护起播稳定期；返回设备当前是否在播放
    private func observeRunning() -> Bool {
        let running = AudioDevice.isRunningSomewhere(currentDevice)
        if running && !lastRunning {
            // 起播瞬间：播放器自己也在配置设备，先让位几秒
            playSettleUntil = Date().addingTimeInterval(playbackSettleSeconds)
            controller.logV("起播稳定期 \(Int(playbackSettleSeconds))s：期间不修改格式")
        }
        if !running && lastRunning {
            // 记录真正开始空闲的时刻：只有持续空闲足够久才能确定
            // 不是切歌间隙，此时写设备才是安全的
            idleSince = Date()
        }
        lastRunning = running
        return running
    }

    /// 综合写入许可：绑定稳定期 + 起播稳定期 + 熔断
    private func canWriteNow() -> Bool {
        guard writeGuard.canWrite(at: Date()) else { return false }
        if Date() < playSettleUntil {
            controller.logV("起播稳定期内，不修改格式")
            return false
        }
        return true
    }

    /// 调用控制器切换，并记录「确实改动了格式」的时间（熔断判定依据）
    @discardableResult
    private func applyWatched(deviceID: AudioObjectID,
                              streamID: AudioObjectID,
                              desiredRate: Float64,
                              sourceBits: Int? = nil,
                              channels: Int? = 2,
                              context: String) -> Bool {
        let before = AudioDevice.streamPhysicalFormat(streamID)
        let result = controller.applyBestFormat(deviceID: deviceID, streamID: streamID,
                                                desiredRate: desiredRate,
                                                sourceBits: sourceBits,
                                                channels: channels,
                                                context: context)
        let after = AudioDevice.streamPhysicalFormat(streamID)
        if let before, let after, !sameFormat(before, after) {
            writeGuard.noteWrite(at: Date())
        }
        return result != nil
    }

    /// 默认输出设备变化（防抖 0.5s 合并）：设备反复插拔时事件可达每秒
    /// 数十条，直接全量 rebind 会风暴
    private func scheduleRebind(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.rebindDebounce?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.rebind(reason: reason) }
            self.rebindDebounce = item
            self.queue.asyncAfter(deadline: .now() + 0.5, execute: item)
        }
    }

    // MARK: - 评估调度

    private func scheduleEvaluate(_ context: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onEvent?(context)
            self.debounce?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.evaluateNow(context: context)
            }
            self.debounce = item
            self.queue.asyncAfter(deadline: .now() + 0.35, execute: item)

            self.handleIdleRestore()
        }
    }

    // MARK: - 源探测（本地音频文件格式发现）

    private func probeTick() {
        guard !stopped, probeEnabled, currentDevice != 0 else { return }
        guard deviceStillPresent() else { return }
        let running = observeRunning()
        guard running else {
            // 无播放：清除探测状态，处理空闲恢复
            if lastProbeKey != nil { lastProbeKey = nil }
            nilStreak = 0
            onPlayingProbe?(nil)
            handleIdleRestore()
            return
        }
        guard !probeBusy else { return }

        // 双快照识别「正在播放」的文件：播放器常常同时打开多个音频文件
        // （播放列表预读、播完不关闭的残留句柄），采样率最高者未必是正在
        // 播放的那首。正在播放的文件读取偏移持续前进，残留句柄停滞——
        // 间隔 1.3s 两次扫描，挑 offset 前进最快者。
        probeBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let a = SourceProbe.scan()
            let best: SourceProbe.Probe?
            if a.isEmpty {
                best = nil
            } else {
                Thread.sleep(forTimeInterval: 1.3)
                let b = SourceProbe.scan()
                best = SourceProbe.pickPlaying(a: a, b: b)
            }
            self?.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.probeBusy = false
                // 探测结果先供听力保护（实测曲目电平），与是否写格式无关：
                // hog 独占 / 自动切换关闭 / 稳定期时同样回调
                self.onPlayingProbe?(best)
                guard self.controller.enabled else { return }
                // 稳定（只读）模式 / 绑定稳定期 / 起播稳定期：不写格式
                guard self.canWriteNow() else { return }
                if let hog = AudioDevice.hogPID(self.currentDevice), hog != -1 {
                    return // 播放器独占（hog），由播放器自行管理格式
                }
                self.applyProbe(best)
            }
        }
    }

    /// 应用一次源探测决策（在 watch 串行队列上调用）
    private func applyProbe(_ best: SourceProbe.Probe?) {
        guard !stopped, currentDevice != 0 else { return }
        guard let best else {
            // 播放中的文件不可识别（流媒体）或读取信号瞬时中断
            // （文件回绕/换歌间隙）：连续 3 个周期无前进证据才认为
            // 源不可知，交回「跟随设备采样率」路径，避免位深抖动
            nilStreak += 1
            if nilStreak >= 3 {
                lastProbeKey = nil
                lastProbeDate = nil
            }
            return
        }
        nilStreak = 0
        lastProbeDate = Date()
        guard Date() >= manualOverrideDeadline else {
            controller.logV("源探测被手动切换抑制：\(best)")
            return
        }
        let wantBits = desiredSourceBits(best)
        // 幂等：同一文件且设备格式（采样率 + 位深）已匹配则跳过
        if best.key == lastProbeKey, formatSatisfied(rate: best.sampleRate, sourceBits: wantBits) {
            return
        }
        lastProbeKey = best.key

        if formatSatisfied(rate: best.sampleRate, sourceBits: wantBits) {
            if pendingRate != nil || pendingBits != nil {
                controller.logV("设备格式已匹配 \(hz(best.sampleRate))，取消待切换")
            }
            pendingRate = nil
            pendingBits = nil
            pendingSource = nil
            return
        }

        // 播放中直接应用：与「音频 MIDI 设置」写入的是同一条 HAL 属性，
        // 切换后物理格式保持可混音交错（0xc）、虚拟格式保持 float。
        // （此前播放中切换导致加速的根因是写入了 NonMixable 的 0x4c 格式，
        //  已由 FormatMatcher / FormatController 两层过滤修复。）
        let failedRecently = best.key == lastFailedKey
            && (lastFailedAt.map { Date().timeIntervalSince($0) < 30 } ?? false)
        if !failedRecently {
            guard let streamID = AudioDevice.outputStreams(currentDevice).first else { return }
            let srcBits = wantBits.map { "/\($0)bit" } ?? ""
            let currentDesc = AudioDevice.streamPhysicalFormat(streamID).map(describe) ?? "?"
            log("播放中源为 \(hz(best.sampleRate))\(srcBits)，设备当前 \(currentDesc)：立即匹配")
            let ok = applyWatched(deviceID: currentDevice, streamID: streamID,
                                  desiredRate: best.sampleRate,
                                  sourceBits: wantBits,
                                  context: "播放中匹配（源 \(URL(fileURLWithPath: best.path).lastPathComponent)）")
            if ok {
                lastFailedKey = nil
                lastFailedAt = nil
                pendingRate = nil
                pendingBits = nil
                pendingSource = nil
                onEvent?("源探测（已匹配）")
                return
            }
            lastFailedKey = best.key
            lastFailedAt = Date()
        }
        // 写失败（驱动拒绝/设备忙）：登记目标，等设备持续空闲后再应用
        if pendingRate != best.sampleRate || pendingBits != wantBits {
            log("播放中切换未成功，暂停或停止播放后自动应用")
        }
        pendingRate = best.sampleRate
        pendingBits = wantBits
        pendingSource = best.key
        onEvent?("源探测（待切换）")
    }

    /// 自动模式下参与位深匹配的源位深。
    /// DSD（Probe 中记为 1bit）等无意义的位深不参与，交给设备最高位深。
    private func desiredSourceBits(_ probe: SourceProbe.Probe) -> Int? {
        guard let bits = probe.bitsPerSample, bits >= 16 else { return nil }
        return bits
    }

    /// 设备当前格式是否已经是「该源在自动模式下应到达的格式」。
    /// 采样率相同但位深不同（如源 24bit、设备 32bit）也算不匹配。
    private func formatSatisfied(rate: Float64, sourceBits: Int?) -> Bool {
        guard rateMatches(rate) else { return false }
        guard let sourceBits else { return true }
        guard let streamID = AudioDevice.outputStreams(currentDevice).first,
              let phys = AudioDevice.streamPhysicalFormat(streamID) else { return true }
        let policy: BitDepthPolicy
        if case .highest = controller.policy {
            policy = .match(sourceBits)
        } else {
            policy = controller.policy
        }
        guard let planned = FormatMatcher.select(
            targetRate: rate, targetBits: sourceBits, preferredChannels: 2,
            entries: AudioDevice.streamAvailablePhysicalFormats(streamID),
            policy: policy) else { return true }
        return sameFormat(phys, planned.asbd)
    }

    /// 设备标称采样率是否已与探测结果匹配
    private func rateMatches(_ rate: Float64) -> Bool {
        guard let cur = AudioDevice.nominalRate(currentDevice) else { return false }
        return abs(cur - rate) < 0.5
    }

    private func evaluateNow(context: String) {
        guard currentDevice != 0 else { return }
        guard deviceStillPresent() else { return }
        guard AudioDevice.findDevice(matching: deviceQuery) == currentDevice
            || (deviceQuery == nil && AudioDevice.defaultOutputDeviceID() == currentDevice) else {
            rebind(reason: "设备已失效 · \(context)")
            return
        }
        // 设备空闲（无音频 IO）时不写格式：仅在真正播放时切换。
        // 这样「在系统设置里把输出切到 DAC」这类操作不会被软件顺手改格式，
        // 对脆弱的 USB 设备尤其重要（改格式会触发带宽重新协商）。
        guard observeRunning() else {
            controller.logV("设备空闲，不修改格式 · \(context)")
            return
        }
        // 稳定（只读）模式 / 绑定稳定期 / 起播稳定期：不写设备
        guard canWriteNow() else {
            controller.logV(writeGuard.passive
                            ? "稳定模式：跳过格式评估 · \(context)"
                            : "稳定期内，跳过格式评估 · \(context)")
            return
        }
        // 播放中的格式跟随由源探测驱动（能同时拿到源采样率与位深，
        // 并按源精确匹配）；这里只处理设备事件，不重复写格式。
        controller.logV("播放中格式由源探测匹配 · \(context)")
    }

    /// 空闲应用：设备持续空闲时，把「播放中登记的目标格式」写进去
    /// （没有目标时按 restoreRate 恢复）。
    ///
    /// 写设备只在空闲期做：播放中写会让播放器送数节奏与设备率失配，
    /// 轻则中断播放，重则播放被加速。切歌间隙通常只有一两秒，
    /// 因此要求连续空闲 ≥ idleApplyDelay 秒，避免与下一曲起播抢设备。
    private func handleIdleRestore() {
        restoreWork?.cancel()
        restoreWork = nil
        guard currentDevice != 0 else { return }
        guard let pending = pendingRate ?? restoreRate else { return }
        guard !AudioDevice.isRunningSomewhere(currentDevice) else { return }
        let isPending = pendingRate != nil
        let source = pendingSource
        let bits = isPending ? pendingBits : nil
        // 还没空闲够久（可能只是切歌间隙）：等到满足条件的那一刻再试
        let wait = max(0.05, idleApplyDelay - Date().timeIntervalSince(idleSince))

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.currentDevice != 0 else { return }
            guard self.writeGuard.canWrite(at: Date()) else { return }
            guard self.deviceStillPresent() else { return }
            // 空闲判定是异步的：真正写之前再确认一次
            guard !AudioDevice.isRunningSomewhere(self.currentDevice) else { return }
            guard Date().timeIntervalSince(self.idleSince) >= self.idleApplyDelay else { return }
            if let hog = AudioDevice.hogPID(self.currentDevice), hog != -1 { return }
            guard let streamID = AudioDevice.outputStreams(self.currentDevice).first else { return }
            self.applyWatched(deviceID: self.currentDevice,
                              streamID: streamID,
                              desiredRate: pending,
                              sourceBits: bits,
                              context: isPending
                                  ? "空闲应用（上次播放源 \(source ?? hz(pending))）"
                                  : "空闲恢复")
            // 目标已尝试应用（成功与否都以设备回读为准），清除待办
            if self.pendingRate == pending {
                self.pendingRate = nil
                self.pendingBits = nil
                self.pendingSource = nil
            }
        }
        restoreWork = item
        queue.asyncAfter(deadline: .now() + wait, execute: item)
    }
}
