import uuid

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from app.models.concert import Concert, EventType
from app.services.ticket import upgrade_event_type_if_multi_artist
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
        f"<genrenm>대중음악</genrenm>"
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


# 첫콘/막콘 자동 판정 테스트

# attended_date가 concert.start_date와 같으면 첫콘으로 자동 판정되는지 테스트
@pytest.mark.asyncio
async def test_create_ticket_detects_first_day():
    concert_id = await _create_concert("PF_T_FIRSTDAY_001", start="2030.06.01", end="2030.06.03")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "attended_date": "2030-06-01"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    data = response.json()
    assert data["is_first_day"] is True
    assert data["is_last_day"] is False


# attended_date가 concert.end_date와 같으면 막콘으로 자동 판정되는지 테스트
@pytest.mark.asyncio
async def test_create_ticket_detects_last_day():
    concert_id = await _create_concert("PF_T_LASTDAY_001", start="2030.06.01", end="2030.06.03")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "attended_date": "2030-06-03"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    data = response.json()
    assert data["is_first_day"] is False
    assert data["is_last_day"] is True


# 첫날도 막날도 아닌 중간 날짜면 둘 다 False 테스트
@pytest.mark.asyncio
async def test_create_ticket_middle_day_is_neither_first_nor_last():
    concert_id = await _create_concert("PF_T_MIDDAY_001", start="2030.06.01", end="2030.06.03")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "attended_date": "2030-06-02"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    data = response.json()
    assert data["is_first_day"] is False
    assert data["is_last_day"] is False


# attended_date를 안 보내면(OCR로 날짜를 못 뽑은 경우 등) 판정 자체를 안 하고 None으로 남는지 테스트
@pytest.mark.asyncio
async def test_create_ticket_without_attended_date_leaves_first_last_day_none():
    concert_id = await _create_concert("PF_T_NODATE_001", start="2030.06.01", end="2030.06.03")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    data = response.json()
    assert data["is_first_day"] is None
    assert data["is_last_day"] is None


# 하루짜리 공연(start_date == end_date)은 attended_date가 있어도 구분이 무의미해서 None 테스트
@pytest.mark.asyncio
async def test_create_ticket_single_day_concert_leaves_first_last_day_none():
    concert_id = await _create_concert("PF_T_ONEDAY_001", start="2030.06.01", end="2030.06.01")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "attended_date": "2030-06-01"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    data = response.json()
    assert data["is_first_day"] is None
    assert data["is_last_day"] is None


# 페스티벌은 날짜별 라인업이 달라 첫콘/막콘 개념이 안 맞으므로, 여러 날짜라도 자동 판정 안 함 테스트
@pytest.mark.asyncio
async def test_create_ticket_festival_leaves_first_last_day_none():
    kopis_id = "PF_T_FEST_001"
    token = await _get_token()
    xml = _make_kopis_xml(kopis_id, "테스트 뮤직페스티벌", "2030.06.01", "2030.06.03")
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            concert_res = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert concert_res.json()["event_type"] == "FESTIVAL"
    concert_id = concert_res.json()["id"]

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "attended_date": "2030-06-01"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 201
    data = response.json()
    assert data["is_first_day"] is None
    assert data["is_last_day"] is None


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


# limit/offset 파라미터로 페이지네이션되는지, 생략 시 기본값(최대 200건)이 적용되는지 테스트
@pytest.mark.asyncio
async def test_list_tickets_pagination():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    concert_ids = []
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        for i in range(5):
            cid = await _create_concert(f"PF_PAGE_{i}_{uuid.uuid4().hex[:6]}")
            concert_ids.append(cid)
            res = await ac.post("/api/v1/tickets", json={"concert_id": cid}, headers=headers)
            assert res.status_code == 201

        default_res = await ac.get("/api/v1/tickets", headers=headers)
        limited_res = await ac.get("/api/v1/tickets", params={"limit": 2}, headers=headers)
        offset_res = await ac.get("/api/v1/tickets", params={"limit": 2, "offset": 2}, headers=headers)

    assert len(default_res.json()) == 5  # 파라미터 생략하면 기본 상한(200) 내에서 전부 반환
    assert len(limited_res.json()) == 2
    assert len(offset_res.json()) == 2
    # offset 적용 시 첫 페이지와 겹치지 않아야 함
    first_page_ids = {t["id"] for t in limited_res.json()}
    second_page_ids = {t["id"] for t in offset_res.json()}
    assert first_page_ids.isdisjoint(second_page_ids)


# 목록 조회는 description/price(가격표) 없이 요약 정보만, 상세 조회는 전체 정보를
# 내려주는지 테스트 (목록 응답 크기를 줄이면서 상세 화면에 필요한 정보는 유지되는지 확인)
@pytest.mark.asyncio
async def test_list_tickets_omits_detail_only_concert_fields():
    concert_id = await _create_concert(f"PF_SLIM_{uuid.uuid4().hex[:6]}")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        create_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        ticket_id = create_res.json()["id"]

        list_res = await ac.get("/api/v1/tickets", headers=headers)
        detail_res = await ac.get(f"/api/v1/tickets/{ticket_id}", headers=headers)

    list_concert = list_res.json()[0]["concert"]
    detail_concert = detail_res.json()["concert"]

    assert "description" not in list_concert
    assert "price" not in list_concert
    assert list_concert["name"] == detail_concert["name"]  # 요약 정보는 그대로 유지

    assert "description" in detail_concert
    assert "price" in detail_concert


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


# "티켓 뜯기" 연출 시각(torn_at) 저장 + 재설정(null로 되돌리는 것 포함) 테스트 -
# 백엔드는 일회성 제약을 두지 않기로 했으므로 몇 번이든 다시 값을 바꿀 수 있어야 함
@pytest.mark.asyncio
async def test_update_ticket_torn_at_can_be_set_and_reset():
    concert_id = await _create_concert("PF_TORN_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        create_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        ticket_id = create_res.json()["id"]
        assert create_res.json()["torn_at"] is None

        torn_res = await ac.patch(
            f"/api/v1/tickets/{ticket_id}",
            json={"torn_at": "2030-06-02T10:00:00+00:00"},
            headers=headers,
        )
        assert torn_res.json()["torn_at"][:10] == "2030-06-02"

        reset_res = await ac.patch(
            f"/api/v1/tickets/{ticket_id}",
            json={"torn_at": None},
            headers=headers,
        )

    assert reset_res.status_code == 200
    assert reset_res.json()["torn_at"] is None


# attended_date만 PATCH로 새로 보내면(is_first_day/is_last_day는 안 보냄) 서버가 재판정하는지 테스트
@pytest.mark.asyncio
async def test_update_ticket_attended_date_recomputes_first_last_day():
    concert_id = await _create_concert("PF_UPDATE_ATTDATE_001", start="2030.06.01", end="2030.06.03")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        create_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        ticket_id = create_res.json()["id"]
        assert create_res.json()["is_first_day"] is None  # attended_date 없이 등록 -> 미판정

        response = await ac.patch(
            f"/api/v1/tickets/{ticket_id}",
            json={"attended_date": "2030-06-03"},
            headers=headers,
        )

    assert response.status_code == 200
    data = response.json()
    assert data["is_first_day"] is False
    assert data["is_last_day"] is True


# attended_date와 is_first_day/is_last_day를 같이 보내면 자동 재판정 없이 보낸 값 그대로(수동 override) 테스트
@pytest.mark.asyncio
async def test_update_ticket_manual_first_last_day_overrides_auto_detection():
    concert_id = await _create_concert("PF_UPDATE_MANUAL_001", start="2030.06.01", end="2030.06.03")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        create_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        ticket_id = create_res.json()["id"]

        # attended_date는 첫날(2030-06-01)이라 자동 판정이면 is_last_day=False가 나와야 하지만,
        # is_last_day를 명시적으로 True로 같이 보냈으니 그 값을 그대로 존중해야 함
        response = await ac.patch(
            f"/api/v1/tickets/{ticket_id}",
            json={"attended_date": "2030-06-01", "is_first_day": True, "is_last_day": True},
            headers=headers,
        )

    assert response.status_code == 200
    data = response.json()
    assert data["is_first_day"] is True
    assert data["is_last_day"] is True


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


# upgrade_event_type_if_multi_artist 단위 테스트 (순수 함수, DB 불필요)

def test_upgrade_event_type_keeps_solo_below_threshold():
    concert = Concert(event_type=EventType.SOLO.value, artist_name=["A", "B", "C", "D"])
    assert upgrade_event_type_if_multi_artist(concert) is False
    assert concert.event_type == EventType.SOLO.value


def test_upgrade_event_type_upgrades_at_threshold():
    concert = Concert(event_type=EventType.SOLO.value, artist_name=["A", "B", "C", "D", "E"])
    assert upgrade_event_type_if_multi_artist(concert) is True
    assert concert.event_type == EventType.FESTIVAL.value


# 페스티벌 1차 라인업은 소수만 공개되는 경우가 흔해서, 이미 FESTIVAL로 확정된 공연은 낮은
# 아티스트 수를 근거로 SOLO로 강등하지 않아야 함(2차/3차 발표를 기다려야 하므로)
def test_upgrade_event_type_does_not_downgrade_existing_festival():
    concert = Concert(event_type=EventType.FESTIVAL.value, artist_name=["A"])
    assert upgrade_event_type_if_multi_artist(concert) is False
    assert concert.event_type == EventType.FESTIVAL.value
