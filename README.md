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

### Android 휴대폰 푸시 알림 설정

앱 사용 중 FCM 알림은 Android 알림 패널에 표시합니다. 백그라운드에서는 FCM SDK가 표시하며, 두 경로는 `ticket_diary_updates` 채널(공연·티켓 알림)을 공유합니다. 알림을 누르면 시작 화면과 최초 계정 선택이 끝난 뒤 알림함을 엽니다. 현재 서버 메시지는 제목·본문만 있으므로 특정 티켓으로 바로 이동하지 않습니다. Firebase 콘솔의 테스트 메시지는 서버 알림함 데이터에 저장되지 않으므로 알림함이 비어 있을 수 있습니다.

개발자가 준비할 것:

1. 백엔드와 같은 Firebase 프로젝트에 Android 앱 `com.example.ticketdiary`를 등록합니다(현재 applicationId).
2. 내려받은 `google-services.json`을 `Prontend/android/app/google-services.json`에 둡니다. 이 파일은 Git 제외 대상입니다. 서버용 서비스 계정 비밀키는 앱에 넣지 않습니다.
3. 백엔드 담당자에게 Firebase Admin 인증 설정과 알림 발송 스케줄러의 운영 여부를 확인합니다. 이번 구현은 백엔드를 변경하지 않습니다.
4. USB 디버깅을 켠 Android 기기에서 실행하고 알림 권한을 허용합니다. Android 13 이상은 런타임 알림 권한이 필요합니다. 설정 → 알림의 상태 행을 누르면 휴대폰 알림 설정을 열 수 있습니다. 앱/채널 알림 차단과 방해금지 설정도 확인합니다.

```bash
cd Prontend
flutter devices
flutter run -d <안드로이드_기기_ID> --dart-define-from-file=env.local.json
```

`env.local.json`은 별도로 준비한 실제 개발 환경 파일 경로를 사용합니다. 네이티브 코드가 추가되어 Hot Reload 대신 앱을 다시 빌드해야 합니다.

실기기 검증 순서:

- Firebase 설정 후 앱을 실행하여 설정의 상태가 “휴대폰 알림이 켜져 있어요”인지 확인합니다. 이 상태는 권한·토큰 등록 확인이며 서버의 실제 발송 성공을 보장하지 않습니다.
- 디버거에서 `await FirebaseMessaging.instance.getToken()`으로 해당 기기의 토큰을 확인하고 Firebase 콘솔의 테스트 메시지 대상으로 입력합니다. 토큰을 공개 저장소에 올리지 않습니다.
- 앱을 사용 중일 때: 알림 패널 표시 → 탭 → 알림함 열림 확인.
- 홈 버튼으로 앱을 내렸을 때: 시스템 알림 표시 → 탭 → 알림함 열림 확인.
- 앱 프로세스가 없는 상태: 알림 탭 → 스플래시 종료 후 알림함 확인. Android 설정의 “강제 종료”는 별개이며, 다시 앱을 실행하기 전에는 수신이 제한될 수 있습니다.
- 권한을 끄거나 채널을 차단한 뒤 앱으로 돌아와 상태 표시 확인. 다시 허용하면 복귀 시 토큰을 재등록합니다.
- 실제 서버 알림으로 목록 갱신 및 읽음·삭제·티켓 이동을 별도 확인합니다.

토큰 발급/등록 실패는 최대 5회(15초씩 증가하는 간격) 재시도하며, 앱 복귀 시 다시 시도합니다. 계정 변경 후에는 현재 계정에 재등록합니다. iOS 푸시는 이번 작업 대상이 아닙니다.
