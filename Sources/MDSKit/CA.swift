// CA.swift — CoreAudio 底层属性读写封装（C API 的 Swift 包装）

import CoreAudio
import Foundation

// MARK: - 错误

public struct CAError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let what: String

    public var description: String {
        "CoreAudio 错误 \(fourCC(status)) (code \(status)) @ \(what)"
    }
}

/// 把 OSStatus 转成可读的 FourCC（如 '!obj'）
public func fourCC(_ code: OSStatus) -> String {
    let c = UInt32(bitPattern: code)
    let bytes = [UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
    let s = String(bytes: bytes, encoding: .ascii) ?? "\(c)"
    return s.allSatisfy({ $0.isPrintableASCII }) ? "'\(s)'" : "\(c)"
}

extension Character {
    var isPrintableASCII: Bool { asciiValue.map { $0 > 0x20 && $0 < 0x7F } ?? false }
}

// MARK: - 属性地址

public func caAddress(_ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
               _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

// MARK: - 读取

/// 判断对象是否拥有某属性
public func caHas(_ id: AudioObjectID,
           _ selector: AudioObjectPropertySelector,
           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
           element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
    var addr = caAddress(selector, scope, element)
    return AudioObjectHasProperty(id, &addr)
}

/// 读取单个标量属性（Float64 / UInt32 / Int32 / AudioStreamBasicDescription ...）
public func caGet<T>(_ id: AudioObjectID,
             _ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
             label: String = "") throws -> T {
    var addr = caAddress(selector, scope, element)
    guard AudioObjectHasProperty(id, &addr) else {
        throw CAError(status: kAudioHardwareUnknownPropertyError, what: label.isEmpty ? String(describing: selector) : label)
    }
    var size: UInt32 = 0
    var st = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
    guard st == noErr else { throw CAError(status: st, what: "size \(label.isEmpty ? String(describing: selector) : label)") }
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<T>.size), alignment: MemoryLayout<T>.alignment)
    defer { ptr.deallocate() }
    ptr.initializeMemory(as: UInt8.self, repeating: 0, count: max(Int(size), MemoryLayout<T>.size))
    st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    guard st == noErr else { throw CAError(status: st, what: "get \(label.isEmpty ? String(describing: selector) : label)") }
    return ptr.load(as: T.self)
}

/// 读取数组属性（[AudioObjectID] / [AudioStreamRangedDescription] ...）
public func caGetArray<T>(_ id: AudioObjectID,
                   _ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                   element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                   label: String = "") throws -> [T] {
    var addr = caAddress(selector, scope, element)
    var size: UInt32 = 0
    var st = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
    guard st == noErr else { throw CAError(status: st, what: "size \(label)") }
    let count = Int(size) / MemoryLayout<T>.size
    guard count > 0 else { return [] }
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { ptr.deallocate() }
    st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    guard st == noErr else { throw CAError(status: st, what: "get \(label)") }
    var out = [T]()
    out.reserveCapacity(count)
    for i in 0..<count {
        out.append(ptr.load(fromByteOffset: i * MemoryLayout<T>.size, as: T.self))
    }
    return out
}

/// 读取 CFString 类型属性（设备名 / UID 等）
public func caGetString(_ id: AudioObjectID,
                 _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
    var addr = caAddress(selector, scope)
    guard AudioObjectHasProperty(id, &addr) else {
        throw CAError(status: kAudioHardwareUnknownPropertyError, what: "has \(selLabel(selector))")
    }
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    guard st == noErr else { throw CAError(status: st, what: "get \(selLabel(selector))") }
    return value as String
}

// MARK: - 写入

/// 写入属性
public func caSet<T>(_ id: AudioObjectID,
              _ selector: AudioObjectPropertySelector,
              _ value: T,
              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
              element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
              label: String = "") throws {
    var addr = caAddress(selector, scope, element)
    var v = value
    let size = UInt32(MemoryLayout<T>.size)
    let st = withUnsafePointer(to: &v) { ptr -> OSStatus in
        AudioObjectSetPropertyData(id, &addr, 0, nil, size, ptr)
    }
    guard st == noErr else { throw CAError(status: st, what: "set \(label.isEmpty ? selLabel(selector) : label)") }
}

// MARK: - 调试用：常见 selector 名称

public func selLabel(_ selector: AudioObjectPropertySelector) -> String {
    switch selector {
    case kAudioHardwarePropertyDevices: return "kAudioHardwarePropertyDevices"
    case kAudioHardwarePropertyDefaultOutputDevice: return "kAudioHardwarePropertyDefaultOutputDevice"
    case kAudioDevicePropertyDeviceUID: return "kAudioDevicePropertyDeviceUID"
    case kAudioObjectPropertyName: return "kAudioObjectPropertyName"
    case kAudioDevicePropertyDeviceManufacturerCFString: return "kAudioDevicePropertyDeviceManufacturer"
    case kAudioDevicePropertyStreams: return "kAudioDevicePropertyStreams"
    case kAudioDevicePropertyNominalSampleRate: return "kAudioDevicePropertyNominalSampleRate"
    case kAudioDevicePropertyHogMode: return "kAudioDevicePropertyHogMode"
    case kAudioDevicePropertyDeviceIsRunningSomewhere: return "kAudioDevicePropertyDeviceIsRunningSomewhere"
    case kAudioStreamPropertyPhysicalFormat: return "kAudioStreamPropertyPhysicalFormat"
    case kAudioStreamPropertyAvailablePhysicalFormats: return "kAudioStreamPropertyAvailablePhysicalFormats"
    case kAudioStreamPropertyAvailableVirtualFormats: return "kAudioStreamPropertyAvailableVirtualFormats"
    default: return "selector(\(selector))"
    }
}
