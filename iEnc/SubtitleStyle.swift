import CoreText
import SwiftUI

/// 자막 모양 (설정 › 자막). iRayer 와 같은 구성: 글꼴 · 가장자리 · 크기 + 미리보기.
/// "자막 입히기"로 변환할 때 이 모양으로 영상에 새길 예정 (2.0, 지금은 설정 화면만)

/// 자막 글꼴. 시스템 글꼴 + 앱에 넣은 나눔글꼴·마루부리 (SIL OFL 1.1 — Fonts/*-OFL.txt).
/// rawValue 는 글꼴의 PostScript 이름
enum SubtitleFont: String, CaseIterable, Identifiable {
    case system
    case nanumGothic = "NanumGothicOTF"
    case nanumBarunGothic = "NanumBarunGothicOTF"
    case nanumMyeongjo = "NanumMyeongjoOTF"
    case nanumBarunpen = "NanumBarunpen"
    case maruBuri = "MaruBuriot-Regular"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: "시스템 기본"
        case .nanumGothic: "나눔고딕"
        case .nanumBarunGothic: "나눔바른고딕"
        case .nanumMyeongjo: "나눔명조"
        case .nanumBarunpen: "나눔바른펜"
        case .maruBuri: "마루부리"
        }
    }

    /// 시스템 글꼴은 잘 읽히도록 약간 굵게, 넣은 글꼴은 일반 굵기만 있으므로 그대로
    func font(size: CGFloat) -> Font {
        self == .system ? .system(size: size, weight: .semibold) : .custom(rawValue, fixedSize: size)
    }

    /// 앱에 넣은 글꼴(otf)을 이 앱에서만 쓰게 등록 (앱 시작 때)
    static func registerBundled() {
        if let urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil), !urls.isEmpty {
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        }
    }
}

/// 자막 글자 가장자리 모양
enum SubtitleEdge: String, CaseIterable, Identifiable {
    /// 사방 테두리 + 옅은 그림자 (기본)
    case outlineShadow
    /// 테두리만
    case outline
    /// 테두리 없이 오른쪽 아래로 떨어지는 그림자만
    case dropShadow

    var id: String { rawValue }

    var name: String {
        switch self {
        case .outlineShadow: "외곽선 + 그림자"
        case .outline: "외곽선"
        case .dropShadow: "그림자 (오른쪽 아래)"
        }
    }
}

/// 설정 키
enum SubtitleStyleKey {
    static let font = "subtitleFont"
    static let edge = "subtitleEdge"
    static let scale = "subtitleScale"
}

/// 자막 글자 한 덩어리: 흰 글자 + 가장자리(설정)
struct SubtitleText: View {
    let text: String
    /// 기준 크기 (자막 크기 설정을 곱하기 전)
    let baseSize: CGFloat

    @AppStorage(SubtitleStyleKey.font) private var font = SubtitleFont.nanumBarunGothic
    @AppStorage(SubtitleStyleKey.edge) private var edge = SubtitleEdge.outlineShadow
    @AppStorage(SubtitleStyleKey.scale) private var scale = 1.0

    @ViewBuilder
    var body: some View {
        let size = baseSize * scale
        let text = Text(text)
            .font(font.font(size: size))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
        switch edge {
        case .outlineShadow:
            outlined(text).shadow(color: .black.opacity(0.6), radius: 3)
        case .outline:
            outlined(text)
        case .dropShadow:
            // 글자 크기에 맞춰 오른쪽 아래로 떨어지는 그림자 (살짝 번진 것과 또렷한 것을 겹친다)
            let offset = max(size * 0.07, 1.5)
            text
                .shadow(color: .black.opacity(0.9), radius: 0, x: offset, y: offset)
                .shadow(color: .black.opacity(0.5), radius: offset, x: offset, y: offset)
        }
    }

    /// 테두리 대신 사방으로 그림자를 겹쳐 밝은 화면에서도 읽히게 한다
    private func outlined(_ text: some View) -> some View {
        text
            .shadow(color: .black, radius: 0, x: 1, y: 1)
            .shadow(color: .black, radius: 0, x: -1, y: -1)
            .shadow(color: .black, radius: 0, x: 1, y: -1)
            .shadow(color: .black, radius: 0, x: -1, y: 1)
    }

    /// 화면 크기에 따른 기준 크기: 짧은 변의 5.5%
    static func baseSize(for size: CGSize) -> CGFloat {
        min(size.width, size.height) * 0.055
    }
}

/// 자막 설정 미리보기: 16:9 장면에 지금 설정의 자막을 같은 비율로 그린다
struct SubtitlePreview: View {
    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .background {
                // 밝은 부분과 어두운 부분이 섞인 장면 (테두리 그림자가 잘 보이는지 함께 확인)
                LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 0.8), Color(red: 0.85, green: 0.8, blue: 0.65), Color(red: 0.2, green: 0.25, blue: 0.2)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    VStack {
                        Spacer()
                        SubtitleText(text: "자막은 이렇게 보입니다\nThe quick brown fox 123",
                                     baseSize: SubtitleText.baseSize(for: geometry.size))
                            .padding(.horizontal, 12)
                            .padding(.bottom, geometry.size.height * 0.06)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .clipped()
    }
}

/// 설정 › 자막 탭
struct SubtitleStyleSettings: View {
    @AppStorage(SubtitleStyleKey.font) private var font = SubtitleFont.nanumBarunGothic
    @AppStorage(SubtitleStyleKey.edge) private var edge = SubtitleEdge.outlineShadow
    @AppStorage(SubtitleStyleKey.scale) private var scale = 1.0

    var body: some View {
        Form {
            Section {
                SubtitlePreview()
                    .clipShape(.rect(cornerRadius: 8))
            }
            Section {
                Picker("글꼴", selection: $font) {
                    ForEach(SubtitleFont.allCases) { f in
                        Text(f.name).font(f.font(size: 13)).tag(f)
                    }
                }
                Picker("가장자리", selection: $edge) {
                    ForEach(SubtitleEdge.allCases) { Text($0.name).tag($0) }
                }
                LabeledContent("크기") {
                    HStack {
                        // step 을 주면 막대 아래 눈금이 생겨 빼고 5% 단위로 반올림
                        Slider(value: Binding(get: { scale }, set: { scale = ($0 * 20).rounded() / 20 }), in: 0.6...1.6)
                        Text("\(Int((scale * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } footer: {
                Text("자막 입히기로 인코딩할 때 이 자막 설정에 따라 자막을 영상에 입힙니다.\n(단, 아직 자막은 지원되지 않습니다.)\n나눔글꼴·마루부리 © NAVER Corporation, SIL Open Font License 1.1")
            }
        }
        .formStyle(.grouped)
    }
}
