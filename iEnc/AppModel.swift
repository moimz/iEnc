import AVFoundation
import AppKit
import Observation

/// 창 하나의 상태: 연 영상, 미리보기 엔진, 정보·진단 값
@Observable
final class AppModel {
    let displayLayer = AVSampleBufferDisplayLayer()
    let audioRenderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    var url: URL?
    var info = MediaInfo()
    var stats = PreviewEngine.Stats()
    var duration: Double = 0
    var frameDuration: Double = 1.0 / 30
    var position: Double = 0
    /// 회전 표시 (시계 방향 각도)
    var rotation: Double = 0
    var isPlaying = false
    var isScrubbing = false
    var openError: String?
    /// 하드웨어(VideoToolbox) 디코딩 강제. 끄면 소프트웨어 (AV1 만 늘 하드웨어)
    var hardware = false {
        didSet { if let url, oldValue != hardware { open(url) } }
    }

    private(set) var engine: PreviewEngine?
    private var timer: Timer?

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
    }

    func open(_ url: URL) {
        engine?.pause()
        stopTimer()
        isPlaying = false
        self.url = url
        openError = nil
        position = 0
        duration = 0
        rotation = 0
        stats = PreviewEngine.Stats()
        info = MediaInfo(sections: [.init(title: "파일", rows: [("이름", url.lastPathComponent), ("상태", "읽는 중…")])])
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audioRenderer.flush()

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
        }
    }

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

    func play() {
        guard let engine, openError == nil else { return }
        let from = position >= duration - frameDuration ? 0 : position
        isPlaying = true
        engine.play(from: from) { [weak self] in
            self?.isPlaying = false
            self?.stopTimer()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine, self.isPlaying else { return }
            self.position = max(0, engine.currentTime)
        }
    }

    func pause() {
        engine?.pause()
        isPlaying = false
        stopTimer()
        if let engine { position = max(0, engine.currentTime) }
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
