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
                // Usuário cancelou — sem erro
                return
            }

            let typeIdentifier = UTType.movie.identifier

            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
                parent.onError("O arquivo selecionado não é um formato de vídeo suportado.")
                return
            }

            DispatchQueue.main.async {
                self.parent.isProcessing = true
                self.parent.processingProgress = 0.1
            }

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] tempURL, error in
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

                // Copiar para temp controlado pelo app (o tempURL do provider é deletado após o closure)
                let fm = FileManager.default
                let safeTempURL = fm.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(tempURL.pathExtension)

                do {
                    if fm.fileExists(atPath: safeTempURL.path) {
                        try fm.removeItem(at: safeTempURL)
                    }
                    try fm.copyItem(at: tempURL, to: safeTempURL)
                } catch {
                    DispatchQueue.main.async {
                        self.parent.isProcessing = false
                        self.parent.onError("Falha ao copiar mídia: \(error.localizedDescription)")
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.parent.processingProgress = 0.3
                }

                self.extractAudio(from: safeTempURL, originalName: tempURL.deletingPathExtension().lastPathComponent)
            }
        }

        // MARK: - Extração de Áudio

        private func extractAudio(from videoURL: URL, originalName: String) {
            let asset = AVAsset(url: videoURL)

            guard !asset.tracks(withMediaType: .audio).isEmpty else {
                DispatchQueue.main.async {
                    self.parent.isProcessing = false
                    self.parent.onError("Este vídeo não possui faixa de áudio.")
                }
                try? FileManager.default.removeItem(at: videoURL)
                return
            }

            let outputFileName = UUID().uuidString + ".m4a"
            let outputURL = AudioManager.documentsDirectory.appendingPathComponent(outputFileName)

            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                DispatchQueue.main.async {
                    self.parent.isProcessing = false
                    self.parent.onError("Não foi possível iniciar a extração de áudio.")
                }
                try? FileManager.default.removeItem(at: videoURL)
                return
            }

            session.outputURL = outputURL
            session.outputFileType = .m4a
            session.shouldOptimizeForNetworkUse = false

            DispatchQueue.main.async {
                self.parent.processingProgress = 0.5
            }

            session.exportAsynchronously { [weak self] in
                guard let self = self else { return }
                try? FileManager.default.removeItem(at: videoURL)

                DispatchQueue.main.async {
                    self.parent.isProcessing = false
                    self.parent.processingProgress = 1.0

                    switch session.status {
                    case .completed:
                        let duration = CMTimeGetSeconds(asset.duration)
                        let track = AudioTrackInfo(
                            fileName: originalName,
                            duration: duration.isFinite ? duration : 0,
                            localFileName: outputFileName
                        )
                        self.parent.onAudioExtracted(track)

                    case .failed:
                        let msg = session.error?.localizedDescription ?? "Erro desconhecido"
                        self.parent.onError("Falha na extração de áudio: \(msg)")

                    case .cancelled:
                        self.parent.onError("Extração cancelada.")

                    default:
                        break
                    }
                }
            }
        }
    }
}
