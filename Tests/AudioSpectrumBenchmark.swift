import AVFoundation
import Foundation

@main
struct SpectrumBenchmark {
    static func main() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
        buffer.frameLength = 1_024
        for channel in 0..<2 {
            for frame in 0..<1_024 {
                buffer.floatChannelData![channel][frame] = 0.4 * sin(Float(frame) * 2 * .pi * 440 / 96_000)
            }
        }
        let analyzer = AudioSpectrumAnalyzer(bandCount: 36)
        var updates = 0
        analyzer.onLevels = { _ in updates += 1 }
        let start = Date()
        for _ in 0..<10_000 { analyzer.analyze(buffer) }
        print(String(format: "10,000 buffers at 96 kHz: %.4f seconds; %d spectrum updates", Date().timeIntervalSince(start), updates))
    }
}
