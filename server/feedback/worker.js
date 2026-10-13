// Feedback relay (suhyeok-feedback.pickuma.workers.dev): turns a report from the app, the phone or an agent skill
// into a GitHub issue on oyhoyhk/suhyeok, so senders need no GitHub account. Stores nothing itself.
// Env: GITHUB_TOKEN (secret; fine-grained, Issues: write on oyhoyhk/suhyeok only), LIMIT (rate limit binding).

const REPO = 'oyhoyhk/suhyeok';
const MAX_TEXT = 4000;
const SOURCES = { mac: '맥 앱', phone: '폰 앱', agent: '에이전트 스킬' };

const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'access-control-allow-origin': '*' },
});

/** Issue title and body from a validated report. Exported for tests. */
export function issueFrom({ text, source, version, os, agent }) {
  const first = text.split('\n').find((l) => l.trim()) ?? '';
  const title = '[피드백] ' + (first.length > 70 ? first.slice(0, 70) + '…' : first.trim());
  const meta = [
    `- 보낸 곳: ${SOURCES[source]}`,
    version && `- 수혁 버전: ${version}`,
    os && `- OS: ${os}`,
    agent && `- 에이전트: ${agent}`,
  ].filter(Boolean).join('\n');
  return { title, body: `${text}\n\n---\n${meta}` };
}

/** The report in a request body, or an error message. Exported for tests. */
export function parseReport(raw) {
  const r = raw && typeof raw === 'object' ? raw : {};
  const text = typeof r.text === 'string' ? r.text.trim() : '';
  if (!text) return { error: '내용이 비어 있음' };
  if (text.length > MAX_TEXT) return { error: `${MAX_TEXT}자 이하로 줄여 주세요` };
  if (!(r.source in SOURCES)) return { error: 'source는 mac, phone, agent 중 하나' };
  // Short free-form context only; anything long or odd is dropped rather than echoed into a public issue.
  const short = (v) => (typeof v === 'string' && v.length <= 60 ? v.replace(/[\r\n]/g, ' ') : undefined);
  return { report: { text, source: r.source, version: short(r.version), os: short(r.os), agent: short(r.agent) } };
}

// Privacy policy for the phone app (linked from its Google Play listing) and the Mac app.
const PRIVACY = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>수혁 개인정보처리방침</title><style>body{font:16px/1.7 -apple-system,sans-serif;max-width:720px;margin:0 auto;padding:24px 16px;color:#222}
h1{font-size:24px}h2{font-size:18px;margin-top:28px}</style></head><body>
<h1>수혁 개인정보처리방침</h1>
<p>시행일: 2026년 10월 13일 · 운영: Pickuma (오윤환)</p>
<p>수혁은 Mac에서 AI 코딩 에이전트 세션을 보여 주는 Mac 앱과, 그 Mac 앱에 연결하는 폰 앱(com.pickuma.suhyeok)입니다. 회원 가입이나 계정이 없고, 기본 설정에서는 개발자 서버로 보내는 정보가 없습니다. 개발자에게 정보가 전달되는 경우는 아래 2항(피드백)과 3항(Mac 앱의 크리스탈 정산·마켓, 사용자가 켤 때만)뿐입니다.</p>
<h2>1. 앱이 다루는 정보</h2>
<ul>
<li><b>Mac 연결 정보</b>: 사용자 Mac의 주소와 연결 토큰. 폰 안에 암호화해 저장하며 개발자에게 전송하지 않습니다.</li>
<li><b>세션 내용</b>: 에이전트 대화와 상태. 사용자 Mac에서 폰으로 직접 전달되며(사용자 Mac이 만든 Cloudflare 터널 경유) 개발자 서버를 거치거나 저장되지 않습니다.</li>
<li><b>카메라</b>: Mac 화면의 연결 QR 코드를 읽는 데만 쓰며, 영상은 폰 안에서만 처리하고 저장·전송하지 않습니다.</li>
<li><b>음성 입력·읽어 주기</b>: 기기의 음성 인식·음성 합성 기능을 사용자가 누를 때만 사용합니다. 처리 방식은 해당 기기 서비스의 정책을 따릅니다.</li>
<li><b>알림</b>: 백그라운드 알림을 켜면 Mac의 세션 상태 변화를 받아 폰 알림으로 보여 줍니다.</li>
</ul>
<h2>2. 피드백</h2>
<p>사용자가 <code>/피드백</code> 명령이나 Mac 앱의 리포트 스킬로 직접 보낸 내용과 앱 버전·OS 버전(Mac 앱은 에이전트 종류 포함)은 GitHub 공개 이슈(github.com/oyhoyhk/suhyeok)로 등록되어 누구나 볼 수 있습니다. 전달 서버(Cloudflare Workers)는 남용 방지를 위해 IP 주소로 전송 횟수만 제한하며 내용을 따로 저장하지 않습니다. 등록된 피드백의 삭제는 아래 문의처로 요청할 수 있습니다. 리포트 스킬은 에이전트가 쓴 글을 그대로 보내므로, 보내기 전에 코드나 회사 정보가 들어 있지 않은지 확인해 주세요.</p>
<h2>3. Mac 앱의 크리스탈 정산·마켓 (선택)</h2>
<p>설정에서 정산을 켜고 등록 코드를 넣은 경우에만 동작하며, 기본값은 꺼짐입니다.</p>
<ul>
<li><b>정산</b>: 이 Mac의 장부 공개키와 장부 기록(시각, 종류, 수량, 대화 파일 이름)을 개발자 서버(suhyeok.pickuma.com)로 보냅니다. 대화 파일 이름은 세션 ID이며 대화 내용은 보내지 않습니다. 서버는 기기 ID, 수량, 기록의 해시만 저장합니다.</li>
<li><b>마켓</b>: 사용자가 올린 캐릭터 팩 파일과 이름·설명·판매자 별칭, 구매 기록을 서버에 저장합니다.</li>
<li>2026년 10월 13일 이전 버전은 정산 기록에 대화 파일의 전체 경로(Mac 사용자 이름과 프로젝트 폴더 이름 포함)를 담아 보냈습니다. 서버는 이 경로를 저장하지 않았습니다.</li>
<li>정산과 마켓 기록의 삭제는 아래 문의처로 요청할 수 있습니다.</li>
</ul>
<h2>4. 제3자 제공·광고</h2>
<p>광고, 분석 도구, 추적 기능이 없으며 개인정보를 판매하거나 제3자에게 제공하지 않습니다.</p>
<h2>5. 보관과 삭제</h2>
<p>앱이 폰에 저장한 연결 정보는 앱 메뉴의 '연결 끊기' 또는 앱 삭제로 지워집니다.</p>
<h2>6. 문의</h2>
<p>github.com/oyhoyhk/suhyeok/issues 에 남겨 주세요.</p>
<h2>7. 변경</h2>
<p>이 방침이 바뀌면 이 페이지에 시행일과 함께 게시합니다.</p>
</body></html>`;

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'POST',
        'access-control-allow-headers': 'content-type' } });
    }
    if (request.method === 'GET' && new URL(request.url).pathname === '/privacy') {
      return new Response(PRIVACY, { headers: { 'content-type': 'text/html; charset=utf-8' } });
    }
    if (request.method !== 'POST') return json({ error: 'POST로 보내 주세요' }, 405);
    const ip = request.headers.get('cf-connecting-ip') ?? 'unknown';
    if (env.LIMIT && !(await env.LIMIT.limit({ key: ip })).success) return json({ error: '잠시 후 다시 보내 주세요' }, 429);

    const { report, error } = parseReport(await request.json().catch(() => null));
    if (error) return json({ error }, 400);

    const res = await fetch(`https://api.github.com/repos/${REPO}/issues`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${env.GITHUB_TOKEN}`, accept: 'application/vnd.github+json',
        'user-agent': 'suhyeok-feedback', 'content-type': 'application/json',
      },
      body: JSON.stringify({ ...issueFrom(report), labels: ['feedback'] }),
    });
    if (!res.ok) {
      console.log('github', res.status, await res.text());
      return json({ error: '이슈를 만들지 못함' }, 502);
    }
    const issue = await res.json();
    return json({ url: issue.html_url, number: issue.number });
  },
};
