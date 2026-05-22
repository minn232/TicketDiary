import uuid
import pytest
from httpx import AsyncClient, ASGITransport
from app.main import app
from conftest import _get_token, kopis_mock


# 헬퍼

# KOPIS 공연 정보 XML 생성
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
        f"<prfcrew>출연: 테스트아티스트</prfcrew>"
        f"<pcseguidance>R석 110,000원</pcseguidance>"
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# 공연 생성 (kopis_mock)
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


_SAMPLE_CONTENTS = [
    {"time": "17:00", "description": "입장"},
    {"time": "18:00", "description": "공연 시작"},
    {"time": "20:00", "description": "공연 종료"},
]


# 타임테이블 upsert 테스트 (PUT /concerts/{concert_id}/timetable)

# 타임테이블 최초 생성 테스트
@pytest.mark.asyncio
async def test_upsert_timetable_create():
    concert_id = await _create_concert("PF_TT_CREATE_001")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.put(
            f"/api/v1/concerts/{concert_id}/timetable",
            json={"contents": _SAMPLE_CONTENTS},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 200
    data = response.json()
    assert data["concert_id"] == concert_id
    assert len(data["contents"]) == 3
    assert data["contents"][0] == {"time": "17:00", "description": "입장"}


# 타임테이블 덮어쓰기(업데이트) 테스트
@pytest.mark.asyncio
async def test_upsert_timetable_update():
    concert_id = await _create_concert("PF_TT_UPDATE_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res1 = await ac.put(
            f"/api/v1/concerts/{concert_id}/timetable",
            json={"contents": _SAMPLE_CONTENTS},
            headers=headers,
        )

    updated_contents = [{"time": "16:30", "description": "사전 입장"}]
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res2 = await ac.put(
            f"/api/v1/concerts/{concert_id}/timetable",
            json={"contents": updated_contents},
            headers=headers,
        )

    assert res1.status_code == 200
    assert res2.status_code == 200
    assert res1.json()["id"] == res2.json()["id"]
    assert len(res2.json()["contents"]) == 1
    assert res2.json()["contents"][0]["time"] == "16:30"


# 존재하지 않는 concert_id로 upsert 시 404 테스트
@pytest.mark.asyncio
async def test_upsert_timetable_concert_not_found_404():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.put(
            f"/api/v1/concerts/{uuid.uuid4()}/timetable",
            json={"contents": _SAMPLE_CONTENTS},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 404


# 타임테이블 조회 테스트 (GET /concerts/{concert_id}/timetable)

# 저장된 타임테이블 조회 성공 테스트
@pytest.mark.asyncio
async def test_get_timetable_success():
    concert_id = await _create_concert("PF_TT_GET_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.put(
            f"/api/v1/concerts/{concert_id}/timetable",
            json={"contents": _SAMPLE_CONTENTS},
            headers=headers,
        )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/timetable",
            headers=headers,
        )

    assert response.status_code == 200
    data = response.json()
    assert data["concert_id"] == concert_id
    assert len(data["contents"]) == 3


# 타임테이블 없는 공연 조회 시 404 테스트
@pytest.mark.asyncio
async def test_get_timetable_not_found_404():
    concert_id = await _create_concert("PF_TT_GET_002")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/timetable",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 404
