import SwiftUI

/// 오른쪽 사이드바: 인코딩 설정 (세로 목록, 폭 고정) + 맨 아래 변환할 구간 요약 · 영상 변환하기.
/// 저장 위치·파일 이름 규칙은 앱 설정(⌘,)에 있다
struct EncodeSettingsView: View {
    @Bindable var model: AppModel

    private var s: Binding<EncodeSettings> { $model.encode }
    private var e: EncodeSettings { model.encode }
    private var copyVideo: Bool { e.videoCodec == .copy }
    /// 고를 수 있는 코덱: x264·x265 는 GPL ffmpeg 가 있고 macOS 27 이상일 때만
    private var codecs: [EncodeSettings.VideoCodec] {
        EncodeSettings.VideoCodec.allCases.filter { !$0.isSoftware || EncodePlan.softwareFFmpeg != nil }
    }
    private var aac: Bool { e.audioCodec == .aac }

    var body: some View {
        Form {
            Section("영상") {
                Picker("코덱", selection: s.videoCodec) {
                    ForEach(codecs) { c in
                        Text(c.rawValue).tag(c)
                        if c == .h264 || c == .x264 { Divider() }
                    }
                }
                .help("하드웨어: 미디어 엔진으로 빠르고 CPU 를 거의 안 씀 (같은 화질이면 큼). CPU(x265·x264): 성능 코어를 다 써서 같은 화질을 더 작게. 원본 그대로: 다시 압축하지 않아 빠르지만 시작점이 키프레임에 맞춰짐")
                if e.videoCodec.isSoftware {
                    Picker(selection: s.preset) {
                        ForEach(EncodeSettings.Preset.allCases) { Text($0.rawValue).tag($0) }
                    } label: { InfoLabel("압축 수고", Info.preset) }
                }
                Group {
                    Picker(selection: s.rateMode) {
                        ForEach(EncodeSettings.RateMode.allCases) { Text($0.rawValue).tag($0) }
                    } label: { InfoLabel("화질", Info.rateMode) }
                    if e.rateMode == .quality && e.videoCodec.isSoftware {
                        LabeledContent {
                            HStack {
                                // 왼쪽이 화질 좋음(작은 CRF) — 하드웨어 품질 막대와 방향을 맞추려고 뒤집어 보인다
                                Slider(value: Binding(get: { 50 - e.crf }, set: { model.encode.crf = 50 - $0 }), in: 15...36, step: 1)
                                Text("\(Int(e.crf))").monospacedDigit().frame(width: 26, alignment: .trailing)
                            }
                        } label: { InfoLabel("화질 (CRF)", Info.crf) }
                    } else if e.rateMode == .quality {
                        LabeledContent {
                            HStack {
                                Slider(value: s.quality, in: 1...100, step: 1)
                                Text("\(Int(e.quality))").monospacedDigit().frame(width: 26, alignment: .trailing)
                            }
                        } label: { InfoLabel("품질", Info.quality) }
                    } else {
                        LabeledContent {
                            HStack(spacing: 4) {
                                TextField("Mbps", value: s.bitrate, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("Mbps")
                            }
                        } label: { InfoLabel("비트레이트", Info.bitrate) }
                    }
                    Picker("해상도", selection: s.resolution) {
                        ForEach(EncodeSettings.Resolution.allCases) { r in
                            Text(r.label).tag(r)
                            if r == .smallest { Divider() }
                        }
                    }
                    .help("원본: 구간마다 제 해상도 (한 파일로 합칠 땐 가장 큰 것에 맞춤)")
                    Picker("비율이 다르면", selection: s.fit) {
                        ForEach(EncodeSettings.Fit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(e.grouping != .joined)
                    .help("가로세로 비율이 다른 구간을 한 파일로 합칠 때만: 비율을 지켜 검은 여백을 넣거나, 꽉 채우고 넘치는 가장자리를 자릅니다")
                    Picker("프레임률", selection: s.frameRate) {
                        ForEach(EncodeSettings.FrameRate.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle(isOn: s.tenBit) { InfoLabel("10비트", Info.tenBit) }
                        .disabled(!e.videoCodec.isHEVC)
                    Picker(selection: s.deinterlace) {
                        ForEach(EncodeSettings.Deinterlace.allCases) { Text($0.rawValue).tag($0) }
                    } label: { InfoLabel("디인터레이스", Info.deinterlace) }
                }
                .disabled(copyVideo)
            }
            Section("소리") {
                Picker("코덱", selection: s.audioCodec) {
                    ForEach(EncodeSettings.AudioCodec.allCases) { Text($0.rawValue).tag($0) }
                }
                Group {
                    Picker("비트레이트", selection: s.audioBitrate) {
                        ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                    Picker("채널", selection: s.channels) {
                        ForEach(EncodeSettings.Channels.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("소리 크기 고르게", isOn: s.normalizeLoudness)
                        .help("구간마다 소리 크기가 달라도 비슷하게 맞춥니다 (loudnorm). 타임라인에서 구간별로 맞춘 음량과 따로 적용")
                }
                .disabled(!aac)
            }
            SubtitleSections(model: model)
            Section("출력") {
                Picker("형식", selection: s.container) {
                    ForEach(EncodeSettings.Container.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("제목 태그 유지", isOn: s.keepMetadata)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { convertBar }
    }

    /// 맨 아래 고정: 구간 묶기(위 설정 일부가 이것에 따라 켜지고 꺼짐) + 예상 크기 + 영상 변환하기.
    /// 변환 중엔 진행 막대 · 지난/남은 시간 · 지금/예상 크기 + 취소
    private var convertBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let job = model.job {
                JobStatus(job: job, model: model)
            } else if model.clips.isEmpty {
                Text("자른 구간이 없습니다")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("구간 (\(model.clips.count)개)")
                    Spacer()
                    Picker("구간", selection: s.grouping) {
                        ForEach(EncodeSettings.Grouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Text("예상 크기")
                    Spacer()
                    if model.estimating {
                        ProgressView().controlSize(.small)
                        Text("어림하는 중").foregroundStyle(.secondary)
                    } else if let bytes = model.estimate {
                        Text("약 \(FF.bytes(bytes))").monospacedDigit()
                    } else {
                        Text("알 수 없음").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .help("비트레이트 지정·원본 그대로는 계산, 품질 기준은 짧은 조각 몇 개를 시험 인코딩해 어림합니다")
            }
            if model.isEncoding {
                Button(role: .cancel) { model.cancelEncode() } label: {
                    Label("취소", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                Button {
                    model.dismissJob()
                    model.startEncode()
                } label: {
                    Label("영상 변환하기", systemImage: "film.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.clips.isEmpty)
            }
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: model.encode) { model.updateEstimate() }
        .onChange(of: model.clips) { model.updateEstimate() }
    }
}

/// 변환 진행·결과
private struct JobStatus: View {
    @Bindable var job: EncodeJob
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch job.state {
            case .running:
                HStack {
                    Text((job.paused ? "멈춤" : "변환 중") + (job.outputs.count > 1 ? " (\(job.fileIndex + 1)/\(job.outputs.count))" : ""))
                    if let left = job.remaining, !job.paused {
                        Text("\(FF.duration(left)) 남음").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text(String(format: "%.1f%%", job.progress * 100)).monospacedDigit()
                }
                .font(.callout.weight(.medium))
                ProgressView(value: job.progress)
                // 지난 시간 / 예상 전체 시간 (크기 줄과 같은 꼴)
                row("시간", "\(FF.duration(job.elapsed)) / " + (job.remaining.map { "예상 " + FF.duration(job.elapsed + $0) } ?? "계산 중"))
                row("크기", "\(FF.bytes(job.bytes)) / " + (job.estimatedBytes.map { "예상 " + FF.bytes($0) } ?? "계산 중"))
                if !job.speed.isEmpty { row("속도", job.speed) }
                HStack {
                    Toggle("효율 코어로만", isOn: $job.lowPriority)
                        .toggleStyle(.checkbox)
                        .help("변환 도중에도 켜고 끌 수 있습니다. 켜면 다른 앱이 거의 안 느려지는 대신 변환이 15~20배 느려집니다")
                    Spacer()
                    Button(job.paused ? "이어서" : "잠시 멈춤") { job.paused.toggle() }
                        .controlSize(.small)
                }
                .font(.caption)
            case .finished:
                Label("변환 끝 · \(FF.duration(job.elapsed))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
                row("파일", "\(job.outputs.count)개 · \(FF.bytes(job.bytes))")
                HStack {
                    Button("Finder 에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(job.producedFiles) }
                    Spacer()
                    Button("닫기") { model.dismissJob() }
                }
                .controlSize(.small)
            case .cancelled:
                Label("취소했습니다", systemImage: "xmark.circle").foregroundStyle(.secondary).font(.callout)
            case .failed(let message):
                Label("변환 실패", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
            }
            ForEach(job.notes, id: \.self) { note in
                Text("· " + note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}

/// 설정 이름 옆 ⓘ: 누르면 그 설정이 무엇인지 풀어 쓴 말풍선
private struct InfoLabel: View {
    let title: String
    let text: String
    @State private var shown = false

    init(_ title: String, _ text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Button { shown.toggle() } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("설명 보기")
            .popover(isPresented: $shown, arrowEdge: .leading) {
                Text(.init(text))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300, alignment: .leading)
                    .padding(14)
            }
        }
    }
}

/// ⓘ 말풍선 글 (마크다운 굵게 가능)
private enum Info {
    static let preset = """
    **장면마다 얼마나 꼼꼼히 들여다보고 압축할지**입니다.

    압축은 "이 조각과 비슷한 게 앞뒤 프레임 어디에 있나" 찾아서 차이만 저장하는 일입니다. 수고를 들일수록 더 넓게, 더 많은 경우를 시험해 더 좋은 방법을 찾습니다.

    · 빠르게: 후보를 조금만 보고 고름
    · 보통: 흔히 쓰는 균형
    · 작게: 오래 걸리는 대신 같은 화질을 더 작은 파일로

    CPU 를 얼마나 쓰느냐가 아닙니다 (그건 설정 › CPU 사용량). 예: 720p 2분 영상, x265 빠르게 약 20초 · 보통 약 30초.
    """

    static let rateMode = """
    **무엇을 기준으로 압축할지** 고릅니다.

    · **품질 기준**: 화질을 일정하게 지키고, 크기는 장면에 따라 달라집니다. 움직임이 많은 장면엔 많이, 정지한 장면엔 적게 씁니다. 같은 크기에서 보통 더 보기 좋습니다. 크기는 미리 어림만 됩니다.
    · **비트레이트**: 1초에 쓸 용량을 정합니다. 크기를 거의 정확히 맞출 수 있지만, 복잡한 장면은 화질이 떨어지고 단순한 장면엔 용량이 남습니다. 올릴 곳의 용량 제한이 있을 때 씁니다.
    """

    static let quality = """
    **하드웨어 인코더가 정보를 얼마나 덜 버릴지**입니다 (1~100).

    높을수록 디테일이 남고 파일이 커지며, 낮을수록 뭉개지고 네모 무늬가 보입니다. 50~70 이 무난하고, 기본은 60 입니다.

    애플 미디어 엔진만의 눈금이라 소프트웨어의 CRF 숫자와 바꿔 셀 수 없습니다.
    """

    static let crf = """
    **x264·x265 의 화질 기준 값(CRF)**입니다. 화질을 일정하게 지키고 크기는 장면에 따라 달라집니다.

    숫자가 **낮을수록** 화질이 좋고 파일이 큽니다 (막대는 다른 설정과 맞춰 오른쪽이 좋은 화질). 6 내리면 크기가 대략 두 배입니다.

    · x264: 18~23 이 흔함 (18 ≈ 눈으로 구별 어려움)
    · x265: 22~28 이 흔함 (같은 숫자면 x264 보다 작음)

    하드웨어 "품질" 숫자와는 다른 눈금입니다.
    """

    static let bitrate = """
    **1초에 쓸 용량**입니다 (Mbps = 초당 메가비트). 크기 ≈ 비트레이트 × 길이 ÷ 8 이라, 6 Mbps 로 10분이면 약 450 MB 입니다 (소리 별도).

    대략 HEVC 기준: 720p 2~4 · 1080p 4~8 · 4K 15~30. H.264 는 이보다 1.5배쯤 필요합니다.
    """

    static let tenBit = """
    **색 단계를 더 잘게 저장**합니다. 8비트는 색마다 256 단계, 10비트는 1024 단계입니다.

    하늘·어두운 벽처럼 서서히 변하는 곳에 생기는 계단 같은 띠가 줄고, 같은 화질에서 크기가 조금 작아지기도 합니다. 원본이 HDR 이면 켜야 합니다.

    HEVC 에서만 됩니다. 아주 오래된 기기·TV 는 재생하지 못할 수 있습니다.
    """

    static let deinterlace = """
    옛 TV 방송·DVD·캠코더 영상(**인터레이스**)은 한 화면을 홀수 줄·짝수 줄로 번갈아 찍어, 움직이는 곳에 **빗살 무늬**가 보입니다. 이를 온전한 화면으로 폅니다.

    · 자동: 파일에 인터레이스 표시가 있는 영상만 폄
    · 끔: 그대로 둠
    · 켬: 표시가 없어도 폄 (표시가 잘못 달린 영상용)

    요즘 영상은 대부분 해당 없습니다.
    """
}
