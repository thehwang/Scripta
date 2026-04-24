import Accelerate
import CoreML
import Foundation

/// Extracts 256-dim speaker embeddings from audio using a WeSpeaker ResNet34
/// CoreML model. Falls back gracefully if the model is not available.
public final class SpeakerEmbedder {

    private let model: MLModel
    private let sampleRate: Double = 16_000

    // Mel spectrogram parameters (must match model training config)
    private let nMels = 80
    private let nFFT = 512
    private let hopLength = 160       // 10ms at 16kHz
    private let winLength = 400       // 25ms at 16kHz

    // The CoreML model accepts only these mel frame counts
    private let enumeratedLengths = [20, 50, 100, 200, 300, 500, 750, 1000, 1500, 2000]

    public init(modelPath: String) throws {
        let url = URL(fileURLWithPath: modelPath)
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
        mplog("SpeakerEmbedder: loaded model from \(modelPath)")
    }

    /// Extract a 256-dim L2-normalized speaker embedding from an audio segment.
    public func embed(audioSamples: [Float]) throws -> [Float] {
        let melFrames = computeLogMelSpectrogram(audioSamples)
        guard !melFrames.isEmpty else { return [] }

        let numFrames = melFrames.count / nMels
        let targetLen = nearestEnumeratedLength(numFrames)

        // Pad or truncate to target length
        var padded: [Float]
        if numFrames < targetLen {
            padded = melFrames + [Float](repeating: 0, count: (targetLen - numFrames) * nMels)
        } else if numFrames > targetLen {
            padded = Array(melFrames.prefix(targetLen * nMels))
        } else {
            padded = melFrames
        }

        // Convert to Float16 MLMultiArray [1, targetLen, 80]
        let shape: [NSNumber] = [1, NSNumber(value: targetLen), NSNumber(value: nMels)]
        let inputArray = try MLMultiArray(shape: shape, dataType: .float16)

        padded.withUnsafeBufferPointer { srcPtr in
            let dst = inputArray.dataPointer.bindMemory(to: Float16.self, capacity: padded.count)
            for i in 0..<padded.count {
                dst[i] = Float16(srcPtr[i])
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["mel": MLFeatureValue(multiArray: inputArray)])
        let prediction = try model.prediction(from: provider)

        guard let embeddingValue = prediction.featureValue(for: "embedding"),
              let embeddingArray = embeddingValue.multiArrayValue else {
            return []
        }

        // Read 256-dim embedding
        var embedding = [Float](repeating: 0, count: 256)
        let embPtr = embeddingArray.dataPointer.bindMemory(to: Float16.self, capacity: 256)
        for i in 0..<256 {
            embedding[i] = Float(embPtr[i])
        }

        return l2Normalize(embedding)
    }

    /// Batch-embed multiple audio segments.
    public func embedSegments(_ segments: [[Float]]) throws -> [[Float]] {
        try segments.map { try embed(audioSamples: $0) }
    }

    // MARK: - Mel Spectrogram

    private func computeLogMelSpectrogram(_ audio: [Float]) -> [Float] {
        guard audio.count > winLength else { return [] }

        let numFrames = max(1, (audio.count - winLength) / hopLength + 1)
        let melFilterbank = buildMelFilterbank()
        var allMelFrames = [Float]()
        allMelFrames.reserveCapacity(numFrames * nMels)

        let window = hanningWindow(winLength)

        for frame in 0..<numFrames {
            let start = frame * hopLength
            let end = min(start + winLength, audio.count)
            var windowed = [Float](repeating: 0, count: nFFT)
            let actualLen = end - start
            for i in 0..<actualLen {
                windowed[i] = audio[start + i] * window[i]
            }

            let powerSpectrum = computePowerSpectrum(windowed)
            var melEnergies = applyMelFilterbank(powerSpectrum, filterbank: melFilterbank)

            // Log scale with floor
            let logFloor: Float = 1e-10
            for i in 0..<nMels {
                melEnergies[i] = log(max(melEnergies[i], logFloor))
            }

            allMelFrames.append(contentsOf: melEnergies)
        }

        return allMelFrames
    }

    private func hanningWindow(_ length: Int) -> [Float] {
        (0..<length).map { i in
            0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(length)))
        }
    }

    private func computePowerSpectrum(_ frame: [Float]) -> [Float] {
        let log2n = vDSP_Length(log2(Double(nFFT)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var real = [Float](repeating: 0, count: nFFT / 2)
        var imag = [Float](repeating: 0, count: nFFT / 2)

        frame.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { complexPtr in
                var splitComplex = DSPSplitComplex(realp: &real, imagp: &imag)
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(nFFT / 2))
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        let specSize = nFFT / 2 + 1
        var power = [Float](repeating: 0, count: specSize)
        for i in 0..<(nFFT / 2) {
            power[i] = real[i] * real[i] + imag[i] * imag[i]
        }
        power[nFFT / 2] = imag[0] * imag[0]

        let scale: Float = 1.0 / Float(nFFT)
        vDSP_vsmul(power, 1, [scale], &power, 1, vDSP_Length(specSize))

        return power
    }

    private func applyMelFilterbank(_ powerSpectrum: [Float], filterbank: [[Float]]) -> [Float] {
        var melEnergies = [Float](repeating: 0, count: nMels)
        let specLen = min(powerSpectrum.count, filterbank[0].count)
        for m in 0..<nMels {
            var sum: Float = 0
            for k in 0..<specLen {
                sum += filterbank[m][k] * powerSpectrum[k]
            }
            melEnergies[m] = sum
        }
        return melEnergies
    }

    private func buildMelFilterbank() -> [[Float]] {
        let specSize = nFFT / 2 + 1
        let fMax = sampleRate / 2.0

        func hzToMel(_ hz: Double) -> Double { 2595.0 * log10(1.0 + hz / 700.0) }
        func melToHz(_ mel: Double) -> Double { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

        let melMin = hzToMel(0)
        let melMax = hzToMel(fMax)
        let melPoints = (0...(nMels + 1)).map { i in
            melMin + Double(i) * (melMax - melMin) / Double(nMels + 1)
        }
        let hzPoints = melPoints.map { melToHz($0) }
        let binPoints = hzPoints.map { Int(floor($0 * Double(nFFT) / sampleRate)) }

        var filterbank = [[Float]](repeating: [Float](repeating: 0, count: specSize), count: nMels)
        for m in 0..<nMels {
            let start = binPoints[m]
            let center = binPoints[m + 1]
            let end = binPoints[m + 2]
            for k in start..<center where k < specSize {
                filterbank[m][k] = Float(k - start) / Float(max(center - start, 1))
            }
            for k in center..<end where k < specSize {
                filterbank[m][k] = Float(end - k) / Float(max(end - center, 1))
            }
        }
        return filterbank
    }

    // MARK: - Helpers

    private func nearestEnumeratedLength(_ numFrames: Int) -> Int {
        var best = enumeratedLengths[0]
        var bestDist = abs(numFrames - best)
        for len in enumeratedLengths {
            let dist = abs(numFrames - len)
            if dist < bestDist {
                best = len
                bestDist = dist
            }
        }
        return best
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 1e-12 else { return v }
        var result = [Float](repeating: 0, count: v.count)
        var divisor = norm
        vDSP_vsdiv(v, 1, &divisor, &result, 1, vDSP_Length(v.count))
        return result
    }
}
