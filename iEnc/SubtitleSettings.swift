import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 자막 설정 (2.0 맛보기: 화면만 있고 변환에는 아직 쓰지 않는다 — 변환하면 자막은 모두 빠진다).
/// 인코딩 설정(EncodeSettings)과 따로 둔다: 바꿀 때마다 예상 크기를 다시 어림하지 않게
struct SubtitleDraft: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case track = "자막 트랙"
        case burn = "자막 입히기"
        var id: Self { self }
    }

    var enabled = false
    var mode = Mode.track
    var font = "Apple SD Gothic Neo"
    var size = 42.0
    var outline = true
    var shadow = false
    var color = Color.white
}

/// 구간 하나의 자막 선택
struct ClipSubtitle: Equatable {
    /// 넣을 자막 트랙 (원본의 몇 번째 자막, 0부터). nil = 모두, [] = 없음
    var tracks: [Int]?
    /// 따로 고른 자막 파일 (smi · srt · ass …)
    var external: URL?
}

/// 인코딩 설정 사이드바의 자막 묶음: 자막 포함 → 구간마다 묶음 → 자막 방식 · 안내
struct SubtitleSections: View {
    @Bindable var model: AppModel
    @State private var pickingFor: Clip.ID?
    /// 접어 둔 구간 (기본은 모두 펼침)
    @State private var collapsed: Set<Clip.ID> = []

    private static let fonts = NSFontManager.shared.availableFontFamilies
    private static let fileTypes: [UTType] = ["smi", "sami", "srt", "ass", "ssa", "vtt", "sub", "sup"]
        .compactMap { UTType(filenameExtension: $0) } + [.plainText, .data]

    private var d: Binding<SubtitleDraft> { $model.subtitle }

    var body: some View {
        // 한 묶음 안에: 자막 포함 → 구간마다 접히는 칸(DisclosureGroup) → 자막 방식 → 안내
        Section {
            Toggle("자막 포함", isOn: d.enabled)
            if model.subtitle.enabled {
                if model.clips.isEmpty {
                    Text("변환할 구간이 없습니다").foregroundStyle(.secondary)
                }
                ForEach(Array(model.clips.enumerated()), id: \.element.id) { i, clip in
                    DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(clip.id) },
                                                        set: { if $0 { collapsed.remove(clip.id) } else { collapsed.insert(clip.id) } })) {
                        tracksRow(clip)
                        externalRow(clip)
                    } label: {
                        HStack(spacing: 6) {
                            Text("구간 #\(i + 1)").fontWeight(.medium)
                            Text(clip.url.deletingPathExtension().lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Picker("자막 방식", selection: d.mode) {
                    ForEach(SubtitleDraft.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.subtitle.mode == .burn {
                    Picker("글꼴", selection: d.font) {
                        ForEach(Self.fonts, id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("크기") {
                        Stepper("\(Int(model.subtitle.size)) pt", value: d.size, in: 12...120, step: 2)
                    }
                    Toggle("외곽선", isOn: d.outline)
                    Toggle("그림자", isOn: d.shadow)
                    ColorPicker("자막 색", selection: d.color, supportsOpacity: false)
                }
            }
            notice
        } header: {
            Text("자막")
        } footer: {
            if model.subtitle.enabled {
                Text(model.subtitle.mode == .track
                     ? "자막 트랙: 켜고 끌 수 있는 자막으로 넣습니다 (MKV 는 꾸밈 그대로, MP4·MOV 는 글자만)."
                     : "자막 입히기: 영상 그림에 새겨 어떤 플레이어에서든 보입니다 (끌 수 없음, 다시 압축할 때만).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notice: some View {
        Label("자막은 아직 지원되지 않습니다. 변환할 때 모든 자막이 빠집니다.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func tracksRow(_ clip: Clip) -> some View {
        let tracks = model.metas[clip.url]?.subtitles ?? []
        let chosen = model.clipSubtitles[clip.id]?.tracks
        let included = chosen ?? Array(tracks.indices)
        // 줄 전체를 들여 쓰면 오른쪽 칸이 잘려서, 라벨만 들여 쓴다
        LabeledContent {
            if tracks.isEmpty {
                Text("없음").foregroundStyle(.secondary)
            } else {
                Menu {
                    if tracks.count > 1 {
                        Toggle("모두", isOn: Binding(get: { chosen == nil }, set: { _ in model.setClipSubtitleTracks(clip.id, toggle: nil) }))
                    }
                    Toggle("없음", isOn: Binding(get: { chosen == [] }, set: { _ in model.setClipSubtitleTracks(clip.id, toggle: -1) }))
                    Divider()
                    ForEach(tracks.indices, id: \.self) { k in
                        Toggle(tracks[k].label(k + 1), isOn: Binding(get: { included.contains(k) },
                                                                    set: { _ in model.setClipSubtitleTracks(clip.id, toggle: k) }))
                    }
                } label: {
                    Text(included.isEmpty ? "없음" : chosen == nil && tracks.count > 1 ? "모두 (\(tracks.count))"
                         : included.map { tracks[$0].short($0 + 1) }.joined(separator: "·"))
                }
                .fixedSize()
            }
        } label: {
            Text("자막 트랙").padding(.leading, 16)
        }
        // 접히는 칸 안의 줄은 높이가 빠듯해, 메뉴 단추에 마우스를 올리면 생기는 배경 위쪽이 잘린다.
        // 구간 이름과는 넉넉히, 아래 외부 자막 줄과는 좁게
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func externalRow(_ clip: Clip) -> some View {
        LabeledContent {
            if let url = model.clipSubtitles[clip.id]?.external {
                HStack(spacing: 4) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                    Button {
                        model.clipSubtitles[clip.id, default: ClipSubtitle()].external = nil
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("외부 자막 빼기")
                }
            } else {
                Button("고르기…") { pickingFor = clip.id }
                    .help("SMI · SRT · ASS · VTT 같은 자막 파일")
            }
        } label: {
            Text("외부 자막").padding(.leading, 16)
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
        .fileImporter(isPresented: Binding(get: { pickingFor == clip.id }, set: { if !$0 { pickingFor = nil } }),
                      allowedContentTypes: Self.fileTypes) { result in
            if case .success(let url) = result {
                model.clipSubtitles[clip.id, default: ClipSubtitle()].external = url
            }
        }
    }
}
