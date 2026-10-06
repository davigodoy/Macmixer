import Foundation

struct StereoRenderMetrics: Equatable {
    let inputPeak: Float
    let outputPeak: Float
}

func requiresNativeOutputConversion(tapRate: Double, selectedOutputRate: Double, selectedOutputChannels: UInt32) -> Bool {
    guard tapRate.isFinite, tapRate > 0,
          selectedOutputRate.isFinite, selectedOutputRate > 0,
          (1...2).contains(selectedOutputChannels) else { return false }
    return abs(tapRate - selectedOutputRate) >= 0.5 || selectedOutputChannels != 2
}

func aggregateCaptureMatchesTap(tapRate: Double, aggregateInputRate: Double) -> Bool {
    guard tapRate.isFinite, tapRate > 0,
          aggregateInputRate.isFinite, aggregateInputRate > 0 else { return false }
    return abs(tapRate - aggregateInputRate) < 0.5
}

/// Cubic perceptual curve: volume 0...100 maps to gain (v/100)^3; muted is silence.
@inline(__always)
func perceptualGain(volume: Int32, muted: Bool) -> Float {
    if muted { return 0 }
    let linear = Float(max(0, min(100, volume))) / 100
    return linear * linear * linear
}

/// Applies gain while converting between interleaved and planar stereo Float32 buffers.
/// For interleaved input/output, both channel pointers refer to the same storage.
@inline(__always)
func renderStereoFloat32(
    inputLeft: UnsafePointer<Float>,
    inputRight: UnsafePointer<Float>,
    outputLeft: UnsafeMutablePointer<Float>,
    outputRight: UnsafeMutablePointer<Float>,
    frameCount: Int,
    gain: Float,
    inputInterleaved: Bool,
    outputInterleaved: Bool
) -> StereoRenderMetrics {
    renderStereoFloat32(
        inputLeft: inputLeft, inputRight: inputRight,
        outputLeft: outputLeft, outputRight: outputRight,
        frameCount: frameCount, startGain: gain, endGain: gain,
        inputInterleaved: inputInterleaved, outputInterleaved: outputInterleaved
    )
}

/// Same as above, ramping gain linearly from startGain (first frame) to endGain (last frame).
@inline(__always)
func renderStereoFloat32(
    inputLeft: UnsafePointer<Float>,
    inputRight: UnsafePointer<Float>,
    outputLeft: UnsafeMutablePointer<Float>,
    outputRight: UnsafeMutablePointer<Float>,
    frameCount: Int,
    startGain: Float,
    endGain: Float,
    inputInterleaved: Bool,
    outputInterleaved: Bool
) -> StereoRenderMetrics {
    guard frameCount > 0 else { return StereoRenderMetrics(inputPeak: 0, outputPeak: 0) }
    var inputPeak: Float = 0
    var outputPeak: Float = 0
    let step = frameCount > 1 ? (endGain - startGain) / Float(frameCount - 1) : 0
    for frame in 0..<frameCount {
        let gain = frame == frameCount - 1 ? endGain : startGain + step * Float(frame)
        let inputIndex = inputInterleaved ? frame * 2 : frame
        let outputIndex = outputInterleaved ? frame * 2 : frame
        let inputL = inputLeft[inputIndex]
        let inputR = inputRight[inputInterleaved ? inputIndex + 1 : inputIndex]
        let left = inputL * gain
        let right = inputR * gain
        if inputL.isFinite { inputPeak = max(inputPeak, abs(inputL)) }
        if inputR.isFinite { inputPeak = max(inputPeak, abs(inputR)) }
        if left.isFinite { outputPeak = max(outputPeak, abs(left)) }
        if right.isFinite { outputPeak = max(outputPeak, abs(right)) }
        outputLeft[outputIndex] = left
        outputRight[outputInterleaved ? outputIndex + 1 : outputIndex] = right
    }
    return StereoRenderMetrics(inputPeak: inputPeak, outputPeak: outputPeak)
}
