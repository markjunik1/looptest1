import SwiftUI

public struct ContentView: View {

    @StateObject private var audio = AudioManager.shared
    @State private var showingPicker = false
    @State private var isProcessing = false
    @State private var processingProgress: Float = 0
    @State private var alertMessage: String?
    @State private var showAlert = false

    public init() {}

    public var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    trackInfoSection
                    playbackControlsSection
                    volumeSection
                    loopToggleSection
                    pickerButtonSection
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
            }

            if isProcessing {
                processingOverlay
            }
        }
        .sheet(isPresented: $showingPicker) {
            VideoPicker(
                isProcessing: $isProcessing,
                processingProgress: $processingProgress,
                onAudioExtracted: { track in
                    audio.loadAudio(track: track, startImmediately: true)
                },
                onError: { message in
                    alertMessage = message
                    showAlert = true
                }
            )
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("Aviso"),
                message: Text(alertMessage ?? "Ocorreu um erro."),
                dismissButton: .default(Text("OK"))
            )
        }
        // Exibir erro do AudioManager como alerta
        .onChange(of: audio.errorMessage) { msg in
            if let msg = msg {
                alertMessage = msg
                showAlert = true
                audio.errorMessage = nil
            }
        }
    }

    // MARK: - Seções

    private var headerSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "repeat.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.accentColor)
                Text("ÁUDIO EM LOOP")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .tracking(1.2)
            }
            Text("Extrai e repete o áudio de qualquer vídeo")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    private var trackInfoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ARQUIVO ATUAL")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)

                    if let track = audio.currentTrack {
                        Text(track.fileName)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(2)
                    } else {
                        Text("Nenhum vídeo selecionado")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()

                if audio.isPlaying {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Tocando")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(8)
                }
            }

            Divider()

            HStack(spacing: 4) {
                Text("Tempo:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let track = audio.currentTrack {
                    Text("\(formatTime(audio.currentTime)) / \(track.formattedDuration)")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                } else {
                    Text("00:00 / 00:00")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(18)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 2)
    }

    private var playbackControlsSection: some View {
        HStack(spacing: 16) {
            // Play
            Button(action: { audio.play() }) {
                Label("Reproduzir", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(audio.currentTrack != nil && !audio.isPlaying ? Color.blue : Color.gray.opacity(0.35))
                    .cornerRadius(14)
            }
            .disabled(audio.currentTrack == nil || audio.isPlaying)

            // Pause
            Button(action: { audio.pause() }) {
                Label("Pausar", systemImage: "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(UIColor.tertiarySystemFill))
                    .cornerRadius(14)
            }
            .disabled(!audio.isPlaying)

            // Stop
            Button(action: { audio.stop() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.red)
                    .frame(width: 52, height: 52)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(14)
            }
            .disabled(audio.currentTrack == nil)
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Volume Interno")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(Int(audio.volume * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Slider(value: $audio.volume, in: 0...1)
                    .accentColor(.blue)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var loopToggleSection: some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: "repeat")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(audio.isLoopEnabled ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Loop Contínuo")
                        .font(.system(size: 16, weight: .medium))
                    Text(audio.isLoopEnabled ? "Gapless — reinicia sem intervalo" : "Reproduz apenas uma vez")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $audio.isLoopEnabled)
                .labelsHidden()
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var pickerButtonSection: some View {
        Button(action: { showingPicker = true }) {
            HStack(spacing: 10) {
                Image(systemName: audio.currentTrack == nil ? "plus.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 18, weight: .bold))
                Text(audio.currentTrack == nil ? "Adicionar Vídeo da Fototeca" : "Escolher Outro Vídeo")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.accentColor)
            .cornerRadius(16)
            .shadow(color: Color.accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .padding(.top, 4)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView(value: Double(processingProgress))
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.6)

                Text("Extraindo áudio do vídeo...")
                    .font(.headline)
                    .foregroundColor(.white)

                Text("Processamento 100% local")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.75))
            }
            .padding(36)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(UIColor.systemGray6).opacity(0.92))
            )
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, !seconds.isNaN else { return "00:00" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
