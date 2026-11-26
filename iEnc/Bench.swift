import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 자동 측정: `iEnc -bench <목록 파일> -out <결과 폴더>`
/// 목록의 영상마다 열기 · 여러 위치 탐색 · 한 프레임 앞뒤 · 정확도 대조(탐색 vs 처음부터 차례로) · 3초 재생을 하고
/// 결과 폴더에 영상별 보고서(.txt)·화면(.png)과 요약표(summary.tsv)를 남긴다. 끝나면 앱을 닫는다.
enum Bench {
    static var arguments: (list: URL, out: URL)? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-bench"), i + 1 < a.count, let o = a.firstIndex(of: "-out"), o + 1 < a.count else { return nil }
        return (URL(fileURLWithPath: a[i + 1]), URL(fileURLWithPath: a[o + 1]))
    }

    static func run(model: AppModel, list: URL, out: URL) {
        // -hw: 하드웨어 디코딩 강제 (기본은 소프트웨어, 비교용)
        model.hardware = ProcessInfo.processInfo.arguments.contains("-hw")
        DispatchQueue.global(qos: .userInitiated).async {
            let files = ((try? String(contentsOf: list, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let summary = out.appending(path: "summary.tsv")
            if !FileManager.default.fileExists(atPath: summary.path) {
                try? (Row.header + "\n").write(to: summary, atomically: true, encoding: .utf8)
            }
            for (n, path) in files.enumerated() {
                let row = measure(model: model, url: URL(fileURLWithPath: path), out: out, number: n + 1)
                append(row.line + "\n", to: summary)
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    struct Row {
        static let header = ["파일", "컨테이너", "영상", "오디오", "디코더", "열기ms", "탐색평균ms", "탐색최대ms", "앞프레임평균ms", "뒤프레임평균ms", "뒤프레임최대ms", "정확도", "재생", "오류"].joined(separator: "\t")
        var cells: [String] = []
        var line: String { cells.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }
    }

    private static func measure(model: AppModel, url: URL, out: URL, number: Int) -> Row {
        var log: [String] = ["# \(url.path)", ""]
        DispatchQueue.main.sync { model.open(url) }

        // 열릴 때까지 (최대 30초)
        var waited = 0.0
        while waited < 30 {
            let (ready, failed) = DispatchQueue.main.sync { (model.duration > 0 && model.engine != nil, model.openError != nil) }
            if ready || failed { break }
            Thread.sleep(forTimeInterval: 0.05)
            waited += 0.05
        }
        // 정보 읽기(키프레임 훑기 포함)를 기다린다
        for _ in 0..<200 {
            if DispatchQueue.main.sync(execute: { model.info.sections.count > 1 }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let (engine, duration, error, info) = DispatchQueue.main.sync { (model.engine, model.duration, model.openError, model.info) }
        var row = Row()
        row.cells.append(url.lastPathComponent)
        row.cells.append(value(info, "파일", "컨테이너").components(separatedBy: " (").first ?? "")
        row.cells.append(videoSummary(info))
        row.cells.append(audioSummary(info))

        guard let engine, error == nil, duration > 0 else {
            log.append("열기 실패: \(error ?? "시간 초과")")
            row.cells += ["-", "-", "-", "-", "-", "-", "-", "열기 실패", "-", error ?? "시간 초과"]
            write(log + ["", info.text], to: out, number: number, url: url)
            return row
        }

        // 1) 여러 위치 탐색 (순서를 섞어 앞뒤로 크게 오가게)
        var rng = SeededRandom(seed: UInt64(truncatingIfNeeded: url.lastPathComponent.hashValue & 0x7fffffff) | 1)
        var targets = [0.5, 0.1, 0.9, 0.33, 0.66, 0.05, 0.98].map { $0 * duration }
        for _ in 0..<6 { targets.append(Double(rng.next() % 10000) / 10000 * duration) }
        var seekMs: [Double] = []
        var midImage: CGImage?
        log.append("[탐색]")
        for t in targets {
            let p = engine.benchSeek(t)
            seekMs.append(p.ms)
            log.append(String(format: "  목표 %@ → %@", FF.clock(t), p.line))
            if abs(t - 0.5 * duration) < 0.001 { midImage = p.image }
        }

        // 2) 한 프레임 앞 10번, 뒤 10번 (가운데에서)
        _ = engine.benchSeek(duration * 0.4)
        var fwd: [Double] = [], back: [Double] = []
        var stepLog: [String] = []
        var prev = engine.shownTime
        for _ in 0..<10 {
            let p = engine.benchSeek(0, step: 1); fwd.append(p.ms)
            stepLog.append(String(format: "+1 %.1fms Δ%.3f", p.ms, p.shown - prev)); prev = p.shown
        }
        for _ in 0..<10 {
            let p = engine.benchSeek(0, step: -1); back.append(p.ms)
            stepLog.append(String(format: "-1 %.1fms Δ%.3f", p.ms, p.shown - prev)); prev = p.shown
        }
        log.append("[한 프레임 이동] " + stepLog.joined(separator: " · "))

        // 3) 정확도: 앞부분 두 곳을 탐색으로 얻은 프레임 vs 처음부터 차례로 푼 프레임
        var verdicts: [String] = []
        log.append("[정확도 대조]")
        for t in [min(17.3, duration * 0.3), min(52.7, duration * 0.6)] {
            let a = engine.benchSeek(t)
            let b = engine.benchLinear(t)
            let diff = imageDiff(a.image, b.image)
            let same = abs(a.shown - b.shown) < 0.001 && diff < 3
            verdicts.append(same ? "OK" : "다름")
            log.append(String(format: "  %@: 탐색 %@ / 차례 %@ (%@, %.0fms) · 그림 차이 %.2f → %@",
                              FF.clock(t), FF.clock(a.shown), FF.clock(b.shown), b.line, b.ms, diff, same ? "같음" : "다름 ⚠️"))
            if !same, let ai = a.image, let bi = b.image {
                save(ai, to: out.appending(path: String(format: "%02d-verify-seek-%.0f.png", number, t)))
                save(bi, to: out.appending(path: String(format: "%02d-verify-linear-%.0f.png", number, t)))
            }
        }

        // 4) 재생 3.5초
        let playFrom = duration * 0.25
        DispatchQueue.main.sync { model.seek(playFrom) }
        Thread.sleep(forTimeInterval: 0.3)
        DispatchQueue.main.sync { model.play() }
        Thread.sleep(forTimeInterval: 3.5)
        let (playback, playedTo) = DispatchQueue.main.sync { (model.stats.playback, model.position) }
        DispatchQueue.main.sync { model.pause() }
        log.append("[재생] \(FF.clock(playFrom))부터 → \(FF.clock(playedTo)) · \(playback)")

        if let midImage { save(midImage, to: out.appending(path: String(format: "%02d.png", number))) }

        let stats = DispatchQueue.main.sync { model.stats }
        row.cells.append(stats.decoder)
        row.cells.append(String(format: "%.0f", stats.openMs))
        row.cells.append(String(format: "%.1f", seekMs.reduce(0, +) / Double(seekMs.count)))
        row.cells.append(String(format: "%.1f", seekMs.max() ?? 0))
        row.cells.append(String(format: "%.1f", fwd.reduce(0, +) / Double(fwd.count)))
        row.cells.append(String(format: "%.1f", back.reduce(0, +) / Double(back.count)))
        row.cells.append(String(format: "%.1f", back.max() ?? 0))
        row.cells.append(verdicts.joined(separator: "/"))
        row.cells.append(playback.replacingOccurrences(of: "재생 중 · ", with: ""))
        row.cells.append(stats.errors.isEmpty ? "-" : "\(stats.errors.count)개: \(stats.errors.last!)")

        let report = DispatchQueue.main.sync { model.reportText }
        write(log + ["", report], to: out, number: number, url: url)
        return row
    }

    // MARK: - 도우미

    private static func value(_ info: MediaInfo, _ section: String, _ key: String) -> String {
        info.sections.first { $0.title.hasPrefix(section) || $0.title.contains(section) }?.rows.first { $0.0 == key }?.1 ?? ""
    }

    private static func videoSummary(_ info: MediaInfo) -> String {
        guard let s = info.sections.first(where: { $0.title.hasSuffix("영상") }) else { return "-" }
        func v(_ k: String) -> String { s.rows.first { $0.0 == k }?.1 ?? "" }
        return [v("코덱").components(separatedBy: " (").first ?? "", v("프로파일").components(separatedBy: " · ").first ?? "", v("픽셀 형식"), v("해상도"), v("주사 방식")]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func audioSummary(_ info: MediaInfo) -> String {
        let list = info.sections.filter { $0.title.hasSuffix("오디오") }.compactMap { s in
            s.rows.first { $0.0 == "코덱" }?.1.components(separatedBy: " (").first
        }
        return list.isEmpty ? "-" : list.joined(separator: "/")
    }

    /// 두 그림을 32×18 회색으로 줄여 평균 밝기 차이 (0~255)
    private static func imageDiff(_ a: CGImage?, _ b: CGImage?) -> Double {
        guard let a, let b, let x = tiny(a), let y = tiny(b) else { return 999 }
        return zip(x, y).map { abs(Double($0) - Double($1)) }.reduce(0, +) / Double(x.count)
    }

    private static func tiny(_ image: CGImage) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: 32 * 18)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 18))
            return true
        }
        return ok ? px : nil
    }

    private static func save(_ image: CGImage, to url: URL) {
        // 폭 640 으로 줄여 저장
        let w = 640, h = max(1, Int(Double(image.height) * 640 / Double(max(image.width, 1))))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, small, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func write(_ lines: [String], to out: URL, number: Int, url: URL) {
        let file = out.appending(path: String(format: "%02d.txt", number))
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private static func append(_ text: String, to url: URL) {
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(text.data(using: .utf8)!)
        try? h.close()
    }
}

/// 영상마다 같은 위치를 재도록 고정 씨앗 난수
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
