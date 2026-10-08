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
    /// What follows the wake phrase so far.
    private var pending = ""
    /// Command words from earlier rounds: recognition often ends a round at the pause after "안녕 수혁아",
    /// so the command continues in the next round, which has no wake phrase in it.
    private var carried = ""
    private var continuing = false

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
    private func newRound(continuing: Bool = false) {
        guard let recognizer, engine.isRunning else { return }
        self.continuing = continuing
        if !continuing { silence?.cancel() }
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
                // A round that ends while awake keeps listening for the rest of the command.
                if done, mine == self.round {
                    if self.state == .awake { self.carried = self.pending; self.newRound(continuing: true) } else { self.newRound() }
                }
            }
        }
    }

    private func heard(_ text: String) {
        // Ignore our own voice reading a reply aloud.
        if Speaker.shared.speaking { return }
        let said: String
        if let c = Self.afterWake(text) { said = c }
        else if state == .awake || continuing {
            // After a pause the recognizer reports a new segment without the earlier words: keep what was said.
            if !continuing { carried = pending; continuing = true }
            said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[wake] continued: %@", said)
        } else { return }
        let command = [carried, said].filter { !$0.isEmpty }.joined(separator: " ")
        pending = command
        if state != .awake {
            NSLog("[wake] wake phrase heard: %@", text)
            state = .awake
            NSSound(named: "Tink")?.play()
        }
        // The command is done once the words stop changing for a moment; with nothing said yet, wait longer.
        silence?.cancel()
        let wait: Duration = command.isEmpty ? .seconds(6) : .seconds(2)
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
        carried = ""
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
                if ok { self.awaiting[session.id] = Awaiting(since: Date(), before: session.lastAssistant) }
            }
        }
    }

    // MARK: answering by voice

    /// Sessions given a spoken command, waiting for their turn to end so the reply can be read aloud.
    private struct Awaiting { let since: Date; let before: String?; var sawBusy = false }
    private var awaiting: [String: Awaiting] = [:]

    /// Called after every refresh: a session asked by voice that has finished its turn gets its reply read
    /// aloud (summarized, in the F1 voice); one that stops on a question says so.
    func observe(_ sessions: [AgentSession]) {
        for (id, var a) in awaiting {
            guard let s = sessions.first(where: { $0.id == id }), Date().timeIntervalSince(a.since) < 3600 else {
                awaiting[id] = nil; continue
            }
            let name = store?.agentName(for: s) ?? "에이전트"
            switch s.status {
            case .busy:
                a.sawBusy = true
                awaiting[id] = a
            case .waiting:
                awaiting[id] = nil
                Speaker.shared.say("\(Self.subject(name)) 선택을 기다리고 있어요.")
            case .idle, .shell, .unknown:
                // Not started yet (the command may still be queued): wait for the turn to begin. A turn short
                // enough to fall between two refreshes shows up as a new reply instead.
                guard a.sawBusy || (s.lastAssistant != a.before && (s.updatedAt ?? .distantPast) > a.since) else { continue }
                awaiting[id] = nil
                let path = s.transcriptPath, agent = s.agent, characterId = store?.character(for: s)?.id
                Task.detached {
                    let reply = path.flatMap { TranscriptRenderer.items(path: $0, agent: agent).last { $0.role == .agent }?.text }
                    await MainActor.run {
                        if let reply { Speaker.shared.speak(reply, characterId: characterId) }
                        else { Speaker.shared.say("\(Self.subject(name)) 작업을 마쳤어요.") }
                    }
                }
            }
        }
    }

    /// "펠릭스가" / "린이": the subject particle that fits the name's last syllable.
    nonisolated static func subject(_ name: String) -> String {
        guard let v = name.unicodeScalars.last?.value, (0xAC00...0xD7A3).contains(v) else { return name + "가" }
        return name + ((v - 0xAC00) % 28 == 0 ? "가" : "이")
    }

    // MARK: parsing (pure, so it can be checked without a microphone)

    nonisolated private static let wake = try! NSRegularExpression(pattern: #"안녕\s*[,.!?]?\s*수\s*혁\s*(아|이|야)?[\s,.!?]*"#)

    /// The words after the last wake phrase, or nil if the phrase was not said.
    nonisolated static func afterWake(_ text: String) -> String? {
        let ns = text as NSString
        guard let m = wake.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds the agent named near the start of a command ("펠릭스야, 커밋해 줘", "지금 하루한테 …") and returns
    /// it with the instruction left once the name is taken out. Names are compared by sound, not spelling,
    /// and allow small mistakes: recognition writes "펠릭스" as "필릭스", "필립스" or "필리 스", and "아린아"
    /// as "아리 나" (the final ㄴ moves to the next syllable). Longer names get more slack; 2-syllable names
    /// must sound exact so ordinary words are not taken for names.
    nonisolated static func route(_ command: String, names: [String]) -> (name: String, text: String)? {
        let c = Array(command.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
        let wordStarts = c.indices.filter { !c[$0].isWhitespace && ($0 == 0 || c[$0 - 1].isWhitespace) }
        typealias Hit = (name: String, distance: Int, word: Int, start: Int, end: Int, midSyllable: Bool)
        var best: Hit?
        for (w, start) in wordStarts.prefix(4).enumerated() {
            var sounds: [(sound: Swift.Character, at: Int)] = []
            for i in start..<c.count where !c[i].isWhitespace && !c[i].isPunctuation { sounds += Self.sounds(c[i]).map { ($0, i) } }
            for name in names {
                let n = name.flatMap(Self.sounds)
                let slack = n.count >= 7 ? 2 : n.count >= 5 ? 1 : 0
                guard !n.isEmpty, n.count - slack <= sounds.count else { continue }
                for len in max(1, n.count - slack)...min(sounds.count, n.count + slack) {
                    let d = Self.distance(n, sounds.prefix(len).map(\.sound))
                    guard d <= slack else { continue }
                    let end = sounds[len - 1].at
                    let hit: Hit = (name, d, w, start, end, len < sounds.count && sounds[len].at == end)
                    // Closest sound first, then the earliest word, then the longer name ("아린" over "린").
                    if let b = best, (b.distance, b.word, -b.name.count) <= (d, w, -name.count) { continue }
                    best = hit
                }
            }
        }
        guard let best else { return nil }
        // The name ended inside a syllable ("아리 나"): the rest of it is the vocative 아/이, so skip it.
        var rest = Substring(String(c[(best.end + 1)...]))
        if !best.midSyllable {
            // Endings after the name: 펠릭스야 / 펠릭스한테 / 펠릭스에게 / 펠릭스님 …
            for ending in ["한테", "에게", "님", "씨", "야", "아", "이", "은", "는"] where rest.hasPrefix(ending) {
                let after = rest.dropFirst(ending.count)
                if after.isEmpty || after.first!.isWhitespace || after.first!.isPunctuation { rest = after; break }
            }
        }
        let before = String(c[..<best.start]).trimmingCharacters(in: .whitespaces)
        let after = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (best.name, [before, after].filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// Edit distance between two letter sequences.
    nonisolated static func distance(_ a: [Swift.Character], _ b: [Swift.Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var prev = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let cur = row[j + 1]
                row[j + 1] = min(row[j + 1] + 1, row[j] + 1, prev + (x == y ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
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
