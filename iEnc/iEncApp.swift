import SwiftUI

@main
struct iEncApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 820, minHeight: 420)
        }
        .defaultSize(width: 1200, height: 700)
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


/// 설정 창: 미리보기 디코딩 방식
struct SettingsView: View {
    @AppStorage("hardwareDecoding") private var hardware = false

    var body: some View {
        Form {
            Section("미리보기") {
                Toggle("하드웨어 디코딩 (VideoToolbox)", isOn: $hardware)
                Text("기본은 소프트웨어 디코딩입니다. 탐색(구간 끝을 끌 때 그 프레임 보이기)이 더 빠릅니다. AV1 은 늘 하드웨어로 풉니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
