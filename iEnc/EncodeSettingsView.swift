import SwiftUI

/// 화면 아래 인코딩 설정: [영상] [소리] [출력 + 변환할 구간 + 영상 변환하기]
/// 저장 위치·파일 이름 규칙은 앱 설정(⌘,)에 있다
struct EncodeSettingsView: View {
    @Bindable var model: AppModel

    private var s: Binding<EncodeSettings> { $model.encode }
    private var copyVideo: Bool { model.encode.videoCodec == .copy }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 0) {
                column("영상") { video }
                Divider()
                column("소리") { audio }
                Divider()
                outputColumn
                    .frame(width: 250)
            }
        }
        .background(.background.secondary)
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            grid(content)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            content()
        }
        .controlSize(.small)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 영상

    @ViewBuilder private var video: some View {
        row("코덱") {
            Picker("코덱", selection: s.videoCodec) {
                ForEach(EncodeSettings.VideoCodec.allCases) { Text($0.rawValue).tag($0) }
            }
            .help("원본 그대로는 다시 압축하지 않아 빠르고 화질 손실이 없지만, 시작점이 키프레임에 맞춰져 조금 앞당겨질 수 있습니다")
        }
        row("화질") {
            HStack(spacing: 6) {
                Picker("방식", selection: s.rateMode) {
                    ForEach(EncodeSettings.RateMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                if model.encode.rateMode == .quality {
                    Slider(value: s.quality, in: 1...100, step: 1)
                        .frame(minWidth: 60)
                    Text("\(Int(model.encode.quality))")
                        .font(.caption.monospacedDigit())
                        .frame(width: 24, alignment: .trailing)
                } else {
                    TextField("Mbps", value: s.bitrate, format: .number)
                        .frame(width: 50)
                    Text("Mbps").font(.caption)
                }
            }
        }
        .disabled(copyVideo)
        row("해상도") {
            HStack(spacing: 6) {
                Picker("해상도", selection: s.resolution) {
                    ForEach(EncodeSettings.Resolution.allCases) { r in
                        Text(r.label).tag(r)
                        if r == .smallest { Divider() }
                    }
                }
                .fixedSize()
                .help("원본: 구간마다 제 해상도 (한 파일로 합칠 땐 가장 큰 것에 맞춤)")
                Text("프레임").font(.caption).foregroundStyle(.secondary)
                Picker("프레임률", selection: s.frameRate) {
                    ForEach(EncodeSettings.FrameRate.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
            }
        }
        .disabled(copyVideo)
        row("비율") {
            Picker("비율이 다를 때", selection: s.fit) {
                ForEach(EncodeSettings.Fit.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            .help("가로세로 비율이 다른 구간을 한 파일로 합칠 때: 비율을 지켜 검은 여백을 넣거나, 화면을 꽉 채우고 넘치는 가장자리를 자릅니다")
        }
        .disabled(copyVideo || model.encode.grouping != .joined)
        row("기타") {
            HStack(spacing: 10) {
                check("10비트", s.tenBit)
                    .disabled(model.encode.videoCodec != .hevc)
                    .help("HEVC Main10. HDR·그러데이션 띠가 덜 생깁니다")
                Text("디인터레이스").font(.caption).foregroundStyle(.secondary)
                Picker("디인터레이스", selection: s.deinterlace) {
                    ForEach(EncodeSettings.Deinterlace.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .help("자동: 인터레이스 표시가 있는 영상만 bwdif 로 폅니다")
            }
        }
        .disabled(copyVideo)
    }

    // MARK: - 소리

    @ViewBuilder private var audio: some View {
        row("코덱") {
            Picker("코덱", selection: s.audioCodec) {
                ForEach(EncodeSettings.AudioCodec.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
        }
        row("비트레이트") {
            Picker("비트레이트", selection: s.audioBitrate) {
                ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
            }
            .fixedSize()
        }
        .disabled(model.encode.audioCodec != .aac)
        row("채널") {
            Picker("채널", selection: s.channels) {
                ForEach(EncodeSettings.Channels.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
        }
        .disabled(model.encode.audioCodec != .aac)
        row("") {
            check("소리 크기 고르게", s.normalizeLoudness)
                .help("구간마다 소리 크기가 달라도 비슷하게 맞춥니다 (loudnorm)")
        }
        .disabled(model.encode.audioCodec != .aac)
    }

    // MARK: - 출력 + 변환할 구간 + 변환

    private var outputColumn: some View {
        let total = model.clips.reduce(0) { $0 + $1.length }
        return VStack(alignment: .leading, spacing: 8) {
            Text("출력").font(.subheadline.weight(.semibold))
            grid {
                row("형식") {
                    Picker("형식", selection: s.container) {
                        ForEach(EncodeSettings.Container.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                row("구간") {
                    Picker("구간", selection: s.grouping) {
                        ForEach(EncodeSettings.Grouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                }
                row("") {
                    HStack(spacing: 10) {
                        check("자막 포함", s.keepSubtitles)
                        check("제목 태그 유지", s.keepMetadata)
                    }
                }
            }
            Spacer(minLength: 4)
            Text(model.clips.isEmpty ? "자른 구간이 없습니다" : "구간 \(model.clips.count)개 · 합계 \(FF.clock(total)) → \(model.encode.container.rawValue) \(model.encode.grouping == .joined ? 1 : model.clips.count)개")
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
    }
}

/// 체크 상자 + 글자 (row() 가 라벨을 숨겨서 글자를 따로 붙인다)
private func check(_ title: String, _ isOn: Binding<Bool>) -> some View {
    HStack(spacing: 4) {
        Toggle(title, isOn: isOn).toggleStyle(.checkbox).labelsHidden()
        Text(title).font(.caption)
    }
}
