import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 창: 왼쪽 사이드바(불러온 영상) · 본문 [미리보기 | 영상 정보] / 구간 선택 바 / 타임라인(자른 구간) · 오른쪽 사이드바(인코딩 설정)
struct ContentView: View {
    @State private var model = AppModel()
    @FocusState private var focused: Bool
    @AppStorage("hardwareDecoding") private var hardware = false
    @AppStorage("showEncode") private var showEncode = true
    @AppStorage("showInfo") private var showInfo = true
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            SourceSidebar(model: model)
                .navigationSplitViewColumnWidth(210)
        } detail: {
            detail
        }
        .navigationTitle(model.url?.lastPathComponent ?? "새 프로젝트")
        .focusedSceneValue(\.appModel, model)
        // Finder 다음으로 열기 · Dock 에 끌어 놓기: 앱 대리자가 받아 둔 파일을 이 창이 가져간다
        .onAppear { takeOpened() }
        .onChange(of: OpenInbox.shared.count) { takeOpened() }
        // 창이 있으면 열기 요청을 이 창이 받는다 (파일마다 새 창을 만들지 않게)
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        // 영상 정보는 영상이 있을 때만: 처음 영상을 열면 저절로 보인다
        .onChange(of: model.url) { old, new in
            if old == nil && new != nil { showInfo = true }
        }
        .onChange(of: model.askReset) {
            // 비어 있으면 묻지 않고 바로
            if model.askReset && model.isEmptyProject { model.resetProject(); model.askReset = false }
        }
        .alert("새 프로젝트를 시작할까요?", isPresented: Binding(get: { model.askReset && !model.isEmptyProject }, set: { model.askReset = $0 })) {
            Button("새 프로젝트", role: .destructive) { model.resetProject() }
            Button("취소", role: .cancel) { }
        } message: {
            Text("불러온 영상 목록과 자른 구간이 모두 지워집니다. 인코딩 설정은 그대로입니다.")
        }
    }

    private func takeOpened() {
        let urls = OpenInbox.shared.take()
        if !urls.isEmpty { model.importFiles(urls) }
    }

    private var detail: some View {
        // 본문 최소 500 (양쪽 사이드바는 폭 고정)
        EditorPane(model: model)
            .frame(minWidth: 500)
            .inspector(isPresented: $showEncode) {
                EncodeSettingsView(model: model)
                    .inspectorColumnWidth(310)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showInfo.toggle() } label: {
                        Label("영상 정보", systemImage: "info.circle")
                    }
                    .help("영상 정보 보이기·숨기기")
                    .disabled(model.url == nil)
                }
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
        .onChange(of: hardware) { model.hardware = hardware }
        .onAppear {
            focused = true
            if let bench = Bench.arguments { Bench.run(model: model, list: bench.list, out: bench.out) }
            // 시험용: iEnc -open <파일>
            let args = ProcessInfo.processInfo.arguments
            // 시험용: -open <파일> [<파일>…] (여러 개면 첫 영상을 열고 나머지는 사이드바에)
            // 여러 파일은 -open a -open b 로도 (따로 떨어진 파일 경로 인자는 AppKit 이 "문서 열기"로 받아
            // 빈 창을 안 만들 때가 있다 → 시험 앱이 창 없이 멈춤, 2026-11-27)
            let files = args.indices.filter { args[$0] == "-open" }.flatMap { i in
                args[(i + 1)...].prefix { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
            }
            if !files.isEmpty { model.importFiles(files) }
            // 시험용: -demo 를 붙이면 열린 영상에서 구간 둘을 잘라 넣고 첫 구간을 고른다 (화면 확인용)
            // 시험용: -settings 를 붙이면 설정 창을 연다 (화면 확인용)
            if args.contains("-settings") { openSettings() }
            if let kv = EncodeTest.arguments { EncodeTest.run(model: model, kv) }
            // 자막 설정 화면 보기용: 구간 둘 + 자막 포함 켜기 + 자막 입히기
            // 원본 그대로 검사 화면 보기용: 연 영상들마다 구간 하나 + 원본 그대로 (뒤에 joined 를 주면 한 파일로)
            if args.contains("-copydemo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    for source in model.sources {
                        model.clips.append(Clip(url: source.url, start: 0, end: min(5, max(1, source.duration))))
                    }
                    model.encode.videoCodec = .copy
                    if args.contains("-joined") { model.encode.grouping = .joined }
                    if args.contains("-bitrate") { model.encode.videoCodec = .hevc; model.encode.rateMode = .bitrate }
                }
            }
            if args.contains("-subdemo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    model.setOut(45); model.setIn(30); model.cut()
                    model.setOut(130); model.setIn(100); model.cut()
                    model.subtitle.enabled = true
                    model.subtitle.mode = .burn
                    if let first = model.clips.first { model.setClipSubtitleTracks(first.id, toggle: 0) }
                }
            }
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
    @AppStorage("showInfo") private var showInfo = true
    @State private var dragStartWidth: Double?

    var body: some View {
        VStack(spacing: 0) {
            // 본문이 좁아지면 정보 칸도 줄인다 (미리보기 최소 200 은 남긴다)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    preview
                        .frame(minWidth: 200, maxWidth: .infinity)
                        .layoutPriority(1)
                    if showInfo && model.url != nil {
                        infoDivider
                        InfoPanel(model: model)
                            .frame(width: min(infoWidth, max(200, geo.size.width - 201)))
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            Divider()

            // 아래는 높이 고정: 창이 줄면 위 미리보기만 준다
            if model.url != nil {
                TrimBar(model: model)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .disabled(model.duration <= 0)
                // 구간 끝 시각 줄과 붙어 보이지 않게 선 + 다른 배경으로 나눈다
                Divider()
                    .padding(.top, 6)
                CutActions(model: model)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.15))
            }
            Divider()
            ClipTimeline(model: model)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .audiovisualContent, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
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
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in dropFiles(providers, into: model) }
    }
}

/// 구간 길이 · 자르기 단추. 타임라인에서 구간을 골랐으면 "구간 적용" 도
struct CutActions: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(FF.clock(model.position))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            // 지금 자리를 구간 시작·끝으로 (I · O 키와 같음)
            // 글자("시작")는 "영상 처음으로 가기"로 읽힐 수 있어 아이콘 + 툴팁만
            HStack(spacing: 6) {
                Button { model.markIn() } label: { Image(systemName: "arrow.left.to.line") }
                    .help("지금 자리를 구간 시작으로 (I)")
                Button { model.markOut() } label: { Image(systemName: "arrow.right.to.line") }
                    .help("지금 자리를 구간 끝으로 (O)")
            }
            Spacer()
            if !model.audioTracks.isEmpty { AudioTrackButton(model: model) }
            if model.selectedClip != nil {
                Button("구간 적용") { model.applyToSelected() }
                    .disabled(!model.selectionChanged)
                    .help("타임라인에서 고른 구간을 지금 범위로 고칩니다")
                Button("새 구간으로 추가") { model.cut() }
                    .keyboardShortcut("k", modifiers: .command)
            } else {
                Button {
                    model.cut()
                } label: {
                    Label("선택 구간 추가", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("k", modifiers: .command)
                .help("지금 구간을 타임라인 끝에 넣습니다 (⌘K)")
            }
        }
        .disabled(model.duration <= 0)
    }
}

/// 선택 구간 추가 옆: 오디오 트랙 설정. 누르면 말풍선에서
/// 미리보기로 들을 트랙(하나)과 자를 구간에 넣을 트랙(여럿·하나·없음)을 고른다
struct AudioTrackButton: View {
    @Bindable var model: AppModel
    @State private var shown = false

    private var tracks: [AudioTrack] { model.audioTracks }
    private var included: [Int] { model.cutTracks ?? Array(tracks.indices) }

    var body: some View {
        Button { shown.toggle() } label: {
            // 글자는 늘 같게 (고른 트랙은 말풍선과 타임라인 소리 줄에서 본다). 아이콘만 소리를 뺐는지 보여 준다
            Label("오디오 트랙 설정", systemImage: included.isEmpty ? "speaker.slash" : "speaker.wave.2")
                .lineLimit(1)
        }
        .help("미리보기로 들을 오디오 트랙과, 구간에 넣을 오디오 트랙을 고릅니다")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if tracks.count > 1 {
                    Text("미리보기").font(.subheadline.weight(.semibold))
                    Picker("미리보기", selection: Binding(get: { model.listenTrack }, set: { model.listen($0) })) {
                        ForEach(tracks.indices, id: \.self) { i in Text(tracks[i].label(i + 1)).tag(i) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Divider().padding(.vertical, 2)
                }
                HStack {
                    Text("구간").font(.subheadline.weight(.semibold))
                    Spacer()
                    if tracks.count > 1 {
                        Button("모두") { model.cutTracks = nil }.controlSize(.small)
                    }
                    Button("없음") { model.cutTracks = [] }.controlSize(.small)
                }
                ForEach(tracks.indices, id: \.self) { i in
                    Toggle(tracks[i].label(i + 1), isOn: Binding(get: { included.contains(i) }, set: { _ in model.toggleCutTrack(i) }))
                        .toggleStyle(.checkbox)
                }
                Text(model.selectedClip != nil ? "바꾸면 구간 적용을 눌러야 이 구간에 들어갑니다." : "여러 개를 고르면 변환한 파일에 오디오 트랙이 그만큼 들어갑니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 300)
        }
    }
}

/// 왼쪽 사이드바: 한 번이라도 불러온 영상. 누르면 구간 없이 그 영상이 열린다.
/// 지금 위에 열린 영상(타임라인에서 구간을 골랐으면 그 구간의 영상)은 노란 테두리
struct SourceSidebar: View {
    @Bindable var model: AppModel
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            list
            // 목록 아래 따로 (목록을 가리지 않게). 누르면 바로 파일을 고른다
            Divider()
            Button { importing = true } label: {
                Label("영상 불러오기", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(10)
            .keyboardShortcut("o", modifiers: .command)
            .help("영상을 불러옵니다 (⌘O)")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .audiovisualContent, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in dropFiles(providers, into: model) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.sources) { source in
                    SourceRow(source: source, current: source.url == model.url,
                              clipCount: model.clips.filter { $0.url == source.url }.count)
                        .contentShape(Rectangle())
                        .onTapGesture { model.openSource(source) }
                        .contextMenu {
                            Button("목록에서 빼기") { model.removeSource(source) }
                                .disabled(model.sourceInUse(source))
                        }
                }
            }
            .padding(10)
        }
        .overlay {
            if model.sources.isEmpty {
                Text("불러온 영상이 없습니다")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }
}

/// 불러온 영상 한 줄: 16:10 썸네일(길이) + 파일 이름 + 자른 구간 수
private struct SourceRow: View {
    let source: Source
    let current: Bool
    let clipCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.black
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let image = source.thumbnail {
                        Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
                    } else if source.thumbnailTried {
                        Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if source.duration > 0 {
                        Text(FF.clock(source.duration))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if current {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(Color.yellow, lineWidth: 3).padding(-2)
                    }
                }
            Text(source.url.lastPathComponent)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(clipCount > 0 ? "구간 \(clipCount)개" : "구간 없음")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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

/// 끌어 놓은 파일들(여러 개 가능)을 받아 순서대로 넣는다
func dropFiles(_ providers: [NSItemProvider], into model: AppModel) -> Bool {
    guard !providers.isEmpty else { return false }
    let group = DispatchGroup()
    var urls = [URL?](repeating: nil, count: providers.count)
    for (i, provider) in providers.enumerated() {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async { urls[i] = url; group.leave() }
        }
    }
    group.notify(queue: .main) { model.importFiles(urls.compactMap { $0 }) }
    return true
}
