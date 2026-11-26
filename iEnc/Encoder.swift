import AppKit
import Foundation
import Observation

/// 변환에 필요한 원본 정보 (해상도·화소 비율·프레임률·인터레이스·소리·자막·비트레이트)
struct SourceMeta {
    var width = 0
    var height = 0
    /// 화소 가로세로 비율 (1 = 정사각)
    var sar = 1.0
    var fps = 0.0
    var hasAudio = false
    var bitRate = 0.0
    /// 자막 스트림 코덱 이름들
    var subtitles: [String] = []

    /// 폰 영상 회전 표시 (시계 방향 0·90·180·270)
    var rotation = 0

    /// 화면에 보이는 크기 (화소 비율·회전 반영)
    var displayWidth: Double { rotation % 180 == 0 ? Double(width) * sar : Double(height) }
    var displayHeight: Double { rotation % 180 == 0 ? Double(height) : Double(width) * sar }

    static func probe(_ url: URL) -> SourceMeta {
        var m = SourceMeta()
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&fmt, url.path, nil, nil) == 0, let ctx = fmt else { return m }
        defer { avformat_close_input(&fmt) }
        avformat_find_stream_info(ctx, nil)
        m.bitRate = Double(ctx.pointee.bit_rate)
        let v = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        if v >= 0, let st = ctx.pointee.streams[Int(v)], let par = st.pointee.codecpar {
            m.width = Int(par.pointee.width)
            m.height = Int(par.pointee.height)
            let sar = par.pointee.sample_aspect_ratio
            if sar.num > 0 && sar.den > 0 { m.sar = Double(sar.num) / Double(sar.den) }
            let r = st.pointee.avg_frame_rate.num > 0 ? st.pointee.avg_frame_rate : st.pointee.r_frame_rate
            if r.den > 0 { m.fps = Double(r.num) / Double(r.den) }
            if let sd = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX) {
                let angle = av_display_rotation_get(UnsafeRawPointer(sd.pointee.data).assumingMemoryBound(to: Int32.self))
                if !angle.isNaN { m.rotation = ((Int((-angle).rounded()) % 360) + 360) % 360 }
            }
        }
        m.hasAudio = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0) >= 0
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let par = ctx.pointee.streams[i]?.pointee.codecpar, par.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            m.subtitles.append(String(cString: avcodec_get_name(par.pointee.codec_id)))
        }
        return m
    }
}

/// 설정 + 구간 → ffmpeg 명령 (만들 파일마다 하나)
enum EncodePlan {
    /// 앱 설정의 CPU 사용량 (1 = 전부, 0.5 = 절반…). 디코딩·필터 스레드 수를 줄이고 실행 우선순위를 낮춘다.
    /// 인코딩은 VideoToolbox 미디어 엔진(전용 하드웨어)이라 이 값과 상관없다
    static var cpuLimit: Double {
        let v = UserDefaults.standard.double(forKey: "cpuLimit")
        return v > 0 ? v : 1
    }

    static func threadArgs() -> [String] {
        guard cpuLimit < 1 else { return [] }
        let n = max(1, Int((Double(ProcessInfo.processInfo.activeProcessorCount) * cpuLimit).rounded()))
        return ["-threads", "\(n)", "-filter_threads", "\(n)", "-filter_complex_threads", "\(n)"]
    }

    struct Output {
        var url: URL
        var args: [String]
        /// 이 파일의 길이 (진행률 계산)
        var duration: Double
        var notes: [String] = []
        /// 끝나면 지울 임시 파일 (구간 목록 등)
        var temp: [URL] = []
    }

    /// 화질·크기에 관계된 영상 인코더 인자 (변환과 크기 어림에 같이 쓴다)
    static func videoCodecArgs(_ e: EncodeSettings) -> [String] {
        var a: [String] = []
        switch e.videoCodec {
        case .copy: return ["-c:v", "copy"]
        case .hevc:
            a = ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1"]
            if e.tenBit { a += ["-profile:v", "main10"] }
        case .h264:
            a = ["-c:v", "h264_videotoolbox", "-profile:v", "high"]
        }
        if e.rateMode == .quality {
            a += ["-q:v", "\(Int(e.quality))"]
        } else {
            a += ["-b:v", String(format: "%.0fk", e.bitrate * 1000)]
        }
        return a
    }

    static func audioCodecArgs(_ e: EncodeSettings) -> [String] {
        switch e.audioCodec {
        case .none: return ["-an"]
        case .copy: return ["-c:a", "copy"]
        case .aac:
            var a = ["-c:a", "aac", "-b:a", "\(e.audioBitrate)k"]
            if e.channels == .stereo { a += ["-ac", "2"] } else if e.channels == .mono { a += ["-ac", "1"] }
            return a
        }
    }

    static func ext(_ e: EncodeSettings) -> String { e.container.rawValue.lowercased() }

    static func containerArgs(_ e: EncodeSettings) -> [String] {
        var a: [String] = []
        if e.container != .mkv { a += ["-movflags", "+faststart"] }
        if !e.keepMetadata { a += ["-map_metadata", "-1"] }
        return a
    }

    /// 짝수로 (영상 인코더는 홀수 크기를 못 받는다)
    static func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

    /// 구간 하나의 영상 필터 (구간마다 파일 하나일 때)
    static func videoFilter(_ e: EncodeSettings, meta: SourceMeta, all: [SourceMeta]) -> String? {
        var f: [String] = []
        switch e.deinterlace {
        case .auto: f.append("bwdif=mode=send_frame:deint=interlaced")  // 인터레이스 표시가 있는 프레임만
        case .on: f.append("bwdif=mode=send_frame:deint=all")
        case .off: break
        }
        let targetH: Int? = switch e.resolution {
        case .source: nil
        case .largest: all.map(\.height).max()
        case .smallest: all.map(\.height).filter { $0 > 0 }.min()
        default: e.resolution.rawValue
        }
        if let h = targetH, h != meta.height { f.append("scale=-2:\(h)") }
        if e.frameRate != .source { f.append("fps=\(e.frameRate.rawValue)") }
        f.append(e.tenBit && e.videoCodec == .hevc ? "format=p010le" : "format=yuv420p")
        return f.joined(separator: ",")
    }

    /// 한 파일로 합칠 때 출력 화면 크기. 가로세로 비율은 타임라인 첫 구간을 따르고(세로 폰 영상이 섞여도 첫 구간이 가로면 가로),
    /// 크기는 해상도 설정으로: 원본·가장 큰 것 = 가장 큰 화면 넓이, 가장 작은 것 = 가장 작은 넓이, 1080p 등 = 짧은 변
    static func joinedSize(_ e: EncodeSettings, metas: [SourceMeta]) -> (Int, Int) {
        let valid = metas.filter { $0.height > 0 }
        guard let first = valid.first else { return (1280, 720) }
        let aspect = first.displayWidth / first.displayHeight
        let areas = valid.map { $0.displayWidth * $0.displayHeight }
        func fromArea(_ area: Double) -> (Int, Int) {
            let w = (area * aspect).squareRoot()
            return (even(w), even(w / aspect))
        }
        switch e.resolution {
        case .smallest: return fromArea(areas.min()!)
        case .source, .largest: return fromArea(areas.max()!)
        default:
            let short = Double(e.resolution.rawValue)
            return aspect >= 1 ? (even(short * aspect), even(short)) : (even(short), even(short / aspect))
        }
    }

    /// 출력 파일 이름: 설정의 규칙 + 겹치면 " (2)"
    static func outputURL(folder: URL, name: String, ext: String, taken: inout Set<String>) -> URL {
        var base = name.replacingOccurrences(of: "/", with: "-")
        if base.isEmpty { base = "iEnc" }
        var n = 1
        while true {
            let candidate = n == 1 ? base : "\(base) (\(n))"
            let url = folder.appendingPathComponent(candidate).appendingPathExtension(ext)
            if !taken.contains(url.path) && !FileManager.default.fileExists(atPath: url.path) {
                taken.insert(url.path)
                return url
            }
            n += 1
        }
    }

    static func make(clips: [Clip], settings e: EncodeSettings, metas: [URL: SourceMeta], folder: (URL) -> URL, template: String) -> [Output] {
        var taken = Set<String>()
        let all = clips.compactMap { metas[$0.url] }
        if e.grouping == .perClip {
            return clips.enumerated().map { i, clip in
                let meta = metas[clip.url] ?? SourceMeta()
                let name = FileNameTemplate.render(template, name: clip.url.deletingPathExtension().lastPathComponent, number: i + 1, start: clip.start)
                let out = outputURL(folder: folder(clip.url), name: name, ext: ext(e), taken: &taken)
                return perClip(clip, meta: meta, all: all, settings: e, output: out)
            }
        }
        guard let first = clips.first else { return [] }
        let name = FileNameTemplate.render(template, name: first.url.deletingPathExtension().lastPathComponent, number: 1, start: first.start)
        let out = outputURL(folder: folder(first.url), name: name, ext: ext(e), taken: &taken)
        if e.videoCodec == .copy { return [joinedCopy(clips, settings: e, output: out)] }
        return [joined(clips, metas: metas, settings: e, output: out)]
    }

    static func perClip(_ clip: Clip, meta: SourceMeta, all: [SourceMeta], settings e: EncodeSettings, output: URL) -> Output {
        var notes: [String] = []
        // 영상은 다시 압축하고 소리만 그대로 복사하면, 입력 쪽 탐색(-ss)이 복사하는 소리를 앞 키프레임부터 가져와
        // 앞에 몇 초가 더 붙는다 → 조금 앞에서 입력 탐색하고 나머지는 출력 쪽 -ss 로 정확히 잘라 낸다
        let mixedCopy = e.videoCodec != .copy && e.audioCodec == .copy && meta.hasAudio
        let pre = mixedCopy ? min(clip.start, 3) : 0
        var a = ["-hide_banner", "-nostdin", "-y"] + threadArgs() + [
                 "-ss", String(format: "%.3f", clip.start - pre)]
        if !mixedCopy { a += ["-t", String(format: "%.3f", clip.length)] }
        a += ["-i", clip.url.path]
        if mixedCopy { a += ["-ss", String(format: "%.3f", pre), "-t", String(format: "%.3f", clip.length)] }
        a += ["-map", "0:v:0"]
        if e.audioCodec != .none && meta.hasAudio { a += ["-map", "0:a:0"] }
        // 자막: MKV 는 그대로, MP4·MOV 는 글자 자막만 mov_text 로 (그림 자막은 못 넣음)
        if e.keepSubtitles && !meta.subtitles.isEmpty {
            if e.container == .mkv {
                a += ["-map", "0:s?", "-c:s", "copy"]
            } else if meta.subtitles.contains(where: { ["subrip", "ass", "ssa", "mov_text", "webvtt", "text"].contains($0) }) {
                for (i, s) in meta.subtitles.enumerated() where ["subrip", "ass", "ssa", "mov_text", "webvtt", "text"].contains(s) {
                    a += ["-map", "0:s:\(i)"]
                }
                a += ["-c:s", "mov_text"]
            } else {
                notes.append("그림 자막은 \(e.container.rawValue) 에 넣을 수 없어 뺐습니다")
            }
        }
        if e.videoCodec != .copy, let vf = videoFilter(e, meta: meta, all: all) { a += ["-vf", vf] }
        a += videoCodecArgs(e)
        if e.audioCodec == .aac && meta.hasAudio {
            var af: [String] = []
            if clip.gain != 0 { af.append(String(format: "volume=%.1fdB", clip.gain)) }
            if e.normalizeLoudness { af.append("loudnorm=I=-16:TP=-1.5:LRA=11") }
            if !af.isEmpty { a += ["-af", af.joined(separator: ",")] }
        } else if e.audioCodec == .copy && clip.gain != 0 {
            notes.append("소리 '원본 그대로' 라 구간 음량(\(String(format: "%+.1f", clip.gain)) dB)은 적용하지 않았습니다")
        }
        a += audioCodecArgs(e)
        a += containerArgs(e)
        a += ["-progress", "pipe:1", "-nostats", "-loglevel", "error", output.path]
        return Output(url: output, args: a, duration: clip.length, notes: notes)
    }

    /// 다시 압축해 한 파일로: 구간마다 크기·비율·프레임률을 맞춘 뒤 concat 필터로 잇는다
    static func joined(_ clips: [Clip], metas: [URL: SourceMeta], settings e: EncodeSettings, output: URL) -> Output {
        let (w, h) = joinedSize(e, metas: clips.compactMap { metas[$0.url] })
        let fpsList = clips.compactMap { metas[$0.url]?.fps }.filter { $0 > 0 }
        let fps: Double = e.frameRate != .source ? e.frameRate.rawValue : (fpsList.max() ?? 30)
        let withAudio = e.audioCodec != .none
        let channels = e.channels == .mono ? "mono" : "stereo"
        var a = ["-hide_banner", "-nostdin", "-y"] + threadArgs()
        // 합칠 땐 ffmpeg 자동 회전이 필터 그래프에 안 들어가서, 끄고 직접 돌린다
        for c in clips {
            a += ["-noautorotate", "-ss", String(format: "%.3f", c.start), "-t", String(format: "%.3f", c.length), "-i", c.url.path]
        }
        var graph: [String] = []
        var concatIn = ""
        for (i, c) in clips.enumerated() {
            let meta = metas[c.url] ?? SourceMeta()
            var v: [String] = []
            switch e.deinterlace {
            case .auto: v.append("bwdif=mode=send_frame:deint=interlaced")
            case .on: v.append("bwdif=mode=send_frame:deint=all")
            case .off: break
            }
            switch meta.rotation {
            case 90: v.append("transpose=clock")
            case 180: v.append("hflip,vflip")
            case 270: v.append("transpose=cclock")
            default: break
            }
            if abs(meta.sar - 1) > 0.001 { v.append("scale=trunc(iw*sar/2)*2:ih") }
            v.append("setsar=1")
            if e.fit == .letterbox {
                v.append("scale=\(w):\(h):force_original_aspect_ratio=decrease")
                v.append("pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2")
            } else {
                v.append("scale=\(w):\(h):force_original_aspect_ratio=increase")
                v.append("crop=\(w):\(h)")
            }
            v.append("setsar=1")
            v.append(String(format: "fps=%.3f", fps))
            v.append(e.tenBit && e.videoCodec == .hevc ? "format=p010le" : "format=yuv420p")
            graph.append("[\(i):v:0]\(v.joined(separator: ","))[v\(i)]")
            if withAudio {
                var af = ["aresample=48000", "aformat=sample_fmts=fltp:channel_layouts=\(channels)"]
                if c.gain != 0 { af.append(String(format: "volume=%.1fdB", c.gain)) }
                if meta.hasAudio {
                    graph.append("[\(i):a:0]\(af.joined(separator: ","))[a\(i)]")
                } else {
                    // 소리 없는 구간은 그 길이만큼 무음
                    graph.append("anullsrc=r=48000:cl=\(channels),atrim=duration=\(String(format: "%.3f", c.length))[a\(i)]")
                }
                concatIn += "[v\(i)][a\(i)]"
            } else {
                concatIn += "[v\(i)]"
            }
        }
        graph.append("\(concatIn)concat=n=\(clips.count):v=1:a=\(withAudio ? 1 : 0)[v]" + (withAudio ? "[a]" : ""))
        var audioLabel = "[a]"
        if withAudio && e.normalizeLoudness {
            graph.append("[a]loudnorm=I=-16:TP=-1.5:LRA=11[an]")
            audioLabel = "[an]"
        }
        a += ["-filter_complex", graph.joined(separator: ";"), "-map", "[v]"]
        if withAudio { a += ["-map", audioLabel] }
        a += videoCodecArgs(e)
        if withAudio {
            // 합칠 땐 소리를 늘 다시 압축 (구간마다 형식이 다를 수 있어서)
            a += ["-c:a", "aac", "-b:a", "\(e.audioBitrate)k"]
        }
        a += containerArgs(e)
        a += ["-progress", "pipe:1", "-nostats", "-loglevel", "error", output.path]
        var notes: [String] = []
        if e.audioCodec == .copy { notes.append("한 파일로 합칠 땐 소리를 AAC 로 다시 압축합니다") }
        if e.keepSubtitles { notes.append("한 파일로 합칠 땐 자막을 넣지 않습니다") }
        return Output(url: output, args: a, duration: clips.reduce(0) { $0 + $1.length }, notes: notes)
    }

    /// 원본 그대로 한 파일로: concat 디먹서 (같은 형식 영상끼리만 됨, 구간 시작은 키프레임에 맞춰짐)
    static func joinedCopy(_ clips: [Clip], settings e: EncodeSettings, output: URL) -> Output {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("iEnc-concat-\(UUID().uuidString).txt")
        let text = clips.map { c in
            "file '\(c.url.path.replacingOccurrences(of: "'", with: "'\\''"))'\ninpoint \(String(format: "%.3f", c.start))\noutpoint \(String(format: "%.3f", c.end))"
        }.joined(separator: "\n")
        try? text.write(to: list, atomically: true, encoding: .utf8)
        var a = ["-hide_banner", "-nostdin", "-y"] + threadArgs() + ["-f", "concat", "-safe", "0", "-i", list.path, "-map", "0:v:0"]
        if e.audioCodec != .none { a += ["-map", "0:a:0?"] }
        a += ["-c:v", "copy"]
        a += e.audioCodec == .none ? ["-an"] : (e.audioCodec == .copy ? ["-c:a", "copy"] : audioCodecArgs(e))
        a += containerArgs(e)
        a += ["-progress", "pipe:1", "-nostats", "-loglevel", "error", output.path]
        var notes = ["원본 그대로 합치기는 같은 코덱·해상도 영상끼리만 됩니다"]
        if clips.contains(where: { $0.gain != 0 }) && e.audioCodec == .copy { notes.append("소리 '원본 그대로' 라 구간 음량은 적용하지 않았습니다") }
        return Output(url: output, args: a, duration: clips.reduce(0) { $0 + $1.length }, notes: notes, temp: [list])
    }
}

/// 변환 실행: 만들 파일을 차례로 ffmpeg 로 만들며 진행률·시간·크기를 알린다. 취소하면 만들던 파일은 지운다
@Observable
final class EncodeJob {
    enum State: Equatable { case running, finished, cancelled, failed(String) }

    let outputs: [EncodePlan.Output]
    let totalDuration: Double
    var state = State.running
    /// 0~1
    var progress = 0.0
    var fileIndex = 0
    var elapsed = 0.0
    var remaining: Double?
    /// 지금까지 만든 크기 (끝난 파일 + 만드는 중인 파일)
    var bytes: Int64 = 0
    var estimatedBytes: Int64?
    var notes: [String]
    var speed = ""

    private var process: Process?
    private var doneDuration = 0.0
    private var doneBytes: Int64 = 0
    private var started = Date()
    private var timer: Timer?

    static var ffmpegURL: URL? { Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") }

    init(outputs: [EncodePlan.Output]) {
        self.outputs = outputs
        totalDuration = outputs.reduce(0) { $0 + $1.duration }
        notes = Array(Set(outputs.flatMap(\.notes))).sorted()
    }

    var producedFiles: [URL] { Array(outputs.prefix(state == .finished ? outputs.count : fileIndex).map(\.url)) }

    func start() {
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        runNext()
    }

    func cancel() {
        guard state == .running else { return }
        state = .cancelled
        process?.terminate()
        stop()
    }

    private func tick() {
        guard state == .running else { return }
        elapsed = Date().timeIntervalSince(started)
        if progress > 0.02 {
            remaining = max(0, elapsed / progress - elapsed)
            estimatedBytes = Int64(Double(bytes) / progress)
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        elapsed = Date().timeIntervalSince(started)
        for o in outputs { for t in o.temp { try? FileManager.default.removeItem(at: t) } }
    }

    private func runNext() {
        guard state == .running else { return }
        guard fileIndex < outputs.count else {
            progress = 1
            remaining = 0
            state = .finished
            stop()
            return
        }
        guard let ffmpeg = Self.ffmpegURL else { fail("앱 안에 ffmpeg 가 없습니다"); return }
        let out = outputs[fileIndex]
        try? FileManager.default.createDirectory(at: out.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = out.args
        // CPU 를 덜 쓰게 했으면 우선순위도 낮춘다 (다른 앱이 먼저)
        if EncodePlan.cpuLimit < 1 { p.qualityOfService = .utility }
        let pipe = Pipe(), errPipe = Pipe()
        p.standardOutput = pipe
        p.standardError = errPipe
        var buffer = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                buffer += text
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<nl])
                    buffer.removeSubrange(...nl)
                    self?.progressLine(line, output: out)
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.finished(proc.terminationStatus, error: err, output: out) }
        }
        do {
            try p.run()
            process = p
        } catch {
            fail("ffmpeg 를 실행하지 못함: \(error.localizedDescription)")
        }
    }

    private func progressLine(_ line: String, output: EncodePlan.Output) {
        guard state == .running else { return }
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "out_time_us":
            if let us = Double(parts[1]), totalDuration > 0 {
                let t = min(output.duration, max(0, us / 1_000_000))
                progress = min(1, (doneDuration + t) / totalDuration)
            }
        case "total_size":
            if let b = Int64(parts[1]) { bytes = doneBytes + b }
        case "speed":
            speed = parts[1].trimmingCharacters(in: .whitespaces)
        default: break
        }
    }

    private func finished(_ status: Int32, error: String, output: EncodePlan.Output) {
        guard state == .running else {
            // 취소: 만들던 파일 지움
            try? FileManager.default.removeItem(at: output.url)
            return
        }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: output.url)
            let last = error.split(separator: "\n").suffix(3).joined(separator: "\n")
            fail("\(output.url.lastPathComponent): \(last.isEmpty ? "ffmpeg 오류 \(status)" : last)")
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.url.path)[.size] as? Int64) ?? 0
        doneBytes += size ?? 0
        bytes = doneBytes
        doneDuration += output.duration
        fileIndex += 1
        runNext()
    }

    private func fail(_ message: String) {
        state = .failed(message)
        stop()
    }
}

/// 변환 전 예상 크기
enum SizeEstimate {
    /// 비트레이트 지정·원본 그대로는 계산, 품질 기준은 짧은 조각을 시험 인코딩해 어림 (몇 초)
    static func estimate(clips: [Clip], settings e: EncodeSettings, metas: [URL: SourceMeta], completion: @escaping (Int64?) -> Void) {
        let total = clips.reduce(0) { $0 + $1.length }
        guard total > 0 else { completion(nil); return }
        let audioBps: Double = switch e.audioCodec {
        case .none: 0
        case .aac: Double(e.audioBitrate) * 1000
        case .copy: 192_000  // 원본 소리 비트레이트를 따로 모르면 대략
        }
        switch (e.videoCodec, e.rateMode) {
        case (.copy, _):
            let bytes = clips.reduce(0.0) { sum, c in
                let rate = metas[c.url]?.bitRate ?? 0
                return sum + (rate > 0 ? rate : 4_000_000) / 8 * c.length
            }
            completion(Int64(bytes))
        case (_, .bitrate):
            completion(Int64((e.bitrate * 1_000_000 + audioBps) / 8 * total))
        case (_, .quality):
            sampleVideoRate(clips: clips, settings: e, metas: metas) { videoBps in
                guard let videoBps else { completion(nil); return }
                completion(Int64((videoBps + audioBps) / 8 * total))
            }
        }
    }

    /// 구간들에서 고르게 3초짜리 조각 최대 4개를 영상만 인코딩해 초당 비트 수를 잰다
    private static func sampleVideoRate(clips: [Clip], settings e: EncodeSettings, metas: [URL: SourceMeta], completion: @escaping (Double?) -> Void) {
        guard let ffmpeg = EncodeJob.ffmpegURL else { completion(nil); return }
        let total = clips.reduce(0) { $0 + $1.length }
        let count = min(4, max(1, Int(total / 10)))
        // 이어 붙인 시간에서 고르게 뽑은 자리 → (구간, 그 안의 시각)
        var picks: [(Clip, Double)] = []
        for k in 0..<count {
            var t = total * (Double(k) + 0.5) / Double(count)
            for c in clips {
                if t <= c.length { picks.append((c, c.start + max(0, min(t, c.length - 3)))); break }
                t -= c.length
            }
        }
        let all = clips.compactMap { metas[$0.url] }
        DispatchQueue.global(qos: .utility).async {
            var bits = 0.0, seconds = 0.0
            for (clip, t) in picks {
                let len = min(3, clip.length)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("iEnc-sample-\(UUID().uuidString).mp4")
                var a = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-ss", String(format: "%.3f", t), "-t", String(format: "%.3f", len), "-i", clip.url.path, "-map", "0:v:0", "-an"]
                var vs = e
                if e.grouping == .joined, vs.resolution == .source { vs.resolution = .largest }
                if let vf = EncodePlan.videoFilter(vs, meta: metas[clip.url] ?? SourceMeta(), all: all) { a += ["-vf", vf] }
                a += EncodePlan.videoCodecArgs(e) + [tmp.path]
                let p = Process()
                p.executableURL = ffmpeg
                p.arguments = a
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { continue }
                p.waitUntilExit()
                if p.terminationStatus == 0, let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size]) as? Int64 {
                    bits += Double(size) * 8
                    seconds += len
                }
                try? FileManager.default.removeItem(at: tmp)
            }
            DispatchQueue.main.async { completion(seconds > 0 ? bits / seconds : nil) }
        }
    }
}

extension FF {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
