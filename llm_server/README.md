# TicketDiary LLM 서버 스켈레톤

백엔드팀이 라우팅/인증/재시도 구조를 전부 만들어둔 FastAPI 스켈레톤입니다.

**2026-08-06 업데이트: `analyze_crawl_screenshot`/`extract_artists_from_poster`는
LLM팀 실제 코드(`extract_poster.py`)를 파일명 그대로 옮겨서 이미 연결해뒀습니다.** 둘 다
poster_info 스키마(json_schema 강제 출력)를 쓰는 같은 함수(`extract_poster_info`)를
공유합니다. 남은 건 아래 "실행 방법"의 `VLLM_BASE_URL` 설정과 `generate_diary_text(item)`
(한줄평 기반 공연 일기 생성, 이번 주 범위 아님이라 아직 `NotImplementedError` 상태) 뿐입니다.

- `extract_poster.py`/`schema.py`는 LLM팀 원본 그대로이니(파일명도 동일) 로직을 고칠 일이
  있으면 원본 파일을 갱신하고 다시 옮기는 방식으로 동기화해주세요 (직접 이 사본만 고치면
  나중에 원본과 어긋남).
- 반환 형태가 살짝 달라져도 괜찮습니다 — 백엔드 쪽 `normalize.py`가 필드명을 맞춰줍니다.
  예외를 던져도 안전하게 로그만 남고 다음날 재시도됩니다.

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
# .env 열어서 LLM_EXTRACT_API_KEY, BACKEND_BASE_URL, VLLM_BASE_URL 채우기
uvicorn main:app --host 0.0.0.0 --port 8000
```

**포트 주의**: 이 FastAPI 래퍼 자체가 8000번 포트를 씁니다. vLLM(OpenAI 호환 서버)은
같은 인스턴스에서 **다른 포트**(예: 8001)로 띄우고, `.env`의 `VLLM_BASE_URL`을 그 포트에
맞게 채워주세요(기본값도 `http://localhost:8001/v1`으로 잡아뒀습니다). 둘 다 8000번으로
띄우면 포트 충돌 납니다.

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

vLLM을 아직 안 띄운 상태여도(또는 `.env`의 `VLLM_BASE_URL`이 아직 안 맞는 상태여도)
라우팅/인증만 먼저 확인하고 싶으면:

```bash
curl -X POST http://localhost:8000/crawl-analyze \
  -H "Authorization: Bearer <LLM_EXTRACT_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '[{"concert_id": "test-1", "concert_name": "테스트 공연", "screenshot_url": "https://example.com/a.png"}]'
```

202는 정상적으로 바로 오고, vLLM 연결이 안 돼 있으면 실제 추론 시도에서만 실패
로그가 서버 콘솔에 남습니다(백그라운드 처리라 요청 자체는 실패로 안 잡힘). vLLM까지
띄운 뒤 실제로 정보가 잘 뽑히는지 확인하려면 실제 이미지 URL로 다시 보내보세요.
