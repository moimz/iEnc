import Foundation

/// 인코딩 설정 값 (화면만 먼저: 변환 기능은 아직 없다).
/// 인코딩은 ffmpeg 실행 파일 + VideoToolbox 하드웨어 인코더로 할 계획 (Ai/iEnc.md "정한 것").
struct EncodeSettings: Equatable {
    // MARK: 영상
    enum VideoCodec: String, CaseIterable, Identifiable {
        case hevc = "HEVC (H.265)"
        case h264 = "H.264"
        case copy = "원본 그대로 (다시 압축 안 함)"
        var id: Self { self }
    }
    enum RateMode: String, CaseIterable, Identifiable {
        case quality = "품질 기준"
        case bitrate = "비트레이트"
        var id: Self { self }
    }
    /// 원본 = 구간마다 제 해상도 (한 파일로 합칠 땐 가장 큰 것). 해상도가 다른 여러 파일을 합칠 수 있어서 가장 큰/작은 원본도 고른다
    enum Resolution: Int, CaseIterable, Identifiable {
        case source = 0, largest = -1, smallest = -2, p2160 = 2160, p1440 = 1440, p1080 = 1080, p720 = 720, p480 = 480
        var id: Self { self }
        var label: String {
            switch self {
            case .source: "원본"
            case .largest: "원본 중 가장 큰 것"
            case .smallest: "원본 중 가장 작은 것"
            default: "\(rawValue)p"
            }
        }
    }
    /// 출력 화면과 원본의 가로세로 비율이 다를 때 (예: 4:3 과 16:9 구간을 한 파일로)
    enum Fit: String, CaseIterable, Identifiable {
        case letterbox = "비율 유지 (검은 여백)"
        case crop = "꽉 채우기 (가장자리 자름)"
        var id: Self { self }
    }
    enum FrameRate: Double, CaseIterable, Identifiable {
        case source = 0, fps60 = 60, fps30 = 30, fps25 = 25, fps24 = 24
        var id: Self { self }
        var label: String { self == .source ? "원본" : "\(Int(rawValue))" }
    }
    enum Deinterlace: String, CaseIterable, Identifiable {
        case auto = "자동", off = "끔", on = "켬"
        var id: Self { self }
    }

    var videoCodec = VideoCodec.hevc
    var rateMode = RateMode.quality
    /// VideoToolbox 품질 (1~100, 높을수록 좋고 큼)
    var quality = 60.0
    /// 비트레이트 (Mbps)
    var bitrate = 6.0
    var resolution = Resolution.source
    var fit = Fit.letterbox
    var frameRate = FrameRate.source
    var tenBit = false
    var deinterlace = Deinterlace.auto

    // MARK: 소리
    enum AudioCodec: String, CaseIterable, Identifiable {
        case aac = "AAC"
        case copy = "원본 그대로"
        case none = "소리 없음"
        var id: Self { self }
    }
    enum Channels: String, CaseIterable, Identifiable {
        case source = "원본", stereo = "스테레오", mono = "모노"
        var id: Self { self }
    }

    var audioCodec = AudioCodec.aac
    var audioBitrate = 192
    var channels = Channels.stereo
    var normalizeLoudness = false

    // MARK: 출력
    enum Container: String, CaseIterable, Identifiable {
        case mp4 = "MP4", mkv = "MKV", mov = "MOV"
        var id: Self { self }
    }
    enum Grouping: String, CaseIterable, Identifiable {
        case perClip = "구간마다 파일 하나"
        case joined = "모든 구간을 한 파일로"
        var id: Self { self }
    }

    var container = Container.mp4
    var grouping = Grouping.perClip
    var keepSubtitles = false
    var keepMetadata = true
}

/// 앱 설정(⌘,)에 두는 저장 방식: 위치 · 파일 이름 규칙
enum SaveLocation: String, CaseIterable, Identifiable {
    case source = "원본과 같은 폴더"
    case folder = "정한 폴더"
    case ask = "매번 묻기"
    var id: Self { self }
}

enum FileNameTemplate {
    static let key = "fileNameTemplate"
    static let defaultValue = "{이름}_iEnc_{번호}"
    /// 넣을 수 있는 칸: (칸, 설명)
    static let tokens: [(String, String)] = [
        ("{이름}", "원본 파일 이름"),
        ("{번호}", "구간 번호 01, 02…"),
        ("{시작}", "구간 시작 시각"),
        ("{날짜}", "변환한 날짜"),
    ]

    /// 규칙을 실제 이름으로 (확장자 제외)
    static func render(_ template: String, name: String, number: Int, start: Double, date: Date = .now) -> String {
        let clock = FF.clock(start).replacingOccurrences(of: ":", with: "-")
        let day = date.formatted(.iso8601.year().month().day())
        return template
            .replacingOccurrences(of: "{이름}", with: name)
            .replacingOccurrences(of: "{번호}", with: String(format: "%02d", number))
            .replacingOccurrences(of: "{시작}", with: clock)
            .replacingOccurrences(of: "{날짜}", with: day)
    }
}
