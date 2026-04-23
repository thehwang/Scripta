import Accelerate
import Foundation

/// Post-processing speaker diarizer.
///
/// Pipeline (all 5 layers):
///   Layer 3 — Energy-based VAD splits raw audio into fine-grained speech segments.
///   Layer 5 — Spectral-distance change-point detection refines segment boundaries.
///   Layer 2 — 13 MFCCs + 13 Delta-MFCCs extracted per segment.
///   Layer 1 — YIN pitch + spectral centroid + rolloff appended to feature vector.
///   Layer 4 — Agglomerative hierarchical clustering (average linkage) groups segments.
///   Segments are mapped back to transcript entries by time overlap.
public enum SpeakerDiarizer {

    // MARK: - Configuration

    private static let fftSize = 2048
    private static let frameHop = 1024          // 50% overlap

    private static let melBandCount = 26
    private static let mfccCount = 13
    /// 13 MFCC + 13 Delta-MFCC + pitch(weighted) + centroid(weighted) + rolloff(weighted)
    private static var featureDim: Int { mfccCount * 2 + 3 }

    // VAD (Layer 3)
    private static let vadFrameSamples = 800     // 50 ms at 16 kHz
    private static let vadEnergyThreshold: Float = 0.004
    private static let vadMinSegmentSec: Double = 1.5
    private static let vadSilenceGapSec: Double = 0.4

    // Change detection (Layer 5)
    private static let cdWindowSec: Double = 0.5
    private static let cdHopSec: Double = 0.25
    private static let cdDistThreshold: Float = 0.40

    // Agglomerative clustering (Layer 4)
    private static let defaultMergeDistThreshold: Float = 0.12

    // YIN pitch (Layer 1)
    private static let yinThreshold: Float = 0.15
    private static let yinMinFreq: Double = 70
    private static let yinMaxFreq: Double = 500

    // Feature weighting before L2 norm
    private static let pitchWeight: Float = 50.0
    private static let centroidWeight: Float = 20.0
    private static let rolloffWeight: Float = 20.0

    private static let silenceRMS: Float = 0.003

    // MARK: - Public API

    public struct DiarizedEntry {
        public let originalIndex: Int
        public let speaker: String
    }

    public struct DiarizedSegment {
        public let startSample: Int
        public let endSample: Int
        public let cluster: Int
    }

    public static func diarize(
        entries: [TranscriptEntry],
        audioBuffer: [Float],
        sampleRate: Double,
        recordingStart: Date,
        mergeThreshold: Float? = nil
    ) -> [DiarizedEntry] {
        let mergeDistThreshold = mergeThreshold ?? defaultMergeDistThreshold
        mplog("diarizer: start — \(entries.count) entries, \(audioBuffer.count) samples (\(String(format:"%.1f", Double(audioBuffer.count)/sampleRate))s)")

        let melFB = buildMelFilterbank(sampleRate: sampleRate)
        let dctMat = buildDCTMatrix()

        // Layer 3: VAD
        var segments = detectSpeechSegments(audioBuffer: audioBuffer, sampleRate: sampleRate)
        mplog("diarizer: VAD → \(segments.count) speech segments")

        // Layer 5: change-point refinement
        segments = splitAtChangePoints(
            segments: segments, audioBuffer: audioBuffer,
            sampleRate: sampleRate, melFB: melFB, dctMat: dctMat)
        mplog("diarizer: after change-point split → \(segments.count) segments")

        guard !segments.isEmpty else {
            mplog("diarizer: no speech segments found")
            return entries.enumerated().map { DiarizedEntry(originalIndex: $0, speaker: $1.speaker) }
        }

        // Layers 1+2: extract MFCC + Delta + YIN features per segment
        var sfs: [SegmentResult] = []
        for (i, seg) in segments.enumerated() {
            let audio = Array(audioBuffer[seg.start..<seg.end])
            if let f = extractSegmentFeatures(audio, sampleRate: sampleRate, melFB: melFB, dctMat: dctMat) {
                sfs.append(SegmentResult(idx: i, start: seg.start, end: seg.end, feat: f))
            }
        }
        mplog("diarizer: features extracted for \(sfs.count)/\(segments.count) segments")

        guard sfs.count >= 2 else {
            mplog("diarizer: too few segments for clustering")
            return entries.enumerated().map { DiarizedEntry(originalIndex: $0, speaker: $1.speaker) }
        }

        // Log a sample of pairwise similarities for debugging
        let samplePairs = min(sfs.count, 6)
        for i in 0..<samplePairs {
            for j in (i+1)..<samplePairs {
                let sim = cosineSimilarity(sfs[i].feat, sfs[j].feat)
                mplog("diarizer: sim(seg\(sfs[i].idx),seg\(sfs[j].idx))=\(String(format:"%.4f", sim))")
            }
        }

        // Layer 4: agglomerative clustering (adaptive threshold)
        let effectiveThresh = adaptiveThreshold(features: sfs.map(\.feat), fallback: mergeDistThreshold)
        let labels = agglomerativeCluster(features: sfs.map(\.feat), threshold: effectiveThresh)
        let numClusters = (labels.max() ?? 0) + 1
        mplog("diarizer: clustering → \(numClusters) speaker(s) from \(sfs.count) segments, threshold=\(String(format:"%.4f",effectiveThresh))")

        // Map clusters → entries
        return mapClustersToEntries(
            entries: entries, sfs: sfs, labels: labels,
            sampleRate: sampleRate, recordingStart: recordingStart,
            numClusters: numClusters)
    }

    /// Returns raw segment-level diarization results (for testing/evaluation).
    public static func diarizeSegments(
        audioBuffer: [Float],
        sampleRate: Double,
        mergeThreshold: Float? = nil
    ) -> [DiarizedSegment] {
        let thresh = mergeThreshold ?? defaultMergeDistThreshold
        mplog("diarizeSegments: \(audioBuffer.count) samples, threshold=\(thresh)")

        let melFB = buildMelFilterbank(sampleRate: sampleRate)
        let dctMat = buildDCTMatrix()

        let rawSegments = detectSpeechSegments(audioBuffer: audioBuffer, sampleRate: sampleRate)
        mplog("diarizeSegments: VAD → \(rawSegments.count) speech segments")

        // Split very long segments (>10s) at change-points for better granularity,
        // but keep short segments as-is
        var segments: [Segment] = []
        let longThreshold = Int(10.0 * sampleRate)
        for seg in rawSegments {
            if seg.end - seg.start > longThreshold {
                let splits = splitAtChangePoints(
                    segments: [seg], audioBuffer: audioBuffer,
                    sampleRate: sampleRate, melFB: melFB, dctMat: dctMat)
                segments.append(contentsOf: splits)
            } else {
                segments.append(seg)
            }
        }

        // Filter very short segments (<1s) — too little audio for reliable features
        let minSamples = Int(1.0 * sampleRate)
        segments = segments.filter { $0.end - $0.start >= minSamples }
        mplog("diarizeSegments: after filtering → \(segments.count) segments (min 1.0s)")

        guard !segments.isEmpty else { return [] }

        var sfs: [SegmentResult] = []
        for (i, seg) in segments.enumerated() {
            let audio = Array(audioBuffer[seg.start..<seg.end])
            if let f = extractSegmentFeatures(audio, sampleRate: sampleRate, melFB: melFB, dctMat: dctMat) {
                sfs.append(SegmentResult(idx: i, start: seg.start, end: seg.end, feat: f))
            }
        }
        mplog("diarizeSegments: features for \(sfs.count)/\(segments.count) segments")

        guard sfs.count >= 2 else {
            return sfs.map { DiarizedSegment(startSample: $0.start, endSample: $0.end, cluster: 0) }
        }

        let feats = sfs.map(\.feat)
        let effectiveThresh: Float
        if mergeThreshold != nil {
            effectiveThresh = thresh
        } else {
            effectiveThresh = adaptiveThreshold(features: feats, fallback: thresh)
        }

        let labels = agglomerativeCluster(features: feats, threshold: effectiveThresh)
        let numClusters = (labels.max() ?? 0) + 1
        mplog("diarizeSegments: clustering → \(numClusters) speaker(s), threshold=\(String(format:"%.4f",effectiveThresh))")

        return zip(sfs, labels).map { DiarizedSegment(startSample: $0.0.start, endSample: $0.0.end, cluster: $0.1) }
    }

    // MARK: - Layer 3: Voice Activity Detection

    private struct Segment { let start: Int; let end: Int }

    private static func detectSpeechSegments(
        audioBuffer: [Float], sampleRate: Double
    ) -> [Segment] {
        let n = audioBuffer.count
        guard n > vadFrameSamples else { return [] }

        let minSegSamples = Int(vadMinSegmentSec * sampleRate)
        let silenceGapSamples = Int(vadSilenceGapSec * sampleRate)

        // Classify each 50 ms frame as speech / silence
        var speechFrames: [(start: Int, end: Int)] = []
        var pos = 0
        while pos + vadFrameSamples <= n {
            let slice = Array(audioBuffer[pos..<(pos + vadFrameSamples)])
            var rms: Float = 0
            vDSP_rmsqv(slice, 1, &rms, vDSP_Length(vadFrameSamples))
            if rms > vadEnergyThreshold {
                speechFrames.append((pos, pos + vadFrameSamples))
            }
            pos += vadFrameSamples
        }

        guard !speechFrames.isEmpty else { return [] }

        // Merge consecutive speech frames, split on silence gaps
        var merged: [Segment] = []
        var curStart = speechFrames[0].start
        var curEnd = speechFrames[0].end

        for i in 1..<speechFrames.count {
            if speechFrames[i].start - curEnd <= silenceGapSamples {
                curEnd = speechFrames[i].end
            } else {
                if curEnd - curStart >= minSegSamples {
                    merged.append(Segment(start: curStart, end: curEnd))
                }
                curStart = speechFrames[i].start
                curEnd = speechFrames[i].end
            }
        }
        if curEnd - curStart >= minSegSamples {
            merged.append(Segment(start: curStart, end: curEnd))
        }

        return merged
    }

    // MARK: - Layer 5: Speaker Change-Point Detection

    private static func splitAtChangePoints(
        segments: [Segment], audioBuffer: [Float],
        sampleRate: Double, melFB: [[Float]], dctMat: [[Float]]
    ) -> [Segment] {
        let winSamples = Int(cdWindowSec * sampleRate)
        let hopSamples = Int(cdHopSec * sampleRate)
        let minSplitSize = Int(1.0 * sampleRate)

        var refined: [Segment] = []

        for seg in segments {
            let length = seg.end - seg.start
            if length < minSplitSize * 2 {
                refined.append(seg)
                continue
            }

            // Extract short-window MFCC features within this segment
            var windowFeats: [(mid: Int, feat: [Float])] = []
            var p = seg.start
            while p + winSamples <= seg.end {
                let slice = Array(audioBuffer[p..<(p + winSamples)])
                if let f = extractStaticMFCC(slice, sampleRate: sampleRate, melFB: melFB, dctMat: dctMat) {
                    windowFeats.append((p + winSamples / 2, f))
                }
                p += hopSamples
            }

            guard windowFeats.count >= 3 else {
                refined.append(seg)
                continue
            }

            // Find change points
            var splitPoints: [Int] = []
            for i in 1..<windowFeats.count {
                let dist = 1.0 - cosineSimilarity(windowFeats[i - 1].feat, windowFeats[i].feat)
                if dist > cdDistThreshold {
                    let sp = (windowFeats[i - 1].mid + windowFeats[i].mid) / 2
                    if sp - seg.start >= minSplitSize && seg.end - sp >= minSplitSize {
                        splitPoints.append(sp)
                    }
                }
            }

            if splitPoints.isEmpty {
                refined.append(seg)
            } else {
                var prev = seg.start
                for sp in splitPoints {
                    refined.append(Segment(start: prev, end: sp))
                    prev = sp
                }
                refined.append(Segment(start: prev, end: seg.end))
            }
        }

        return refined
    }

    /// Quick static-MFCC (no delta) for change-point comparison.
    private static func extractStaticMFCC(
        _ samples: [Float], sampleRate: Double,
        melFB: [[Float]], dctMat: [[Float]]
    ) -> [Float]? {
        let n = samples.count
        guard n >= fftSize else { return nil }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
        guard rms > silenceRMS else { return nil }

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let halfN = fftSize / 2
        var accMFCC = [Float](repeating: 0, count: mfccCount)
        var frames = 0
        var pos = 0

        while pos + fftSize <= n {
            let mfcc = computeFrameMFCC(
                Array(samples[pos..<(pos + fftSize)]),
                window: window, fftSetup: fftSetup, log2n: log2n,
                halfN: halfN, melFB: melFB, dctMat: dctMat)
            for k in 0..<mfccCount { accMFCC[k] += mfcc[k] }
            frames += 1
            pos += frameHop
        }

        guard frames > 0 else { return nil }
        let inv = 1.0 / Float(frames)
        for k in 0..<mfccCount { accMFCC[k] *= inv }
        return l2Normalize(accMFCC)
    }

    // MARK: - Layers 1+2: Segment Feature Extraction (MFCC + Delta + YIN + Spectral)

    private static func extractSegmentFeatures(
        _ samples: [Float], sampleRate: Double,
        melFB: [[Float]], dctMat: [[Float]]
    ) -> [Float]? {
        let n = samples.count
        guard n >= fftSize else { return nil }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
        guard rms > silenceRMS else { return nil }

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let halfN = fftSize / 2
        var frameMFCCs: [[Float]] = []
        var accCentroid: Float = 0
        var accRolloff: Float = 0
        var frameCount = 0

        var pos = 0
        while pos + fftSize <= n {
            let frame = Array(samples[pos..<(pos + fftSize)])

            let mfcc = computeFrameMFCC(
                frame, window: window, fftSetup: fftSetup, log2n: log2n,
                halfN: halfN, melFB: melFB, dctMat: dctMat)
            frameMFCCs.append(mfcc)

            // Spectral shape features from the same FFT
            let mags = computeMagnitudeSpectrum(
                frame, window: window, fftSetup: fftSetup,
                log2n: log2n, halfN: halfN)

            var totalE: Float = 0
            vDSP_sve(mags, 1, &totalE, vDSP_Length(halfN))
            if totalE > 1e-10 {
                var wSum: Float = 0
                for k in 0..<halfN { wSum += Float(k) * mags[k] }
                accCentroid += wSum / totalE
            }
            let target = totalE * 0.85
            var cum: Float = 0
            var rollBin = halfN - 1
            for k in 0..<halfN {
                cum += mags[k]
                if cum >= target { rollBin = k; break }
            }
            accRolloff += Float(rollBin) / Float(halfN)
            frameCount += 1
            pos += frameHop
        }

        guard frameCount > 0 else { return nil }
        let invFC = 1.0 / Float(frameCount)

        // Average MFCC
        var avgMFCC = [Float](repeating: 0, count: mfccCount)
        for fr in frameMFCCs { for k in 0..<mfccCount { avgMFCC[k] += fr[k] } }
        for k in 0..<mfccCount { avgMFCC[k] *= invFC }

        // Delta-MFCC
        var avgDelta = [Float](repeating: 0, count: mfccCount)
        if frameMFCCs.count >= 2 {
            for t in 0..<frameMFCCs.count {
                let prev = max(0, t - 1)
                let next = min(frameMFCCs.count - 1, t + 1)
                let denom = Float(next - prev)
                if denom > 0 {
                    for k in 0..<mfccCount {
                        avgDelta[k] += (frameMFCCs[next][k] - frameMFCCs[prev][k]) / denom
                    }
                }
            }
            for k in 0..<mfccCount { avgDelta[k] *= invFC }
        }

        // YIN pitch (Layer 1)
        let pitch = yinEstimatePitch(samples, sampleRate: sampleRate) ?? 150.0
        let normPitch = (pitch - Float(yinMinFreq)) / Float(yinMaxFreq - yinMinFreq)

        let normCentroid = accCentroid * invFC / Float(halfN)
        let normRolloff = accRolloff * invFC

        // Build feature vector with balanced sub-vector normalization.
        // L2-normalize MFCC block and spectral block separately so neither
        // dominates after final concatenation.
        var mfccBlock = [Float](repeating: 0, count: mfccCount * 2)
        for k in 0..<mfccCount { mfccBlock[k] = avgMFCC[k] }
        for k in 0..<mfccCount { mfccBlock[mfccCount + k] = avgDelta[k] }
        mfccBlock = l2Normalize(mfccBlock)

        var spectralBlock: [Float] = [
            normPitch * pitchWeight,
            normCentroid * centroidWeight,
            normRolloff * rolloffWeight,
        ]
        spectralBlock = l2Normalize(spectralBlock)

        var feat = [Float](repeating: 0, count: featureDim)
        for k in 0..<(mfccCount * 2) { feat[k] = mfccBlock[k] }
        feat[mfccCount * 2]     = spectralBlock[0]
        feat[mfccCount * 2 + 1] = spectralBlock[1]
        feat[mfccCount * 2 + 2] = spectralBlock[2]

        return l2Normalize(feat)
    }

    // MARK: - Layer 1: YIN Pitch Estimation

    private static func yinEstimatePitch(_ samples: [Float], sampleRate: Double) -> Float? {
        let minLag = Int(sampleRate / yinMaxFreq)
        let maxLag = Int(sampleRate / yinMinFreq)
        let W = min(samples.count / 2, fftSize)
        guard W > maxLag, maxLag > minLag else { return nil }

        // Difference function: d(tau) = sum_{j=0}^{W-1} (x[j] - x[j+tau])^2
        var d = [Float](repeating: 0, count: maxLag + 1)
        for tau in 1...maxLag {
            var sum: Float = 0
            for j in 0..<W {
                let diff = samples[j] - samples[j + tau]
                sum += diff * diff
            }
            d[tau] = sum
        }

        // Cumulative mean normalized difference: d'(tau) = d(tau) * tau / cumSum(d,1..tau)
        var cmndf = [Float](repeating: 1, count: maxLag + 1)
        var runSum: Float = 0
        for tau in 1...maxLag {
            runSum += d[tau]
            cmndf[tau] = runSum > 0 ? d[tau] * Float(tau) / runSum : 1.0
        }

        // Absolute threshold: first dip below yinThreshold, then follow to local minimum
        for tau in minLag...maxLag {
            if cmndf[tau] < yinThreshold {
                var best = tau
                while best + 1 <= maxLag && cmndf[best + 1] < cmndf[best] { best += 1 }
                return Float(sampleRate) / Float(best)
            }
        }

        // Fallback: global minimum if reasonably low
        var bestTau = minLag
        var bestVal = cmndf[minLag]
        for tau in (minLag + 1)...maxLag {
            if cmndf[tau] < bestVal { bestVal = cmndf[tau]; bestTau = tau }
        }
        guard bestVal < 0.5 else { return nil }
        return Float(sampleRate) / Float(bestTau)
    }

    // MARK: - Layer 4: Agglomerative Hierarchical Clustering

    /// Finds the natural threshold by looking for the largest gap in the sorted
    /// pairwise distance distribution. This separates intra-speaker distances
    /// (small) from inter-speaker distances (large).
    private static func adaptiveThreshold(features: [[Float]], fallback: Float) -> Float {
        let n = features.count
        guard n >= 4 else { return fallback }

        var dists: [Float] = []
        dists.reserveCapacity(n * (n - 1) / 2)
        for i in 0..<n {
            for j in (i + 1)..<n {
                dists.append(1.0 - cosineSimilarity(features[i], features[j]))
            }
        }
        dists.sort()

        let count = dists.count
        let p5  = dists[count * 5 / 100]
        let p25 = dists[count * 25 / 100]
        let p50 = dists[count * 50 / 100]
        let p75 = dists[count * 75 / 100]
        let p95 = dists[count * 95 / 100]
        mplog("diarizer: distances n=\(count) min=\(String(format:"%.4f",dists[0])) p25=\(String(format:"%.4f",p25)) p50=\(String(format:"%.4f",p50)) p75=\(String(format:"%.4f",p75)) p95=\(String(format:"%.4f",p95)) max=\(String(format:"%.4f",dists[count-1]))")

        // If the distance range is very narrow, likely single speaker
        let range = dists[count - 1] - dists[0]
        if range < 0.10 {
            mplog("diarizer: narrow distance range (\(String(format:"%.4f",range))) → single speaker")
            return dists[count - 1] + 0.01
        }

        // Strategy: find the largest gap in a smoothed histogram of distances.
        // Bin the distances and look for the biggest empty region.
        let numBins = 50
        let binWidth = range / Float(numBins)
        var histogram = [Int](repeating: 0, count: numBins)
        for d in dists {
            let bin = min(numBins - 1, Int((d - dists[0]) / binWidth))
            histogram[bin] += 1
        }

        // Find the valley: longest run of low-density bins between two peaks
        let avgBin = count / numBins
        let lowThreshold = max(1, avgBin / 4)  // "low density" = less than 25% of average

        var bestGapStart = -1
        var bestGapLen = 0
        var gapStart = -1
        var gapLen = 0

        for b in 0..<numBins {
            if histogram[b] <= lowThreshold {
                if gapStart < 0 { gapStart = b }
                gapLen += 1
            } else {
                if gapLen > bestGapLen {
                    bestGapLen = gapLen
                    bestGapStart = gapStart
                }
                gapStart = -1
                gapLen = 0
            }
        }
        if gapLen > bestGapLen { bestGapLen = gapLen; bestGapStart = gapStart }

        if bestGapLen >= 2 && bestGapStart > 0 {
            // Threshold = start of the valley
            let adaptive = dists[0] + Float(bestGapStart) * binWidth
            mplog("diarizer: adaptive threshold=\(String(format:"%.4f",adaptive)) (valley at bin \(bestGapStart), width=\(bestGapLen) bins)")
            return adaptive
        }

        // Fallback: also try the largest single gap (ratio-based)
        let searchStart = count * 40 / 100
        let searchEnd = count * 98 / 100
        var maxGap: Float = 0
        var gapIdx = searchStart

        for i in searchStart..<searchEnd {
            let gap = dists[i + 1] - dists[i]
            if gap > maxGap {
                maxGap = gap
                gapIdx = i
            }
        }

        if maxGap > range * 0.05 {
            let adaptive = (dists[gapIdx] + dists[gapIdx + 1]) / 2.0
            mplog("diarizer: adaptive threshold=\(String(format:"%.4f",adaptive)) (gap=\(String(format:"%.4f",maxGap)) at p\(gapIdx * 100 / count))")
            return adaptive
        }

        mplog("diarizer: no clear separation found → fallback threshold \(String(format:"%.4f",fallback))")
        return fallback
    }

    private static func agglomerativeCluster(features: [[Float]], threshold: Float) -> [Int] {
        let n = features.count
        guard n >= 2 else { return Array(0..<n) }

        // Pairwise distance matrix (flat): dist[i*n+j] = 1 - cosine_sim
        var dist = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let d = 1.0 - cosineSimilarity(features[i], features[j])
                dist[i * n + j] = d
                dist[j * n + i] = d
            }
        }

        var clusterOf = Array(0..<n)
        var clusterSize = [Int](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)

        // Inter-cluster distance (average linkage), initially = pairwise
        var cDist = dist

        for _ in 0..<(n - 1) {
            var bestI = -1, bestJ = -1
            var bestD: Float = .infinity

            for i in 0..<n where active[i] {
                for j in (i + 1)..<n where active[j] {
                    if cDist[i * n + j] < bestD {
                        bestD = cDist[i * n + j]
                        bestI = i; bestJ = j
                    }
                }
            }

            guard bestD < threshold else { break }

            // Merge bestJ → bestI (average linkage update)
            let sI = clusterSize[bestI], sJ = clusterSize[bestJ]
            let total = sI + sJ
            for k in 0..<n where active[k] && k != bestI && k != bestJ {
                let nd = (Float(sI) * cDist[bestI * n + k]
                        + Float(sJ) * cDist[bestJ * n + k]) / Float(total)
                cDist[bestI * n + k] = nd
                cDist[k * n + bestI] = nd
            }
            clusterSize[bestI] = total
            active[bestJ] = false
            for m in 0..<n where clusterOf[m] == bestJ { clusterOf[m] = bestI }
        }

        // Compact labels to 0, 1, 2, …
        let unique = Array(Set(clusterOf)).sorted()
        var remap = [Int: Int]()
        for (newID, oldID) in unique.enumerated() { remap[oldID] = newID }
        return clusterOf.map { remap[$0]! }
    }

    // MARK: - Map clusters → transcript entries

    private struct SegmentResult {
        let idx: Int; let start: Int; let end: Int; let feat: [Float]
    }

    private static func mapClustersToEntries(
        entries: [TranscriptEntry],
        sfs: [SegmentResult],
        labels: [Int],
        sampleRate: Double,
        recordingStart: Date,
        numClusters: Int
    ) -> [DiarizedEntry] {
        let onlyOne = numClusters <= 1
        return entries.enumerated().map { i, entry in
            if entry.speaker == "You" {
                return DiarizedEntry(originalIndex: i, speaker: "You")
            }
            if onlyOne {
                return DiarizedEntry(originalIndex: i, speaker: "Remote")
            }

            let entryOff = entry.timestamp.timeIntervalSince(recordingStart)
            let entryStart = max(0, Int(entryOff * sampleRate))
            let entryEnd: Int
            if i + 1 < entries.count {
                entryEnd = max(0, Int(entries[i + 1].timestamp.timeIntervalSince(recordingStart) * sampleRate))
            } else {
                entryEnd = entryStart + Int(10.0 * sampleRate)
            }

            var votes = [Int](repeating: 0, count: numClusters)
            for (sfIdx, sf) in sfs.enumerated() {
                let oStart = max(entryStart, sf.start)
                let oEnd = min(entryEnd, sf.end)
                let overlap = max(0, oEnd - oStart)
                if overlap > 0 { votes[labels[sfIdx]] += overlap }
            }

            let best = votes.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
            if votes[best] == 0 {
                return DiarizedEntry(originalIndex: i, speaker: "Remote")
            }
            return DiarizedEntry(originalIndex: i, speaker: "Speaker \(best + 1)")
        }
    }

    // MARK: - FFT helpers

    private static func computeFrameMFCC(
        _ frame: [Float], window: [Float],
        fftSetup: FFTSetup, log2n: vDSP_Length,
        halfN: Int, melFB: [[Float]], dctMat: [[Float]]
    ) -> [Float] {
        let mags = computeMagnitudeSpectrum(
            frame, window: window, fftSetup: fftSetup,
            log2n: log2n, halfN: halfN)

        // Mel filterbank → log
        var logMel = [Float](repeating: 0, count: melBandCount)
        for b in 0..<melBandCount {
            var energy: Float = 0
            vDSP_dotpr(mags, 1, melFB[b], 1, &energy, vDSP_Length(halfN))
            logMel[b] = log(max(energy, 1e-10))
        }

        // DCT-II → MFCC
        var mfcc = [Float](repeating: 0, count: mfccCount)
        for k in 0..<mfccCount {
            var val: Float = 0
            vDSP_dotpr(dctMat[k], 1, logMel, 1, &val, vDSP_Length(melBandCount))
            mfcc[k] = val
        }
        return mfcc
    }

    private static func computeMagnitudeSpectrum(
        _ frame: [Float], window: [Float],
        fftSetup: FFTSetup, log2n: vDSP_Length, halfN: Int
    ) -> [Float] {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var realPart = stride(from: 0, to: fftSize, by: 2).map { windowed[$0] }
        var imagPart = stride(from: 1, to: fftSize, by: 2).map { windowed[$0] }
        var magnitudes = [Float](repeating: 0, count: halfN)

        realPart.withUnsafeMutableBufferPointer { rBuf in
            imagPart.withUnsafeMutableBufferPointer { iBuf in
                var sc = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&sc, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }
        return magnitudes
    }

    // MARK: - Mel Filterbank

    private static func buildMelFilterbank(sampleRate: Double) -> [[Float]] {
        let halfN = fftSize / 2
        func hzToMel(_ hz: Double) -> Double { 2595.0 * log10(1.0 + hz / 700.0) }
        func melToHz(_ mel: Double) -> Double { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

        let melLow = hzToMel(80)
        let melHigh = hzToMel(sampleRate / 2.0)
        let pts = (0...(melBandCount + 1)).map { i in
            melLow + Double(i) * (melHigh - melLow) / Double(melBandCount + 1)
        }
        let hzPts = pts.map { melToHz($0) }
        let bins = hzPts.map { Int(round($0 * Double(fftSize) / sampleRate)) }

        var fb = [[Float]](repeating: [Float](repeating: 0, count: halfN), count: melBandCount)
        for b in 0..<melBandCount {
            let left = bins[b], center = bins[b + 1], right = bins[b + 2]
            for k in left..<center where k < halfN {
                fb[b][k] = Float(k - left) / Float(max(1, center - left))
            }
            for k in center..<right where k < halfN {
                fb[b][k] = Float(right - k) / Float(max(1, right - center))
            }
        }
        return fb
    }

    // MARK: - DCT-II Matrix (Layer 2)

    /// Pre-compute the mfccCount × melBandCount DCT-II matrix.
    /// c[k] = sum_{n=0}^{N-1} x[n] * cos(pi * k * (2n+1) / (2N))
    private static func buildDCTMatrix() -> [[Float]] {
        let N = melBandCount
        return (0..<mfccCount).map { k in
            (0..<N).map { n in
                cos(Float.pi * Float(k) * (2.0 * Float(n) + 1.0) / (2.0 * Float(N)))
            }
        }
    }

    // MARK: - Vector Math

    private static func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 1e-8 else { return v }
        var result = v
        var invNorm = 1.0 / norm
        vDSP_vsmul(v, 1, &invNorm, &result, 1, vDSP_Length(v.count))
        return result
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, nA: Float = 0, nB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &nA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nB, vDSP_Length(b.count))
        let d = sqrt(nA * nB)
        return d > 1e-8 ? dot / d : 0
    }
}
