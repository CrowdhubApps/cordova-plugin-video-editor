//
//  SDAVAssetExportSession.swift
//
//  Swift rewrite of SDAVAssetExportSession by Olivier Poitrey.
//  Provides custom video/audio settings for export (bitrate, sample rate, etc.)
//  unlike AVAssetExportSession which only supports preset-based encoding.
//

import Foundation
import AVFoundation
import CoreVideo

@objc protocol SDAVAssetExportSessionDelegate: AnyObject {
    func exportSession(
        _ exportSession: SDAVAssetExportSession,
        renderFrame pixelBuffer: CVPixelBuffer,
        withPresentationTime presentationTime: CMTime,
        toBuffer renderBuffer: CVPixelBuffer
    )
}

class SDAVAssetExportSession: NSObject {

    @objc weak var delegate: SDAVAssetExportSessionDelegate?

    @objc private(set) var asset: AVAsset
    @objc var videoComposition: AVVideoComposition?
    @objc var audioMix: AVAudioMix?
    @objc var outputFileType: AVFileType = .mp4
    @objc var outputURL: URL?
    @objc var videoInputSettings: [String: Any]?
    @objc var videoSettings: [String: Any]?
    @objc var audioSettings: [String: Any]?
    @objc var timeRange: CMTimeRange = CMTimeRangeMake(start: .zero, duration: .positiveInfinity)
    @objc var shouldOptimizeForNetworkUse: Bool = false
    @objc var metadata: [AVMetadataItem] = []

    @objc private(set) var progress: Float = 0

    @objc var status: AVAssetExportSession.Status {
        switch writer?.status {
        case .writing:   return .exporting
        case .failed:    return .failed
        case .completed: return .completed
        case .cancelled: return .cancelled
        default:         return .unknown
        }
    }

    var exportError: Error? {
        return internalError ?? writer?.error ?? reader?.error
    }

    private var internalError: Error?
    private var reader: AVAssetReader?
    private var videoOutput: AVAssetReaderVideoCompositionOutput?
    private var audioOutput: AVAssetReaderAudioMixOutput?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var inputQueue: DispatchQueue?
    private var completionHandler: (() -> Void)?

    private var duration: TimeInterval = 0
    private var lastSamplePresentationTime: CMTime = .zero

    @objc static func exportSession(withAsset asset: AVAsset) -> SDAVAssetExportSession {
        return SDAVAssetExportSession(asset: asset)
    }

    @objc init(asset: AVAsset) {
        self.asset = asset
        super.init()
    }

    @objc func exportAsynchronously(completionHandler handler: @escaping () -> Void) {
        cancelExport()
        self.completionHandler = handler

        guard let outputURL = outputURL else {
            internalError = NSError(
                domain: AVFoundationErrorDomain,
                code: AVError.exportFailed.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Output URL not set"]
            )
            handler()
            return
        }

        try? FileManager.default.removeItem(at: outputURL)

        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            internalError = error
            handler()
            return
        }

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: outputFileType)
        } catch {
            internalError = error
            handler()
            return
        }

        reader!.timeRange = timeRange
        writer!.shouldOptimizeForNetworkUse = shouldOptimizeForNetworkUse
        writer!.metadata = metadata

        if CMTIME_IS_VALID(timeRange.duration) && !CMTIME_IS_POSITIVE_INFINITY(timeRange.duration) {
            duration = CMTimeGetSeconds(timeRange.duration)
        } else {
            duration = CMTimeGetSeconds(asset.duration)
        }

        let videoTracks = asset.tracks(withMediaType: .video)

        // Video output
        if !videoTracks.isEmpty {
            videoOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: videoInputSettings
            )
            videoOutput!.alwaysCopiesSampleData = false
            videoOutput!.videoComposition = videoComposition ?? buildDefaultVideoComposition()

            if reader!.canAdd(videoOutput!) {
                reader!.add(videoOutput!)
            }

            // Video input
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput!.expectsMediaDataInRealTime = false
            if writer!.canAdd(videoInput!) {
                writer!.add(videoInput!)
            }

            let renderSize = videoOutput!.videoComposition!.renderSize
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: renderSize.width,
                kCVPixelBufferHeightKey as String: renderSize.height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            videoPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput!,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )
        }

        // Audio output
        let audioTracks = asset.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            audioOutput!.alwaysCopiesSampleData = false
            audioOutput!.audioMix = audioMix
            if reader!.canAdd(audioOutput!) {
                reader!.add(audioOutput!)
            }

            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput!.expectsMediaDataInRealTime = false
            if writer!.canAdd(audioInput!) {
                writer!.add(audioInput!)
            }
        }

        writer!.startWriting()
        reader!.startReading()
        writer!.startSession(atSourceTime: timeRange.start)

        var videoCompleted = false
        var audioCompleted = false

        func checkCompletion() {
            if videoCompleted && audioCompleted {
                self.finish()
            }
        }

        let inputQueue = DispatchQueue(label: "VideoEncoderInputQueue", qos: .userInitiated)
        self.inputQueue = inputQueue

        if !videoTracks.isEmpty {
            videoInput!.requestMediaDataWhenReady(on: inputQueue) { [weak self] in
                guard let self = self else { return }
                if !self.encodeReadySamples(from: self.videoOutput!, to: self.videoInput!) {
                    videoCompleted = true
                    checkCompletion()
                }
            }
        } else {
            videoCompleted = true
        }

        if let audioInput = audioInput {
            audioInput.requestMediaDataWhenReady(on: inputQueue) { [weak self] in
                guard let self = self else { return }
                if !self.encodeReadySamples(from: self.audioOutput!, to: self.audioInput!) {
                    audioCompleted = true
                    checkCompletion()
                }
            }
        } else {
            audioCompleted = true
        }
    }

    private func encodeReadySamples(from output: AVAssetReaderOutput, to input: AVAssetWriterInput) -> Bool {
        while input.isReadyForMoreMediaData {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                return false
            }

            var handled = false
            var encodeError = false

            if reader?.status != .reading || writer?.status != .writing {
                handled = true
                encodeError = true
            }

            if !handled, output === videoOutput {
                lastSamplePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                lastSamplePresentationTime = CMTimeSubtract(lastSamplePresentationTime, timeRange.start)
                progress = duration == 0 ? 1.0 : Float(CMTimeGetSeconds(lastSamplePresentationTime) / duration)

                if let delegate = delegate,
                   let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                   let adaptor = videoPixelBufferAdaptor,
                   let pool = adaptor.pixelBufferPool {
                    var renderBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &renderBuffer)
                    if let renderBuffer = renderBuffer {
                        delegate.exportSession(
                            self,
                            renderFrame: pixelBuffer,
                            withPresentationTime: lastSamplePresentationTime,
                            toBuffer: renderBuffer
                        )
                        if !adaptor.append(renderBuffer, withPresentationTime: lastSamplePresentationTime) {
                            encodeError = true
                        }
                    }
                    handled = true
                }
            }

            if !handled && !input.append(sampleBuffer) {
                encodeError = true
            }

            if encodeError {
                return false
            }
        }
        return true
    }

    private func buildDefaultVideoComposition() -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        let videoTrack = asset.tracks(withMediaType: .video)[0]

        var trackFrameRate: Float = 0
        if let compressionProps = videoSettings?[AVVideoCompressionPropertiesKey] as? [String: Any],
           let maxKeyFrameInterval = compressionProps[AVVideoMaxKeyFrameIntervalKey] as? NSNumber {
            trackFrameRate = maxKeyFrameInterval.floatValue
        } else {
            trackFrameRate = videoTrack.nominalFrameRate
        }
        if trackFrameRate == 0 { trackFrameRate = 30 }

        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(trackFrameRate))

        let targetWidth = (videoSettings?[AVVideoWidthKey] as? NSNumber)?.floatValue ?? 0
        let targetHeight = (videoSettings?[AVVideoHeightKey] as? NSNumber)?.floatValue ?? 0
        let targetSize = CGSize(width: CGFloat(targetWidth), height: CGFloat(targetHeight))

        var naturalSize = videoTrack.naturalSize
        var transform = videoTrack.preferredTransform
        let angleInDegrees = atan2(transform.b, transform.a) * 180 / .pi
        if angleInDegrees == 90 || angleInDegrees == -90 {
            swap(&naturalSize.width, &naturalSize.height)
        }
        videoComposition.renderSize = naturalSize

        // Center inside target size
        let xratio = targetSize.width / naturalSize.width
        let yratio = targetSize.height / naturalSize.height
        let ratio = min(xratio, yratio)
        let postWidth = naturalSize.width * ratio
        let postHeight = naturalSize.height * ratio
        let transx = (targetSize.width - postWidth) / 2
        let transy = (targetSize.height - postHeight) / 2

        var matrix = CGAffineTransform(translationX: transx / xratio, y: transy / yratio)
        matrix = matrix.scaledBy(x: ratio / xratio, y: ratio / yratio)
        transform = transform.concatenating(matrix)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRangeMake(start: .zero, duration: asset.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        return videoComposition
    }

    private func finish() {
        guard reader?.status != .cancelled, writer?.status != .cancelled else { return }

        if writer?.status == .failed {
            complete()
        } else {
            writer?.endSession(atSourceTime: lastSamplePresentationTime)
            writer?.finishWriting { [weak self] in
                self?.complete()
            }
        }
    }

    private func complete() {
        if writer?.status == .failed || writer?.status == .cancelled {
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        completionHandler?()
        completionHandler = nil
    }

    @objc func cancelExport() {
        guard let queue = inputQueue else { return }
        queue.async { [weak self] in
            self?.writer?.cancelWriting()
            self?.reader?.cancelReading()
            self?.complete()
            self?.reset()
        }
    }

    private func reset() {
        internalError = nil
        progress = 0
        reader = nil
        videoOutput = nil
        audioOutput = nil
        writer = nil
        videoInput = nil
        videoPixelBufferAdaptor = nil
        audioInput = nil
        inputQueue = nil
        completionHandler = nil
    }
}
