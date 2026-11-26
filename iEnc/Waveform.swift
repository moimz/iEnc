import Foundation
import os
import QuartzCore

/// 구간의 소리 파형: 소리만 풀어서(영상은 안 풂) 작은 묶음마다 최댓값(peak)과 평균 세기(RMS)를 모은다.
/// 타임라인 소리 줄에 그린다. 소리가 영상 사이사이에 섞여 있어 결국 파일을 거의 다 읽는다
/// (NAS 의 1.5GB MP4 ≈ 20초) → 푸는 동안 0.3초마다 중간 결과를 넘겨 왼쪽부터 차오르게 그린다.
/// 구간마다 따로(동시에 둘까지) 만든다: 긴 구간 하나가 다른 구간을 막지 않게
struct WavePeaks: Equatable {
    var peak: [Float]
    var rms: [Float]
    /// 다 만들었는지 (false 면 아직 푸는 중, 채워진 앞부분만 그림)
    var done: Bool
    /// 어디까지 채웠는지 (0~1)
    var progress: Double
}

enum Waveform {
    private static let limit = DispatchSemaphore(value: 2)

    /// 묶음 수: 초당 25개 (긴 구간은 최대 20000개)
    static func bucketCount(for length: Double) -> Int { min(20000, max(200, Int(length * 25))) }

    /// update 는 중간 결과와 마지막 결과(done = true)를 메인 스레드로 여러 번 받는다. false 를 돌려주면 그만 만든다
    static func make(url: URL, start: Double, end: Double, update: @escaping (WavePeaks?) -> Bool) {
        DispatchQueue.global(qos: .utility).async {
            limit.wait()
            defer { limit.signal() }
            let keep = OSAllocatedUnfairLock(initialState: true)
            let result = compute(url: url, start: start, end: end) { partial in
                DispatchQueue.main.async { if !update(partial) { keep.withLock { $0 = false } } }
                return keep.withLock { $0 }
            }
            DispatchQueue.main.async { _ = update(result) }
        }
    }

    private static func compute(url: URL, start: Double, end: Double, partial: (WavePeaks) -> Bool) -> WavePeaks? {
        let length = end - start
        guard length > 0 else { return nil }
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&fmt, url.path, nil, nil) == 0, let ctx = fmt else { return nil }
        defer { avformat_close_input(&fmt) }
        avformat_find_stream_info(ctx, nil)
        let index = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard index >= 0, let st = ctx.pointee.streams[Int(index)], let par = st.pointee.codecpar,
              let codec = avcodec_find_decoder(par.pointee.codec_id) else {
            return WavePeaks(peak: [], rms: [], done: true, progress: 1)  // 소리 없음 = 빈 파형
        }
        // 소리 스트림만 읽게 나머지는 버린다
        for i in 0..<Int(ctx.pointee.nb_streams) where i != Int(index) {
            ctx.pointee.streams[i]?.pointee.discard = AVDISCARD_ALL
        }
        var dec = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&dec) }
        guard let c = dec else { return nil }
        avcodec_parameters_to_context(c, par)
        c.pointee.pkt_timebase = st.pointee.time_base
        guard avcodec_open2(c, codec, nil) == 0 else { return nil }

        let offset = ctx.pointee.start_time != ienc_nopts() ? Double(ctx.pointee.start_time) / Double(AV_TIME_BASE) : 0
        let tb = av_q2d(st.pointee.time_base)
        // 시작 조금 앞으로 (실패하면 처음부터 읽으며 건너뜀: 색인 없는 FLV·RM)
        av_seek_frame(ctx, -1, Int64((start + offset - 0.5) * Double(AV_TIME_BASE)), AVSEEK_FLAG_BACKWARD)

        let count = bucketCount(for: length)
        var peaks = [Float](repeating: 0, count: count)
        var squares = [Double](repeating: 0, count: count)
        var samples = [Int](repeating: 0, count: count)
        func snapshot(done: Bool) -> WavePeaks {
            let rms = (0..<count).map { samples[$0] > 0 ? Float((squares[$0] / Double(samples[$0])).squareRoot()) : 0 }
            return WavePeaks(peak: peaks.map { min(1, $0) }, rms: rms.map { min(1, $0) }, done: done,
                             progress: done ? 1 : max(0, min(1, (lastTime - start) / length)))
        }
        var lastSent = CACurrentMediaTime()
        var pkt = av_packet_alloc()
        var frame = av_frame_alloc()
        var swr: OpaquePointer?
        var swrKey = ""
        defer { av_packet_free(&pkt); av_frame_free(&frame); swr_free(&swr) }
        var mono = [Float]()
        var done = false
        var lastTime = start

        func take(_ f: UnsafeMutablePointer<AVFrame>) {
            let rate = Int(f.pointee.sample_rate)
            let n = Int(f.pointee.nb_samples)
            guard rate > 0, n > 0 else { return }
            let pts = f.pointee.best_effort_timestamp
            let t0 = pts != ienc_nopts() ? Double(pts) * tb - offset : lastTime
            lastTime = t0 + Double(n) / Double(rate)
            if t0 > end { done = true; return }
            if lastTime < start { return }
            // 모노 float 로 (여러 채널은 섞음)
            let key = "\(rate)/\(f.pointee.format)/\(f.pointee.ch_layout.nb_channels)/\(f.pointee.ch_layout.u.mask)"
            if key != swrKey {
                swr_free(&swr)
                var outLayout = AVChannelLayout()
                av_channel_layout_default(&outLayout, 1)
                var inLayout = f.pointee.ch_layout
                guard swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_FLT, f.pointee.sample_rate, &inLayout,
                                          AVSampleFormat(rawValue: f.pointee.format), f.pointee.sample_rate, 0, nil) == 0,
                      swr_init(swr) == 0 else { swr_free(&swr); swrKey = ""; return }
                swrKey = key
            }
            let capacity = Int(swr_get_out_samples(swr, f.pointee.nb_samples))
            if mono.count < capacity { mono = [Float](repeating: 0, count: capacity) }
            let got: Int32 = mono.withUnsafeMutableBytes { buf in
                var out: UnsafeMutablePointer<UInt8>? = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                let input = UnsafeRawPointer(f.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                return withUnsafeMutablePointer(to: &out) { swr_convert(swr, $0, Int32(capacity), input, f.pointee.nb_samples) }
            }
            guard got > 0 else { return }
            let scale = Double(count) / length
            let step = 1.0 / Double(rate)
            for i in 0..<Int(got) {
                let t = t0 + Double(i) * step
                guard t >= start, t < end else { continue }
                let b = min(count - 1, Int((t - start) * scale))
                let x = mono[i]
                let v = abs(x)
                if v > peaks[b] { peaks[b] = v }
                squares[b] += Double(x * x)
                samples[b] += 1
            }
        }

        while !done, av_read_frame(ctx, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt!.pointee.stream_index == index else { continue }
            guard avcodec_send_packet(c, pkt) >= 0 else { continue }
            while !done, avcodec_receive_frame(c, frame) == 0 { take(frame!) }
            if CACurrentMediaTime() - lastSent > 0.3 {
                lastSent = CACurrentMediaTime()
                if !partial(snapshot(done: false)) { return nil }
            }
        }
        return snapshot(done: true)
    }
}
