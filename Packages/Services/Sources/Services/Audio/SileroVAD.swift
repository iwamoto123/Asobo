import Foundation
import OnnxRuntimeBindings

/// Stateful Silero VAD wrapper backed by ONNX Runtime.
/// このモデルは state 出力を持たないため、state は常にゼロで使い回す。
public final class SileroVAD {
    private let env: ORTEnv
    private let session: ORTSession
    private var stateBuffer: [Float]
    private let sampleRateValue: ORTValue

    private let inputName = "input"
    private let stateInputName = "state"
    private let sampleRateName = "sr"
    private let outputName = "output"

    private static let sampleRate: Int64 = 16_000
    private static let stateShape: [NSNumber] = [2, 1, 128]
    private static let stateElementCount = 2 * 1 * 128

    public init() throws {
        guard let modelURL = Bundle.main.url(forResource: "silero_vad",
                                             withExtension: "onnx") else {
            throw NSError(
                domain: "SileroVAD",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "silero_vad.onnx not found in bundle"]
            )
        }

        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        session = try ORTSession(
            env: env,
            modelPath: modelURL.path,
            sessionOptions: options
        )

        // state は「全部 0」で初期化して維持（モデルからの更新はできない）
        stateBuffer = Array(repeating: 0, count: Self.stateElementCount)
        sampleRateValue = try Self.makeSampleRateValue()
    }

    /// Runs VAD over a 16 kHz mono segment and returns speech probability (0.0 ... 1.0).
    public func process(segment: [Float]) -> Float {
        do {
            let inputTensor = try Self.makeTensor(
                from: segment,
                shape: [1, NSNumber(value: segment.count)]
            )

            // モデル側に state 入力はあるので、ゼロ状態を渡す
            let stateTensor = try Self.makeTensor(
                from: stateBuffer,
                shape: Self.stateShape
            )

            let inputs: [String: ORTValue] = [
                inputName: inputTensor,
                stateInputName: stateTensor,
                sampleRateName: sampleRateValue
            ]

            let outputsDict: [String: ORTValue] = try session.run(
                withInputs: inputs,
                outputNames: [outputName],
                runOptions: nil
            )

            guard let probValue = outputsDict[outputName] else {
                throw NSError(
                    domain: "SileroVAD",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Missing output tensor 'output'"]
                )
            }

            let probability = try Self.extractProbability(from: probValue)
            // Debug: surface probability value
            // print("🎯 SileroVAD prob=\(probability)")
            return probability
        } catch {
            print("❌ SileroVAD process failed: \(error)")
            return 0.0
        }
    }

    // MARK: - Helpers

    private static func makeSampleRateValue() throws -> ORTValue {
        var sr = sampleRate
        let data = Data(bytes: &sr, count: MemoryLayout<Int64>.size)
        let mutable = NSMutableData(data: data)
        return try ORTValue(
            tensorData: mutable,
            elementType: .int64,
            shape: [1]
        )
    }

    private static func makeTensor(from values: [Float],
                                   shape: [NSNumber]) throws -> ORTValue {
        let data = values.withUnsafeBytes { Data($0) }
        let mutable = NSMutableData(data: data)
        return try ORTValue(
            tensorData: mutable,
            elementType: .float,
            shape: shape
        )
    }

    private static func extractProbability(from value: ORTValue) throws -> Float {
        let data = try value.tensorData() as Data
        guard data.count >= MemoryLayout<Float>.size else {
            throw NSError(
                domain: "SileroVAD",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Probability tensor is empty"]
            )
        }

        let prob: Float = data.withUnsafeBytes { rawPtr in
            rawPtr.bindMemory(to: Float.self)[0]
        }
        return prob
    }
}
