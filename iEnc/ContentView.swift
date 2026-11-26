import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 창: 본문 [미리보기 | 영상 정보] / 구간 선택 바 / 타임라인(자른 구간) + 오른쪽 사이드바(인코딩 설정, 본문을 줄임)
struct ContentView: View {
    @State private var model = AppModel()
    @FocusState private var focused: Bool
    @AppStorage("hardwareDecoding") private var hardware = false
    @AppStorage("showEncode") private var showEncode = true
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // 본문 최소 800
        EditorPane(model: model)
            .frame(minWidth: 800)
            .inspector(isPresented: $showEncode) {
                EncodeSettingsView(model: model)
                    .inspectorColumnWidth(min: 290, ideal: 310, max: 380)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showEncode.toggle() } label: {
                        Label("인코딩 설정", systemImage: "sidebar.right")
                    }
                    .help("인코딩 설정 열기·닫기")
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.space) { model.togglePlay(); return .handled }
            .onKeyPress(.leftArrow) { model.step(-1); return .handled }
            .onKeyPress(.rightArrow) { model.step(1); return .handled }
            .onKeyPress(characters: .init(charactersIn: "jlio"), phases: .down) { press in
                guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                switch press.characters {
                case "j", "l":  // 5초 앞뒤
                    model.seek(max(0, min(model.duration, model.position + (press.characters == "l" ? 5 : -5))))
                case "i": model.markIn()
                case "o": model.markOut()
                default: break
                }
                return .handled
            }
            .onDeleteCommand {
                if let id = model.selectedClipID { model.delete([id]) }
            }
        .navigationTitle(model.url?.lastPathComponent ?? "iEnc")
        .onChange(of: hardware) { model.hardware = hardware }
        .onAppear {
            focused = true
            if let bench = Bench.arguments { Bench.run(model: model, list: bench.list, out: bench.out) }
            // 시험용: iEnc -open <파일>
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-open"), i + 1 < args.count { model.openNew(URL(fileURLWithPath: args[i + 1])) }
            // 시험용: -demo 를 붙이면 열린 영상에서 구간 둘을 잘라 넣고 첫 구간을 고른다 (화면 확인용)
            // 시험용: -settings 를 붙이면 설정 창을 연다 (화면 확인용)
            if args.contains("-settings") { openSettings() }
            if args.contains("-demo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    model.setOut(45); model.setIn(30); model.cut()
                    model.setOut(130); model.setIn(100); model.cut()
                    model.setOut(300); model.setIn(250); model.cut()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        model.selectedClipID = model.clips.first?.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.setOut(48.5) }
                    }
                }
            }
        }
    }
}

/// [미리보기 | 영상 정보] + 구간 선택 바 + 자르기 단추 + 타임라인. 영상이 없으면 불러오기 안내.
/// 영상 정보는 미리보기 옆에 둔다 (미리보기는 좌우 레터박스가 많이 남아서 그 자리를 쓴다)
struct EditorPane: View {
    @Bindable var model: AppModel
    @State private var dropping = false
    @State private var importing = false
    /// 영상 정보 칸 폭 (경계를 끌어 바꿈, 창 크기가 바뀌어도 그대로 → 줄고 느는 건 미리보기만)
    @AppStorage("infoWidth") private var infoWidth: Double = 320
    @State private var dragStartWidth: Double?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                preview
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .layoutPriority(1)
                infoDivider
                InfoPanel(model: model)
                    .frame(width: infoWidth)
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            Divider()

            // 아래는 높이 고정: 창이 줄면 위 미리보기만 준다
            if model.url != nil {
                TrimBar(model: model)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .disabled(model.duration <= 0)
                CutActions(model: model)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            Divider()
            ClipTimeline(model: model)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .audiovisualContent, .data]) { result in
            if case .success(let url) = result { model.openNew(url) }
        }
    }

    /// 미리보기와 정보 사이 경계: 끌어서 정보 폭 240~520
    private var infoDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                if dragStartWidth == nil { dragStartWidth = infoWidth }
                                infoWidth = min(520, max(240, (dragStartWidth ?? infoWidth) - v.translation.width))
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
    }

    private var preview: some View {
            ZStack {
                VideoLayerView(layer: model.displayLayer, rotation: model.rotation)
                if model.url == nil {
                    VStack(spacing: 12) {
                        Button { importing = true } label: {
                            Label("영상 불러오기", systemImage: "plus")
                                .font(.title3)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Text("또는 영상을 여기에 끌어 놓으세요")
                            .foregroundStyle(.secondary)
                    }
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
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.openNew(url) } }
                }
                return true
            }
    }
}

/// 구간 길이 · 자르기 단추. 타임라인에서 구간을 골랐으면 "구간 적용" 도
struct CutActions: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text("구간 \(FF.clock(model.outPoint - model.inPoint))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("현재 \(FF.clock(model.position))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            if model.selectedClip != nil {
                Button("구간 적용") { model.applyToSelected() }
                    .disabled(!model.selectionChanged)
                    .help("타임라인에서 고른 구간을 지금 범위로 고칩니다")
                Button("새 구간으로 자르기") { model.cut() }
                    .keyboardShortcut("k", modifiers: .command)
            } else {
                Button {
                    model.cut()
                } label: {
                    Label("구간 자르기", systemImage: "scissors")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("k", modifiers: .command)
                .help("지금 구간을 타임라인 끝에 넣습니다 (⌘K)")
            }
        }
        .disabled(model.duration <= 0)
    }
}

/// 오른쪽 정보 칸: 파일·스트림 정보 + 미리보기 진단
struct InfoPanel: View {
    @Bindable var model: AppModel

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
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        // 라벨 칸 폭을 넉넉히 고정 (섹션마다 같은 폭이라 줄이 맞는다)
                        Text(row.0).foregroundStyle(.secondary)
                            .frame(width: 104, alignment: .trailing)
                            .gridColumnAlignment(.trailing)
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
