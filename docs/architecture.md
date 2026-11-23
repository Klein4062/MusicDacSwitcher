# 架构与数据流

> 面向维护者。使用方法见 [README](../README.md)；CoreAudio 底层细节见 [coreaudio.md](coreaudio.md)。

## 模块职责

```
┌────────────── Sources/MDSKit（CLI 与 GUI 共用核心）──────────────┐
│                                                                  │
│  CA.swift           CoreAudio C API 的薄封装（读写 / 监听）      │
│  AudioDevice.swift  设备 / 流 / 格式的高层模型与查询             │
│  FormatMatcher.swift  匹配决策（纯函数，全部可自测）              │
│  FormatController.swift  切换执行（写入 + 等待生效 + 校验）       │
│  DeviceWriteGuard.swift  稳定期 + 掉线熔断（纯逻辑，可自测）      │
│  SourceProbe.swift   源探测：原生 fd 扫描 + 文件头解析            │
│  HearingGuard.swift  听力保护：音量→声压估算，峰值/平均双口径    │
│  Watcher.swift       调度中枢：监听属性 / 防抖 / 探测定时器       │
│  Log.swift           日志 sink（CLI→stdout，GUI→面板）           │
│  TrackLevel.swift   曲目电平分析（ExtAudioFile 解码实测 RMS/峰值，缓存） │
│  HearingLog.swift   暴露历史落盘（5min 桶 JSONL）+ WHO 周剂量计算      │
│  SelfTest.swift      内置自测（78 项）                           │
└──────────────────────────────────────────────────────────────────┘
        ▲                                        ▲
Sources/mds（CLI 入口）                Sources/MDSBar（菜单栏 GUI）
```

依赖方向：`Watcher → FormatController → FormatMatcher / AudioDevice / CA`；
`SourceProbe` 只被 `Watcher` 调用。决策逻辑（Matcher、WriteGuard、SourceProbe 解析）
全部是纯函数或近纯函数，这是自测能覆盖它们的原因——**新增行为优先落在纯函数层**。

## 自动切换流水线（watch 模式）

```
属性监听（默认设备/标称率/IO 启停/物理格式）─┐
                                            ├─► 防抖 0.35s ─► evaluateNow
源探测定时器（默认 4s，双快照间隔 1.3s）────┘                     │
                                                                 ▼
                       ┌── 设备空闲？──► 空闲 ≥4s 且有 pending → 应用登记目标
                       │
                       └── 播放中 ──► 源探测拿到 (采样率, 位深)
                                        │
                                        ▼
                            formatSatisfied？── 是 → 不动作
                                        │ 否
                                        ▼
                            播放中直接写入（与 AMS 同一条属性）
                                        │
                              成功 ◄────┴──── 失败 → 登记 pending，
                              ↑                        空闲 ≥4s 后重试，
                              │                        同文件 30s 内不重试
                    writeGuard.noteWrite()
                    （熔断计次）
```

## 保护机制与参数

所有时间参数集中在 `DeviceWatcher` 的属性上，改动时同步本表：

| 机制 | 参数 | 默认值 | 目的 |
|---|---|---|---|
| 绑定稳定期 | `settleSeconds` | 8s | USB 枚举未完成时写格式会导致掉线 |
| 起播稳定期 | `playbackSettleSeconds` | 3s | 起播瞬间播放器自己在配设备，让位 |
| 掉线熔断窗口 | `writeFaultWindow` | 20s | 写入后此窗口内设备消失 → 记一次故障 |
| 熔断阈值 | `faultThreshold` | 2 次 | 连续达标进入稳定（只读）模式 |
| 空闲应用延迟 | `idleApplyDelay` | 4s | 排除切歌间隙，避免与下一曲起播抢设备 |
| 探测间隔 | `probeInterval` | 4s | 源扫描周期（CLI `--probe-interval`） |
| 手动切换抑制 | `manualOverrideDeadline` | 60s | 手动点按后不被探测立即覆盖 |
| 写失败退避 | `lastFailedKey` | 30s | 驱动拒绝某格式时不反复暂停 IO |

熔断与稳定期的时间线逻辑在 `DeviceWriteGuard`（纯逻辑、自测覆盖），
`Watcher` 只负责把设备事件喂给它。

## GUI 结构

`MDSBar` 为纯菜单栏应用（LSUIElement）：

- `main.swift`：单实例文件锁 + NSApplication 启动
- `StatusBarController.swift`：状态栏图标、NSPopover 呈现、点击外部关闭
- `AppModel.swift`：`@MainActor` 状态中枢，持有一个 `DeviceWatcher` + `FormatController`
- `Views.swift`：SwiftUI 面板
- 听力保护：2s 刷新时顺带读 `AudioDevice.volumeInfo`，`HearingGuard` 估算声压
  （峰值 = 满幅正弦等效；平均 = 峰值 − 峰值因子，告警按平均口径）；
  超阈值边沿 → 状态栏图标变橙 + 系统通知（持续超阈值 5 分钟内不重复提醒）。
  估算参数（灵敏度/阻抗/满幅电压/阈值/峰值因子/机身衰减）持久化在 UserDefaults（`mds.hearing.*`）；
  满幅电压需跟随 DAC 机身增益档（模拟域切换，macOS 感知不到）；
  机身旋钮不联动系统音量时（读数恒 0dB）衰减同样感知不到，经「机身衰减」参数手动补偿

日志从 MDSKit 经 `LogSink.handler` 回调汇入 `AppModel`，0.5s 批量合并后刷 UI。
