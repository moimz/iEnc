import AVFoundation
import AppKit
import Observation

/// 창 하나의 상태: 자른 구간 목록(사이드바), 지금 연 영상과 고르는 구간, 미리보기 엔진, 정보·진단 값
@Observable
final class AppModel {
    let displayLayer = AVSampleBufferDisplayLayer()
    let audioRenderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    // MARK: 사이드바: 자른 구간
    var clips: [Clip] = []
    /// 인코딩 설정 (화면 아래. 아직 변환 기능 없음)
    var encode = EncodeSettings()
    /// 사이드바에서 고른 구간. 고르면 그 원본과 범위를 연다
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
        return clip.url != url || abs(clip.start - inPoint) > 0.0005 || abs(clip.end - outPoint) > 0.0005
    }

    // MARK: - 영상 열기

    /// 새 영상을 연다 (사이드바 선택은 풂: 이제부터 자르는 건 새 구간)
    func openNew(_ url: URL) {
        selectedClipID = nil
        open(url)
    }

    /// 사이드바 + : 빈 상태로
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
        openError = nil
        position = range?.0 ?? 0
        duration = 0
        rotation = 0
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
            self.duration = engine.duration
            self.frameDuration = engine.frameDuration
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

    /// 사이드바에서 고른 구간: 원본이 이미 열려 있으면 범위만, 아니면 열면서
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

    /// 지금 구간을 사이드바에 새로 넣는다 (영상은 그대로 두고 또 자를 수 있다)
    func cut() {
        guard let url, outPoint > inPoint else { return }
        let clip = Clip(url: url, start: inPoint, end: outPoint)
        clips.append(clip)
        makeThumbnail(for: clip.id)
        selectedClipID = nil
    }

    /// 고른 구간을 지금 범위로 고친다
    func applyToSelected() {
        guard let id = selectedClipID, let i = clips.firstIndex(where: { $0.id == id }), let url else { return }
        let startChanged = clips[i].start != inPoint || clips[i].url != url
        clips[i].url = url
        clips[i].start = inPoint
        clips[i].end = outPoint
        if startChanged { makeThumbnail(for: id) }
    }

    func delete(_ ids: Set<Clip.ID>) {
        clips.removeAll { ids.contains($0.id) }
        if let id = selectedClipID, ids.contains(id) { selectedClipID = nil }
    }

    func move(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
    }

    private func makeThumbnail(for id: Clip.ID) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        let maker = clip.url == url ? (thumbnailer ?? Thumbnailer(url: clip.url)) : Thumbnailer(url: clip.url)
        maker.image(at: clip.start, height: 240) { [weak self] image in
            guard let self, let i = self.clips.firstIndex(where: { $0.id == id }) else { return }
            self.clips[i].thumbnail = image
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
