import uuid
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

import app.services.kopis as kopis_module
from app.main import app
from app.core.database import AsyncSessionLocal
from app.models.concert import Concert
from app.models.social import NewsFeed
from app.services.kopis import (
    _fetch_all_kopis_ids,
    _is_allowed_genre,
    _is_large_venue,
    sync_daily_concerts,
)
from conftest import _get_token, kopis_mock


# 헬퍼

# KOPIS 목록 API XML 생성 (kopis_id 목록 기반)
# fcltynm에 대형 공연장 키워드("체조경기장")를 포함시켜 _is_large_venue 필터를 통과하도록 함
def _make_list_xml(kopis_ids: list[str]) -> bytes:
    dbs = ""
    for kid in kopis_ids:
        dbs += (
            f"<db>"
            f"<mt20id>{kid}</mt20id>"
            f"<prfnm>{kid} 공연</prfnm>"
            f"<prfpdfrom>2030.06.01</prfpdfrom>"
            f"<prfpdto>2030.06.30</prfpdto>"
            f"<fcltynm>테스트체조경기장</fcltynm>"
            f"<genrenm>대중음악</genrenm>"
            f"<poster></poster>"
            f"</db>"
        )
    return f'<?xml version="1.0" encoding="UTF-8"?><dbs>{dbs}</dbs>'.encode("utf-8")


# KOPIS 상세 API XML 생성 (아티스트 지정 가능)
def _make_detail_xml(kopis_id: str, artist: str = "테스트아티스트") -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.30</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f"<genrenm>대중음악</genrenm>"
        f"<prfcast>{artist}</prfcast>"
        f"<pcseguidance></pcseguidance>"
        f"<sty></sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# 목록 API와 상세 API를 URL 기반으로 구분하는 KOPIS mock
@contextmanager
def _batch_kopis_mock(list_xml: bytes, detail_xml: bytes):
    list_response = MagicMock()
    list_response.status_code = 200
    list_response.content = list_xml

    detail_response = MagicMock()
    detail_response.status_code = 200
    detail_response.content = detail_xml

    async def _mock_get(url, **kwargs):
        parts = url.split("/pblprfr/")
        if len(parts) > 1 and parts[1]:
            return detail_response
        return list_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        yield


# kopis_id, fcltynm 쌍으로 목록 API XML 생성 (공연장 필터 테스트용)
def _make_list_xml_with_venues(entries: list[tuple[str, str]]) -> bytes:
    dbs = ""
    for kid, fclty in entries:
        dbs += (
            f"<db>"
            f"<mt20id>{kid}</mt20id>"
            f"<prfnm>{kid} 공연</prfnm>"
            f"<prfpdfrom>2030.06.01</prfpdfrom>"
            f"<prfpdto>2030.06.30</prfpdto>"
            f"<fcltynm>{fclty}</fcltynm>"
            f"<genrenm>대중음악</genrenm>"
            f"<poster></poster>"
            f"</db>"
        )
    return f'<?xml version="1.0" encoding="UTF-8"?><dbs>{dbs}</dbs>'.encode("utf-8")


# kopis_id, genrenm 쌍으로 목록 API XML 생성 (장르 필터 테스트용)
def _make_list_xml_with_genres(entries: list[tuple[str, str]]) -> bytes:
    dbs = ""
    for kid, genre in entries:
        dbs += (
            f"<db>"
            f"<mt20id>{kid}</mt20id>"
            f"<prfnm>{kid} 공연</prfnm>"
            f"<prfpdfrom>2030.06.01</prfpdfrom>"
            f"<prfpdto>2030.06.30</prfpdto>"
            f"<fcltynm>테스트공연장</fcltynm>"
            f"<genrenm>{genre}</genrenm>"
            f"<poster></poster>"
            f"</db>"
        )
    return f'<?xml version="1.0" encoding="UTF-8"?><dbs>{dbs}</dbs>'.encode("utf-8")


_TEST_LARGE_VENUE_KEYWORDS = ["체조경기장", "스카이돔", "종합운동장", "주경기장"]


# _is_allowed_genre 테스트

# KOPIS 응답의 genrenm이 실제로는 요청 파라미터로 걸러지지 않아 (연극/뮤지컬 등이 섞여 들어옴)
# 클라이언트에서 대중음악만 통과시키는지 확인
def test_is_allowed_genre_only_passes_popular_music():
    assert _is_allowed_genre("대중음악")
    assert not _is_allowed_genre("연극")
    assert not _is_allowed_genre("뮤지컬")
    assert not _is_allowed_genre("서양음악(클래식)")


# 허용 장르 목록이 비어있으면 전부 통과되는지 테스트
def test_is_allowed_genre_passes_everything_when_list_empty():
    with patch("app.services.kopis._ALLOWED_GENRES", []):
        assert _is_allowed_genre("연극")
        assert _is_allowed_genre("아무거나")


# 목록 API 응답에 장르가 섞여 있어도 대중음악만 수집하는지 테스트 (요청 파라미터 genrenm 미작동 대비)
@pytest.mark.asyncio
async def test_fetch_all_kopis_ids_filters_to_allowed_genre():
    entries = [
        ("PF_PLAY", "연극"),
        ("PF_POP_1", "대중음악"),
        ("PF_MUSICAL", "뮤지컬"),
        ("PF_POP_2", "대중음악"),
    ]

    async def _mock_get(url, **kwargs):
        return MagicMock(status_code=200, content=_make_list_xml_with_genres(entries))

    mock_client = MagicMock()
    mock_client.get = _mock_get

    ids = await _fetch_all_kopis_ids(mock_client, date(2030, 1, 1), date(2030, 12, 31))

    assert ids == ["PF_POP_1", "PF_POP_2"]


# _is_large_venue 테스트

# 대형 공연장 키워드 포함 여부로 판별 (운영 기본값은 빈 리스트=필터 비활성화라 테스트용 키워드로 명시적 패치)
def test_is_large_venue_matches_known_keywords():
    with patch("app.services.kopis._LARGE_VENUE_KEYWORDS", _TEST_LARGE_VENUE_KEYWORDS):
        assert _is_large_venue("올림픽공원 체조경기장")
        assert _is_large_venue("고척스카이돔")
        assert _is_large_venue("잠실종합운동장 (주경기장)")
        assert not _is_large_venue("대학로 소극장")


# 키워드 목록이 비어있으면(운영 기본값) 전부 통과되는지 테스트
def test_is_large_venue_passes_everything_when_keywords_empty():
    with patch("app.services.kopis._LARGE_VENUE_KEYWORDS", []):
        assert _is_large_venue("대학로 소극장")
        assert _is_large_venue("동네공연장")


# _throttle_kopis_request 테스트

# KOPIS IP당 초당 10회 제한(공식 정책)을 넘지 않도록 연속 호출 시 대기하는지 테스트
@pytest.mark.asyncio
async def test_throttle_kopis_request_waits_when_called_too_soon():
    kopis_module._kopis_last_request_at = 0.0
    sleep_mock = AsyncMock()
    mock_loop = MagicMock()
    # 1번째 호출: now=10.0 (마지막 요청 0.0과 충분히 떨어져 대기 없음), 이후 last_request_at=10.0으로 갱신
    # 2번째 호출: now=10.1 (0.35초 간격에 못 미침 -> 약 0.25초 대기해야 함)
    mock_loop.time.side_effect = [10.0, 10.0, 10.1, 10.45]

    with (
        patch("asyncio.sleep", sleep_mock),
        patch("asyncio.get_event_loop", return_value=mock_loop),
    ):
        await kopis_module._throttle_kopis_request()
        sleep_mock.assert_not_called()

        await kopis_module._throttle_kopis_request()
        sleep_mock.assert_awaited_once()
        waited = sleep_mock.await_args[0][0]
        assert waited == pytest.approx(0.25, abs=0.01)


# _fetch_all_kopis_ids 테스트

# 대형 공연장만 필터링해서 kopis_id를 수집하는지 테스트 (운영 기본값은 필터 비활성화라 테스트용 키워드로 명시적 패치)
@pytest.mark.asyncio
async def test_fetch_all_kopis_ids_filters_to_large_venues():
    entries = [
        ("PF_SMALL_1", "대학로 소극장"),
        ("PF_BIG_1", "올림픽공원 체조경기장"),
        ("PF_SMALL_2", "동네공연장"),
        ("PF_BIG_2", "고척스카이돔"),
    ]

    async def _mock_get(url, **kwargs):
        return MagicMock(status_code=200, content=_make_list_xml_with_venues(entries))

    mock_client = MagicMock()
    mock_client.get = _mock_get

    with patch("app.services.kopis._LARGE_VENUE_KEYWORDS", _TEST_LARGE_VENUE_KEYWORDS):
        ids = await _fetch_all_kopis_ids(mock_client, date(2030, 1, 1), date(2030, 12, 31))

    assert ids == ["PF_BIG_1", "PF_BIG_2"]


# 필터링 후 건수가 100건 미만이어도, 원본 응답이 100건 꽉 찼으면 다음 페이지를 계속 조회하는지 테스트
@pytest.mark.asyncio
async def test_fetch_all_kopis_ids_pagination_uses_raw_count_not_filtered_count():
    async def _mock_get(url, **kwargs):
        cpage = kwargs["params"]["cpage"]
        if cpage == 1:
            # 100건 꽉 찬 페이지지만 대형 공연장은 1건뿐
            entries = [("PF_SMALL", "동네공연장")] * 99 + [("PF_BIG_P1", "고척스카이돔")]
        elif cpage == 2:
            # 마지막 페이지 (50건, 대형 공연장 1건)
            entries = [("PF_SMALL2", "동네공연장")] * 49 + [("PF_BIG_P2", "올림픽공원 체조경기장")]
        else:
            entries = []
        return MagicMock(status_code=200, content=_make_list_xml_with_venues(entries))

    mock_client = MagicMock()
    mock_client.get = _mock_get

    with patch("app.services.kopis._LARGE_VENUE_KEYWORDS", _TEST_LARGE_VENUE_KEYWORDS):
        ids = await _fetch_all_kopis_ids(mock_client, date(2030, 1, 1), date(2030, 12, 31))

    # 1페이지의 필터링 후 건수(1건)만 보고 조기 종료됐다면 PF_BIG_P2는 못 받았을 것
    assert ids == ["PF_BIG_P1", "PF_BIG_P2"]


# 21페이지 이상 존재해도 (구 상한 20페이지=2000건을 넘어) 끝까지 수집하는지 테스트
@pytest.mark.asyncio
async def test_fetch_all_kopis_ids_collects_beyond_old_page_cap():
    # 25페이지 100건씩(2500건) + 26페이지째 50건(마지막 페이지) = 총 2550건
    async def _mock_get(url, **kwargs):
        cpage = kwargs["params"]["cpage"]
        if cpage <= 25:
            ids = [f"PF_PAGE{cpage}_{i}" for i in range(100)]
        elif cpage == 26:
            ids = [f"PF_PAGE26_{i}" for i in range(50)]
        else:
            ids = []
        return MagicMock(status_code=200, content=_make_list_xml(ids))

    mock_client = MagicMock()
    mock_client.get = _mock_get

    ids = await _fetch_all_kopis_ids(mock_client, date(2030, 1, 1), date(2030, 12, 31))

    assert len(ids) == 2550


# 특정 페이지 응답이 200이지만 몸체가 깨져있어도(XML 파싱 실패), 그 이전 페이지에서 이미
# 모은 kopis_id는 잃지 않고 반환되는지 테스트 (한 페이지 파싱 실패로 배치 전체가 죽던 버그 회귀 방지)
@pytest.mark.asyncio
async def test_fetch_all_kopis_ids_recovers_from_malformed_page():
    async def _mock_get(url, **kwargs):
        cpage = kwargs["params"]["cpage"]
        if cpage == 1:
            return MagicMock(status_code=200, content=_make_list_xml(["PF_OK_1", "PF_OK_2"]))
        # 2페이지는 순간 오류로 몸체가 깨진 채 200으로 응답
        return MagicMock(status_code=200, content=b"<not-valid-xml")

    mock_client = MagicMock()
    mock_client.get = _mock_get

    ids = await _fetch_all_kopis_ids(mock_client, date(2030, 1, 1), date(2030, 12, 31))

    assert ids == ["PF_OK_1", "PF_OK_2"]


# HTTP 요청 자체가 예외를 던져도(네트워크 오류 등) 그 이전 페이지 결과는 반환되는지 테스트
@pytest.mark.asyncio
async def test_fetch_all_kopis_ids_recovers_from_request_error():
    async def _mock_get(url, **kwargs):
        cpage = kwargs["params"]["cpage"]
        if cpage == 1:
            return MagicMock(status_code=200, content=_make_list_xml(["PF_OK_1"]))
        raise httpx.ConnectError("connection reset")

    mock_client = MagicMock()
    mock_client.get = _mock_get

    ids = await _fetch_all_kopis_ids(mock_client, date(2030, 1, 1), date(2030, 12, 31))

    assert ids == ["PF_OK_1"]


# sync_daily_concerts 테스트

# 1회 실행당 신규 공연 처리 상한 테스트 - 상한 초과분은 다음 실행에서 이어서 처리됨
@pytest.mark.asyncio
async def test_sync_caps_new_concerts_per_run_and_continues_next_run():
    kopis_ids = [f"PF_CAP_{i}_{uuid.uuid4().hex[:6]}" for i in range(5)]
    list_xml = _make_list_xml(kopis_ids)

    async def _mock_get(url, **kwargs):
        parts = url.split("/pblprfr/")
        if len(parts) > 1 and parts[1]:
            kid = parts[1]
            return MagicMock(status_code=200, content=_make_detail_xml(kid, f"아티스트_{kid}"))
        return MagicMock(status_code=200, content=list_xml)

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with (
        patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client),
        patch("app.services.kopis._MAX_NEW_CONCERTS_PER_RUN", 3),
        patch("asyncio.sleep"),
    ):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Concert).where(Concert.kopis_id.in_(kopis_ids)))
            assert len(result.scalars().all()) == 3

        # 다음 실행 -> 상한에 걸려 못 받은 나머지 2건을 이어서 처리
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Concert).where(Concert.kopis_id.in_(kopis_ids)))
            assert len(result.scalars().all()) == 5


# 신규 공연 DB 저장 및 아티스트 정보 포함 테스트
@pytest.mark.asyncio
async def test_sync_creates_new_concert():
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, "배치테스트아티스트")

    with _batch_kopis_mock(list_xml, detail_xml), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
        concert = result.scalar_one_or_none()

    assert concert is not None
    assert "배치테스트아티스트" in concert.artist_name


# 신규 공연 + 팔로우 아티스트 일치 시 뉴스피드 생성 테스트
@pytest.mark.asyncio
async def test_sync_creates_newsfeed_for_followed_artist():
    artist_name = f"배치아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    # 아티스트 팔로우 등록
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, artist_name)

    with _batch_kopis_mock(list_xml, detail_xml), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    # 뉴스피드 생성 확인
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert res.status_code == 200
    feed = res.json()
    assert len(feed) == 1
    assert feed[0]["artist_name"] == artist_name
    assert feed[0]["is_read"] is False


# 미팔로우 아티스트 공연 신규 등록 시 뉴스피드 미생성 테스트
@pytest.mark.asyncio
async def test_sync_no_newsfeed_for_non_followed_artist():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"

    # 다른 아티스트만 팔로우
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": "팔로우안한아티스트"}]},
            headers=headers,
        )

    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, "전혀다른아티스트")

    with _batch_kopis_mock(list_xml, detail_xml), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert res.status_code == 200
    assert res.json() == []


# 신규 공연 + 팔로우 아티스트 일치 시 NEW_CONCERT 알림도 생성되고, 발송 예약 시각이
# 그날 오전 9시(KST)로 잡히는지 테스트 (자정 배치 직후 바로 발송하지 않도록)
@pytest.mark.asyncio
async def test_sync_creates_new_concert_notification_for_followed_artist():
    artist_name = f"배치알림아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, artist_name)

    with _batch_kopis_mock(list_xml, detail_xml), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers=headers)

    assert res.status_code == 200
    new_concert_notifs = [n for n in res.json() if n["type"] == "new_concert"]
    assert len(new_concert_notifs) == 1
    assert artist_name in new_concert_notifs[0]["body"]

    kst = timezone(timedelta(hours=9))
    scheduled_kst = datetime.fromisoformat(new_concert_notifs[0]["scheduled_at"]).astimezone(kst)
    assert (scheduled_kst.hour, scheduled_kst.minute) == (9, 0)


# 같은 공연이 배치에서 두 번 "신규"로 감지돼도(재시도로 인한 중복 호출 등)
# NEW_CONCERT 알림이 중복 생성되지 않는지 테스트
@pytest.mark.asyncio
async def test_schedule_new_concert_notifications_does_not_duplicate():
    from app.services.notification import schedule_new_concert_notifications

    artist_name = f"배치중복아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        me_res = await ac.get("/api/v1/auth/me", headers=headers)
    user_id = uuid.UUID(me_res.json()["id"])

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, artist_name)
    with _batch_kopis_mock(list_xml, detail_xml), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
        concert = result.scalar_one()

        # 배치가 같은 공연을 다시 "신규"로 감지해 두 번째로 호출한 상황을 시뮬레이션
        await schedule_new_concert_notifications(db, concert, [(user_id, artist_name)])
        await db.commit()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers=headers)

    new_concert_notifs = [n for n in res.json() if n["type"] == "new_concert"]
    assert len(new_concert_notifs) == 1


# notification_settings.new_concert를 꺼두면 팔로우 아티스트 신규 공연이어도
# NEW_CONCERT 알림이 생성되지 않는지 테스트 (뉴스피드는 설정과 무관하게 그대로 생성됨)
@pytest.mark.asyncio
async def test_sync_no_new_concert_notification_when_setting_off():
    artist_name = f"배치설정끔아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )
        await ac.patch(
            "/api/v1/settings",
            json={"notification_settings": {"new_concert": False}},
            headers=headers,
        )

    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, artist_name)

    with _batch_kopis_mock(list_xml, detail_xml), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        notif_res = await ac.get("/api/v1/notifications", headers=headers)
        feed_res = await ac.get("/api/v1/social/feed", headers=headers)

    assert [n for n in notif_res.json() if n["type"] == "new_concert"] == []
    assert any(f["artist_name"] == artist_name for f in feed_res.json())


# 기존 공연(artist_name 뒤늦게 채워짐)에 뉴스피드는 생성되지만, "진짜 신규" 발견이 아니므로
# NEW_CONCERT 알림은 생성되지 않는지 테스트 (온디맨드 상세조회로 먼저 생긴 공연 시나리오)
@pytest.mark.asyncio
async def test_sync_no_new_concert_notification_for_existing_concert_backfill():
    artist_name = f"배치백필아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    # 공연을 온디맨드 상세조회로 먼저 생성 (배치가 돌기 전에 이미 DB에 있는 상태)
    detail_xml = _make_detail_xml(kopis_id, artist_name)
    with kopis_mock(detail_xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.get(f"/api/v1/concerts/{kopis_id}", headers=headers)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    with _batch_kopis_mock(_make_list_xml([kopis_id]), detail_xml), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers=headers)

    assert res.status_code == 200
    assert [n for n in res.json() if n["type"] == "new_concert"] == []


# 기존 공연 (artist_name 있음) -> 상세 API 재호출 없이 뉴스피드만 생성 테스트
@pytest.mark.asyncio
async def test_sync_skips_detail_api_for_existing_concert():
    artist_name = f"배치기존아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    # 공연 먼저 DB에 생성 (상세 조회 경로)
    detail_xml = _make_detail_xml(kopis_id, artist_name)
    with kopis_mock(detail_xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.get(f"/api/v1/concerts/{kopis_id}", headers=headers)

    # 아티스트 팔로우 등록 (공연 생성 이후에 팔로우)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    # 상세 API 호출 횟수 추적
    detail_call_count = 0

    async def _mock_get(url, **kwargs):
        nonlocal detail_call_count
        parts = url.split("/pblprfr/")
        if len(parts) > 1 and parts[1]:
            detail_call_count += 1
            return MagicMock(status_code=200, content=detail_xml)
        return MagicMock(status_code=200, content=_make_list_xml([kopis_id]))

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    # 상세 API 재호출 없음
    assert detail_call_count == 0

    # 뉴스피드는 생성됨
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert any(f["artist_name"] == artist_name for f in res.json())


# KOPIS 빈 응답 시 아무 변화 없음 테스트
@pytest.mark.asyncio
async def test_sync_handles_empty_kopis_response():
    empty_xml = b'<?xml version="1.0" encoding="UTF-8"?><dbs></dbs>'

    with _batch_kopis_mock(empty_xml, b""), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    # 예외 없이 정상 종료됨 (assert 없음 — 예외 발생 시 테스트 실패)


# 상세 조회가 일시적으로 실패(400)했다가 재시도 시 성공하면 공연이 정상 저장되는지 테스트
@pytest.mark.asyncio
async def test_sync_retries_transient_detail_failure():
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, "재시도아티스트")

    call_count = 0

    async def _mock_get(url, **kwargs):
        nonlocal call_count
        parts = url.split("/pblprfr/")
        if len(parts) > 1 and parts[1]:
            call_count += 1
            if call_count == 1:
                return MagicMock(status_code=400, content=b"")
            return MagicMock(status_code=200, content=detail_xml)
        return MagicMock(status_code=200, content=list_xml)

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with (
        patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client),
        patch("asyncio.sleep"),
    ):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    assert call_count == 2

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
        concert = result.scalar_one_or_none()

    assert concert is not None
    assert "재시도아티스트" in concert.artist_name


# 상세 조회가 재시도 횟수만큼 계속 실패하면 해당 공연은 포기하고 넘어가는지 테스트
@pytest.mark.asyncio
async def test_sync_gives_up_after_max_detail_retries():
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    list_xml = _make_list_xml([kopis_id])

    call_count = 0

    async def _mock_get(url, **kwargs):
        nonlocal call_count
        parts = url.split("/pblprfr/")
        if len(parts) > 1 and parts[1]:
            call_count += 1
            return MagicMock(status_code=400, content=b"")
        return MagicMock(status_code=200, content=list_xml)

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with (
        patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client),
        patch("asyncio.sleep"),
    ):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    assert call_count == 3

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
        concert = result.scalar_one_or_none()

    assert concert is None


# KOPIS 목록 API 실패 시 조기 종료 테스트
@pytest.mark.asyncio
async def test_sync_handles_kopis_list_api_failure():
    error_response = MagicMock()
    error_response.status_code = 500
    error_response.content = b""

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=error_response)

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    # 예외 없이 정상 종료됨


# refresh_ticketing_links 테스트
# (콘서트 상세정보를 최초 1회만 동기화하고 다시 안 보는 기존 구조 때문에, 얼리버드/블라인드
# 판매 시점에 캡처된 예매 링크가 실제 판매 링크로 바뀌어도 영원히 못 따라가는 문제 대응)

# KOPIS 상세 API의 relates에 예매링크가 있는 XML 생성 (site_name -> url 딕셔너리 기반)
def _make_detail_xml_with_relates(kopis_id: str, relates: dict[str, str]) -> bytes:
    relates_xml = "".join(
        f"<relate><relatenm>{name}</relatenm><relateurl>{url}</relateurl></relate>"
        for name, url in relates.items()
    )
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.30</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f"<genrenm>대중음악</genrenm>"
        f"<prfcast></prfcast>"
        f"<pcseguidance></pcseguidance>"
        f"<sty></sty>"
        f"<relates>{relates_xml}</relates>"
        f"</db></dbs>"
    ).encode("utf-8")


# KOPIS 쪽 relate 링크가 바뀌었으면(블라인드→실제 판매 등) ticketing_links를 갱신하고 True를 반환하는지 테스트
@pytest.mark.asyncio
async def test_refresh_ticketing_links_updates_when_changed():
    from app.services.kopis import refresh_ticketing_links

    concert = MagicMock()
    concert.kopis_id = "PF_REFRESH_1"
    concert.ticketing_links = {"INTERPARK": "https://tickets.interpark.com/goods/OLD_BLIND"}
    concert.kopis_detail_synced_at = None

    detail_xml = _make_detail_xml_with_relates(
        "PF_REFRESH_1", {"놀유니버스": "https://tickets.interpark.com/goods/NEW_REAL"}
    )
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=MagicMock(status_code=200, content=detail_xml))

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        changed = await refresh_ticketing_links(concert)

    assert changed is True
    assert concert.ticketing_links == {"INTERPARK": "https://tickets.interpark.com/goods/NEW_REAL"}
    assert concert.kopis_detail_synced_at is not None


# KOPIS 쪽 링크가 기존과 동일하면 아무것도 안 바꾸고 False를 반환하는지 테스트
@pytest.mark.asyncio
async def test_refresh_ticketing_links_no_change_returns_false():
    from app.services.kopis import refresh_ticketing_links

    concert = MagicMock()
    concert.kopis_id = "PF_REFRESH_2"
    concert.ticketing_links = {"INTERPARK": "https://tickets.interpark.com/goods/SAME"}
    concert.kopis_detail_synced_at = None

    detail_xml = _make_detail_xml_with_relates(
        "PF_REFRESH_2", {"놀유니버스": "https://tickets.interpark.com/goods/SAME"}
    )
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=MagicMock(status_code=200, content=detail_xml))

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        changed = await refresh_ticketing_links(concert)

    assert changed is False
    assert concert.ticketing_links == {"INTERPARK": "https://tickets.interpark.com/goods/SAME"}
    assert concert.kopis_detail_synced_at is None


# KOPIS가 relates를 아예 안 주면(빈 응답) 기존 링크를 그대로 유지하는지 테스트 - 크롤링
# 대상을 아예 잃어버리는 회귀 방지
@pytest.mark.asyncio
async def test_refresh_ticketing_links_empty_relates_keeps_existing():
    from app.services.kopis import refresh_ticketing_links

    concert = MagicMock()
    concert.kopis_id = "PF_REFRESH_3"
    concert.ticketing_links = {"INTERPARK": "https://tickets.interpark.com/goods/KEEP_ME"}
    concert.kopis_detail_synced_at = None

    detail_xml = _make_detail_xml_with_relates("PF_REFRESH_3", {})
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=MagicMock(status_code=200, content=detail_xml))

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        changed = await refresh_ticketing_links(concert)

    assert changed is False
    assert concert.ticketing_links == {"INTERPARK": "https://tickets.interpark.com/goods/KEEP_ME"}


# KOPIS API 호출 자체가 실패해도 예외를 밖으로 던지지 않고 기존 링크를 유지하는지 테스트
# (배치 하나에서 실패해도 다른 대상 처리가 멈추면 안 됨)
@pytest.mark.asyncio
async def test_refresh_ticketing_links_api_failure_keeps_existing():
    from app.services.kopis import refresh_ticketing_links

    concert = MagicMock()
    concert.kopis_id = "PF_REFRESH_4"
    concert.ticketing_links = {"INTERPARK": "https://tickets.interpark.com/goods/KEEP_ME"}
    concert.kopis_detail_synced_at = None

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=MagicMock(status_code=502, content=b""))

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        changed = await refresh_ticketing_links(concert)

    assert changed is False
    assert concert.ticketing_links == {"INTERPARK": "https://tickets.interpark.com/goods/KEEP_ME"}
