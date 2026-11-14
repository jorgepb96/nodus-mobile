import AVFoundation
import Observation
import NodusKit
@preconcurrency import MediaPlayer
import WebKit

/// WebKit's Ogg demuxer handles Desktop's Opus fallback. AVAudioPlayer does not
/// prepare this container on iOS. Only verified local bytes enter this document;
/// it has no network, file navigation, providers or script-message bridge.
@Observable @MainActor
final class OpusPlayback: NSObject, WKNavigationDelegate {
    var position = 0.0
    var duration = 0.0
    var playing = false
    var rate: Float = 1
    var prepared = false
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var navigation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var navigationTimeout: Task<Void, Never>?
    @ObservationIgnored private var targets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var title = ""
    @ObservationIgnored private var seekRevision = 0

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }
    func prepare(_ bytes: Data, title: String, position: Double = 0) async throws {
        guard bytes.count <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        prepared = false; self.title = title
        let html = "<meta name='viewport' content='width=device-width'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; media-src blob:; connect-src 'none'; object-src 'none'; base-uri 'none'\"><audio id='audio' preload='auto' playsinline></audio>"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            webView.loadHTMLString(html, baseURL: nil)
            navigationTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)); self?.finishNavigation(URLError(.timedOut)) }
                catch { }
            }
        }
        let value = try await webView.callAsyncJavaScript("""
            const audio = document.getElementById('audio');
            if (!audio.canPlayType('audio/ogg; codecs="opus"')) throw new Error('Para escuchar este formato, actualiza iOS o iPadOS a 18.4 o posterior.');
            const result = await new Promise((resolve, reject) => {
              const timeout = setTimeout(() => reject(new Error('No se pudo preparar el audio guardado.')), 15000);
              audio.oncanplay = () => { clearTimeout(timeout); resolve(audio.duration); };
              audio.onerror = () => { clearTimeout(timeout); reject(new Error('El audio guardado no se puede decodificar.')); };
              const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
              window.audioURL = URL.createObjectURL(new Blob([bytes], {type:'audio/ogg'}));
              audio.src = window.audioURL; audio.load();
            });
            audio.currentTime = Math.min(Math.max(0, start), audio.duration);
            return result;
            """, arguments: ["encoded": bytes.base64EncodedString(), "start": position], in: nil, contentWorld: .page)
        guard let length = value as? Double, length.isFinite, length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        duration = length; self.position = min(max(0, position), length); prepared = true
        bindRemote(); updateNowPlaying()
    }
    func play() async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        _ = try await webView.callAsyncJavaScript("await document.getElementById('audio').play();", arguments: [:], in: nil, contentWorld: .page)
        playing = true; updateNowPlaying()
    }
    func pause() async {
        _ = try? await webView.callAsyncJavaScript("document.getElementById('audio')?.pause();", arguments: [:], in: nil, contentWorld: .page)
        playing = false; updateNowPlaying()
    }
    func seek(_ value: Double) async {
        guard prepared, value.isFinite else { return }
        seekRevision += 1
        position = min(duration, max(0, value))
        _ = try? await webView.callAsyncJavaScript("document.getElementById('audio').currentTime=position;", arguments: ["position": position], in: nil, contentWorld: .page)
        updateNowPlaying()
    }
    func changeRate(_ value: Float) async {
        rate = value
        _ = try? await webView.callAsyncJavaScript("document.getElementById('audio').playbackRate=rate;", arguments: ["rate": value], in: nil, contentWorld: .page)
        updateNowPlaying()
    }
    func poll() async {
        let revision = seekRevision
        guard prepared, let result = try? await webView.callAsyncJavaScript("const a=document.getElementById('audio');return {position:a.currentTime,playing:!a.paused&&!a.ended};", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] else { return }
        guard revision == seekRevision else { return }
        position = result["position"] as? Double ?? position
        playing = result["playing"] as? Bool ?? false
        updateNowPlaying()
    }
    func stop() async {
        navigationTimeout?.cancel(); finishNavigation(CancellationError())
        for (command, target) in targets { command.removeTarget(target) }; targets.removeAll()
        await pause()
        _ = try? await webView.callAsyncJavaScript("const a=document.getElementById('audio');a?.removeAttribute('src');a?.load();if(window.audioURL)URL.revokeObjectURL(window.audioURL);", arguments: [:], in: nil, contentWorld: .page)
        webView.stopLoading(); prepared = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishNavigation(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishNavigation(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishNavigation(error) }
    private func finishNavigation(_ error: Error?) {
        guard let continuation = navigation else { return }; navigation = nil; navigationTimeout?.cancel()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    private func bindRemote() {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        targets.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in try? await self?.play() }; return .success
        }))
        targets.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pause() }; return .success
        }))
        targets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor [weak self] in await self?.seek(position) }; return .success
        }))
    }
    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0]
    }
}
