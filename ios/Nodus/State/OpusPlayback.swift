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
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
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
    func prepare(_ bytes: Data, title: String, position: Double = 0, artworkData: Data? = nil) async throws {
        guard bytes.count <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        prepared = false; self.title = title
        artwork = SavedAudioNowPlayingInfo.artwork(artworkData)
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
        seekRevision += 1
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        let value = try await webView.callAsyncJavaScript("""
            const a=document.getElementById('audio');
            if(a.ended || a.currentTime >= a.duration - 0.05) {
              await new Promise((resolve,reject)=>{
                const done=()=>{clearTimeout(timer);a.removeEventListener('seeked',done);resolve();};
                const timer=setTimeout(()=>{a.removeEventListener('seeked',done);reject(new Error('No se pudo reiniciar el episodio.'));},5000);
                a.addEventListener('seeked',done);a.currentTime=0;if(!a.seeking)done();
              });
            }
            await a.play();return a.currentTime;
            """, arguments: [:], in: nil, contentWorld: .page)
        if let value = value as? Double { position = value }
        playing = true; updateNowPlaying()
    }
    func pause() async {
        seekRevision += 1
        _ = try? await webView.callAsyncJavaScript("document.getElementById('audio')?.pause();", arguments: [:], in: nil, contentWorld: .page)
        playing = false; updateNowPlaying()
    }
    func seek(_ value: Double) async {
        guard prepared, value.isFinite else { return }
        seekRevision += 1
        trace("seek:\(value)")
        position = min(duration, max(0, value))
        _ = try? await webView.callAsyncJavaScript("""
            const a=document.getElementById('audio');
            if(Math.abs(a.currentTime-position)>0.001 || a.seeking) {
              await new Promise((resolve,reject)=>{
                const done=()=>{clearTimeout(timer);a.removeEventListener('seeked',done);resolve();};
                const timer=setTimeout(()=>{a.removeEventListener('seeked',done);reject(new Error('No se pudo cambiar la posición del episodio.'));},5000);
                a.addEventListener('seeked',done);a.currentTime=position;if(!a.seeking)done();
              });
            }
            """, arguments: ["position": position], in: nil, contentWorld: .page)
        updateNowPlaying()
    }
    func changeRate(_ value: Float) async {
        seekRevision += 1
        rate = value
        _ = try? await webView.callAsyncJavaScript("document.getElementById('audio').playbackRate=rate;", arguments: ["rate": value], in: nil, contentWorld: .page)
        updateNowPlaying()
    }
    func poll() async {
        let revision = seekRevision
        guard prepared, let result = try? await webView.callAsyncJavaScript("const a=document.getElementById('audio');return {position:a.currentTime,playing:!a.paused&&!a.ended};", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] else { return }
        guard revision == seekRevision else { return }
        position = result["position"] as? Double ?? position
        trace("clock:\(position)")
        playing = result["playing"] as? Bool ?? false
        updateNowPlaying()
    }
    func stop() async {
        seekRevision += 1
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
        center.playCommand.isEnabled = true; center.pauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true; center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.isEnabled = true; center.skipForwardCommand.preferredIntervals = [15]
        targets.append((center.playCommand, center.playCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in try? await self?.play() }; return .success
        }))
        targets.append((center.pauseCommand, center.pauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in await self?.pause() }; return .success
        }))
        targets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor [weak self] in await self?.seek(position) }; return .success
        }))
        for (command, delta) in [(center.skipBackwardCommand, -15.0), (center.skipForwardCommand, 15.0)] {
            targets.append((command, command.addTarget { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in guard let self else { return }; await self.seek(self.position + delta) }; return .success
            }))
        }
    }
    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = SavedAudioNowPlayingInfo.metadata(title: title,
            duration: duration, position: position, playing: playing, rate: rate, artwork: artwork)
    }
    private func trace(_ event: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_AUDIO_TRACE"] == "1" {
            print("[acceptance-opus] \(event)")
        }
        #endif
    }
}
