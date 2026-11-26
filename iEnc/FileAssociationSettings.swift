import CoreServices
import SwiftUI

/// 설정 › 파일 연결: Finder "다음으로 열기"에 iEnc 가 나오는 확장자.
/// 실제 등록은 Info.plist(Support/Info.plist)의 문서 형식에 고정으로 적혀 있다 — 모든 영상(public.movie)을 Alternate(보조 앱)로.
/// 앱 파일 안에 있어 실행 중에 확장자별로 켜고 끌 수는 없다 (고치면 서명이 깨진다). 기본 앱은 바꾸지 않는다
struct FileAssociationSettings: View {
    /// 화면에 보이는 목록 (Info.plist 의 형식 선언·시스템이 아는 영상 형식과 맞춘 것)
    static let extensions = ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "asf", "flv", "f4v", "rm", "rmvb",
                             "vob", "mpg", "mpeg", "m2v", "ts", "m2ts", "mts", "webm", "3gp", "3g2", "dv", "ogv", "mxf"]
    @State private var registered = false

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(Self.extensions, id: \.self) { ext in
                        Text(".\(ext)")
                            .font(.callout.monospaced())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("다음으로 열기에 나오는 확장자")
            } footer: {
                Text("Finder 에서 위 확장자의 파일을 우클릭하면 다음으로 열기… 메뉴에 iEnc 가 나옵니다.\n단, 기본 앱으로 설정하지는 않으므로 파일을 더블클릭해 여는 동작에는 영향을 주지 않습니다.")
            }
            Section {
                LabeledContent("다음으로 열기에 안 보이면") {
                    Button(registered ? "다시 알렸습니다" : "Finder 에 다시 알리기") {
                        // LaunchServices 에 이 앱을 다시 등록 (앱을 옮긴 뒤 목록에 늦게 나올 때)
                        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
                        registered = true
                    }
                    .disabled(registered)
                }
            }
        }
        .formStyle(.grouped)
    }
}
