import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import os

/// B안 미리보기 엔진: libavformat·libavcodec 으로 직접 풀어 AVSampleBuffer 렌더러에 넘긴다.
/// - 멈춤 상태의 탐색은 프레임 단위로 정확하게: 직전 키프레임으로 간 뒤 목표 프레임까지 푼다.
/// - 재생은 영상·소리를 AVSampleBufferRenderSynchronizer 하나의 시계에 맞춘다.
/// 모든 FFmpeg 호출은 직렬 큐 하나(queue)에서만 한다.
final class PreviewEngine: @unchecked Sendable {
    /// 화면 아래·정보 칸에 보이는 진단 값
    struct Stats {
        var decoder = "-"
        var openMs = 0.0
        var lastSeek = "-"
        var seekCount = 0
        var seekTotalMs = 0.0
        var seekMaxMs = 0.0
        var playback = "-"
        var errors: [String] = []
    }

    let url: URL
    private(set) var duration: Double = 0
    private(set) var frameDuration: Double = 1.0 / 30
    /// 화면에서 시계 방향으로 돌려 보여야 하는 각도 (0·90·180·270)
    private(set) var rotation: Double = 0
    private(set) var hasVideo = false
    private(set) var hasAudio = false

    private let renderer: AVSampleBufferVideoRenderer
    private let audioRenderer: AVSampleBufferAudioRenderer
    private let sync: AVSampleBufferRenderSynchronizer
    private let queue = DispatchQueue(label: "com.moimz.iEnc.decode", qos: .userInitiated)
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    private var fmt: UnsafeMutablePointer<AVFormatContext>?
    private var vIndex: Int32 = -1
    private var aIndex: Int32 = -1
    private var vCtx: UnsafeMutablePointer<AVCodecContext>?
    private var aCtx: UnsafeMutablePointer<AVCodecContext>?
    private var vTB = AVRational(num: 1, den: 1)
    private var aTB = AVRational(num: 1, den: 1)
    private var startOffset = 0.0
    private var useHardware: Bool

    private var pkt = av_packet_alloc()
    private var frame = av_frame_alloc()
    private var held = av_frame_alloc()
    private var sws: UnsafeMutablePointer<SwsContext>?
    private var swsKey = ""
    private var pool: CVPixelBufferPool?
    private var poolKey = ""
    private var swr: OpaquePointer?
    private var swrKey = ""
    private var audioFormat: CMAudioFormatDescription?
    private var audioFormatRate: Int32 = 0

    /// 마지막으로 푼 영상 프레임 시각 (빠른 전진 판단용). 디코더를 비우거나 EOF 를 지나면 nil
    private var decodedUntil: Double?
    private(set) var shownTime: Double = 0
    private var stats = Stats()
    private var statsHandler: ((Stats) -> Void)?
    private var timeHandler: ((Double) -> Void)?

    init(url: URL, renderer: AVSampleBufferVideoRenderer, audioRenderer: AVSampleBufferAudioRenderer, sync: AVSampleBufferRenderSynchronizer, hardware: Bool) {
        self.url = url
        self.renderer = renderer
        self.audioRenderer = audioRenderer
        self.sync = sync
        self.useHardware = hardware
    }

    deinit {
        cacheClear()
        avcodec_free_context(&vCtx)
        avcodec_free_context(&aCtx)
        avformat_close_input(&fmt)
        av_packet_free(&pkt)
        av_frame_free(&frame)
        av_frame_free(&held)
        sws_freeContext(sws)
        swr_free(&swr)
    }

    func onStats(_ handler: @escaping (Stats) -> Void) { statsHandler = handler }
    /// 재생 중이 아닐 때 화면에 보인 프레임의 시각
    func onShown(_ handler: @escaping (Double) -> Void) { timeHandler = handler }

    // MARK: - 열기

    func open(completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            let t0 = CACurrentMediaTime()
            var ctx: UnsafeMutablePointer<AVFormatContext>?
            var r = avformat_open_input(&ctx, url.path, nil, nil)
            guard r == 0, let ctx else { return finish("열지 못함: \(FF.error(r))") }
            fmt = ctx
            r = avformat_find_stream_info(ctx, nil)
            if r < 0 { note("스트림 분석 실패: \(FF.error(r))") }

            startOffset = ctx.pointee.start_time != ienc_nopts() ? Double(ctx.pointee.start_time) / Double(AV_TIME_BASE) : 0
            if ctx.pointee.duration != ienc_nopts() { duration = Double(ctx.pointee.duration) / Double(AV_TIME_BASE) }

            vIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
            aIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, vIndex, nil, 0)
            if vIndex >= 0 { openVideo() }
            if aIndex >= 0 { openAudio() }
            hasVideo = vCtx != nil
            hasAudio = aCtx != nil
            if !hasVideo { return finish("풀 수 있는 영상 스트림이 없음") }
            if duration <= 0, let st = ctx.pointee.streams[Int(vIndex)], st.pointee.duration != ienc_nopts() {
                duration = Double(st.pointee.duration) * av_q2d(st.pointee.time_base)
            }
            stats.openMs = (CACurrentMediaTime() - t0) * 1000
            publish()
            finish(nil)
            showFrame(at: 0, generation: currentGeneration())
        }
        func finish(_ error: String?) {
            DispatchQueue.main.async { completion(error) }
        }
    }

    private func openVideo() {
        guard let st = fmt?.pointee.streams[Int(vIndex)] else { return }
        let par = st.pointee.codecpar
        guard let codec = avcodec_find_decoder(par!.pointee.codec_id) else {
            note("영상 디코더 없음: \(String(cString: avcodec_get_name(par!.pointee.codec_id)))")
            return
        }
        var c = avcodec_alloc_context3(codec)
        avcodec_parameters_to_context(c, par)
        c!.pointee.pkt_timebase = st.pointee.time_base
        c!.pointee.thread_count = 0
        var hw = false
        // 기본은 소프트웨어: 탐색처럼 프레임을 몰아 풀 때 FFmpeg 의 VideoToolbox 경로(프레임마다 기다림)보다 몇 배 빠르다 (2026-11-26 측정).
        // AV1 은 FFmpeg 안에 소프트웨어 디코더가 없어(하드웨어 전용) 늘 VideoToolbox.
        if useHardware || par!.pointee.codec_id == AV_CODEC_ID_AV1 {
            var dev: UnsafeMutablePointer<AVBufferRef>?
            if av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) == 0 {
                c!.pointee.hw_device_ctx = av_buffer_ref(dev)
                av_buffer_unref(&dev)
                ienc_use_hw(c)
                hw = true
            }
        }
        let r = avcodec_open2(c, codec, nil)
        guard r == 0 else {
            note("영상 디코더 열기 실패: \(FF.error(r))")
            avcodec_free_context(&c)
            return
        }
        vCtx = c
        vTB = st.pointee.time_base
        // 폰 영상의 회전 표시 (디스플레이 행렬): 화면에서 시계 방향으로 돌릴 각도
        if let sd = av_packet_side_data_get(par!.pointee.coded_side_data, par!.pointee.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX) {
            let angle = av_display_rotation_get(UnsafeRawPointer(sd.pointee.data).assumingMemoryBound(to: Int32.self))
            if !angle.isNaN { rotation = (-angle).truncatingRemainder(dividingBy: 360) }
        }
        let rate = st.pointee.avg_frame_rate.den > 0 && st.pointee.avg_frame_rate.num > 0 ? st.pointee.avg_frame_rate : st.pointee.r_frame_rate
        if rate.num > 0 && rate.den > 0 { frameDuration = 1 / av_q2d(rate) }
        stats.decoder = "\(String(cString: codec.pointee.name))" + (hw ? " · VideoToolbox 시도" : " · 소프트웨어")
    }

    private func openAudio() {
        guard let st = fmt?.pointee.streams[Int(aIndex)] else { return }
        let par = st.pointee.codecpar
        guard let codec = avcodec_find_decoder(par!.pointee.codec_id) else {
            note("오디오 디코더 없음: \(String(cString: avcodec_get_name(par!.pointee.codec_id)))")
            return
        }
        var c = avcodec_alloc_context3(codec)
        avcodec_parameters_to_context(c, par)
        c!.pointee.pkt_timebase = st.pointee.time_base
        let r = avcodec_open2(c, codec, nil)
        guard r == 0 else {
            note("오디오 디코더 열기 실패: \(FF.error(r))")
            avcodec_free_context(&c)
            return
        }
        aCtx = c
        aTB = st.pointee.time_base
    }

    // MARK: - 멈춤 상태 탐색 (프레임 단위)

    /// 끄는 중에 요청이 몰리면 가장 최근 것만 한다 (앞의 것은 큐에서 건너뜀)
    func seek(to time: Double) {
        let gen = bump()
        queue.async { [self] in
            guard gen == currentGeneration() else { return }
            showFrame(at: time, generation: gen)
        }
    }

    /// 한 프레임 앞·뒤
    func step(_ frames: Int) {
        let gen = bump()
        queue.async { [self] in
            guard gen == currentGeneration() else { return }
            showFrame(at: max(0, shownTime + Double(frames) * frameDuration), generation: gen)
        }
    }

    private func showFrame(at target: Double, generation gen: Int) {
        guard vCtx != nil, let fmt else { return }
        let t0 = CACurrentMediaTime()
        let tol = frameDuration / 2
        var path: String
        var result: Decoded

        // 0) 방금 풀어 둔 프레임 안이면 풀지 않고 바로 (한 프레임 뒤로·조금 뒤로 끌기)
        if let hit = cacheLookup(target) {
            av_frame_unref(held)
            av_frame_ref(held, hit.frame)
            result = Decoded(haveHeld: true, heldTime: hit.time, landed: hit.time, decoded: 0)
            path = "캐시"
        } else if let last = decodedUntil, target > last, target - last < 3 {
            // 1) 앞쪽으로 조금만 가면 되면 탐색 없이 이어서 푼다
            path = "이어 풀기"
            result = decodeUntil(target, generation: gen)
        } else {
            // 2) 직전 키프레임으로 탐색. 데먹서가 목표보다 뒤의 키프레임에 내려 주면(TS·색인 없는 파일 등) 더 앞에서 다시.
            //    다시 갈 때는 전에 풀면서 본 키프레임 중 목표 직전 것으로 (본 것만 기억하므로 처음부터 쓰면 실제보다 먼 키프레임일 수 있다)
            path = "키프레임 탐색"
            var back = 0.0
            var tries = 0
            var how = ""
            while true {
                let at = max(0, target - back)
                let (r, mode) = seekDemuxer(to: at)
                if r < 0 { note("탐색 실패 \(FF.clock(at)): \(FF.error(r))") }
                if !mode.isEmpty { how = " · \(mode)" }
                avcodec_flush_buffers(vCtx)
                decodedUntil = nil
                cacheClear()
                result = decodeUntil(target, generation: gen, needKey: mode == "바이트 위치로")
                guard let landed = result.landed, landed > target + tol, at > 0, back < 60 else { break }
                tries += 1
                // 본 키프레임이 다음 단계(지금의 3배)보다 가까우면 그리로, 아니면 2→6→18초로 넓힌다.
                // (지나친 것은 첫 키프레임 패킷만 보고 바로 알기 때문에 넓혀 가며 다시 해도 싸다)
                if let k = keyTimes.last(where: { $0 <= target + tol }), target - k > back, target - k <= max(2, back * 3) {
                    back = target - k
                    how = " · 본 키프레임으로"
                } else {
                    back = back < 2 ? 2 : back * 3
                }
            }
            path += how + (tries > 0 ? " (더 앞에서 \(tries)번 다시)" : "")
        }

        let ms = (CACurrentMediaTime() - t0) * 1000
        if result.haveHeld {
            displayStill(held!, time: result.heldTime)
            shownTime = result.heldTime
            let off = result.heldTime - target
            let gap = result.aborted ? " (새 요청이 와서 중간에 멈춤)" : abs(off) > frameDuration * 1.5 ? String(format: " (목표와 %.3f초 차이 ⚠️)", off) : ""
            stats.lastSeek = String(format: "%@ · %.1fms · 프레임 %d개 풂 · 시작 %@ → 보인 %@%@",
                                    path, ms, result.decoded, result.landed.map { FF.clock($0) } ?? "-", FF.clock(result.heldTime), gap)
            let shown = result.heldTime
            DispatchQueue.main.async { self.timeHandler?(shown) }
        } else {
            stats.lastSeek = String(format: "%@ · %.1fms · 프레임을 못 얻음 ⚠️", path, ms)
        }
        stats.seekCount += 1
        stats.seekTotalMs += ms
        stats.seekMaxMs = max(stats.seekMaxMs, ms)
        publish()
    }

    /// 데먹서를 at 초 근처(그 이전)로 보낸다. 시각 탐색이 안 되는 형식(FLV·RM 의 색인 없는 파일)은
    /// 바이트 위치로 어림해 가고, 맨 앞이면 파일을 다시 연다. 돌려주는 글은 어떤 방법을 썼는지 (보통 탐색이면 빈 글)
    private func seekDemuxer(to at: Double) -> (Int32, String) {
        guard let fmt else { return (-1, "") }
        var r = av_seek_frame(fmt, vIndex, Int64(((at + startOffset) / av_q2d(vTB)).rounded(.down)), AVSEEK_FLAG_BACKWARD)
        if r >= 0 { return (r, "") }
        r = av_seek_frame(fmt, -1, Int64((at + startOffset) * Double(AV_TIME_BASE)), AVSEEK_FLAG_BACKWARD)
        if r >= 0 { return (r, "") }
        let size = avio_size(fmt.pointee.pb)
        if at > 0.5, duration > 0, size > 0 {
            let pos = Int64(Double(size) * min(1, at / duration))
            r = av_seek_frame(fmt, -1, pos, AVSEEK_FLAG_BYTE)
            if r >= 0 { return (r, "바이트 위치로") }
        }
        return (reopen(), "처음부터 다시 열어")
    }

    /// 같은 파일을 다시 열어 데먹서를 맨 앞으로 (디코더는 그대로 쓴다)
    private func reopen() -> Int32 {
        avformat_close_input(&fmt)
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let r = avformat_open_input(&ctx, url.path, nil, nil)
        guard r == 0, let ctx else { return r }
        avformat_find_stream_info(ctx, nil)
        fmt = ctx
        return 0
    }

    /// 풀면서 본 키프레임 시각 (정렬). 다음 탐색 때 목표 직전 키프레임으로 바로 가는 데 쓴다
    private var keyTimes: [Double] = []

    private func rememberKey(_ t: Double) {
        let i = keyTimes.firstIndex { $0 >= t } ?? keyTimes.endIndex
        if i < keyTimes.endIndex, abs(keyTimes[i] - t) < 0.0005 { return }
        keyTimes.insert(t, at: i)
    }

    private struct Decoded {
        var haveHeld = false
        var heldTime = 0.0
        var landed: Double?
        var decoded = 0
        var aborted = false
    }

    // MARK: - 방금 푼 프레임 캐시
    // 키프레임부터 목표까지 이어서 푼 프레임들(한 덩어리)을 참조로 잡아 둔다. 키프레임 탐색을 새로 하면 비운다.

    private var cache: [(time: Double, frame: UnsafeMutablePointer<AVFrame>)] = []
    private var cacheBytes = 0
    private let cacheLimit = 1 << 30

    private func cacheClear() {
        for item in cache { var f: UnsafeMutablePointer<AVFrame>? = item.frame; av_frame_free(&f) }
        cache.removeAll()
        cacheBytes = 0
    }

    private func cacheAdd(_ f: UnsafeMutablePointer<AVFrame>, time: Double) {
        guard let copy = av_frame_clone(f) else { return }
        let deep = f.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue ? 2 : max(1, Int(f.pointee.linesize.0) / max(1, Int(f.pointee.width)))
        cache.append((time, copy))
        cacheBytes += Int(f.pointee.width) * Int(f.pointee.height) * 3 / 2 * deep
        while cacheBytes > cacheLimit, cache.count > 1 {
            var first: UnsafeMutablePointer<AVFrame>? = cache.removeFirst().frame
            cacheBytes -= Int(first!.pointee.width) * Int(first!.pointee.height) * 3 / 2 * deep
            av_frame_free(&first)
        }
    }

    /// 목표 시각이 캐시 범위 안이면 목표 이하의 마지막 프레임
    private func cacheLookup(_ target: Double) -> (time: Double, frame: UnsafeMutablePointer<AVFrame>)? {
        let tol = frameDuration / 2
        guard let first = cache.first, let last = cache.last, target >= first.time - tol, target <= last.time + tol else { return nil }
        return cache.last { $0.time <= target + tol } ?? first
    }

    /// 목표 시각 이하인 마지막 프레임을 held 에 잡아 둔다. 목표를 넘는 프레임이 나오면 멈춘다
    /// needKey: 바이트 위치로 간 뒤처럼 아무 데서나 시작했으면 키프레임이 나올 때까지 버린다 (앞 프레임 없이 푼 깨진 그림을 안 보이게)
    private func decodeUntil(_ target: Double, generation gen: Int, needKey: Bool = false) -> Decoded {
        var waitKey = needKey
        guard let vCtx, let fmt else { return Decoded() }
        let tol = frameDuration / 2
        var out = Decoded()
        av_frame_unref(held)
        var reachedEnd = false
        // 탐색 직후면 첫 키프레임 패킷을 보고 목표를 지나쳤는지 풀기 전에 안다 (TS 처럼 데먹서가 다음 키프레임에 내려 주는 경우)
        var firstKeyPending = decodedUntil == nil
        decode: while true {
            if gen != currentGeneration() && out.haveHeld { out.aborted = true; break }  // 더 새 요청이 있으면 지금까지 잡은 것만 보이고 넘긴다
            let r = av_read_frame(fmt, pkt)
            if r < 0 {
                avcodec_send_packet(vCtx, nil)  // 남은 프레임 비우기
                reachedEnd = true
            } else if pkt!.pointee.stream_index != vIndex {
                av_packet_unref(pkt)
                continue
            } else {
                if pkt!.pointee.flags & AV_PKT_FLAG_KEY != 0 {
                    let ts = pkt!.pointee.pts != ienc_nopts() ? pkt!.pointee.pts : pkt!.pointee.dts
                    if ts != ienc_nopts() {
                        let kt = Double(ts) * av_q2d(vTB) - startOffset
                        rememberKey(kt)
                        if firstKeyPending && !out.haveHeld && kt > target + tol {
                            av_packet_unref(pkt)
                            out.landed = kt
                            break decode
                        }
                    }
                    firstKeyPending = false
                }
                let s = avcodec_send_packet(vCtx, pkt)
                av_packet_unref(pkt)
                if s < 0 && s != ienc_eagain() { note("영상 패킷 오류: \(FF.error(s))") }
            }
            while true {
                let g = avcodec_receive_frame(vCtx, frame)
                if g == ienc_eagain() { break }
                if g < 0 {
                    if g != ienc_eof() { note("영상 풀기 오류: \(FF.error(g))") }
                    break decode
                }
                out.decoded += 1
                let t = videoTime(frame!)
                let isKey = frame!.pointee.flags & AV_FRAME_FLAG_KEY != 0
                if isKey { rememberKey(t) }
                if waitKey && !isKey { av_frame_unref(frame); continue }
                waitKey = false
                decodedUntil = t
                cacheAdd(frame!, time: t)
                if out.landed == nil { out.landed = t }
                if t <= target + tol || !out.haveHeld {
                    av_frame_unref(held)
                    av_frame_move_ref(held, frame)
                    out.haveHeld = true
                    out.heldTime = t
                    if t + tol >= target { break decode }
                    // 첫 프레임부터 목표를 넘었으면 더 풀어도 소용없다 (더 앞에서 다시 탐색할지는 부른 쪽이 정함)
                    if t > target + tol { break decode }
                } else {
                    av_frame_unref(frame)
                    break decode
                }
            }
            if reachedEnd { break }
        }
        if reachedEnd {
            avcodec_flush_buffers(vCtx)
            decodedUntil = nil
        }
        return out
    }

    private func videoTime(_ f: UnsafeMutablePointer<AVFrame>) -> Double {
        var ts = f.pointee.best_effort_timestamp
        if ts == ienc_nopts() { ts = f.pointee.pts }
        if ts == ienc_nopts() { return (decodedUntil ?? 0) + frameDuration }
        return Double(ts) * av_q2d(vTB) - startOffset
    }

    private func audioTime(_ f: UnsafeMutablePointer<AVFrame>) -> Double? {
        var ts = f.pointee.best_effort_timestamp
        if ts == ienc_nopts() { ts = f.pointee.pts }
        if ts == ienc_nopts() { return nil }
        return Double(ts) * av_q2d(aTB) - startOffset
    }

    // MARK: - 재생

    private var playing = false

    func play(from time: Double, onEnd: @escaping () -> Void) {
        let gen = bump()
        queue.async { [self] in
            guard gen == currentGeneration(), let fmt else { return }
            playing = true
            _ = fmt
            _ = seekDemuxer(to: time)
            guard let fmt = self.fmt else { return }
            if let vCtx { avcodec_flush_buffers(vCtx) }
            if let aCtx { avcodec_flush_buffers(aCtx) }
            decodedUntil = nil
            renderer.flush()
            audioRenderer.flush()
            sync.setRate(0, time: CMTime(seconds: time, preferredTimescale: 90000))

            var videoAhead = time
            var audioAhead = time
            var started = false
            var decodeSeconds = 0.0
            var lastVideo = time
            var lastShown = time
            var late = 0
            var ended = false
            let wallStart = CACurrentMediaTime()

            while gen == currentGeneration() {
                let now = started ? sync.currentTime().seconds : time
                let needVideo = videoAhead - now < 0.5
                let needAudio = hasAudio && audioAhead - now < 1.0
                if started && !needVideo && !needAudio && !ended {
                    if now - lastShown > 1 {
                        lastShown = now
                        let played = now - time
                        stats.playback = String(format: "재생 중 · 풀기 속도 %.1f배 실시간 · 늦은 프레임 %d · 경과 %.1f초", played / max(decodeSeconds, 0.001), late, CACurrentMediaTime() - wallStart)
                        publish()
                    }
                    usleep(4000)
                    continue
                }
                if ended {
                    if now >= lastVideo { break }
                    usleep(10000)
                    continue
                }
                let d0 = CACurrentMediaTime()
                let r = av_read_frame(fmt, pkt)
                if r < 0 {
                    if let vCtx { avcodec_send_packet(vCtx, nil) }
                    if let aCtx { avcodec_send_packet(aCtx, nil) }
                    drainVideo(from: time, ahead: &videoAhead, last: &lastVideo, late: &late, started: started, now: now)
                    drainAudio(from: time, ahead: &audioAhead)
                    ended = true
                    if !started { sync.setRate(1, time: CMTime(seconds: time, preferredTimescale: 90000)); started = true }
                    continue
                }
                let idx = pkt!.pointee.stream_index
                if idx == vIndex, let vCtx {
                    avcodec_send_packet(vCtx, pkt)
                    av_packet_unref(pkt)
                    drainVideo(from: time, ahead: &videoAhead, last: &lastVideo, late: &late, started: started, now: now)
                } else if idx == aIndex, let aCtx {
                    avcodec_send_packet(aCtx, pkt)
                    av_packet_unref(pkt)
                    drainAudio(from: time, ahead: &audioAhead)
                } else {
                    av_packet_unref(pkt)
                }
                decodeSeconds += CACurrentMediaTime() - d0
                if !started && videoAhead - time > 0.3 && (!hasAudio || audioAhead - time > 0.3) {
                    sync.setRate(1, time: CMTime(seconds: time, preferredTimescale: 90000))
                    started = true
                }
                let played = sync.currentTime().seconds - time
                if started && played - (lastShown - time) > 1 {
                    lastShown = sync.currentTime().seconds
                    let speed = played > 0 ? played / max(decodeSeconds, 0.001) : 0
                    stats.playback = String(format: "재생 중 · 풀기 속도 %.1f배 실시간 · 늦은 프레임 %d · 경과 %.1f초", speed, late, CACurrentMediaTime() - wallStart)
                    publish()
                }
            }
            let stoppedAt = sync.currentTime().seconds
            sync.setRate(0, time: CMTime(seconds: stoppedAt, preferredTimescale: 90000))
            playing = false
            shownTime = min(stoppedAt, lastVideo)
            decodedUntil = nil
            if let vCtx { avcodec_flush_buffers(vCtx) }
            if let aCtx { avcodec_flush_buffers(aCtx) }
            if ended && gen == currentGeneration() {
                DispatchQueue.main.async { onEnd() }
            }
        }
    }

    func pause() {
        bump()
        sync.setRate(0, time: sync.currentTime())
    }

    var currentTime: Double { sync.currentTime().seconds }

    private func drainVideo(from start: Double, ahead: inout Double, last: inout Double, late: inout Int, started: Bool, now: Double) {
        guard let vCtx else { return }
        while avcodec_receive_frame(vCtx, frame) == 0 {
            let t = videoTime(frame!)
            if t + frameDuration < start { av_frame_unref(frame); continue }
            if started && t < now { late += 1 }
            if let sb = makeVideoSample(frame!, time: t, immediate: false) { renderer.enqueue(sb) }
            av_frame_unref(frame)
            ahead = max(ahead, t)
            last = max(last, t + frameDuration)
        }
    }

    private func drainAudio(from start: Double, ahead: inout Double) {
        guard let aCtx else { return }
        while avcodec_receive_frame(aCtx, frame) == 0 {
            defer { av_frame_unref(frame) }
            guard let t = audioTime(frame!) else { continue }
            let len = Double(frame!.pointee.nb_samples) / Double(max(frame!.pointee.sample_rate, 1))
            if t + len < start { continue }
            if let sb = makeAudioSample(frame!, time: t) { audioRenderer.enqueue(sb) }
            ahead = max(ahead, t + len)
        }
    }

    // MARK: - 화면·소리 샘플 만들기

    private func displayStill(_ f: UnsafeMutablePointer<AVFrame>, time: Double) {
        guard let sb = makeVideoSample(f, time: time, immediate: true) else { return }
        renderer.flush()
        renderer.enqueue(sb)
    }

    /// 푼 프레임의 픽셀 버퍼: VideoToolbox 로 풀었으면 그대로, 소프트웨어면 BGRA 로 바꿔서
    private func pixelBuffer(_ f: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        if f.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue, let raw = f.pointee.data.3 {
            mark("\(decoderName) · VideoToolbox (하드웨어)")
            return Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
        }
        let pix = av_get_pix_fmt_name(AVPixelFormat(rawValue: f.pointee.format)).map { String(cString: $0) } ?? "?"
        mark("\(decoderName) · 소프트웨어 (\(pix) → BGRA)")
        return convert(f)
    }

    private func makeVideoSample(_ f: UnsafeMutablePointer<AVFrame>, time: Double, immediate: Bool) -> CMSampleBuffer? {
        guard let pb = pixelBuffer(f) else { return nil }
        let sar = f.pointee.sample_aspect_ratio
        if sar.num > 0 && sar.den > 0 && sar.num != sar.den {
            CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: sar.num,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: sar.den,
            ] as CFDictionary, .shouldPropagate)
        }
        var desc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &desc) == noErr, let desc else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: frameDuration, preferredTimescale: 90000),
                                        presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 90000),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: desc, sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        if immediate, let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    private var decoderName: String {
        vCtx.map { String(cString: $0.pointee.codec.pointee.name) } ?? "?"
    }

    private func mark(_ decoder: String) {
        if stats.decoder != decoder {
            stats.decoder = decoder
            publish()
        }
    }

    /// 소프트웨어로 푼 프레임(어떤 픽셀 형식이든)을 BGRA 픽셀 버퍼로
    private func convert(_ f: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let w = f.pointee.width, h = f.pointee.height
        guard w > 0, h > 0 else { return nil }
        let src = AVPixelFormat(rawValue: f.pointee.format)
        let key = "\(w)x\(h)/\(f.pointee.format)/\(f.pointee.colorspace.rawValue)/\(f.pointee.color_range.rawValue)"
        if key != swsKey {
            sws_freeContext(sws)
            sws = sws_getContext(w, h, src, w, h, AV_PIX_FMT_BGRA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
            guard sws != nil else { note("변환 준비 실패 (\(key))"); return nil }
            let hd = f.pointee.colorspace == AVCOL_SPC_BT709 || (f.pointee.colorspace == AVCOL_SPC_UNSPECIFIED && h >= 720)
            let coef = sws_getCoefficients(hd ? SWS_CS_ITU709 : SWS_CS_ITU601)
            let full: Int32 = f.pointee.color_range == AVCOL_RANGE_JPEG ? 1 : 0
            sws_setColorspaceDetails(sws, coef, full, coef, 1, 0, 1 << 16, 1 << 16)
            swsKey = key
        }
        let pk = "\(w)x\(h)"
        if pk != poolKey {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolKey = pk
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let srcData: [UnsafePointer<UInt8>?] = [f.pointee.data.0, f.pointee.data.1, f.pointee.data.2, f.pointee.data.3].map { $0.map { UnsafePointer($0) } }
        let srcStride: [Int32] = [f.pointee.linesize.0, f.pointee.linesize.1, f.pointee.linesize.2, f.pointee.linesize.3]
        let dst: [UnsafeMutablePointer<UInt8>?] = [CVPixelBufferGetBaseAddress(out)?.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
        let dstStride: [Int32] = [Int32(CVPixelBufferGetBytesPerRow(out)), 0, 0, 0]
        let lines = sws_scale(sws, srcData, srcStride, 0, h, dst, dstStride)
        return lines > 0 ? out : nil
    }

    /// 소리는 스테레오 float32 로 바꿔 넘긴다 (원본 샘플레이트 그대로)
    private func makeAudioSample(_ f: UnsafeMutablePointer<AVFrame>, time: Double) -> CMSampleBuffer? {
        let rate = f.pointee.sample_rate
        guard rate > 0, f.pointee.nb_samples > 0 else { return nil }
        let key = "\(rate)/\(f.pointee.format)/\(f.pointee.ch_layout.nb_channels)/\(f.pointee.ch_layout.order.rawValue)/\(f.pointee.ch_layout.u.mask)"
        if key != swrKey {
            swr_free(&swr)
            var outLayout = AVChannelLayout()
            av_channel_layout_default(&outLayout, 2)
            var inLayout = f.pointee.ch_layout
            let r = swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_FLT, rate, &inLayout, AVSampleFormat(rawValue: f.pointee.format), rate, 0, nil)
            guard r == 0, swr_init(swr) == 0 else { note("소리 변환 준비 실패 (\(key))"); swr_free(&swr); return nil }
            swrKey = key
        }
        if audioFormatRate != rate || audioFormat == nil {
            var asbd = AudioStreamBasicDescription(mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                   mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            audioFormat = nil
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
            audioFormatRate = rate
        }
        guard let audioFormat else { return nil }
        let capacity = Int(swr_get_out_samples(swr, f.pointee.nb_samples))
        var samples = [Float](repeating: 0, count: max(capacity, 1) * 2)
        let count: Int32 = samples.withUnsafeMutableBytes { buf in
            var out: UnsafeMutablePointer<UInt8>? = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let input = UnsafeRawPointer(f.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            return withUnsafeMutablePointer(to: &out) { swr_convert(swr, $0, Int32(capacity), input, f.pointee.nb_samples) }
        }
        guard count > 0 else { return nil }
        let bytes = Int(count) * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: CMItemCount(count),
                                                             presentationTimeStamp: CMTime(seconds: time, preferredTimescale: CMTimeScale(rate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    // MARK: - 자동 측정 (Bench) 용: 큐에서 기다렸다가 결과를 돌려준다

    struct Probe {
        var shown: Double
        var ms: Double
        var line: String
        var image: CGImage?
    }

    /// 멈춤 상태 탐색을 하고 끝날 때까지 기다린다. 보인 프레임 그림도 돌려준다
    func benchSeek(_ target: Double, step: Int = 0) -> Probe {
        let gen = bump()
        return queue.sync {
            let t0 = CACurrentMediaTime()
            showFrame(at: step == 0 ? target : max(0, shownTime + Double(step) * frameDuration), generation: gen)
            let ms = (CACurrentMediaTime() - t0) * 1000
            return Probe(shown: shownTime, ms: ms, line: stats.lastSeek, image: heldImage())
        }
    }

    /// 처음부터 차례로 풀어 목표 시각의 프레임을 얻는다 (탐색 결과가 맞는지 대조용)
    func benchLinear(_ target: Double) -> Probe {
        let gen = bump()
        return queue.sync {
            guard let fmt, let vCtx else { return Probe(shown: -1, ms: 0, line: "열리지 않음", image: nil) }
            let t0 = CACurrentMediaTime()
            _ = fmt
            _ = seekDemuxer(to: 0)
            avcodec_flush_buffers(vCtx)
            decodedUntil = nil
            cacheClear()
            let r = decodeUntil(target, generation: gen)
            avcodec_flush_buffers(vCtx)
            decodedUntil = nil
            cacheClear()
            let ms = (CACurrentMediaTime() - t0) * 1000
            return Probe(shown: r.haveHeld ? r.heldTime : -1, ms: ms, line: "차례로 \(r.decoded)개 풂", image: r.haveHeld ? heldImage() : nil)
        }
    }

    private static let ci = CIContext(options: [.cacheIntermediates: false])

    private func heldImage() -> CGImage? {
        guard let held, held.pointee.width > 0, let pb = pixelBuffer(held) else { return nil }
        let image = CIImage(cvPixelBuffer: pb)
        return Self.ci.createCGImage(image, from: image.extent)
    }

    // MARK: - 도우미

    @discardableResult
    private func bump() -> Int { generation.withLock { $0 += 1; return $0 } }
    private func currentGeneration() -> Int { generation.withLock { $0 } }

    private func note(_ message: String) {
        stats.errors.append(message)
        if stats.errors.count > 30 { stats.errors.removeFirst(stats.errors.count - 30) }
        publish()
    }

    private func publish() {
        let s = stats
        DispatchQueue.main.async { self.statsHandler?(s) }
    }
}
