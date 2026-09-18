import Foundation
import AVFoundation
import MediaPlayer
import Combine

public enum AntiDetectionIntensity: String, CaseIterable, Identifiable, Codable {
    case natural = "Natural"
    case balanced = "Moderado"
    case shielded = "Blindado (Audivel)"

    public var id: String { rawValue }

    public var rateRange: ClosedRange<Float> {
        switch self {
        case .natural: return 0.980...1.020   // +/-2.0%
        case .balanced: return 0.955...1.045  // +/-4.5% (Recomendado)
        case .shielded: return 0.930...1.070  // +/-7.0% (Claramente audivel e anti-ban maximo)
        }
    }

    public var volumeJitter: ClosedRange<Float> {
        switch self {
        case .natural: return 0.97...1.02
        case .balanced: return 0.94...1.04
        case .shielded: return 0.91...1.06
        }
    }

    public var microPauseRange: ClosedRange<Double> {
        switch self {
        case .natural: return 0.05...0.15
        case .balanced: return 0.10...0.30
        case .shielded: return 0.20...0.55
        }
    }
}

public final class AudioManager: NSObject, ObservableObject, AVAudioPlayerDelegate {

    public static let shared = AudioManager()

    @Published public private(set) var isPlaying: Bool = false

    @Published public var isLoopEnabled: Bool = true {
        didSet {
            updateLoopMode()
            UserDefaults.standard.set(isLoopEnabled, forKey: "LoopAudio_isLoopEnabled")
        }
    }

    @Published public var volume: Float = 1.0 {
        didSet {
            applyVolume()
            UserDefaults.standard.set(volume, forKey: "LoopAudio_volume")
        }
    }

    @Published public var isAntiDetectionEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isAntiDetectionEnabled, forKey: "LoopAudio_antiDetection")
            updateLoopMode()
            if isAntiDetectionEnabled && isPlaying {
                startDriftTimer()
                applyRandomizedParameters()
            } else {
                stopDriftTimer()
                resetModulation()
            }
        }
    }

    @Published public var antiDetectionIntensity: AntiDetectionIntensity = .balanced {
        didSet {
            if let encoded = try? JSONEncoder().encode(antiDetectionIntensity) {
                UserDefaults.standard.set(encoded, forKey: "LoopAudio_intensity")
            }
            if isAntiDetectionEnabled && isPlaying {
                applyRandomizedParameters()
            }
        }
    }

    @Published public private(set) var currentTrack: AudioTrackInfo?
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public var errorMessage: String?

    @Published public private(set) var currentRateFactor: Float = 1.0
    @Published public private(set) var loopCycleCount: Int = 1
    
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: AnyCancellable?
    private var driftTimer: AnyCancellable?
    private var currentJitterVolume: Float = 1.0
    private var lastModulationTime: Date = Date()

    private override init() {
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupInterruptionObserver()

        isLoopEnabled = UserDefaults.standard.bool(forKey: "LoopAudio_isLoopEnabled")
        if UserDefaults.standard.object(forKey: "LoopAudio_volume") != nil {
            volume = UserDefaults.standard.float(forKey: "LoopAudio_volume")
        }
        if UserDefaults.standard.object(forKey: "LoopAudio_antiDetection") != nil {
            isAntiDetectionEnabled = UserDefaults.standard.bool(forKey: "LoopAudio_antiDetection")
        }
        if let data = UserDefaults.standard.data(forKey: "LoopAudio_intensity"),
           let decoded = try? JSONDecoder().decode(AntiDetectionIntensity.self, from: data) {
            antiDetectionIntensity = decoded
        }

        loadPersistedTrack()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[AudioManager] Erro ao configurar sessao de audio: \(error.localizedDescription)")
        }
    }

    public func loadAudio(track: AudioTrackInfo, startImmediately: Bool = true) {
        guard let url = audioFileURL(for: track.localFileName) else {
            DispatchQueue.main.async {
                self.errorMessage = "Arquivo de audio nao encontrado."
            }
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            
            player.enableRate = true
            
            self.audioPlayer = player
            self.currentTrack = track
            self.currentTime = 0
            self.loopCycleCount = 1
            self.currentRateFactor = 1.0
            self.currentJitterVolume = 1.0

            updateLoopMode()
            applyVolume()
            savePersistedTrack(track)

            if startImmediately {
                play()
            } else {
                updateNowPlayingInfo()
            }

        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Nao foi possivel carregar o audio: \(error.localizedDescription)"
            }
        }
    }

    public func play() {
        guard let player = audioPlayer else { return }
        setupAudioSession()

        if isAntiDetectionEnabled {
            if player.currentTime == 0 {
                applyRandomizedParameters()
            }
            startDriftTimer()
        } else {
            resetModulation()
        }

        player.play()
        isPlaying = true
        startProgressTimer()
        updateNowPlayingInfo()
    }

    public func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
        stopDriftTimer()
        updateNowPlayingInfo()
    }

    public func stop() {
        audioPlayer?.stop()
        if let player = audioPlayer {
            player.currentTime = 0
            currentTime = 0
        }
        isPlaying = false
        loopCycleCount = 1
        stopProgressTimer()
        stopDriftTimer()
        resetModulation()
        updateNowPlayingInfo()
    }

    private func updateLoopMode() {
        guard let player = audioPlayer else { return }
        if isAntiDetectionEnabled {
            player.numberOfLoops = 0
        } else {
            player.numberOfLoops = isLoopEnabled ? -1 : 0
        }
    }

    private func applyVolume() {
        audioPlayer?.volume = volume * currentJitterVolume
    }

    private func resetModulation() {
        currentRateFactor = 1.0
        currentJitterVolume = 1.0
        audioPlayer?.rate = 1.0
        applyVolume()
    }

    public func applyRandomizedParameters() {
        guard let player = audioPlayer, isAntiDetectionEnabled else { return }

        let newRate = Float.random(in: antiDetectionIntensity.rateRange)
        currentRateFactor = newRate
        player.rate = newRate
        lastModulationTime = Date()

        currentJitterVolume = Float.random(in: antiDetectionIntensity.volumeJitter)
        applyVolume()
    }

    public func triggerInstantVariation() {
        guard let player = audioPlayer else { return }
        let current = currentRateFactor
        let target: Float = current >= 1.0 ? Float.random(in: 0.93...0.96) : Float.random(in: 1.04...1.07)
        currentRateFactor = target
        player.rate = target
        lastModulationTime = Date()
        currentJitterVolume = Float.random(in: 0.92...1.05)
        applyVolume()
    }

    private func startDriftTimer() {
        stopDriftTimer()
        guard isAntiDetectionEnabled else { return }

        driftTimer = Timer.publish(every: 7.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isPlaying, self.isAntiDetectionEnabled else { return }
                self.applyRandomizedParameters()
            }
    }

    private func stopDriftTimer() {
        driftTimer?.cancel()
        driftTimer = nil
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
            }
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if !isLoopEnabled {
            isPlaying = false
            currentTime = 0
            stopProgressTimer()
            stopDriftTimer()
            updateNowPlayingInfo()
            return
        }

        if isAntiDetectionEnabled {
            loopCycleCount += 1

            let pauseDuration = Double.random(in: antiDetectionIntensity.microPauseRange)

            DispatchQueue.main.asyncAfter(deadline: .now() + pauseDuration) { [weak self] in
                guard let self = self, self.isLoopEnabled, self.isPlaying else { return }
                self.applyRandomizedParameters()
                self.audioPlayer?.currentTime = 0
                self.audioPlayer?.play()
                self.updateNowPlayingInfo()
            }
        } else {
            player.currentTime = 0
            player.play()
            updateNowPlayingInfo()
        }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let msg = error?.localizedDescription ?? "Erro desconhecido"
        print("[AudioManager] Erro de decodificacao: \(msg)")
        DispatchQueue.main.async {
            self.errorMessage = "Erro ao decodificar audio: \(msg)"
        }
        stop()
    }

    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            pause()
        case .ended:
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                play()
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }
        if reason == .oldDeviceUnavailable {
            pause()
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.isPlaying ? self.pause() : self.play()
            return .success
        }

        center.stopCommand.isEnabled = true
        center.stopCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.fileName
        info[MPMediaItemPropertyArtist] = isAntiDetectionEnabled ? "LoopAudio (Live Shield Pro)" : "LoopAudio"
        info[MPMediaItemPropertyPlaybackDuration] = track.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer?.currentTime ?? 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(currentRateFactor) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public func audioFileURL(for fileName: String) -> URL? {
        let url = Self.documentsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func savePersistedTrack(_ track: AudioTrackInfo) {
        if let encoded = try? JSONEncoder().encode(track) {
            UserDefaults.standard.set(encoded, forKey: "LoopAudio_currentTrack")
        }
    }

    private func loadPersistedTrack() {
        guard
            let data = UserDefaults.standard.data(forKey: "LoopAudio_currentTrack"),
            let track = try? JSONDecoder().decode(AudioTrackInfo.self, from: data)
        else { return }
        loadAudio(track: track, startImmediately: false)
    }
}
