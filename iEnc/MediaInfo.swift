import Foundation

/// 영상 파일의 정보 (오른쪽 정보 칸). "이 영상은 왜 안 되지?" 를 가릴 수 있을 만큼 자세히.
struct MediaInfo {
    struct Section: Identifiable {
        let id = UUID()
        let title: String
        var rows: [(String, String)]
    }

    var sections: [Section] = []

    /// 정보 칸 전체를 글로 (복사해 기록에 붙이기 좋게)
    var text: String {
        sections.map { s in
            "[\(s.title)]\n" + s.rows.map { "  \($0.0): \($0.1)" }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// 파일을 따로 열어 읽는다 (미리보기 엔진과 상태를 섞지 않게)
    static func probe(_ url: URL) -> MediaInfo {
        var info = MediaInfo()
        var file = Section(title: "파일", rows: [("이름", url.lastPathComponent)])
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            file.rows.append(("크기", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }

        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let opened = avformat_open_input(&ctx, url.path, nil, nil)
        guard opened == 0, let fmt = ctx else {
            file.rows.append(("열기", "실패: \(FF.error(opened))"))
            info.sections = [file]
            return info
        }
        defer { avformat_close_input(&ctx) }
        let found = avformat_find_stream_info(fmt, nil)

        let f = fmt.pointee
        file.rows.append(("컨테이너", "\(String(cString: f.iformat.pointee.name)) (\(String(cString: f.iformat.pointee.long_name)))"))
        file.rows.append(("길이", f.duration == ienc_nopts() ? "알 수 없음" : FF.clock(Double(f.duration) / Double(AV_TIME_BASE))))
        if f.start_time != ienc_nopts() && f.start_time != 0 {
            file.rows.append(("시작 시각", String(format: "%.3f초", Double(f.start_time) / Double(AV_TIME_BASE))))
        }
        if f.bit_rate > 0 { file.rows.append(("전체 비트레이트", FF.bitrate(f.bit_rate))) }
        if found < 0 { file.rows.append(("스트림 분석", "실패: \(FF.error(found))")) }
        if let title = FF.tag(f.metadata, "title") { file.rows.append(("제목 태그", title)) }
        info.sections.append(file)

        for i in 0..<Int(f.nb_streams) {
            guard let st = f.streams[i] else { continue }
            info.sections.append(streamSection(st, index: i))
        }

        let video = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        if video >= 0 {
            info.sections.append(keyframeSection(fmt, stream: video))
        }
        return info
    }

    private static func streamSection(_ st: UnsafeMutablePointer<AVStream>, index: Int) -> Section {
        let s = st.pointee
        let par = s.codecpar.pointee
        let kind: String
        switch par.codec_type {
        case AVMEDIA_TYPE_VIDEO: kind = "영상"
        case AVMEDIA_TYPE_AUDIO: kind = "오디오"
        case AVMEDIA_TYPE_SUBTITLE: kind = "자막"
        case AVMEDIA_TYPE_ATTACHMENT: kind = "첨부"
        case AVMEDIA_TYPE_DATA: kind = "데이터"
        default: kind = "기타"
        }
        var rows: [(String, String)] = []
        let name = String(cString: avcodec_get_name(par.codec_id))
        let long = avcodec_descriptor_get(par.codec_id).map { String(cString: $0.pointee.long_name) } ?? ""
        rows.append(("코덱", long.isEmpty ? name : "\(name) (\(long))"))
        if let p = avcodec_profile_name(par.codec_id, par.profile) {
            rows.append(("프로파일", String(cString: p) + (par.level > 0 ? " · 레벨 \(par.level)" : "")))
        }
        if par.codec_tag != 0 { rows.append(("태그(FourCC)", FF.fourcc(par.codec_tag))) }
        rows.append(("디코더", avcodec_find_decoder(par.codec_id) == nil ? "없음 ⚠️" : "있음"))

        switch par.codec_type {
        case AVMEDIA_TYPE_VIDEO:
            rows.append(("해상도", "\(par.width)×\(par.height)"))
            if par.sample_aspect_ratio.num > 0 && par.sample_aspect_ratio.num != par.sample_aspect_ratio.den {
                var dar = AVRational()
                av_reduce(&dar.num, &dar.den, Int64(par.width) * Int64(par.sample_aspect_ratio.num), Int64(par.height) * Int64(par.sample_aspect_ratio.den), 1024 * 1024)
                rows.append(("화소 비율", "SAR \(par.sample_aspect_ratio.num):\(par.sample_aspect_ratio.den) → 화면 \(dar.num):\(dar.den)"))
            }
            if let pix = av_get_pix_fmt_name(AVPixelFormat(rawValue: par.format)) {
                rows.append(("픽셀 형식", String(cString: pix)))
            }
            if par.bits_per_raw_sample > 0 { rows.append(("비트 깊이", "\(par.bits_per_raw_sample)비트")) }
            rows.append(("프레임률", FF.rate(s.avg_frame_rate, s.r_frame_rate)))
            rows.append(("주사 방식", FF.fieldOrder(par.field_order)))
            let color = [av_color_space_name(par.color_space), av_color_primaries_name(par.color_primaries), av_color_transfer_name(par.color_trc)]
                .compactMap { $0.map { String(cString: $0) } }
                .filter { $0 != "unknown" && $0 != "reserved" }
            if !color.isEmpty { rows.append(("색 공간", color.joined(separator: " / "))) }
            if par.color_range != AVCOL_RANGE_UNSPECIFIED, let r = av_color_range_name(par.color_range) {
                rows.append(("색 범위", String(cString: r)))
            }
            if let sd = av_packet_side_data_get(par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX) {
                let angle = av_display_rotation_get(UnsafeRawPointer(sd.pointee.data).assumingMemoryBound(to: Int32.self))
                if !angle.isNaN && angle != 0 { rows.append(("회전", String(format: "%.0f°", -angle))) }
            }
            if par.video_delay > 0 { rows.append(("B프레임 지연", "\(par.video_delay)")) }
        case AVMEDIA_TYPE_AUDIO:
            var buf = [CChar](repeating: 0, count: 64)
            var layout = par.ch_layout
            av_channel_layout_describe(&layout, &buf, buf.count)
            rows.append(("채널", "\(par.ch_layout.nb_channels) (\(String(cString: buf)))"))
            rows.append(("샘플레이트", "\(par.sample_rate) Hz"))
            if let sf = av_get_sample_fmt_name(AVSampleFormat(rawValue: par.format)) {
                rows.append(("샘플 형식", String(cString: sf)))
            }
        default:
            break
        }
        if par.bit_rate > 0 { rows.append(("비트레이트", FF.bitrate(par.bit_rate))) }
        if s.duration != ienc_nopts() && s.duration > 0 {
            rows.append(("스트림 길이", FF.clock(Double(s.duration) * av_q2d(s.time_base))))
        }
        rows.append(("시간 단위", "\(s.time_base.num)/\(s.time_base.den)"))
        if let lang = FF.tag(s.metadata, "language") { rows.append(("언어", lang)) }
        if let title = FF.tag(s.metadata, "title") { rows.append(("제목", title)) }
        if s.disposition & AV_DISPOSITION_DEFAULT != 0 { rows.append(("기본 트랙", "예")) }
        return Section(title: "#\(index) \(kind)", rows: rows)
    }

    /// 앞부분(최대 60초·3000 패킷)을 읽어 키프레임 간격과 색인 유무를 본다.
    /// 무손실 자르기의 정확도, 탐색 속도(직전 키프레임부터 풀어야 하므로)를 가늠하는 값.
    private static func keyframeSection(_ fmt: UnsafeMutablePointer<AVFormatContext>, stream: Int32) -> Section {
        var rows: [(String, String)] = []
        guard let st = fmt.pointee.streams[Int(stream)] else { return Section(title: "키프레임", rows: rows) }
        let entries = avformat_index_get_entries_count(st)
        rows.append(("색인", entries > 0 ? "있음 (\(entries)개)" : "없음 (탐색 때 파일을 훑어야 함)"))

        let tb = av_q2d(st.pointee.time_base)
        var keys: [Double] = []
        var packets = 0
        var noPts = 0
        var first: Double?
        let pkt = av_packet_alloc()
        defer { var p = pkt; av_packet_free(&p) }
        while packets < 3000, av_read_frame(fmt, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt!.pointee.stream_index == stream else { continue }
            packets += 1
            let ts = pkt!.pointee.pts != ienc_nopts() ? pkt!.pointee.pts : pkt!.pointee.dts
            if ts == ienc_nopts() { noPts += 1; continue }
            let t = Double(ts) * tb
            if first == nil { first = t }
            if pkt!.pointee.flags & AV_PKT_FLAG_KEY != 0 { keys.append(t) }
            if t - (first ?? t) > 60 { break }
        }
        let span = keys.count > 1 ? keys.last! - keys.first! : 0
        if keys.count > 1 {
            let gaps = zip(keys.dropFirst(), keys).map { $0 - $1 }
            rows.append(("간격 (앞부분)", String(format: "평균 %.2f초 · 최대 %.2f초 · %d개 / %.0f초", span / Double(gaps.count), gaps.max() ?? 0, keys.count, span)))
        } else {
            rows.append(("간격 (앞부분)", keys.isEmpty ? "키프레임 표시 없음 ⚠️" : "1개만 있음 (\(packets) 패킷 중)"))
        }
        if noPts > 0 { rows.append(("시각 없는 패킷", "\(noPts) / \(packets) ⚠️")) }
        return Section(title: "키프레임 (영상 #\(stream))", rows: rows)
    }
}

/// FFmpeg 값을 사람이 읽을 글로
enum FF {
    static func error(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        return String(cString: ienc_err(code, &buf, buf.count))
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "-" }
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    static func bitrate(_ bps: Int64) -> String {
        bps >= 1_000_000 ? String(format: "%.2f Mbps", Double(bps) / 1e6) : String(format: "%.0f kbps", Double(bps) / 1e3)
    }

    static func rate(_ avg: AVRational, _ r: AVRational) -> String {
        let a = avg.den > 0 ? av_q2d(avg) : 0
        let b = r.den > 0 ? av_q2d(r) : 0
        if a > 0 && b > 0 && abs(a - b) > 0.01 {
            return String(format: "평균 %.3f · 기준 %.3f (가변 프레임률일 수 있음)", a, b)
        }
        return a > 0 ? String(format: "%.3f fps", a) : (b > 0 ? String(format: "%.3f fps (기준)", b) : "알 수 없음")
    }

    static func fieldOrder(_ f: AVFieldOrder) -> String {
        switch f {
        case AV_FIELD_PROGRESSIVE: return "프로그레시브"
        case AV_FIELD_TT, AV_FIELD_TB: return "인터레이스 (윗 필드 먼저)"
        case AV_FIELD_BB, AV_FIELD_BT: return "인터레이스 (아랫 필드 먼저)"
        default: return "표시 없음"
        }
    }

    static func fourcc(_ tag: UInt32) -> String {
        let chars = (0..<4).map { Character(UnicodeScalar(UInt8((tag >> (8 * $0)) & 0xFF))) }
        let text = String(chars)
        return text.allSatisfy { $0.isASCII && !$0.isWhitespace || $0 == " " } ? text : String(format: "0x%08X", tag)
    }

    static func tag(_ dict: OpaquePointer?, _ key: String) -> String? {
        guard let e = av_dict_get(dict, key, nil, 0), let v = e.pointee.value else { return nil }
        return text(v)
    }

    /// 태그 글자: UTF-8 이 아니면 옛 윈도우 인코딩(한국어 CP949 · 일본어 Shift-JIS · 중국어)을 골라 푼다.
    /// AVI 의 INFO 태그 같은 건 만든 PC 의 인코딩 그대로 들어 있어서 UTF-8 로 읽으면 깨진다.
    static func text(_ p: UnsafePointer<CChar>) -> String {
        let data = Data(bytes: p, count: strlen(p))
        if let s = String(data: data, encoding: .utf8) { return s }
        var converted: NSString?
        var lossy: ObjCBool = false
        let found = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: legacyEncodings,
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        if found != 0, let converted { return converted as String }
        return String(cString: p)
    }

    private static let legacyEncodings: [UInt] = [
        CFStringEncodings.dosKorean, .dosJapanese, .GB_18030_2000, .big5_HKSCS_1999,
    ].map { CFStringConvertEncodingToNSStringEncoding(CFStringEncoding($0.rawValue)) }
}
