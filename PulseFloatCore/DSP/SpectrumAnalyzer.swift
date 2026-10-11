import Accelerate
import Foundation

/// Blackman-windowed PCM spectrum analysis with dBFS output, for serial use on one thread.
/// Instances own reusable FFT storage and must not be used concurrently.
public final class SpectrumAnalyzer {
    private struct BandMapping {
        let lowerBin: Int
        let upperBin: Int
        let fraction: Float
        let interpolates: Bool
    }

    private let fftSize: Int
    private let binCount: Int
    private let log2Size: vDSP_Length
    private let fftSetup: FFTSetup?
    private let window: UnsafeMutablePointer<Float>
    private let timeDomain: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let binDb: UnsafeMutablePointer<Float>
    private let coherentScale: Float
    private var mappings: [BandMapping] = []
    private var bandCount = 0
    private var validSampleRate = false

    /// Preallocates all analysis buffers for mono Float PCM with nominal amplitude −1...1.
    /// `fftSize` must be a power of two at least 4; other values use 4096 samples.
    /// `sampleRate` is in Hz; nonpositive or nonfinite rates produce −160 dBFS until updated.
    /// Create and subsequently access the instance serially on one thread.
    public init(fftSize: Int = 4096, sampleRate: Double, layout: BandLayout) {
        let size = fftSize >= 4 && fftSize.nonzeroBitCount == 1 ? fftSize : 4096
        self.fftSize = size
        binCount = size / 2
        log2Size = vDSP_Length(size.trailingZeroBitCount)
        fftSetup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))
        coherentScale = 0.42 * Float(size)

        window = .allocate(capacity: size)
        timeDomain = .allocate(capacity: size)
        real = .allocate(capacity: size / 2)
        imaginary = .allocate(capacity: size / 2)
        binDb = .allocate(capacity: size / 2)
        window.initialize(repeating: 0, count: size)
        timeDomain.initialize(repeating: 0, count: size)
        real.initialize(repeating: 0, count: size / 2)
        imaginary.initialize(repeating: 0, count: size / 2)
        binDb.initialize(repeating: -160, count: size / 2)
        // Flag 0 is the periodic Blackman window, whose coherent gain is 0.42.
        vDSP_blkman_window(window, vDSP_Length(size), 0)
        update(sampleRate: sampleRate, layout: layout)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
        window.deinitialize(count: fftSize)
        timeDomain.deinitialize(count: fftSize)
        real.deinitialize(count: binCount)
        imaginary.deinitialize(count: binCount)
        binDb.deinitialize(count: binCount)
        window.deallocate()
        timeDomain.deallocate()
        real.deallocate()
        imaginary.deallocate()
        binDb.deallocate()
    }

    /// Width of one FFT bin in Hz for the current sampling rate (0 when the rate is invalid).
    public private(set) var binHz: Double = 0

    /// Lends the per-bin dBFS levels (DC...Nyquist−1, `fftSize / 2` values) computed by the most
    /// recent `analyze`; −160 before the first analysis. No allocation; call serially on the analysis thread.
    public func withBinLevels<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(start: binDb, count: binCount))
    }

    /// Rebuilds the Hz-to-bin mapping for `layout` and a sampling rate in Hz.
    /// This method may allocate; call serially between analyses, never concurrently with them.
    /// Nonpositive or nonfinite rates cause analysis to write −160 dBFS.
    public func update(sampleRate: Double, layout: BandLayout) {
        bandCount = layout.count
        mappings.removeAll(keepingCapacity: true)
        let binHz = sampleRate / Double(fftSize)
        validSampleRate = binHz.isFinite && binHz > 0
        self.binHz = validSampleRate ? binHz : 0
        guard validSampleRate else { return }

        mappings.reserveCapacity(layout.count)
        let lastBin = binCount - 1
        for index in 0..<layout.count {
            let lower = ceil(layout.lo[index] / binHz)
            let upper = min(floor(layout.hi[index] / binHz), Double(lastBin))
            if lower <= upper {
                mappings.append(BandMapping(
                    lowerBin: Int(lower), upperBin: Int(upper), fraction: 0,
                    interpolates: false
                ))
            } else {
                // Clamp before converting to Int, including frequencies far above Nyquist.
                let position = min(layout.center[index] / binHz, Double(lastBin))
                let lowerBin = Int(floor(position))
                mappings.append(BandMapping(
                    lowerBin: lowerBin, upperBin: min(lowerBin + 1, lastBin),
                    fraction: Float(position - Double(lowerBin)), interpolates: true
                ))
            }
        }
    }

    /// Writes up to `min(bandsDb.count, layout.count)` finite band levels in dBFS.
    /// A bin-centered full-scale sine measures 0 dBFS; silence/nonfinite levels use −160.
    /// Short input is zero-padded on the left; long input uses the newest `fftSize` samples.
    /// Trailing output elements are untouched. Uses no allocation; call serially on one thread.
    public func analyze(samples: UnsafeBufferPointer<Float>, into bandsDb: UnsafeMutableBufferPointer<Float>) {
        let outputCount = min(bandsDb.count, bandCount)
        guard outputCount > 0 else { return }
        guard validSampleRate, let fftSetup else {
            var index = 0
            while index < outputCount {
                bandsDb[index] = -160
                index += 1
            }
            return
        }

        let copyCount = min(samples.count, fftSize)
        let padding = fftSize - copyCount
        let start = samples.count - copyCount
        var index = 0
        while index < padding {
            timeDomain[index] = 0
            index += 1
        }
        index = 0
        while index < copyCount {
            timeDomain[padding + index] = samples[start + index]
            index += 1
        }
        vDSP_vmul(timeDomain, 1, window, 1, timeDomain, 1, vDSP_Length(fftSize))
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        // This nonescaping rebinding closure only borrows preallocated storage.
        timeDomain.withMemoryRebound(to: DSPComplex.self, capacity: binCount) { packed in
            vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(binCount))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
        // zrip packs the real Nyquist term in imagp[0]; it is not part of DC magnitude.
        imaginary[0] = 0
        vDSP_zvabs(&split, 1, binDb, 1, vDSP_Length(binCount))
        index = 0
        while index < binCount {
            // The real forward FFT is twice the mathematical DFT, canceling sine's 1/2.
            let level = 20 * log10f(binDb[index] / coherentScale)
            binDb[index] = level.isFinite ? level : -160
            index += 1
        }

        index = 0
        while index < outputCount {
            let mapping = mappings[index]
            var level: Float = -160
            if mapping.interpolates {
                let lower = binDb[mapping.lowerBin]
                level = lower + (binDb[mapping.upperBin] - lower) * mapping.fraction
            } else {
                var bin = mapping.lowerBin
                while bin <= mapping.upperBin {
                    level = max(level, binDb[bin])
                    bin += 1
                }
            }
            bandsDb[index] = level.isFinite ? level : -160
            index += 1
        }
    }
}
