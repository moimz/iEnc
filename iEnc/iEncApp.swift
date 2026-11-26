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
