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
        // .current entrega o arquivo original imediatamente sem tentar converter
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

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

                self.fastExtractAudio(from: safeTempURL, originalName: tempURL.deletingPathExtension().lastPathComponent)
            }
        }

        private func fastExtractAudio(from videoURL: URL, originalName: String) {
            let asset = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

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

            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                DispatchQueue.main.async {
                    self.parent.isProcessing = false
                    self.parent.onError("Falha ao iniciar exportador de áudio.")
                }
                try? FileManager.default.removeItem(at: videoURL)
                return
            }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .m4a
            exportSession.shouldOptimizeForNetworkUse = false
            exportSession.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

            DispatchQueue.main.async {
                self.parent.processingProgress = 0.6
            }

            exportSession.exportAsynchronously { [weak self] in
                guard let self = self else { return }
                try? FileManager.default.removeItem(at: videoURL)

                DispatchQueue.main.async {
                    self.parent.isProcessing = false
                    self.parent.processingProgress = 1.0

                    if exportSession.status == .completed {
                        let duration = CMTimeGetSeconds(asset.duration)
                        let track = AudioTrackInfo(
                            fileName: originalName,
                            duration: duration.isFinite ? duration : 0,
                            localFileName: outputFileName
                        )
                        self.parent.onAudioExtracted(track)
                    } else {
                        let msg = exportSession.error?.localizedDescription ?? "Erro na extração rápida"
                        self.parent.onError("Falha na extração de áudio: \(msg)")
                    }
                }
            }
        }
    }
}
