import CoreGraphics
import Foundation

/// 타임라인의 자른 구간 하나: 어느 파일의 어디부터 어디까지 + 음량
struct Clip: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var start: Double
    var end: Double
    /// 음량 조절 (dB, 0 = 그대로). 변환할 때 적용 (아직 변환 기능 없음)
    var gain: Double = 0

    var length: Double { max(0, end - start) }

    static let gainRange: ClosedRange<Double> = -30...12
}

/// 왼쪽 사이드바의 불러온 영상 하나. 파형은 영상 전체를 한 번만 만들고 구간은 그 일부를 잘라 쓴다
struct Source: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var duration: Double = 0
    var thumbnail: CGImage?
    /// 썸네일을 뽑아 봤는지 (소리만 있는 파일은 그림이 없다)
    var thumbnailTried = false

    static func == (a: Source, b: Source) -> Bool {
        a.id == b.id && a.url == b.url && a.duration == b.duration && a.thumbnail === b.thumbnail && a.thumbnailTried == b.thumbnailTried
    }
}
