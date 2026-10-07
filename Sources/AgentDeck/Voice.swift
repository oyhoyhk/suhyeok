import AVFoundation
import Speech
import SwiftUI

/// Voice for the dialogue: dictation into the input (on-device Speech, Korean first) and spoken replies.
/// Claude Code's own /voice is push-to-talk inside its TUI (hold space), which works in the embedded terminal;
/// the dialogue has no held key to forward, so it dictates here and sends text instead.
@MainActor
final class Dictation: ObservableObject {
    @Published var listening = false
    @Published var text = ""
    @Published var error: String?

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
    }
}

/// Reads finished agent replies aloud, one system voice per character so each NPC sounds different.
@MainActor
final class Speaker: NSObject, ObservableObject {
    static let shared = Speaker()
    @Published var speaking = false
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, characterId: String?) {
        let clean = Self.plain(text)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        u.voice = Self.voice(for: characterId)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// Korean voices installed on this Mac, picked by a stable hash of the character id.
    static func voice(for characterId: String?) -> AVSpeechSynthesisVoice? {
        let ko = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ko-KR" }
            .sorted { $0.identifier < $1.identifier }
        guard !ko.isEmpty else { return AVSpeechSynthesisVoice(language: "ko-KR") }
        var h: UInt64 = 0xcbf29ce484222325
        for b in (characterId ?? "").utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return ko[Int(h % UInt64(ko.count))]
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
