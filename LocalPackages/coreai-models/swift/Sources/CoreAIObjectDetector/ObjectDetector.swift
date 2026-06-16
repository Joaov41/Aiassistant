// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAI
import CoreAIShared
import CoreGraphics
import Foundation

// MARK: - ObjectDetector

/// Core AI-backed object detector.
public struct ObjectDetector {
    private let function: InferenceFunction
    private let functionDescriptor: InferenceFunctionDescriptor

    private let imageInputName: String
    private let logitsOutputName: String
    private let boxesOutputName: String

    /// Loads the `.aimodel` at `path` and initializes a detector.
    public init(resourcesAt path: String) async throws {
        let modelURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            modelURL.pathExtension == "aimodel"
        else {
            throw DetectionRuntimeError.modelNotFound(modelURL.path)
        }

        let model = try await AIModel(contentsOf: modelURL)

        guard let descriptor = model.functionDescriptor(for: "main") else {
            throw DetectionRuntimeError.invalidConfiguration(
                "Cannot find 'main' function in model"
            )
        }

        // Discover input names
        guard let imageInputName = Self.findImageInputName(in: descriptor.inputNames) else {
            throw DetectionRuntimeError.invalidConfiguration(
                "Cannot find image input in model. Inputs: \(descriptor.inputNames)"
            )
        }

        // Discover output names
        guard let logitsOutputName = Self.findLogitsOutputName(in: descriptor.outputNames) else {
            throw DetectionRuntimeError.invalidConfiguration(
                "Cannot find logits output in model. Outputs: \(descriptor.outputNames)"
            )
        }
        guard let boxesOutputName = Self.findBoxesOutputName(in: descriptor.outputNames) else {
            throw DetectionRuntimeError.invalidConfiguration(
                "Cannot find boxes output in model. Outputs: \(descriptor.outputNames)"
            )
        }

        guard case .ndArray = descriptor.outputDescriptor(of: logitsOutputName) else {
            throw DetectionRuntimeError.outputMissing(logitsOutputName)
        }
        guard case .ndArray = descriptor.outputDescriptor(of: boxesOutputName) else {
            throw DetectionRuntimeError.outputMissing(boxesOutputName)
        }

        guard let fn = try model.loadFunction(named: "main") else {
            throw DetectionRuntimeError.invalidConfiguration(
                "Cannot load 'main' function from model"
            )
        }

        self.function = fn
        self.functionDescriptor = descriptor
        self.imageInputName = imageInputName
        self.logitsOutputName = logitsOutputName
        self.boxesOutputName = boxesOutputName
    }

    // MARK: - Inference

    /// Warm up the backend (e.g. trigger Metal kernel compilation) with a dummy pass.
    public func warmup() async throws {
        guard case .ndArray(let imageDescriptor) = functionDescriptor.inputDescriptor(of: imageInputName) else {
            throw DetectionRuntimeError.invalidConfiguration(
                "No array descriptor for image input '\(imageInputName)'"
            )
        }
        let imageArray = NDArray(descriptor: imageDescriptor)
        _ = try await function.run(inputs: [imageInputName: imageArray])
    }

    /// Detect objects in `image` using `.default` parameters.
    public func detect(image: CGImage) async throws -> [DetectedObject] {
        try await detect(image: image, parameters: .default)
    }

    /// Detect objects in `image`.
    public func detect(image: CGImage, parameters: DetectionParameters) async throws -> [DetectedObject] {
        // Build image NDArray
        guard case .ndArray(let imageDescriptor) = functionDescriptor.inputDescriptor(of: imageInputName) else {
            throw DetectionRuntimeError.invalidConfiguration(
                "No array descriptor for image input '\(imageInputName)'"
            )
        }

        let expectedShape = imageDescriptor.shape
        guard expectedShape.count == 4 else {
            throw DetectionRuntimeError.invalidConfiguration(
                "Expected 4-dimensional input shape, got \(expectedShape.count)"
            )
        }
        let height = expectedShape[2]
        let width = expectedShape[3]
        let floatPixels = try ImagePreprocessor(
            targetSize: CGSize(width: width, height: height),
            mean: parameters.normalizationMeans,
            std: parameters.normalizationStds,
            rescaleFactor: 1.0
        ).preprocessCHW(cgImage: image)

        var imageArray = NDArray(descriptor: imageDescriptor)

        if imageDescriptor.scalarType == .float16 {
            #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
            fillNDArray(&imageArray, as: Float16.self, with: floatPixels.map(Float16.init))
            #else
            fatalError("Float16 is not supported on this platform")
            #endif
        } else {
            fillNDArray(&imageArray, as: Float.self, with: floatPixels)
        }

        // Run inference and extract outputs
        var outputs = try await function.run(inputs: [imageInputName: imageArray])
        guard let logitsArray = outputs.remove(logitsOutputName)?.ndArray,
            let boxesArray = outputs.remove(boxesOutputName)?.ndArray
        else {
            throw DetectionRuntimeError.invalidConfiguration(
                "Missing one or more outputs after run."
            )
        }

        let rawOutput = DetectionOutput(
            logits: flattenAsFloat(logitsArray),
            logitsShape: logitsArray.shape,
            predictedBoxes: flattenAsFloat(boxesArray)
        )
        let inputSize = CGSize(width: image.width, height: image.height)
        return DetectionPostprocessor.decode(output: rawOutput, inputSize: inputSize, parameters: parameters)
    }

    // MARK: - Name Discovery

    static func findImageInputName(in names: [String]) -> String? {
        names.first {
            let l = $0.lowercased()
            return l.contains("pixel") || l.contains("image")
        }
    }

    static func findLogitsOutputName(in names: [String]) -> String? {
        names.first { $0.lowercased().contains("logit") }
    }

    static func findBoxesOutputName(in names: [String]) -> String? {
        names.first {
            let l = $0.lowercased()
            return l.contains("box")
        }
    }
}

// MARK: - Errors

/// Runtime errors thrown by the detection pipeline.
public enum DetectionRuntimeError: Error, LocalizedError, Sendable {
    case modelLoadFailed(String)
    case outputMissing(String)
    case invalidConfiguration(String)
    case modelNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let reason):
            return "Model load failed: \(reason)"
        case .outputMissing(let name):
            return "Expected output tensor missing: \(name)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .modelNotFound(let path):
            return "No .aimodel directory at: \(path)"
        }
    }
}
