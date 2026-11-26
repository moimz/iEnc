import AVFoundation
import AppKit
import Observation

/// 창 하나의 상태: 자른 구간 목록(타임라인), 지금 연 영상과 고르는 구간, 미리보기 엔진, 정보·진단 값
@Observable
final class AppModel {
    let displayLayer = AVSampleBufferDisplayLayer()
    let audioRenderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    // MARK: 타임라인: 자른 구간
    var clips: [Clip] = []
    /// 타임라인 영상 줄 그림 (구간마다)
    var laneImages: [Clip.ID: [CGImage?]] = [:]
    // MARK: 왼쪽 사이드바: 불러온 영상
    var sources: [Source] = []
    /// 영상 전체 파형 (영상마다 한 번). 타임라인 구간은 이 중 제 범위를 잘라 그린다
    var sourceWaves: [URL: WavePeaks] = [:]
    /// 인코딩 설정 (오른쪽 사이드바)
    var encode = EncodeSettings()
    /// 변환 중·끝난 작업 (사이드바 맨 아래 진행 표시)
    var job: EncodeJob?
    /// 변환 전 예상 크기 (nil = 모름), 어림하는 중인지
    var estimate: Int64?
    var estimating = false
    /// 원본 정보 (변환 명령 만들 때)
    private(set) var metas: [URL: SourceMeta] = [:]
    var metasReady: Bool { sources.allSatisfy { metas[$0.url]?.height ?? 0 > 0 || metas[$0.url]?.hasAudio == true } }
    private var estimateToken = 0
    /// 타임라인에서 고른 구간. 고르면 그 원본과 범위를 연다
    var selectedClipID: Clip.ID? {
        didSet { if let id = selectedClipID, id != oldValue { load(id) } }
    }

    // MARK: 지금 연 영상
    var url: URL?
    var info = MediaInfo()
    var stats = PreviewEngine.Stats()
    var duration: Double = 0
    var frameDuration: Double = 1.0 / 30
    var position: Double = 0
    /// 고르는 구간 (재생바 노란 테두리)
    var inPoint: Double = 0
    var outPoint: Double = 0
    /// 회전 표시 (시계 방향 각도)
    var rotation: Double = 0
    /// 미리보기로 듣는 소리 트랙 (원본의 몇 번째 소리 트랙)
    var listenTrack = 0
    /// 자를 구간에 넣을 소리 트랙 (nil = 모두, [] = 소리 없이). 타임라인 구간을 고르면 그 구간의 값
    var cutTracks: [Int]?
    /// 지금 연 영상의 소리 트랙들
    var audioTracks: [AudioTrack] { url.flatMap { metas[$0]?.audioTracks } ?? [] }
    var isPlaying = false
    var isScrubbing = false
    var openError: String?
    /// 재생바 필름 띠 그림 (자리마다, 아직 안 뽑힌 칸은 nil)
    var strip: [CGImage?] = []
    /// 하드웨어(VideoToolbox) 디코딩 강제. 끄면 소프트웨어 (AV1 만 늘 하드웨어)
    var hardware = UserDefaults.standard.bool(forKey: "hardwareDecoding") {
        didSet { if let url, oldValue != hardware { open(url, range: (inPoint, outPoint)) } }
    }

    private(set) var engine: PreviewEngine?
    private var thumbnailer: Thumbnailer?
    private var stripKey = ""
    private var pendingRange: (Double, Double)?
    private var timer: Timer?
    private var laneMakers: [Clip.ID: Thumbnailer] = [:]
    private var laneKeys: [Clip.ID: String] = [:]

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
    }

    var selectedClip: Clip? { clips.first { $0.id == selectedClipID } }

    /// 고른 구간과 지금 범위가 다르면 (구간 적용 단추를 보인다)
    var selectionChanged: Bool {
        guard let clip = selectedClip else { return false }
        return clip.url != url || abs(clip.start - inPoint) > 0.0005 || abs(clip.end - outPoint) > 0.0005 || clip.audioTracks != cutTracks
    }

    // MARK: - 영상 열기

    /// 사이드바에서 영상을 누름: 구간 없이(전체 범위) 그 영상을 연다
    func openSource(_ source: Source) {
        selectedClipID = nil
        cutTracks = nil
        if source.url == url && duration > 0 {
            if isPlaying { pause() }
            inPoint = 0
            outPoint = duration
            seek(0)
        } else {
            open(source.url)
        }
    }

    /// 사이드바에서 빼기 (타임라인에 이 영상 구간이 있으면 못 뺀다)
    func removeSource(_ source: Source) {
        guard !clips.contains(where: { $0.url == source.url }) else { return }
        sources.removeAll { $0.id == source.id }
        sourceWaves[source.url] = nil
        if url == source.url { newSource() }
    }

    func sourceInUse(_ source: Source) -> Bool { clips.contains { $0.url == source.url } }

    /// 여러 영상을 한 번에 (파일 고르기·끌어 놓기): 모두 사이드바에 넣고 첫 영상을 연다.
    /// 나머지는 열지 않고 길이·썸네일·파형만 미리 만든다
    func importFiles(_ urls: [URL]) {
        guard let first = urls.first else { return }
        // 고른 순서대로 목록에 (첫 영상도 먼저 넣어 두고 연다)
        for url in urls where !sources.contains(where: { $0.url == url }) {
            sources.append(Source(url: url))
            loadMeta(url)
            if url != first { preload(url) }
        }
        openNew(first)
    }

    private func preload(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            var fmt: UnsafeMutablePointer<AVFormatContext>?
            var duration = 0.0
            if avformat_open_input(&fmt, url.path, nil, nil) == 0, let ctx = fmt {
                avformat_find_stream_info(ctx, nil)
                if ctx.pointee.duration != ienc_nopts() { duration = Double(ctx.pointee.duration) / Double(AV_TIME_BASE) }
                avformat_close_input(&fmt)
            }
            DispatchQueue.main.async {
                guard duration > 0 else { return }
                self.sourceOpened(url, duration: duration, maker: Thumbnailer(url: url))
            }
        }
    }

    /// 처음 연 영상이면 사이드바에 넣는다
    private func addSource(_ url: URL) {
        if !sources.contains(where: { $0.url == url }) { sources.append(Source(url: url)) }
        loadMeta(url)
    }

    private func loadMeta(_ url: URL) {
        guard metas[url] == nil else { return }
        metas[url] = SourceMeta()  // 자리 잡기 (두 번 읽지 않게)
        DispatchQueue.global(qos: .utility).async {
            let m = SourceMeta.probe(url)
            DispatchQueue.main.async { self.metas[url] = m; self.updateEstimate() }
        }
    }

    // MARK: - 변환

    /// 설정·구간이 바뀌면 예상 크기를 다시 (품질 기준은 시험 인코딩이라 잠깐 기다렸다가)
    func updateEstimate() {
        estimateToken += 1
        let token = estimateToken
        guard !clips.isEmpty else { estimate = nil; estimating = false; return }
        estimating = true
        let delay = encode.videoCodec != .copy && encode.rateMode == .quality ? 0.8 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard token == estimateToken else { return }
            SizeEstimate.estimate(clips: clips, settings: encode, metas: metas) { [self] bytes in
                guard token == estimateToken else { return }
                estimate = bytes
                estimating = false
            }
        }
    }

    var isEncoding: Bool { job?.state == .running }

    /// 영상 변환하기. folder 를 주면 그 폴더에 (시험용), 아니면 설정의 저장 위치
    @discardableResult
    func startEncode(folder override: URL? = nil, template overrideTemplate: String? = nil) -> Bool {
        guard !clips.isEmpty, !isEncoding else { return false }
        if isPlaying { pause() }
        let defaults = UserDefaults.standard
        let location = SaveLocation(rawValue: defaults.string(forKey: "saveLocation") ?? "") ?? .source
        var fixed: URL? = override
        if fixed == nil, location == .folder, let path = defaults.string(forKey: "saveFolder"), !path.isEmpty {
            fixed = URL(fileURLWithPath: path)
        }
        if fixed == nil, location != .source {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "여기에 저장"
            panel.message = "변환한 영상을 저장할 폴더"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            fixed = url
        }
        let template = overrideTemplate ?? defaults.string(forKey: FileNameTemplate.key) ?? FileNameTemplate.defaultValue
        let outputs = EncodePlan.make(clips: clips, settings: encode, metas: metas,
                                      folder: { fixed ?? $0.deletingLastPathComponent() }, template: template)
        let job = EncodeJob(outputs: outputs, ffmpeg: EncodePlan.ffmpeg(for: encode))
        job.estimatedBytes = estimate
        self.job = job
        job.start()
        return true
    }

    func cancelEncode() { job?.cancel() }

    /// 끝난 표시를 치우고 다시 설정 화면으로
    func dismissJob() { if !isEncoding { job = nil } }

    /// 영상 길이를 알게 되면: 사이드바 썸네일 + 영상 전체 파형 (한 번만)
    private func sourceOpened(_ url: URL, duration: Double, maker: Thumbnailer? = nil) {
        guard let i = sources.firstIndex(where: { $0.url == url }) else { return }
        sources[i].duration = duration
        if sources[i].thumbnail == nil, let thumbnailer = maker ?? (url == self.url ? thumbnailer : nil) {
            thumbnailer.image(at: min(duration * 0.1, 60), height: 240) { [weak self] image in
                guard let self, let i = self.sources.firstIndex(where: { $0.url == url }) else { return }
                self.sources[i].thumbnail = image
                self.sources[i].thumbnailTried = true
            }
        }
        guard sourceWaves[url] == nil, duration > 0 else { return }
        sourceWaves[url] = WavePeaks(peak: [], rms: [], done: false, progress: 0, duration: duration)
        Waveform.make(url: url, start: 0, end: duration) { [weak self] peaks in
            guard let self, self.sources.contains(where: { $0.url == url }) else { return false }
            if let peaks { self.sourceWaves[url] = peaks }
            return true
        }
    }

    /// 새 영상을 연다 (타임라인 선택은 풂: 이제부터 자르는 건 새 구간)
    func openNew(_ url: URL) {
        selectedClipID = nil
        open(url)
    }

    /// 파일 › 새 프로젝트: 불러온 영상·자른 구간·파형을 모두 비운다 (저장하지 않는 앱이라 이게 "처음부터")
    /// 인코딩 설정은 그대로 둔다
    func resetProject() {
        guard !isEncoding else { return }
        job = nil
        estimate = nil
        newSource()
        clips = []
        sources = []
        sourceWaves = [:]  // 만드는 중인 파형은 목록에 영상이 없어서 스스로 멈춘다
        laneImages = [:]
        laneMakers = [:]
        laneKeys = [:]
    }

    var isEmptyProject: Bool { sources.isEmpty && clips.isEmpty }
    /// 새 프로젝트 확인 창 띄우기 (메뉴에서)
    var askReset = false

    /// 빈 상태로 (지금 연 영상을 목록에서 뺄 때)
    func newSource() {
        selectedClipID = nil
        closeSource()
    }

    private func closeSource() {
        engine?.pause()
        stopTimer()
        isPlaying = false
        engine = nil
        thumbnailer = nil
        url = nil
        info = MediaInfo()
        stats = PreviewEngine.Stats()
        duration = 0
        position = 0
        inPoint = 0
        outPoint = 0
        strip = []
        stripKey = ""
        openError = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audioRenderer.flush()
    }

    /// range 를 주면 열고 나서 그 구간으로 맞추고 시작점을 보인다
    func open(_ url: URL, range: (Double, Double)? = nil) {
        engine?.pause()
        stopTimer()
        isPlaying = false
        self.url = url
        addSource(url)
        openError = nil
        position = range?.0 ?? 0
        duration = 0
        rotation = 0
        listenTrack = 0
        cutTracks = nil
        inPoint = range?.0 ?? 0
        outPoint = range?.1 ?? 0
        pendingRange = range
        strip = []
        stripKey = ""
        stats = PreviewEngine.Stats()
        info = MediaInfo(sections: [.init(title: "파일", rows: [("이름", url.lastPathComponent), ("상태", "읽는 중…")])])
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audioRenderer.flush()
        thumbnailer = Thumbnailer(url: url)

        DispatchQueue.global(qos: .userInitiated).async {
            let info = MediaInfo.probe(url)
            DispatchQueue.main.async { if self.url == url { self.info = info } }
        }

        let engine = PreviewEngine(url: url, renderer: displayLayer.sampleBufferRenderer, audioRenderer: audioRenderer, sync: synchronizer, hardware: hardware)
        engine.onStats { [weak self] in self?.stats = $0 }
        engine.onShown { [weak self] t in
            guard let self, !self.isScrubbing, !self.isPlaying else { return }
            self.position = t
        }
        self.engine = engine
        engine.open { [weak self, weak engine] error in
            guard let self, let engine, self.engine === engine else { return }
            self.openError = error
            self.rotation = engine.rotation
            self.listenTrack = engine.audioTrack
            self.duration = engine.duration
            self.frameDuration = engine.frameDuration
            self.sourceOpened(url, duration: engine.duration)
            if let r = self.pendingRange {
                self.inPoint = max(0, min(r.0, engine.duration))
                self.outPoint = max(self.inPoint, min(r.1, engine.duration))
                self.seek(self.inPoint)
            } else {
                self.inPoint = 0
                self.outPoint = engine.duration
            }
            self.pendingRange = nil
        }
    }

    /// 타임라인에서 고른 구간: 원본이 이미 열려 있으면 범위만, 아니면 열면서
    private func load(_ id: Clip.ID) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        if clip.url == url && duration > 0 {
            if isPlaying { pause() }
            inPoint = clip.start
            outPoint = clip.end
            seek(clip.start)
        } else {
            open(clip.url, range: (clip.start, clip.end))
        }
        cutTracks = clip.audioTracks
    }

    // MARK: - 구간 고르기

    func setIn(_ t: Double) {
        inPoint = max(0, min(t, outPoint - frameDuration))
        seek(inPoint)
    }

    func setOut(_ t: Double) {
        outPoint = min(duration, max(t, inPoint + frameDuration))
        seek(outPoint)
    }

    /// 재생 위치를 시작·끝으로 (I·O 키)
    func markIn() { setIn(position) }
    func markOut() { setOut(position) }

    // MARK: - 자르기

    /// 지금 구간을 타임라인 끝에 넣는다 (영상은 그대로 두고 또 자를 수 있다)
    func cut() {
        guard let url, outPoint > inPoint else { return }
        var clip = Clip(url: url, start: inPoint, end: outPoint)
        clip.audioTracks = cutTracks
        clips.append(clip)
        selectedClipID = nil
    }

    /// 고른 구간을 지금 범위로 고친다
    func applyToSelected() {
        guard let id = selectedClipID, let i = clips.firstIndex(where: { $0.id == id }), let url else { return }
        if clips[i].url != url { laneMakers[id] = nil }
        clips[i].url = url
        clips[i].start = inPoint
        clips[i].end = outPoint
        clips[i].audioTracks = cutTracks
        laneKeys[id] = nil  // 영상 줄 그림은 타임라인이 다시 부른다
    }

    func delete(_ ids: Set<Clip.ID>) {
        clips.removeAll { ids.contains($0.id) }
        for id in ids {
            laneImages[id] = nil; laneMakers[id] = nil; laneKeys[id] = nil
        }
        if let id = selectedClipID, ids.contains(id) { selectedClipID = nil }
    }

    /// 타임라인에서 끌어 놓기: id 구간을 target 구간 앞(또는 뒤)으로
    func moveClip(_ id: Clip.ID, beside target: Clip.ID, after: Bool) {
        guard id != target, let from = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips.remove(at: from)
        guard let to = clips.firstIndex(where: { $0.id == target }) else { clips.insert(clip, at: from); return }
        clips.insert(clip, at: after ? to + 1 : to)
    }

    func setGain(_ id: Clip.ID, _ db: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].gain = min(Clip.gainRange.upperBound, max(Clip.gainRange.lowerBound, db))
    }

    // MARK: - 타임라인 그림·파형

    /// 영상 줄: 구간 폭에 맞춰 count 칸 그림 (확대·축소로 칸 수가 바뀌면 다시)
    func requestLane(_ id: Clip.ID, count: Int, height: Int) {
        guard let clip = clips.first(where: { $0.id == id }), count > 0 else { return }
        let key = "\(clip.url.path)/\(clip.start)/\(clip.end)/\(count)/\(height)"
        guard laneKeys[id] != key else { return }
        laneKeys[id] = key
        // 이미 있는 그림은 새 칸 수에 맞을 때까지 그대로 둔다 (깜빡이지 않게)
        if laneImages[id]?.count != count { laneImages[id] = Array(repeating: nil, count: count) }
        let maker = laneMakers[id] ?? Thumbnailer(url: clip.url)
        laneMakers[id] = maker
        let times = (0..<count).map { clip.start + (Double($0) + 0.5) / Double(count) * clip.length }
        maker.strip(times: times, height: height) { [weak self] i, image in
            guard let self, self.laneKeys[id] == key, var images = self.laneImages[id], i < images.count else { return }
            images[i] = image
            self.laneImages[id] = images
        }
    }

    // MARK: - 필름 띠

    /// 재생바 폭에 맞춰 count 칸의 그림을 (다시) 뽑는다
    func requestStrip(count: Int, height: Int) {
        guard let thumbnailer, let url, duration > 0, count > 0 else { return }
        let key = "\(url.path)/\(count)/\(height)"
        guard key != stripKey else { return }
        stripKey = key
        strip = Array(repeating: nil, count: count)
        let times = (0..<count).map { (Double($0) + 0.5) / Double(count) * duration }
        thumbnailer.strip(times: times, height: height) { [weak self] i, image in
            guard let self, self.stripKey == key, i < self.strip.count else { return }
            self.strip[i] = image
        }
    }

    // MARK: - 재생

    func seek(_ time: Double) {
        if isPlaying { pause() }
        position = time
        engine?.seek(to: time)
    }

    func step(_ frames: Int) {
        if isPlaying { pause() }
        engine?.step(frames)
    }

    /// 구간에 넣을 소리 트랙을 짧게: "eng·jpn", "소리 없음". 트랙이 하나뿐이고 그대로 넣으면 nil (표시할 것 없음)
    func trackSummary(_ tracks: [Int]?, of url: URL) -> String? {
        let all = metas[url]?.audioTracks ?? []
        if tracks == [] && !all.isEmpty { return "소리 없음" }
        let list = tracks ?? Array(all.indices)
        guard all.count > 1 else { return nil }
        return list.filter { $0 < all.count }.map { all[$0].short($0 + 1) }.joined(separator: "·")
    }

    /// 미리보기로 들을 소리 트랙 바꾸기 (재생 중이면 그 자리에서 이어 재생)
    func listen(_ track: Int) {
        guard let engine, track != listenTrack else { return }
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        listenTrack = track
        engine.selectAudio(track) { [weak self] in
            if wasPlaying { self?.play() }
        }
    }

    /// 자를 구간에 넣을 트랙 하나 켜기·끄기 (모두 켜지면 nil = "모두")
    func toggleCutTrack(_ track: Int) {
        let all = Array(audioTracks.indices)
        var set = Set(cutTracks ?? all)
        if set.contains(track) { set.remove(track) } else { set.insert(track) }
        let list = all.filter { set.contains($0) }
        cutTracks = list == all ? nil : list
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// 구간 밖에 있으면 구간 시작부터. 구간 끝에 닿으면 멈춘다
    func play() {
        guard let engine, openError == nil else { return }
        let inside = position >= inPoint - frameDuration / 2 && position < outPoint - frameDuration
        let from = inside ? position : inPoint
        let stopAt = outPoint
        isPlaying = true
        engine.play(from: from) { [weak self] in
            self?.isPlaying = false
            self?.stopTimer()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine, self.isPlaying else { return }
            self.position = max(0, engine.currentTime)
            if self.position >= stopAt { self.pause() }
        }
    }

    func pause() {
        engine?.pause()
        isPlaying = false
        stopTimer()
        if let engine { position = max(0, min(engine.currentTime, duration)) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 정보 칸 + 진단 값을 한 덩어리 글로 (기록에 붙여 넣기용)
    var reportText: String {
        var lines = [info.text, "[미리보기 진단]"]
        lines.append("  디코더: \(stats.decoder)")
        lines.append(String(format: "  열기: %.0fms", stats.openMs))
        if stats.seekCount > 0 {
            lines.append(String(format: "  탐색: %d번 · 평균 %.1fms · 최대 %.1fms", stats.seekCount, stats.seekTotalMs / Double(stats.seekCount), stats.seekMaxMs))
        }
        lines.append("  마지막 탐색: \(stats.lastSeek)")
        lines.append("  재생: \(stats.playback)")
        if !stats.errors.isEmpty { lines.append("  오류:\n" + stats.errors.map { "    - \($0)" }.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }
}
