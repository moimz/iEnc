import SwiftUI

/// iEnc 정보 창 (메뉴 iEnc › iEnc에 관하여). iRayer 와 같은 모양:
/// 아이콘·이름·버전 + 둥근 상자 안에 오픈소스 목록. 라이선스 전문은 앱에 넣은 글 파일(Licenses·Fonts)을 시트로 보여 준다.
/// 같은 내용이 소스의 THIRD_PARTY_NOTICES.md 에도 있다 (하나를 고치면 같이 고친다)
struct AboutView: View {
    static let windowID = "about"

    @State private var license: LicenseText?

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 8)
            Text("iEnc").font(.title2.bold()).padding(.top, 10)
            Text("버전 " + iEncApp.versionText).font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                .textSelection(.enabled)
            Text("영상 구간을 잘라 이어 붙이고 압축하는 맥 앱").font(.caption).foregroundStyle(.tertiary).padding(.top, 2)

            VStack(alignment: .leading, spacing: 12) {
                section("오픈소스") {
                    item("FFmpeg (LGPL 2.1)", "영상 열기·미리보기·하드웨어 변환", "https://ffmpeg.org")
                    item("x264 · x265 (GPL 2.0)", "CPU 변환(H.264·HEVC), FFmpeg 와 함께 ffmpeg-gpl 로", "https://www.videolan.org/developers/x264.html")
                    item("나눔글꼴 · 마루부리 (SIL OFL 1.1)", "자막 글꼴, 네이버", "https://hangeul.naver.com")
                    Text("FFmpeg 라이브러리(LGPL)는 앱 안에 따로 된 동적 라이브러리·실행 파일로 들어 있어 바꿔 넣을 수 있고, 소스는 위 주소에서 받을 수 있습니다. iEnc 코드는 MIT 라이선스입니다.")
                        .padding(.top, 2)
                    Text("x264·x265 가 든 ffmpeg-gpl 은 앱과 링크하지 않고 따로 실행하는 별개 프로그램으로, GPL 을 따르며 소스는 FFmpeg·x264·x265 주소와 저장소의 Scripts/build-ffmpeg-gpl.sh 로 만들 수 있습니다.")
                }
                section("라이선스 전문") {
                    FlowButtons(texts: LicenseText.all) { license = $0 }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(width: 380)
        .sheet(item: $license) { LicenseTextView(text: $0) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold).foregroundStyle(.primary.opacity(0.75))
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func item(_ name: String, _ what: String, _ url: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("·")
            if let url = URL(string: url) {
                Link(destination: url) { Text(name) + Text(" — " + what).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
    }
}

/// 앱에 넣은 라이선스 글 파일 하나
struct LicenseText: Identifiable {
    let title: String
    let file: String
    var id: String { file }

    static let all: [LicenseText] = [
        .init(title: "LGPL 2.1", file: "LGPL-2.1"),
        .init(title: "GPL 2.0", file: "GPL-2.0"),
        .init(title: "나눔글꼴 (OFL)", file: "Nanum-OFL"),
        .init(title: "마루부리 (OFL)", file: "MaruBuri-OFL"),
    ]

    var body: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let data = try? Data(contentsOf: url) else { return "(파일을 찾지 못했습니다: \(file).txt)" }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// 라이선스 단추들 (상자 폭에 맞춰 줄을 바꾼다)
private struct FlowButtons: View {
    let texts: [LicenseText]
    let open: (LicenseText) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { buttons }
            VStack(alignment: .leading, spacing: 6) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(texts) { text in
            Button(text.title) { open(text) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// 라이선스 전문 보기 (시트)
private struct LicenseTextView: View {
    let text: LicenseText
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.body)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(text.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
            }
        }
        .frame(width: 560, height: 520)
    }
}

/// 메뉴 iEnc › iEnc에 관하여 (기본 정보 창 대신 AboutView)
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("iEnc에 관하여") { openWindow(id: AboutView.windowID) }
    }
}

/// 도움말 메뉴 (Ai.md "도움말 메뉴"): GitHub 페이지 · 문제 신고…
struct HelpMenuButtons: View {
    static let repo = "https://github.com/moimz/iEnc"

    var body: some View {
        Button("iEnc GitHub 페이지") { NSWorkspace.shared.open(URL(string: Self.repo)!) }
        Button("문제 신고…") { NSWorkspace.shared.open(Self.issueURL) }
    }

    /// 새 이슈 본문 맨 아래에 버전·macOS 만 미리 채운다 (개인 정보·경로는 넣지 않는다)
    static var issueURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var c = URLComponents(string: repo + "/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: "\n\n---\niEnc \(iEncApp.versionText) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")]
        return c.url!
    }
}
