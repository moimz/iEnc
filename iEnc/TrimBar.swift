import SwiftUI

/// 미리보기 아래 재생바: 재생 단추 + 필름 띠 + 노란 구간 테두리(양쪽 손잡이로 끌기).
/// 시작 시각 조절은 시작점 위에, 끝 시각 조절은 끝점 아래에 (구간이 짧아도 겹치지 않게).
struct TrimBar: View {
    @Bindable var model: AppModel
    /// 손잡이를 잡은 자리와 구간 경계의 차이 (끌기 시작할 때 정함 → 잡은 곳에서 튀지 않게)
    @State private var grabOffset: CGFloat?

    private let barHeight: CGFloat = 64
    private let playWidth: CGFloat = 56
    private let handleWidth: CGFloat = 14
    private let border: CGFloat = 4
    private let nudgeHeight: CGFloat = 26
    private let nudgeWidth: CGFloat = 430

    var body: some View {
        GeometryReader { geo in
            let stripX = playWidth + 8
            let stripW = max(1, geo.size.width - stripX - 8)
            VStack(spacing: 6) {
                nudge(time: model.inPoint, anchor: stripX + x(model.inPoint, stripW), total: geo.size.width) { model.setIn(model.inPoint + $0) }
                bar(stripW: stripW)
                nudge(time: model.outPoint, anchor: stripX + x(model.outPoint, stripW), total: geo.size.width) { model.setOut(model.outPoint + $0) }
            }
        }
        .frame(height: nudgeHeight * 2 + barHeight + 12 + 12)  // 위아래 시각 줄 + 바(위아래 여백 6씩) + 줄 사이 6씩
    }

    private func x(_ t: Double, _ width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(max(0, min(1, t / model.duration))) * width
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(max(0, min(1, x / width))) * model.duration
    }

    // MARK: - 바

    private func bar(stripW: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .regular))
                    .frame(width: playWidth - 8, height: barHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("구간 재생·멈춤 (스페이스)")

            strip(width: stripW)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
    }

    private func strip(width: CGFloat) -> some View {
        let h = barHeight - 2 * border
        let thumbW = h * 16 / 9
        let count = max(1, Int((width / thumbW).rounded(.up)))
        let xIn = x(model.inPoint, width)
        let xOut = x(model.outPoint, width)
        let xPos = x(model.position, width)
        return ZStack(alignment: .topLeading) {
            // 필름 띠
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    let image = i < model.strip.count ? model.strip[i] : nil
                    ZStack {
                        Color(white: 0.2)
                        if let image {
                            Image(decorative: image, scale: 2)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                    }
                    .frame(width: width / CGFloat(count), height: h)
                    .clipped()
                }
            }
            .frame(width: width, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .offset(y: border)

            // 구간 밖 흐리게
            Color.black.opacity(0.55)
                .frame(width: max(0, xIn), height: h)
                .offset(y: border)
            Color.black.opacity(0.55)
                .frame(width: max(0, width - xOut), height: h)
                .offset(x: xOut, y: border)

            // 노란 구간 테두리
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.yellow, lineWidth: border)
                .frame(width: max(handleWidth * 2, xOut - xIn + handleWidth * 2), height: barHeight)
                .offset(x: xIn - handleWidth)
                .allowsHitTesting(false)

            // 재생 위치
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: barHeight + 6)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .offset(x: xPos - 1, y: -3)
                .allowsHitTesting(false)

            // 손잡이
            handle(isIn: true)
                .offset(x: xIn - handleWidth)
                .gesture(handleDrag(isIn: true, width: width))
            handle(isIn: false)
                .offset(x: xOut)
                .gesture(handleDrag(isIn: false, width: width))
        }
        .frame(width: width, height: barHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        // 띠를 누르거나 끌면 그 자리를 보여 준다
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                .onChanged { v in
                    model.isScrubbing = true
                    model.seek(time(v.location.x, width))
                }
                .onEnded { _ in model.isScrubbing = false }
        )
        .coordinateSpace(.named("strip"))
        .onAppear { model.requestStrip(count: count, height: Int(h * 2)) }
        .onChange(of: count) { model.requestStrip(count: count, height: Int(h * 2)) }
        .onChange(of: model.duration) { model.requestStrip(count: count, height: Int(h * 2)) }
    }

    private func handle(isIn: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isIn ? 6 : 0, bottomLeadingRadius: isIn ? 6 : 0,
            bottomTrailingRadius: isIn ? 0 : 6, topTrailingRadius: isIn ? 0 : 6
        )
        .fill(Color.yellow)
        .frame(width: handleWidth, height: barHeight)
        .overlay(
            Capsule().fill(Color.black.opacity(0.55)).frame(width: 2.5, height: 18)
        )
        .contentShape(Rectangle().inset(by: -6))
        .pointerStyle(.columnResize)
        .help(isIn ? "구간 시작 (I)" : "구간 끝 (O)")
    }

    private func handleDrag(isIn: Bool, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
            .onChanged { v in
                model.isScrubbing = true
                if grabOffset == nil {
                    grabOffset = x(isIn ? model.inPoint : model.outPoint, width) - v.startLocation.x
                }
                let t = time(v.location.x + (grabOffset ?? 0), width)
                if isIn { model.setIn(t) } else { model.setOut(t) }
            }
            .onEnded { _ in
                grabOffset = nil
                model.isScrubbing = false
            }
    }

    // MARK: - 시각 조절 (−10 −1 −0.1 · 시각 · +0.1 +1 +10)

    private func nudge(time t: Double, anchor: CGFloat, total: CGFloat, change: @escaping (Double) -> Void) -> some View {
        let half = nudgeWidth / 2
        let center = min(max(anchor, half), max(half, total - half))
        return HStack(spacing: 3) {
            ForEach([-10.0, -1, -0.1], id: \.self) { d in NudgeButton(delta: d, action: change) }
            Text(FF.clock(t))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.yellow)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
            ForEach([0.1, 1.0, 10], id: \.self) { d in NudgeButton(delta: d, action: change) }
        }
        .frame(width: nudgeWidth, height: nudgeHeight)
        .position(x: center, y: nudgeHeight / 2)
        .frame(height: nudgeHeight)
    }
}

private struct NudgeButton: View {
    let delta: Double
    let action: (Double) -> Void

    var body: some View {
        Button { action(delta) } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(minWidth: 34)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var label: String {
        let n = abs(delta) < 1 ? String(format: "%.1f", abs(delta)) : String(format: "%.0f", abs(delta))
        return (delta < 0 ? "−" : "+") + n
    }
}
