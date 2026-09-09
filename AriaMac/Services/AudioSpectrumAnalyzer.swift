import AVFoundation
import Foundation

final class AudioSpectrumAnalyzer {
    var onLevels: (([Float]) -> Void)?

    private let bandCount: Int
    private var format = AudioStreamBasicDescription()
    private var windowedSamples: [Float] = []
    private var smoothedLevels: [Float]
    private var hannWindow: [Float] = []
    private var coefficients: [Double] = []
    private var bandDecibels: [Float]
    private var secondsSinceAnalysis: Double = .infinity
    private let analysisInterval = 1.0 / 20

    init(bandCount: Int = 32) {
        self.bandCount = bandCount
        smoothedLevels = Array(repeating: 0.04, count: bandCount)
        bandDecibels = Array(repeating: -120, count: bandCount)
    }

    /// The engine tap continues across track boundaries, just like the output audio.
    func analyze(_ buffer: AVAudioPCMBuffer) {
        let description = buffer.format.streamDescription.pointee
        guard description.mSampleRate > 0 else { return }
        secondsSinceAnalysis += Double(buffer.frameLength) / description.mSampleRate
        guard secondsSinceAnalysis >= analysisInterval else { return }
        secondsSinceAnalysis = 0
        if format.mSampleRate != description.mSampleRate || format.mChannelsPerFrame != description.mChannelsPerFrame
            || windowedSamples.count != min(Int(buffer.frameLength), 1_024) {
            prepare(maxFrames: Int(buffer.frameLength), format: description)
        }
        analyze(bufferList: buffer.mutableAudioBufferList, frameCount: Int(buffer.frameLength))
    }

    private func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        self.format = format
        let sampleCount = min(max(maxFrames, 2), 1_024)
        windowedSamples = Array(repeating: 0, count: sampleCount)
        smoothedLevels = Array(repeating: 0.04, count: bandCount)
        hannWindow = (0..<sampleCount).map { index in
            Float(0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(sampleCount - 1)))
        }
        let minimumFrequency = 45.0
        let frequencyRatio = min(18_000.0, format.mSampleRate * 0.45) / minimumFrequency
        coefficients = (0..<bandCount).map { band in
            let centerFrequency = minimumFrequency * pow(frequencyRatio, (Double(band) + 0.5) / Double(bandCount))
            return 2 * cos(2 * .pi * centerFrequency / format.mSampleRate)
        }
    }

    private func analyze(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard format.mFormatID == kAudioFormatLinearPCM else { return }

        let sampleCount = min(frameCount, windowedSamples.count, 1_024)
        guard sampleCount >= 64 else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let channelCount = max(Int(format.mChannelsPerFrame), 1)
        let isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let startFrame = max(frameCount - sampleCount, 0)

        var sampleEnergy = 0.0

        for sampleIndex in 0..<sampleCount {
            let frameIndex = startFrame + sampleIndex
            let sample: Float

            if isFloat, format.mBitsPerChannel == 32 {
                sample = floatSample(
                    at: frameIndex,
                    buffers: buffers,
                    channelCount: channelCount,
                    isInterleaved: isInterleaved
                )
            } else if isSignedInteger, format.mBitsPerChannel == 16 {
                sample = integer16Sample(
                    at: frameIndex,
                    buffers: buffers,
                    channelCount: channelCount,
                    isInterleaved: isInterleaved
                )
            } else {
                return
            }

            sampleEnergy += Double(sample * sample)
            windowedSamples[sampleIndex] = sample * hannWindow[sampleIndex]
        }

        let sampleRate = format.mSampleRate
        guard sampleRate > 0 else { return }

        let signalRMS = sqrt(sampleEnergy / Double(sampleCount))
        let signalDecibels = 20 * log10(max(signalRMS, 0.000_000_1))
        let signalPresence = min(max((Float(signalDecibels) + 66) / 36, 0), 1)

        for band in 0..<bandCount {
            let lowerProgress = Double(band) / Double(bandCount)
            let magnitude = goertzelMagnitude(
                coefficient: coefficients[band],
                sampleCount: sampleCount
            )
            let decibels = 20 * log10(max(magnitude, 0.000_000_1))
            let highFrequencyCompensation = Float(lowerProgress) * 7.5
            bandDecibels[band] = Float(decibels) + highFrequencyCompensation
        }

        let framePeak = bandDecibels.max() ?? -120

        for band in 0..<bandCount {
            let relativeLevel = min(max((bandDecibels[band] - framePeak + 34) / 34, 0), 1)
            let target = min(pow(relativeLevel, 0.64) * pow(signalPresence, 0.38) * 1.08, 1)
            let smoothing: Float = target > smoothedLevels[band] ? 0.84 : 0.30

            smoothedLevels[band] += (target - smoothedLevels[band]) * smoothing
            smoothedLevels[band] = max(smoothedLevels[band], 0.025)
        }

        onLevels?(smoothedLevels)
    }

    private func floatSample(
        at frame: Int,
        buffers: UnsafeMutableAudioBufferListPointer,
        channelCount: Int,
        isInterleaved: Bool
    ) -> Float {
        if isInterleaved {
            guard let data = buffers.first?.mData else { return 0 }
            let samples = data.assumingMemoryBound(to: Float.self)
            let channelsToRead = min(channelCount, Int(buffers[0].mNumberChannels))
            guard channelsToRead > 0 else { return 0 }

            var sum: Float = 0
            for channel in 0..<channelsToRead {
                sum += samples[frame * channelCount + channel]
            }
            return sum / Float(channelsToRead)
        }

        let channelsToRead = min(channelCount, buffers.count)
        guard channelsToRead > 0 else { return 0 }

        var sum: Float = 0
        for channel in 0..<channelsToRead {
            guard let data = buffers[channel].mData else { continue }
            sum += data.assumingMemoryBound(to: Float.self)[frame]
        }
        return sum / Float(channelsToRead)
    }

    private func integer16Sample(
        at frame: Int,
        buffers: UnsafeMutableAudioBufferListPointer,
        channelCount: Int,
        isInterleaved: Bool
    ) -> Float {
        if isInterleaved {
            guard let data = buffers.first?.mData else { return 0 }
            let samples = data.assumingMemoryBound(to: Int16.self)
            let channelsToRead = min(channelCount, Int(buffers[0].mNumberChannels))
            guard channelsToRead > 0 else { return 0 }

            var sum: Float = 0
            for channel in 0..<channelsToRead {
                sum += Float(samples[frame * channelCount + channel]) / Float(Int16.max)
            }
            return sum / Float(channelsToRead)
        }

        let channelsToRead = min(channelCount, buffers.count)
        guard channelsToRead > 0 else { return 0 }

        var sum: Float = 0
        for channel in 0..<channelsToRead {
            guard let data = buffers[channel].mData else { continue }
            sum += Float(data.assumingMemoryBound(to: Int16.self)[frame]) / Float(Int16.max)
        }
        return sum / Float(channelsToRead)
    }

    private func goertzelMagnitude(coefficient: Double, sampleCount: Int) -> Double {
        var previous = 0.0
        var previousPrevious = 0.0

        for index in 0..<sampleCount {
            let current = Double(windowedSamples[index]) + coefficient * previous - previousPrevious
            previousPrevious = previous
            previous = current
        }

        let power = previousPrevious * previousPrevious
            + previous * previous
            - coefficient * previous * previousPrevious
        return sqrt(max(power, 0)) / Double(sampleCount)
    }
}
