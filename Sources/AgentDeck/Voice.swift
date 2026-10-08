import AVFoundation
import Supertonic
#if canImport(FoundationModels)
import FoundationModels
#endif
import Speech
import SwiftUI

/// Voice for the dialogue: dictation into the input (on-device Speech, Korean first) and spoken replies.
/// Claude Code's own /voice is push-to-talk inside its TUI (hold space), which works in the embedded terminal;
/// the dialogue has no held key to forward, so it dictates here and sends text instead.
@MainActor
final class Dictation: ObservableObject {
    @Published var listening = false
    @Published var text = ""
    /// Any failure ends the attempt, so the wake listener gets the microphone back.
    @Published var error: String? { didSet { if error != nil { WakeWord.shared.resume() } } }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))

    /// macOS speech recognition only works while Dictation is turned on in System Settings.
    nonisolated(unsafe) static var dictationOff = false

    static func log(_ s: String) {
        NSLog("[dictation] %@", s)
        if let path = ProcessInfo.processInfo.environment["SUHYEOK_DICTATION_LOG"] ?? UserDefaults.standard.string(forKey: "dictationLog"),
           let h = FileHandle(forWritingAtPath: path) ?? { FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path) }() {
            h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close()
        }
    }

    func toggle() { listening ? stop() : start() }

    func start() {
        error = nil
        WakeWord.shared.pause()
        Self.log("start; speech auth=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic auth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        // Callbacks arrive on background queues; hop to the main actor explicitly.
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { self.afterSpeechAuth(status) }
        }
    }

    private func afterSpeechAuth(_ status: SFSpeechRecognizerAuthorizationStatus) {
        Self.log("speech auth -> \(status.rawValue)")
        guard status == .authorized else {
            error = "음성 인식 권한이 없음 — 시스템 설정 > 개인정보 보호 및 보안 > 음성 인식에서 수혁을 켜 주세요"
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                Dictation.log("mic auth -> \(ok)")
                if ok { self.begin() } else { self.error = "마이크 권한이 없음 — 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 수혁을 켜 주세요" }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { error = "음성 인식을 지금 쓸 수 없음"; Self.log("recognizer unavailable"); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }  // stays on this Mac
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Self.log("input format \(format.sampleRate)Hz ch=\(format.channelCount)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            error = "입력 장치(마이크)를 찾지 못함 — 시스템 설정 > 사운드 > 입력을 확인해 주세요"
            return
        }
        input.removeTap(onBus: 0)
        Self.installTap(on: input, format: format, request: req)
        engine.prepare()
        do { try engine.start() } catch {
            self.error = "마이크를 열지 못함: \(error.localizedDescription)"; Self.log("engine start failed \(error)"); return
        }
        text = ""
        listening = true
        task = Self.recognize(recognizer, req) { [weak self] text, done in
            DispatchQueue.main.async {
                guard let self else { return }
                if let text { self.text = text }
                if Dictation.dictationOff {
                    self.error = "macOS 받아쓰기가 꺼져 있음 — 시스템 설정 > 키보드 > 받아쓰기를 켜면 됨"
                    Dictation.dictationOff = false
                }
                if done { self.finish() }
            }
        }
        Self.log("listening")
    }

    /// The tap runs on the audio thread: keep it out of the main actor.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func recognize(_ r: SFSpeechRecognizer, _ req: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        r.recognitionTask(with: req) { result, err in
            if let err { Dictation.log("recognition ended: \(err.localizedDescription)") }
            if let err, err.localizedDescription.contains("Siri and Dictation are disabled") {
                Dictation.dictationOff = true
            }
            update(result?.bestTranscription.formattedString, err != nil || (result?.isFinal ?? false))
        }
    }

    func stop() {
        Self.log("stop; text=\(text)")
        request?.endAudio()  // the task delivers the final text, then finish() runs
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        listening = false
    }

    private func finish() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        task = nil
        request = nil
        listening = false
        WakeWord.shared.resume()
    }
}

/// Reads finished agent replies aloud, one system voice per character so each NPC sounds different.
@MainActor
final class Speaker: NSObject, ObservableObject {
    static let shared = Speaker()
    @Published var speaking = false
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Bumped by every speak/stop so a summary that finishes late does not talk over a newer reply.
    private var generation = 0

    /// Says a short fixed line as is (confirmations), in the same voice as replies.
    func say(_ line: String) {
        generation += 1
        let mine = generation
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        Task { await play(line, characterId: nil, generation: mine) }
    }

    /// Reads a short spoken summary of the reply (on-device model), or its opening when no model is available.
    func speak(_ text: String, characterId: String?) {
        let clean = Self.plain(text)
        guard !clean.isEmpty else { return }
        generation += 1
        let mine = generation
        synth.stopSpeaking(at: .immediate)
        Task {
            let summary = await SpokenSummary.make(clean).map(Self.plain)
            guard mine == generation else { return }
            var said = summary ?? Self.gist(clean)
            // A question at the end of the reply is what the agent needs from you: always say it.
            if summary != nil, !said.contains("?"), let ask = clean.components(separatedBy: "\n").last(where: { !$0.isEmpty }),
               ask.hasSuffix("?") { said += " " + ask }
            await play(said, characterId: characterId, generation: mine)
        }
    }

    /// Supertonic F1 when its model is installed; the system voice while it downloads or if it fails.
    private func play(_ said: String, characterId: String?, generation mine: Int) async {
        if let data = await NeuralVoice.shared.wav(said) {
            guard mine == generation else { return }
            if let p = try? AVAudioPlayer(data: data) {
                player = p
                p.delegate = self
                speaking = p.play()
                if speaking { return }
            }
        }
        guard mine == generation else { return }
        let u = AVSpeechUtterance(string: said)
        let (voice, pitch) = Self.voice(for: characterId)
        u.voice = voice
        u.pitchMultiplier = pitch
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(u)
    }

    func stop() {
        generation += 1
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        speaking = false
    }

    /// The best-quality Korean voices installed on this Mac (Premium > Enhanced > default), one per character
    /// by a stable hash of its id. With fewer voices than characters, pitch varies so NPCs still sound apart.
    /// Novelty voices (Grandpa, Rocko, …) are used only when nothing else is installed.
    static func voice(for characterId: String?) -> (AVSpeechSynthesisVoice?, Float) {
        let ko = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ko-KR" }
        let natural = ko.filter { !$0.identifier.contains(".eloquence.") }
        let pool = natural.isEmpty ? ko : natural
        let best = pool.map(\.quality.rawValue).max() ?? 0
        let voices = pool.filter { $0.quality.rawValue == best }.sorted { $0.identifier < $1.identifier }
        var h: UInt64 = 0xcbf29ce484222325
        for b in (characterId ?? "").utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let pitches: [Float] = [1.0, 0.9, 1.1, 0.95, 1.05]
        let pitch = pitches[Int((h >> 8) % UInt64(pitches.count))]
        guard !voices.isEmpty else { return (AVSpeechSynthesisVoice(language: "ko-KR"), pitch) }
        return (voices[Int(h % UInt64(voices.count))], pitch)
    }

    /// Without a model: the opening line (replies lead with the conclusion) and a closing question, if any.
    static func gist(_ clean: String) -> String {
        let lines = clean.components(separatedBy: "\n").filter { !$0.isEmpty }
        let head = String((lines.first ?? "").prefix(200))
        guard let ask = lines.last, ask != lines.first, ask.hasSuffix("?") else { return head }
        return head + "\n" + ask
    }

    /// Markdown and code are noise when spoken: drop code blocks, tables and symbols, keep the prose.
    static func plain(_ s: String) -> String {
        var out: [String] = []
        var inCode = false
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || t.hasPrefix("|") { continue }
            out.append(t.replacingOccurrences(of: #"[*_`#>\[\]]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\(https?://[^)]*\)"#, with: "", options: .regularExpression))
        }
        let joined = out.filter { !$0.isEmpty }.joined(separator: "\n")
        return String(joined.prefix(1200))  // long reports: read the opening, the rest stays on screen
    }
}

extension Speaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if self.player === p { self.player = nil; self.speaking = false } }
    }
}

/// The Supertonic F1 voice, loaded on first use. The model (about 400 MB) is not bundled: the first reply
/// read aloud starts the download and uses the system voice; later replies use F1 once it is in place.
final class NeuralVoice: @unchecked Sendable {
    static let shared = NeuralVoice()
    static let voice = "F1"
    static let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Suhyeok/supertonic"

    /// Model state is touched only on this queue; the model itself is not safe to run concurrently.
    private let queue = DispatchQueue(label: "suhyeok.supertonic")
    private var tts: SupertonicTTS?
    private var downloading = false

    var installed: Bool { SupertonicTTS.isInstalled(dir: Self.dir, voice: Self.voice) }

    /// WAV bytes for `text`, or nil while the model is not installed (the download starts) or synthesis fails.
    func wav(_ text: String) async -> Data? {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.synthesize(text)) } }
    }

    private func synthesize(_ text: String) -> Data? {
        if tts == nil {
            guard installed else { startDownload(); return nil }
            do { tts = try SupertonicTTS(dir: Self.dir, voice: Self.voice) } catch {
                NSLog("[voice] supertonic load failed: %@", "\(error)"); return nil
            }
        }
        do { return try tts?.wav(text) } catch { NSLog("[voice] supertonic synth failed: %@", "\(error)"); return nil }
    }

    private func startDownload() {
        guard !downloading else { return }
        downloading = true
        Task.detached {
            do { try await self.install() } catch { NSLog("[voice] supertonic download failed: %@", "\(error)") }
            self.queue.async { self.downloading = false }
        }
    }

    func install() async throws {
        try await SupertonicTTS.download(to: Self.dir, voice: Self.voice)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = true }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}

/// A two-or-three sentence spoken version of a reply, from Apple's on-device model (macOS 26 with
/// Apple Intelligence on). Free and local; returns nil when the model is unavailable or fails.
enum SpokenSummary {
    static func make(_ reply: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return await OnDevice.make(reply) }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    @Generable struct Spoken {
        @Guide(description: "소리 내어 읽을 한국어 요약. 존댓말 구어체 두세 문장, 150자 이내. 모든 문장을 끝맺는다. 결론을 먼저 말하고 질문이 있으면 마지막에 말한다. 마크다운·코드·파일 경로·기호를 쓰지 않는다.")
        var text: String
    }

    @available(macOS 26, *)
    enum OnDevice {
        static func make(_ reply: String) async -> String? {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let session = LanguageModelSession(instructions: "너는 에이전트의 답변을 사용자에게 짧게 말로 전해 주는 비서다.")
            // The on-device context is about 4k tokens; the opening carries the conclusion anyway.
            let prompt = "다음 답변을 들려줄 요약으로 바꿔라.\n\n" + String(reply.prefix(2500))
            guard let text = try? await session.respond(to: prompt, generating: Spoken.self,
                                                        options: GenerationOptions(temperature: 0.2)).content.text
            else { return nil }
            let spoken = firstSentences(wholeSentences(text), upTo: 200)
            return spoken.count < 10 ? nil : spoken
        }

        /// The model sometimes copies the reply instead of summarizing; keep only what fits in a short listen.
        static func firstSentences(_ s: String, upTo limit: Int) -> String {
            var out = ""
            for part in s.split(separator: " ", omittingEmptySubsequences: false) {
                let next = out.isEmpty ? String(part) : out + " " + part
                if next.count > limit, let cut = out.lastIndex(where: { ".?!".contains($0) }) { return String(out[...cut]) }
                out = next
            }
            return out
        }

        /// The model sometimes stops mid-sentence; keep up to the last finished one.
        static func wholeSentences(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = t.last, !".?!".contains(last),
                  let cut = t.lastIndex(where: { ".?!".contains($0) }) else { return t }
            return String(t[...cut])
        }
    }
    #endif
}
