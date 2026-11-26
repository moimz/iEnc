import CoreGraphics
import Foundation
import os

/// 영상 한 개의 작은 그림을 뽑는다 (재생바 필름 띠·사이드바 구간 썸네일).
/// 미리보기 엔진과 따로 파일을 열어 자기 큐에서만 FFmpeg 를 부른다.
final class Thumbnailer: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.moimz.iEnc.thumb", qos: .utility)
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    private var fmt: UnsafeMutablePointer<AVFormatContext>?
    private var vCtx: UnsafeMutablePointer<AVCodecContext>?
    private var vIndex: Int32 = -1
    private var vTB = AVRational(num: 1, den: 1)
    private var startOffset = 0.0
    private var duration = 0.0
    private var frameDuration = 1.0 / 30
    private var opened = false
    private var pkt = av_packet_alloc()
    private var frame = av_frame_alloc()
    private var held = av_frame_alloc()
    private var soft = av_frame_alloc()
    private var sws: UnsafeMutablePointer<SwsContext>?

    init(url: URL) { self.url = url }

    deinit {
        avcodec_free_context(&vCtx)
        avformat_close_input(&fmt)
        av_packet_free(&pkt)
        av_frame_free(&frame)
        av_frame_free(&held)
        av_frame_free(&soft)
        sws_freeContext(sws)
    }

    /// 여러 시각의 그림을 키프레임 기준으로 빨리 뽑는다. 다시 부르면 앞의 작업은 멈춘다
    func strip(times: [Double], height: Int, each: @escaping (Int, CGImage) -> Void) {
        let gen = generation.withLock { $0 += 1; return $0 }
        queue.async { [self] in
            for (i, t) in times.enumerated() {
                guard gen == generation.withLock({ $0 }) else { return }
                if let image = grab(t, height: height, exact: false) {
                    DispatchQueue.main.async { each(i, image) }
                }
            }
        }
    }

    /// 그 시각의 정확한 프레임 그림 (구간 썸네일)
    func image(at time: Double, height: Int, completion: @escaping (CGImage?) -> Void) {
        queue.async { [self] in
            let image = grab(time, height: height, exact: true)
            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: -

    private func openIfNeeded() -> Bool {
        if opened { return vCtx != nil }
        opened = true
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, let ctx else { return false }
        fmt = ctx
        avformat_find_stream_info(ctx, nil)
        startOffset = ctx.pointee.start_time != ienc_nopts() ? Double(ctx.pointee.start_time) / Double(AV_TIME_BASE) : 0
        if ctx.pointee.duration != ienc_nopts() { duration = Double(ctx.pointee.duration) / Double(AV_TIME_BASE) }
        vIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard vIndex >= 0, let st = ctx.pointee.streams[Int(vIndex)], let par = st.pointee.codecpar,
              let codec = avcodec_find_decoder(par.pointee.codec_id) else { return false }
        var c = avcodec_alloc_context3(codec)
        avcodec_parameters_to_context(c, par)
        c!.pointee.pkt_timebase = st.pointee.time_base
        c!.pointee.thread_count = 0
        if par.pointee.codec_id == AV_CODEC_ID_AV1 {  // 소프트웨어 디코더가 없어 VideoToolbox (미리보기 엔진과 같음)
            var dev: UnsafeMutablePointer<AVBufferRef>?
            if av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) == 0 {
                c!.pointee.hw_device_ctx = av_buffer_ref(dev)
                av_buffer_unref(&dev)
                ienc_use_hw(c)
            }
        }
        guard avcodec_open2(c, codec, nil) == 0 else { avcodec_free_context(&c); return false }
        vCtx = c
        vTB = st.pointee.time_base
        let rate = st.pointee.avg_frame_rate.num > 0 && st.pointee.avg_frame_rate.den > 0 ? st.pointee.avg_frame_rate : st.pointee.r_frame_rate
        if rate.num > 0 && rate.den > 0 { frameDuration = 1 / av_q2d(rate) }
        return true
    }

    private func grab(_ time: Double, height: Int, exact: Bool) -> CGImage? {
        guard openIfNeeded(), let fmt, let vCtx else { return nil }
        let tol = frameDuration / 2
        var r = av_seek_frame(fmt, vIndex, Int64(((time + startOffset) / av_q2d(vTB)).rounded(.down)), AVSEEK_FLAG_BACKWARD)
        if r < 0, duration > 0 {
            let size = avio_size(fmt.pointee.pb)
            if size > 0 { r = av_seek_frame(fmt, -1, Int64(Double(size) * min(1, time / duration)), AVSEEK_FLAG_BYTE) }
        }
        avcodec_flush_buffers(vCtx)
        // 필름 띠는 키프레임만 풀어 빨리 (정확한 자리보다 빠르기가 중요)
        vCtx.pointee.skip_frame = exact ? AVDISCARD_DEFAULT : AVDISCARD_NONKEY
        av_frame_unref(held)
        var have = false
        var packets = 0
        read: while packets < 5000 {
            let rr = av_read_frame(fmt, pkt)
            if rr < 0 {
                avcodec_send_packet(vCtx, nil)
            } else if pkt!.pointee.stream_index != vIndex {
                av_packet_unref(pkt)
                continue
            } else {
                packets += 1
                avcodec_send_packet(vCtx, pkt)
                av_packet_unref(pkt)
            }
            while avcodec_receive_frame(vCtx, frame) == 0 {
                var ts = frame!.pointee.best_effort_timestamp
                if ts == ienc_nopts() { ts = frame!.pointee.pts }
                let t = ts == ienc_nopts() ? time : Double(ts) * av_q2d(vTB) - startOffset
                if !exact || !have || t <= time + tol {
                    av_frame_unref(held)
                    av_frame_move_ref(held, frame)
                    have = true
                    if !exact || t + tol >= time { break read }
                } else {
                    av_frame_unref(frame)
                    break read
                }
            }
            if rr < 0 { break }
        }
        return have ? makeImage(held!, height: height) : nil
    }

    /// 화소 비율까지 맞춘 크기로 줄여 CGImage 로
    private func makeImage(_ f: UnsafeMutablePointer<AVFrame>, height: Int) -> CGImage? {
        var src = f
        if f.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            av_frame_unref(soft)
            guard av_hwframe_transfer_data(soft, f, 0) == 0 else { return nil }
            src = soft!
        }
        let w = Int(src.pointee.width), h = Int(src.pointee.height)
        guard w > 0, h > 0 else { return nil }
        var sar = av_q2d(src.pointee.sample_aspect_ratio)
        if !(sar > 0) { sar = 1 }
        let outH = min(height, h * 2)
        let outW = max(1, Int((Double(w) * sar / Double(h) * Double(outH)).rounded()))
        sws = sws_getCachedContext(sws, Int32(w), Int32(h), AVPixelFormat(rawValue: src.pointee.format),
                                   Int32(outW), Int32(outH), AV_PIX_FMT_BGRA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
        guard sws != nil else { return nil }
        let stride = outW * 4
        var data = Data(count: stride * outH)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            let srcData: [UnsafePointer<UInt8>?] = [src.pointee.data.0, src.pointee.data.1, src.pointee.data.2, src.pointee.data.3].map { $0.map { UnsafePointer($0) } }
            let srcStride: [Int32] = [src.pointee.linesize.0, src.pointee.linesize.1, src.pointee.linesize.2, src.pointee.linesize.3]
            let dst: [UnsafeMutablePointer<UInt8>?] = [buf.baseAddress?.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
            let dstStride: [Int32] = [Int32(stride), 0, 0, 0]
            return sws_scale(sws, srcData, srcStride, 0, Int32(h), dst, dstStride) > 0
        }
        guard ok, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: outW, height: outH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
