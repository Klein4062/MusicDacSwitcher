// Views.swift — 菜单栏面板界面（SwiftUI）

import SwiftUI
import MDSKit

// MARK: - 根视图

struct PopoverRootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HeaderCard()
                AutoSwitchCard()
                HearingCard()
                FormatsCard()
                LogCard()
                FooterBar()
            }
            .padding(10)
        }
        .frame(minWidth: 380, minHeight: 640)
        .background(.ultraThinMaterial.opacity(0.001)) // 保持毛玻璃穿透
    }
}

// MARK: - 卡片容器

struct Card<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quinary))
    }
}

// MARK: - 顶部：设备 + 当前格式

struct HeaderCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.blue.opacity(0.30), .purple.opacity(0.14), .teal.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 10) {
                // 设备选择 + 播放状态
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("跟随系统默认输出设备") { model.selectDevice(nil) }
                        Divider()
                        ForEach(model.deviceChoices, id: \.uid) { dev in
                            Button(dev.name) { model.selectDevice(dev.uid) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.deviceName).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    if let badge = model.listenModeBadge {
                        BadgeView(text: badge, fg: .secondary, bg: .primary.opacity(0.08))
                    }
                    Spacer()
                    RunningDot(running: model.isRunning, visible: model.popoverVisible)
                    if model.isHogged {
                        BadgeView(text: "HOG", fg: .orange, bg: .orange.opacity(0.15))
                    }
                }
                .font(.system(size: 12, weight: .medium))

                // 当前格式大字
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.currentRateLabel)
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.3), value: model.currentRateLabel)
                    Text("kHz")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 6) {
                    BadgeView(text: "\(model.currentChannels) ch",
                              fg: .primary, bg: .primary.opacity(0.08))
                    BadgeView(text: "\(model.currentBits) bit \(model.currentIsFloat ? "Float" : "Int")",
                              fg: .white, bg: .accentColor)
                    if let vol = model.volumeDBText {
                        BadgeView(text: "音量 \(vol)", fg: .primary, bg: .primary.opacity(0.08))
                    }
                    if model.loud, let spl = model.avgSPLText {
                        BadgeView(text: "\(spl) ⚠️", fg: .white, bg: .orange)
                    } else if let spl = model.avgSPLText {
                        BadgeView(text: spl, fg: .primary, bg: .primary.opacity(0.08))
                    }
                }
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 1))
    }
}

/// 播放中呼吸圆点。动画用 CALayer + CABasicAnimation：
/// 在系统 render server 进程执行，本进程零逐帧开销。
/// （SwiftUI 的 repeatForever 动画挂在 display link 上每帧主线程求值，
///  即使面板隐藏也持续运行，实测常驻 ~10% CPU；TimelineView 同样要逐帧驱动。）
/// `visible` 在面板隐藏时移除动画，render server 不再持有本窗口的图层树。
struct RunningDot: View {
    var running: Bool
    var visible: Bool

    var body: some View {
        HStack(spacing: 4) {
            PulseDotLayer(running: running && visible)
                .frame(width: 16, height: 16)
            Text(running ? "播放中" : "空闲")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct PulseDotLayer: NSViewRepresentable {
    var running: Bool

    func makeNSView(context: Context) -> PulseDotView {
        PulseDotView()
    }

    func updateNSView(_ v: PulseDotView, context: Context) {
        v.setRunning(running)
    }
}

final class PulseDotView: NSView {
    private let dot = CALayer()
    private let ring = CALayer()
    private var appliedRunning: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dot.name = "dot"
        dot.cornerRadius = 3.5
        ring.name = "ring"
        ring.cornerRadius = 5
        ring.borderWidth = 1.5
        layer?.addSublayer(dot)
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 IB 构建") }

    func setRunning(_ running: Bool) {
        guard running != appliedRunning else { return }
        appliedRunning = running
        needsLayout = true
        dot.removeAnimation(forKey: "breathe")
        ring.removeAnimation(forKey: "breathe")
        guard running else { return }

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1.0
        grow.toValue = 1.3
        grow.duration = 0.9
        grow.autoreverses = true
        grow.repeatCount = .infinity
        grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(grow, forKey: "breathe")

        let expand = CABasicAnimation(keyPath: "transform.scale")
        expand.fromValue = 1.0
        expand.toValue = 1.55
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0.1
        let group = CAAnimationGroup()
        group.animations = [expand, fade]
        group.duration = 0.9
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(group, forKey: "breathe")
    }

    override func layout() {
        super.layout()
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        ring.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        dot.position = c
        ring.position = c
        dot.backgroundColor = (appliedRunning == true
            ? NSColor.systemGreen : NSColor.secondaryLabelColor.withAlphaComponent(0.5)).cgColor
        ring.borderColor = NSColor.systemGreen.withAlphaComponent(0.55).cgColor
    }
}

struct BadgeView: View {
    var text: String
    var fg: Color
    var bg: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
    }
}

// MARK: - 自动切换

struct AutoSwitchCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("自动切换", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: $model.autoSwitch)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                HStack {
                    Label("源探测", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11))
                    Text("读取正在播放的本地音频（FLAC/WAV/AIFF/DSD）并精确匹配格式")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Toggle("", isOn: $model.probeEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }

                // 稳定模式：设备曾在切换格式后掉线 → 停止自动写格式
                if model.passiveMode {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text("检测到切换格式后设备掉线，已停止自动修改格式以保持设备连接。"
                                 + "确认设备稳定后可重新启用。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            model.resetPassiveMode()
                        } label: {
                            Label("重新启用自动切换", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                }

                Picker("位深", selection: $model.bitDepthMode) {
                    ForEach(AppModel.BitDepthMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.autoSwitch)

                HStack(alignment: .top) {
                    Text(model.autoSwitch
                         ? "播放时自动匹配音源采样率，并选择该采样率下设备支持的最佳格式"
                         : "已暂停 — 不会自动修改设备格式")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        model.optimizeNow()
                    } label: {
                        Label("立即优化", systemImage: "wand.and.stars")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.autoSwitch)
                }
            }
        }
    }
}

// MARK: - 听力保护

/// 音量 dB 读数 + 估算声压（双口径：峰值 = 满幅正弦等效上限；平均 ≈ LAeq，
/// 告警依据）。估算基于耳机灵敏度/阻抗与输出口满幅电压，非实测声压。
struct HearingCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("听力保护", systemImage: "ear")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: $model.hearingEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                HStack(spacing: 6) {
                    if let vol = model.volumeDBText {
                        Text("音量 \(vol)")
                        if let tl = model.trackLevelText {
                            Text("· \(tl)")
                                .foregroundStyle(Color.secondary)
                        }
                        if let peak = model.peakSPLText, let avg = model.avgSPLText {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8))
                            Text("峰值 \(peak) · 平均 \(avg)")
                                .foregroundStyle(model.loud ? Color.orange : Color.secondary)
                            if model.loud {
                                Label("超过 \(Int(model.thresholdDB)) dB", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("设备未上报音量")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.system(size: 10, design: .monospaced))

                // 此刻声压（随乐段起伏，停止归 0）+ 实时消耗速率
                HStack(spacing: 6) {
                    Text(model.liveSPLText)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let rate = model.burnRateText {
                        Text("· \(rate)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                // 周剂量（WHO 80dB×40h 基准）：有历史记录才显示
                if let dose = model.weeklyDoseText {
                    HStack(spacing: 4) {
                        Label("听力剂量", systemImage: "chart.pie")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(dose)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let remain = model.doseRemainText {
                        Text(remain)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 14)
                    }
                }

                if model.hearingEnabled {
                    HStack(spacing: 10) {
                        paramField("灵敏度 dB/mW", $model.sensDB)
                        paramField("阻抗 Ω", $model.impOhm)
                        paramField("满幅 Vrms", $model.maxVrms)
                    }
                    HStack(spacing: 10) {
                        paramField("阈值 dB", $model.thresholdDB)
                        paramField("峰值因子 dB", $model.crestDB)
                        paramField("机身衰减 dB", $model.attenDB)
                    }
                    Text("SPL峰值 = 灵敏度 + 20·log₁₀(V) − 10·log₁₀(阻抗)，V = 满幅 × 10^((音量+机身衰减)/20)；"
                         + "平均 = 峰值 − 曲目电平：优先按实测（源探测到播放文件后解码分析，显示「曲电平」），"
                         + "不可测时回退峰值因子参数（流行 ~12 / 古典 ~18 / 纯音 0）。告警按平均口径。"
                         + "满幅电压随 DAC 增益档变化（如 TP55：高 4.2 / 低 2.1 Vrms），切档请同步修改。"
                         + "机身旋钮不联动系统音量时（mac 拉满、旋钮控音量，读数恒 0dB）填「机身衰减」（负值，0=全开）："
                         + "旋钮无 dB 显示时按听感粗校准——临时降 mac 音量到与当前听感相同，"
                         + "该读数即机身衰减的近似值。"
                         + "听力剂量按 WHO 80dB×40h/周 = 100%、3dB 交换率累计（90dB 听 1h 即 25%），"
                         + "滚动最近 7 天，仅统计播放中的估算平均声压。估算非实测；参数查耳机与 DAC 规格书。")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func paramField(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("", value: value, formatter: AppModel.numFmt)
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .frame(width: 64)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - 格式矩阵

struct FormatsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("支持的格式", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("点按切换")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if model.rateRows.isEmpty {
                    Text("设备未报告能力")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ForEach(model.rateRows) { row in
                    RateRowView(row: row)
                }
            }
        }
    }
}

struct RateRowView: View {
    @EnvironmentObject var model: AppModel
    var row: AppModel.RateRow

    private var hovering: Bool { model.hoveredRate == row.rate && !row.isCurrent }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.isCurrent ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 11))
                .foregroundStyle(row.isCurrent ? Color.green : Color.secondary.opacity(0.5))

            Text(row.label)
                .font(.system(size: 12, weight: row.isCurrent ? .bold : .regular, design: .monospaced))
                .frame(width: 86, alignment: .leading)

            Spacer()

            HStack(spacing: 4) {
                ForEach(row.intBits, id: \.self) { bits in
                    bitChip(bits, float: false)
                }
                ForEach(row.floatBits, id: \.self) { bits in
                    bitChip(bits, float: true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { model.apply(rate: row.rate) }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(Color.clear))
        )
        .onHover { model.setHovered($0 ? row.rate : nil) }
        .opacity(row.isCurrent ? 1.0 : 0.92)
    }

    @ViewBuilder
    private func bitChip(_ bits: Int, float: Bool) -> some View {
        let isCurrent = row.isCurrent && row.currentBits == bits
        Text("\(bits)\(float ? "f" : "")")
            .font(.system(size: 10, weight: isCurrent ? .bold : .medium, design: .monospaced))
            .foregroundStyle(isCurrent ? Color.white : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)))
            )
    }
}

// MARK: - 日志

struct LogCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("活动日志", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("清空") { model.logs.removeAll() }
                        .controlSize(.mini)
                        .buttonStyle(.borderless)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.logs.suffix(80).reversed().enumerated()),
                                id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(height: 96)
            }
        }
    }
}

// MARK: - 底部

struct FooterBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Toggle(isOn: $model.launchAtLogin) {
                Label("登录时启动", systemImage: "arrow.clockwise.circle")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("退出 MusicDacSwitcher")
        }
        .padding(.horizontal, 4)
    }
}
