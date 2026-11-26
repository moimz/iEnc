import SwiftUI

/// 화면 아래 타임라인: 자른 구간을 순서대로 붙여 놓은 영상 한 줄 + 소리 한 줄.
/// 구간 폭 = 길이 × 확대 비율. 누르면 위 재생바에 그 구간이 열리고(노란 테두리), 끌어서 순서를 바꾼다.
/// 소리 줄의 가로 선을 위아래로 끌면 구간 음량(dB)이 바뀐다.
struct ClipTimeline: View {
    @Bindable var model: AppModel
    /// 확대 정도 0(전체 보기)~1(최대 확대), 로그 눈금
    @State private var zoom: Double = 0
    @State private var pinchBase: Double?

    static let videoHeight: CGFloat = 52
    static let audioHeight: CGFloat = 38
    static let rulerHeight: CGFloat = 16
    private let spacing: CGFloat = 3
    private let addWidth: CGFloat = 76
    /// 최대 확대: 1초에 80pt
    private let maxPPS: Double = 80

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                let total = model.clips.reduce(0) { $0 + $1.length }
                let usable = max(100, geo.size.width - 24 - addWidth - spacing * CGFloat(model.clips.count))
                let fitPPS = total > 0 ? Double(usable) / total : 1
                let maxZoom = max(1, maxPPS / fitPPS)
                let pps = fitPPS * exp(zoom * log(maxZoom))
                let widths = model.clips.map { max(28, CGFloat($0.length * pps)) }
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 3) {
                        TimeRuler(lengths: model.clips.map(\.length), widths: widths, spacing: spacing, pps: pps)
                            .frame(width: widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)), height: Self.rulerHeight)
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(Array(model.clips.enumerated()), id: \.element.id) { i, clip in
                                ClipBlock(model: model, clip: clip, width: widths[i])
                            }
                            addTile
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.visible)
                .overlay {
                    if model.clips.isEmpty {
                        Text("구간을 자르면(⌘K) 여기에 차례로 쌓입니다")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { v in
                            if pinchBase == nil { pinchBase = zoom }
                            let step = log(v.magnification) / log(max(1.001, maxZoom))
                            zoom = min(1, max(0, (pinchBase ?? zoom) + step))
                        }
                        .onEnded { _ in pinchBase = nil }
                )
            }
            .frame(height: Self.rulerHeight + 3 + Self.videoHeight + Self.audioHeight + 2 + 12 + 12)
        }
        .background(Color(white: 0.11))
    }

    private var header: some View {
        let total = model.clips.reduce(0) { $0 + $1.length }
        return HStack(spacing: 8) {
            Text("타임라인").font(.subheadline.weight(.semibold))
            if !model.clips.isEmpty {
                Text("구간 \(model.clips.count)개 · \(FF.clock(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { zoom = max(0, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("축소 (⌘−)")
            Slider(value: $zoom, in: 0...1)
                .frame(width: 120)
                .controlSize(.mini)
            Button { zoom = min(1, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .help("확대 (⌘+)")
            Button("전체 보기") { zoom = 0 }
                .keyboardShortcut("0", modifiers: .command)
                .help("모든 구간을 한 화면에 (⌘0)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .disabled(model.clips.isEmpty)
    }

    /// 맨 끝 + : 빈 화면으로 가서 새 영상을 연다. 구간을 고르지 않은(새 영상·빈 화면) 상태면 강조
    private var addTile: some View {
        let emphasized = model.selectedClipID == nil
        return Button { model.newSource() } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                Text("영상 추가").font(.caption2)
            }
            .frame(width: addWidth, height: Self.videoHeight + Self.audioHeight + 2)
            .foregroundStyle(emphasized ? Color.white : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(emphasized ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(emphasized ? Color.accentColor : Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: emphasized ? [] : [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("빈 화면에서 새 영상을 불러옵니다")
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.moveClip(id, before: nil)
            return true
        }
    }
}

/// 타임라인 위 시간 눈금자: 구간을 이어 붙인 결과(변환한 영상)의 시각. 확대 정도에 맞춰 눈금 간격을 고른다.
/// 구간 폭은 짧으면 최소 폭이 있어 시간과 딱 비례하지 않으므로, 구간마다 그 안에서 시각 → x 를 바꾼다
private struct TimeRuler: View {
    let lengths: [Double]
    let widths: [CGFloat]
    let spacing: CGFloat
    let pps: Double

    /// 글자 눈금 간격 후보 (초)
    private static let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]

    var body: some View {
        Canvas { ctx, size in
            guard !lengths.isEmpty else { return }
            let major = Self.steps.first { $0 * pps >= 72 } ?? 7200
            let minor = major / (major >= 60 && Int(major) % 300 == 0 ? 5 : (Int(major) % 5 == 0 ? 5 : 2))
            let total = lengths.reduce(0, +)
            // 시각 → x
            var starts: [(t: Double, x: CGFloat)] = []
            var t = 0.0, x: CGFloat = 0
            for i in lengths.indices {
                starts.append((t, x))
                t += lengths[i]; x += widths[i] + spacing
            }
            func xAt(_ time: Double) -> CGFloat {
                var i = starts.count - 1
                while i > 0 && starts[i].t > time { i -= 1 }
                let len = max(0.000_001, lengths[i])
                return starts[i].x + CGFloat(min(1, (time - starts[i].t) / len)) * widths[i]
            }
            let color = Color.white.opacity(0.35)
            var ticks = Path()
            var k = 0.0
            while k <= total + 0.000_1 {
                let px = xAt(k)
                let isMajor = abs((k / major).rounded() * major - k) < 0.001
                ticks.move(to: CGPoint(x: px + 0.5, y: size.height))
                ticks.addLine(to: CGPoint(x: px + 0.5, y: size.height - (isMajor ? 7 : 3)))
                if isMajor {
                    ctx.draw(Text(Self.label(k)).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: px + 3, y: size.height - 8), anchor: .bottomLeading)
                }
                k += minor
            }
            ctx.stroke(ticks, with: .color(color), lineWidth: 1)
            // 구간 경계 표시
            var edges = Path()
            for s in starts.dropFirst() {
                edges.move(to: CGPoint(x: s.x - spacing / 2, y: 0))
                edges.addLine(to: CGPoint(x: s.x - spacing / 2, y: size.height))
            }
            ctx.stroke(edges, with: .color(.yellow.opacity(0.35)), lineWidth: 1)
        }
    }

    private static func label(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// 타임라인 구간 하나: 위 영상 줄(그림) + 아래 소리 줄(파형 + 음량 선)
private struct ClipBlock: View {
    @Bindable var model: AppModel
    let clip: Clip
    let width: CGFloat
    @State private var dragGain: Double?
    @State private var dropTarget = false

    private var selected: Bool { model.selectedClipID == clip.id }

    var body: some View {
        VStack(spacing: 2) {
            videoLane
            audioLane
        }
        .frame(width: width)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow, lineWidth: 3)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            // 끌어 놓을 자리 표시 (이 구간 앞)
            if dropTarget {
                Capsule().fill(Color.accentColor).frame(width: 3).offset(x: -3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedClipID = clip.id }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.moveClip(id, before: clip.id)
            return true
        } isTargeted: { dropTarget = $0 }
        .contextMenu {
            Button("음량 0 dB 로") { model.setGain(clip.id, 0) }
            Button("음량 +6 dB") { model.setGain(clip.id, clip.gain + 6) }
            Button("음량 −6 dB") { model.setGain(clip.id, clip.gain - 6) }
            Button("소리 끄기 (−30 dB)") { model.setGain(clip.id, Clip.gainRange.lowerBound) }
            Divider()
            Button("삭제") { model.delete([clip.id]) }
        }
        .help("\(clip.url.lastPathComponent)\n\(FF.clock(clip.start)) – \(FF.clock(clip.end)) (\(FF.clock(clip.length)))")
    }

    // MARK: 영상 줄

    private var videoLane: some View {
        let h = ClipTimeline.videoHeight
        let thumbW = h * 16 / 9
        let count = max(1, min(400, Int((width / thumbW).rounded(.up))))
        let images = model.laneImages[clip.id] ?? []
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                ZStack {
                    Color(white: 0.2)
                    if i < images.count, let image = images[i] {
                        Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: width / CGFloat(count), height: h)
                .clipped()
            }
        }
        .frame(width: width, height: h)
        .overlay(alignment: .topLeading) {
            Text(clip.url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white)
                .padding(3)
                .frame(maxWidth: width, alignment: .leading)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5))
        .draggable(clip.id.uuidString) {
            Text(clip.url.lastPathComponent).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .onAppear { model.requestLane(clip.id, count: count, height: Int(h * 2)) }
        .onChange(of: count) { model.requestLane(clip.id, count: count, height: Int(h * 2)) }
        .onChange(of: clip.start) { model.requestLane(clip.id, count: count, height: Int(h * 2)) }
        .onChange(of: clip.end) { model.requestLane(clip.id, count: count, height: Int(h * 2)) }
    }

    // MARK: 소리 줄

    /// dB → 위에서부터의 y 비율 (위 = +12, 아래 = −30)
    private func y(_ db: Double) -> Double {
        let r = Clip.gainRange
        return 1 - (db - r.lowerBound) / (r.upperBound - r.lowerBound)
    }

    private var audioLane: some View {
        let h = ClipTimeline.audioHeight
        let peaks = model.waveforms[clip.id]
        let gain = dragGain ?? clip.gain
        return Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.10, green: 0.17, blue: 0.24)))
            if let wave = peaks, !wave.peak.isEmpty {
                // 한 픽셀 칸마다 그 사이 묶음들의 최댓값. 연한 색 = 순간 최댓값(peak), 진한 색 = 평균 세기(RMS)
                let n = wave.peak.count
                let cols = max(1, Int(size.width))
                let filled = wave.done ? cols : Int(Double(cols) * wave.progress)
                // 진폭의 제곱근 눈금: dB 눈금은 방송 소리가 늘 꽉 차 보이고, 그냥 진폭은 대사가 너무 작게 보인다
                let amp = pow(10, gain / 20)
                func bar(_ v: Float) -> CGFloat {
                    CGFloat(min(1, (Double(v) * amp).squareRoot())) * size.height
                }
                var peakPath = Path(), rmsPath = Path()
                for c in 0..<filled {
                    let a = c * n / cols
                    let b = min(n, max(a + 1, (c + 1) * n / cols))
                    var p: Float = 0, r: Float = 0
                    for k in a..<b {
                        if wave.peak[k] > p { p = wave.peak[k] }
                        if wave.rms[k] > r { r = wave.rms[k] }
                    }
                    let ph = max(0.5, bar(p)), rh = max(0.5, bar(r))
                    peakPath.addRect(CGRect(x: CGFloat(c), y: size.height - ph, width: 1, height: ph))
                    rmsPath.addRect(CGRect(x: CGFloat(c), y: size.height - rh, width: 1, height: rh))
                }
                ctx.fill(peakPath, with: .color(Color(red: 0.35, green: 0.72, blue: 0.95).opacity(0.45)))
                ctx.fill(rmsPath, with: .color(Color(red: 0.42, green: 0.78, blue: 1.0)))
            }
            // 음량 선
            let ly = size.height * y(gain)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: ly)); $0.addLine(to: CGPoint(x: size.width, y: ly)) },
                       with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
        .frame(width: width, height: h)
        .overlay {
            // 아직 거의 못 채웠으면 돌아가는 표시 (NAS 의 긴 구간은 수십 초 걸린다)
            if peaks.map({ !$0.done && $0.progress < 0.03 }) ?? true { ProgressView().controlSize(.mini) }
        }
        .overlay(alignment: .topTrailing) {
            if dragGain != nil || clip.gain != 0 {
                Text(String(format: "%+.1f dB", gain))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .padding(2)
            }
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5))
        .pointerStyle(.rowResize)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    let span = Clip.gainRange.upperBound - Clip.gainRange.lowerBound
                    let d = clip.gain - Double(v.translation.height / h) * span
                    dragGain = min(Clip.gainRange.upperBound, max(Clip.gainRange.lowerBound, (d * 2).rounded() / 2))
                }
                .onEnded { _ in
                    if let dragGain { model.setGain(clip.id, dragGain) }
                    dragGain = nil
                }
        )
        .help("위아래로 끌어 음량 조절 (오른쪽 클릭: 0 dB · ±6 dB)")
    }
}
