import Foundation

public struct AudioTrackInfo: Codable, Equatable {
    public let fileName: String
    public let duration: TimeInterval
    public let localFileName: String
    public let creationDate: Date

    public init(
        fileName: String,
        duration: TimeInterval,
        localFileName: String,
        creationDate: Date = Date()
    ) {
        self.fileName = fileName
        self.duration = duration
        self.localFileName = localFileName
        self.creationDate = creationDate
    }

    public var formattedDuration: String {
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
