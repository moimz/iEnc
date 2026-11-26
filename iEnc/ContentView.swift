import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 창: 왼쪽 사이드바(자른 구간) · 가운데 미리보기 + 구간 선택 바 + 인코딩 설정 · 오른쪽 영상 정보(덮는 패널)
struct ContentView: View {
    @State private var model = AppModel()
    @FocusState private var focused: Bool
    @AppStorage("showInfo") private var showInfo = false
    @AppStorage("hardwareDecoding") private var hardware = false

    var body: some View {
        NavigationSplitView {
            ClipSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            EditorPane(model: model)
                .frame(minWidth: 560)
                .sidePanel(isPresented: $showInfo, width: 360) { InfoPanel(model: model) }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInfo.toggle() } label: {
                            Label("영상 정보", systemImage: "info.circle")
                        }
                        .keyboardShortcut("i", modifiers: .command)
                        .help("영상 정보 (⌘I)")
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

/// 미리보기 + 구간 선택 바 + 자르기 단추. 영상이 없으면 불러오기 안내
struct EditorPane: View {
    @Bindable var model: AppModel
    @State private var dropping = false
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(minHeight: 260)
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.openNew(url) } }
                }
                return true
            }

            if model.url != nil {
                TrimBar(model: model)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .disabled(model.duration <= 0)
                CutActions(model: model)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            EncodeSettingsArea()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .audiovisualContent, .data]) { result in
            if case .success(let url) = result { model.openNew(url) }
        }
    }
}

/// 구간 길이 · 자르기 단추. 사이드바에서 구간을 골랐으면 "구간 적용" 도
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
                    .help("사이드바에서 고른 구간을 지금 범위로 고칩니다")
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
                .help("지금 구간을 사이드바에 넣습니다 (⌘K)")
            }
        }
        .disabled(model.duration <= 0)
    }
}

/// 인코딩 설정 자리 (아직 비어 있음)
struct EncodeSettingsArea: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Text("인코딩 설정 (준비 중)")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 150)
        .background(.background.secondary)
    }
}

/// 사이드바: 자른 구간 목록 (끌어서 순서 바꾸기) + 맨 아래 영상 추가
struct ClipSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            list
            // 목록 아래 따로 둔다 (겹쳐 띄우면 마지막 구간을 가린다)
            Divider()
            Button { model.newSource() } label: {
                Label("영상 추가", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(10)
            .help("빈 화면에서 새 영상을 불러옵니다")
        }
    }

    private var list: some View {
        List(selection: $model.selectedClipID) {
            ForEach(model.clips) { clip in
                ClipRow(clip: clip)
                    .tag(clip.id)
            }
            .onMove { model.move(from: $0, to: $1) }
        }
        .overlay {
            if model.clips.isEmpty {
                Text("자른 구간이 여기에 쌓입니다")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .onDeleteCommand {
            if let id = model.selectedClipID { model.delete([id]) }
        }
        .contextMenu(forSelectionType: Clip.ID.self) { ids in
            Button("삭제") { model.delete(ids) }
        }
    }
}

/// 구간 한 줄: 16:10 썸네일 + 파일 이름 + 시작–끝
struct ClipRow: View {
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 16:10 칸을 먼저 정하고 그림은 그 안을 채우게 (그림 크기가 칸을 넓히지 않도록 overlay 로)
            Color.black
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let image = clip.thumbnail {
                        Image(decorative: image, scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(FF.clock(clip.length))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(clip.url.lastPathComponent)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(FF.clock(clip.start)) – \(FF.clock(clip.end))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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

extension View {
    /// 오른쪽 옆 패널: 본문 폭은 그대로 두고 위에 덮어 띄운다 (iRayer 의 설정 패널과 같은 방식)
    func sidePanel<Content: View>(isPresented: Binding<Bool>, width: CGFloat, @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay(alignment: .trailing) {
            if isPresented.wrappedValue {
                content()
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(.background)
                    // 왼쪽 가장자리 세로 구분선 (Divider 는 겹쳐 놓으면 가로줄이 된다)
                    .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
                    .shadow(color: .black.opacity(0.15), radius: 12, x: -2)
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: isPresented.wrappedValue)
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
