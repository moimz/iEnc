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
