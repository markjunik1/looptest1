import SwiftUI
import Photos
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
        var config = PHPickerConfiguration(photoLibrary: .shared())
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

    public class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker

        init(_ parent: VideoPicker) {
            self.parent = parent
        }

        public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let result = results.first else {
                return
            }

            DispatchQueue.main.async {
                self.parent.isProcessing = true
                self.parent.processingProgress = 0.05
            }

            // ESTRATÉGIA 1: PhotoKit Direto (Zero cópias de disco - Instantâneo para vídeos longos)
            if let assetIdentifier = result.assetIdentifier {
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
                if let phAsset = fetchResult.firstObject {
                    self.loadViaPhotoKit(phAsset: phAsset, fallbackProvider: result.itemProvider)
                    return
                }
            }

            // ESTRATÉGIA 2: Fallback caso o identificador não esteja disponível
            self.loadViaItemProvider(provider: result.itemProvider)
        }

        private func loadViaPhotoKit(phAsset: PHAsset, fallbackProvider: NSItemProvider) {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            options.progressHandler = { progress, error, stop, info in
                DispatchQueue.main.async {
                    self.parent.processingProgress = Float(progress) * 0.4
                }
            }

            let resources = PHAssetResource.assetResources(for: phAsset)
            let originalName = resources.first?.originalFilename ?? "Vídeo_Galeria"

            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { [weak self] avAsset, _, info in
                guard let self = self else { return }

                if let error = info?[PHImageErrorKey] as? Error {
                    print("[VideoPicker] Erro no PhotoKit: \(error.localizedDescription), tentando fallback...")
                    self.loadViaItemProvider(provider: fallbackProvider)
                    return
                }

                guard let avAsset = avAsset else {
                    self.loadViaItemProvider(provider: fallbackProvider)
                    return
                }

                DispatchQueue.main.async {
                    self.parent.processingProgress = 0.4
                }

                self.extractAudioFromAVAsset(asset: avAsset, originalName: originalName)
            }
        }

        private func loadViaItemProvider(provider: NSItemProvider) {
            let selectedType: String
            if let match = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .movie) == true
            }) {
                selectedType = match
            } else {
                selectedType = UTType.movie.identifier
            }

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
                    self.parent.processingProgress = 0.3
                }

                let asset = AVURLAsset(url: tempURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                self.extractAudioFromAVAsset(asset: asset, originalName: tempURL.deletingPathExtension().lastPathComponent)
            }
        }

        private func extractAudioFromAVAsset(asset: AVAsset, originalName: String) {
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

            DispatchQueue.global(qos: .userInitiated).async {
                while !isFinished {
                    let progress = exportSession.progress
                    DispatchQueue.main.async {
                        self.parent.processingProgress = 0.4 + (progress * 0.6)
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }

            exportSession.exportAsynchronously {
                isFinished = true
                semaphore.signal()
            }

            let waitResult = semaphore.wait(timeout: .now() + 60)
            isFinished = true

            if waitResult == .timedOut {
                exportSession.cancelExport()
                try? FileManager.default.removeItem(at: outputURL)
                DispatchQueue.main.async {
                    self.parent.isProcessing = false
                    self.parent.onError("Tempo limite excedido ao converter o áudio.")
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
