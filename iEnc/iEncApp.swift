import SwiftUI

@main
struct iEncApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    init() {
        SaveLocation.migrate()
        // 자막 글꼴(나눔·마루부리): 이 앱에서만 쓰게 등록 (설정 › 자막)
        SubtitleFont.registerBundled()
    }

    var body: some Scene {
        WindowGroup {
            // 왼쪽 사이드바 210 · 본문 최소 500 · 인코딩 사이드바 310 (양쪽 사이드바는 폭 고정, 줄고 느는 건 본문만)
            ContentView()
                .frame(minWidth: 1030, minHeight: 640)
        }
        .defaultSize(width: 1560, height: 880)
        .commands {
            // 저장하지 않는 앱: 새 창 대신 "새 프로젝트" 로 모두 비운다
            CommandGroup(replacing: .newItem) {
                NewProjectButton()
            }
            // iEnc에 관하여: 기본 정보 창 대신 직접 만든 창 (오픈소스 고지, iRayer 와 같은 모양)
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
            // 도움말: GitHub 페이지 · 문제 신고… (도움말 책이 없어 기본 항목은 뺀다)
            CommandGroup(replacing: .help) {
                HelpMenuButtons()
            }
        }

        // iEnc 정보 창
        Window("iEnc 정보", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        settings
    }

    /// 설정 창 (⌘,)
    var settings: some Scene {
        Settings { SettingsView() }
    }

    /// "0.1 (빌드 3 · abc1234)" (Ai.md "앱 안의 버전 표시")
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["IEncCommit"] as? String ?? "?"
        return "\(version) (빌드 \(build) · \(commit))"
    }
}


/// Finder "다음으로 열기"·Dock 에 끌어 놓기로 온 파일을 받는다. 여러 개를 고르면 한 번에 온다
/// (SwiftUI onOpenURL 은 앱이 꺼진 상태에서 여러 파일을 열면 첫 파일만 받았다, 2026-11-27)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenInbox.shared.put(urls.filter(\.isFileURL))
    }
}

/// 받아 둔 파일. 창(ContentView)이 뜨면 가져가 영상 불러오기와 같게 연다
@Observable
final class OpenInbox {
    static let shared = OpenInbox()
    private var urls: [URL] = []
    /// 바뀌면 창이 가져가도록 알리는 번호
    private(set) var count = 0

    func put(_ new: [URL]) {
        guard !new.isEmpty else { return }
        urls += new
        count += 1
    }

    func take() -> [URL] {
        defer { urls = [] }
        return urls
    }
}

/// 설정 창 (⌘,): 위쪽 탭으로 나눈다 (iRayer 와 같은 모양): 일반 · 자막 · 파일 연결
struct SettingsView: View {
    // 시험용: -settings -subtab 으로 자막 탭을 바로 연다
    @State private var tab = ProcessInfo.processInfo.arguments.contains("-subtab") ? "subtitle" : (ProcessInfo.processInfo.arguments.contains("-filetab") ? "files" : "general")

    var body: some View {
        TabView(selection: $tab) {
            Tab("일반", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("자막", systemImage: "captions.bubble", value: "subtitle") { SubtitleStyleSettings() }
            Tab("파일 연결", systemImage: "doc.badge.arrow.up", value: "files") { FileAssociationSettings() }
        }
        .frame(width: 520, height: 550)
        .background(SettingsWindowStyler())
    }
}

/// 설정 창(NSWindow)을 직접 다듬는다 (iRayer·iSQL 과 같은 방법).
/// 맥 26 SwiftUI 설정 창은 내용이 탭줄 밑까지 깔려(fullSizeContentView) 창이 활성이면 탭줄 띠가 안 보인다
private struct SettingsWindowStyler: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async {
                window.styleMask.remove(.fullSizeContentView)
                window.titlebarAppearsTransparent = false
                window.titlebarSeparatorStyle = .line
                window.toolbarStyle = .preference
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}

/// 일반 탭: 저장 위치 · 파일 이름 규칙 · CPU 사용량 · 미리보기 디코딩 · 버전
private struct GeneralSettings: View {
    @AppStorage("hardwareDecoding") private var hardware = false
    @AppStorage("cpuLimit") private var cpuLimit: Double = 1
    @AppStorage("saveLocation") private var location = SaveLocation.source
    @AppStorage("saveFolder") private var folder = ""
    @AppStorage(FileNameTemplate.key) private var template = FileNameTemplate.defaultValue
    @State private var choosingFolder = false

    var body: some View {
        Form {
            Section("저장") {
                Picker("기본 저장 위치", selection: $location) {
                    ForEach(SaveLocation.allCases) { Text($0.label).tag($0) }
                }
                if location == .folder {
                    LabeledContent("폴더") {
                        HStack {
                            Text(folder.isEmpty ? "고르지 않음" : (folder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(folder.isEmpty ? .secondary : .primary)
                            Button("고르기…") { choosingFolder = true }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    TextField("파일 이름", text: $template)
                    HStack(spacing: 4) {
                        ForEach(FileNameTemplate.tokens, id: \.0) { token, about in
                            Button(token) { template += token }
                                .controlSize(.small)
                                .help(about)
                        }
                        Spacer()
                        Button("기본값") { template = FileNameTemplate.defaultValue }
                            .controlSize(.small)
                    }
                    Text("예: " + FileNameTemplate.render(template, name: "나의동영상", number: 1, start: 1834.5) + ".mp4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Section("변환") {
                Picker("CPU 사용량", selection: $cpuLimit) {
                    Text("최대").tag(1.0)
                    Text("절반").tag(0.5)
                    Text("적게 (4분의 1)").tag(0.25)
                }
                Text("인코딩할 때 사용할 CPU 스레드 수를 설정합니다. 하드웨어 인코딩에는 영향이 없고, CPU 인코딩(x265·x264)의 변환 속도에 영향을 줍니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("미리보기") {
                Toggle("하드웨어 디코딩 (VideoToolbox)", isOn: $hardware)
                Text("기본적으로 탐색 속도 향상을 위해 소프트웨어 디코딩을 사용합니다. 다만 AV1 같이 소프트웨어 디코딩이 되지 않는 형식은 항상 하드웨어 디코딩을 사용합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("버전", value: iEncApp.versionText)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folder = url.path }
        }
    }
}

/// 파일 › 새 프로젝트 (⌘N). 지금 창의 모델은 FocusedValue 로 받는다
private struct NewProjectButton: View {
    @FocusedValue(\.appModel) private var model

    var body: some View {
        Button("새 프로젝트") { model?.askReset = true }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model == nil)
    }
}

extension FocusedValues {
    @Entry var appModel: AppModel?
}
