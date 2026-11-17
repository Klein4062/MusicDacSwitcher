# MusicDacSwitcher (mds)

macOS 上的音频播放格式自动切换工具：播放音乐时，自动把输出设备（DAC）在「音频 MIDI 设置」中的输出格式——**声道 / 位深 / 采样率**——切换为匹配音源的最佳格式，例如 `2声道 24位整数 192.0kHz`、`2声道 32位整数 768.0kHz`。

全部能力**动态读取自设备实际支持的格式列表**（不同采样率下支持的位深不同），不做任何硬编码；无法精确匹配时自动降级到最合适的格式。

提供两种使用形态：

- **菜单栏 App（推荐）**——常驻状态栏的图形界面：当前格式一目了然、点按切换、自动切换开关、活动日志
- **命令行 `mds`**——相同核心，适合脚本 / LaunchAgent

## 菜单栏 App

```bash
./scripts/make-app.sh --install   # 构建并安装到 /Applications
open /Applications/MusicDacSwitcher.app
```

菜单栏会出现 🌊 波形图标（播放音频时变绿）。点击展开面板：

- **头部**：设备切换菜单、播放状态呼吸灯（播放中绿色脉动）、当前格式大字显示 + 声道/位深徽章（HOG 独占提示）
- **自动切换**：总开关、位深策略（最高 / 16 / 24 / 32 bit）、「立即优化」按钮
- **支持的格式**：设备全部采样率 × 位深矩阵，当前格式高亮，点按任意采样率行即切换
- **活动日志**：实时切换记录
- **底部**：登录时自动启动（LaunchAgent）、退出

纯菜单栏应用（LSUIElement），无 Dock 图标；深浅色模式自动适配。

**单实例保护**：无论从 /Applications、build 目录还是 LaunchAgent 启动，任意时刻只有一个实例（文件锁保证）；重复启动会自动激活现有实例并退出，不会出现两个菜单栏图标。

## 命令行

```bash
mds list                    # 设备与支持的格式矩阵
mds format                  # 当前格式
mds probe                   # 查看探测到的打开音频文件（含读取偏移与残留识别）
mds playtest <文件> [--device <名称>] [--seconds N]
                            # 端到端测试：向设备发起静音播放（真实 IO + 文件持续读取），
                            # 验证自动切换，不影响听感
mds watch                   # 守护模式
mds selftest                # 内置自测（算法 + 文件头解析 + 播放识别）
```

## 工作原理

**源探测（核心机制）**：共享输出模式下 macOS 不向第三方暴露正在播放内容的真实格式，且常驻占用（聊天工具、浏览器等）会让系统自动切率永远不触发。mds 的做法：

```
播放器打开本地音频文件 ──► mds 周期扫描系统文件句柄（lsof -o，约 0.2s）
                              │
                              ▼
              解析文件头：FLAC / WAV / AIFF / DSF(DSD)
              → 真实采样率 + 位深 + 声道
                              │
                              ▼
        双快照比对文件读取偏移：正在播放的文件 offset 持续前进，
        播放器残留句柄（播放列表预读/播完未关）offset 停滞
        → 选出「正在播放」的那一首，而不是采样率最高的残留文件
                              │
                              ▼
              播放中只登记目标格式（绝不写设备）
              → 设备连续空闲 ≥4s（暂停/停止）后一次性写入
                精确匹配的采样率 + 位深
```

- `播放 001.flac [FLAC 192kHz/24bit] → 已切换 2声道 24位整数 192.0kHz`——采样率与位深都与音源精确一致
- **稳定期**：设备刚（重新）连接 / 刚成为默认输出的 8 秒内不修改格式，避免 USB 枚举未完成时切格式导致设备掉线
- **掉线熔断**：若写入格式后设备很快从系统消失（判定为切换导致掉线），连续 2 次后进入「稳定模式」，停止自动修改格式以保持设备连接；确认设备稳定后可在面板中「重新启用自动切换」
- **播放中绝不写设备**：播放器在起播时按当时的设备格式建立送数/重采样节奏，播放中途修改物理格式会中断音频；实测修改标称采样率同样会让播放器按旧节奏送数，表现为音频中断或**播放被加速**。因此播放期间只登记目标格式，等设备连续空闲 ≥4 秒（暂停、停止播放，已排除切歌间隙）后再一次性应用——下一次播放即以匹配音源的格式启动
- 播放器常常同时打开多个音频文件句柄（残留），仅凭「采样率最高」会选错歌；mds 通过读取偏移前进量识别真正在播的那首
- 文件头无法解析的格式（m4a/mp3/流媒体等）自动回退到「跟随设备采样率 + 最高整数位深」模式
- 播放器 hog 独占（Audirvana 等位完美模式）时完全不干预，释放后自动善后

**辅助监听**（均为 CoreAudio 官方属性，无需任何系统权限）：
  - 设备标称采样率变化（系统 auto-switch 正常工作的设备上直接跟随）
  - 设备任意 IO 启停 / 物理格式变化 / 默认输出设备变化（自动跟随新设备）
- **两步切换法**：DAC 在不同采样率下支持的位深列表不同，因此先切采样率、等待异步生效、重新枚举该采样率下的位深、再设置最佳位深的完整物理格式。
- **hog 模式保护**：播放器独占设备（Audirvana / Decibel 等位完美播放器的 hog mode）时 mds 完全不干预，播放器释放后自动接手善后。

### 匹配策略

| 维度 | 优先级 |
|------|--------|
| 采样率 | 精确匹配 > 整数倍升频（44.1k → 88.2k）> 整数分频（88.2k → 44.1k）> 就近 |
| 位深 | 指定/匹配值 > ≥ 源位深的最小整数位深 > 该采样率下最高整数位深 > 浮点 |
| 声道 | 源声道 > 2 声道 > 该采样率下支持的最大声道数 |

**位深策略**：源探测命中时精确匹配文件位深（如 24bit 文件 → 24bit 输出）；无法探测源格式时，取该采样率下最高整数位深——32bit 容器传输 16bit 源不损信息（低位补零），DAC 数字滤波器行为也更稳定。可用 `--bits N` 强制。

## 构建与安装

```bash
cd MusicDacSwitcher
swift build -c release
# 可执行文件: .build/release/mds
# 建议软链到 PATH:
ln -sf "$(pwd)/.build/release/mds" /usr/local/bin/mds
```

要求：macOS 12+，Xcode Command Line Tools（无第三方依赖）。

## 使用

### 查看设备能力

```bash
$ mds list
◆ TP55 — EPZ Technology
    uid: AppleUSBAudioEngine:EPZ Technology:TP55:33024383251202:2
    标称采样率: 768.0kHz
    当前格式: 2声道 32位整数 768.0kHz
    支持的物理格式:
      44.1kHz → 16bit int 2ch / 24bit int 2ch / 32bit int 2ch
      48.0kHz → 16bit int 2ch / 24bit int 2ch / 32bit int 2ch
      ...
      768.0kHz → 16bit int 2ch / 24bit int 2ch / 32bit int 2ch
```

`mds list --json` 输出机器可读格式。

### 手动切换

```bash
mds set 44100            # 切到 44.1kHz 下最佳格式（32bit int）
mds set 192k             # 支持写法: 44100 / 44.1k / 96k / 192.0kHz / 768k
mds set 44.1k --bits 16  # 指定位深
mds best 768k            # 只预览决策，不实际切换（加 --apply 生效）
mds set 48000 --device "LEN"   # 按 UID / 名称片段指定设备
```

### 自动切换（核心功能）

```bash
mds watch                          # 跟随系统默认输出设备，播放即自动切换
mds watch -v                       # 详细日志
mds watch --device TP55            # 固定监听某台 DAC
mds watch --restore-rate 44100     # 空闲 4 秒后恢复到 44.1kHz
mds watch --dry-run                # 只打印决策，先观察一阵再实弹
```

播放任意来源（Music.app / 浏览器 / 流媒体 / foobar2000 共享模式）即可看到类似日志：

```
[20:15:02.113] 监听设备：「TP55」 uid=AppleUSBAudioEngine:...
[20:15:02.114]   当前格式：2声道 32位整数 44.1kHz
[20:21:45.882] 播放中源为 96.0kHz，设备当前 44.1kHz：为避免打断播放/变速，暂停或停止播放后自动切换
[20:22:03.120] 已切换 → 2声道 32位整数 96.0kHz （单步直接切换 · 采样率精确 96.0kHz）· 空闲应用（上次播放源 xxx.flac）
```

播放中探测到不匹配时，面板会记录「待切换」；暂停或停止播放（设备连续空闲 4 秒，已排除切歌间隙）后自动应用，下一次播放即以匹配音源的格式开始。

### 为什么切换结果与「音频 MIDI 设置」完全一致

不少 USB DAC（如 TP55）会对**同一个采样率/位深**上报两组只差 `mFormatFlags` 的物理格式：

| flags | 含义 | 可用性 |
|---|---|---|
| `0xc` | 有符号整数 + Packed（可混音） | ✅ 硬件输出流真正使用的格式 |
| `0x4c` | 额外带 `NonMixable`（不可混音/独占） | ❌ 写入后设备进入独占状态 |

`NonMixable` 的坑在于它与可混音格式的采样率、位深、字节数**完全相同**，仅靠这些字段无法区分：一旦写入 `0x4c`，HAL 会把设备当成独占流，客户端可见的虚拟格式从 float（`0x9`）变成整数（`0x4c`），正在播放的播放器数据错位——这就是「切换后 100% 加速/断裂」的根因。

mds 在两层过滤这类格式：选格式时直接排除 `NonMixable` 与非交错（`0x20`）条目；写入前再清一次标志作为兜底。切换后设备稳定态与「音频 MIDI 设置」完全相同：**物理 `0xc`（32bit 整数交错）、虚拟 `0x9`（32bit float）**。

### 开机自启（LaunchAgent）

`~/Library/LaunchAgents/com.musicdacswitcher.watch.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.musicdacswitcher.watch</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/mds</string>
    <string>watch</string>
    <string>--restore-rate</string><string>44100</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/mds.log</string>
  <key>StandardErrorPath</key><string>/tmp/mds.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.musicdacswitcher.watch.plist
tail -f /tmp/mds.log
```

## 验证安装

```bash
mds selftest   # 53 项自测：匹配算法 / 格式标志清洗 / 文件头解析 / 播放识别 / 稳定期与掉线熔断
```

## 已知限制与路线图

- 源探测仅覆盖本地文件播放（FLAC/WAV/AIFF/DSF）；流媒体（Apple Music/QQ 音乐等）拿不到文件，自动回退到跟随设备采样率模式。
- 为保证不打断播放，播放中不做任何格式切换：若起播时设备率与音源不一致，会在暂停/停止播放后自动切换（面板「立即优化」在播放中也只提示不执行）。这是播放器兼容性的硬约束，不是可调项。
- 多台输出设备同时播放不同内容时，文件句柄无法区分归属设备，探测可能跟随另一台设备正在播的文件。
- 独占（hog）播放器自带格式管理，mds 会主动让位。
- 极少数 USB DAC 的驱动不完整上报 AvailablePhysicalFormats，此时以 `mds list` 实际输出为准。
- 路线图：DSD（DoP）识别、多设备同时管理、探测结果的设备归属关联。

## 项目结构

```
Sources/
  MDSKit/                 核心逻辑库（CLI 与 GUI 共用）
    CA.swift              CoreAudio C API 的 Swift 封装（读写/监听）
    AudioDevice.swift     设备/流/格式高层模型
    FormatMatcher.swift   匹配算法（纯函数，自测覆盖）
    FormatController.swift 切换执行（单步优先 + 两步法回退 + 等待异步生效）
    Watcher.swift         属性监听与防抖调度
    Log.swift             日志 sink（CLI→stdout，GUI→界面）
    SelfTest.swift        内置自测
  mds/                    命令行（main / CLI）
  MDSBar/                 菜单栏 App（main / StatusBarController / AppModel / Views）
scripts/
  make-app.sh             构建 .app 并安装
  gen-icon.swift          程序化生成应用图标
```

## 开发说明

- GUI 为无 Xcode 项目构建（Swift Package + AppKit/SwiftUI），规避了 CLT 下 SwiftUI 宏插件缺失的问题（不使用 `@State`，动画用 `TimelineView` 驱动、悬停状态集中于 `AppModel`）。
- 若本机装有已同意许可的完整 Xcode，一切照常；无需修改任何配置。

## License

[MIT](LICENSE)
