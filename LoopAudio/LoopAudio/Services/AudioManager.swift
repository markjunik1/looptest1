import Foundation
import AVFoundation
import MediaPlayer
import Combine

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
            audioPlayer?.volume = volume
            UserDefaults.standard.set(volume, forKey: "LoopAudio_volume")
        }
    }

    @Published public private(set) var currentTrack: AudioTrackInfo?
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public var errorMessage: String?

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: AnyCancellable?

    override private init() {
        super.init()
        let defaults = UserDefaults.standard
        self.isLoopEnabled = defaults.object(forKey: "LoopAudio_isLoopEnabled") as? Bool ?? true
        self.volume = defaults.object(forKey: "LoopAudio_volume") as? Float ?? 1.0
        setupAudioSession()
        setupRemoteCommands()
        setupInterruptionObserver()
        loadPersistedTrack()
    }

    // MARK: - Audio Session

    public func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers: permite coexistir com outros apps (ex: TikTok)
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[AudioManager] Erro ao configurar sessão: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.errorMessage = "Falha ao ativar sessão de áudio: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Carregar e Reproduzir

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
            player.volume = self.volume
            player.numberOfLoops = self.isLoopEnabled ? -1 : 0
            player.prepareToPlay()

            self.audioPlayer = player
            self.currentTrack = track
            self.currentTime = 0
            self.errorMessage = nil

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
        stopProgressTimer()
        updateNowPlayingInfo()
    }

    private func updateLoopMode() {
        audioPlayer?.numberOfLoops = isLoopEnabled ? -1 : 0
    }

    // MARK: - Progress Timer

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

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Só chamado quando numberOfLoops = 0 (loop desligado)
        if !isLoopEnabled {
            isPlaying = false
            currentTime = 0
            stopProgressTimer()
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

    // MARK: - Interrupções de áudio (chamada, Siri, etc.)

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
        // Pausar quando fone de ouvido é removido (comportamento padrão iOS)
        if reason == .oldDeviceUnavailable {
            pause()
        }
    }

    // MARK: - MPRemoteCommandCenter (Tela Bloqueada)

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

    // MARK: - MPNowPlayingInfoCenter

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.fileName
        info[MPMediaItemPropertyArtist] = "LoopAudio"
        info[MPMediaItemPropertyPlaybackDuration] = track.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer?.currentTime ?? 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Arquivos e Persistência

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
        // Carrega sem auto-play na abertura fria
        loadAudio(track: track, startImmediately: false)
    }
}
