import SwiftUI

/// 오른쪽 사이드바: 인코딩 설정 (세로 목록, 폭 고정) + 맨 아래 변환할 구간 요약 · 영상 변환하기.
/// 저장 위치·파일 이름 규칙은 앱 설정(⌘,)에 있다
struct EncodeSettingsView: View {
    @Bindable var model: AppModel

    private var s: Binding<EncodeSettings> { $model.encode }
    private var e: EncodeSettings { model.encode }
    private var copyVideo: Bool { e.videoCodec == .copy }
    private var aac: Bool { e.audioCodec == .aac }

    var body: some View {
        Form {
            Section("영상") {
                Picker("코덱", selection: s.videoCodec) {
                    ForEach(EncodeSettings.VideoCodec.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("원본 그대로는 다시 압축하지 않아 빠르고 화질 손실이 없지만, 시작점이 키프레임에 맞춰져 조금 앞당겨질 수 있습니다")
                Group {
                    Picker("화질", selection: s.rateMode) {
                        ForEach(EncodeSettings.RateMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if e.rateMode == .quality {
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
                        .disabled(e.videoCodec != .hevc)
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
                Picker("구간", selection: s.grouping) {
                    ForEach(EncodeSettings.Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("자막 포함", isOn: s.keepSubtitles)
                Toggle("제목 태그 유지", isOn: s.keepMetadata)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { convertBar }
    }

    private var convertBar: some View {
        let total = model.clips.reduce(0) { $0 + $1.length }
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.clips.isEmpty
                 ? "자른 구간이 없습니다"
                 : "구간 \(model.clips.count)개 · \(FF.clock(total)) → \(e.container.rawValue) \(e.grouping == .joined ? 1 : model.clips.count)개")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Button {
                // 변환 기능은 아직 없다 (설정 화면 먼저)
            } label: {
                Label("영상 변환하기", systemImage: "film.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.clips.isEmpty)
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
