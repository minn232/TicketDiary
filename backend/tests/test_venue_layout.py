import uuid
from unittest.mock import patch

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.concert import Concert
from conftest import _get_token, kopis_mock

_LLM_API_KEY = "test-llm-key"


# 헬퍼

def _make_kopis_xml(kopis_id: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.01</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f'<poster>https://example.com/poster.jpg</poster>'
        f"<genrenm>대중음악</genrenm>"
        f"<prfstate>공연예정</prfstate>"
        f"<prfcast>테스트아티스트</prfcast>"
        f"<pcseguidance>R석 110,000원</pcseguidance>"
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


async def _create_concert(kopis_id: str) -> str:
    token = await _get_token()
    with kopis_mock(_make_kopis_xml(kopis_id)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.status_code == 200
    return response.json()["id"]


def _llm_headers():
    return {"Authorization": f"Bearer {_LLM_API_KEY}"}


# prfcast를 비워서 출연진 없이 공연 생성 (포스터 추출 실패한 페스티벌 등을 시뮬레이션)
def _make_kopis_xml_no_artist(kopis_id: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.03</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f'<poster>https://example.com/poster.jpg</poster>'
        f"<genrenm>대중음악</genrenm>"
        f"<prfstate>공연예정</prfstate>"
        f"<prfcast></prfcast>"
        f"<pcseguidance>R석 110,000원</pcseguidance>"
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


async def _create_concert_without_artist(kopis_id: str) -> str:
    token = await _get_token()
    with kopis_mock(_make_kopis_xml_no_artist(kopis_id)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.status_code == 200
    assert response.json()["artist_name"] == []
    return response.json()["id"]


# venue-layout 조회 테스트

# venue-layout 없는 공연 조회 시 404
@pytest.mark.asyncio
async def test_get_venue_layout_not_found():
    concert_id = await _create_concert("PF_VL_GET_001")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/venue-layout",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 404


# 존재하지 않는 concert_id로 조회 시 404
@pytest.mark.asyncio
async def test_get_venue_layout_concert_not_found():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{uuid.uuid4()}/venue-layout",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 404


# crawl-result 수신 후 venue-layout 저장 + 조회 성공
@pytest.mark.asyncio
async def test_get_venue_layout_after_crawl_result():
    concert_id = await _create_concert("PF_VL_GET_002")
    token = await _get_token()

    crawl_body = {
        "venue_layout": {
            "image_url": "https://s3.example.com/layout.png",
            "layout_data": {"sections": ["R석", "S석"]},
        }
    }

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            post_res = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=crawl_body,
                headers=_llm_headers(),
            )

    assert post_res.status_code == 200
    assert "venue_layout" in post_res.json()["updated"]

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        get_res = await ac.get(
            f"/api/v1/concerts/{concert_id}/venue-layout",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert get_res.status_code == 200
    data = get_res.json()
    assert data["concert_id"] == concert_id
    assert data["image_url"] == "https://s3.example.com/layout.png"
    assert data["layout_data"] == {"sections": ["R석", "S석"]}


# crawl-result 테스트

# timetable만 포함된 결과 수신
@pytest.mark.asyncio
async def test_crawl_result_timetable_only():
    concert_id = await _create_concert("PF_CR_TT_001")

    body = {
        "timetable": [
            {"date": "2030-06-01", "time": None, "stage": "TOUCH", "event": "아티스트A 17:00 - 17:40 (40)"},
            {"date": "2030-06-01", "time": None, "stage": "TOUCH", "event": "아티스트B 18:00 - 18:50 (50)"},
        ]
    }

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert response.json()["updated"] == ["timetable"]


# prices만 포함된 결과 수신 → Concert.price 업데이트
# kopis_id를 매번 새로 생성함 - 이 테스트 스위트는 트랜잭션 롤백 없이 실제 로컬 DB를 그대로
# 쓰고, crawl-result의 prices는 이제 KOPIS 값과 겹치지 않는 seat_type만 추가하는 병합 방식이라
# (2026-08-06), 고정 kopis_id를 재사용하면 이전 실행에서 이미 추가된 S석이 남아있어 재실행 시
# "새로 추가할 게 없다"고 판단해 실패함
@pytest.mark.asyncio
async def test_crawl_result_prices_only():
    concert_id = await _create_concert(f"PF_CR_PRICE_{uuid.uuid4().hex[:8]}")

    body = {
        "prices": [
            {"seat_type": "R석", "price": 110000},
            {"seat_type": "S석", "price": 88000},
        ]
    }

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert response.json()["updated"] == ["prices"]


# KOPIS가 이미 채운 R석과 대소문자/공백만 다른 표기("r 석")로 크롤링 결과가 들어오면 같은
# 좌석으로 인식해서 KOPIS 값을 유지(덮어쓰지 않음)하고, 진짜 새로운 seat_type(얼리버드)만
# 추가하는지 테스트 (2026-08-06)
@pytest.mark.asyncio
async def test_crawl_result_prices_seat_type_normalized_dedup():
    concert_id = await _create_concert(f"PF_CR_PRICE_NORM_{uuid.uuid4().hex[:8]}")

    body = {
        "prices": [
            {"seat_type": "r 석", "price": 999999},  # KOPIS의 "R석"(110,000원)과 같은 좌석 표기 변형
            {"seat_type": "얼리버드", "price": 50000},  # KOPIS엔 없는 진짜 새 항목
        ]
    }

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert response.json()["updated"] == ["prices"]

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        concert = result.scalar_one()

    prices_by_type = {p["seat_type"]: p["price"] for p in concert.price}
    assert prices_by_type["R석"] == 110000  # KOPIS 값 그대로 유지, 999999로 안 덮어써짐
    assert "r 석" not in prices_by_type  # 크롤링 쪽 표기로 중복 추가되지 않음
    assert prices_by_type["얼리버드"] == 50000  # 새 항목은 정상 추가


# crawl-result의 artist_name으로 아티스트가 비어있던 공연이 채워지는지 테스트
# (포스터 기반 추출이 실패하기 쉬운 페스티벌 등의 대체 경로)
@pytest.mark.asyncio
async def test_crawl_result_artist_name_fills_when_empty():
    concert_id = await _create_concert_without_artist(f"PF_CR_ARTIST_{uuid.uuid4().hex[:6]}")

    body = {"artist_name": ["아티스트A", "아티스트B"]}
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert "artist_name" in response.json()["updated"]

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        concert = result.scalar_one()
    assert set(concert.artist_name) == {"아티스트A", "아티스트B"}


# 이미 포스터 기반 추출(prfcast/artist-result)로 아티스트가 채워져 있어도 크롤링 결과로 온 새
# 아티스트는 합집합으로 병합되는지 테스트 (페스티벌 1차/2차/3차 라인업처럼 시간차를 두고 늘어나는 경우 대응)
@pytest.mark.asyncio
async def test_crawl_result_artist_name_merges_with_existing():
    concert_id = await _create_concert(f"PF_CR_ARTIST_MERGE_{uuid.uuid4().hex}")  # prfcast="테스트아티스트"로 이미 채워짐

    body = {"artist_name": ["다른아티스트"]}
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert "artist_name" in response.json()["updated"]

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        concert = result.scalar_one()
    assert set(concert.artist_name) == {"테스트아티스트", "다른아티스트"}


# 크롤링 결과로 온 아티스트가 기존과 완전히 동일하면(병합 결과가 안 바뀌면) updated에 안 잡히는지 테스트
@pytest.mark.asyncio
async def test_crawl_result_artist_name_no_change_when_already_merged():
    concert_id = await _create_concert(f"PF_CR_ARTIST_SAME_{uuid.uuid4().hex}")  # prfcast="테스트아티스트"로 이미 채워짐

    body = {"artist_name": ["테스트아티스트"]}
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert "artist_name" not in response.json()["updated"]


# 크롤링 결과로 아티스트가 임계치(5명) 이상 채워지면 event_type이 SOLO->FESTIVAL로 승격되고,
# 이미 등록된 티켓의 첫콘/막콘 값이 재계산(백필)되는지 테스트
@pytest.mark.asyncio
async def test_crawl_result_upgrades_event_type_and_backfills_first_last_day():
    concert_id = await _create_concert_without_artist(f"PF_CR_UPGRADE_{uuid.uuid4().hex[:6]}")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    # SOLO로 추측된 상태에서 첫날 관람으로 등록 -> is_first_day=True로 계산됨
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "attended_date": "2030-06-01"},
            headers=headers,
        )
    assert ticket_res.json()["is_first_day"] is True

    artists = [f"아티스트{uuid.uuid4().hex}" for _ in range(5)]
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"artist_name": artists},
                headers=_llm_headers(),
            )

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        concert = result.scalar_one()
    assert concert.event_type == "FESTIVAL"

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_get = await ac.get(f"/api/v1/tickets/{ticket_res.json()['id']}", headers=headers)
    assert ticket_get.json()["is_first_day"] is None
    assert ticket_get.json()["is_last_day"] is None


# 아티스트가 임계치(5명) 미만이면 event_type이 승격되지 않아야 함(밴드 멤버 등으로 소수만
# 확인된 상태 - 페스티벌 아닌데 잘못 승격되는 것 방지)
@pytest.mark.asyncio
async def test_crawl_result_does_not_upgrade_event_type_below_threshold():
    concert_id = await _create_concert_without_artist(f"PF_CR_NOUPGRADE_{uuid.uuid4().hex[:6]}")

    artists = [f"아티스트{uuid.uuid4().hex}" for _ in range(4)]
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"artist_name": artists},
                headers=_llm_headers(),
            )

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        concert = result.scalar_one()
    assert concert.event_type == "SOLO"


# timetable + prices + venue_layout 모두 포함된 결과 수신
@pytest.mark.asyncio
async def test_crawl_result_all_fields():
    # kopis_id를 매번 새로 생성함 - test_crawl_result_prices_only와 같은 이유
    # (prices 병합 방식이 고정 ID 재사용 시 재실행에 취약함, 2026-08-06)
    concert_id = await _create_concert(f"PF_CR_ALL_{uuid.uuid4().hex[:8]}")

    body = {
        "timetable": [{"date": "2030-06-01", "time": None, "stage": None, "event": "공연 시작"}],
        "prices": [{"seat_type": "VIP석", "price": 150000}],
        "venue_layout": {
            "image_url": "https://s3.example.com/layout-all.png",
            "layout_data": {"sections": ["VIP석"]},
        },
    }

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert set(response.json()["updated"]) == {"timetable", "prices", "venue_layout"}


# 아무 필드 없는 빈 body 수신
@pytest.mark.asyncio
async def test_crawl_result_empty_body():
    concert_id = await _create_concert("PF_CR_EMPTY_001")

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={},
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert response.json()["updated"] == []


# 잘못된 API Key → 401
@pytest.mark.asyncio
async def test_crawl_result_invalid_api_key():
    concert_id = await _create_concert("PF_CR_AUTH_001")

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={},
                headers={"Authorization": "Bearer wrong-key"},
            )

    assert response.status_code == 401


# venue_layout upsert (두 번째 요청은 update)
@pytest.mark.asyncio
async def test_crawl_result_venue_layout_upsert():
    concert_id = await _create_concert("PF_CR_UPSERT_001")

    first_body = {
        "venue_layout": {
            "image_url": "https://s3.example.com/v1.png",
            "layout_data": {"sections": ["R석"]},
        }
    }
    second_body = {
        "venue_layout": {
            "image_url": "https://s3.example.com/v2.png",
            "layout_data": {"sections": ["R석", "S석"]},
        }
    }

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res1 = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=first_body,
                headers=_llm_headers(),
            )
            res2 = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=second_body,
                headers=_llm_headers(),
            )

    assert res1.status_code == 200
    assert res2.status_code == 200

    token = await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        get_res = await ac.get(
            f"/api/v1/concerts/{concert_id}/venue-layout",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert get_res.status_code == 200
    data = get_res.json()
    assert data["image_url"] == "https://s3.example.com/v2.png"
    assert data["layout_data"] == {"sections": ["R석", "S석"]}


# ticketing_date 수신 → Concert.ticketing_date 저장 + "ticketing_date" in updated
@pytest.mark.asyncio
async def test_crawl_result_ticketing_date_saved():
    from app.core.database import AsyncSessionLocal
    from app.models.concert import Concert
    from sqlalchemy import select
    import uuid as _uuid

    concert_id = await _create_concert("PF_CR_TD_001")

    body = {"ticketing_date": "2030-05-01"}

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert "ticketing_date" in response.json()["updated"]

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == _uuid.UUID(concert_id)))
        concert = result.scalar_one()

    assert concert.ticketing_date is not None
    assert concert.ticketing_date.year == 2030
    assert concert.ticketing_date.month == 5
    assert concert.ticketing_date.day == 1


# 잘못된 ticketing_date 형식은 400이 아닌 updated에서 누락
@pytest.mark.asyncio
async def test_crawl_result_invalid_ticketing_date_ignored():
    concert_id = await _create_concert("PF_CR_TD_INVALID_001")

    body = {"ticketing_date": "not-a-date"}

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert "ticketing_date" not in response.json()["updated"]


# delivery_date 수신 → Concert.delivery_date 저장 + "delivery_date" in updated
@pytest.mark.asyncio
async def test_crawl_result_delivery_date_saved():
    from app.core.database import AsyncSessionLocal
    from app.models.concert import Concert
    from sqlalchemy import select
    import uuid as _uuid

    concert_id = await _create_concert("PF_CR_DD_001")

    body = {"delivery_date": "2030-04-20"}

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert "delivery_date" in response.json()["updated"]

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == _uuid.UUID(concert_id)))
        concert = result.scalar_one()

    assert concert.delivery_date is not None
    assert concert.delivery_date.year == 2030
    assert concert.delivery_date.month == 4
    assert concert.delivery_date.day == 20


# 잘못된 delivery_date 형식은 400이 아닌 updated에서 누락
@pytest.mark.asyncio
async def test_crawl_result_invalid_delivery_date_ignored():
    concert_id = await _create_concert("PF_CR_DD_INVALID_001")

    body = {"delivery_date": "not-a-date"}

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    assert response.status_code == 200
    assert "delivery_date" not in response.json()["updated"]


# delivery_date 수신 시, 이미 등록됐지만 자체 delivery_date가 없는 티켓에 백필되고
# DELIVERY_DAY 알림이 생성되는지 테스트 (찜/티켓등록 시점엔 몰랐던 배송일을 크롤링이 나중에 채워주는 시나리오)
@pytest.mark.asyncio
async def test_crawl_result_delivery_date_backfills_existing_ticket():
    # 매 실행마다 겹치지 않는 kopis_id 사용 (로컬 DB는 테스트 간 rollback되지 않고 실제로
    # upsert된 채 남으므로, 고정 ID를 쓰면 이전 실행의 delivery_date 잔여 데이터와 충돌함)
    concert_id = await _create_concert(f"PF_CR_DD_BACKFILL_{uuid.uuid4().hex[:10]}")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id},  # delivery_date 없이 등록(OCR로 못 뽑은 경우)
            headers=headers,
        )
    assert ticket_res.json()["delivery_date"] is None

    body = {"delivery_date": "2030-05-10"}
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json=body,
                headers=_llm_headers(),
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_get = await ac.get(f"/api/v1/tickets/{ticket_res.json()['id']}", headers=headers)
        notif_res = await ac.get("/api/v1/notifications", headers=headers)

    assert ticket_get.json()["delivery_date"][:10] == "2030-05-10"
    assert any(n["type"] == "delivery_day" for n in notif_res.json())


# 크롤링이 delivery_date를 두 번째로 다시 보내(정정) 이전 값과 다르면, 첫 번째 크롤링 값으로
# 채워졌던(delivery_date_synced=True) 티켓도 새 값으로 갱신되는지 테스트 (정정이 씹히던 버그 회귀 방지)
@pytest.mark.asyncio
async def test_crawl_result_delivery_date_correction_updates_synced_ticket():
    concert_id = await _create_concert(f"PF_CR_DD_CORRECT_{uuid.uuid4().hex[:10]}")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id},
            headers=headers,
        )

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"delivery_date": "2030-05-10"},
                headers=_llm_headers(),
            )
            # 두 번째 크롤링(정정): 실제 배송일이 05-10이 아니라 05-25였던 경우
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"delivery_date": "2030-05-25"},
                headers=_llm_headers(),
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_get = await ac.get(f"/api/v1/tickets/{ticket_res.json()['id']}", headers=headers)

    assert ticket_get.json()["delivery_date"][:10] == "2030-05-25"


# 유저가 OCR/직접 입력으로 delivery_date를 채운 티켓은, 이후 크롤링이 concert.delivery_date를
# 다른 값으로 정정해도 덮어써지지 않는지 테스트 (유저 입력 우선순위 유지 회귀 방지)
@pytest.mark.asyncio
async def test_crawl_result_delivery_date_correction_does_not_override_user_value():
    concert_id = await _create_concert(f"PF_CR_DD_USER_{uuid.uuid4().hex[:10]}")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "delivery_date": "2030-05-15T00:00:00Z"},
            headers=headers,
        )

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"delivery_date": "2030-05-25"},
                headers=_llm_headers(),
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_get = await ac.get(f"/api/v1/tickets/{ticket_res.json()['id']}", headers=headers)

    assert ticket_get.json()["delivery_date"][:10] == "2030-05-15"


# 같은 공연에 티켓을 등록한 유저가 여럿일 때, 크롤링 결과 수신 한 번으로 전원 배송일이
# 백필되고 각자 DELIVERY_DAY 알림도 생성되는지 테스트 (배치 처리로 바꾸면서 일부만 처리되는
# 회귀가 없는지 확인)
@pytest.mark.asyncio
async def test_crawl_result_delivery_date_backfills_multiple_tickets():
    concert_id = await _create_concert(f"PF_CR_DD_MULTI_{uuid.uuid4().hex[:10]}")
    tokens = [await _get_token() for _ in range(3)]
    ticket_ids = []

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        for token in tokens:
            res = await ac.post(
                "/api/v1/tickets",
                json={"concert_id": concert_id},
                headers={"Authorization": f"Bearer {token}"},
            )
            assert res.json()["delivery_date"] is None
            ticket_ids.append(res.json()["id"])

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"delivery_date": "2030-05-10"},
                headers=_llm_headers(),
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        for token, ticket_id in zip(tokens, ticket_ids):
            headers = {"Authorization": f"Bearer {token}"}
            ticket_get = await ac.get(f"/api/v1/tickets/{ticket_id}", headers=headers)
            notif_res = await ac.get("/api/v1/notifications", headers=headers)

            assert ticket_get.json()["delivery_date"][:10] == "2030-05-10"
            assert any(n["type"] == "delivery_day" for n in notif_res.json())
