//VideoHandler.swift
import Foundation

class VideoHandler {
    static let supportedFormats = ["mp4", "mov", "avi", "mkv"]
    
    static func getVideoData(from url: URL) -> Data? {
        guard supportedFormats.contains(url.pathExtension.lowercased()) else { return nil }
        return try? Data(contentsOf: url)
    }
}
