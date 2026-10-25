import AVFoundation
import Foundation

/// Peak-loudness analysis for live-photo movie clips. Returns dBFS (negative,
/// 0 = clip) or nil when the asset has no audio track. Silent or unreadable
/// audio is reported as -120 so callers can compare with a single threshold
/// instead of branching on nil.
enum LivePhotoAudioAnalysis {
    static func measurePeakDbfs(url: URL) -> Double? {
        let asset = AVAsset(url: url)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            return nil
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return nil
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.startReading()

        var peak: Int32 = 0
        while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else {
                CMSampleBufferInvalidate(buffer)
                continue
            }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            if let ptr = dataPointer, length > 0 {
                let sampleCount = length / MemoryLayout<Int16>.size
                ptr.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                    for i in 0..<sampleCount {
                        let v = Int32(abs(Int32(samples[i])))
                        if v > peak { peak = v }
                    }
                }
            }
            CMSampleBufferInvalidate(buffer)
        }
        reader.cancelReading()

        if peak <= 0 { return -120.0 }
        let normalized = Double(peak) / Double(Int16.max)
        return 20.0 * log10(normalized)
    }
}
