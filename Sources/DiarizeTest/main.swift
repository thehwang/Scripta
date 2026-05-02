import Foundation
import ScriptaCore

/// Read a 16-bit PCM WAV file (as produced by ffmpeg) into Float32 samples.
func readWAV(_ path: String) -> (samples: [Float], sampleRate: Int)? {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("ERROR: Cannot read file: \(path)")
        return nil
    }
    guard data.count > 44 else {
        print("ERROR: File too small to be a valid WAV")
        return nil
    }

    // Verify RIFF/WAVE header
    let riff = String(data: data[0..<4], encoding: .ascii)
    let wave = String(data: data[8..<12], encoding: .ascii)
    guard riff == "RIFF", wave == "WAVE" else {
        print("ERROR: Not a valid WAV file (header: \(riff ?? "?") / \(wave ?? "?"))")
        return nil
    }

    // Parse fmt chunk
    var pos = 12
    var audioFormat: UInt16 = 0
    var channels: UInt16 = 0
    var sampleRate: UInt32 = 0
    var bitsPerSample: UInt16 = 0
    var dataStart = 0
    var dataSize: UInt32 = 0

    while pos + 8 <= data.count {
        let chunkID = String(data: data[pos..<(pos + 4)], encoding: .ascii) ?? ""
        let chunkSize: UInt32 = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: pos + 4, as: UInt32.self)
        }

        if chunkID == "fmt " {
            audioFormat = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos + 8, as: UInt16.self) }
            channels = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos + 10, as: UInt16.self) }
            sampleRate = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos + 12, as: UInt32.self) }
            bitsPerSample = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos + 22, as: UInt16.self) }
        } else if chunkID == "data" {
            dataStart = pos + 8
            dataSize = chunkSize
            break
        }

        pos += 8 + Int(chunkSize)
        if pos % 2 != 0 { pos += 1 }
    }

    guard dataStart > 0, dataSize > 0 else {
        print("ERROR: No data chunk found in WAV")
        return nil
    }

    print("  WAV: \(sampleRate)Hz, \(channels)ch, \(bitsPerSample)bit, format=\(audioFormat)")

    // Convert to Float32 samples
    var samples: [Float] = []
    let bytesPerSample = Int(bitsPerSample) / 8

    if audioFormat == 1 && bitsPerSample == 16 {
        // PCM 16-bit signed integer
        let sampleCount = Int(dataSize) / bytesPerSample
        samples.reserveCapacity(sampleCount)
        data.withUnsafeBytes { raw in
            for i in 0..<sampleCount {
                let offset = dataStart + i * 2
                guard offset + 1 < raw.count else { return }
                let val = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                samples.append(Float(val) / 32768.0)
            }
        }
    } else if audioFormat == 3 && bitsPerSample == 32 {
        // IEEE Float32
        let sampleCount = Int(dataSize) / 4
        samples.reserveCapacity(sampleCount)
        data.withUnsafeBytes { raw in
            for i in 0..<sampleCount {
                let offset = dataStart + i * 4
                guard offset + 3 < raw.count else { return }
                let val = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                samples.append(val)
            }
        }
    } else {
        print("ERROR: Unsupported WAV format (audioFormat=\(audioFormat), bits=\(bitsPerSample))")
        print("  Convert with: ffmpeg -i input.wav -ar 16000 -ac 1 -acodec pcm_s16le output.wav")
        return nil
    }

    // If stereo, downmix to mono
    if channels == 2 {
        var mono: [Float] = []
        mono.reserveCapacity(samples.count / 2)
        for i in stride(from: 0, to: samples.count - 1, by: 2) {
            mono.append((samples[i] + samples[i + 1]) * 0.5)
        }
        return (mono, Int(sampleRate))
    }

    return (samples, Int(sampleRate))
}

func run() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        print("Usage: DiarizeTest <audio.wav> [--interval <seconds>]")
        exit(1)
    }

    let wavPath = args[1]
    var entryInterval: Double = 10.0
    var mergeThreshold: Float? = nil
    if let idx = args.firstIndex(of: "--interval"), idx + 1 < args.count,
       let val = Double(args[idx + 1]) {
        entryInterval = val
    }
    if let idx = args.firstIndex(of: "--threshold"), idx + 1 < args.count,
       let val = Float(args[idx + 1]) {
        mergeThreshold = val
    }

    guard FileManager.default.fileExists(atPath: wavPath) else {
        print("ERROR: File not found: \(wavPath)")
        exit(1)
    }

    print("Reading: \(wavPath)")
    guard let (rawSamples, fileSR) = readWAV(wavPath) else { exit(1) }

    // Resample to 16kHz if needed (simple linear interpolation)
    let targetRate: Double = 16000
    let audioBuffer: [Float]
    if fileSR == Int(targetRate) {
        audioBuffer = rawSamples
    } else {
        print("  Resampling \(fileSR)Hz → \(Int(targetRate))Hz...")
        let ratio = Double(fileSR) / targetRate
        let outCount = Int(Double(rawSamples.count) / ratio)
        var resampled = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) * ratio
            let idx = Int(srcPos)
            let frac = Float(srcPos - Double(idx))
            if idx + 1 < rawSamples.count {
                resampled[i] = rawSamples[idx] * (1 - frac) + rawSamples[idx + 1] * frac
            } else if idx < rawSamples.count {
                resampled[i] = rawSamples[idx]
            }
        }
        audioBuffer = resampled
    }

    let durationSec = Double(audioBuffer.count) / targetRate
    print("  Loaded \(audioBuffer.count) samples (\(String(format: "%.1f", durationSec))s)\n")

    // Create synthetic entries
    let recordingStart = Date()
    var entries: [TranscriptEntry] = []
    var t: Double = 0
    while t < durationSec {
        entries.append(TranscriptEntry(
            speaker: "Remote", text: "seg_\(entries.count)",
            timestamp: recordingStart.addingTimeInterval(t)))
        t += entryInterval
    }
    print("Created \(entries.count) entries at \(entryInterval)s intervals\n")

    // Run segment-level diarization (raw, no entry mapping)
    print("Running segment-level diarization...")
    let start = CFAbsoluteTimeGetCurrent()

    if let t = mergeThreshold {
        print("  Using merge threshold: \(t)")
    }
    let segments = SpeakerDiarizer.diarizeSegments(
        audioBuffer: audioBuffer,
        sampleRate: targetRate,
        mergeThreshold: mergeThreshold
    )

    let elapsed = CFAbsoluteTimeGetCurrent() - start
    print("Completed in \(String(format: "%.2f", elapsed))s\n")

    let sep = String(repeating: "=", count: 70)
    print(sep)
    print("SEGMENT-LEVEL DIARIZATION RESULTS")
    print(sep)
    print("  Start    End      Duration  Speaker")
    print(String(repeating: "-", count: 70))

    var clusterCounts: [Int: Int] = [:]
    var clusterDuration: [Int: Double] = [:]

    for seg in segments {
        let startSec = Double(seg.startSample) / targetRate
        let endSec = Double(seg.endSample) / targetRate
        let dur = endSec - startSec

        let s1 = Int(startSec)
        let s2 = Int(endSec)
        let startStr = String(format: "%02d:%02d", s1 / 60, s1 % 60)
        let endStr = String(format: "%02d:%02d", s2 / 60, s2 % 60)
        let durStr = String(format: "%.1fs", dur)
        let spk = "Speaker \(seg.cluster + 1)"

        print("  \(startStr)     \(endStr)     \(durStr.padding(toLength: 8, withPad: " ", startingAt: 0))\(spk)")
        clusterCounts[seg.cluster, default: 0] += 1
        clusterDuration[seg.cluster, default: 0] += dur
    }

    print("\nSUMMARY")
    print(String(repeating: "-", count: 40))
    print("Total segments: \(segments.count)")
    let numSpeakers = Set(segments.map(\.cluster)).count
    print("Speakers found: \(numSpeakers)")
    for cluster in clusterDuration.keys.sorted() {
        let cnt = clusterCounts[cluster, default: 0]
        let dur = clusterDuration[cluster, default: 0]
        print("  Speaker \(cluster + 1): \(cnt) segments, \(String(format: "%.1f", dur))s total")
    }
    print("\nDebug: ~/Documents/ScriptaScripts/debug.log")
}

run()
