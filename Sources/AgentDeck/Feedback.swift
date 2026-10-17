import Foundation
import SwiftUI

/// Feedback to the 수혁 developers: each report becomes a public GitHub issue on oyhoyhk/suhyeok through a small
/// relay (server/feedback), so senders need no GitHub account. Three ways in: `/피드백 …` in the dialogue input,
/// the same command on the phone, and an agent skill ("이 내용 리포트해줘") installed from Settings.
enum Feedback {
    static let endpoint = URL(string: "https://suhyeok-feedback.pickuma.workers.dev")!
    static let skillName = "suhyeok-report"

    /// The report in a draft that starts with `/피드백` (or `/feedback`); nil for an ordinary instruction.
    static func command(_ draft: String) -> String? {
        for prefix in ["/피드백", "/feedback"] where draft.hasPrefix(prefix) {
            let rest = draft.dropFirst(prefix.count)
            guard rest.isEmpty || rest.first!.isWhitespace else { return nil }
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Sends the report; returns the new issue's address.
    static func send(_ text: String, agent: Agent?) async throws -> URL {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var body: [String: String] = ["text": text, "source": "mac",
                                      "os": "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"]
        body["version"] = version
        body["agent"] = agent?.rawValue
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let url = (reply?["url"] as? String).flatMap(URL.init(string:)) { return url }
        throw NSError(domain: "Feedback", code: 1, userInfo: [NSLocalizedDescriptionKey: reply?["error"] as? String ?? String(localized: "보내지 못함")])
    }

    /// Skill folders per agent; Codex only when it is installed.
    static var skillDirs: [(Agent, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [(Agent.claude, home.appendingPathComponent(".claude/skills/\(skillName)"))]
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) {
            dirs.append((.codex, home.appendingPathComponent(".codex/skills/\(skillName)")))
        }
        return dirs
    }

    static var skillInstalled: Bool {
        skillDirs.allSatisfy { FileManager.default.fileExists(atPath: $0.1.appendingPathComponent("SKILL.md").path) }
    }

    static func installSkill() throws {
        for (agent, dir) in skillDirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try skill(agent: agent).write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
    }

    private static func skill(agent: Agent) -> String {
        """
        ---
        name: \(skillName)
        description: Send feedback or a bug report about the 수혁 (Suhyeok) app to its developers as a GitHub issue. Use when the user asks to report something about 수혁, e.g. "이 내용 리포트해줘", "수혁에 피드백 보내줘", "report this to 수혁".
        ---

        # Report to 수혁

        1. Write the report in Korean from this conversation, about 수혁 only: what the user tried, what happened,
           what they expected, and steps to reproduce if known. Keep it short.
        2. Before sending, remove secrets, tokens, emails and people's names, write home paths as `~`, and leave out
           the user's own project code and long logs.
        3. Show the final text to the user and say it will be posted publicly on GitHub. Send only after they agree.
        4. Save the text to a temporary file and send it:

           ```bash
           python3 -c 'import json,sys,urllib.request as u;r=u.urlopen(u.Request("\(endpoint.absoluteString)",json.dumps({"text":open(sys.argv[1]).read(),"source":"agent","agent":"\(agent.rawValue)"}).encode(),{"content-type":"application/json"}));print(json.load(r)["url"])' <file>
           ```

        5. Tell the user the issue link it prints. On an error, show the message; do not retry more than once.
        """
    }
}

struct FeedbackSettings: View {
    @State private var installed = Feedback.skillInstalled
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("피드백").font(.headline)
            Text("대화창이나 폰 입력칸에 `/피드백 내용`을 보내면 에이전트 대신 수혁 개발진에게 전달됨. GitHub 이슈로 공개 등록됨.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(installed ? "에이전트 스킬 다시 설치" : "에이전트 스킬 설치") {
                    do { try Feedback.installSkill(); installed = true; result = String(localized: "설치됨 — 새로 연 세션부터 적용") }
                    catch { result = String(localized: "설치 실패: \(error.localizedDescription)") }
                }
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            }
            Text("설치하면 세션 안에서 \"이 내용 수혁에 리포트해줘\"라고 말해 에이전트가 정리해서 보냄. 보내기 전에 내용을 보여주고 확인받음.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
