# TicketDiary LLM 서버 스켈레톤

백엔드팀이 라우팅/인증/재시도 구조를 전부 만들어둔 FastAPI 스켈레톤입니다.
**`inference.py`의 함수 3개만 채우면 됩니다.** 나머지 파일은 손댈 필요 없습니다.

## 할 일은 딱 하나

`inference.py`를 열어서 아래 세 함수의 본문을 노트북에서 만든 실제 추론 로직으로
채워주세요.

- `analyze_crawl_screenshot(item)` — 크롤링 스크린샷 분석 (타임테이블/가격/좌석배치도/티켓팅일/배송일/아티스트명)
- `extract_artists_from_poster(item)` — 포스터에서 아티스트명 추출
- `generate_diary_text(item)` — 한줄평 기반 공연 일기 생성

각 함수가 받는 `item`에 어떤 필드가 들어있는지는 `schemas.py`의
`CrawlAnalyzeItem` / `ArtistExtractItem` / `DiaryGenerateItem`을 보면 됩니다.
반환값은 `inference.py` 안의 예시 주석을 참고하세요 — **일부 필드만 뽑아냈어도
됩니다.** 형식이 예시와 완전히 똑같지 않아도 괜찮습니다(백엔드 쪽 `normalize.py`가
다듬어줍니다). 정말 아무것도 못 뽑아냈으면 빈 값(빈 리스트/빈 문자열)을 반환하면
되고, 예외를 던져도 안전하게 로그만 남고 다음날 재시도됩니다.

## 신경 쓰지 않아도 되는 것들 (이미 구현됨)

- **인증**: 백엔드가 보내는 요청의 API 키 검증, 백엔드로 콜백 보낼 때 같은 키를
  실어 보내는 것 전부 자동 처리됩니다.
- **즉시 응답(ACK)**: 요청이 들어오면 실제 처리를 기다리지 않고 바로 202를
  반환합니다. 추론은 백그라운드에서 순서대로 처리됩니다. (건당 처리에 몇 분씩
  걸려도, 이 서버가 30초 안에 202를 못 주는 일은 없습니다.)
- **결과 전송(콜백)**: 추론이 끝나면 알아서 백엔드 웹훅으로 결과를 보냅니다.
- **중복 처리 방지**: 이미 콜백까지 성공한 항목은 로컬 SQLite 장부에 기록해두고,
  같은 항목이 또 오면 재추론 없이 스킵합니다. (처리 중 끊긴 항목은 장부에
  기록이 없어서 다음날 정상적으로 재시도됩니다 — 별도 신경 쓸 필요 없음.)

## 실행 방법

```bash
pip install -r requirements.txt
cp .env.example .env
# .env 열어서 LLM_EXTRACT_API_KEY, BACKEND_BASE_URL 채우기
uvicorn main:app --host 0.0.0.0 --port 8000
```

이 프로세스 하나만 떠있으면 됩니다 (별도 중계 서버 없음 — 모델 추론과 웹서버가
같은 프로세스).

## 도메인/네트워크 (인프라 담당이 처리)

이 서버가 외부에서 `https://llm.ticket-diary.com`으로 접근 가능해야 백엔드가
요청을 보낼 수 있습니다. Cloudflare Tunnel(`cloudflared`)로 연결하면 인스턴스의
실제 IP를 몰라도(또는 껐다 켜서 바뀌어도) 자동으로 재연결됩니다 — runpod이든
나중에 다른 클라우드로 바뀌든 이 부분 코드는 그대로 두고 그 인스턴스에서
`cloudflared` 데몬만 다시 띄우면 됩니다. 자세한 설정은 인프라 담당(백엔드팀)이
진행합니다.

## 로컬에서 먼저 테스트해보고 싶다면

`inference.py` 채우기 전에 라우팅/인증만 먼저 확인하고 싶으면:

```bash
curl -X POST http://localhost:8000/crawl-analyze \
  -H "Authorization: Bearer <LLM_EXTRACT_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '[{"concert_id": "test-1", "concert_name": "테스트 공연", "screenshot_url": "https://example.com/a.png"}]'
```

`inference.py`가 아직 `NotImplementedError`를 던지는 상태여도 202는 정상적으로
바로 오고, 실패 로그만 서버 콘솔에 남습니다 (백그라운드 처리라 요청 자체는 실패로
안 잡힘).
