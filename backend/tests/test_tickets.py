import uuid

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from conftest import _get_token, kopis_mock


# 헬퍼

# KOPIS 공연 정보 XML 생성
def _make_kopis_xml(kopis_id: str, name: str, start: str, end: str, dtguidance: str = "") -> bytes:
    dt = f"<dtguidance>{dtguidance}</dtguidance>" if dtguidance else ""
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{name}</prfnm>"
        f"<prfpdfrom>{start}</prfpdfrom>"
        f"<prfpdto>{end}</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f'<poster>https://example.com/poster.jpg</poster>'
        f"<genrenm>팝</genrenm>"
        f"<prfstate>공연예정</prfstate>"
        f"<prfcast>테스트아티스트</prfcast>"
        f"<pcseguidance>R석 110,000원</pcseguidance>"
        f"{dt}"
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# 공연 생성 (kopis_mock)
async def _create_concert(
    kopis_id: str, start: str = "2030.06.01", end: str = "2030.06.30", dtguidance: str = ""
) -> str:
    token = await _get_token()
    xml = _make_kopis_xml(kopis_id, f"{kopis_id} 공연", start, end, dtguidance)
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.status_code == 200
    return response.json()["id"]


# 티켓 등록 테스트

# concert_id로 티켓 등록 성공 테스트
@pytest.mark.asyncio
async def test_create_ticket_with_concert_id():
    concert_id = await _create_concert("PF_T_CID_001")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "seat_type": "R석", "price": 110000},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    data = response.json()
    assert data["concert_id"] == concert_id
    assert data["status"] == "before_concert"
    assert data["seat_type"] == "R석"
    assert data["concert"] is not None


# kopis_id로 티켓 등록 성공 테스트
@pytest.mark.asyncio
async def test_create_ticket_with_kopis_id():
    await _create_concert("PF_T_KID_001")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"kopis_id": "PF_T_KID_001"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    assert response.json()["concert"] is not None


# concert.start_time이 비어있을 때 OCR 시간으로 최초 백필되는지 테스트
@pytest.mark.asyncio
async def test_create_ticket_backfills_concert_start_time_from_ocr():
    concert_id = await _create_concert("PF_T_TIME_001")  # dtguidance 없음 -> concert.start_time None
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "start_time": "19:00"},
            headers={"Authorization": f"Bearer {token}"},
        )
        detail = await ac.get(
            "/api/v1/concerts/PF_T_TIME_001",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    assert response.json()["start_time"] == "19:00"
    assert detail.json()["start_time"] == "19:00"


# OCR 시간과 KOPIS 시간이 다르면 OCR(실물 티켓) 값을 신뢰해서 저장하는지 테스트
@pytest.mark.asyncio
async def test_create_ticket_prefers_ocr_time_on_mismatch():
    concert_id = await _create_concert(
        "PF_T_TIME_002", dtguidance="화~금 19:30"
    )  # concert.start_time == "19:30"
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "start_time": "20:00"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    assert response.json()["start_time"] == "20:00"


# OCR 시간이 없으면 concert.start_time으로 폴백되는지 테스트
@pytest.mark.asyncio
async def test_create_ticket_falls_back_to_concert_start_time():
    concert_id = await _create_concert(
        "PF_T_TIME_003", dtguidance="화~금 19:30"
    )
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    assert response.json()["start_time"] == "19:30"


# OCR 좌석등급이 깨져서(예: "아지정석") 크롤링 가격표(concert.price)의 등급명과 다르면
# 크롤링 값으로 교정해서 저장하는지 테스트 (구역/열/번 등 나머지 디테일은 그대로 보존)
@pytest.mark.asyncio
async def test_create_ticket_corrects_seat_type_from_crawled_price():
    concert_id = await _create_concert("PF_T_SEAT_001")  # pcseguidance="R석 110,000원" -> price=[{"seat_type": "R석", ...}]
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "seat_type": "이R석 A구역 12열 15번"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    assert response.json()["seat_type"] == "R석 A구역 12열 15번"


# OCR 좌석등급이 크롤링 가격표와 이미 일치하면 그대로 저장(불필요한 교정 없음) 테스트
@pytest.mark.asyncio
async def test_create_ticket_keeps_seat_type_when_already_matching():
    concert_id = await _create_concert("PF_T_SEAT_002")  # price=[{"seat_type": "R석", ...}]
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "seat_type": "R석 A구역 12열 15번"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    assert response.json()["seat_type"] == "R석 A구역 12열 15번"


# 크롤링 가격표 등급명과 확실히 다른(유사도가 너무 낮은) OCR 값은 잘못 덮어쓰지 않고
# 그대로 두는지 테스트 (억지 교정으로 오히려 정확도를 해치지 않기 위한 안전장치)
@pytest.mark.asyncio
async def test_create_ticket_seat_type_unchanged_when_no_confident_match():
    concert_id = await _create_concert("PF_T_SEAT_003")  # price=[{"seat_type": "R석", ...}]
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "seat_type": "스탠딩석"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    assert response.json()["seat_type"] == "스탠딩석"


# 배송일 OCR 값이 없으면 크롤링으로 채워진 concert.delivery_date로 폴백되는지 테스트
@pytest.mark.asyncio
async def test_create_ticket_falls_back_to_concert_delivery_date():
    from app.core.database import AsyncSessionLocal
    from app.models.concert import Concert
    from sqlalchemy import select
    from datetime import datetime, timezone as tz
    import uuid as _uuid

    concert_id = await _create_concert("PF_T_DELIVERY_001")
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == _uuid.UUID(concert_id)))
        concert = result.scalar_one()
        concert.delivery_date = datetime(2030, 5, 10, tzinfo=tz.utc)
        await db.commit()

    token = await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    assert response.json()["delivery_date"][:10] == "2030-05-10"


# 배송일 OCR 값이 있으면 크롤링 값(concert.delivery_date)보다 우선하는지 테스트
@pytest.mark.asyncio
async def test_create_ticket_prefers_ocr_delivery_date_over_concert():
    from app.core.database import AsyncSessionLocal
    from app.models.concert import Concert
    from sqlalchemy import select
    from datetime import datetime, timezone as tz
    import uuid as _uuid

    concert_id = await _create_concert("PF_T_DELIVERY_002")
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == _uuid.UUID(concert_id)))
        concert = result.scalar_one()
        concert.delivery_date = datetime(2030, 5, 10, tzinfo=tz.utc)
        await db.commit()

    token = await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "delivery_date": "2030-05-15T00:00:00Z"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    assert response.json()["delivery_date"][:10] == "2030-05-15"


# 존재하지 않는 concert_id로 등록 404 테스트
@pytest.mark.asyncio
async def test_create_ticket_concert_not_found_404():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": str(uuid.uuid4())},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 404


# 동일 유저-공연 중복 등록 409 테스트
@pytest.mark.asyncio
async def test_create_ticket_duplicate_409():
    concert_id = await _create_concert("PF_T_DUP_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res1 = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        res2 = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)

    assert res1.status_code == 201
    assert res2.status_code == 409


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_create_ticket_no_auth_401():
    concert_id = await _create_concert("PF_T_NOAUTH_001")

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/tickets", json={"concert_id": concert_id})

    assert response.status_code == 401


# 티켓 목록 조회 테스트

# 티켓 없을 때 빈 배열 반환 테스트
@pytest.mark.asyncio
async def test_list_tickets_empty():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get("/api/v1/tickets", headers={"Authorization": f"Bearer {token}"})

    assert response.status_code == 200
    assert response.json() == []


# 티켓 정렬 테스트 (공연일 기준 현재와 가까운 순, 공연전 티켓 먼저)
@pytest.mark.asyncio
async def test_list_tickets_sorting():
    near_id = await _create_concert("PF_SORT_NEAR", "2030.07.01", "2030.07.01")
    far_id = await _create_concert("PF_SORT_FAR", "2040.01.01", "2040.01.01")
    past_id = await _create_concert("PF_SORT_PAST", "2000.01.01", "2000.01.01")

    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res_near = await ac.post("/api/v1/tickets", json={"concert_id": near_id}, headers=headers)
        res_far = await ac.post("/api/v1/tickets", json={"concert_id": far_id}, headers=headers)
        res_past = await ac.post("/api/v1/tickets", json={"concert_id": past_id}, headers=headers)

        assert res_near.status_code == 201
        assert res_far.status_code == 201
        assert res_past.status_code == 201

        response = await ac.get("/api/v1/tickets", headers=headers)

    assert response.status_code == 200
    tickets = response.json()
    assert len(tickets) == 3

    concert_ids = [t["concert_id"] for t in tickets]
    assert concert_ids.index(near_id) < concert_ids.index(past_id)
    assert concert_ids.index(far_id) < concert_ids.index(past_id)
    assert concert_ids.index(near_id) < concert_ids.index(far_id)


# 티켓 상세 조회 테스트

# 티켓 상세 조회 성공 테스트
@pytest.mark.asyncio
async def test_get_ticket_success():
    concert_id = await _create_concert("PF_GET_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        create_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        ticket_id = create_res.json()["id"]

        response = await ac.get(f"/api/v1/tickets/{ticket_id}", headers=headers)

    assert response.status_code == 200
    data = response.json()
    assert data["id"] == ticket_id
    assert data["concert"] is not None


# 다른 유저의 티켓 조회 404 테스트
@pytest.mark.asyncio
async def test_get_ticket_other_user_404():
    concert_id = await _create_concert("PF_GET_OTHER_001")
    token_a = await _get_token()
    token_b = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        create_res = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id},
            headers={"Authorization": f"Bearer {token_a}"},
        )
        ticket_id = create_res.json()["id"]

        response = await ac.get(
            f"/api/v1/tickets/{ticket_id}",
            headers={"Authorization": f"Bearer {token_b}"},
        )

    assert response.status_code == 404


# 티켓 수정 테스트

# 티켓 정보 수정 성공 테스트
@pytest.mark.asyncio
async def test_update_ticket_fields():
    concert_id = await _create_concert("PF_UPDATE_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        create_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        ticket_id = create_res.json()["id"]

        response = await ac.patch(
            f"/api/v1/tickets/{ticket_id}",
            json={
                "seat_type": "VIP",
                "price": 150000,
                "review": "공연공연",
                "concert_photo_urls": ["https://example.com/photo1.jpg"],
                "is_first_day": True,
            },
            headers=headers,
        )

    assert response.status_code == 200
    data = response.json()
    assert data["seat_type"] == "VIP"
    assert data["price"] == 150000
    assert data["review"] == "공연공연"
    assert data["concert_photo_urls"] == ["https://example.com/photo1.jpg"]
    assert data["is_first_day"] is True


# 티켓 삭제 테스트

# 티켓 삭제 성공 테스트 (삭제 후 조회 시 404)
@pytest.mark.asyncio
async def test_delete_ticket_success():
    concert_id = await _create_concert("PF_DEL_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        create_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        ticket_id = create_res.json()["id"]

        del_response = await ac.delete(f"/api/v1/tickets/{ticket_id}", headers=headers)
        get_response = await ac.get(f"/api/v1/tickets/{ticket_id}", headers=headers)

    assert del_response.status_code == 204
    assert get_response.status_code == 404


# 존재하지 않는 티켓 삭제 404 테스트
@pytest.mark.asyncio
async def test_delete_ticket_not_found_404():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.delete(
            f"/api/v1/tickets/{uuid.uuid4()}",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 404
