//
//  VideoEditor.swift
//
//  Swift rewrite of VideoEditor.m
//  Requires iOS 14+
//

import Foundation
import AVFoundation
import Photos
import UIKit
import CoreMedia

@objc(VideoEditor)
class VideoEditor: CDVPlugin {

    private enum OutputFileType: Int {
        case m4v = 0
        case mpeg4 = 1
        case m4a = 2
        case quickTime = 3

        var avFileType: AVFileType {
            switch self {
            case .quickTime: return .mov
            case .m4a:       return .m4a
            case .m4v:       return .m4v
            case .mpeg4:     return .mp4
            }
        }

        var fileExtension: String {
            switch self {
            case .quickTime: return ".mov"
            case .m4a:       return ".m4a"
            case .m4v:       return ".m4v"
            case .mpeg4:     return ".mp4"
            }
        }
    }

    // MARK: - transcodeVideo

    @objc func transcodeVideo(_ command: CDVInvokedUrlCommand) {
        guard let options = command.arguments[0] as? [String: Any] else {
            sendError("Invalid arguments", for: command)
            return
        }

        let inputFilePath = options["fileUri"] as? String ?? ""
        guard let inputFileURL = url(from: inputFilePath) else {
            sendError("Invalid file URI", for: command)
            return
        }

        let videoFileName       = options["outputFileName"] as? String ?? "output"
        let outputFileTypeRaw   = options["outputFileType"] as? Int ?? OutputFileType.mpeg4.rawValue
        let outputFileType      = OutputFileType(rawValue: outputFileTypeRaw) ?? .mpeg4
        let optimizeForNetwork  = options["optimizeForNetworkUse"] as? Bool ?? false
        let saveToPhotoAlbum    = options["saveToLibrary"] as? Bool ?? true
        let maintainAspectRatio = options["maintainAspectRatio"] as? Bool ?? true
        let width               = options["width"] as? CGFloat ?? 0
        let height              = options["height"] as? CGFloat ?? 0
        let videoBitrate        = options["videoBitrate"] as? Int ?? 1_000_000
        let audioChannels       = options["audioChannels"] as? Int ?? 2
        let audioSampleRate     = options["audioSampleRate"] as? Int ?? 44_100
        let audioBitrate        = options["audioBitrate"] as? Int ?? 128_000

        if saveToPhotoAlbum && !UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(inputFileURL.path) {
            sendError("Video cannot be saved to photo album", for: command)
            return
        }

        let avAsset = AVURLAsset(url: inputFileURL)
        let videoTracks = avAsset.tracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            sendError("No video track found in input file", for: command)
            return
        }

        let cacheDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
        let outputPath = "\(cacheDir)/\(videoFileName)\(outputFileType.fileExtension)"
        let outputURL = URL(fileURLWithPath: outputPath)

        let mediaSize = track.naturalSize
        var videoWidth = mediaSize.width
        var videoHeight = mediaSize.height

        if maintainAspectRatio {
            let orientation = orientation(for: avAsset)
            if orientation == "portrait" && videoWidth > videoHeight {
                swap(&videoWidth, &videoHeight)
            }
            let aspectRatio = videoWidth / videoHeight
            if width > 0 && height > 0 {
                videoWidth = height * aspectRatio
                videoHeight = videoWidth / aspectRatio
            }
        } else {
            if width > 0 && height > 0 {
                videoWidth = width
                videoHeight = height
            }
        }

        let newWidth = Int(videoWidth)
        let newHeight = Int(videoHeight)

        print("VideoEditor: input \(mediaSize.width)x\(mediaSize.height) → output \(newWidth)x\(newHeight)")

        let encoder = SDAVAssetExportSession(asset: avAsset)
        encoder.outputFileType = outputFileType.avFileType
        encoder.outputURL = outputURL
        encoder.shouldOptimizeForNetworkUse = optimizeForNetwork
        encoder.videoSettings = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: newWidth,
            AVVideoHeightKey: newHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264High40
            ] as [String: Any]
        ]
        encoder.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: audioChannels,
            AVSampleRateKey: audioSampleRate,
            AVEncoderBitRateKey: audioBitrate
        ]

        let semaphore = DispatchSemaphore(value: 0)

        commandDelegate.run(inBackground: {
            encoder.exportAsynchronously {
                semaphore.signal()
            }

            repeat {
                let progress = Double(encoder.progress) * 100
                let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: ["progress": progress])
                result?.setKeepCallbackAs(true)
                self.commandDelegate.send(result, callbackId: command.callbackId)
                _ = semaphore.wait(timeout: .now() + 1.0)
            } while encoder.status != .completed && encoder.status != .failed && encoder.status != .cancelled

            // Send final 100% before the result
            if encoder.status == .completed {
                let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: ["progress": 100.0])
                result?.setKeepCallbackAs(true)
                self.commandDelegate.send(result, callbackId: command.callbackId)
            }

            switch encoder.status {
            case .completed:
                print("VideoEditor: export succeeded → \(outputPath)")
                if saveToPhotoAlbum {
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                    }, completionHandler: nil)
                }
                self.commandDelegate.send(
                    CDVPluginResult(status: CDVCommandStatus_OK, messageAs: outputPath),
                    callbackId: command.callbackId
                )
            case .cancelled:
                self.commandDelegate.send(
                    CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Video export cancelled"),
                    callbackId: command.callbackId
                )
            default:
                let nsError = encoder.exportError as NSError?
                let msg = "Video export failed with error: \(nsError?.localizedDescription ?? "Unknown") (\(nsError?.code ?? -1))"
                self.commandDelegate.send(
                    CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: msg),
                    callbackId: command.callbackId
                )
            }
        })
    }

    // MARK: - createThumbnail

    @objc func createThumbnail(_ command: CDVInvokedUrlCommand) {
        guard let options = command.arguments[0] as? [String: Any] else {
            sendError("Invalid arguments", for: command)
            return
        }

        let srcVideoPath    = options["fileUri"] as? String ?? ""
        let outputFileName  = options["outputFileName"] as? String ?? "thumbnail"
        let atTime          = options["atTime"] as? Float ?? 0
        let thumbWidth      = options["width"] as? CGFloat ?? 0
        let thumbHeight     = options["height"] as? CGFloat ?? 0
        let quality         = options["quality"] as? CGFloat ?? 100
        let thumbQuality    = quality / 100.0

        let time = CMTimeMakeWithSeconds(Float64(atTime), preferredTimescale: 600)
        guard var thumbnail = generateThumbnail(forVideoPath: srcVideoPath, at: time) else {
            sendError("Failed to generate thumbnail", for: command)
            return
        }

        if thumbWidth > 0 && thumbHeight > 0 {
            thumbnail = scale(image: thumbnail, to: CGSize(width: thumbWidth, height: thumbHeight))
        }

        let cacheDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
        let outputFilePath = (cacheDir as NSString).appendingPathComponent("\(outputFileName).jpg")

        guard let jpegData = thumbnail.jpegData(compressionQuality: thumbQuality),
              (try? jpegData.write(to: URL(fileURLWithPath: outputFilePath), options: .atomic)) != nil else {
            sendError("Failed to create thumbnail file", for: command)
            return
        }

        commandDelegate.send(
            CDVPluginResult(status: CDVCommandStatus_OK, messageAs: outputFilePath),
            callbackId: command.callbackId
        )
    }

    // MARK: - getVideoInfo

    @objc func getVideoInfo(_ command: CDVInvokedUrlCommand) {
        guard let options = command.arguments[0] as? [String: Any],
              let filePath = options["fileUri"] as? String,
              let fileURL = url(from: filePath) else {
            sendError("Invalid arguments", for: command)
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int64 ?? 0

        let avAsset = AVURLAsset(url: fileURL)
        let videoTracks = avAsset.tracks(withMediaType: .video)
        let audioTracks = avAsset.tracks(withMediaType: .audio)

        guard let videoTrack = videoTracks.first else {
            sendError("No video track found in file", for: command)
            return
        }
        let audioTrack = audioTracks.first

        var videoMediaType: String? = nil
        var audioMediaType: String? = nil
        if let desc = videoTrack.formatDescriptions.first {
            videoMediaType = mediaType(fromDescription: desc as! CMFormatDescription)
        }
        if let desc = audioTrack?.formatDescriptions.first {
            audioMediaType = mediaType(fromDescription: desc as! CMFormatDescription)
        }

        let mediaSize = videoTrack.naturalSize
        var videoWidth = mediaSize.width
        var videoHeight = mediaSize.height

        let videoOrientation = orientation(for: avAsset)
        if videoOrientation == "portrait" && videoWidth > videoHeight {
            swap(&videoWidth, &videoHeight)
        }

        let duration = CMTimeGetSeconds(avAsset.duration)

        var dict: [String: Any] = [
            "width":     videoWidth,
            "height":    videoHeight,
            "orientation": videoOrientation,
            "duration":  duration,
            "size":      fileSize,
            "bitrate":   videoTrack.estimatedDataRate
        ]
        dict["videoMediaType"] = videoMediaType
        dict["audioMediaType"] = audioMediaType

        commandDelegate.send(
            CDVPluginResult(status: CDVCommandStatus_OK, messageAs: dict),
            callbackId: command.callbackId
        )
    }

    // MARK: - trim

    @objc func trim(_ command: CDVInvokedUrlCommand) {
        guard let options = command.arguments[0] as? [String: Any] else {
            sendError("Invalid arguments", for: command)
            return
        }

        let inputFilePath = options["fileUri"] as? String ?? ""
        guard let inputFileURL = url(from: inputFilePath) else {
            sendError("Invalid file URI", for: command)
            return
        }
        let trimStart  = options["trimStart"] as? Float ?? 0
        let trimEnd    = options["trimEnd"] as? Float ?? 0
        let outputName = options["outputFileName"] as? String ?? "trimmed"

        let cacheDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
        let videoDir = (cacheDir as NSString).appendingPathComponent("mp4")

        do {
            try FileManager.default.createDirectory(atPath: videoDir, withIntermediateDirectories: true)
        } catch {
            sendError("Failed to create output directory: \(error.localizedDescription)", for: command)
            return
        }

        let videoOutput = (videoDir as NSString).appendingPathComponent("\(outputName).mp4")
        let outputURL = URL(fileURLWithPath: videoOutput)

        print("VideoEditor trim: \(inputFilePath) → \(videoOutput)")

        commandDelegate.run(inBackground: {
            let avAsset = AVURLAsset(url: inputFileURL)
            guard let exportSession = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
                self.sendError("Failed to create export session", for: command)
                return
            }
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true

            let preferredTimeScale: Int32 = 600
            let startTime = CMTimeMakeWithSeconds(Float64(trimStart), preferredTimescale: preferredTimeScale)
            let stopTime  = CMTimeMakeWithSeconds(Float64(trimEnd),   preferredTimescale: preferredTimeScale)
            exportSession.timeRange = CMTimeRangeFromTimeToTime(start: startTime, end: stopTime)

            let startDesc = CMTimeCopyDescription(allocator: nil, time: startTime) as String
            let stopDesc  = CMTimeCopyDescription(allocator: nil, time: stopTime) as String
            print("VideoEditor trim: duration=\(avAsset.duration.value), start=\(startDesc), end=\(stopDesc)")

            let semaphore = DispatchSemaphore(value: 0)

            exportSession.exportAsynchronously {
                semaphore.signal()
            }

            repeat {
                let progress = Double(exportSession.progress) * 100
                let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: ["progress": progress])
                result?.setKeepCallbackAs(true)
                self.commandDelegate.send(result, callbackId: command.callbackId)
                _ = semaphore.wait(timeout: .now() + 1.0)
            } while exportSession.status != .completed && exportSession.status != .failed && exportSession.status != .cancelled

            if exportSession.status == .completed {
                let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: ["progress": 100.0])
                result?.setKeepCallbackAs(true)
                self.commandDelegate.send(result, callbackId: command.callbackId)
            }

            switch exportSession.status {
            case .completed:
                print("VideoEditor trim: complete → \(videoOutput)")
                self.commandDelegate.send(
                    CDVPluginResult(status: CDVCommandStatus_OK, messageAs: videoOutput),
                    callbackId: command.callbackId
                )
            case .failed:
                let msg = exportSession.error?.localizedDescription ?? "Unknown error"
                print("VideoEditor trim: failed: \(msg)")
                self.commandDelegate.send(
                    CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: msg),
                    callbackId: command.callbackId
                )
            case .cancelled:
                print("VideoEditor trim: cancelled")
            default:
                break
            }
        })
    }

    // MARK: - Private helpers

    private func url(from filePath: String) -> URL? {
        guard !filePath.isEmpty else { return nil }
        if filePath.contains("://") {
            guard let encoded = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: encoded) else { return nil }
            return url
        }
        return URL(fileURLWithPath: filePath)
    }

    private func orientation(for asset: AVAsset) -> String {
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            return "landscape"
        }
        let size = videoTrack.naturalSize
        let txf  = videoTrack.preferredTransform

        if size.width == txf.tx && size.height == txf.ty { return "landscape" }
        if txf.tx == 0 && txf.ty == 0                    { return "landscape" }
        if txf.tx == 0 && txf.ty == size.width            { return "portrait" }
        return "portrait"
    }

    private func generateThumbnail(forVideoPath path: String, at time: CMTime) -> UIImage? {
        guard let videoURL = url(from: path) else { return nil }
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func scale(image: UIImage, to newSize: CGSize) -> UIImage {
        let scaleFactor = newSize.width / image.size.width
        let scaledSize  = CGSize(width: image.size.width * scaleFactor,
                                 height: image.size.height * scaleFactor)
        let renderer = UIGraphicsImageRenderer(size: scaledSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: scaledSize))
        }
    }

    private func mediaType(fromDescription desc: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(desc)
        let chars: [Character] = [
            Character(UnicodeScalar((code >> 24) & 0xff)!),
            Character(UnicodeScalar((code >> 16) & 0xff)!),
            Character(UnicodeScalar((code >>  8) & 0xff)!),
            Character(UnicodeScalar( code        & 0xff)!)
        ]
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    private func sendError(_ message: String, for command: CDVInvokedUrlCommand) {
        commandDelegate.send(
            CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: message),
            callbackId: command.callbackId
        )
    }
}
