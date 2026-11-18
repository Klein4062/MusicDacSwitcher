# CoreAudio 深水区笔记

> 本项目踩过的坑与结论，全部来自真机验证（设备：EPZ TP55 USB DAC，
> 播放器：索尼精选 Hi-Res / 网易云 / Music.app）。修改切换逻辑前先读本文。

## 关键概念

| 属性 | 作用 |
|---|---|
| `kAudioStreamPropertyPhysicalFormat` | 硬件流真实格式，本项目写入的目标 |
| `kAudioStreamPropertyVirtualFormat` | 客户端可见格式，HAL 自动维护（正常稳定态为 32bit float `0x9`） |
| `kAudioStreamPropertyAvailablePhysicalFormats` | 设备能力列表（注意与当前采样率相关） |
| `kAudioDevicePropertyNominalSampleRate` | 设备标称采样率（Global/Main） |

「音频 MIDI 设置」（AMS）切换格式时写的也是 `PhysicalFormat`——
**与 AMS 写同一条属性、写同样的值，结果就与 AMS 一致**。这是本项目切换正确性的基准。

## 陷阱一：重复上报的伪格式（NonMixable）

不少 USB DAC（如 TP55）对**同一个采样率/位深**上报两组只差 `mFormatFlags` 的格式：

| flags | 含义 | 可用性 |
|---|---|---|
| `0xc` | 有符号整数(0x4) + Packed(0x8)，可混音 | ✅ 硬件输出流真正使用的格式 |
| `0x4c` | 额外带 NonMixable(0x40) | ❌ 写入后设备进入独占状态 |

`NonMixable` 与可混音格式的采样率、位深、字节数**完全相同**，仅靠这些字段无法区分。
写入 `0x4c` 后 HAL 把设备当独占流：虚拟格式从 float（`0x9`）变成整数（`0x4c`），
正在播放的播放器数据错位——表现为**切换后 100% 加速/断裂**。
（另有一组非交错重复条目，flags `0x20`，同样要排除。）

**代码里的两层防御**（改动时不可移除）：

1. `FormatMatcher.preferMixable()`：选格式时排除 NonMixable / 非交错条目
2. `FormatController.apply()`：写入前再清一次这两个标志兜底

`sameFormat()` 必须比较这两个标志，否则写入失败会被误判成功
（曾导致「回读瞬间是 0xc、1 秒后变 0x4c」的假成功）。

## 陷阱二：播放中写格式是安全的——前提是写对格式

实测结论（曾长期误判，务必不要再走回头路）：

- **写正确的可混音格式（`0xc`）**：HAL 走 `HandlePlugIn_RequestConfigChange`
  → `PauseIO` → 调驱动 → `ResumeIO`，播放器无感继续，虚拟格式保持 float。AMS 亦如此。
- **写错的格式（`0x4c`）**：数据错位、加速、断裂——曾经的「播放中 100% 出问题」
  根因全部在此，与「时机」「竞态」无关。
- 播放器（索尼 Hi-Res 实测）起播时按当时设备率建立送数节奏，因此**播放中改采样率**
  对少数播放器仍有风险：写失败时回退「登记 pending、空闲 ≥4s 后应用」，
  不要在播放中反复重试（`lastFailedKey` 30s 退避）。

## 陷阱三：AudioObjectID 是临时的（重枚举后静默失效）

USB 短暂重枚举（端口复位、睡眠唤醒）后 HAL 会给设备分配**新的对象 ID**，uid 不变。
若重枚举落在两次探测（4s）之间，不会留下任何可观测事件：

- 旧 ID 上的属性监听器从此不再回调（事件静默消失）
- 读旧 ID 的属性返回错误 → `isRunningSomewhere` 恒为 false
- 按 uid 查找设备仍然成功 → 「设备存在」检查放行

三者叠加 = Watcher 变成永远「查无播放」的僵尸，日志毫无异常，重启才恢复。
防御：`deviceStillPresent()` 每 4s 比对 `findDevice(uid)` 解析出的 ID 与当前绑定的
`currentDevice`，不一致即重绑（`Watcher.swift`）。症状识别：面板显示正常、
设备在播但无任何切换/事件日志 → 先怀疑僵尸绑定。

## 写入后的校验

`AudioObjectSetPropertyData` 返回 noErr ≠ 生效：

1. `waitForFormat`：轮询回读物理格式（≤800ms），须与目标逐字段一致
2. `verifyNominalRate`：再确认标称采样率真的切过去（部分驱动接受无效格式后异步回滚）

## 切换策略：单步优先，两步回退

- **单步直接切换**：设备能力列表通常覆盖全部采样率，直接选出目标采样率下的
  完整格式一次写入。两次 USB 重新协商对脆弱设备是额外风险，能一步到位就不走两步。
- **两步法回退**：先以当前位深为模板切采样率 → 重新枚举（不同采样率支持的位深不同）
  → 再设最佳位深。单步未生效或目标采样率不在当前能力列表时使用。

## 其他要点

- **hog 独占**（Audirvana 等位完美播放器）：`kAudioDevicePropertyHogMode` ≠ -1 时
  完全不干预，播放器自行管理格式，释放后自动善后。
- Chromium 系播放器（网易云、浏览器）打开设备用**当前采样率 + 内部重采样**，
  从不向 HAL 请求音源采样率——系统自动切率永远不触发，只能靠源探测（见
  [source-probe.md](source-probe.md)）。
- 原生播放器（Music.app 等）会按内容请求采样率，设备标称率变化监听即可跟随，
  此时只优化位深。
- 诊断工具：`mds probe`（探测视角）、`mds list`（能力矩阵）、
  `mds playtest <文件>`（端到端静音播放验证）；
  HAL 内部行为用 `log show --predicate 'process == "coreaudiod"' --info --debug`。
