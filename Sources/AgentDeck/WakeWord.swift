import AVFoundation
import Speech
import SwiftUI

/// "안녕 수혁아" voice commands. When turned on in Settings, on-device recognition listens all the time;
/// after the wake phrase, what follows goes to the agent it names: "안녕 수혁아, 펠릭스 커밋해 줘".
@MainActor
final class WakeWord: ObservableObject {
    static let shared = WakeWord()
    static let enabledKey = "wakeWordEnabled"

    enum State: Equatable { case off, listening, awake, failed(String) }
    @Published private(set) var state: State = .off

    private weak var store: SessionStore?
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private let feed = RequestFeed()
    private var task: SFSpeechRecognitionTask?
    /// Bumped on each restart so callbacks from an old recognition task are ignored.
    private var round = 0
    private var silence: Task<Void, Never>?
    private var paused = false
    /// What follows the wake phrase so far in this round.
    private var pending = ""

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func attach(_ store: SessionStore) {
        NSLog("[wake] attach enabled=%d", enabled ? 1 : 0)
        self.store = store
        if enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        on ? start() : stop()
    }

    /// Dictation in the dialogue needs the microphone to itself.
    func pause() { paused = true; stopAudio() }
    func resume() { paused = false; if enabled { start() } }

    private func start() {
        guard state == .off || state.isFailed, !paused else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async {
                    NSLog("[wake] auth speech=%d mic=%d", status.rawValue, mic ? 1 : 0)
                    guard status == .authorized, mic else {
                        self.state = .failed("음성 인식·마이크 권한이 필요함 — 시스템 설정 > 개인정보 보호 및 보안")
                        return
                    }
                    self.beginAudio()
                }
            }
        }
    }

    private func stop() {
        stopAudio()
        state = .off
    }

    private func beginAudio() {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            state = .failed("이 Mac에서 한국어 온디바이스 음성 인식을 쓸 수 없음 — 시스템 설정 > 키보드 > 받아쓰기를 켤 것")
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { state = .failed("입력 장치(마이크)를 찾지 못함"); return }
        input.removeTap(onBus: 0)
        Self.installTap(on: input, format: format, feed: feed)
        engine.prepare()
        do { try engine.start() } catch { state = .failed("마이크를 열지 못함: \(error.localizedDescription)"); return }
        state = .listening
        NSLog("[wake] listening")
        newRound()
    }

    private func stopAudio() {
        silence?.cancel()
        round += 1
        task?.cancel()
        task = nil
        feed.set(nil)
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// A fresh recognition request, so each command starts from empty text. On-device tasks also end on
    /// their own after a while; they are restarted the same way.
    private func newRound() {
        guard let recognizer, engine.isRunning else { return }
        silence?.cancel()
        task?.cancel()
        round += 1
        let mine = round
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        // Bias recognition toward the wake phrase and the agents' names.
        req.contextualStrings = ["안녕 수혁아", "수혁아"] + (store.map { s in s.sessions.map { s.agentName(for: $0) } } ?? [])
        feed.set(req)
        task = Self.recognize(recognizer, req) { [weak self] text, done in
            DispatchQueue.main.async {
                guard let self, mine == self.round else { return }
                if let text { self.heard(text) }
                // A task that ends mid-command (on-device recognition finalizes after a pause) still counts.
                if done, mine == self.round { self.state == .awake ? self.finish(self.pending) : self.newRound() }
            }
        }
    }

    private func heard(_ text: String) {
        // Ignore our own voice reading a reply aloud.
        if Speaker.shared.speaking { return }
        guard let command = Self.afterWake(text) else { return }
        pending = command
        if state != .awake {
            NSLog("[wake] wake phrase heard: %@", text)
            state = .awake
            NSSound(named: "Tink")?.play()
        }
        // The command is done once the words stop changing for a moment; with nothing said yet, wait longer.
        silence?.cancel()
        let wait: Duration = command.isEmpty ? .seconds(6) : .seconds(1.6)
        silence = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.finish(command)
        }
    }

    private func finish(_ command: String) {
        NSLog("[wake] command: %@", command)
        state = .listening
        pending = ""
        newRound()
        guard !command.isEmpty else { NSSound(named: "Bottle")?.play(); return }
        guard let store else { return }
        let named = store.sessions.map { (store.agentName(for: $0), $0) }
        guard let (name, text) = Self.route(command, names: named.map(\.0)),
              let session = named.first(where: { $0.0 == name })?.1 else {
            Speaker.shared.say("누구에게 시킬지 못 들었어요. 에이전트 이름을 먼저 말해 주세요.")
            return
        }
        guard !text.isEmpty else { Speaker.shared.say("\(name)에게 무엇을 시킬까요?"); return }
        Task.detached {
            let ok = SessionInput.send(session, text: text)
            await MainActor.run {
                Speaker.shared.say(ok ? "\(name)에게 전달했어요." : "\(name)에게 보내지 못했어요.")
            }
        }
    }

    // MARK: parsing (pure, so it can be checked without a microphone)

    nonisolated private static let wake = try! NSRegularExpression(pattern: #"안녕\s*[,.!?]?\s*수\s*혁\s*(아|이|야)?[\s,.!?]*"#)

    /// The words after the last wake phrase, or nil if the phrase was not said.
    nonisolated static func afterWake(_ text: String) -> String? {
        let ns = text as NSString
        guard let m = wake.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits "펠릭스야, 커밋해 줘" into the named agent and the instruction. The name has to come first;
    /// the longest name wins, so "아린" is not read as "린". Names are compared by sound, not spelling:
    /// speech recognition writes "아린아" as "아리 나" (the final ㄴ moves to the next syllable).
    nonisolated static func route(_ command: String, names: [String]) -> (name: String, text: String)? {
        let c = Array(command.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
        // Sounds of the command with where each one came from; spaces carry no sound.
        var sounds: [(sound: Swift.Character, at: Int)] = []
        for (i, ch) in c.enumerated() where !ch.isWhitespace { sounds += Self.sounds(ch).map { ($0, i) } }
        var best: (name: String, end: Int, midSyllable: Bool)?
        for name in names {
            let n = name.flatMap(Self.sounds)
            guard !n.isEmpty, n.count <= sounds.count, zip(n, sounds).allSatisfy({ $0 == $1.sound }) else { continue }
            let last = sounds[n.count - 1].at
            let midSyllable = n.count < sounds.count && sounds[n.count].at == last
            if best == nil || name.count > best!.name.count { best = (name, last, midSyllable) }
        }
        guard let best else { return nil }
        // The name ended inside a syllable ("아리 나"): the rest of it is the vocative 아/이, so skip it.
        var rest = Substring(String(c[(best.end + 1)...]))
        if !best.midSyllable {
            // Vocative and dative endings after the name: 펠릭스야 / 펠릭스한테 / 펠릭스에게 / 펠릭스님 …
            for ending in ["한테", "에게", "님", "씨", "야", "아", "이", "은", "는"] where rest.hasPrefix(ending) {
                let after = rest.dropFirst(ending.count)
                if after.isEmpty || after.first!.isWhitespace || after.first!.isPunctuation { rest = after; break }
            }
        }
        let text = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (best.name, text)
    }

    private nonisolated static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    private nonisolated static let vowels = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    private nonisolated static let finals: [String] = ["", "ㄱ", "ㄲ", "ㄱㅅ", "ㄴ", "ㄴㅈ", "ㄴㅎ", "ㄷ", "ㄹ", "ㄹㄱ", "ㄹㅁ", "ㄹㅂ",
        "ㄹㅅ", "ㄹㅌ", "ㄹㅍ", "ㄹㅎ", "ㅁ", "ㅂ", "ㅂㅅ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]

    /// A Hangul syllable as consonant and vowel letters, with the silent initial ㅇ dropped (아 = ㅏ).
    nonisolated static func sounds(_ ch: Swift.Character) -> [Swift.Character] {
        guard let v = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1, (0xAC00...0xD7A3).contains(v) else {
            return [ch]
        }
        let i = Int(v - 0xAC00)
        let initial = initials[i / 588]
        var out: [Swift.Character] = initial == "ㅇ" ? [] : [initial]
        out.append(vowels[(i % 588) / 28])
        out += Array(finals[i % 28])
        return out
    }

    /// `AgentDeck --wake-test <audio file> [names…]`: recognizes a recording and prints what would be sent.
    static func test(file: String, names: [String]) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR")) else { print("no recognizer"); exit(1) }
        let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: file))
        req.requiresOnDeviceRecognition = true
        req.contextualStrings = ["안녕 수혁아", "수혁아"] + names
        var finished = false
        setbuf(stdout, nil)
        print("speech auth before request:", SFSpeechRecognizer.authorizationStatus().rawValue)
        SFSpeechRecognizer.requestAuthorization { status in
            print("speech auth:", status.rawValue, "onDevice:", r.supportsOnDeviceRecognition)
            _ = r.recognitionTask(with: req) { result, err in
                if let err { print("error:", err.localizedDescription) }
                let text = result?.bestTranscription.formattedString
                let done = err != nil || (result?.isFinal ?? false)
                guard done else { return }
                let t = text ?? ""
                print("heard:", t)
                if let cmd = afterWake(t) {
                    print("command:", cmd)
                    if let (name, text) = route(cmd, names: names) { print("to:", name, "| text:", text) } else { print("to: (no agent named)") }
                } else { print("no wake phrase") }
                finished = true
            }
        }
        let end = Date().addingTimeInterval(30)
        while !finished, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        exit(finished ? 0 : 1)
    }

    // MARK: audio plumbing kept off the main actor

    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, feed: RequestFeed) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
    }

    nonisolated private static func recognize(_ r: SFSpeechRecognizer, _ req: SFSpeechRecognitionRequest,
                                              update: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        r.recognitionTask(with: req) { result, err in
            update(result?.bestTranscription.formattedString, err != nil || (result?.isFinal ?? false))
        }
    }
}

extension WakeWord.State {
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}

/// The microphone tap outlives each recognition request; it feeds whichever one is current.
final class RequestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request?.endAudio(); request = r; lock.unlock() }
    func append(_ b: AVAudioPCMBuffer) { lock.lock(); request?.append(b); lock.unlock() }
}

struct WakeWordSettings: View {
    @ObservedObject private var wake = WakeWord.shared
    @State private var on = WakeWord.shared.enabled

    var body: some View {
        Toggle("\"안녕 수혁아\"로 음성 지시", isOn: $on)
            .onChange(of: on) { _, v in wake.setEnabled(v) }
        Text("예: \"안녕 수혁아, 펠릭스 커밋해 줘\" — 에이전트 이름을 먼저 말하면 그 에이전트에게 지시를 보냄. 소리 인식은 이 Mac 안에서만 처리하지만, 켜 두는 동안 마이크가 계속 켜져 있음.")
            .font(.caption).foregroundStyle(.secondary)
        if case .failed(let msg) = wake.state { Text(msg).font(.caption).foregroundStyle(.orange) }
    }
}
