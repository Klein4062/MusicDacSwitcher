// CLI.swift — 命令行入口：list / format / best / set / watch

import CoreAudio
import Foundation
import Dispatch
import MDSKit

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("错误: \(msg)\n".utf8))
    exit(1)
}

// MARK: - 参数解析

struct ParsedArgs {
    var flags = Set<String>()
    var options = [String: String]()
    var positional = [String]()

    func bits() -> Int? { options["bits"].flatMap(Int.init) }
}

private let knownOptions: Set<String> = ["device", "bits", "restore-rate", "rate", "probe-interval"]

func parseArgs(_ args: [String]) -> ParsedArgs {
    var p = ParsedArgs()
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let body = String(a.dropFirst(2))
            if let eq = body.firstIndex(of: "=") {
                p.options[String(body[..<eq])] = String(body[body.index(after: eq)...])
            } else if knownOptions.contains(body), i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                p.options[body] = args[i + 1]
                i += 1
            } else {
                p.flags.insert(body)
            }
        } else if a.hasPrefix("-"), a.count > 1 {
            p.flags.insert(String(a.dropFirst()))
        } else {
            p.positional.append(a)
        }
        i += 1
    }
    return p
}

/// "192000" / "192k" / "192.0kHz" / "768" → 768000
func parseRate(_ s: String) -> Float64? {
    var t = s.lowercased()
        .replacingOccurrences(of: "khz", with: "k")
        .replacingOccurrences(of: "hz", with: "")
    var mult: Float64 = 1
    if t.hasSuffix("k") { mult = 1_000; t.removeLast() }
    else if t.hasSuffix("m") { mult = 1_000_000; t.removeLast() }
    guard let v = Double(t), v > 0 else { return nil }
    return v * mult
}

// MARK: - 入口

func cliMain() {
    var args = Array(CommandLine.arguments.dropFirst())
    let command = args.isEmpty ? "help" : args.removeFirst()

    switch command {
    case "list", "devices": cmdList(args)
    case "format", "status": cmdFormat(args)
    case "best": cmdBest(args)
    case "set": cmdSet(args)
    case "watch", "daemon": cmdWatch(args)
    case "probe": cmdProbe(args)
    case "vol", "volume": cmdVol(args)
    case "playtest": cmdPlayTest(args)
    case "selftest", "test": runSelfTest()
    case "version": print("MusicDacSwitcher 0.1.0")
    default: printHelp()
    }
}

func printHelp() {
    print("""
    MusicDacSwitcher (mds) — 播放时自动把输出设备格式切换为匹配音源的最佳格式

    用法:
      mds list [--json]                     列出输出设备及支持的格式
      mds format [--device <uid|名称>]      显示当前格式
      mds best <rate> [--bits N]            预览对某采样率将选择的最佳格式（不修改）
      mds set <rate> [--bits N] [--device]  立即切换到最佳格式（如 44100 / 192k / 768kHz）
      mds probe                             查看探测到的打开音频文件（含正在播放识别）
      mds vol [--device <uid|名称>]         查看设备音量（dB）与估算声压
      mds playtest <文件> [--device] [--seconds N]  端到端测试：静音播放验证自动切换
      mds watch [选项]                      守护模式：播放时自动切换
        --device <uid|名称>     指定设备（默认跟随系统默认输出设备）
        --bits N                固定位深（默认：每采样率下最高整数位深）
        --restore-rate <rate>   空闲 3 秒后恢复到的采样率（可选）
        --dry-run               只打印决策，不实际切换
        --no-probe              关闭"正在播放文件"源格式探测（默认开启）
        --probe-interval <秒>   源探测轮询间隔（默认 4 秒）
        -v                      详细输出
      mds probe                             探测正在播放的本地音频文件及其格式
      mds selftest                          匹配算法自测

    示例:
      mds set 192k
      mds set 44100 --bits 16
      mds watch --device "Denafrips" --restore-rate 44100

    rate 写法: 44100 / 44.1k / 96k / 192.0kHz / 768k
    """)
}

// MARK: - 子命令

/// 查看设备音量（dB）与估算声压
func cmdVol(_ args: [String]) {
    let p = parseArgs(args)
    guard let id = AudioDevice.findDevice(matching: p.options["device"]) else {
        fail("未找到输出设备")
    }
    let snap = AudioDevice.snapshot(deviceID: id)
    let vol = AudioDevice.volumeInfo(deviceID: id)
    print("设备: \(snap.name)")
    guard let db = vol.decibels else {
        print("音量: 设备未上报音量属性（固定输出或独占模式）")
        return
    }
    let scalar = vol.scalar.map { String(format: "%.3f", $0) } ?? "?"
    print("音量: \(String(format: "%.1f", db)) dB（scalar \(scalar)）")
    if let lo = vol.rangeMin, let hi = vol.rangeMax {
        print("范围: \(String(format: "%.1f", lo)) ~ \(String(format: "%.1f", hi)) dB")
    }
    if vol.muted {
        print("状态: 静音")
        return
    }
    let params = HearingGuard.Params()
    // GUI 面板持久化的真实参数优先（写入 com.musicdacswitcher.app 域）；
    // 耳机档案按当前设备名匹配后覆盖前四项（与 GUI 自动跟随一致）
    let gui = UserDefaults(suiteName: "com.musicdacswitcher.app")
    var real = HearingGuard.Params(
        sensitivity: gui?.object(forKey: "mds.hearing.sens") as? Double ?? params.sensitivity,
        impedance: gui?.object(forKey: "mds.hearing.imp") as? Double ?? params.impedance,
        maxVrms: gui?.object(forKey: "mds.hearing.vrms") as? Double ?? params.maxVrms,
        threshold: gui?.object(forKey: "mds.hearing.threshold") as? Double ?? params.threshold,
        crestDB: gui?.object(forKey: "mds.hearing.crest") as? Double ?? params.crestDB,
        deviceAttenuationDB: gui?.object(forKey: "mds.hearing.atten") as? Double ?? params.deviceAttenuationDB)
    var fromGUI = gui?.object(forKey: "mds.hearing.sens") != nil
    let autoFollow = gui?.object(forKey: "mds.hearing.autoprofile") as? Bool ?? true
    if let data = gui?.data(forKey: "mds.hearing.profiles"),
       let ps = try? JSONDecoder().decode([HearingProfile].self, from: data),
       !ps.isEmpty {
        if let hit = HearingProfile.match(ps, deviceName: snap.name) {
            real.sensitivity = hit.sensDB
            real.impedance = hit.impOhm
            real.maxVrms = hit.maxVrms
            real.deviceAttenuationDB = hit.attenDB
            fromGUI = true
            print("耳机档案: \(hit.name)（按设备 \(snap.name) 匹配）")
        } else if autoFollow {
            // 与 GUI 一致：外放/未建档设备不按残留耳机参数瞎猜（宁缺毋错）
            real.maxVrms = 0
        }
    }
    if let peak = HearingGuard.estimatedSPL(volumeDB: db, params: real),
       let avg = HearingGuard.averageSPL(peakSPL: peak, params: real) {
        let verdict = HearingGuard.exceedsThreshold(spl: peak, params: real)
            ? " → 平均已超过 \(Int(real.threshold)) dB 阈值 ⚠️" : ""
        print(String(format: "估算声压: 峰值 ≤ %.1f · 平均 ≈ %.1f dB SPL（%@ %.0f dB/mW · %.0f Ω · %.1f Vrms · 峰值因子 %.0f · 机身衰减 %.0f dB）",
                     peak, avg, fromGUI ? "面板参数" : "默认参数",
                     real.sensitivity, real.impedance, real.maxVrms, real.crestDB,
                     real.deviceAttenuationDB) + verdict)
        print("提示: 峰值=满幅正弦等效上限，平均≈LAeq（告警口径）；机身旋钮控音量时在 GUI 面板填「机身衰减」；0 dB 音量 = 无衰减直通")
    } else if real.maxVrms <= 0 {
        // 不估算：档案置为不估算（如 HDB 630 自控音量不可见），或设备
        // 无匹配档案（外放）——参数无从校准，宁缺毋错，不累计剂量
        print("估算声压: —（不估算：档案不可校准或设备无匹配档案，不累计剂量）")
    }
    if let hist = HearingLog.windowAverageSPL() {
        print(String(format: "近7天均值: ≈ %.1f dB（所有播放的时长加权平均）", hist))
    }
    if let dose = HearingLog.weeklyDose() {
        let eq = dose.equivalentHours < 1
            ? String(format: "%.0f 分钟", dose.equivalentHours * 60)
            : String(format: "%.1fh", dose.equivalentHours)
        print(String(format: "听力剂量: 近 7 天 %.1f%%（等效 %@ / %.0fh @80dB · 实际聆听 %.1fh）",
                     dose.percent, eq, HearingLog.referenceHours, dose.activeHours))
        let avg = HearingGuard.averageSPL(
            peakSPL: HearingGuard.estimatedSPL(volumeDB: vol.muted ? nil : db, params: real),
            params: real)
        if let h = HearingLog.remainingHours(dose: dose, avgSPL: avg) {
            let hText = h >= 999 ? "999+ 小时" : String(format: "%.0f 小时", h)
            if let avg {
                print(String(format: "额度余额: 剩余 %.1f%% · 当前 ≈%.0f dB 下约可再听 %@",
                             max(0, 100 - dose.percent), avg, hText))
            } else {
                print(String(format: "额度余额: 剩余 %.1f%%（80 dB 下 %@）",
                             max(0, 100 - dose.percent), hText))
            }
        }
        if dose.percent > 100 {
            print("提示: 已超过 WHO 周剂量参考（80dB×40h），建议控制高音量聆听时长")
        }
    }
    if let rate = HearingLog.burnRate(
        avgSPL: HearingGuard.averageSPL(
            peakSPL: HearingGuard.estimatedSPL(volumeDB: vol.muted ? nil : db, params: real),
            params: real)) {
        let rateText = rate < 0.1 ? String(format: "%.3f", rate)
            : (rate < 10 ? String(format: "%.2f", rate) : String(format: "%.1f", rate))
        print(String(format: "实时消耗: %@ %%/h（当前声压口径，随音量与曲目电平变化）", rateText))
    }
}

func cmdList(_ args: [String]) {
    let p = parseArgs(args)
    let json = p.flags.contains("json")
    let devices = AudioDevice.outputDeviceSnapshots()

    if json {
        var out: [[String: Any]] = []
        for d in devices {
            out.append([
                "uid": d.uid,
                "name": d.name,
                "manufacturer": d.manufacturer,
                "isDefault": d.isDefaultOutput,
                "nominalRate": d.nominalRate ?? 0,
                "hogPID": d.hogPID.map(Int.init) ?? -1,
                "running": d.runningSomewhere,
                "currentFormat": d.streams.first?.physical.map(describe) ?? "",
                "formats": d.streams.first.map { stream in
                    stream.available.map { e in
                        [
                            "rateMin": e.rateMin,
                            "rateMax": e.rateMax,
                            "bits": e.bits,
                            "channels": e.channels,
                            "kind": e.isFloat ? "float" : "int",
                        ] as [String: Any]
                    }
                } ?? [],
            ])
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8)!)
        }
        return
    }

    if devices.isEmpty { print("（未发现输出设备）"); return }
    for d in devices {
        print("\(d.isDefaultOutput ? "◆" : " ◇") \(d.name)\(d.manufacturer.isEmpty ? "" : " — \(d.manufacturer)")")
        print("    uid: \(d.uid)")
        if let r = d.nominalRate { print("    标称采样率: \(hz(r))") }
        print("    正在使用: \(d.runningSomewhere ? "是" : "否") · hog: \(d.hogPID == nil || d.hogPID == -1 ? "无" : "PID \(d.hogPID!)")")
        for s in d.streams {
            if let cur = s.physical {
                print("    当前格式: \(describe(cur))")
            }
            print("    支持的物理格式:")
            for line in summarizeFormats(s.available) {
                print("      \(line)")
            }
        }
        print()
    }
}

/// 把能力列表按采样率分组，输出 "44.1kHz → int 16/24bit, 2ch" 形式
func summarizeFormats(_ entries: [PhysicalFormatEntry]) -> [String] {
    guard !entries.isEmpty else { return ["      （未报告）"] }
    var order: [String] = []
    var groups = [String: Set<String>]()
    for e in entries {
        let key = e.rateMin == e.rateMax ? hz(e.rateMin) : "\(hz(e.rateMin))~\(hz(e.rateMax))"
        let kind = e.isFloat ? "float" : "int"
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].insert("\(e.bits)bit \(kind) \(e.channels)ch")
    }
    // 采样率数值排序
    order.sort { rateValue(of: $0) < rateValue(of: $1) }
    return order.map { key in
        let set = groups[key]!.sorted { $0.count < $1.count }
        return "\(key) → \(set.joined(separator: " / "))"
    }
}

private func rateValue(of label: String) -> Float64 {
    let digits = label.prefix { $0.isNumber || $0 == "." }
    return Float64(digits) ?? 0
}

func cmdFormat(_ args: [String]) {
    let p = parseArgs(args)
    guard let id = AudioDevice.findDevice(matching: p.options["device"]) else {
        fail("找不到输出设备：\(p.options["device"] ?? "默认")")
    }
    let d = AudioDevice.snapshot(deviceID: id)
    print("设备: \(d.name) (uid: \(d.uid))")
    if let r = d.nominalRate { print("标称采样率: \(hz(r))") }
    print("正在使用: \(d.runningSomewhere ? "是" : "否") · hog: \(d.hogPID == nil || d.hogPID == -1 ? "无" : "PID \(d.hogPID!)")")
    for (i, s) in d.streams.enumerated() {
        if let cur = s.physical {
            print("流 #\(i + 1) 当前物理格式: \(describe(cur))")
        }
        for line in summarizeFormats(s.available) {
            print("    \(line)")
        }
    }
}

func cmdBest(_ args: [String]) {
    let p = parseArgs(args)
    guard let rateStr = p.positional.first, let rate = parseRate(rateStr) else {
        fail("用法: mds best <rate> [--bits N] [--device <uid|名称>]")
    }
    let apply = p.flags.contains("apply")
    let policy: BitDepthPolicy = p.bits().map { .fixed($0) } ?? .highest
    guard let id = AudioDevice.findDevice(matching: p.options["device"]) else {
        fail("找不到输出设备：\(p.options["device"] ?? "默认")")
    }
    guard let streamID = AudioDevice.outputStreams(id).first else {
        fail("该设备没有输出流")
    }
    let controller = FormatController(policy: policy, dryRun: !apply, verbose: true)
    guard let result = controller.applyBestFormat(deviceID: id, streamID: streamID,
                                                  desiredRate: rate, context: apply ? "best --apply" : "best 预览") else {
        fail("无法为 \(hz(rate)) 选择格式")
    }
    print("最佳格式: \(describe(result))")
    if !apply { print("（预览模式，加 --apply 实际切换）") }
}

func cmdSet(_ args: [String]) {
    let p = parseArgs(args)
    guard let rateStr = p.positional.first, let rate = parseRate(rateStr) else {
        fail("用法: mds set <rate> [--bits N] [--device <uid|名称>]")
    }
    let policy: BitDepthPolicy = p.bits().map { .fixed($0) } ?? .highest
    guard let id = AudioDevice.findDevice(matching: p.options["device"]) else {
        fail("找不到输出设备：\(p.options["device"] ?? "默认")")
    }
    guard let streamID = AudioDevice.outputStreams(id).first else {
        fail("该设备没有输出流")
    }
    let controller = FormatController(policy: policy, dryRun: p.flags.contains("dry-run"), verbose: true)
    guard controller.applyBestFormat(deviceID: id, streamID: streamID,
                                     desiredRate: rate, context: "set \(rateStr)") != nil else {
        fail("切换失败")
    }
    if let verify = AudioDevice.streamPhysicalFormat(streamID) {
        print("当前格式: \(describe(verify))")
    }
}

func cmdProbe(_ args: [String]) {
    let a = SourceProbe.scan()
    if a.isEmpty {
        print("（当前没有已打开的可解析音频文件 — 需要 macOS 正在播放本地音频）")
        return
    }
    // 双快照：标记读取偏移前进（= 正在播放）的文件
    print("… 间隔 1.3s 二次扫描以识别正在播放的文件")
    Thread.sleep(forTimeInterval: 1.3)
    let b = SourceProbe.scan()
    let playing = SourceProbe.pickPlaying(a: a, b: b)
    for pr in b.sorted(by: { $0.sampleRate > $1.sampleRate }) {
        let mark = playing?.path == pr.path ? "▶ 正在播放" : "  残留"
        let off = pr.offset.map { String($0) } ?? "?"
        print("\(mark)  \(pr.description)  offset=\(off) pid=\(pr.pid.map(String.init) ?? "?")")
        print("    路径: \(pr.path)")
    }
    if let playing {
        print("\n决策: 跟随 \(playing.description)")
        if let lv = TrackLevelAnalyzer.analyze(path: playing.path) {
            print(String(format: "曲目电平: 平均 %.1f · 峰值 %.1f dBFS（听力保护按实测平均折算）",
                         lv.rmsDB, lv.peakDB))
        }
    } else {
        print("\n决策: 未发现读取活动（句柄均为残留），不切换")
    }
}

func cmdWatch(_ args: [String]) {
    let p = parseArgs(args)
    let verbose = p.flags.contains("v") || p.flags.contains("verbose")
    let dryRun = p.flags.contains("dry-run")
    let policy: BitDepthPolicy = p.bits().map { .fixed($0) } ?? .highest
    let restoreRate = p.options["restore-rate"].flatMap(parseRate)

    let controller = FormatController(policy: policy, dryRun: dryRun, verbose: verbose)
    let probeOn = !p.flags.contains("no-probe")
    let probeInterval = p.options["probe-interval"].flatMap(Double.init) ?? 4
    let watcher = DeviceWatcher(deviceQuery: p.options["device"],
                                controller: controller,
                                restoreRate: restoreRate,
                                probeEnabled: probeOn,
                                probeInterval: probeInterval)
    if dryRun { log("⚠️ dry-run 模式：只打印决策，不会实际切换") }
    if let rr = restoreRate { log("空闲恢复采样率: \(hz(rr))") }
    log("源探测: \(probeOn ? "开启（每 \(probeInterval)s 扫描正在播放的本地音频文件）" : "关闭")")

    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    src.setEventHandler {
        print("\n退出")
        exit(0)
    }
    src.resume()

    watcher.start()
    dispatchMain()
}
