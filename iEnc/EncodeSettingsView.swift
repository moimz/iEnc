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
                    Picker("압축 수고", selection: s.preset) {
                        ForEach(EncodeSettings.Preset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .help("CPU 사용량이 아니라 장면마다 얼마나 꼼꼼히 압축하느냐. 작게일수록 같은 화질이 작은 파일이 되고 오래 걸립니다")
                }
                Group {
                    Picker("화질", selection: s.rateMode) {
                        ForEach(EncodeSettings.RateMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if e.rateMode == .quality && e.videoCodec.isSoftware {
                        LabeledContent("화질 (CRF)") {
                            HStack {
                                // 왼쪽이 화질 좋음(작은 CRF) — 하드웨어 품질 막대와 방향을 맞추려고 뒤집어 보인다
                                Slider(value: Binding(get: { 50 - e.crf }, set: { model.encode.crf = 50 - $0 }), in: 15...36, step: 1)
                                Text("\(Int(e.crf))").monospacedDigit().frame(width: 26, alignment: .trailing)
                            }
                        }
                        .help("낮을수록 화질이 좋고 파일이 큽니다. x264 는 18~23, x265 는 22~28 이 흔히 쓰는 범위")
                    } else if e.rateMode == .quality {
                        LabeledContent("품질") {
                            HStack {
                                Slider(value: s.quality, in: 1...100, step: 1)
                                Text("\(Int(e.quality))").monospacedDigit().frame(width: 26, alignment: .trailing)
                            }
                        }
                    } else {
                        LabeledContent("비트레이트") {
                            HStack(spacing: 4) {
                                TextField("Mbps", value: s.bitrate, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("Mbps")
                            }
                        }
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
                    Toggle("10비트", isOn: s.tenBit)
                        .disabled(!e.videoCodec.isHEVC)
                        .help("HEVC Main10. 그러데이션 띠가 덜 생깁니다")
                    Picker("디인터레이스", selection: s.deinterlace) {
                        ForEach(EncodeSettings.Deinterlace.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .help("자동: 인터레이스 표시가 있는 영상만 bwdif 로 폅니다")
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
            Section("출력") {
                Picker("형식", selection: s.container) {
                    ForEach(EncodeSettings.Container.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("자막 포함", isOn: s.keepSubtitles)
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
                    Spacer()
                    Text("\(Int(job.progress * 100))%").monospacedDigit()
                }
                .font(.callout.weight(.medium))
                ProgressView(value: job.progress)
                row("시간", "\(FF.duration(job.elapsed)) / " + (job.remaining.map { "남은 약 " + FF.duration($0) } ?? "계산 중"))
                row("크기", "\(FF.bytes(job.bytes)) / " + (job.estimatedBytes.map { "예상 " + FF.bytes($0) } ?? "계산 중"))
                if !job.speed.isEmpty { row("속도", "실시간의 \(job.speed)") }
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
