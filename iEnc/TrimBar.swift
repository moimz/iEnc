import SwiftUI

/// 미리보기 아래 재생바: 재생 단추 + 필름 띠 + 노란 구간 테두리(양쪽 손잡이로 끌기).
/// 시작 시각 조절은 시작점 위에, 끝 시각 조절은 끝점 아래에 (구간이 짧아도 겹치지 않게).
struct TrimBar: View {
    @Bindable var model: AppModel
    /// 손잡이를 잡은 자리와 구간 경계의 차이 (끌기 시작할 때 정함 → 잡은 곳에서 튀지 않게)
    @State private var grabOffset: CGFloat?

    private let barHeight: CGFloat = 40
    private let playWidth: CGFloat = 44
    private let handleWidth: CGFloat = 12
    private let border: CGFloat = 3
    private let nudgeHeight: CGFloat = 22
    private let nudgeWidth: CGFloat = 330

    var body: some View {
        GeometryReader { geo in
            // 바 안 손잡이 영역의 왼쪽 끝 (바 왼쪽 여백 8 + 재생 단추 + 사이 8)
            let trimX = playWidth + 8
            let trimW = max(handleWidth * 2 + 1, geo.size.width - trimX - 8)
            VStack(spacing: 6) {
                nudge(time: model.inPoint, anchor: trimX + x(model.inPoint, trimW), total: geo.size.width) { model.setIn(model.inPoint + $0) }
                bar(trimW: trimW)
                nudge(time: model.outPoint, anchor: trimX + x(model.outPoint, trimW), total: geo.size.width) { model.setOut(model.outPoint + $0) }
            }
        }
        .frame(height: nudgeHeight * 2 + barHeight + 12 + 12)  // 위아래 시각 줄 + 바(위아래 여백 6씩) + 줄 사이 6씩
    }

    /// 손잡이 영역(폭 trimW) 안에서 시각 t 의 x. 필름 띠는 양쪽 손잡이 폭만큼 안쪽에 있다
    private func x(_ t: Double, _ trimW: CGFloat) -> CGFloat {
        let w = trimW - handleWidth * 2
        guard model.duration > 0 else { return handleWidth }
        return handleWidth + CGFloat(max(0, min(1, t / model.duration))) * w
    }

    private func time(_ x: CGFloat, _ trimW: CGFloat) -> Double {
        let w = max(1, trimW - handleWidth * 2)
        return Double(max(0, min(1, (x - handleWidth) / w))) * model.duration
    }

    // MARK: - 바

    private func bar(trimW: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: playWidth - 8, height: barHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("구간 재생·멈춤 (스페이스)")

            trimArea(width: trimW)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
    }

    /// 손잡이까지 들어가는 영역: [손잡이 폭][필름 띠][손잡이 폭]. 손잡이가 이 틀 밖으로 삐져나가지 않게 한다
    private func trimArea(width trimW: CGFloat) -> some View {
        let h = barHeight - 2 * border
        let w = trimW - handleWidth * 2
        let thumbW = h * 16 / 9
        let count = max(1, Int((w / thumbW).rounded(.up)))
        let xIn = x(model.inPoint, trimW)
        let xOut = x(model.outPoint, trimW)
        let xPos = x(model.position, trimW)
        return ZStack(alignment: .topLeading) {
            // 필름 띠: 누르거나 끌면 그 자리를 보여 준다 (이 띠에만 붙여서 손잡이 끌기와 다투지 않게)
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
                    .frame(width: w / CGFloat(count), height: h)
                    .clipped()
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                    .onChanged { v in
                        model.isScrubbing = true
                        model.seek(time(v.location.x, trimW))
                    }
                    .onEnded { _ in model.isScrubbing = false }
            )
            .offset(x: handleWidth, y: border)

            // 구간 밖 흐리게
            Color.black.opacity(0.55)
                .frame(width: max(0, xIn - handleWidth), height: h)
                .offset(x: handleWidth, y: border)
                .allowsHitTesting(false)
            Color.black.opacity(0.55)
                .frame(width: max(0, trimW - handleWidth - xOut), height: h)
                .offset(x: xOut, y: border)
                .allowsHitTesting(false)

            // 노란 구간 테두리 (손잡이 바깥 끝까지)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.yellow, lineWidth: border)
                .frame(width: xOut - xIn + handleWidth * 2, height: barHeight)
                .offset(x: xIn - handleWidth)
                .allowsHitTesting(false)

            // 재생 위치
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: barHeight + 6)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .offset(x: xPos - 1, y: -3)
                .allowsHitTesting(false)

            // 손잡이 (맨 위, 손잡이 몸통 전체가 끌기 영역)
            handle(isIn: true)
                .highPriorityGesture(handleDrag(isIn: true, trimW: trimW))
                .offset(x: xIn - handleWidth)
            handle(isIn: false)
                .highPriorityGesture(handleDrag(isIn: false, trimW: trimW))
                .offset(x: xOut)
        }
        .frame(width: trimW, height: barHeight, alignment: .topLeading)
        .coordinateSpace(.named("trim"))
        .onAppear { model.requestStrip(count: count, height: Int(h * 2)) }
        .onChange(of: count) { model.requestStrip(count: count, height: Int(h * 2)) }
        .onChange(of: model.duration) { model.requestStrip(count: count, height: Int(h * 2)) }
    }

    private func handle(isIn: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isIn ? 5 : 0, bottomLeadingRadius: isIn ? 5 : 0,
            bottomTrailingRadius: isIn ? 0 : 5, topTrailingRadius: isIn ? 0 : 5
        )
        .fill(Color.yellow)
        .frame(width: handleWidth, height: barHeight)
        .overlay(
            Capsule().fill(Color.black.opacity(0.55)).frame(width: 2, height: 12)
        )
        .contentShape(Rectangle())
        .pointerStyle(.columnResize)
        .help(isIn ? "구간 시작 (I)" : "구간 끝 (O)")
    }

    private func handleDrag(isIn: Bool, trimW: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { v in
                model.isScrubbing = true
                if grabOffset == nil {
                    grabOffset = x(isIn ? model.inPoint : model.outPoint, trimW) - v.startLocation.x
                }
                let t = time(v.location.x + (grabOffset ?? 0), trimW)
                if isIn { model.setIn(t) } else { model.setOut(t) }
            }
            .onEnded { _ in
                grabOffset = nil
                model.isScrubbing = false
            }
    }

    // MARK: - 시각 조절  −[10|1|0.1] 시각 [0.1|1|10]+

    private func nudge(time t: Double, anchor: CGFloat, total: CGFloat, change: @escaping (Double) -> Void) -> some View {
        let half = nudgeWidth / 2
        let center = min(max(anchor, half), max(half, total - half))
        return HStack(spacing: 6) {
            NudgeGroup(sign: -1, action: change)
            Text(FF.clock(t))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.yellow)
                .lineLimit(1)
                .fixedSize()
            NudgeGroup(sign: 1, action: change)
        }
        .frame(width: nudgeWidth, height: nudgeHeight)
        .position(x: center, y: nudgeHeight / 2)
        .frame(height: nudgeHeight)
    }
}

/// 한 덩어리로 붙은 초 단추: −[10|1|0.1] 또는 [0.1|1|10]+ (가까운 쪽이 작은 값)
private struct NudgeGroup: View {
    let sign: Double
    let action: (Double) -> Void

    private var steps: [Double] { sign < 0 ? [10, 1, 0.1] : [0.1, 1, 10] }

    var body: some View {
        HStack(spacing: 3) {
            if sign < 0 { symbol }
            HStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    if i > 0 { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 12) }
                    Button { action(sign * step) } label: {
                        Text(step < 1 ? "0.1" : String(format: "%.0f", step))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .frame(width: 30, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(sign < 0 ? "−" : "+")\(step < 1 ? "0.1" : String(format: "%.0f", step))초")
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            if sign > 0 { symbol }
        }
    }

    private var symbol: some View {
        Text(sign < 0 ? "−" : "+")
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}
