import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

public struct VideoPicker: UIViewControllerRepresentable {

    @Binding public var isProcessing: Bool
    @Binding public var processingProgress: Float
    public var onAudioExtracted: (AudioTrackInfo) -> Void
    public var onError: (String) -> Void

    @Environment(\.presentationMode) private var presentationMode

    public init(
        isProcessing: Binding<Bool>,
        processingProgress: Binding<Float>,
        onAudioExtracted: @escaping (AudioTrackInfo) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self._isProcessing = isProcessing
        self._processingProgress = processingProgress
        self.onAudioExtracted = onAudioExtracted
        self.onError = onError
    }

    public func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    public class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker

        init(_ parent: VideoPicker) {
            self.parent = parent
        }

        public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let provider = results.first?.itemProvider else {
                return
            }

            // Seleciona o identificador exato nativo (ex: com.apple.quicktime-movie) para evitar transcodificacao pelo iOS
            let selectedType: String
            if let match = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .movie) == true
            }) {
                selectedType = match
            } else {
                selectedType = UTType.movie.identifier
            }

            DispatchQueue.main.async {
                self.parent.isProcessing = true
                self.parent.processingProgress = 0.05
            }

            // Carrega o arquivo diretamente sem conversao previa
            _ = provider.loadFileRepresentation(forTypeIdentifier: selectedType) { [weak self] tempURL, error in
                guard let self = self else { return }

                if let error = error {
                    DispatchQueue.main.async {
                        self.parent.isProcessing = false
                        self.parent.onError("Erro ao acessar vídeo: \(error.localizedDescription)")
                    }
                    return
                }

                guard let tempURL = tempURL else {
                    DispatchQueue.main.async {
                        self.parent.isProcessing = false
                        self.parent.onError("Arquivo de vídeo indisponível.")
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.parent.processingProgress = 0.15
                }

                // Processa diretamente na URL temporaria mantendo o closure ativo durante a extracao
                self.extractAudioDirectly(from: tempURL, originalName: tempURL.deletingPathExtension().lastPathComponent)
            }
        }

        // MARK: - Extracao Direta e Ultrarrapida (Sem duplicar video na memoria/disco)

        private func extractAudioDirectly(from videoURL: URL, originalName: String) {
            let asset = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

            // Cria uma composicao contendo SOMENTE a trilha de audio
            // Isso faz o sistema ignorar completamente a trilha de video 4K/HDR/60fps, acelerando o processo em mais de 100x
            let composition = AVMutableComposition()
            guard let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let sourceAudioTrack = asset.tracks(withMediaType: .audio).first else {
                DispatchQueue.main.async {
                    self.parent.isProcessing = false
                    self.parent.onError("Este vídeo não possui nenhuma faixa de áudio.")
                }
                return
            }

            do {
                try compAudioTrack.insertTimeRange(sourceAudioTrack.timeRange, of: sourceAudioTrack, at: .zero)
            } catch {
                DispatchQueue.main.async {
                    self.parent.isProcessing = false
                    self.parent.onError("Falha ao isolar áudio: \(error.localizedDescription)")
                }
                return
            }

            let outputFileName = UUID().uuidString + ".m4a"
            let outputURL = AudioManager.documentsDirectory.appendingPathComponent(outputFileName)

            try? FileManager.default.removeItem(at: outputURL)

            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                DispatchQueue.main.async {
                    self.parent.isProcessing = false
                    self.parent.onError("Não foi possível inicializar o conversor de áudio.")
                }
                return
            }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .m4a
            exportSession.shouldOptimizeForNetworkUse = false

            let semaphore = DispatchSemaphore(value: 0)
            var isFinished = false

            // Monitora a barra de progresso em tempo real
            DispatchQueue.global(qos: .userInitiated).async {
                while !isFinished {
                    let progress = exportSession.progress
                    DispatchQueue.main.async {
                        self.parent.processingProgress = 0.2 + (progress * 0.8)
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }

            exportSession.exportAsynchronously {
                isFinished = true
                semaphore.signal()
            }

            // Timeout de seguranca (60 segundos) para NUNCA travar infinitamente
            let waitResult = semaphore.wait(timeout: .now() + 60)
            isFinished = true

            if waitResult == .timedOut {
                exportSession.cancelExport()
                try? FileManager.default.removeItem(at: outputURL)
                DispatchQueue.main.async {
                    self.parent.isProcessing = false
                    self.parent.onError("Tempo limite excedido ao processar o vídeo.")
                }
                return
            }

            DispatchQueue.main.async {
                self.parent.isProcessing = false
                self.parent.processingProgress = 1.0

                switch exportSession.status {
                case .completed:
                    let duration = CMTimeGetSeconds(composition.duration)
                    let track = AudioTrackInfo(
                        fileName: originalName,
                        duration: duration.isFinite ? duration : 0,
                        localFileName: outputFileName
                    )
                    self.parent.onAudioExtracted(track)

                case .failed:
                    try? FileManager.default.removeItem(at: outputURL)
                    let msg = exportSession.error?.localizedDescription ?? "Erro desconhecido"
                    self.parent.onError("Falha na extração de áudio: \(msg)")

                case .cancelled:
                    try? FileManager.default.removeItem(at: outputURL)
                    self.parent.onError("Extração de áudio cancelada.")

                default:
                    try? FileManager.default.removeItem(at: outputURL)
                    self.parent.onError("Erro inesperado no processamento.")
                }
            }
        }
    }
}
