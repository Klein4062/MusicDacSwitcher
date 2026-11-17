// PlayTest.swift — 定向静音播放测试器
//
// 向指定设备发起真实 IO（HALOutput 输出静音，听不到声音），
// 同时以播放速率持续读取一个音频文件（句柄保持打开、读取偏移
// 持续前进），完整模拟「播放器播放本地文件」的行为，用于端到端
// 验证源探测自动切换：
//
//   mds playtest /tmp/test44k16.wav --device TP55 --seconds 15

import Foundation
import CoreAudio
import AudioUnit
import MDSKit

/// 渲染静音（目的在于产生真实设备 IO，不在于发声）
private func silentRenderProc(_ inRefCon: UnsafeMutableRawPointer,
                              _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
                              _ inBusNumber: UInt32,
                              _ inNumberFrames: UInt32,
                              ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let ioData else { return noErr }
    let list = UnsafeMutableAudioBufferListPointer(ioData)
    for b in list {
        if let data = b.mData, b.mDataByteSize > 0 {
            memset(data, 0, Int(b.mDataByteSize))
        }
    }
    return noErr
}

func cmdPlayTest(_ args: [String]) {
    let p = parseArgs(args)
    guard let path = p.positional.first else {
        print("用法: mds playtest <音频文件> [--device <uid|名称>] [--seconds N]")
        exit(2)
    }
    let seconds = p.options["seconds"].flatMap(Double.init) ?? 10
    let query = p.options["device"] ?? "TP55"
    guard FileManager.default.fileExists(atPath: path) else {
        print("文件不存在: \(path)")
        exit(2)
    }
    guard let devID = AudioDevice.findDevice(matching: query) else {
        print("设备未找到: \(query)")
        exit(2)
    }
    guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
        print("无法打开文件: \(path)")
        exit(2)
    }

    // 绑定设备的 HALOutput，静音渲染
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else {
        print("无 HALOutput 组件")
        exit(2)
    }
    var unit: AudioUnit?
    guard AudioComponentInstanceNew(comp, &unit) == noErr, let unit else {
        print("创建 AudioUnit 失败")
        exit(2)
    }
    var dev = devID
    var st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global, 0, &dev,
                                  UInt32(MemoryLayout<AudioDeviceID>.size))
    guard st == noErr else {
        print("绑定设备失败: \(st)")
        exit(2)
    }
    var cb = AURenderCallbackStruct(inputProc: silentRenderProc, inputProcRefCon: nil)
    st = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                              kAudioUnitScope_Input, 0, &cb,
                              UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    guard st == noErr, AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr else {
        print("启动播放失败: \(st)")
        exit(2)
    }
    let devName = AudioDevice.snapshot(deviceID: devID).name
    print("▶ 静音播放 → \(devName) · \(path) · \(Int(seconds))s（设备有真实 IO，文件持续读取）")

    // 以 ~1MB/s 持续读取文件推进偏移（模拟流式播放）；读到结尾则从头继续
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
        let d = (try? fh.read(upToCount: 200 * 1024)).flatMap { $0 } ?? Data()
        if d.isEmpty { try? fh.seek(toOffset: 0) }
    }

    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
    try? fh.close()
    print("■ 播放结束")
}
