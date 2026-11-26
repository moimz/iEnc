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
    enum Resolution: Int, CaseIterable, Identifiable {
        case source = 0, p2160 = 2160, p1440 = 1440, p1080 = 1080, p720 = 720, p480 = 480
        var id: Self { self }
        var label: String { self == .source ? "원본" : "\(rawValue)p" }
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
    /// nil 이면 원본과 같은 폴더
    var folder: URL?
    /// 파일 이름 뒤에 붙일 글자 (원본이름 + 이 글자 + 구간 번호)
    var suffix = "_iEnc"
    var keepSubtitles = false
    var keepMetadata = true
}
