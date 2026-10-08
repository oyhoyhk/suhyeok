import Foundation
import OnnxRuntimeBindings

/// Supertonic 3 text-to-speech (on-device ONNX). The model files are not bundled: `SupertonicTTS.download`
/// fetches them once into `dir`, pinned to the revision this code was tested with.
public final class SupertonicTTS {
    public static let revision = "aafc6e32416a594460b32413efc49d7fe4ce6d46"
    public static let modelFiles = ["onnx/duration_predictor.onnx", "onnx/text_encoder.onnx", "onnx/tts.json",
                                    "onnx/unicode_indexer.json", "onnx/vector_estimator.onnx", "onnx/vocoder.onnx"]

    private let env: ORTEnv
    private let tts: TextToSpeech
    private let style: Style

    /// `dir` holds onnx/… and voice_styles/<voice>.json as laid out in the Hugging Face repo.
    public init(dir: String, voice: String) throws {
        env = try ORTEnv(loggingLevel: .warning)
        tts = try loadTextToSpeech(dir + "/onnx", false, env)
        style = try loadVoiceStyle([dir + "/voice_styles/\(voice).json"], verbose: false)
    }

    public static func isInstalled(dir: String, voice: String) -> Bool {
        (modelFiles + ["voice_styles/\(voice).json"]).allSatisfy { FileManager.default.fileExists(atPath: dir + "/" + $0) }
    }

    /// Downloads whatever is missing (about 400 MB in all). Each file lands under a temp name first,
    /// so an interrupted download never leaves a half file that looks installed.
    public static func download(to dir: String, voice: String) async throws {
        for file in modelFiles + ["voice_styles/\(voice).json"] {
            let dest = URL(fileURLWithPath: dir + "/" + file)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            let url = URL(string: "https://huggingface.co/supertone-oss-archive/supertonic-3/resolve/\(revision)/\(file)")!
            let (tmp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
    }

    /// Synthesizes `text` and returns a 16-bit mono WAV file's bytes.
    public func wav(_ text: String, lang: String = "ko", speed: Float = 1.05) throws -> Data {
        let (samples, _) = try tts.call(text, lang, style, 8, speed: speed, silenceDuration: 0.3)
        let path = NSTemporaryDirectory() + "supertonic-\(UUID().uuidString).wav"
        try writeWavFile(path, samples, tts.sampleRate)
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
}
