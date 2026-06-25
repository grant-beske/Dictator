import AVFoundation

// Captures microphone audio with AVAudioEngine and writes it to a WAV file in
// exactly the format whisper.cpp expects: 16 kHz, 16-bit signed, mono, PCM.
//
// The input node delivers float32 at the hardware sample rate (often 44.1/48
// kHz, sometimes stereo), so we run every captured buffer through an
// AVAudioConverter that resamples + downmixes + requantizes to the target
// format before writing.
final class AudioRecorder {
  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var outputFile: AVAudioFile?
  private var outputFormat: AVAudioFormat!
  private var inputFormat: AVAudioFormat!
  private(set) var isRecording = false

  // Called on the main thread with normalized 0...1 per-band magnitudes, for the
  // spectrum-analyzer UI. Array length == analyzer.bandCount.
  var onSpectrum: (([Float]) -> Void)?

  // User-tunable visual gain for the waveform (config.waveformGain).
  var waveformGain: Float = 1.4

  private let analyzer = SpectrumAnalyzer()

  enum RecorderError: Error { case formatUnavailable, converterUnavailable }

  // Begin recording into `url` (which must end in .wav).
  func start(to url: URL) throws {
    guard !isRecording else { return }

    let input = engine.inputNode
    inputFormat = input.inputFormat(forBus: 0)
    // A zero sample rate means the input device isn't ready (no mic permission,
    // or no input device). Bail rather than crash inside CoreAudio.
    guard inputFormat.sampleRate > 0 else { throw RecorderError.formatUnavailable }

    // Target: 16 kHz, mono, 16-bit signed integer, interleaved PCM.
    guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 16_000,
                                     channels: 1,
                                     interleaved: true) else {
      throw RecorderError.formatUnavailable
    }
    outputFormat = outFmt

    guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      throw RecorderError.converterUnavailable
    }
    converter = conv

    // AVAudioFile infers WAV from the .wav extension. We pass the *file's*
    // settings (16-bit PCM) and tell it we'll hand it int16 interleaved buffers.
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false
    ]
    outputFile = try AVAudioFile(forWriting: url,
                                 settings: settings,
                                 commonFormat: .pcmFormatInt16,
                                 interleaved: true)

    // The tap block runs on a real-time audio thread; it's called serially, so
    // converting + writing inline here is safe (no extra locking needed).
    // 2048-frame buffers give ~20+ spectrum updates/sec for a lively meter.
    input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
      self?.append(buffer)
    }

    engine.prepare()
    try engine.start()
    isRecording = true
  }

  // Convert one input buffer to the target format and append it to the file.
  private func append(_ inBuffer: AVAudioPCMBuffer) {
    guard let converter = converter,
          let outputFile = outputFile else { return }

    // Compute a frequency spectrum for the UI meter from the raw float buffer.
    publishSpectrum(from: inBuffer)

    // Output capacity scales by the sample-rate ratio; add slack for the
    // resampler's internal latency so we never truncate a buffer.
    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                           frameCapacity: capacity) else { return }

    // The converter pulls input via this block. We feed the current buffer
    // exactly once, then report .noDataNow so it flushes what it has.
    var fed = false
    var error: NSError?
    let status = converter.convert(to: outBuffer, error: &error) { _, inStatus in
      if fed {
        inStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      inStatus.pointee = .haveData
      return inBuffer
    }

    if status == .error {
      NSLog("Dictator: audio convert error \(String(describing: error))")
      return
    }
    guard outBuffer.frameLength > 0 else { return }
    do {
      try outputFile.write(from: outBuffer)
    } catch {
      NSLog("Dictator: audio write error \(error)")
    }
  }

  // Run the FFT analyzer on the audio thread, deliver bands on the main thread.
  private func publishSpectrum(from buffer: AVAudioPCMBuffer) {
    guard let onSpectrum = onSpectrum,
          let channel = buffer.floatChannelData else { return }
    let n = Int(buffer.frameLength)
    guard n > 0 else { return }
    let bands = analyzer.analyze(channel[0], count: n, gain: waveformGain)
    DispatchQueue.main.async { onSpectrum(bands) }
  }

  func stop() {
    guard isRecording else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    isRecording = false
    // Releasing the file handle flushes/closes the WAV so it's readable.
    outputFile = nil
    converter = nil
  }
}
