import Foundation

/// 시험용 자동 변환: iEnc -open a b … -encode out=<폴더> name=<이름> codec=hevc q=60 group=joined …
/// 열린 영상마다 구간 하나(30% 지점부터 len 초)를 만들고 설정대로 변환한 뒤
/// <폴더>/report.tsv 에 결과(상태·시간·크기·예상 크기·CPU 사용)를 한 줄 붙이고 앱을 닫는다
enum EncodeTest {
    static var arguments: [String: String]? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-encode") else { return nil }
        var kv: [String: String] = [:]
        for a in args[(i + 1)...] {
            let p = a.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { kv[p[0]] = p[1] }
        }
        return kv
    }

    static func run(model: AppModel, _ kv: [String: String]) {
        let out = URL(fileURLWithPath: kv["out"] ?? NSTemporaryDirectory())
        let name = kv["name"] ?? "test"
        let len = Double(kv["len"] ?? "") ?? 15
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            waited += 0.5
            guard (model.metasReady && model.sources.allSatisfy { $0.duration > 0 }) || waited > 60 else { return }
            timer.invalidate()
            var e = EncodeSettings()
            switch kv["codec"] {
            case "h264": e.videoCodec = .h264
            case "x264": e.videoCodec = .x264
            case "x265": e.videoCodec = .x265
            case "copy": e.videoCodec = .copy
            default: break
            }
            switch kv["preset"] { case "fast": e.preset = .fast; case "small": e.preset = .small; default: break }
            if let c = kv["crf"], let v = Double(c) { e.crf = v }
            if let q = kv["q"], let v = Double(q) { e.quality = v }
            if let b = kv["br"], let v = Double(b) { e.rateMode = .bitrate; e.bitrate = v }
            switch kv["res"] {
            case "largest": e.resolution = .largest
            case "smallest": e.resolution = .smallest
            case let r?: if let v = Int(r), let res = EncodeSettings.Resolution(rawValue: v) { e.resolution = res }
            default: break
            }
            if kv["fit"] == "crop" { e.fit = .crop }
            if let f = kv["fps"], let v = Double(f), let r = EncodeSettings.FrameRate(rawValue: v) { e.frameRate = r }
            e.tenBit = kv["tenbit"] == "1"
            switch kv["deint"] { case "off": e.deinterlace = .off; case "on": e.deinterlace = .on; default: break }
            switch kv["audio"] { case "copy": e.audioCodec = .copy; case "none": e.audioCodec = .none; default: break }
            if let b = kv["abr"], let v = Int(b) { e.audioBitrate = v }
            switch kv["ch"] { case "mono": e.channels = .mono; case "source": e.channels = .source; default: break }
            e.normalizeLoudness = kv["loud"] == "1"
            switch kv["cont"] { case "mkv": e.container = .mkv; case "mov": e.container = .mov; default: break }
            if kv["group"] == "joined" { e.grouping = .joined }
            model.encode = e
            for s in model.sources {
                let start = min(s.duration * 0.3, max(0, s.duration - len))
                model.clips.append(Clip(url: s.url, start: start, end: min(s.duration, start + len)))
            }
            if let g = kv["gain"], let v = Double(g), let first = model.clips.first { model.setGain(first.id, v) }
            // tracks=2 · tracks=1,2 · tracks=none (1부터). 구간마다 다르게: tracks=2/1,2 (슬래시로 구간 순서대로)
            if let t = kv["tracks"] {
                let per = t.split(separator: "/").map(String.init)
                for i in model.clips.indices {
                    let spec = per[min(i, per.count - 1)]
                    model.clips[i].audioTracks = spec == "none" ? [] : spec.split(separator: ",").compactMap { Int($0).map { $0 - 1 } }
                }
            }
            // CPU 제한은 앱 설정 값을 잠깐 바꿨다가 되돌린다
            let oldCPU = UserDefaults.standard.object(forKey: "cpuLimit")
            if let c = kv["cpu"], let v = Double(c) { UserDefaults.standard.set(v, forKey: "cpuLimit") }
            model.updateEstimate()
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { t2 in
                guard !model.estimating else { return }
                t2.invalidate()
                let estimate = model.estimate
                var before = rusage()
                getrusage(RUSAGE_CHILDREN, &before)
                model.startEncode(folder: out, template: "\(name)_{번호}")
                if kv["bg"] == "1" { model.job?.lowPriority = true }
                Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { t3 in
                    guard let job = model.job, job.state != .running else { return }
                    t3.invalidate()
                    var after = rusage()
                    getrusage(RUSAGE_CHILDREN, &after)
                    func sec(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
                    let cpu = sec(after.ru_utime) - sec(before.ru_utime) + sec(after.ru_stime) - sec(before.ru_stime)
                    if let oldCPU { UserDefaults.standard.set(oldCPU, forKey: "cpuLimit") } else { UserDefaults.standard.removeObject(forKey: "cpuLimit") }
                    let state: String = switch job.state {
                    case .finished: "ok"
                    case .cancelled: "cancelled"
                    case .failed(let m): "FAIL: " + m.replacingOccurrences(of: "\n", with: " / ")
                    case .running: "running"
                    }
                    let media = model.clips.reduce(0) { $0 + $1.length }
                    let line = [name, state, String(format: "%.2f", job.elapsed), String(format: "%.1fx", media / max(0.01, job.elapsed)),
                                "\(job.bytes)", estimate.map(String.init) ?? "-", String(format: "%.1f", cpu / max(0.01, job.elapsed)),
                                job.outputs.map(\.url.lastPathComponent).joined(separator: ","), job.notes.joined(separator: " / "),
                                job.outputs.first.map { $0.args.joined(separator: " ") } ?? ""].joined(separator: "\t")
                    let report = out.appendingPathComponent("report.tsv")
                    if !FileManager.default.fileExists(atPath: report.path) {
                        try? "이름\t결과\t걸린초\t속도(실시간 배)\t크기\t예상크기\t평균CPU코어\t파일\t알림\t첫 명령\n".write(to: report, atomically: true, encoding: .utf8)
                    }
                    if let h = try? FileHandle(forWritingTo: report) { h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.close() }
                    exit(0)
                }
            }
        }
    }
}
