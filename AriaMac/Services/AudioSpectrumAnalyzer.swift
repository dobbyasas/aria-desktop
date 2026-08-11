import AVFoundation
import Foundation
import MediaToolbox

final class AudioSpectrumAnalyzer {
    var onLevels: (([Float]) -> Void)?

    private let bandCount: Int
    private var format = AudioStreamBasicDescription()
    private var windowedSamples: [Float] = []
    private var smoothedLevels: [Float]

    init(bandCount: Int = 32) {
        self.bandCount = bandCount
        smoothedLevels = Array(repeating: 0.04, count: bandCount)
    }

    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        let retainedSelf = Unmanaged.passRetained(self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedSelf.toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<AudioSpectrumAnalyzer>.fromOpaque(storage).release()
            },
            prepare: { tap, maxFrames, processingFormat in
                let analyzer = AudioSpectrumAnalyzer.fromStorage(of: tap)
                analyzer.prepare(maxFrames: Int(maxFrames), format: processingFormat.pointee)
            },
            unprepare: { tap in
                AudioSpectrumAnalyzer.fromStorage(of: tap).unprepare()
            },
            process: { tap, requestedFrames, _, bufferList, framesOut, flagsOut in
                var sourceFlags: MTAudioProcessingTapFlags = 0
                var sourceFrames: CMItemCount = 0
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    requestedFrames,
                    bufferList,
                    &sourceFlags,
                    nil,
                    &sourceFrames
                )

                framesOut.pointee = sourceFrames
                flagsOut.pointee = sourceFlags

                guard status == noErr, sourceFrames > 0 else { return }
                AudioSpectrumAnalyzer.fromStorage(of: tap).analyze(
                    bufferList: bufferList,
                    frameCount: Int(sourceFrames)
                )
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )

        guard status == noErr, let tap else {
            retainedSelf.release()
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parameters]
        return audioMix
    }

    private static func fromStorage(of tap: MTAudioProcessingTap) -> AudioSpectrumAnalyzer {
        Unmanaged<AudioSpectrumAnalyzer>
            .fromOpaque(MTAudioProcessingTapGetStorage(tap))
            .takeUnretainedValue()
    }

    private func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        self.format = format
        windowedSamples = Array(repeating: 0, count: max(maxFrames, 2))
        smoothedLevels = Array(repeating: 0.04, count: bandCount)
    }

    private func unprepare() {
        windowedSamples.removeAll(keepingCapacity: false)
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
            let phase = Double(sampleIndex) / Double(sampleCount - 1)
            let hannWindow = Float(0.5 - 0.5 * cos(2 * .pi * phase))
            windowedSamples[sampleIndex] = sample * hannWindow
        }

        let sampleRate = format.mSampleRate
        guard sampleRate > 0 else { return }

        let minimumFrequency = 45.0
        let maximumFrequency = min(18_000.0, sampleRate * 0.45)
        let frequencyRatio = maximumFrequency / minimumFrequency
        let signalRMS = sqrt(sampleEnergy / Double(sampleCount))
        let signalDecibels = 20 * log10(max(signalRMS, 0.000_000_1))
        let signalPresence = min(max((Float(signalDecibels) + 66) / 36, 0), 1)
        var bandDecibels = Array(repeating: Float(-120), count: bandCount)

        for band in 0..<bandCount {
            let lowerProgress = Double(band) / Double(bandCount)
            let upperProgress = Double(band + 1) / Double(bandCount)
            let lowerFrequency = minimumFrequency * pow(frequencyRatio, lowerProgress)
            let upperFrequency = minimumFrequency * pow(frequencyRatio, upperProgress)
            let centerFrequency = sqrt(lowerFrequency * upperFrequency)

            let magnitude = goertzelMagnitude(
                frequency: centerFrequency,
                sampleRate: sampleRate,
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

    private func goertzelMagnitude(frequency: Double, sampleRate: Double, sampleCount: Int) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
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
