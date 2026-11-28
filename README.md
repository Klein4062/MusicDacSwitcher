# MusicDacSwitcher (mds)

macOS 上的音频播放格式自动切换工具：播放音乐时，自动把输出设备（DAC）在「音频 MIDI 设置」中的输出格式——**声道 / 位深 / 采样率**——切换为匹配音源的最佳格式，例如 `2声道 24位整数 192.0kHz`、`2声道 32位整数 768.0kHz`。

全部能力**动态读取自设备实际支持的格式列表**（不同采样率下支持的位深不同），不做任何硬编码；无法精确匹配时自动降级到最合适的格式。

提供两种使用形态：

- **菜单栏 App（推荐）**——常驻状态栏的图形界面：当前格式一目了然、点按切换、自动切换开关、活动日志
- **命令行 `mds`**——相同核心，适合脚本 / LaunchAgent

## 快速开始

```bash
git clone https://github.com/Klein4062/MusicDacSwitcher.git
cd MusicDacSwitcher

# 方式一：菜单栏 App
./scripts/make-app.sh --install   # 构建并安装到 /Applications
open /Applications/MusicDacSwitcher.app

# 方式二：命令行
swift build -c release
ln -sf "$(pwd)/.build/release/mds" /usr/local/bin/mds
```

要求：macOS 12+，Xcode Command Line Tools（无第三方依赖）。

## 播放器支持情况

| 播放源 | 自动切换 | 说明 |
|---|---|---|
| 本地文件（FLAC/WAV/AIFF/DSF/M4A） | ✅ 精确匹配采样率 + 位深 | Music.app、foobar2000 共享模式、索尼精选等 |
| 网易云音乐（含 Hi-Res） | ✅ 精确匹配 | 经 `.uc!` 缓存元数据探测（仅读采样率/位深，不解密音频） |
| QQ 音乐 | ➖ 跟随设备采样率 | `.mflac` 为逐文件密钥加密，本项目不实现解密；可在面板手动切采样率 |
| Apple Music 等流媒体 | ➖ 跟随设备采样率 | 无本地文件句柄可探测 |
| hog 独占播放器（Audirvana 等） | ⏸ 不干预 | 播放器自管格式，释放后自动善后 |

## 菜单栏 App

菜单栏出现 🌊 波形图标（播放音频时变绿），点击展开面板：

- **头部**：设备切换菜单、播放状态呼吸灯、当前格式大字显示 + 声道/位深/音量徽章（HOG 独占提示）
- **自动切换**：总开关、位深策略（最高 / 16 / 24 / 32 bit）、「立即优化」按钮
- **听力保护**：读取 DAC 硬件音量（dB），按耳机灵敏度/阻抗**估算**声压级——峰值（满幅正弦等效上限）与平均（≈LAeq，告警口径，优先按**实测曲目电平**折算——源探测到播放文件后解码分析，古典与响度战争流行差 10dB+，实测替代静态峰值因子假设；不可测回退参数）双口径显示，平均超阈值（默认 85 dB）时状态栏图标变橙 + 系统通知提醒；机身旋钮不联动系统音量时可填「机身衰减」手动补偿；**听力剂量**：按 WHO 80dB×40h/周 = 100%（3dB 交换率）滚动累计最近 7 天播放中的暴露，5 分钟粒度落盘，面板与 `mds vol` 显示额度百分比与剩余额度（按当前声压反解还能听多久）
- **支持的格式**：设备全部采样率 × 位深矩阵，当前格式高亮，点按任意采样率行即切换
- **活动日志**：实时切换记录
- **底部**：登录时自动启动、退出

纯菜单栏应用（LSUIElement），无 Dock 图标；深浅色模式自动适配。
**单实例保护**：任意来源（/Applications、build 目录、LaunchAgent）同时只有一个实例（文件锁），重复启动自动激活现有实例。

## 命令行

```bash
mds list                    # 设备与支持的格式矩阵（--json 机器可读）
mds format                  # 当前格式
mds probe                   # 源探测视角：谁在播、读取偏移是否前进
mds vol                     # 设备音量（dB）与估算声压
mds set 192k                # 立即切换（44100 / 44.1k / 768kHz 等写法）
mds set 44.1k --bits 16     # 指定位深
mds best 768k               # 只预览决策（--apply 生效）
mds set 48000 --device LEN  # 按 UID / 名称片段指定设备
mds watch [--device TP55] [--restore-rate 44100] [--dry-run] [-v]
                            # 守护模式：播放即自动切换
mds playtest <文件>         # 端到端验证（真实 IO + 静音播放）
mds selftest                # 90 项内置自测
```

自动切换运行时日志示例：

```
[20:21:45.882] 播放中源为 96.0kHz/24bit，设备当前 2声道 32位整数 44.1kHz：立即匹配
[20:21:46.530] 已切换 → 2声道 24位整数 96.0kHz （单步直接切换 · 采样率精确 96.0kHz · 位深精确 24bit）· 播放中匹配（源 xxx.flac）
```

### 开机自启（LaunchAgent，CLI 守护）

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

## 工作原理（一图版）

```
播放器打开本地音频文件 ──► mds 周期扫描系统文件句柄（原生 fd 枚举）
                              │
                              ▼
              解析文件头（FLAC/WAV/AIFF/DSF/M4A；
              网易云 .uc! 缓存解混淆后同样解析）
              → 真实采样率 + 位深 + 声道
                              │
                              ▼
        双快照比对读取偏移：正在播放的文件 offset 持续前进，
        残留句柄停滞 → 选出「正在播放」的那一首
                              │
                              ▼
              播放中直接写入匹配格式（与「音频 MIDI 设置」同一条 HAL 属性）
              写入失败 → 登记，设备连续空闲 ≥4s 后重试
```

**匹配策略**：

| 维度 | 优先级 |
|------|--------|
| 采样率 | 精确匹配 > 整数倍升频（44.1k → 88.2k）> 整数分频（88.2k → 44.1k）> 就近 |
| 位深 | 源位深精确 > ≥ 源位深的最小整数位深 > 该采样率下最高整数位深 > 浮点 |
| 声道 | 源声道 > 2 声道 > 该采样率下支持的最大声道数 |

**安全机制**：绑定稳定期 8s / 起播稳定期 3s / 写后掉线熔断（20s 窗口、2 次进稳定模式）/ 空闲 ≥4s 才应用登记目标。切换结果与「音频 MIDI 设置」完全一致（物理可混音交错 `0xc`、客户端虚拟格式保持 float）——曾导致「切换后播放加速」的 NonMixable 格式陷阱与全部防御细节见 [docs/coreaudio.md](docs/coreaudio.md)。

## 已知限制与路线图

- 播放中的格式跟随依赖源探测（每 4 秒扫描），切换发生在起播后数秒；探测不到的来源回退「跟随设备采样率 + 位深策略」
- 听力保护为**估算**（硬件音量衰减 × 耳机灵敏度/阻抗 × 输出口满幅电压），非实测声压——软件无法测得真实 SPL（需人工耳/耦合腔）；平均口径按音乐峰值因子（默认 12 dB）从峰值折算；机身增益档会改变满幅基准（如 TP55 高/低增益 4.2/2.1 Vrms），切档需同步面板「满幅电压」参数；机身音量旋钮若不联动系统音量（mac 拉满、旋钮控音量，读数恒 0dB），实际衰减 macOS 感知不到，需按听感粗校准填入面板「机身衰减」（0 = 机身全开）
- 多台输出设备同时播放不同内容时，文件句柄无法区分归属设备，探测可能跟随另一台设备正在播的文件
- 极少数 USB DAC 的驱动不完整上报 AvailablePhysicalFormats，此时以 `mds list` 实际输出为准
- 路线图：DSD（DoP）识别、多设备同时管理、探测结果的设备归属关联

## 项目结构与文档

```
Sources/
  MDSKit/                 核心逻辑库（CLI 与 GUI 共用）
  mds/                    命令行
  MDSBar/                 菜单栏 App
scripts/
  make-app.sh             构建 .app 并安装
  gen-icon.swift          程序化生成应用图标
docs/
  architecture.md         架构与数据流、保护机制参数表
  coreaudio.md            CoreAudio 陷阱（NonMixable 等）与切换正确性基准
  source-probe.md         源探测机制与播放器支持矩阵
  development.md          构建、自测、排查与文档维护约定
CLAUDE.md                 AI 辅助开发的硬约束速览
```

## License

[MIT](LICENSE)
