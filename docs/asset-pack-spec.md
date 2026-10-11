# 캐릭터 팩 규격 (format 1)

수혁 캐릭터 마켓에 올리는 캐릭터 한 명의 파일 묶음. 서버(`server/ledger/assets.js`)와 앱(`Sources/AgentDeck/AssetPack.swift`)이 같은 규칙으로 검사함. 두 구현은 `server/ledger/test/asset-vectors/`의 같은 샘플로 맞춤

## 파일 구성

| 경로 | 필수 | 형식 | 크기 |
|---|---|---|---|
| `manifest.json` | ✅ | JSON, 16KB 이하 | — |
| `portrait.jpg` 또는 `portrait.png` | ✅ (둘 중 하나) | JPEG 또는 PNG | 128~1024 × 128~1365 px |
| `sprite.png` | ✅ | PNG, 투명 배경 | 1~256 × 1~256 px |
| `frames/<동작>_<번호>.png` | 동작별 | PNG, 투명 배경 | 1~256 × 1~256 px |

- 다른 경로·하위 폴더·숨김 파일은 받지 않음
- 파일 하나 1MB 이하, 팩 전체 4MB 이하
- PNG 투명 배경 = RGBA(색 형식 6, 비트 깊이 8·16) 또는 팔레트(색 형식 3, 비트 깊이 1·2·4·8) + `tRNS` 청크
- SVG·GIF·WebP 등 다른 형식은 받지 않음 (확장자가 아니라 파일 내용으로 판정)

## 동작 프레임

번호는 0부터 시작. 동작을 넣으면 장수를 정확히 맞춰야 함

| 동작 | 필수 | 장수 | 쓰이는 곳 |
|---|---|---|---|
| `walk_down`, `walk_left`, `walk_up` | ✅ | 6 | 걷기 (오른쪽은 `walk_left`를 뒤집어 씀) |
| `attack` | ✅ | 6 | 사냥터 공격 |
| `hammer`, `read`, `type` | 선택 | 3 | 작업대 동작 |
| `smith`, `study`, `write` | 선택 | 6 | 작업대 동작 |

## manifest.json

```json
{
  "format": 1,
  "kind": "character",
  "name": "Sir Bolt",
  "frames": { "walk_down": 6, "walk_left": 6, "walk_up": 6, "attack": 6 },
  "files": {
    "portrait.jpg": { "sha256": "<64자리 소문자 hex>", "bytes": 136611 },
    "sprite.png": { "sha256": "…", "bytes": 9012 },
    "frames/walk_down_0.png": { "sha256": "…", "bytes": 4821 }
  }
}
```

- `kind`는 1차에서 `character`만 받음
- `name`: 1~40자, 제어 문자 금지
- `frames`는 실제 동작 파일과 정확히 일치해야 함
- `files`의 sha256·bytes는 실제 파일과 일치해야 함

## 오류 코드

| 코드 | 뜻 |
|---|---|
| `bad_manifest` | JSON이 아니거나 필드 형식이 틀림 |
| `bad_format_version` | `format`이 1이 아님 |
| `bad_kind` | `kind`가 `character`가 아님 |
| `bad_name` | 이름 길이·문자 위반 |
| `bad_path` | 허용되지 않은 경로 |
| `missing_file` | 필수 파일이나 manifest에 적힌 파일이 없음 |
| `frame_count` | 동작 장수가 규격과 다르거나 `frames`와 파일이 어긋남 |
| `hash_mismatch` | sha256 또는 bytes 불일치 |
| `too_large` | 파일·팩 크기 초과 |
| `bad_format` | 파일 내용이 PNG/JPEG가 아니거나 구조가 깨짐 |
| `bad_dimensions` | 해상도 범위 밖 |
| `no_transparency` | 프레임·스프라이트에 투명 정보가 없음 |
| `undecodable` | (앱만) 헤더는 맞지만 실제로 그릴 수 없음 |

## 만드는 법

- 기존 캐릭터는 `python3 art/pack.py <캐릭터 id> <출력 폴더>`로 팩을 만들 수 있음
- 새 캐릭터는 `art/gen.py`(이미지 생성) → `art/process.py`(배경 제거·128px 정리) 흐름으로 프레임을 만든 뒤 같은 도구로 묶음
