import AVFoundation
import Foundation

/// Phase 0 iOS audio capture using `AVAudioEngine`.
///
/// Compliance:
///   * Requires `NSMicrophoneUsageDescription` in Info.plist.
///   * Requires `UIBackgroundModes=audio` for continuous capture when screen-locked.
///   * Uses `.playAndRecord` category with `.measurement` mode to disable iOS's voice
///     processing chain (AGC / NS / AEC) — we want raw PCM for DSP.
///
/// Audio path: `AVAudioInputNode` tap -> Int16 interleaved buffer -> Rust C-ABI.
final class AudioCapture {

    static let shared = AudioCapture()
    private init() {}

    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    /// Target format: 48 kHz Int16 stereo, interleaved. Most input nodes give us Float32
    /// in their hardware format; we install the tap on the input node's preferred format
    /// and convert in the callback.
    private let targetSampleRate: Double = 48_000

    func start() throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setPreferredSampleRate(targetSampleRate)
        try session.setPreferredIOBufferDuration(0.020) // ~20 ms callbacks
        try session.setActive(true, options: [])

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)

        // Build a target Int16 interleaved stereo format. The converter handles channel-
        // count adjustments (mono mics get duplicated to stereo).
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 2,
            interleaved: true
        ) else {
            throw NSError(domain: "Prism", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "could not build target format"])
        }

        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = converter else { return }
            self.convertAndPush(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        prism_init_logger()
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isRunning = false
    }

    private func convertAndPush(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Convert any input format to interleaved Int16 stereo @ 48 kHz, then push via FFI.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outFrames
        ) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || outBuf.frameLength == 0 { return }
        guard let int16Channel = outBuf.int16ChannelData else { return }

        let frames = Int(outBuf.frameLength)
        let interleavedCount = frames * 2
        // Interleaved Int16 = single channel pointer with length frames * channels.
        int16Channel.pointee.withMemoryRebound(to: Int16.self, capacity: interleavedCount) { ptr in
            _ = prism_push_audio_interleaved(ptr, interleavedCount)
        }
    }
}
