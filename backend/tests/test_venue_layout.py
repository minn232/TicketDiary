import uuid
from unittest.mock import patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
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
        f"<genrenm>팝</genrenm>"
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
@pytest.mark.asyncio
async def test_crawl_result_prices_only():
    concert_id = await _create_concert("PF_CR_PRICE_001")

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


# timetable + prices + venue_layout 모두 포함된 결과 수신
@pytest.mark.asyncio
async def test_crawl_result_all_fields():
    concert_id = await _create_concert("PF_CR_ALL_001")

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
