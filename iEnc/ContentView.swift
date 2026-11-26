import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = AppModel()
    @State private var dropping = false
    @FocusState private var focused: Bool

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ZStack {
                    VideoLayerView(layer: model.displayLayer, rotation: model.rotation)
                    if model.url == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 40))
                            Text("영상을 여기에 끌어 놓으세요")
                        }
                        .foregroundStyle(.secondary)
                    } else if let error = model.openError {
                        Text(error)
                            .foregroundStyle(.red)
                            .padding(8)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if dropping {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(6)
                    }
                }
                .frame(minWidth: 480, minHeight: 270)
                if model.url != nil {
                    TransportBar(model: model)
                }
            }
            .frame(minWidth: 480)

            InfoPanel(model: model)
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 600)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.open(url) } }
            }
            return true
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            if let bench = Bench.arguments { Bench.run(model: model, list: bench.list, out: bench.out) }
            // 시험용: iEnc -open <파일>
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-open"), i + 1 < args.count { model.open(URL(fileURLWithPath: args[i + 1])) }
        }
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { model.step(-1); return .handled }
        .onKeyPress(.rightArrow) { model.step(1); return .handled }
        .onKeyPress(characters: .init(charactersIn: "jl"), phases: .down) { press in
            // J·L: 5초 앞뒤
            model.seek(max(0, min(model.duration, model.position + (press.characters == "l" ? 5 : -5))))
            return .handled
        }
        .navigationTitle(model.url?.lastPathComponent ?? "iEnc")
    }
}

/// 재생 단추 · 시각 · 타임라인
struct TransportBar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { model.position },
                set: { model.seek($0) }
            ), in: 0...max(model.duration, 0.001)) { editing in
                model.isScrubbing = editing
            }
            .controlSize(.small)
            HStack(spacing: 12) {
                Button { model.step(-1) } label: { Image(systemName: "backward.frame") }
                    .help("한 프레임 뒤 (←)")
                Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                    .help("재생·멈춤 (스페이스)")
                Button { model.step(1) } label: { Image(systemName: "forward.frame") }
                    .help("한 프레임 앞 (→)")
                Text("\(FF.clock(model.position)) / \(FF.clock(model.duration))")
                    .font(.system(.body, design: .monospaced))
                Text("#\(Int((model.position / model.frameDuration).rounded()))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("하드웨어 디코딩", isOn: $model.hardware)
                    .toggleStyle(.checkbox)
                    .help("VideoToolbox 로 풉니다. 기본은 소프트웨어 (탐색이 더 빠름, AV1 만 늘 하드웨어)")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 오른쪽 정보 칸: 파일·스트림 정보 + 미리보기 진단
struct InfoPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("영상 정보").font(.headline)
                Spacer()
                Button("복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.reportText, forType: .string)
                }
                .disabled(model.url == nil)
                .help("정보와 진단 값을 글로 복사")
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.url == nil {
                        Text("영상을 끌어 놓으면 형식·코덱·해상도·키프레임 간격과 미리보기 진단 값이 여기에 나옵니다.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.info.sections) { section in
                        SectionView(title: section.title, rows: section.rows)
                    }
                    if model.url != nil {
                        SectionView(title: "미리보기 진단", rows: diagnostics)
                    }
                }
                .padding(10)
                .textSelection(.enabled)
            }
        }
    }

    private var diagnostics: [(String, String)] {
        let s = model.stats
        var rows: [(String, String)] = [
            ("디코더", s.decoder),
            ("열기", String(format: "%.0fms", s.openMs)),
        ]
        if s.seekCount > 0 {
            rows.append(("탐색", String(format: "%d번 · 평균 %.1fms · 최대 %.1fms", s.seekCount, s.seekTotalMs / Double(s.seekCount), s.seekMaxMs)))
        }
        rows.append(("마지막 탐색", s.lastSeek))
        rows.append(("재생", s.playback))
        for (i, e) in s.errors.enumerated() { rows.append(("오류 \(i + 1)", e)) }
        return rows
    }
}

struct SectionView: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(row.1).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

/// AVSampleBufferDisplayLayer 를 붙이는 뷰. 회전 표시가 있으면 레이어를 돌린다 (90·270도면 가로세로를 바꿔 맞춤)
struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    var rotation: Double = 0

    func makeNSView(context: Context) -> LayerHost {
        let view = LayerHost()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.video = layer
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ view: LayerHost, context: Context) {
        if view.rotation != rotation {
            view.rotation = rotation
            view.needsLayout = true
        }
    }

    final class LayerHost: NSView {
        var video: CALayer?
        var rotation: Double = 0

        override func layout() {
            super.layout()
            guard let video else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let sideways = Int(rotation.rounded()) % 180 != 0
            video.bounds = CGRect(x: 0, y: 0, width: sideways ? bounds.height : bounds.width, height: sideways ? bounds.width : bounds.height)
            video.position = CGPoint(x: bounds.midX, y: bounds.midY)
            video.setAffineTransform(CGAffineTransform(rotationAngle: -rotation * .pi / 180))
            CATransaction.commit()
        }
    }
}
