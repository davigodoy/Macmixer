import Foundation
import AVFAudio
import AudioToolbox

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct StereoPCMTests {
    static func main() {
        testInterleavedGainAndMute()
        testPlanarToInterleaved()
        testInterleavedToPlanar()
        testAggregateSampleRateValidation()
        testNativeRateConversion()
        testHelperProcessGrouping()
        testSafariProcessOwnership()
        testAudioSourceOrdering()
        print("Mixer tests passed (gain, mute, rate conversion, planar conversion, process ownership, source ordering)")
    }

    private static func testInterleavedGainAndMute() {
        let input: [Float] = [0.8, -0.6, 0.25, -0.5]
        var output = [Float](repeating: 9, count: input.count)
        let gainMetrics = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                renderStereoFloat32(
                    inputLeft: source.baseAddress!, inputRight: source.baseAddress!,
                    outputLeft: destination.baseAddress!, outputRight: destination.baseAddress!,
                    frameCount: 2, gain: 0.5,
                    inputInterleaved: true, outputInterleaved: true
                )
            }
        }
        expect(abs(output[0] - 0.4) < 0.0001 && abs(output[1] + 0.3) < 0.0001, "interleaved gain")
        expect(abs(output[2] - 0.125) < 0.0001 && abs(output[3] + 0.25) < 0.0001, "interleaved second frame")
        expect(abs(gainMetrics.inputPeak - 0.8) < 0.0001, "input peak telemetry")
        expect(abs(gainMetrics.outputPeak - 0.4) < 0.0001, "output peak telemetry")

        output = [Float](repeating: 9, count: input.count)
        let muteMetrics = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                renderStereoFloat32(
                    inputLeft: source.baseAddress!, inputRight: source.baseAddress!,
                    outputLeft: destination.baseAddress!, outputRight: destination.baseAddress!,
                    frameCount: 2, gain: 0,
                    inputInterleaved: true, outputInterleaved: true
                )
            }
        }
        expect(output.allSatisfy { $0 == 0 }, "mute produces digital silence")
        expect(abs(muteMetrics.inputPeak - 0.8) < 0.0001 && muteMetrics.outputPeak == 0, "mute peak telemetry")
    }

    private static func testPlanarToInterleaved() {
        let left: [Float] = [0.5, -0.25]
        let right: [Float] = [-0.5, 0.75]
        var output = [Float](repeating: 0, count: 4)
        _ = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                output.withUnsafeMutableBufferPointer { o in
                    renderStereoFloat32(
                        inputLeft: l.baseAddress!, inputRight: r.baseAddress!,
                        outputLeft: o.baseAddress!, outputRight: o.baseAddress!,
                        frameCount: 2, gain: 0.5,
                        inputInterleaved: false, outputInterleaved: true
                    )
                }
            }
        }
        expect(output == [0.25, -0.25, -0.125, 0.375], "planar to interleaved conversion")
    }

    private static func testInterleavedToPlanar() {
        let input: [Float] = [0.2, -0.4, 0.6, -0.8]
        var left = [Float](repeating: 0, count: 2)
        var right = [Float](repeating: 0, count: 2)
        _ = input.withUnsafeBufferPointer { source in
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    renderStereoFloat32(
                        inputLeft: source.baseAddress!, inputRight: source.baseAddress!,
                        outputLeft: l.baseAddress!, outputRight: r.baseAddress!,
                        frameCount: 2, gain: 1,
                        inputInterleaved: true, outputInterleaved: false
                    )
                }
            }
        }
        expect(left == [0.2, 0.6] && right == [-0.4, -0.8], "interleaved to planar conversion")
    }

    private static func testAggregateSampleRateValidation() {
        expect(requiresNativeOutputConversion(tapRate: 48_000, selectedOutputRate: 44_100, selectedOutputChannels: 2), "48 kHz tap routes through the native converter for a 44.1 kHz stereo output")
        expect(requiresNativeOutputConversion(tapRate: 48_000, selectedOutputRate: 16_000, selectedOutputChannels: 1), "48 kHz stereo tap routes through the native converter for a 16 kHz mono output")
        expect(aggregateCaptureMatchesTap(tapRate: 48_000, aggregateInputRate: 48_000), "tap-only aggregate retains the tap input rate")
        expect(!aggregateCaptureMatchesTap(tapRate: 48_000, aggregateInputRate: 44_100), "reject aggregate input that does not match the tap")
        expect(!requiresNativeOutputConversion(tapRate: 48_000, selectedOutputRate: 48_000, selectedOutputChannels: 2), "same-rate stereo route can use direct IOProc")
        expect(requiresNativeOutputConversion(tapRate: 48_000, selectedOutputRate: 48_000, selectedOutputChannels: 1), "same-rate mono output uses native channel conversion")
    }

    private static func testNativeRateConversion() {
        checkAVAudioConverter(inputRate: 48_000, outputRate: 44_100)
        checkAVAudioConverter(inputRate: 44_100, outputRate: 48_000)
        checkAVAudioConverter(inputRate: 48_000, outputRate: 16_000, outputChannels: 1)
        var outputDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        if AudioComponentFindNext(nil, &outputDescription) != nil {
            checkManualEngineGraph(inputRate: 48_000, outputRate: 44_100)
            checkManualEngineGraph(inputRate: 44_100, outputRate: 48_000)
            checkManualEngineGraph(inputRate: 48_000, outputRate: 16_000, outputChannels: 1)
        } else {
            print("AVAudioEngine offline graph skipped: HAL output component is unavailable in this execution sandbox")
        }
    }

    private static func checkAVAudioConverter(inputRate: Double, outputRate: Double, outputChannels: AVAudioChannelCount = 2) {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: false)!
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: outputChannels, interleaved: false)!
        let totalFrames = Int(inputRate)
        let blockSizes = [127, 512, 1024, 289, 2048, 384, 768]
        var inputBlocks: [AVAudioPCMBuffer] = []
        var offset = 0
        var blockIndex = 0
        while offset < totalFrames {
            let count = min(blockSizes[blockIndex % blockSizes.count], totalFrames - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            let left = buffer.floatChannelData![0]
            let right = buffer.floatChannelData![1]
            for frame in 0..<count {
                let phase = 2 * Double.pi * 1_000 * Double(offset + frame) / inputRate
                left[frame] = Float(0.5 * sin(phase))
                right[frame] = Float(0.25 * sin(phase))
            }
            inputBlocks.append(buffer)
            offset += count
            blockIndex += 1
        }

        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        var nextInput = 0
        var outputLeft: [Float] = []
        var outputRight: [Float] = []
        let outputCapacities = [511, 1024, 733, 2048, 389]
        var ended = false
        for iteration in 0..<256 {
            let capacity = outputCapacities[iteration % outputCapacities.count]
            let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(capacity))!
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, inputStatus in
                if nextInput < inputBlocks.count {
                    let input = inputBlocks[nextInput]
                    nextInput += 1
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            expect(conversionError == nil, "AVAudioConverter \(inputRate) to \(outputRate) reports no error")
            if buffer.frameLength > 0 {
                let left = buffer.floatChannelData![0]
                let right = outputChannels == 2 ? buffer.floatChannelData![1] : nil
                outputLeft.append(contentsOf: UnsafeBufferPointer(start: left, count: Int(buffer.frameLength)))
                if let right {
                    outputRight.append(contentsOf: UnsafeBufferPointer(start: right, count: Int(buffer.frameLength)))
                }
            }
            if status == .endOfStream {
                ended = true
                break
            }
            expect(status != .error, "AVAudioConverter \(inputRate) to \(outputRate) does not return error status")
        }
        expect(ended, "AVAudioConverter \(inputRate) to \(outputRate) reaches end of stream")
        if outputChannels == 1 {
            verifyMonoTone(outputLeft, rate: outputRate)
        } else {
            verifyTone(outputLeft, right: outputRight, rate: outputRate)
        }
    }

    private static func checkManualEngineGraph(inputRate: Double, outputRate: Double, outputChannels: AVAudioChannelCount = 2) {
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: false)!
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: outputChannels, interleaved: false)!
        let engine = AVAudioEngine()
        try! engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 2_048)
        var sourceFrameCursor: Int64 = 0
        var sourceLayoutIssue = false
        let sourceNode = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count == 2,
                  buffers[0].mNumberChannels == 1, buffers[1].mNumberChannels == 1,
                  Int(buffers[0].mDataByteSize) >= Int(frameCount) * MemoryLayout<Float>.size,
                  Int(buffers[1].mDataByteSize) >= Int(frameCount) * MemoryLayout<Float>.size,
                  let leftData = buffers[0].mData, let rightData = buffers[1].mData else {
                sourceLayoutIssue = true
                return noErr
            }
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = rightData.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(frameCount) {
                let sampleIndex = sourceFrameCursor + Int64(frame)
                let phase = 2 * Double.pi * 1_000 * Double(sampleIndex) / inputRate
                left[frame] = Float(0.5 * sin(phase))
                right[frame] = Float(0.25 * sin(phase))
            }
            sourceFrameCursor += Int64(frameCount)
            return noErr
        }
        engine.attach(sourceNode)
        let mixer = engine.mainMixerNode
        engine.connect(sourceNode, to: mixer, format: sourceFormat)
        engine.connect(mixer, to: engine.outputNode, format: outputFormat)
        engine.prepare()
        expect(abs(engine.outputNode.outputFormat(forBus: 0).sampleRate - outputRate) < 0.5, "manual graph output uses the selected rate")
        expect(engine.outputNode.outputFormat(forBus: 0).channelCount == outputChannels, "manual graph output uses the selected channel count")
        expect(abs(mixer.outputFormat(forBus: 0).sampleRate - outputRate) < 0.5, "main mixer converts to the selected rate")
        expect(mixer.outputFormat(forBus: 0).channelCount == outputChannels, "main mixer converts to the selected channel count")
        try! engine.start()

        let expectedFrames = Int(outputRate)
        let outputCapacities = [511, 1024, 733, 2048, 389]
        var outputLeft: [Float] = []
        var outputRight: [Float] = []
        var iteration = 0
        while outputLeft.count < expectedFrames && iteration < 256 {
            let capacity = min(outputCapacities[iteration % outputCapacities.count], expectedFrames - outputLeft.count)
            let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(capacity))!
            let status = try! engine.renderOffline(AVAudioFrameCount(capacity), to: buffer)
            expect(status == .success, "manual engine renders a sample-rate conversion block")
            let count = Int(buffer.frameLength)
            outputLeft.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count))
            if outputChannels == 2 {
                outputRight.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![1], count: count))
            }
            iteration += 1
        }
        engine.stop()
        expect(!sourceLayoutIssue, "manual engine requests the expected planar source layout")
        expect(outputLeft.count == expectedFrames, "manual engine renders the expected frame count")
        if outputChannels == 1 {
            verifyMonoTone(outputLeft, rate: outputRate)
        } else {
            verifyTone(outputLeft, right: outputRight, rate: outputRate)
        }
    }

    private static func verifyMonoTone(_ samples: [Float], rate: Double) {
        let actualDuration = Double(samples.count) / rate
        expect(abs(actualDuration - 1) < 0.004, "stereo-to-mono conversion preserves one-second duration")

        let margin = min(Int(rate / 20), max(1, samples.count / 10))
        let interior = Array(samples[margin..<(samples.count - margin)])
        let rms = sqrt(interior.reduce(0.0) { $0 + Double($1 * $1) } / Double(interior.count))
        expect(rms > 0.15 && rms < 0.4, "stereo-to-mono conversion preserves a bounded signal without clipping")

        var positiveCrossings = 0
        if interior.count > 1 {
            for index in 1..<interior.count where interior[index - 1] <= 0 && interior[index] > 0 {
                positiveCrossings += 1
            }
        }
        let measuredFrequency = Double(positiveCrossings) / (Double(interior.count) / rate)
        expect(abs(measuredFrequency - 1_000) < 2, "stereo-to-mono conversion preserves tone frequency")

        var maxInteriorJump: Float = 0
        for index in (margin + 1)..<(samples.count - margin) {
            maxInteriorJump = max(maxInteriorJump, abs(samples[index] - samples[index - 1]))
        }
        expect(maxInteriorJump < 0.22, "stereo-to-mono conversion has no block-boundary jump")
    }

    private static func verifyTone(_ outputLeft: [Float], right outputRight: [Float], rate: Double) {
        let actualDuration = Double(outputLeft.count) / rate
        expect(abs(actualDuration - 1) < 0.004, "sample-rate conversion preserves one-second duration")

        let margin = min(Int(rate / 20), max(1, outputLeft.count / 10))
        let interior = Array(outputLeft[margin..<(outputLeft.count - margin)])
        let rms = sqrt(interior.reduce(0.0) { $0 + Double($1 * $1) } / Double(interior.count))
        expect(abs(rms - 0.5 / sqrt(2)) < 0.02, "sample-rate conversion preserves tone amplitude")

        var positiveCrossings = 0
        if interior.count > 1 {
            for index in 1..<interior.count where interior[index - 1] <= 0 && interior[index] > 0 {
                positiveCrossings += 1
            }
        }
        let measuredFrequency = Double(positiveCrossings) / (Double(interior.count) / rate)
        expect(abs(measuredFrequency - 1_000) < 2, "sample-rate conversion preserves tone frequency")

        var maxInteriorJump: Float = 0
        for index in (margin + 1)..<(outputLeft.count - margin) {
            maxInteriorJump = max(maxInteriorJump, abs(outputLeft[index] - outputLeft[index - 1]))
        }
        expect(maxInteriorJump < 0.16, "sample-rate conversion has no block-boundary jump")
        let rightRMS = sqrt(outputRight[margin..<(outputRight.count - margin)].reduce(0.0) { $0 + Double($1 * $1) } / Double(interior.count))
        expect(abs(rightRMS - rms / 2) < 0.015, "sample-rate conversion preserves independent stereo channels")
    }

    private static func testHelperProcessGrouping() {
        let chromeIDs: Set<String> = ["com.google.Chrome", "com.google.Chrome.helper"]
        expect(groupedAudioAppBundleID("com.google.Chrome.helper", knownBundleIDs: chromeIDs) == "com.google.Chrome", "Chromium helper maps to app")
        expect(groupedAudioAppBundleID("com.google.Chrome.helper.renderer", knownBundleIDs: chromeIDs) == "com.google.Chrome", "nested renderer maps to app")
        expect(groupedAudioAppBundleID("com.apple.Safari.WebContent", knownBundleIDs: ["com.apple.Safari"]) == "com.apple.Safari", "visible app bundle prefix maps to app")
        expect(groupedAudioAppBundleID("com.apple.WebKit.WebContent", knownBundleIDs: ["com.apple.Safari"]) == nil, "unrelated WebKit bundle is not guessed to be Safari")
        expect(groupedAudioAppBundleID("com.apple.WebKit.GPU", knownBundleIDs: ["com.apple.Safari"]) == nil, "WebKit GPU bundle is not guessed to be Safari")
        expect(groupedAudioAppBundleID("com.example.Player", knownBundleIDs: ["com.example"]) == nil, "ordinary nested ID is not mistaken for a helper")
        expect(groupedAudioAppBundleID(nil, knownBundleIDs: []) == nil, "missing bundle ID remains missing")
    }

    private static func testSafariProcessOwnership() {
        let visibleByPID: [pid_t: String] = [101: "com.apple.Safari"]
        let visibleIDs: Set<String> = ["com.apple.Safari"]
        let parentMap: [pid_t: pid_t] = [202: 101]
        let owned = resolveAudioProcessOwner(
            processPID: 202,
            processBundleID: "com.apple.WebKit.WebContent",
            visibleAppBundleIDsByPID: visibleByPID,
            visibleAppBundleIDs: visibleIDs,
            parentPIDForProcess: { parentMap[$0] }
        )
        expect(owned.bundleID == "com.apple.Safari", "WebKit process with a Safari ancestor maps to Safari")
        expect(owned.method == "parent-pid:101", "Safari ancestry is explicit in diagnostics")

        let unresolved = resolveAudioProcessOwner(
            processPID: 303,
            processBundleID: "com.apple.WebKit.GPU",
            visibleAppBundleIDsByPID: visibleByPID,
            visibleAppBundleIDs: visibleIDs,
            parentPIDForProcess: { _ in nil }
        )
        expect(unresolved.bundleID == "com.apple.WebKit.GPU", "unowned WebKit process remains separately controllable")
        expect(unresolved.method == "unresolved-bundle-id", "unowned WebKit process is explicit in diagnostics")
        let firstKey = audioProcessGroupKey(
            processPID: 303,
            processBundleID: "com.apple.WebKit.GPU",
            ownerBundleID: unresolved.bundleID,
            method: unresolved.method
        )
        let secondKey = audioProcessGroupKey(
            processPID: 304,
            processBundleID: "com.apple.WebKit.GPU",
            ownerBundleID: unresolved.bundleID,
            method: unresolved.method
        )
        expect(firstKey == "pid-303" && secondKey == "pid-304", "unresolved WebKit processes remain separate by PID")
    }

    private static func testAudioSourceOrdering() {
        let entries = [
            AudioSourceOrderEntry(id: "open-safari", hasCoreAudioClient: false, isProducingAudio: false),
            AudioSourceOrderEntry(id: "idle-music", hasCoreAudioClient: true, isProducingAudio: false),
            AudioSourceOrderEntry(id: "live-webkit", hasCoreAudioClient: true, isProducingAudio: true)
        ]
        expect(orderedAudioSourceIDs(entries) == ["live-webkit", "idle-music", "open-safari"], "active Core Audio sources appear before recent clients and other open apps")
    }
}
