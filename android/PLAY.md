# Google Play 배포

`./play-release.sh` 한 줄로 업로드. 단 첫 등록과 권한 설정은 콘솔에서 사람이 1회 처리함

## 빌드 구성

| 빌드 | 용도 | 업데이트 경로 |
|---|---|---|
| `direct` | 기존 방식 (`publish.sh`) | 맥이 APK 제공, 앱이 직접 설치 |
| `play` | Google Play | Play 스토어만 |

- Play 빌드는 자체 업데이트 코드·`REQUEST_INSTALL_PACKAGES` 권한 제외 — Play 정책상 스스로 업데이트하는 앱 금지
- 두 빌드는 서명 키가 달라 서로 덮어 설치 불가 — direct에서 Play로 옮기려면 지우고 다시 설치

## 열쇠 (저장소 밖)

| 무엇 | 위치 |
|---|---|
| 업로드 키 | `~/keys/suhyeok-upload.keystore` (PKCS12, alias `suhyeok`, 30년) |
| 키 비밀번호 | `~/keys/suhyeok-release.properties` (chmod 600) |
| 서비스 계정 키 | `~/keys/suhyeok-play.json` (아래 3단계에서 받음) |

- ⚠️ 업로드 키·비밀번호는 암호관리자에 백업. Play 앱 서명을 켠 뒤에는 분실 시 Google에 업로드 키 재설정 요청 가능

## 1회 설정 (콘솔, 사람이 직접)

### 1. 앱 만들기 — https://play.google.com/console

- 앱 만들기 → 이름 `수혁`, 기본 언어 한국어, 앱, 무료
- API는 새 앱을 만들 수 없음 — 이 단계만 콘솔에서 처리

### 2. 첫 빌드 수동 업로드

- `./play-release.sh --bundle` → `app/build/outputs/bundle/playRelease/app-play-release.aab`
- 테스트 및 출시 → 내부 테스트 → 새 버전 만들기 → AAB 업로드
- 이때 Play 앱 서명 사용 동의 (기본값)
- 첫 버전은 콘솔로 올려야 API 업로드가 열림

### 3. 서비스 계정 만들기 — https://console.cloud.google.com

1. 프로젝트 선택(또는 새로 만들기) → API 및 서비스 → **Google Play Android Developer API** 사용 설정
2. IAM 및 관리자 → 서비스 계정 → 만들기 (이름 예: `suhyeok-play`), 역할 부여 없이 완료
3. 그 계정 → 키 → 키 추가 → JSON → 받은 파일을 `~/keys/suhyeok-play.json`으로 저장 후 `chmod 600`

### 4. 서비스 계정을 콘솔에 초대

- Play Console → 사용자 및 권한 → 새 사용자 초대 → 서비스 계정 이메일(`…@….iam.gserviceaccount.com`)
- 앱 권한: `수혁`만 선택 → **출시 관리**(테스트 트랙·프로덕션 출시) 권한
- 반영까지 수 분~최대 하루 소요 가능

## 이후 배포

```bash
./play-release.sh             # 내부 테스트
./play-release.sh alpha       # 비공개 테스트
./play-release.sh production  # 프로덕션
```

- versionCode = 2026-01-01부터 지난 분 수 → 항상 증가, 수동 관리 불필요

## 프로덕션 전 남은 관문

| 항목 | 내용 |
|---|---|
| 비공개 테스트 12명 × 14일 | 2023-11 이후 개인 계정 필수 조건 |
| 앱 액세스 (심사용) | 맥 앱과 QR 페어링해야 동작 → 심사자가 쓸 방법 필요. 데모 모드 또는 영상·설명 제출 검토 |
| 포그라운드 서비스 선언 | 알림 서비스 = `dataSync`. 콘솔에서 용도 설명·영상 요구 가능. Android 15+는 하루 6시간 제한 (초과 시 서비스 중지, 앱 열면 재시작) |
| 카메라 권한 | QR 페어링 용도로 데이터 안전 항목에 기재 |
| 개인정보처리방침 URL | 필수. 수집 항목 없음이어도 페이지 필요 |

## 콘솔 입력 답안 (앱 설정)

| 항목 | 답 |
|---|---|
| 개인정보처리방침 | `https://suhyeok-feedback.pickuma.workers.dev/privacy` (server/feedback/worker.js) |
| 앱 액세스 | 일부 기능 제한 → 안내: "첫 화면 'Mac 없이 둘러보기 (체험 모드)'를 누르면 로그인 없이 모든 화면 확인 가능. 실제 사용은 Mac용 수혁 앱의 QR 페어링 필요" |
| 광고 | 광고 없음 |
| 콘텐츠 등급 | 카테고리 '기타 앱 유형' → 폭력·성·약물·도박·사용자 간 소통 모두 '아니요' |
| 타겟층 | 18세 이상 |
| 뉴스 앱 / 정부 앱 / 금융 기능 / 건강 | 아니요 |
| 포그라운드 서비스 | 데이터 동기화(dataSync): "사용자가 켠 경우에만, 사용자 Mac의 에이전트 세션 상태 변화를 받아 알림 표시. 앱을 닫아도 작업 완료·선택 필요를 알려야 해서 필요" |

### 데이터 보안
- 데이터 수집: **예** (피드백만)
- 수집 항목: 앱 활동 → **기타 사용자 생성 콘텐츠** (`/피드백` 내용), 앱 정보 및 성능 → **기타** (앱·OS 버전)
  - 선택 사항, 사용자가 보낼 때만 / 목적: 앱 기능, 개발자 소통 / 공유 안 함 / 전송 중 암호화(HTTPS) / 삭제 요청: GitHub 이슈로
- 카메라·연결 토큰·세션 내용: 기기 안 처리 또는 사용자 본인 Mac으로만 전송 → 수집 아님

## 스토어 등록정보 (파일로 관리)

- `app/src/main/play/listings/ko-KR/` — 제목·설명·아이콘·그래픽 이미지·스크린샷 3장 (체험 모드 화면)
- `./gradlew publishPlayListing`으로 업로드 — 서비스 계정에 '스토어 등록정보 관리' 권한 필요
- 출시 노트: `app/src/main/play/release-notes/ko-KR/default.txt`
