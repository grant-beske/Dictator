import Accelerate

// Turns a buffer of mono float samples into a small array of normalized
// frequency-band magnitudes (0...1) for a stationary "music visualizer" /
// graphic-EQ display. Each band maps to a fixed bar on screen; bars rise and
// fall in place rather than scrolling.
//
// Two normalization stages make it actually register visually:
//   1. Auto-gain: bands are scaled relative to a slowly-decaying recent peak,
//      so the spectrum shape always fills the height regardless of mic level.
//   2. Loudness gate: an overall RMS-derived 0...1 factor collapses the bars to
//      flat during silence (otherwise auto-gain would amplify noise).
final class SpectrumAnalyzer {
  private let n: Int                 // FFT length (power of two)
  private let log2n: vDSP_Length
  private let setup: FFTSetup
  private var window: [Float]
  let bandCount: Int

  // Auto-gain state: exponential decaying peak across recent frames.
  private var peak: Float = 1e-6

  init(n: Int = 2048, bandCount: Int = 28) {
    self.n = n
    self.bandCount = bandCount
    self.log2n = vDSP_Length(log2(Double(n)))
    self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    self.window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
  }

  deinit { vDSP_destroy_fftsetup(setup) }

  // `gain` is a user-tunable final multiplier (config.waveformGain).
  func analyze(_ samples: UnsafePointer<Float>, count: Int, gain: Float) -> [Float] {
    let m = min(count, n)
    guard m > 0 else { return [Float](repeating: 0, count: bandCount) }

    // Overall loudness → gate (silence collapses the display to flat).
    var rms: Float = 0
    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(m))
    let gate: Float = rms > 0 ? max(0, min(1, (20 * log10(rms) + 55) / 40)) : 0

    // Window the first m samples (rest stays zero-padded to n).
    var windowed = [Float](repeating: 0, count: n)
    vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(m))

    // Real FFT → magnitude spectrum (n/2 bins).
    let half = n / 2
    var realp = [Float](repeating: 0, count: half)
    var imagp = [Float](repeating: 0, count: half)
    var mags = [Float](repeating: 0, count: half)
    realp.withUnsafeMutableBufferPointer { rp in
      imagp.withUnsafeMutableBufferPointer { ip in
        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        // Reinterpret the interleaved real buffer as complex for the pack step.
        windowed.withUnsafeBufferPointer { wp in
          wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
          }
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
      }
    }

    // Group bins into log-spaced bands (so low/speech frequencies get detail).
    let minBin = 1
    let maxBin = half - 1
    var bands = [Float](repeating: 0, count: bandCount)
    var frameMax: Float = 0
    for b in 0..<bandCount {
      let lo = logBin(Double(b) / Double(bandCount), minBin: minBin, maxBin: maxBin)
      var hi = logBin(Double(b + 1) / Double(bandCount), minBin: minBin, maxBin: maxBin)
      if hi <= lo { hi = lo + 1 }
      var sum: Float = 0
      for bin in lo..<hi { sum += mags[bin] }
      let avg = sum / Float(hi - lo)
      let v = avg.squareRoot()       // perceptual compression
      bands[b] = v
      frameMax = max(frameMax, v)
    }

    // Auto-gain: track the recent peak with slow decay, normalize to it.
    peak = max(frameMax, peak * 0.92)
    if peak < 1e-6 { peak = 1e-6 }
    for b in 0..<bandCount {
      bands[b] = min(1, (bands[b] / peak) * gate * gain)
    }
    return bands
  }

  // Map a 0...1 fraction to a log-spaced FFT bin index.
  private func logBin(_ frac: Double, minBin: Int, maxBin: Int) -> Int {
    let v = Double(minBin) * pow(Double(maxBin) / Double(minBin), frac)
    return min(maxBin, max(minBin, Int(v)))
  }
}
