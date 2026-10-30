# TicketDiary

## 시작하기

### Flutter iOS 시뮬레이터 실행

저장소 루트에서 실행하면 iPhone 17 시뮬레이터를 부팅하고 앱을 빌드·실행합니다.

```bash
(cd Prontend && open -a Simulator && xcrun simctl bootstatus "iPhone 17" -b && flutter run -d "iPhone 17" --dart-define-from-file=env.local.json)
```

`Prontend/env.local.json`이 필요하며, `API_BASE_URL`을 `https://ticket-diary.com/api/v1`로 설정합니다.

### 1. 가상환경 생성 및 패키지 설치

```bash
python -m venv .venv
.venv\Scripts\activate       # Windows
source .venv/bin/activate    # macOS/Linux

pip install -r requirements.txt
```

### 2. 환경변수 설정

`backend/.env.example`을 복사해 `backend/.env`를 만들고 값을 채웁니다.

```bash
cp backend/.env.example backend/.env
```

| 변수 | 설명 |
|------|------|
| `DATABASE_URL` | PostgreSQL 비동기 URL (`postgresql+asyncpg://...`) |
| `SYNC_DATABASE_URL` | PostgreSQL 동기 URL (Alembic용) |
| `SECRET_KEY` | JWT 서명 키 |
| `KAKAO_REST_API_KEY` | 카카오 로그인 REST API 키 |

### 3. DB 마이그레이션

```bash
cd backend
alembic upgrade head
```

### 4. 서버 실행

```bash
cd backend
uvicorn app.main:app --reload
```

서버 실행 후 API 문서: http://localhost:8000/docs

---

## 테스트

### 블로그 공유 UI (프런트엔드 준비)

공연 후 페이지 → 공유 → **블로그 공유**에서 네이버 앱 내부 브라우저로 글쓰기 페이지를 엽니다. 앱이 없거나 실행에 실패하면 기본 브라우저로 연결합니다. 네이버 로그인 상태에 따라 로그인이 먼저 필요합니다.

현재 자동 작성 백엔드는 미연결 상태라 준비 중 안내를 표시하며 기존 클립보드를 변경하지 않습니다. 추후 `showConcertAfterShareSheet`의 `loadBlogDraft`에 글을 반환하는 비동기 함수를 연결하면, 전달된 글을 클립보드에 복사한 후 네이버로 이동합니다. 사용자는 본문에 붙여넣고 직접 발행합니다. 로그인 후 편집기 이동은 실제 기기에서 확인이 필요합니다.

```bash
cd backend
pytest -v
```
