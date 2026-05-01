# TicketDiary DB Schema 정리

## 목차
- [Models](#models)
  - [User](#user)
  - [Concert](#concert)
  - [Ticket](#ticket)
  - [RealSetlist](#realsetlist)
  - [PreSetlist](#presetlist)
  - [TimeTable](#timetable)
  - [ArtistFollow](#artistfollow)
  - [ConcertFollow](#concertfollow)
  - [NewsFeed](#newsfeed)
  - [Notification](#notification)
- [Schemas (Pydantic)](#schemas-pydantic)
  - [Auth](#auth)
  - [Concert Schemas](#concert-schemas)
  - [Ticket Schemas](#ticket-schemas)
  - [Setlist Schemas](#setlist-schemas)
  - [TimeTable Schemas](#timetable-schemas)
  - [Social Schemas](#social-schemas)
  - [Notification Schemas](#notification-schemas)
- [Enums](#enums)

---

## Models

### User
테이블명: `users`

| 컬럼 | 타입 | 제약조건 | 설명 |
|------|------|----------|------|
| `id` | UUID | PK, default=uuid4 | 유저 고유 식별자 |
| `kakao_id` | String | unique, nullable, index | 카카오 로그인 ID |
| `guest_token` | String | unique, nullable, index | 비회원 세션 토큰 |
| `nickname` | String | nullable | 닉네임 |
| `profile_image_url` | String | nullable | 프로필 이미지 URL |
| `role` | Enum(UserRole) | default=`kakao_user` | 유저 역할 |

**관계:**
- `tickets` → `Ticket` (one-to-many)
- `artist_follow` → `ArtistFollow` (one-to-one)
- `concert_follow` → `ConcertFollow` (one-to-one)

---

### Concert
테이블명: `concerts`

| 컬럼 | 타입 | 제약조건 | 설명 |
|------|------|----------|------|
| `id` | UUID | PK, default=uuid4 | 공연 고유 식별자 |
| `kopis_id` | String | nullable, index | KOPIS 공연 ID |
| `name` | String | NOT NULL | 공연명 |
| `artist_name` | ARRAY(String) | NOT NULL | 아티스트명 목록 |
| `venue` | String | nullable | 공연 장소 |
| `start_date` | DateTime(tz) | NOT NULL | 공연 시작일 |
| `end_date` | DateTime(tz) | NOT NULL | 공연 종료일 |
| `genre` | ARRAY(String) | nullable | 장르 목록 |
| `poster_url` | String | nullable | 포스터 이미지 URL |
| `description` | Text | nullable | 공연 설명 |
| `price` | JSONB | nullable | 좌석 등급별 가격 (`[{"seat_type": "S석", "price": 150000}]`) |

**관계:**
- `tickets` → `Ticket` (one-to-many)
- `timetable` → `TimeTable` (one-to-one)
- `real_setlist` → `RealSetlist` (one-to-one)
- `pre_setlist` → `PreSetlist` (one-to-one)

---

### Ticket
테이블명: `tickets`

| 컬럼 | 타입 | 제약조건 | 설명 |
|------|------|----------|------|
| `id` | UUID | PK, default=uuid4 | 티켓 고유 식별자 |
| `user_id` | UUID | FK(users.id), NOT NULL, index | 소유 유저 |
| `concert_id` | UUID | FK(concerts.id), nullable, index | 연결된 공연 |
| `status` | Enum(TicketStatus) | default=`before_delivery` | 티켓 상태 |
| `delivery_date` | DateTime(tz) | nullable | 티켓 수령 예정일 |
| `ticketing_site` | String | nullable | 예매 사이트 |
| `price` | Integer | nullable | 실제 구매 가격 |
| `seat_type` | String | nullable | 좌석 종류 |
| `ticket_image_url` | String | nullable | 티켓 이미지 URL |
| `review` | Text | nullable | 공연 후기 |
| `concert_photo_urls` | Text | nullable | 공연 사진 URL 목록 (JSON 문자열) |
| `is_first_day` | Boolean | nullable | 첫날 공연 여부 |
| `is_last_day` | Boolean | nullable | 마지막날 공연 여부 |

**제약조건:** `(user_id, concert_id)` 복합 unique — 한 유저당 같은 공연 티켓 1개만 허용

**관계:**
- `concert` → `Concert` (many-to-one)

---

### RealSetlist
테이블명: `real_setlists`

| 컬럼 | 타입 | 제약조건 | 설명 |
|------|------|----------|------|
| `id` | UUID | PK, default=uuid4 | 고유 식별자 |
| `concert_id` | UUID | FK(concerts.id), NOT NULL, unique | 연결된 공연 (1:1) |
| `setlistfm_id` | String | nullable | setlist.fm 연동 ID |
| `songs` | Text | NOT NULL | 곡 목록 (JSON 문자열) |
| `is_user_edited` | Boolean | default=`False` | 유저 직접 수정 여부 |
| `edited_user_nickname` | String | nullable | 수정한 유저 닉네임 |

**관계:**
- `concert` → `Concert` (one-to-one)

---

### PreSetlist
테이블명: `pre_setlists`

| 컬럼 | 타입 | 제약조건 | 설명 |
|------|------|----------|------|
| `id` | UUID | PK, default=uuid4 | 고유 식별자 |
| `concert_id` | UUID | FK(concerts.id), NOT NULL, unique | 연결된 공연 (1:1) |
| `setlistfm_id` | String | nullable | setlist.fm 연동 ID |
| `songs` | Text | NOT NULL | 예상 곡 목록 (JSON 문자열) |
| `is_user_edited` | Boolean | default=`False` | 유저 직접 수정 여부 |
| `edited_user_nickname` | String | nullable | 수정한 유저 닉네임 |

**관계:**
- `concert` → `Concert` (one-to-one)

---

### TimeTable
테이블명: `timetables`

| 컬럼 | 타입 | 제약조건 | 설명 |
|------|------|----------|------|
| `id` | UUID | PK, default=uuid4 | 고유 식별자 |
| `concert_id` | UUID | FK(concerts.id), NOT NULL, unique | 연결된 공연 (1:1) |
| `contents` | JSONB | NOT NULL, default=[] | 타임테이블 항목 (`[{"time": "17:00", "description": "입장"}]`) |

**관계:**
- `concert` → `Concert` (one-to-one)

---

### ArtistFollow
테이블명: `artist_follows`

| 컬럼 | 타입 | 제약조건 | 설명 |
|------|------|----------|------|
| `id` | UUID | PK, default=uuid4 | 고유 식별자 |
| `user_id` | UUID | FK(users.id), NOT NULL, unique | 유저 (1:1) |
| `artists` | JSONB | NOT NULL, default=[] | 팔로우 아티스트 목록 (`[{"artist_name": "아이유", "kopis_artist_id": "K001"}]`) |

---

### ConcertFollow
테이블명: `concert_follows`

| 컬럼 | 타입 | 제약조건 | 설명 |
|------|------|----------|------|
| `id` | UUID | PK, default=uuid4 | 고유 식별자 |
| `user_id` | UUID | FK(users.id), NOT NULL, unique | 유저 (1:1) |
| `concerts` | JSONB | NOT NULL, default=[] | 팔로우 공연 목록 (`[{"concert_id": "uuid", "kopis_concert_id": "K001"}]`) |

---

### NewsFeed
테이블명: `news_feeds`

| 컬럼 | 타입 | 제약조건 | 설명 |
|------|------|----------|------|
| `id` | UUID | PK, default=uuid4 | 고유 식별자 |
| `user_id` | UUID | FK(users.id), NOT NULL, index | 대상 유저 |
| `concert_id` | UUID | FK(concerts.id, CASCADE), NOT NULL, index | 연결된 공연 (공연 삭제 시 같이 삭제) |
| `artist_name` | String | NOT NULL | 팔로우로 인해 트리거된 아티스트명 |
| `is_read` | Boolean | default=`False` | 읽음 여부 |

**관계:**
- `concert` → `Concert` (many-to-one)

---

### Notification
테이블명: `notifications`

| 컬럼 | 타입 | 제약조건 | 설명 |
|------|------|----------|------|
| `id` | UUID | PK, default=uuid4 | 고유 식별자 |
| `user_id` | UUID | FK(users.id), NOT NULL, index | 수신 유저 |
| `ticket_id` | UUID | FK(tickets.id), nullable | 관련 티켓 |
| `type` | Enum(NotificationType) | NOT NULL | 알림 유형 |
| `title` | String | NOT NULL | 알림 제목 |
| `body` | String | NOT NULL | 알림 본문 |
| `is_sent` | Boolean | default=`False` | 발송 여부 |
| `scheduled_at` | DateTime(tz) | NOT NULL | 예약 발송 시각 |

---

## Schemas (Pydantic)

### Auth

#### `TokenResponse`
| 필드 | 타입 | 기본값 | 설명 |
|------|------|--------|------|
| `access_token` | str | 필수 | JWT 액세스 토큰 |
| `token_type` | str | `"bearer"` | 토큰 타입 |
| `user_id` | UUID | 필수 | 유저 ID |
| `role` | UserRole | 필수 | 유저 역할 |

#### `GuestLoginRequest`
| 필드 | 타입 | 설명 |
|------|------|------|
| `device_id` | str | 기기 고유 식별자 (서버에서 SHA-256 해싱 후 저장) |

#### `UserResponse`
| 필드 | 타입 | 설명 |
|------|------|------|
| `id` | UUID | 유저 ID |
| `nickname` | str \| None | 닉네임 |
| `profile_image_url` | str \| None | 프로필 이미지 URL |
| `role` | UserRole | 유저 역할 |

---

### Concert Schemas

#### `ConcertCreate`
| 필드 | 타입 | 기본값 | 설명 |
|------|------|--------|------|
| `kopis_id` | str \| None | `None` | KOPIS ID |
| `name` | str | 필수 | 공연명 |
| `artist_name` | list[str] | 필수 | 아티스트명 목록 |
| `venue` | str \| None | `None` | 공연 장소 |
| `start_date` | datetime | 필수 | 공연 시작일 |
| `end_date` | datetime | 필수 | 공연 종료일 |
| `genre` | list[str] \| None | `None` | 장르 목록 |
| `poster_url` | str \| None | `None` | 포스터 URL |
| `description` | str \| None | `None` | 공연 설명 |
| `price` | list[PriceEntry] \| None | `None` | 좌석 등급별 가격 |

#### `ConcertUpdate`
`ConcertCreate`와 동일한 필드, 모두 선택적.

#### `ConcertResponse`
`ConcertCreate` 필드 전체 + `id: UUID`

---

### Ticket Schemas

#### `TicketCreate`
| 필드 | 타입 | 기본값 | 설명 |
|------|------|--------|------|
| `concert_id` | UUID | 필수 | 연결할 공연 ID |
| `delivery_date` | datetime \| None | `None` | 수령 예정일 |
| `ticketing_site` | str \| None | `None` | 예매 사이트 |
| `price` | int \| None | `None` | 실제 구매 가격 |
| `seat_type` | str \| None | `None` | 좌석 종류 |

#### `TicketUpdate`
| 필드 | 타입 | 설명 |
|------|------|------|
| `status` | TicketStatus \| None | 티켓 상태 |
| `delivery_date` | datetime \| None | 수령 예정일 |
| `ticketing_site` | str \| None | 예매 사이트 |
| `price` | int \| None | 실제 구매 가격 |
| `seat_type` | str \| None | 좌석 종류 |
| `ticket_image_url` | str \| None | 티켓 이미지 URL |
| `review` | str \| None | 공연 후기 |
| `concert_photo_urls` | str \| None | 공연 사진 URL 목록 |
| `is_first_day` | bool \| None | 첫날 여부 |
| `is_last_day` | bool \| None | 마지막날 여부 |

#### `TicketResponse`
`TicketUpdate` 필드 전체 + `id: UUID`, `concert_id: UUID | None`

---

### Setlist Schemas

#### `RealSetlistCreate` / `PreSetlistCreate`
| 필드 | 타입 | 기본값 | 설명 |
|------|------|--------|------|
| `concert_id` | UUID | 필수 | 연결할 공연 ID |
| `setlistfm_id` | str \| None | `None` | setlist.fm ID |
| `songs` | str | 필수 | 곡 목록 (JSON 문자열) |
| `is_user_edited` | bool | `False` | 유저 수정 여부 |
| `edited_user_nickname` | str \| None | `None` | 수정한 유저 닉네임 |

#### `RealSetlistUpdate` / `PreSetlistUpdate`
위 필드에서 `concert_id` 제외, 모두 선택적.

#### `RealSetlistResponse` / `PreSetlistResponse`
Create 필드 전체 + `id: UUID`

---

### TimeTable Schemas

#### `TimeTableCreate`
| 필드 | 타입 | 설명 |
|------|------|------|
| `concert_id` | UUID | 연결할 공연 ID |
| `contents` | list[TimeTableEntry] | 타임테이블 항목 목록 |

#### `TimeTableEntry`
| 필드 | 타입 | 설명 |
|------|------|------|
| `time` | str | 시각 (예: "17:00") |
| `description` | str | 내용 (예: "입장") |

#### `TimeTableUpdate`
`contents: list[TimeTableEntry] | None`

#### `TimeTableResponse`
`TimeTableCreate` 필드 전체 + `id: UUID`

---

### Social Schemas

#### `ArtistFollowUpdate`
| 필드 | 타입 | 설명 |
|------|------|------|
| `artists` | list[ArtistEntry] | 팔로우 아티스트 목록 전체 |

#### `ArtistEntry`
| 필드 | 타입 | 설명 |
|------|------|------|
| `artist_name` | str | 아티스트명 |
| `kopis_artist_id` | str \| None | KOPIS 아티스트 ID |

#### `ArtistFollowResponse`
`ArtistFollowUpdate` 필드 전체 + `id: UUID`, `user_id: UUID`

#### `ConcertFollowUpdate`
| 필드 | 타입 | 설명 |
|------|------|------|
| `concerts` | list[ConcertEntry] | 팔로우 공연 목록 전체 |

#### `ConcertEntry`
| 필드 | 타입 | 설명 |
|------|------|------|
| `concert_id` | str | 공연 UUID |
| `kopis_concert_id` | str \| None | KOPIS 공연 ID |

#### `ConcertFollowResponse`
`ConcertFollowUpdate` 필드 전체 + `id: UUID`, `user_id: UUID`

#### `NewsFeedResponse`
| 필드 | 타입 | 설명 |
|------|------|------|
| `id` | UUID | 고유 식별자 |
| `user_id` | UUID | 대상 유저 ID |
| `concert_id` | UUID | 연결된 공연 ID |
| `artist_name` | str | 트리거된 아티스트명 |
| `is_read` | bool | 읽음 여부 |

---

### Notification Schemas

#### `NotificationResponse`
| 필드 | 타입 | 설명 |
|------|------|------|
| `id` | UUID | 고유 식별자 |
| `user_id` | UUID | 수신 유저 ID |
| `ticket_id` | UUID \| None | 관련 티켓 ID |
| `type` | NotificationType | 알림 유형 |
| `title` | str | 알림 제목 |
| `body` | str | 알림 본문 |
| `is_sent` | bool | 발송 여부 |
| `scheduled_at` | datetime | 예약 발송 시각 |

---

## Enums

### `UserRole`
| 값 | 설명 |
|----|------|
| `kakao_user` | 카카오 로그인 유저 |
| `guest` | 비회원 게스트 유저 |

### `TicketStatus`
| 값 | 설명 |
|----|------|
| `before_delivery` | 티켓 수령 전 |
| `before_concert` | 티켓 수령 후, 공연 전 |
| `after_concert` | 공연 종료 후 |

### `NotificationType`
| 값 | 설명 |
|----|------|
| `day_before` | 공연 하루 전 알림 |
| `concert_day` | 공연 당일 알림 |
| `delivery_day` | 티켓 수령일 알림 |
| `ticketing_day` | 티켓팅 오픈일 알림 |
| `new_concert` | 팔로우 아티스트 신규 공연 알림 |
