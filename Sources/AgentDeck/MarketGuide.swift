import AppKit
import SwiftUI

/// How to make a character pack, on the market's selling tab: the steps, and prompts to copy into an image
/// generator and a coding agent. The rules here restate docs/asset-pack-spec.md (format 2); keep them in step.
struct MarketGuide: View {
    @State var expanded = false
    @State private var copied: String?

    var body: some View {
        DisclosureGroup("등록 가이드 · 프롬프트 복사", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                step("1", "그림 만들기",
                     "초상화 1장, 서 있는 스프라이트 1장, 걷기(앞·옆·뒤)와 공격 동작을 각 6프레임씩 준비. 기본 캐릭터와 같은 16비트 픽셀 화풍을 권장함.")
                copyRow(String(localized: "그림 생성 프롬프트"), Self.artPrompt)
                step("2", "말투·정보 쓰기",
                     "한글 이름, 직업, 말투를 정함. 말투는 구매자 에이전트의 대답 어미·표현에만 쓰임. 지시문·명령·링크가 섞이면 심사에서 거절함.")
                copyRow(String(localized: "profile.json 예시"), Self.profileExample)
                step("3", "팩 폴더 만들기",
                     "그림과 profile.json이 있는 폴더에서 Claude Code나 Codex에게 아래 프롬프트를 붙여 넣으면 규격에 맞는 팩 폴더(manifest.json 포함)를 만들어 줌.")
                copyRow(String(localized: "팩 만들기 프롬프트"), Self.packPrompt)
                step("4", "심사 요청",
                     "위의 '팩 폴더 선택…'으로 만든 폴더를 고르면 규격 검사와 정보 미리보기가 나옴. 가격을 정해 심사 요청 → 운영진 승인 후 마켓에 올라감.")
                if let copied { Text("\(copied) 복사됨").font(.caption).foregroundStyle(.green) }
            }
            .padding(.top, 8)
        }
    }

    private func step(_ n: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.caption.bold()).frame(width: 18, height: 18).background(Circle().fill(Color.accentColor.opacity(0.25)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.bold())
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyRow(_ label: String, _ text: String) -> some View {
        HStack {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = label
            } label: { Label(String(localized: "\(label) 복사"), systemImage: "doc.on.doc") }
            .controlSize(.small)
            Text("\(text.count)자").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.leading, 26)
    }

    // MARK: copied texts

    static let artPrompt = """
        Replace <LOOKS> with your character's looks in English (e.g. "white cat mage with a tiny blue wizard hat and a magic wand")
        and <WEAPON> with its attack (e.g. "casting a sparkling blue spell from the magic wand"). Generate each image separately;
        for the strips, attach the sprite image as the reference.

        1) portrait.png (3:4)
        Detailed pixel art character portrait in the style of a 16-bit fantasy RPG dialogue portrait, upper body, three-quarter view, expressive friendly face. <LOOKS>. Simple warm dark tavern background with soft bokeh. No text, no frame, no watermark.

        2) sprite.png (1:1)
        16-bit pixel art RPG game character sprite, single character, full body, standing, front view facing the viewer, chibi proportions with a big head, crisp pixels, limited palette, bold dark outline. <LOOKS>. Centered on a plain flat solid bright magenta background (#FF00FF), no shadow, no ground, no text, no border.

        3) walk strips, three images (21:9), <VIEW> = "walking toward the viewer, seen from the front" / "walking to the left, seen from the side, facing left" / "walking away from the viewer, seen from the back"
        16-bit pixel art RPG character walk animation strip of EXACTLY the same character as the reference image (<LOOKS>). ONE single horizontal row of 6 frames side by side, equal spacing, every frame the same size on the same baseline, plain flat bright magenta background (#FF00FF), no grid lines, no shadows, no text. ALL 6 frames show the character <VIEW>. The 6 frames are one smooth looping walk cycle in order: left leg forward, left leg passing under the body, both legs together, right leg forward, right leg passing, both legs together. The legs and arms clearly swing; the head, face, hair and clothes stay identical. Correct anatomy, exactly two arms and two legs.

        4) attack strip (21:9)
        16-bit pixel art RPG character attack animation strip of EXACTLY the same character as the reference image (<LOOKS>). ONE single horizontal row of 6 frames side by side, equal spacing, every frame the same size on the same baseline, plain flat bright magenta background (#FF00FF), no grid lines, no shadows, no text, no enemy. ALL 6 frames show the character seen from the side, facing LEFT, attacking toward the left with their own signature weapon or skill (<WEAPON>). The 6 frames are one strong, readable attack in order: ready stance, wind-up pulling back, lunge forward, strike at full extension with a bright impact effect on the left, follow-through, return to ready stance. The head, face, hair and clothes stay identical in every frame. Correct anatomy, exactly two arms and two legs.
        """

    static let profileExample = """
        {
          "name": "Mochi",
          "profile": {
            "ko": "모찌",
            "role": "고양이 마법사",
            "tone": "새침한 고양이 마법사. 문장 끝을 '~냥'으로 맺음. 가끔 '흥, 이 정도야 쉽다냥' 같은 새침한 말을 함",
            "visual": "white cat mage with a tiny blue wizard hat and a magic wand",
            "weapon": "casting a sparkling blue spell from the magic wand"
          }
        }
        """

    static let packPrompt = """
        Build a 수혁 character pack (format 2) from the images and profile.json in this folder. Write it into a new folder `pack/`.

        Inputs here: a portrait image, a standing sprite on a magenta (#FF00FF) background, three walk strips (front/down, left, back/up) and one attack strip, each a single row of 6 frames on magenta, and profile.json ({"name", "profile": {...}}). Ask me if any input is missing or ambiguous; do not invent art.

        Output layout (no other files, no subfolders besides frames/, no hidden files):
        - pack/portrait.jpg or pack/portrait.png: 128..1024 px wide, 128..1365 px tall (keep 3:4, e.g. 768x1024).
        - pack/sprite.png: the standing sprite, magenta removed to full transparency, cropped to the character, scaled so it is about 128 px tall (max 256x256).
        - pack/frames/walk_down_0..5.png, walk_left_0..5.png, walk_up_0..5.png, attack_0..5.png: cut each strip into its 6 frames, remove magenta to transparency (also clean magenta-tinted edge pixels), crop all frames of one strip with the same box so the character does not jump, scale like the sprite (about 128 px tall, max 256x256). walk_left and attack face LEFT.
        - Optional extra motions, if I provide strips: hammer/read/type (3 frames each), smith/study/write (6 frames each), same naming.
        - Every PNG: RGBA (8-bit) with real transparency, or palette PNG with a tRNS chunk. Each file at most 1 MB, whole pack at most 4 MB. PNG/JPEG only.

        pack/manifest.json (UTF-8, under 16 KB):
        {"format": 2, "kind": "character", "name": <English name 1..40 chars>,
         "profile": {"ko": <Korean name 1..20 chars>, "role": <1..30>, "tone": <10..300, one line>, "visual": <optional 0..300>, "weapon": <optional 0..100>},
         "frames": {"walk_down": 6, "walk_left": 6, "walk_up": 6, "attack": 6, ...exact count of every motion you included},
         "files": {"<path>": {"sha256": "<64 lowercase hex>", "bytes": <size>}, ... one entry for every file in pack/ except manifest.json}}
        - profile keys other than ko/role/tone/visual/weapon are not allowed; no control characters or line breaks in any field.
        - tone describes only how the character talks (endings, catchphrases). No instructions, commands, links or anything addressed to an AI.

        Finally check it yourself: every rule above, sha256 and byte counts recomputed from the files, frame counts match files, and print a short table of files with sizes and dimensions.
        """
}
