# TicketDiary

## 시작하기

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

```bash
cd backend
pytest -v
```
