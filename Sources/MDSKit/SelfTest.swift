// SelfTest.swift — 匹配算法自测（mds selftest，不依赖 XCTest，任何环境可跑）

import CoreAudio
import Foundation

// MARK: - 测试用格式构造

private func entry(rate: Float64, bits: UInt32, channels: UInt32 = 2, isFloat: Bool = false) -> PhysicalFormatEntry {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = rate
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = isFloat
        ? kAudioFormatFlagIsFloat
        : (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
    asbd.mChannelsPerFrame = channels
    asbd.mBitsPerChannel = bits
    asbd.mFramesPerPacket = 1
    asbd.mBytesPerFrame = channels * bits / 8
    asbd.mBytesPerPacket = asbd.mBytesPerFrame
    return PhysicalFormatEntry(AudioStreamRangedDescription(
        mFormat: asbd,
        mSampleRateRange: AudioValueRange(mMinimum: rate, mMaximum: rate)))
}

/// 模拟类似 TP55 的 DAC：44.1 系 + 48 系全档，16/24/32bit 整数
private let tp55: [PhysicalFormatEntry] = {
    var e: [PhysicalFormatEntry] = []
    for rate: Float64 in [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000] {
        for bits: UInt32 in [16, 24, 32] {
            e.append(entry(rate: rate, bits: bits))
        }
    }
    return e
}()

/// 非交错（每声道独立缓冲区）条目
private func niEntry(rate: Float64, bits: UInt32, channels: UInt32 = 2) -> PhysicalFormatEntry {
    var e = entry(rate: rate, bits: bits, channels: channels)
    e.asbd.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
    return e
}

/// NonMixable（flags 0x4c）条目：TP55 对每个采样率都会重复上报这一组，
/// 采样率/位深/字节数与可混音组完全相同，只有 0x40 标志不同
private func nmEntry(rate: Float64, bits: UInt32, channels: UInt32 = 2) -> PhysicalFormatEntry {
    var e = entry(rate: rate, bits: bits, channels: channels)
    e.asbd.mFormatFlags |= kAudioFormatFlagIsNonMixable
    return e
}

/// 模拟仅支持 32k/48k/96k、16/20/24bit 的老 DAC（类似 LEN T27q）
private let legacy48: [PhysicalFormatEntry] = {
    var e: [PhysicalFormatEntry] = []
    for rate: Float64 in [32000, 48000, 96000] {
        for bits: UInt32 in [16, 20, 24] {
            e.append(entry(rate: rate, bits: bits))
        }
    }
    return e
}()

// MARK: - 断言工具

private var passCount = 0
private var failCount = 0

private func expect(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond {
        passCount += 1
        print("  ✓ \(name)")
    } else {
        failCount += 1
        print("  ✗ \(name) \(detail())")
    }
}

// MARK: - 用例

public func runSelfTest() {
    print("FormatMatcher 自测")

    // 精确匹配 · 最高位深
    do {
        let m = FormatMatcher.select(targetRate: 192000, targetBits: nil, entries: tp55, policy: .highest)
        expect("192k 精确匹配取最高 32bit", m?.asbd.mSampleRate == 192000 && m?.asbd.mBitsPerChannel == 32)
        expect("192k 标记为精确匹配", m?.exactRate == true)
    }
    do {
        let m = FormatMatcher.select(targetRate: 768000, targetBits: nil, entries: tp55, policy: .highest)
        expect("768k 取 32bit", m?.asbd.mBitsPerChannel == 32 && m?.asbd.mSampleRate == 768000)
    }
    // 位深匹配策略
    do {
        let m = FormatMatcher.select(targetRate: 44100, targetBits: 20, entries: tp55, policy: .match(20))
        expect("源 20bit → ≥20 的最小 24bit", m?.asbd.mBitsPerChannel == 24 && m?.asbd.mSampleRate == 44100)
    }
    do {
        let m = FormatMatcher.select(targetRate: 44100, targetBits: 16, entries: tp55, policy: .match(16))
        expect("源 16bit 精确匹配 16bit", m?.asbd.mBitsPerChannel == 16)
    }
    do {
        let m = FormatMatcher.select(targetRate: 48000, targetBits: nil, entries: legacy48, policy: .fixed(32))
        expect("强制 32bit 但设备最高 24 → 回退 24bit", m?.asbd.mBitsPerChannel == 24)
    }
    do {
        // 源 32bit（如 DSD 转 PCM 高位深），老 DAC 最高 24 → 向下降级
        let m = FormatMatcher.select(targetRate: 48000, targetBits: 32, entries: legacy48, policy: .match(32))
        expect("源 32bit 设备最高 24 → 取 24bit", m?.asbd.mBitsPerChannel == 24)
    }
    // 采样率降级
    do {
        let m = FormatMatcher.select(targetRate: 44100, targetBits: nil, entries: legacy48, policy: .highest)
        expect("44.1k 在仅 48 系设备上 → 就近 48k", m?.asbd.mSampleRate == 48000 && m?.exactRate == false)
    }
    do {
        let device = [entry(rate: 48000, bits: 24), entry(rate: 88200, bits: 24)]
        let m = FormatMatcher.select(targetRate: 44100, targetBits: nil, entries: device, policy: .highest)
        expect("44.1k 无精确但 88.2k 为整数倍 → 升频 88.2k", m?.asbd.mSampleRate == 88200)
    }
    do {
        // 源 88.2k，设备仅 44.1/48：88.2 = 2×44.1 → 整数倍降频选 44.1（而非就近 48）
        let device = [entry(rate: 44100, bits: 24), entry(rate: 48000, bits: 24)]
        let m = FormatMatcher.select(targetRate: 88200, targetBits: nil, entries: device, policy: .highest)
        expect("88.2k → 整数分频 44.1k 优先于就近 48k", m?.asbd.mSampleRate == 44100)
    }
    do {
        let device = [entry(rate: 48000, bits: 24), entry(rate: 96000, bits: 24)]
        let m = FormatMatcher.select(targetRate: 50000, targetBits: nil, entries: device, policy: .highest)
        expect("50k 无整数关系 → 就近 48k", m?.asbd.mSampleRate == 48000)
    }
    // 浮点设备（内置扬声器类）
    do {
        let builtin = [entry(rate: 44100, bits: 32, isFloat: true),
                       entry(rate: 48000, bits: 32, isFloat: true)]
        let m = FormatMatcher.select(targetRate: 44100, targetBits: 16, entries: builtin, policy: .match(16))
        expect("浮点设备回退 32bit float", m?.asbd.mSampleRate == 44100
            && m?.asbd.mBitsPerChannel == 32
            && m!.asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }
    // 声道
    do {
        var device = tp55
        device.append(entry(rate: 96000, bits: 24, channels: 8))
        let m = FormatMatcher.select(targetRate: 96000, targetBits: nil, preferredChannels: 2,
                                     entries: device, policy: .highest)
        expect("存在多声道条目时仍选 2ch", m?.asbd.mChannelsPerFrame == 2)
    }
    // 整数倍判断
    expect("88200 是 44100 的整数倍", FormatMatcher.isIntegerMultiple(88200, of: 44100))
    expect("48000 不是 44100 的整数倍", !FormatMatcher.isIntegerMultiple(48000, of: 44100))
    expect("44100 不是 88200 的整数倍（小数为大）", !FormatMatcher.isIntegerMultiple(44100, of: 88200))

    // 连续采样率设备
    do {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = 48000
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        asbd.mChannelsPerFrame = 2
        asbd.mBitsPerChannel = 32
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerFrame = 8
        asbd.mBytesPerPacket = 8
        let continuous = [PhysicalFormatEntry(AudioStreamRangedDescription(
            mFormat: asbd,
            mSampleRateRange: AudioValueRange(mMinimum: 8000, mMaximum: 768000)))]
        var allOK = true
        for rate: Float64 in [44100, 44300, 192000, 705600] {
            let m = FormatMatcher.select(targetRate: rate, targetBits: nil, entries: continuous, policy: .highest)
            if m?.asbd.mSampleRate != rate { allOK = false }
        }
        expect("连续采样率设备支持任意率（含 44.3k 等非标率）", allOK)
    }

    // 空能力
    expect("空能力列表返回 nil", FormatMatcher.select(targetRate: 44100, targetBits: nil, entries: [], policy: .highest) == nil)

    // 重复上报的伪格式：交错（0x20）与 NonMixable（0x40）都不能写入
    do {
        var dev = tp55
        for rate: Float64 in [44100, 96000, 192000, 768000] {
            dev.append(niEntry(rate: rate, bits: 32))
            dev.append(niEntry(rate: rate, bits: 24))
            dev.append(nmEntry(rate: rate, bits: 32))
            dev.append(nmEntry(rate: rate, bits: 24))
        }
        let m = FormatMatcher.select(targetRate: 192000, targetBits: nil, entries: dev, policy: .highest)
        expect("重复上报时选可混音格式（不选 NonMixable）",
               m != nil && m!.asbd.mFormatFlags & kAudioFormatFlagIsNonMixable == 0)
        expect("同时不选非交错格式",
               m != nil && m!.asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
        expect("选中格式 flags 为 0xc（与音频 MIDI 设置一致）",
               m != nil && m!.asbd.mFormatFlags == kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        expect("选中格式位深仍为 32bit", m?.asbd.mBitsPerChannel == 32)
        expect("交错格式字节数正确（2ch×32bit=8）",
               m?.asbd.mBytesPerFrame == 8 && m?.asbd.mBytesPerPacket == 8)
        // 位深匹配策略也不能落到其他条目
        let m24 = FormatMatcher.select(targetRate: 96000, targetBits: 24, entries: dev, policy: .match(24))
        expect("位深匹配 24bit 时同样选可混音交错",
               m24 != nil && m24!.asbd.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsNonMixable) == 0)
        // 设备只上报伪格式：仍必须清洗成普通交错（清标志、修字节数）
        let onlyBad = [nmEntry(rate: 44100, bits: 32), niEntry(rate: 44100, bits: 24)]
        let m2 = FormatMatcher.select(targetRate: 44100, targetBits: nil, entries: onlyBad, policy: .highest)
        expect("仅上报伪格式：写入前清除非交错/NonMixable 标志",
               m2 != nil && m2!.asbd.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsNonMixable) == 0)
        expect("仅上报伪格式：字节数修正为交错口径", m2?.asbd.mBytesPerFrame == 8)
        // sameFormat 必须能区分这些标志（否则写入失败的校验会漏判）
        let a = entry(rate: 44100, bits: 24).asbd
        var b = a
        b.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        expect("sameFormat 区分交错与非交错", !sameFormat(a, b))
        var c = a
        c.mFormatFlags |= kAudioFormatFlagIsNonMixable
        expect("sameFormat 区分可混音与 NonMixable（0xc vs 0x4c 不能视为相同）", !sameFormat(a, c))
        expect("sameFormat 同类格式仍相等", sameFormat(a, entry(rate: 44100, bits: 24).asbd))
    }

    // 源探测：文件头解析
    do {
        let tmp = FileManager.default.temporaryDirectory
        // 构造 44 字节 WAV 头（48k/16bit/2ch）
        var wav = Data()
        func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func le32(_ v: UInt32) -> Data { le16(UInt16(v & 0xFFFF)) + le16(UInt16(v >> 16)) }
        wav.append(Data("RIFF".utf8)); wav.append(le32(36)); wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8)); wav.append(le32(16))
        wav.append(le16(1)); wav.append(le16(2)); wav.append(le32(48000))
        wav.append(le32(48000 * 4)); wav.append(le16(4)); wav.append(le16(16))
        wav.append(Data("data".utf8)); wav.append(le32(0))
        let wavURL = tmp.appendingPathComponent("mds-selftest.wav")
        try? wav.write(to: wavURL)
        let p1 = SourceProbe.parseHeader(wavURL.path)
        expect("WAV 头解析 48k/16bit/2ch", p1?.sampleRate == 48000 && p1?.bitsPerSample == 16 && p1?.channels == 2)

        // 构造 FLAC STREAMINFO（96k/24bit/2ch）
        var flac = Data("fLaC".utf8)
        flac.append(0x00)                       // 非最后块 | type 0 = STREAMINFO
        flac.append(contentsOf: [0, 0, 34])     // 块长 34
        flac.append(contentsOf: [UInt8](repeating: 0, count: 10)) // min/max blocksize/framesize
        var v: UInt64 = (UInt64(96000) << 44) | (1 << 41) | (23 << 36) // rate=96000 ch=2 bits=24
        var field = Data()
        for shift in stride(from: 56, through: 0, by: -8) { field.append(UInt8((v >> UInt64(shift)) & 0xFF)) }
        flac.append(field)
        flac.append(contentsOf: [UInt8](repeating: 0, count: 16)) // md5 占位
        let flacURL = tmp.appendingPathComponent("mds-selftest.flac")
        try? flac.write(to: flacURL)
        let p2 = SourceProbe.parseHeader(flacURL.path)
        expect("FLAC 头解析 96k/24bit/2ch", p2?.sampleRate == 96000 && p2?.bitsPerSample == 24 && p2?.channels == 2)

        // 网易云 .uc! 加密缓存：整体 XOR 0xA3（96k/24bit FLAC，实测格式）
        let uc = Data(flac.map { $0 ^ SourceProbe.neteaseUCKey })
        let ucURL = tmp.appendingPathComponent("mds-selftest.uc!")
        try? uc.write(to: ucURL)
        let p3 = SourceProbe.parseHeader(ucURL.path)
        expect(".uc! 解密后解析 FLAC 96k/24bit/2ch",
               p3?.sampleRate == 96000 && p3?.bitsPerSample == 24 && p3?.channels == 2)
        expect(".uc! 标注来源为网易云", p3?.kind.contains("网易云") == true)

        // 网易云 .uc! 内的 M4A/AAC（moov 在文件头）：取音频轨 mdhd timescale
        func mp4Box(_ type: String, _ payload: Data) -> Data {
            var box = Data()
            var len = UInt32(payload.count + 8)
            box.append(contentsOf: [UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF),
                                    UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
            box.append(Data(type.utf8))
            box.append(payload)
            return box
        }
        var mdhd = Data([0, 0, 0, 0])           // version 0 + flags
        mdhd.append(contentsOf: [0, 0, 0, 0])   // creation
        mdhd.append(contentsOf: [0, 0, 0, 0])   // modification
        var ts: UInt32 = 44100
        mdhd.append(contentsOf: [UInt8((ts >> 24) & 0xFF), UInt8((ts >> 16) & 0xFF),
                                 UInt8((ts >> 8) & 0xFF), UInt8(ts & 0xFF)])
        mdhd.append(contentsOf: [0, 0, 0, 0])   // duration
        var hdlr = Data([0, 0, 0, 0])           // version + flags
        hdlr.append(contentsOf: [0, 0, 0, 0])   // pre_defined
        hdlr.append(Data("soun".utf8))
        let mdia = mp4Box("mdia", mp4Box("mdhd", mdhd) + mp4Box("hdlr", hdlr))
        let m4a = mp4Box("ftyp", Data("M4A ".utf8) + Data([0, 0, 0, 0]))
            + mp4Box("moov", mp4Box("trak", mdia))
        let ucM4aURL = tmp.appendingPathComponent("mds-selftest-m4a.uc!")
        try? Data(m4a.map { $0 ^ SourceProbe.neteaseUCKey }).write(to: ucM4aURL)
        let p4 = SourceProbe.parseHeader(ucM4aURL.path)
        expect(".uc! 内 M4A 解析音频轨 44.1k",
               p4?.sampleRate == 44100 && p4?.kind.contains("M4A") == true)
        expect(".uc! 内 M4A 位深为 nil（有损不参与位深匹配）", p4?.bitsPerSample == nil)

        // M4A 明文（非加密）同样可解析
        let m4aURL = tmp.appendingPathComponent("mds-selftest.m4a")
        try? m4a.write(to: m4aURL)
        let p5 = SourceProbe.parseHeader(m4aURL.path)
        expect("明文 M4A 解析 44.1k", p5?.sampleRate == 44100)
    }

    // 源探测：正在播放文件识别（offset 前进检测）
    do {
        func f(_ path: String, _ rate: Float64, _ offset: UInt64?) -> SourceProbe.Probe {
            SourceProbe.Probe(path: path, sampleRate: rate, bitsPerSample: 16,
                              channels: 2, kind: "FLAC", pid: 1, offset: offset)
        }
        // 场景：播放 44.1k 文件（offset 前进），残留 192k 句柄停滞 → 必须选 44.1k
        let a = [f("/m/hi.flac", 192000, 548_680), f("/m/cur.flac", 44100, 16_384)]
        let b = [f("/m/hi.flac", 192000, 548_680), f("/m/cur.flac", 44100, 98_304)]
        let picked = SourceProbe.pickPlaying(a: a, b: b)
        expect("前进的 44.1k 文件胜过停滞的 192k 残留", picked?.path == "/m/cur.flac")
        // 多个前进：读取量最大者优先
        let c = [f("/m/x.flac", 96000, 100), f("/m/y.flac", 48000, 100)]
        let d = [f("/m/x.flac", 96000, 300), f("/m/y.flac", 48000, 90_000)]
        expect("多个前进时选前进量最大者", SourceProbe.pickPlaying(a: c, b: d)?.path == "/m/y.flac")
        // 全部停滞 → nil（残留不可信）
        let e = [f("/m/hi.flac", 192000, 548_680)]
        expect("全部停滞返回 nil（不误信残留）", SourceProbe.pickPlaying(a: e, b: e) == nil)
        // 完全无 offset 信息 → 回退采样率最高
        let g = [f("/m/a.flac", 44100, nil), f("/m/b.flac", 96000, nil)]
        expect("无 offset 信息回退采样率最高", SourceProbe.pickPlaying(a: [], b: g)?.path == "/m/b.flac")
        // offset 解析
        expect("lsof offset \"0t548680\" 解析", SourceProbe.parseOffset("0t548680") == 548_680)
        expect("lsof offset \"548680\" 解析", SourceProbe.parseOffset("548680") == 548_680)
        expect("lsof offset \"0x10\" 拒绝", SourceProbe.parseOffset("0x10") == nil)
        // lsof 输出解析：跳过写句柄（边下边播），保留读/读写句柄
        let lsofText = """
        p123
        f91
        ar
        o0t1000
        n/a/play.uc!
        f100
        aw
        o0t5000000
        n/a/download.uc!
        f101
        au
        o0t2000
        n/a/other.flac
        """
        let files = SourceProbe.parseLsofOutput(lsofText)
        expect("lsof 解析跳过只写句柄（下载）",
               files.count == 2 && !files.contains { $0.path == "/a/download.uc!" })
        expect("lsof 解析保留读写句柄", files.contains { $0.path == "/a/other.flac" })
        // 空集
        expect("空扫描返回 nil", SourceProbe.pickPlaying(a: [], b: []) == nil)
    }

    // 设备写入保护：稳定期 + 写后掉线熔断
    do {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var g = DeviceWriteGuard(settleSeconds: 8, faultWindow: 20, faultThreshold: 2, now: t0)
        expect("刚绑定：稳定期内不允许写设备", !g.canWrite(at: t0 + 1))
        expect("刚绑定：稳定期结束前仍不允许写", !g.canWrite(at: t0 + 7.9))
        expect("稳定期结束后允许写设备", g.canWrite(at: t0 + 8))

        // 场景1：写入后 5 秒设备消失 → 第 1 次故障，尚未熔断
        g.noteWrite(at: t0 + 10)
        let entered1 = g.noteVanished(at: t0 + 15)
        expect("写入后 5s 掉线记为故障", g.faults == 1)
        expect("首次故障不进入稳定模式", !entered1 && !g.passive && g.canWrite(at: t0 + 16))

        // 场景2：再次写入后 3 秒设备消失 → 达到阈值，进入稳定模式
        g.noteWrite(at: t0 + 20)
        let entered2 = g.noteVanished(at: t0 + 23)
        expect("第二次切换后掉线进入稳定模式", entered2 && g.passive)
        expect("稳定模式禁止写设备", !g.canWrite(at: t0 + 100))

        // 场景3：设备多次消失不重复归咎（一次写入只记一次）
        let before = g.faults
        _ = g.noteVanished(at: t0 + 24)
        expect("同一次写入只归咎一次", g.faults == before)

        // 场景4：用户解除 → 清空故障并重新进入稳定期
        g.reset(at: t0 + 30)
        expect("解除稳定模式后恢复写权限（稳定期后）", !g.passive && g.canWrite(at: t0 + 38))
        expect("解除后稳定期内仍不可写", !g.canWrite(at: t0 + 35))
        expect("解除后故障计数清零", g.faults == 0)

        // 场景5：写入后很久才消失（超出熔断窗口）→ 不归咎
        var g2 = DeviceWriteGuard(settleSeconds: 8, faultWindow: 20, faultThreshold: 2, now: t0)
        g2.noteWrite(at: t0 + 10)
        _ = g2.noteVanished(at: t0 + 31) // 21s 后，超窗口
        expect("超出熔断窗口的掉线不归咎于切换", g2.faults == 0 && !g2.passive)

        // 场景6：从未写入过就消失（USB 自身接触不良）→ 不归咎
        var g3 = DeviceWriteGuard(settleSeconds: 8, faultWindow: 20, faultThreshold: 2, now: t0)
        _ = g3.noteVanished(at: t0 + 12)
        expect("未写入格式时掉线不归咎（硬件自身问题）", g3.faults == 0 && !g3.passive)

        // 场景7：默认阈值下需连续两次才熔断
        var g4 = DeviceWriteGuard(now: t0)
        g4.noteWrite(at: t0 + 10)
        _ = g4.noteVanished(at: t0 + 12)
        g4.noteWrite(at: t0 + 20)
        _ = g4.noteVanished(at: t0 + 22)
        expect("默认阈值：连续两次切换后掉线才熔断", g4.passive)
    }

    print()
    print("结果: \(passCount) 通过, \(failCount) 失败")
    if failCount > 0 { exit(1) }
}
