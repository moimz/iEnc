import SwiftUI

@main
struct iEncApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1120, minHeight: 640)  // 본문 800 + 인코딩 사이드바 310. 최종 크기는 인코딩 설정 완성 후 (Ai/iEnc.md)
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("iEnc에 관하여") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: Self.versionText, .version: ""])
                }
            }
        }
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


/// 설정 창: 저장 위치 · 파일 이름 규칙 · 미리보기 디코딩
struct SettingsView: View {
    @AppStorage("hardwareDecoding") private var hardware = false
    @AppStorage("saveLocation") private var location = SaveLocation.source
    @AppStorage("saveFolder") private var folder = ""
    @AppStorage(FileNameTemplate.key) private var template = FileNameTemplate.defaultValue
    @State private var choosingFolder = false

    var body: some View {
        Form {
            Section("저장") {
                Picker("기본 저장 위치", selection: $location) {
                    ForEach(SaveLocation.allCases) { Text($0.rawValue).tag($0) }
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
                    Text("예: " + FileNameTemplate.render(template, name: "구명병동 24시 - S03E01", number: 1, start: 1834.5) + ".mp4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Section("미리보기") {
                Toggle("하드웨어 디코딩 (VideoToolbox)", isOn: $hardware)
                Text("기본은 소프트웨어 디코딩입니다. 탐색(구간 끝을 끌 때 그 프레임 보이기)이 더 빠릅니다. AV1 은 늘 하드웨어로 풉니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folder = url.path }
        }
    }
}
