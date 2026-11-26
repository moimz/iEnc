import CoreGraphics
import Foundation

/// 사이드바의 자른 구간 하나: 어느 파일의 어디부터 어디까지
struct Clip: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var start: Double
    var end: Double
    /// 시작 프레임 그림 (나중에 채워짐)
    var thumbnail: CGImage?

    var length: Double { max(0, end - start) }

    static func == (a: Clip, b: Clip) -> Bool {
        a.id == b.id && a.url == b.url && a.start == b.start && a.end == b.end && a.thumbnail === b.thumbnail
    }
}
