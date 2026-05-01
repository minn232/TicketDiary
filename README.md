# TicketDiary

<<<<<<< Updated upstream
=======
공연 티켓을 기록하고 관리하는 앱의 백엔드 서버입니다.

---

## 기술 스택

- **Framework**: FastAPI
- **Database**: PostgreSQL
- **ORM**: SQLAlchemy 2.0 (async)
- **Migration**: Alembic
- **Auth**: JWT (카카오 로그인 / 게스트 로그인)
- **Python**: 3.12

---

## 프로젝트 구조

```
TicketDiary/
├── backend/
│   ├── app/
│   │   ├── api/v1/
│   │   │   ├── endpoints/       # 라우터 (auth, tickets, concerts, ...)
│   │   │   ├── dependencies.py  # 인증 의존성 (get_current_user)
│   │   │   └── router.py
│   │   ├── core/
│   │   │   ├── config.py        # 환경변수 설정
│   │   │   ├── database.py      # DB 엔진 및 세션
│   │   │   └── security.py      # JWT 생성/검증
│   │   ├── models/              # SQLAlchemy ORM 모델
│   │   ├── schemas/             # Pydantic 요청/응답 스키마
│   │   └── services/            # 비즈니스 로직
│   ├── alembic/                 # DB 마이그레이션
│   ├── tests/
│   ├── .env                     # 환경변수 (git 제외)
│   └── pytest.ini
└── DB_SCHEMA.md                 # DB 스키마 문서
```

---

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

## API 엔드포인트

| prefix | 설명 |
|--------|------|
| `/api/v1/auth` | 로그인 (카카오, 게스트), 내 정보 조회 |
| `/api/v1/tickets` | 티켓 CRUD |
| `/api/v1/concerts` | 공연 CRUD |
| `/api/v1/setlists` | 실제/예상 셋리스트 |
| `/api/v1/news` | 뉴스피드 |
| `/api/v1/stats` | 통계 |
| `/api/v1/settings` | 유저 설정 |

---

## 테스트

```bash
cd backend
pytest -v
```

---

## DB 스키마

전체 테이블 구조는 [DB_SCHEMA.md](./DB_SCHEMA.md)를 참고하세요.
>>>>>>> Stashed changes
