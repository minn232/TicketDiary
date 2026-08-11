# TicketDiary Backend API

FastAPI 기반 백엔드. 프론트엔드 연동을 위한 API 명세서.

---

## 기본 설정

### Base URL
```
http://localhost:8000/api/v1
```
개발 서버는 `uvicorn app.main:app --reload`로 실행. Swagger UI는 `http://localhost:8000/docs`에서 확인 가능.

### 인증
로그인 후 발급된 `access_token`을 모든 요청 헤더에 포함.
```
Authorization: Bearer <access_token>
```
토큰 유효 기간: 24시간. 만료 시 재로그인 필요.

### 공통 에러 응답
```json
{ "detail": "에러 메시지" }
```
| 상태코드 | 의미 |
|----------|------|
| 401 | 인증 토큰 없음 또는 만료 |
| 403 | 권한 없음 |
| 404 | 리소스 없음 |
| 409 | 중복 (이미 존재) |
| 413 | 파일 크기 초과 |
| 422 | 요청 형식 오류 |

---

## 인증 API

### 게스트 로그인
앱 최초 실행 시 디바이스 ID로 게스트 계정 자동 생성.
```
POST /auth/guest
```
```json
// Request
{ "device_id": "unique-device-id-string" }

// Response
{
  "access_token": "eyJ...",
  "token_type": "bearer",
  "user_id": "uuid",
  "role": "guest"
}
```

### 카카오 OAuth URL 조회
```
GET /auth/kakao/url
```
```json
// Response
{ "url": "https://kauth.kakao.com/oauth/authorize?..." }
```

### 카카오 로그인
카카오 인증 코드로 로그인 (신규면 계정 생성, 기존이면 조회).
```
POST /auth/kakao
```
```json
// Request
{ "code": "kakao-auth-code" }

// Response
{
  "access_token": "eyJ...",
  "token_type": "bearer",
  "user_id": "uuid",
  "role": "kakao_user"
}
```

### 게스트 → 카카오 마이그레이션
게스트 상태에서 카카오 로그인 시 기존 데이터 이전.
```
POST /auth/migrate
Authorization: Bearer <guest_token>
```
```json
// Request
{ "code": "kakao-auth-code" }

// Response (새 카카오 토큰)
{
  "access_token": "eyJ...",
  "token_type": "bearer",
  "user_id": "uuid",
  "role": "kakao_user"
}
```

### 내 정보 조회
```
GET /auth/me
Authorization: Bearer <token>
```
```json
// Response
{
  "id": "uuid",
  "nickname": "홍길동",
  "profile_image_url": "https://...",
  "role": "kakao_user",
  "is_guest": false
}
```
> 설정 정보(`show_predicted_setlist`, `notification_settings`)는 `GET /settings` 사용.

### 회원 탈퇴
```
DELETE /auth/me
Authorization: Bearer <token>
```
성공 시 204 No Content.

---

## 공연 API

### 티켓 스캔 (OCR)
티켓 사진을 업로드하면 OCR로 정보 추출 + KOPIS에서 공연 후보 검색.
```
POST /concerts/scan
Authorization: Bearer <token>
Content-Type: multipart/form-data
```
```
Form: image (파일, 최대 10MB, JPEG/PNG/HEIC/WebP 지원)
```
```json
// Response
{
  "extracted": {
    "title": "아이유 콘서트",
    "artist": ["아이유"],
    "date": "2030-06-01",
    "time": "19:30",
    "location": "KSPO돔",
    "seat": "VIP석 1구역 5열 20번",
    "platform": "YES24",
    "price": 150000,
    "shipping_date": "2030-05-15",
    "event_type": "SOLO"
  },
  "candidates": [
    {
      "id": "uuid",
      "kopis_id": "PF123456",
      "name": "아이유 콘서트",
      "artist_name": ["아이유"],
      "venue": "KSPO돔",
      "start_date": "2030-06-01T00:00:00Z",
      "end_date": "2030-06-30T00:00:00Z",
      "genre": ["대중음악"],
      "poster_url": "https://...",
      "event_type": "SOLO"
    }
  ]
}
```
- `extracted`: OCR로 티켓에서 뽑아낸 정보 (없는 필드는 null)
- `candidates`: KOPIS에서 검색된 공연 후보 목록 (유저가 선택)
- `event_type`: `"SOLO"` | `"FESTIVAL"` | `"UNKNOWN"`

### 공연 검색
키워드로 KOPIS에서 공연 검색.
```
GET /concerts/search?keyword=아이유&start_date=2030-01-01&end_date=2030-12-31
Authorization: Bearer <token>
```
```json
// Response: ConcertResponse[]
[{ "id": "uuid", "kopis_id": "PF123456", "name": "아이유 콘서트", ... }]
```

### 공연 상세 조회
```
GET /concerts/{kopis_id}
Authorization: Bearer <token>
```
```json
// Response
{
  "id": "uuid",
  "kopis_id": "PF123456",
  "name": "아이유 콘서트",
  "artist_name": ["아이유"],
  "venue": "KSPO돔",
  "start_date": "2030-06-01T00:00:00Z",
  "end_date": "2030-06-30T00:00:00Z",
  "genre": ["대중음악"],
  "poster_url": "https://...",
  "description": "공연 설명",
  "price": [
    { "seat_type": "VIP석", "price": 150000 },
    { "seat_type": "R석", "price": 110000 }
  ],
  "event_type": "SOLO"
}
```

---

## 티켓 API

### 티켓 등록
스캔 후 유저가 선택한 공연으로 티켓 등록. `concert_id`(DB UUID) 또는 `kopis_id` 중 하나 필수.
```
POST /tickets
Authorization: Bearer <token>
```
```json
// Request
{
  "concert_id": "uuid",          // 또는 kopis_id 사용
  "kopis_id": "PF123456",
  "delivery_date": "2030-05-15", // 배송 예정일 (선택)
  "ticketing_site": "YES24",     // 예매처 (선택)
  "price": 150000,               // 가격 (선택)
  "seat_type": "VIP석",          // 좌석 (선택)
  "attended_date": "2030-05-20"  // OCR로 추출한 실제 관람일 (선택)
}

// Response: 201 Created
{
  "id": "uuid",
  "concert_id": "uuid",
  "status": "before_concert",
  "delivery_date": "2030-05-15T00:00:00Z",
  "ticketing_site": "YES24",
  "price": 150000,
  "seat_type": "VIP석",
  "ticket_image_url": null,
  "review": null,
  "concert_photo_urls": null,
  "attended_date": "2030-05-20T00:00:00Z",
  "is_first_day": null,
  "is_last_day": null,
  "concert": { ...ConcertResponse }
}
```
- `status` 자동 결정: 공연 종료 후 등록이면 `after_concert`, 아니면 `before_concert`
- 등록 성공 시 배송일/공연전날/공연당일 알림 자동 생성
- `is_first_day`/`is_last_day` 자동 판정: `attended_date`가 있고, 공연이 `event_type=SOLO`이며,
  `concert.start_date`와 `end_date`가 다른 날(여러 날짜 공연)일 때만 자동 계산됨. 그 외(관람일 모름/
  페스티벌/하루짜리 공연)엔 `null`로 남고, PATCH로 수동 지정 가능

### 내 티켓 목록 조회
```
GET /tickets
Authorization: Bearer <token>
```
```json
// Response: TicketWithConcert[]
// 공연 전 티켓 먼저, 공연일 기준 가까운 순 정렬
[{ "id": "uuid", "status": "before_concert", "concert": {...}, ... }]
```

### 티켓 상세 조회
```
GET /tickets/{ticket_id}
Authorization: Bearer <token>
```

### 티켓 수정
```
PATCH /tickets/{ticket_id}
Authorization: Bearer <token>
```
```json
// Request (수정할 필드만 포함)
{
  "delivery_date": "2030-05-20",
  "seat_type": "R석",
  "price": 110000,
  "review": "너무 좋았어요",
  "concert_photo_urls": ["https://s3.../photo1.jpg"],
  "attended_date": "2030-05-20", // 이것만 보내면 is_first_day/is_last_day는 서버가 재판정
  "is_first_day": true,          // is_first_day/is_last_day를 같이 보내면 수동 override(재판정 안 함)
  "is_last_day": false,
  "status": "after_concert",
  "ticket_image_url": "https://s3.../ticket.jpg"
}
```

### 티켓 삭제
```
DELETE /tickets/{ticket_id}
Authorization: Bearer <token>
```
성공 시 204 No Content.

---

## 셋리스트 API

### 실제 셋리스트 조회
```
GET /concerts/{concert_id}/setlist
Authorization: Bearer <token>
```
```json
// Response (없으면 404)
{
  "id": "uuid",
  "concert_id": "uuid",
  "setlistfm_id": "abc123",
  "songs": [
    { "name": "좋은 날", "encore": false },
    { "name": "밤편지", "encore": true }
  ],
  "is_user_edited": false,
  "edited_user_nickname": null
}
```

### Setlist.fm 후보 검색
실제 셋리스트 등록 전 후보를 검색해서 유저에게 보여줌.
```
GET /concerts/{concert_id}/setlist/search
Authorization: Bearer <token>
```
```json
// Response
[
  {
    "setlistfm_id": "abc123",
    "event_date": "2030-06-01",
    "artist_name": "아이유",
    "venue_name": "KSPO돔",
    "city_name": "서울",
    "song_count": 25,
    "songs": [{ "name": "좋은 날", "encore": false }],
    "url": "https://www.setlist.fm/setlist/..."
  }
]
```

### 실제 셋리스트 저장 (Setlist.fm)
검색 결과에서 선택한 셋리스트 저장.
```
POST /concerts/{concert_id}/setlist
Authorization: Bearer <token>
```
```json
// Request
{ "setlistfm_id": "abc123" }
```

### 실제 셋리스트 유저 수정
```
PATCH /concerts/{concert_id}/setlist
Authorization: Bearer <token>
```
```json
// Request
{
  "songs": [
    { "name": "좋은 날", "encore": false },
    { "name": "밤편지", "encore": false },
    { "name": "celebrity", "encore": true }
  ]
}
```

### 예상 셋리스트 조회
```
GET /concerts/{concert_id}/setlist/pre
Authorization: Bearer <token>
```

### 예상 셋리스트 생성
아티스트 과거 공연 데이터 기반으로 상위 20곡 자동 생성.
```
POST /concerts/{concert_id}/setlist/pre/generate
Authorization: Bearer <token>
```

### 예상 셋리스트 유저 수정
```
PATCH /concerts/{concert_id}/setlist/pre
Authorization: Bearer <token>
```
```json
// Request
{ "songs": [{ "name": "좋은 날", "encore": false }] }
```

---

## 타임테이블 API

### 타임테이블 조회
```
GET /concerts/{concert_id}/timetable
Authorization: Bearer <token>
```
```json
// Response (없으면 404)
{
  "id": "uuid",
  "concert_id": "uuid",
  "contents": [
    { "time": "17:00", "description": "입장 시작" },
    { "time": "18:00", "description": "공연 시작" },
    { "time": "20:30", "description": "공연 종료" }
  ]
}
```

### 타임테이블 등록/수정 (upsert)
```
PUT /concerts/{concert_id}/timetable
Authorization: Bearer <token>
```
```json
// Request
{
  "contents": [
    { "time": "17:00", "description": "입장 시작" },
    { "time": "18:00", "description": "공연 시작" }
  ]
}
```

---

## 알림 API

### 알림 목록 조회
```
GET /notifications
Authorization: Bearer <token>
```
```json
// Response
[
  {
    "id": "uuid",
    "type": "day_before",
    "title": "아이유 콘서트",
    "body": "내일 공연이에요.",
    "is_read": false,
    "is_sent": true,
    "scheduled_at": "2030-05-31T00:00:00Z"
  }
]
```
- `type`: `day_before` | `concert_day` | `delivery_day` | `ticketing_day` | `new_concert`

### 알림 읽음 처리
```
PATCH /notifications/{notification_id}/read
Authorization: Bearer <token>
```
```json
// Response
{ "id": "uuid", "is_read": true, ... }
```

### 알림 삭제
```
DELETE /notifications/{notification_id}
Authorization: Bearer <token>
```
성공 시 204 No Content.

---

## 소셜 API

### 팔로우 아티스트 조회
```
GET /social/artists
Authorization: Bearer <token>
```
```json
// Response
{
  "id": "uuid",
  "user_id": "uuid",
  "artists": [
    { "artist_name": "아이유", "kopis_artist_id": "A000123" }
  ]
}
```

### 팔로우 아티스트 수정 (전체 교체)
```
PATCH /social/artists
Authorization: Bearer <token>
```
```json
// Request (전체 목록으로 교체)
{
  "artists": [
    { "artist_name": "아이유", "kopis_artist_id": "A000123" },
    { "artist_name": "세븐틴", "kopis_artist_id": "A000456" }
  ]
}
```

### 찜 공연 조회
```
GET /social/concerts
Authorization: Bearer <token>
```
```json
// Response
{
  "id": "uuid",
  "user_id": "uuid",
  "concerts": [
    { "concert_id": "uuid", "kopis_concert_id": "PF123456" }
  ]
}
```

### 찜 공연 수정 (전체 교체)
```
PATCH /social/concerts
Authorization: Bearer <token>
```
```json
// Request
{
  "concerts": [
    { "concert_id": "uuid", "kopis_concert_id": "PF123456" }
  ]
}
```

### 뉴스피드 조회
팔로우한 아티스트의 새 공연 알림.
```
GET /social/feed
Authorization: Bearer <token>
```
```json
// Response
[
  {
    "id": "uuid",
    "concert_id": "uuid",
    "artist_name": "아이유",
    "is_read": false,
    "created_at": "2030-01-15T09:00:00Z",
    "concert": { ...ConcertResponse }
  }
]
```

### 뉴스피드 읽음 처리
```
PATCH /social/feed/{feed_id}/read
Authorization: Bearer <token>
```

---

## 설정 API

> `show_predicted_setlist`는 조회/생성을 막는 스위치가 아니라 프론트 전용
> 블러 처리 취향 값입니다 — 꺼져 있어도 `GET/POST/PATCH .../setlist/pre`는
> 그대로 정상 응답합니다.

### 설정 조회
```
GET /settings
Authorization: Bearer <token>
```
```json
// Response
{
  "show_predicted_setlist": true,
  "notification_settings": {
    "delivery": true,
    "day_before": true,
    "concert_day": true
  }
}
```

### 설정 수정
```
PATCH /settings
Authorization: Bearer <token>
```
```json
// Request (수정할 필드만)
{
  "show_predicted_setlist": false,
  "notification_settings": {
    "delivery": false,
    "day_before": true,
    "concert_day": true
  }
}
```

### FCM 토큰 등록
앱 실행 시 또는 토큰 갱신 시 호출.
```
PATCH /settings/fcm-token
Authorization: Bearer <token>
```
```json
// Request
{ "fcm_token": "firebase-fcm-token-string" }
```

---

## 결산 API

### 기간별 결산 조회
```
GET /summary?period=6m
Authorization: Bearer <token>
```
- `period`: `6m` (6개월) | `1y` (1년) | `all` (전체)

```json
// Response
{
  "period": "6m",
  "concert_count": 12,
  "song_count": 245,
  "total_spent": 1320000,
  "top_genre": "대중음악",
  "artists": ["아이유", "세븐틴"],
  "standing_count": 7,
  "seated_count": 5,
  "first_day_count": 3,
  "last_day_count": 2
}
```

---

## 업로드 API

### 티켓 이미지 업로드
```
POST /upload/ticket-image
Authorization: Bearer <token>
Content-Type: multipart/form-data
```
```
Form: image (파일, 최대 10MB)
```
```json
// Response
{ "url": "https://s3.ap-northeast-2.amazonaws.com/ticketdiary-images/ticket-images/uuid.jpg" }
```
업로드 후 반환된 URL을 `PATCH /tickets/{id}` → `ticket_image_url` 필드에 저장.

### 공연 사진 업로드
```
POST /upload/concert-photo
Authorization: Bearer <token>
Content-Type: multipart/form-data
```
```
Form: image (파일, 최대 10MB)
```
```json
// Response
{ "url": "https://s3.ap-northeast-2.amazonaws.com/ticketdiary-images/concert-photos/uuid.jpg" }
```
업로드 후 반환된 URL을 `PATCH /tickets/{id}` → `concert_photo_urls` 배열에 추가.

---

## 주요 플로우

### 티켓 등록 플로우

```
1. 티켓 사진 촬영
   → POST /upload/ticket-image  (선택: 이미지 저장)
   → POST /concerts/scan        (OCR + 공연 후보 검색)

2. 유저가 candidates 중 공연 선택
   → POST /tickets              (concert_id 또는 kopis_id로 등록)
     ∟ 배송/공연전날/공연당일 알림 자동 생성
     ∟ 백그라운드: 티켓팅 사이트 크롤링 시작

3. (선택) 타임테이블, 셋리스트 설정
   → PUT  /concerts/{id}/timetable
   → POST /concerts/{id}/setlist/pre/generate
```

### 공연 후 기록 플로우

```
1. 공연 사진 업로드
   → POST /upload/concert-photo  (여러 장 반복)

2. 티켓 정보 업데이트
   → PATCH /tickets/{id}
     { concert_photo_urls, review, is_first_day, is_last_day }

3. 실제 셋리스트 저장
   → GET  /concerts/{id}/setlist/search  (Setlist.fm 후보 검색)
   → POST /concerts/{id}/setlist         (후보 선택 저장)
   또는
   → PATCH /concerts/{id}/setlist        (직접 입력)
```

### 소셜/알림 플로우

```
1. 아티스트 팔로우 등록
   → PATCH /social/artists

2. (서버 배치 04:00 UTC) KOPIS 신규 공연 감지 → 뉴스피드 자동 생성

3. 앱 실행 시 뉴스피드 확인
   → GET /social/feed
   → PATCH /social/feed/{id}/read

4. FCM 푸시 수신 (공연전날/당일 KST 09:00 자동 발송)
   → GET /notifications          (목록 확인)
   → PATCH /notifications/{id}/read
```

---

## 티켓 status 값

| 값 | 의미 | 전환 시점 |
|----|------|----------|
| `before_delivery` | 배송 전 | 수동 (PATCH) |
| `before_concert` | 공연 전 | 티켓 등록 시 자동 설정, 매일 KST 00:05 배치로 자동 전환 |
| `after_concert` | 공연 후 | 공연 종료 다음날 KST 자정 배치로 자동 전환 |
