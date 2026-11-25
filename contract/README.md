# 수혁 서버 계약

모든 수혁 서버(맥 Swift `MobileServer`, 윈도우·리눅스 Rust `server-rs`)가 지키는 HTTP 계약. 화면(`/desk`, 폰 페이지, 안드로이드 앱)은 이 계약만 보고 동작함.

- 기준 구현: `Sources/AgentDeck/MobileServer.swift`, `DesktopAPI.swift` (2026-11-17)
- 검사: `node contract/check.mjs` (아래 "검사" 참고)

## 공통 규칙

| 규칙 | 내용 |
|---|---|
| 주소 | 기본 `127.0.0.1:4380`. 외부 접근은 터널 또는 사용자가 켠 LAN 주소 |
| Host 검사 | `127.0.0.1:<포트>`, `localhost:<포트>`, 현재 터널 호스트만 허용. 그 외 `421 {"error":"host"}` (DNS 리바인딩 차단) |
| 출처 검사 | POST는 `Content-Type: application/json`(업로드는 `application/octet-stream`)만. `Sec-Fetch-Site`가 있으면 `same-origin`/`none`만, `Origin` 호스트는 `Host`와 같아야 함. 어기면 `403 {"error":"origin"}` |
| 인증 | 쿠키 `sh=<토큰>`. 서버는 토큰의 SHA-256만 보관. 없거나 틀리면 `401 {"error":"pair"}` |
| 토큰 만료 | 마지막 사용 후 7일 또는 발급 후 30일 |
| 크기 제한 | 헤더 16KB, 본문 64KB, 업로드 25MB(페어링된 기기만), chunked 거부 |
| 연결 | 동시 32개, 15초 무응답 끊김(업로드 300초, 파일 전송은 진행 중이면 유지) |
| 공통 응답 헤더 | `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, CSP `default-src 'self'` (아래 `/api/file`은 `sandbox`) |
| 모르는 경로 | 인증 후 `404 {"error":"not found"}` |

## 페어링 (인증 없음)

| 단계 | 요청 | 응답 |
|---|---|---|
| 0 | 서버 소유자가 "연결 시작" → 60초짜리 128비트 비밀값(32자 16진수) 생성, 링크 `…/desk#pair=<비밀값>` | |
| 1 | `POST /pair {"secret": "<32hex>"}` | `200 {"pending":"<id>"}`. 비밀값은 한 번 쓰면 사라짐. 틀리면 `403 {"error":"…"}`, 같은 출처에서 10분에 5번 틀리면 `429` |
| 2 | 서버 소유자가 허용/거부 (서버 화면의 확인 창) | |
| 3 | `GET /pair/status?id=<id>` 반복 | 대기 `{"waiting":true}` · 허용 `{"ok":true}` + `Set-Cookie: sh=<64hex>; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Strict` · 거부 `403` · 2분 초과 `410` · 모름 `404` |

## 경로

### 인증 없음

| 경로 | 응답 |
|---|---|
| `GET /`, `/index.html` | 폰 페이지 HTML |
| `GET /desk` | 데스크톱 페이지 HTML = `web/desk.html`의 `{{LANG}}`을 `ko`/`en`으로 바꾼 것 |
| `GET /art/<경로>` | 앱에 포함된 공개 아트(png·jpg·woff2), `Cache-Control: max-age=86400`. `..` 금지 |

### 인증 필요 — 읽기

| 경로 | 응답 필드 |
|---|---|
| `GET /art/<이름>` (번들에 없을 때) | 마켓에서 산 캐릭터 이미지 |
| `GET /api/state` | `agents[]`, `bosses[]`, `crystals`(정수), `world{w,h}`, `avatar`(숫자), `prompts[]` |
| `GET /api/chat?id=<세션>[&screen=1]` | `items[]{role,text,files?}`, `status`, `activity`, `activityCode`, `action`, 선택: `usage`, `screen`, `menu[]{label,detail,free}`, `menuQuestion`, `menuContext`, `live`. 세션 없으면 `404 {"error":"gone"}` |
| `GET /api/events?after=<seq>&boot=<boot>` | `boot`, `seq`, `events[]{seq,id,name,title,kind,text,at}`. `kind`: `asking`(선택 필요), `done`(작업 완료), `cleared`(그 에이전트 알림이 다른 곳에서 처리됨: 답함·새 지시·세션 종료, Mac은 작업 완료를 Mac 앱에서 열어 봄도 포함 → 알림 내림). `boot`가 다르면 빈 목록(서버 재시작) |
| `GET /api/sidebar?sort=<키>&asc=0/1` | `hosted[]`, `shells[]`, `external[]` (각 `{folder, items[]}`), `recent[]{id,agent,title,folder,updated}`, `sorts[]{key,label}`, `sort`, `ascending`, `panel` |
| `GET /api/terminals` | `terminals[]` |
| `GET /api/term?name=<터미널>&history=<줄>` | 터미널 화면. 없으면 `404 {"error":"gone"}` |
| `GET /api/folders` | `home`, `folders[]` |
| `GET /api/files[?dir=<폴더>]` | 폴더 없음: `home`, `folders[]`. 폴더: 항목 목록. 없으면 `404` |
| `GET /api/file?path=<파일>` | 파일 바이트, `Range` 지원(206/416), CSP `sandbox` |
| `GET /app/android.json`, `/app/android.apk` | 안드로이드 앱 갱신 파일. 없으면 `404 {"error":"none"}` |

`agents[]` 항목:

| 필드 | 형식 | 비고 |
|---|---|---|
| `id` `name` `title` `project` `cwd` `agent` `status` `activity` `activityCode` `character` `hunt` `action` | 문자열 | `activityCode` = `working`/`waiting`/`resting` 계열, `agent` = `Claude`/`Codex`/… |
| `x` `y` `last` `started` `updated` | 숫자 | 월드 좌표, 유닉스 시각 |
| `tier` | 문자열 또는 null | 사냥터 키 |
| `canSend` `hosted` `canClone` `canFork` `estimated` | 불리언 | |
| `color` | 정수 0–9 | 프로젝트 색 팔레트 번호(FNV-1a, `DesktopAPI.colorIndex`) |
| `charName` `lastUser` `lastAssistant` `parent` `actionSymbol` | 문자열 | |
| `term` | 문자열(선택) | 수혁이 띄운 세션의 터미널 이름 |
| `working` | 선택 | 지금 쓰는 도구 정보 |

### 인증 필요 — 동작 (모두 POST, JSON 본문)

| 경로 | 본문 | 응답 |
|---|---|---|
| `/api/send` | `{id, text}` | `{ok}`. 같은 세션·같은 글이 5초 안에 다시 오면 다시 입력하지 않고 `ok:true` |
| `/api/upload?name=<파일명>` | 파일 바이트(`application/octet-stream`) | `{ok, path}` |
| `/api/term-input` | `{name, text}` 또는 `{name, key}` | `{ok}` |
| `/api/term-new` | `{}` | `{ok, name}` |
| `/api/resume` | `{id}` (최근 대화) | `{ok}` |
| `/api/new` | `{agent, cwd, prompt?}` | `{ok, message?}` |
| `/api/action` | `{id, action: clone/rename/clear/migrate/end, text?}` | `{ok, message?}` |
| `/api/choose` | `{id, index, text?}` (권한 메뉴 선택, 자유 입력 줄은 `text`) | `{ok}` |
| `/api/choose-hosted` | `{name, index}` (세션 ID가 생기기 전 메뉴) | `{ok}` |
| `/api/key` | `{id, key}` (tmux 키 이름, 대소문자 무시) | `{ok}` |

## 주인 경로 (Rust 서버, 같은 컴퓨터 전용)

윈도우·리눅스에서는 서버(`suhyeok-server`)와 창(데스크톱 앱)이 따로 돈다. 맥 앱이 직접 하는 일을 데스크톱 앱이 주인 토큰으로 대신한다.

| 항목 | 내용 |
|---|---|
| 주인 토큰 | `<데이터 폴더>/owner-token` (64자 16진수, 유닉스 0600). 서버가 처음 뜰 때 만들고 그대로 유지 |
| 조건 | Host가 `127.0.0.1:<포트>`/`localhost:<포트>`일 때만. 그 외 421 또는 403 |
| 주인 증명 | `X-Suhyeok-Owner: <토큰>` 헤더, 또는 주인 기기 쿠키 |

| 경로 | 내용 |
|---|---|
| `GET /owner#<토큰>` | 주인 창 열기: 같은 출처로 `/pair/owner`를 부른 뒤 `/desk`로 이동 (토큰은 URL 조각이라 서버로 가지 않음) |
| `POST /pair/owner {token}` | 주인 기기 쿠키 발급(페어링 요청 없이). 틀리면 403 |
| `GET /api/owner/info` | `{server:"suhyeok-server", version, pid, dataDir, artDir}` |
| `GET /api/owner/pending` | 허용을 기다리는 요청 `[{id, device, client, created}]` |
| `POST /api/owner/decide {id, allow}` | 허용/거부 |
| `POST /api/owner/pair-start` | 60초 비밀값과 접속 주소별 링크 `{secret, expires, links[]}` |
| `GET /api/owner/devices` · `POST /api/owner/forget {hash}` | 기기 목록, 끊기 |
| `POST /api/owner/shutdown` | 모든 터미널을 끝내고 서버 종료. 열린 대화는 다음 실행 때 다시 열림 |
| `GET /api/owner/network` | `{lan:{on, port, error, names}, tunnel:{on, url, error}, addresses[]}` |
| `POST /api/owner/network {lan?, tunnel?, names?}` | LAN 열기/닫기, Cloudflare 터널 켜기/끄기, LAN에서 받을 이름(Tailscale MagicDNS 등). `<데이터 폴더>/network.json`에 저장, 시작 때 적용 |

## 다른 컴퓨터에서 접속 (Rust 서버)

| 경로 | 내용 |
|---|---|
| 이 컴퓨터 | `http://127.0.0.1:<포트>` (기본 4380). 항상 열림 |
| LAN·Tailscale | 주인이 켜면 `http://<IP>:<포트+1>`. Host는 IP 숫자 주소이거나 주인이 등록한 이름만 허용(그 외 421). 주인 경로는 거부 |
| Cloudflare 터널 | 주인이 켜면 `cloudflared` 빠른 터널(`<데이터 폴더>/named-tunnel.yml`이 있으면 고정 주소). 터널 주소는 허용 호스트에 들어감 |
| 쿠키 | 이 컴퓨터·터널(https)은 `Secure`, LAN(http)은 `Secure` 없이. LAN은 Tailscale처럼 암호화된 망에서만 권장 |

## 검사

```bash
# 서버 하나(기본 127.0.0.1:4380)를 페어링한 뒤 읽기·보안 계약을 검사함. 동작 API는 호출하지 않음.
node contract/check.mjs --base http://127.0.0.1:4392 --secret <32hex> --approve 'echo allow > /path/to/fifo'
```

- `--secret`: 서버가 낸 페어링 비밀값 (맥 시험 서버: `AgentDeck --serve-mobile <초>`가 `secret …`으로 출력)
- `--approve`: 페어링 요청 뒤 허용을 대신하는 셸 명령 (맥 시험 서버는 표준 입력 `allow`)
- 결과: 항목별 PASS/FAIL, 하나라도 실패하면 종료 코드 1
