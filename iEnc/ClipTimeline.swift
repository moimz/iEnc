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
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(model.clips) { clip in
                            ClipBlock(model: model, clip: clip, width: max(28, CGFloat(clip.length * pps)))
                        }
                        addTile
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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
            .frame(height: Self.videoHeight + Self.audioHeight + 2 + 16 + 12)
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
            if let peaks, !peaks.isEmpty {
                // 한 픽셀 칸마다 그 사이 묶음들의 최댓값 (아래에서 위로)
                let cols = max(1, Int(size.width))
                var path = Path()
                for c in 0..<cols {
                    let a = c * peaks.count / cols
                    let b = max(a + 1, (c + 1) * peaks.count / cols)
                    var m: Float = 0
                    for k in a..<min(b, peaks.count) where peaks[k] > m { m = peaks[k] }
                    // dB 눈금으로 그린다 (조용한 소리도 보이게): −48 dBFS = 바닥, 0 dBFS = 꼭대기
                    let db = m > 0 ? 20 * log10(Double(m)) + gain : -100
                    let v = min(1, max(0, (db + 48) / 48))
                    let bar = max(0.5, v * Double(size.height))
                    path.addRect(CGRect(x: CGFloat(c), y: size.height - bar, width: 1, height: bar))
                }
                ctx.fill(path, with: .color(Color(red: 0.35, green: 0.72, blue: 0.95)))
            }
            // 음량 선
            let ly = size.height * y(gain)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: ly)); $0.addLine(to: CGPoint(x: size.width, y: ly)) },
                       with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
        .frame(width: width, height: h)
        .overlay {
            if peaks == nil { ProgressView().controlSize(.mini) }
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
