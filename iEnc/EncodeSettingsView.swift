import SwiftUI

/// 화면 아래 인코딩 설정: [영상] [소리] [출력] [요약 + 영상 변환하기]
struct EncodeSettingsView: View {
    @Bindable var model: AppModel
    @State private var choosingFolder = false

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
                column("출력") { output }
                Divider()
                summary
                    .frame(width: 200)
                    .padding(12)
            }
        }
        .background(.background.secondary)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.encode.folder = url }
        }
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                content()
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    ForEach(EncodeSettings.Resolution.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Text("프레임").font(.caption).foregroundStyle(.secondary)
                Picker("프레임률", selection: s.frameRate) {
                    ForEach(EncodeSettings.FrameRate.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
            }
        }
        .disabled(copyVideo)
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

    // MARK: - 출력

    @ViewBuilder private var output: some View {
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
        row("저장 위치") {
            HStack(spacing: 6) {
                Text(model.encode.folder?.lastPathComponent ?? "원본과 같은 폴더")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("바꾸기…") { choosingFolder = true }
                if model.encode.folder != nil {
                    Button("원본 폴더로") { model.encode.folder = nil }
                }
            }
        }
        row("이름 뒤") {
            TextField("이름 뒤에 붙일 글자", text: s.suffix)
                .frame(width: 90)
        }
        row("") {
            HStack(spacing: 10) {
                check("자막 포함", s.keepSubtitles)
                check("제목 태그 유지", s.keepMetadata)
            }
        }
    }

    // MARK: - 요약 + 변환

    private var summary: some View {
        let total = model.clips.reduce(0) { $0 + $1.length }
        return VStack(alignment: .leading, spacing: 6) {
            Text("변환할 구간").font(.subheadline.weight(.semibold))
            Text(model.clips.isEmpty ? "자른 구간이 없습니다" : "\(model.clips.count)개 · 합계 \(FF.clock(total))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(outputCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
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
    }

    private var outputCountText: String {
        guard !model.clips.isEmpty else { return " " }
        let n = model.encode.grouping == .joined ? 1 : model.clips.count
        return "→ \(model.encode.container.rawValue) 파일 \(n)개"
    }
}

/// 체크 상자 + 글자 (row() 가 라벨을 숨겨서 글자를 따로 붙인다)
private func check(_ title: String, _ isOn: Binding<Bool>) -> some View {
    HStack(spacing: 4) {
        Toggle(title, isOn: isOn).toggleStyle(.checkbox).labelsHidden()
        Text(title).font(.caption)
    }
}
