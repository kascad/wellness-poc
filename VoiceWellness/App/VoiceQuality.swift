import Foundation

struct VoiceQuality: Codable, Sendable {
    let cpps: Double
    let inputID: String
    let inputName: String
    let sampleRate: Int

    var profile: String { "\(inputID)|\(sampleRate)" }
}

enum VoiceQualityError: LocalizedError {
    case tooShort, tooQuiet, clipped, noisy, inputChanged

    var errorDescription: String? {
        switch self {
        case .tooShort: "Потяните «А-а-а» непрерывно 3–4 секунды."
        case .tooQuiet: "Голос слишком тихий. Поднесите микрофон немного ближе и повторите."
        case .clipped: "Звук перегружен. Отодвиньте микрофон и повторите."
        case .noisy: "Голос плохо выделяется на фоне. Начните с короткой тишины и повторите в тихом месте."
        case .inputChanged: "Аудиовход изменился во время записи. Повторите замер с одним микрофоном."
        }
    }
}

enum VoiceQualityAnalyzer {
    static func cpps(_ samples: [Float], sampleRate: Int) throws -> Double {
        let block = sampleRate / 50
        guard block > 0, samples.count >= sampleRate * 2 else { throw VoiceQualityError.tooShort }
        let levels = stride(from: 0, through: samples.count - block, by: block).map { start in
            let energy = samples[start..<(start + block)].reduce(0.0) { $0 + Double($1 * $1) }
            return 10 * log10(max(energy / Double(block), 1e-12))
        }
        let sorted = levels.sorted()
        let voice = sorted[Int(Double(sorted.count - 1) * 0.8)]
        guard voice > -48 else { throw VoiceQualityError.tooQuiet }
        let noise = levels.prefix(15).sorted()[7]
        guard voice - noise >= 15 else { throw VoiceQualityError.noisy }

        let threshold = max(noise + 12, voice - 14)
        var start = 0
        var longest = 0..<0
        for index in 0...levels.count {
            if index == levels.count || levels[index] < threshold {
                if index - start > longest.count { longest = start..<index }
                start = index + 1
            }
        }
        guard longest.count >= 90 else { throw VoiceQualityError.tooShort }
        let voiceSamples = samples[(longest.lowerBound * block)..<(longest.upperBound * block)]
        let clipped = voiceSamples.filter { abs($0) >= 0.985 }.count
        guard Double(clipped) / Double(voiceSamples.count) < 0.005 else { throw VoiceQualityError.clipped }

        // Trim attacks and offsets, average adjacent input samples before decimation.
        let trim = sampleRate / 5
        let strideSize = max(1, sampleRate / 12_000)
        let rate = Double(sampleRate) / Double(strideSize)
        let signal = stride(from: voiceSamples.startIndex + trim,
                            through: voiceSamples.endIndex - trim - strideSize, by: strideSize).map { index in
            voiceSamples[index..<(index + strideSize)].reduce(0.0) { $0 + Double($1) } / Double(strideSize)
        }
        let frame = Int(rate * 0.04)
        let hop = Int(rate * 0.01)
        var fftSize = 1
        while fftSize < frame * 2 { fftSize *= 2 }
        let window = (0..<frame).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(frame - 1)) }
        let high = Int(rate * 0.020)
        let low = max(2, Int(rate * 0.001))
        let peakStart = max(low, Int(ceil(rate / 450)))
        let peakEnd = Int(rate / 70)

        let cepstra = stride(from: 0, through: signal.count - frame, by: hop).map { offset in
            var real = Array(repeating: 0.0, count: fftSize)
            var imaginary = real
            let mean = signal[offset..<(offset + frame)].reduce(0, +) / Double(frame)
            for i in 0..<frame { real[i] = (signal[offset + i] - mean) * window[i] }
            fft(&real, &imaginary)
            for i in real.indices {
                real[i] = log(max(1e-12, real[i] * real[i] + imaginary[i] * imaginary[i]))
                imaginary[i] = 0
            }
            // For real symmetric log power, the forward transform gives the
            // same real coefficients as the inverse up to scale.
            fft(&real, &imaginary)
            return (0...(high + 1)).map { index in
                let quefrency = max(1, index)
                return 20 * log10(max(1e-12, abs(real[quefrency]) / Double(fftSize)))
            }
        }
        var sum = 0.0
        let meanX = Double(low + high) / 2
        let variance = (low...high).reduce(0.0) { $0 + pow(Double($1) - meanX, 2) }
        for index in cepstra.indices {
            let neighbors = max(0, index - 2)...min(cepstra.count - 1, index + 2)
            var smoothed: [Double] = []
            for q in low...high {
                var total = 0.0
                for frame in neighbors {
                    let coefficients = cepstra[frame]
                    total += coefficients[q - 1]
                    total += coefficients[q]
                    total += coefficients[q + 1]
                }
                smoothed.append(total / Double(3 * neighbors.count))
            }
            let meanY = smoothed.reduce(0, +) / Double(smoothed.count)
            var covariance = 0.0
            for q in low...high {
                covariance += (Double(q) - meanX) * (smoothed[q - low] - meanY)
            }
            let slope = covariance / variance
            let peak = (peakStart...peakEnd).max { smoothed[$0 - low] < smoothed[$1 - low] } ?? peakStart
            let baseline = meanY + slope * (Double(peak) - meanX)
            sum += smoothed[peak - low] - baseline
        }
        return sum / Double(cepstra.count)
    }

    private static func fft(_ real: inout [Double], _ imaginary: inout [Double]) {
        let n = real.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
        }
        var size = 2
        while size <= n {
            let angle = -2 * Double.pi / Double(size)
            let stepR = cos(angle)
            let stepI = sin(angle)
            for start in stride(from: 0, to: n, by: size) {
                var wr = 1.0
                var wi = 0.0
                for a in start..<(start + size / 2) {
                    let b = a + size / 2
                    let tr = wr * real[b] - wi * imaginary[b]
                    let ti = wr * imaginary[b] + wi * real[b]
                    real[b] = real[a] - tr
                    imaginary[b] = imaginary[a] - ti
                    real[a] += tr
                    imaginary[a] += ti
                    (wr, wi) = (wr * stepR - wi * stepI, wr * stepI + wi * stepR)
                }
            }
            size *= 2
        }
    }
}
