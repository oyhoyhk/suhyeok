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

    func toggle() { listening ? stop() : start() }

    func start() {
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.error = "음성 인식 권한이 없음 — 시스템 설정 > 개인정보 보호 > 음성 인식에서 수혁 허용"
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    Task { @MainActor in
                        if ok { self.begin() } else { self.error = "마이크 권한이 없음 — 시스템 설정 > 개인정보 보호 > 마이크에서 수혁 허용" }
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { error = "음성 인식을 지금 쓸 수 없음"; return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }  // stays on this Mac
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
        }
        do { try engine.start() } catch { self.error = "마이크를 열지 못함: \(error.localizedDescription)"; return }
        text = ""
        listening = true
        task = recognizer.recognitionTask(with: req) { result, err in
            Task { @MainActor in
                if let result { self.text = result.bestTranscription.formattedString }
                if err != nil || (result?.isFinal ?? false) { self.finish() }
            }
        }
    }

    func stop() {
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
