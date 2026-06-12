// // ScreenshotHelper.swift (Using ScreenCaptureKit)

import AppKit
import ScreenCaptureKit
import Combine
import UniformTypeIdentifiers
import CoreGraphics
import CoreMedia
import CoreVideo

enum ScreenCaptureError: Error {
    case windowNotFound
    case captureFailed
    case permissionDenied
    case timeout
}

class ScreenshotHelper {
    /// Capture a window belonging to the specified process ID.
    /// Returns PNG image data of the window.
    static func captureWindow(pid: pid_t) async throws -> Data {
        // Check screen recording permission
        guard await checkScreenCapturePermission() else {
            throw ScreenCaptureError.permissionDenied
        }
        
        // Get available content
        let content = try await SCShareableContent.current
        
        // Print all windows for debugging
        print("DEBUG: All windows:")
        for window in content.windows {
            let owningPid = window.owningApplication?.processID ?? 0
            let area = window.frame.width * window.frame.height
            print("  - Window: \(window.title ?? "<No Title>"), PID: \(owningPid), OnScreen: \(window.isOnScreen), Layer: \(window.windowLayer), Frame: \(window.frame), Area: \(area)")
        }
        
        // Find the best target window for the PID
        var targetWindow: SCWindow?
        
        // Strategy 1: On-screen, > 1x1 size, largest area first
        print("Window Selection Strategy 1: OnScreen=true, Size > 1x1, Sort by Area")
        let potentialWindows1 = content.windows.filter { window in
            window.owningApplication?.processID == pid &&
            window.isOnScreen &&
            window.frame.width > 1 &&
            window.frame.height > 1
        }.sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
        
        targetWindow = potentialWindows1.first
        
        // Strategy 2: Any screen state, > 1x1 size, largest area first
        if targetWindow == nil {
            print("Window Selection Strategy 2: OnScreen=any, Size > 1x1, Sort by Area")
            let potentialWindows2 = content.windows.filter { window in
                window.owningApplication?.processID == pid &&
                window.frame.width > 1 &&
                window.frame.height > 1
            }.sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
            targetWindow = potentialWindows2.first
        }
        
        // Strategy 3: On-screen, any size, largest area first
        if targetWindow == nil {
            print("Window Selection Strategy 3: OnScreen=true, Size >= 0x0, Sort by Area")
            let potentialWindows3 = content.windows.filter { window in
                window.owningApplication?.processID == pid &&
                window.isOnScreen
            }.sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
            targetWindow = potentialWindows3.first
        }
        
        // Strategy 4: Any screen state, any size, largest area first (Last Resort)
        if targetWindow == nil {
            print("Window Selection Strategy 4 (Last Resort): OnScreen=any, Size >= 0x0, Sort by Area")
            let potentialWindows4 = content.windows.filter { window in
                window.owningApplication?.processID == pid
            }.sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
            targetWindow = potentialWindows4.first
        }
        
        // Check if any window was found
        guard let finalTargetWindow = targetWindow else {
            print("Could not find ANY window for PID \(pid) after trying multiple strategies.")
            throw ScreenCaptureError.windowNotFound
        }
        
        // Use the finally selected window
        print("Selected target window (using strategy result): \(finalTargetWindow.title ?? "<No Title>"), Frame: \(finalTargetWindow.frame), OnScreen: \(finalTargetWindow.isOnScreen), Area: \(finalTargetWindow.frame.width * finalTargetWindow.frame.height)")
        
        // --- Capture the Specific Window --- 
        
        // Create window-specific filter
        let filter = SCContentFilter(desktopIndependentWindow: finalTargetWindow)
        
        // Configure stream for the specific window dimensions
        let config = SCStreamConfiguration()
        // Use actual window dimensions, minimum 50x50
        config.width = max(50, Int(finalTargetWindow.frame.width))
        config.height = max(50, Int(finalTargetWindow.frame.height))
        // Capture at 30fps, queue depth 1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 1
        // Ensure pixel format is usable
        config.pixelFormat = kCVPixelFormatType_32BGRA // Common format

        print("Configuring WINDOW capture with dimensions: \(config.width)x\(config.height) @ 30fps")
        
        // Create stream
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ScreenshotCaptureCompletion(continuation: continuation)
            let handler = ImageCaptureHandler(completion: completion)
            completion.cleanup = {
                print("Cleaning up window capture stream...")
                stream.stopCapture { error in
                    if let error = error { print("Error stopping stream: \(error)") }
                }
                _ = handler
            }
            completion.startTimeout(seconds: 5)
            
            do {
                try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: .main)
                print("Added stream output for window capture")
                
                stream.startCapture { error in
                    if let error = error {
                        print("Failed to start WINDOW capture: \(error)")
                        completion.resume(with: .failure(ScreenCaptureError.captureFailed))
                    } else {
                        print("Started WINDOW capture successfully")
                    }
                }
            } catch {
                print("Failed to setup WINDOW stream: \(error)")
                completion.resume(with: .failure(ScreenCaptureError.captureFailed))
            }
        }
    }
    
    /// Check if screen recording permission is granted
    static func checkScreenCapturePermission() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            print("Screen capture permission check failed: \(error)")
            return false
        }
    }
}

fileprivate final class ScreenshotCaptureCompletion {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutTask: Task<Void, Never>?
    var cleanup: (() -> Void)?

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func startTimeout(seconds: TimeInterval) {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            print("Operation timed out after \(seconds) seconds")
            self?.resume(with: .failure(ScreenCaptureError.timeout))
        }
    }

    func resume(with result: Result<Data, Error>) {
        let continuationToResume: CheckedContinuation<Data, Error>?
        let cleanupToRun: (() -> Void)?

        lock.lock()
        continuationToResume = continuation
        continuation = nil
        cleanupToRun = cleanup
        cleanup = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        lock.unlock()

        guard let continuationToResume else {
            print("Ignoring duplicate screenshot capture completion.")
            return
        }

        cleanupToRun?()

        switch result {
        case .success(let data):
            print("Resuming continuation with data.")
            continuationToResume.resume(returning: data)
        case .failure(let error):
            print("Resuming continuation with error: \(error)")
            continuationToResume.resume(throwing: error)
        }
    }
}

// Handler for capturing a single image from the stream
class ImageCaptureHandler: NSObject, SCStreamOutput {
    private let completion: ScreenshotCaptureCompletion

    fileprivate init(completion: ScreenshotCaptureCompletion) {
        self.completion = completion
        super.init()
    }

    func resumeWithError(_ error: Error) {
        completion.resume(with: .failure(error))
    }

    private func resumeReturning(_ data: Data) {
        completion.resume(with: .success(data))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        print("Processing sample buffer...")

        do {
            let data = try processBuffer(sampleBuffer)
            print("Successfully processed buffer: \(data.count) bytes")
            resumeReturning(data)
        } catch {
            print("Failed to process buffer: \(error)")
            resumeWithError(error)
        }
    }

    private func processBuffer(_ sampleBuffer: CMSampleBuffer) throws -> Data {
        guard sampleBuffer.isValid else {
            print("Error: Received invalid sample buffer")
            throw ScreenCaptureError.captureFailed
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Error: Failed to get CVPixelBuffer from sample buffer")
            throw ScreenCaptureError.captureFailed
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("Error: Failed to create CGImage from CIImage")
            throw ScreenCaptureError.captureFailed
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("Error: Failed to convert NSImage to PNG data")
            throw ScreenCaptureError.captureFailed
        }
        
        print("Buffer conversion to PNG successful.")
        return pngData
    }
}
