// AudioDevice.swift — 输出设备 / 流 / 格式的高层封装

import CoreAudio
import Foundation

// MARK: - 数据模型

/// 一条设备支持的物理格式（来自 AvailablePhysicalFormats，含采样率范围）
public struct PhysicalFormatEntry {
    public var asbd: AudioStreamBasicDescription
    public var rateMin: Float64
    public var rateMax: Float64

    init(_ r: AudioStreamRangedDescription) {
        asbd = r.mFormat
        rateMin = r.mSampleRateRange.mMinimum
        rateMax = r.mSampleRateRange.mMaximum
    }

    public var bits: Int { Int(asbd.mBitsPerChannel) }
    public var channels: Int { Int(asbd.mChannelsPerFrame) }
    public var isFloat: Bool { asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 }
    public var isSignedInteger: Bool {
        !isFloat && asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
    }
    public var isPacked: Bool {
        asbd.mFormatFlags & kAudioFormatFlagIsPacked != 0
            || asbd.mBytesPerFrame == asbd.mChannelsPerFrame * asbd.mBitsPerChannel / 8
    }
    public func coversRate(_ r: Float64) -> Bool { rateMin <= r && r <= rateMax }
}

/// 设备当前状态的完整快照
public struct DeviceSnapshot {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var manufacturer: String
    public var isDefaultOutput: Bool
    public var nominalRate: Float64?
    public var hogPID: Int32?
    public var runningSomewhere: Bool
    public var streams: [StreamSnapshot]

    public struct StreamSnapshot {
        public var id: AudioObjectID
        public var physical: AudioStreamBasicDescription?
        public var available: [PhysicalFormatEntry]
        public var virtualRanges: [(min: Float64, max: Float64)]

        init(deviceID: AudioObjectID, streamID: AudioObjectID) {
            id = streamID
            physical = AudioDevice.streamPhysicalFormat(streamID)
            available = AudioDevice.streamAvailablePhysicalFormats(streamID)
            virtualRanges = AudioDevice.streamAvailableVirtualRanges(streamID)
        }
    }
}

// MARK: - 设备操作

public enum AudioDevice {
    // ---- 系统 ----

    /// 系统默认输出设备
    public static func defaultOutputDeviceID() -> AudioObjectID? {
        let id: AudioObjectID? = try? caGet(AudioObjectID(kAudioObjectSystemObject),
                                            kAudioHardwarePropertyDefaultOutputDevice,
                                            label: "default-output")
        return id
    }

    /// 所有音频设备
    public static func allDeviceIDs() -> [AudioObjectID] {
        (try? caGetArray(AudioObjectID(kAudioObjectSystemObject),
                         kAudioHardwarePropertyDevices,
                         label: "devices")) ?? []
    }

    // ---- 设备属性 ----

    public static func uid(_ id: AudioObjectID) -> String? {
        try? caGetString(id, kAudioDevicePropertyDeviceUID)
    }

    public static func name(_ id: AudioObjectID) -> String? {
        try? caGetString(id, kAudioObjectPropertyName)
    }

    public static func manufacturer(_ id: AudioObjectID) -> String? {
        try? caGetString(id, kAudioDevicePropertyDeviceManufacturerCFString)
    }

    /// 设备是否有输出流
    public static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var addr = caAddress(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// 所有具有输出的设备快照
    public static func outputDeviceSnapshots() -> [DeviceSnapshot] {
        let defID = defaultOutputDeviceID()
        return allDeviceIDs()
            .filter { hasOutputStreams($0) }
            .map { snapshot(deviceID: $0, defaultID: defID) }
    }

    public static func snapshot(deviceID: AudioObjectID, defaultID: AudioObjectID? = nil) -> DeviceSnapshot {
        let streams = outputStreams(deviceID).map { sid in
            DeviceSnapshot.StreamSnapshot(deviceID: deviceID, streamID: sid)
        }
        return DeviceSnapshot(
            id: deviceID,
            uid: uid(deviceID) ?? "uid-\(deviceID)",
            name: name(deviceID) ?? "device-\(deviceID)",
            manufacturer: manufacturer(deviceID) ?? "",
            isDefaultOutput: deviceID == (defaultID ?? defaultOutputDeviceID()),
            nominalRate: nominalRate(deviceID),
            hogPID: hogPID(deviceID),
            runningSomewhere: isRunningSomewhere(deviceID),
            streams: streams
        )
    }

    // ---- 查找设备（UID / UID 前缀 / 名称包含，不区分大小写）----

    public static func findDevice(matching query: String?) -> AudioObjectID? {
        guard let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty else {
            return defaultOutputDeviceID()
        }
        let devices = allDeviceIDs().filter { hasOutputStreams($0) }
        if let exact = devices.first(where: { uid($0) == q }) { return exact }
        if let prefix = devices.first(where: { (uid($0) ?? "").hasPrefix(q) }) { return prefix }
        if let contains = devices.first(where: { (uid($0) ?? "").localizedCaseInsensitiveContains(q) }) { return contains }
        if let byName = devices.first(where: { (name($0) ?? "").localizedCaseInsensitiveContains(q) }) { return byName }
        return nil
    }

    // ---- 流 ----

    /// 设备（输出方向）的流 ID 列表
    public static func outputStreams(_ deviceID: AudioObjectID) -> [AudioObjectID] {
        (try? caGetArray(deviceID, kAudioDevicePropertyStreams,
                         scope: kAudioObjectPropertyScopeOutput,
                         label: "streams")) ?? []
    }

    /// 流当前物理格式
    public static func streamPhysicalFormat(_ streamID: AudioObjectID) -> AudioStreamBasicDescription? {
        try? caGet(streamID, kAudioStreamPropertyPhysicalFormat, label: "physical-format")
    }

    /// 流支持的物理格式（注意：该列表与「当前采样率」相关，切换采样率后需重新枚举）
    public static func streamAvailablePhysicalFormats(_ streamID: AudioObjectID) -> [PhysicalFormatEntry] {
        let raw: [AudioStreamRangedDescription] = (try? caGetArray(
            streamID, kAudioStreamPropertyAvailablePhysicalFormats,
            label: "available-physical")) ?? []
        return raw.map(PhysicalFormatEntry.init)
    }

    /// 流支持的虚拟格式采样率范围（用于判断设备支持哪些采样率）
    public static func streamAvailableVirtualRanges(_ streamID: AudioObjectID) -> [(min: Float64, max: Float64)] {
        let raw: [AudioStreamRangedDescription] = (try? caGetArray(
            streamID, kAudioStreamPropertyAvailableVirtualFormats,
            label: "available-virtual")) ?? []
        return raw.map { ($0.mSampleRateRange.mMinimum, $0.mSampleRateRange.mMaximum) }
    }

    /// 设备当前标称采样率
    public static func nominalRate(_ deviceID: AudioObjectID) -> Float64? {
        try? caGet(deviceID, kAudioDevicePropertyNominalSampleRate, label: "nominal-rate")
    }

    /// 设置设备标称采样率
    public static func setNominalRate(_ deviceID: AudioObjectID, _ rate: Float64) throws {
        try caSet(deviceID, kAudioDevicePropertyNominalSampleRate, rate, label: "set-nominal-rate")
    }

    /// hog 模式占用进程 PID；-1 表示无占用（先查 output scope，再回退 global）
    public static func hogPID(_ deviceID: AudioObjectID) -> Int32? {
        if let v: Int32 = try? caGet(deviceID, kAudioDevicePropertyHogMode,
                                     scope: kAudioObjectPropertyScopeOutput,
                                     label: "hog-mode") {
            return v
        }
        return try? caGet(deviceID, kAudioDevicePropertyHogMode, label: "hog-mode")
    }

    /// 设备是否正被任意进程使用（正在播放）
    public static func isRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        let v: UInt32? = try? caGet(deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere, label: "running-somewhere")
        return v == 1
    }

    // ---- 设置 ----

    /// 设置流的物理格式
    public static func setStreamPhysicalFormat(_ streamID: AudioObjectID, _ asbd: AudioStreamBasicDescription) throws {
        try caSet(streamID, kAudioStreamPropertyPhysicalFormat, asbd, label: "set-physical-format")
    }
}

// MARK: - 格式描述工具

/// 比较两个物理格式在"听感/时钟"意义上是否等价（采样率/位深/声道/整数性）
public func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
    a.mSampleRate == b.mSampleRate
        && a.mBitsPerChannel == b.mBitsPerChannel
        && a.mChannelsPerFrame == b.mChannelsPerFrame
        && a.mBytesPerFrame == b.mBytesPerFrame
        && (a.mFormatFlags & kAudioFormatFlagIsFloat != 0) == (b.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        && (a.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0) == (b.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
}

/// 采样率显示，如 192.0kHz / 44.1kHz / 768.0kHz
public func hz(_ r: Float64) -> String {
    let kHz = r / 1000.0
    if kHz.truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%.1fkHz", kHz)
    }
    return String(format: "%.4gkHz", kHz)
}

/// 格式描述，如 "2声道 24位整数 192.0kHz"
public func describe(_ f: AudioStreamBasicDescription) -> String {
    let kind: String
    if f.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
        kind = "浮点"
    } else if f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
        kind = "整数"
    } else {
        kind = "无符号整数"
    }
    return "\(f.mChannelsPerFrame)声道 \(f.mBitsPerChannel)位\(kind) \(hz(f.mSampleRate))"
}

public extension AudioStreamRangedDescription {
    /// 用现有描述构造一个具体采样率的副本
    public func at(rate: Float64) -> AudioStreamBasicDescription {
        var f = mFormat
        f.mSampleRate = rate
        return f
    }
}
