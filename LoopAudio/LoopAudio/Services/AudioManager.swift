import Foundation
import AVFoundation
import MediaPlayer
import Combine

public enum AntiDetectionIntensity: String, CaseIterable, Identifiable, Codable {
    case natural = "Natural"
    case balanced = "Moderado"
    case shielded = "Blindado (Audível)"

    public var id: String { rawValue }

    public var rateRange: ClosedRange<Float> {
        switch self {
        case .natural: return 0.980...1.020   // ±2.0%
        case .balanced: return 0.955...1.045  // ±4.5% (Recomendado)
        case .shielded: return 0.930...1.070  // ±7.0% (Audível e anti-ban máximo)
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

    // MARK: - Modo Live Anti-Detecção 2.0
    @Published public var isAntiDetectionEnabled: Bool = true {
        didSet {
            updateLoopMode()
            if isAntiDetectionEnabled {
                applyRandomizedParameters()
                startDriftTimer()
            } else {
                stopDriftTimer()
                currentRateFactor = 1.0
                audioPlayer?.rate = 1.0
                applyVolume()
            }
            UserDefaults.standard.set(isAntiDetectionEnabled, forKey: "LoopAudio_isAntiDetectionEnabled")
        }
    }

    @Published public var antiDetectionIntensity: AntiDetectionIntensity = .shielded {
        didSet {
            if let encoded = try? JSONEncoder().encode(antiDetectionIntensity) {
                UserDefaults.standard.set(encoded, forKey: "LoopAudio_antiDetectionIntensity")
            }
            if isAntiDetectionEnabled {
                applyRandomizedParameters()
            }
        }
    }

    @Published public private(set) var loopCycleCount: Int = 1
    @Published public private(set) var currentRateFactor: Float = 1.0
    @Published public private(set) var lastModulationTime: Date = Date()

    @Published public private(set) var currentTrack: AudioTrackInfo?
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public var errorMessage: String?

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: AnyCancellable?
    private var driftTimer: AnyCancellable?
    private var currentJitterVolume: Float = 1.0

    override private init() {
        super.init()
        let defaults = UserDefaults.standard
        self.isLoopEnabled = defaults.object(forKey: "LoopAudio_isLoopEnabled") as? Bool ?? true
        self.volume = defaults.object(forKey: "LoopAudio_volume") as? Float ?? 1.0
        self.isAntiDetectionEnabled = defaults.object(forKey: "LoopAudio_isAntiDetectionEnabled") as? Bool ?? true

        if let data = defaults.data(forKey: "LoopAudio_antiDetectionIntensity"),
           let intensity = try? JSONDecoder().decode(AntiDetectionIntensity.self, from: data) {
            self.antiDetectionIntensity = intensity
        }

        setupAudioSession()
        setupRemoteCommands()
        setupInterruptionObserver()
        loadPersistedTrack()
    }

    public func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[AudioManager] Erro ao configurar sessão: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.errorMessage = "Falha ao ativar sessão de áudio: \(error.localizedDescription)"
            }
        }
    }

    public func loadAudio(track: AudioTrackInfo, startImmediately: Bool = true) {
        stop()

        guard let url = audioFileURL(for: track.localFileName) else {
            DispatchQueue.main.async {
                self.errorMessage = "Arquivo de áudio não encontrado no dispositivo."
            }
            return
        }

        do {
            setupAudioSession()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true

            self.audioPlayer = player
            self.currentTrack = track
            self.currentTime = 0
            self.loopCycleCount = 1
            self.errorMessage = nil

            updateLoopMode()
            applyVolume()

            if isAntiDetectionEnabled {
                applyRandomizedParameters()
            }

            player.prepareToPlay()

            savePersistedTrack(track)
            updateNowPlayingInfo()

            if startImmediately {
                play()
            }
        } catch {
            print("[AudioManager] Erro ao criar AVAudioPlayer: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.errorMessage = "Erro ao carregar áudio: \(error.localizedDescription)"
            }
        }
    }

    public func play() {
        guard let player = audioPlayer else { return }
        setupAudioSession()

        if isAntiDetectionEnabled {
            applyRandomizedParameters()
            startDriftTimer()
        }

        if player.play() {
            isPlaying = true
            startProgressTimer()
            updateNowPlayingInfo()
        }
    }

    public func pause() {
        guard let player = audioPlayer, isPlaying else { return }
        player.pause()
        isPlaying = false
        stopProgressTimer()
        stopDriftTimer()
        currentTime = player.currentTime
        updateNowPlayingInfo()
    }

    public func stop() {
        if let player = audioPlayer {
            player.stop()
            player.currentTime = 0
        }
        isPlaying = false
        currentTime = 0
        loopCycleCount = 1
        stopProgressTimer()
        stopDriftTimer()
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
        let actual = isAntiDetectionEnabled ? (volume * currentJitterVolume) : volume
        audioPlayer?.volume = max(0.0, min(1.0, actual))
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

    // Gatilho para o usuário testar e ouvir a variação imediatamente
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

        // Modulação frequente a cada 7 segundos para janelas de 15-20s de live
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
        print("[AudioManager] Erro de decodificação: \(msg)")
        DispatchQueue.main.async {
            self.errorMessage = "Erro ao decodificar áudio: \(msg)"
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
