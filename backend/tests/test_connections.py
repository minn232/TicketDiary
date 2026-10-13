import asyncio
import uuid
from datetime import datetime, timedelta, timezone

from httpx import AsyncClient, ASGITransport
from sqlalchemy import select, update

from app.main import app
from app.core.database import AsyncSessionLocal
from app.models.connection import NearbyCode, UserConnection
from conftest import _get_token


# 헬퍼

def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _iso(dt: datetime) -> str:
    return dt.isoformat()


async def _user_id(ac: AsyncClient, token: str) -> uuid.UUID:
    res = await ac.get("/api/v1/auth/me", headers=_auth(token))
    return uuid.UUID(res.json()["id"])


async def _code(ac: AsyncClient, token: str) -> str:
    res = await ac.post("/api/v1/social/nearby/code", headers=_auth(token))
    assert res.status_code == 200
    return res.json()["code"]


async def _sight(ac: AsyncClient, token: str, code: str, seen_at: datetime | None = None, rssi: int = -45):
    return await ac.post(
        "/api/v1/social/nearby/sightings",
        headers=_auth(token),
        json={"code": code, "rssi": rssi, "seen_at": _iso(seen_at or datetime.now(timezone.utc))},
    )


# 두 유저가 서로를 본 판정을 올리고 양쪽 모두 확인해 연결까지 만든 뒤 connection_id 반환
async def _connect(ac: AsyncClient, token_a: str, token_b: str) -> str:
    code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
    await _sight(ac, token_a, code_b)
    res = await _sight(ac, token_b, code_a)
    connection_id = res.json()["connection_id"]
    await ac.post(f"/api/v1/social/connections/requests/{connection_id}/confirm", headers=_auth(token_a))
    await ac.post(f"/api/v1/social/connections/requests/{connection_id}/confirm", headers=_auth(token_b))
    return connection_id


# 코드 발급: 8자리 hex, 유효한 동안 같은 코드 재사용
async def test_nearby_code_reused_while_valid():
    token = await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        first = await ac.post("/api/v1/social/nearby/code", headers=_auth(token))
        second = await ac.post("/api/v1/social/nearby/code", headers=_auth(token))
    assert first.status_code == 200
    assert len(first.json()["code"]) == 8
    int(first.json()["code"], 16)
    assert second.json()["code"] == first.json()["code"]


# 만료 1시간 이내로 남은 코드는 새 코드로 교체
async def test_nearby_code_renewed_near_expiry():
    token = await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        old = await _code(ac, token)
        async with AsyncSessionLocal() as db:
            await db.execute(
                update(NearbyCode)
                .where(NearbyCode.code == old)
                .values(valid_until=datetime.now(timezone.utc) + timedelta(minutes=30))
            )
            await db.commit()
        new = await _code(ac, token)
    assert new != old


# 한쪽만 올리면 waiting, 양쪽이 서로를 올리면 pending + 상대 프로필
async def test_mutual_sighting_creates_pending_request():
    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        user_a, user_b = await _user_id(ac, token_a), await _user_id(ac, token_b)
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)

        first = await _sight(ac, token_a, code_b)
        second = await _sight(ac, token_b, code_a)
        requests_a = await ac.get("/api/v1/social/connections/requests", headers=_auth(token_a))

    assert first.json()["status"] == "waiting"
    assert second.json()["status"] == "pending"
    assert second.json()["peer"]["user_id"] == str(user_a)
    assert second.json()["confirmed_by_me"] is False
    assert [r["peer"]["user_id"] for r in requests_a.json()] == [str(user_b)]


# 서로 본 시각이 60초 넘게 차이 나면 짝짓지 않음
async def test_sightings_outside_window_not_paired():
    token_a, token_b = await _get_token(), await _get_token()
    now = datetime.now(timezone.utc)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        # 방금 발급한 코드라 과거 시각으론 못 풀어서, 뒤쪽 판정을 2분 뒤(미래 허용 범위 안)로 둠
        await _sight(ac, token_a, code_b, seen_at=now)
        res = await _sight(ac, token_b, code_a, seen_at=now + timedelta(minutes=2))
    assert res.json()["status"] == "waiting"


# 양쪽 모두 확인해야 연결 완료 / 연결 목록에 서로 보임
async def test_both_confirm_connects():
    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        user_a, user_b = await _user_id(ac, token_a), await _user_id(ac, token_b)
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        await _sight(ac, token_a, code_b)
        connection_id = (await _sight(ac, token_b, code_a)).json()["connection_id"]

        first = await ac.post(f"/api/v1/social/connections/requests/{connection_id}/confirm", headers=_auth(token_a))
        requests_a = await ac.get("/api/v1/social/connections/requests", headers=_auth(token_a))
        second = await ac.post(f"/api/v1/social/connections/requests/{connection_id}/confirm", headers=_auth(token_b))
        list_a = await ac.get("/api/v1/social/connections", headers=_auth(token_a))
        list_b = await ac.get("/api/v1/social/connections", headers=_auth(token_b))
        requests_after = await ac.get("/api/v1/social/connections/requests", headers=_auth(token_a))

    assert first.json()["status"] == "pending"
    assert requests_a.json()[0]["confirmed_by_me"] is True
    assert second.json()["status"] == "connected"
    assert [c["peer"]["user_id"] for c in list_a.json()] == [str(user_b)]
    assert [c["peer"]["user_id"] for c in list_b.json()] == [str(user_a)]
    assert requests_after.json() == []


# 이미 연결된 사이가 다시 맞대면 connected + 다시 만난 시각 갱신
async def test_sighting_after_connected_updates_last_met():
    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        connection_id = await _connect(ac, token_a, token_b)
        async with AsyncSessionLocal() as db:
            old = datetime.now(timezone.utc) - timedelta(days=3)
            await db.execute(
                update(UserConnection).where(UserConnection.id == uuid.UUID(connection_id)).values(last_met_at=old)
            )
            await db.commit()

        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        await _sight(ac, token_a, code_b)
        res = await _sight(ac, token_b, code_a)
        listed = await ac.get("/api/v1/social/connections", headers=_auth(token_a))

    assert res.json()["status"] == "connected"
    assert res.json()["connection_id"] == connection_id
    last_met = datetime.fromisoformat(listed.json()[0]["last_met_at"])
    assert last_met > datetime.now(timezone.utc) - timedelta(minutes=1)


# 10분 넘게 방치된 요청은 목록에서 빠지고 확인 불가(410), 다시 맞대면 새로 시작
async def test_expired_request_resets_on_new_sighting():
    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        await _sight(ac, token_a, code_b)
        connection_id = (await _sight(ac, token_b, code_a)).json()["connection_id"]
        await ac.post(f"/api/v1/social/connections/requests/{connection_id}/confirm", headers=_auth(token_a))
        async with AsyncSessionLocal() as db:
            await db.execute(
                update(UserConnection)
                .where(UserConnection.id == uuid.UUID(connection_id))
                .values(requested_at=datetime.now(timezone.utc) - timedelta(minutes=11))
            )
            await db.commit()

        listed = await ac.get("/api/v1/social/connections/requests", headers=_auth(token_a))
        expired = await ac.post(f"/api/v1/social/connections/requests/{connection_id}/confirm", headers=_auth(token_b))

        await _sight(ac, token_a, code_b)
        again = await _sight(ac, token_b, code_a)

    assert listed.json() == []
    assert expired.status_code == 410
    assert again.json()["status"] == "pending"
    assert again.json()["connection_id"] == connection_id
    # 새로 시작이라 A의 이전 확인도 지워짐
    async with AsyncSessionLocal() as db:
        row = await db.get(UserConnection, uuid.UUID(connection_id))
        assert row.a_confirmed_at is None and row.b_confirmed_at is None


# 거절하면 요청 삭제, 상대도 더 이상 확인 불가
async def test_reject_request():
    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        await _sight(ac, token_a, code_b)
        connection_id = (await _sight(ac, token_b, code_a)).json()["connection_id"]

        rejected = await ac.delete(f"/api/v1/social/connections/requests/{connection_id}", headers=_auth(token_a))
        confirm = await ac.post(f"/api/v1/social/connections/requests/{connection_id}/confirm", headers=_auth(token_b))

    assert rejected.status_code == 204
    assert confirm.status_code == 404


# 제3자는 남의 요청을 확인/거절할 수 없음
async def test_third_user_cannot_touch_request():
    token_a, token_b, token_c = await _get_token(), await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        await _sight(ac, token_a, code_b)
        connection_id = (await _sight(ac, token_b, code_a)).json()["connection_id"]

        confirm = await ac.post(f"/api/v1/social/connections/requests/{connection_id}/confirm", headers=_auth(token_c))
        reject = await ac.delete(f"/api/v1/social/connections/requests/{connection_id}", headers=_auth(token_c))
    assert confirm.status_code == 404
    assert reject.status_code == 404


# 연결 끊기 후 목록에서 사라지고, 다시 끊으면 404
async def test_delete_connection():
    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await _connect(ac, token_a, token_b)
        user_b = await _user_id(ac, token_b)

        deleted = await ac.delete(f"/api/v1/social/connections/{user_b}", headers=_auth(token_a))
        listed = await ac.get("/api/v1/social/connections", headers=_auth(token_b))
        again = await ac.delete(f"/api/v1/social/connections/{user_b}", headers=_auth(token_a))

    assert deleted.status_code == 204
    assert listed.json() == []
    assert again.status_code == 404


# 잘못된 판정: 모르는 코드 404, 내 코드 400, 허용 범위 밖 시각 400, 코드 형식 오류 422
async def test_invalid_sightings():
    token = await _get_token()
    now = datetime.now(timezone.utc)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        my_code = await _code(ac, token)
        unknown = await _sight(ac, token, "00000000" if my_code != "00000000" else "00000001")
        own = await _sight(ac, token, my_code)
        too_old = await _sight(ac, token, my_code, seen_at=now - timedelta(days=4))
        future = await _sight(ac, token, my_code, seen_at=now + timedelta(hours=1))
        bad_format = await _sight(ac, token, "XYZ")
    assert unknown.status_code == 404
    assert own.status_code == 400
    assert too_old.status_code == 400
    assert future.status_code == 400
    assert bad_format.status_code == 422


# 오프라인에서 저장했다가 나중에 올린 판정: 그 시각에 유효했던 (지금은 교체된) 코드로도 풀림
async def test_late_offline_sighting_resolves_old_code():
    token_a, token_b = await _get_token(), await _get_token()
    seen_at = datetime.now(timezone.utc) - timedelta(hours=30)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        user_a, user_b = await _user_id(ac, token_a), await _user_id(ac, token_b)
        # 30시간 전에 유효했던 각자의 옛 코드를 직접 넣어둠
        async with AsyncSessionLocal() as db:
            for user_id, code in ((user_a, "a1a1a1a1"), (user_b, "b2b2b2b2")):
                db.add(NearbyCode(
                    user_id=user_id, code=code,
                    valid_from=seen_at - timedelta(hours=1), valid_until=seen_at + timedelta(hours=23),
                ))
            await db.commit()

        await _sight(ac, token_a, "b2b2b2b2", seen_at=seen_at)
        res = await _sight(ac, token_b, "a1a1a1a1", seen_at=seen_at + timedelta(seconds=2))
    assert res.json()["status"] == "pending"
    assert res.json()["peer"]["user_id"] == str(user_a)


# 두 폰이 동시에 올려도 서로를 놓치지 않음 (쌍 단위 잠금) - 요청이 정확히 하나 생김
async def test_concurrent_sightings_pair_once():
    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        user_a, user_b = await _user_id(ac, token_a), await _user_id(ac, token_b)
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        results = await asyncio.gather(_sight(ac, token_a, code_b), _sight(ac, token_b, code_a))

    statuses = sorted(r.json()["status"] for r in results)
    assert statuses == ["pending", "waiting"]
    a, b = sorted([user_a, user_b], key=str)
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(
            select(UserConnection).where(UserConnection.user_a_id == a, UserConnection.user_b_id == b)
        )).scalars().all()
    assert len(rows) == 1


# 회원 탈퇴하면 상대 연결 목록에서도 사라짐 (DB cascade)
async def test_account_deletion_removes_connection():
    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await _connect(ac, token_a, token_b)
        deleted = await ac.delete("/api/v1/auth/me", headers=_auth(token_a))
        listed = await ac.get("/api/v1/social/connections", headers=_auth(token_b))
    assert deleted.status_code == 204
    assert listed.json() == []


# 기기마다 송신 세기가 달라 한쪽 -55 이상 + 다른 쪽 -62 이상이면 짝지음, 둘 다 약하면 대기
async def test_pairing_rssi_rule():
    async def pair(rssi_a: int | None, rssi_b: int | None) -> str:
        token_a, token_b = await _get_token(), await _get_token()
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
            await ac.post(
                "/api/v1/social/nearby/sightings", headers=_auth(token_a),
                json={"code": code_b, "rssi": rssi_a, "seen_at": _iso(datetime.now(timezone.utc))},
            )
            res = await ac.post(
                "/api/v1/social/nearby/sightings", headers=_auth(token_b),
                json={"code": code_a, "rssi": rssi_b, "seen_at": _iso(datetime.now(timezone.utc))},
            )
        return res.json()["status"]

    assert await pair(-44, -52) == "pending"  # 태블릿 윗변
    assert await pair(-51, -60) == "pending"  # 태블릿 왼변 - 한쪽만 강함
    assert await pair(-60, -61) == "waiting"  # 폰끼리 5cm - 강한 쪽 없음
    assert await pair(-50, -64) == "waiting"  # 약한 쪽이 너무 약함
    assert await pair(None, -60) == "pending"  # RSSI 없는 구버전 판정은 기준 검사 없이


# 같은 접촉에서 처음엔 약하게, 이어서 강하게 올리면 강한 판정으로 짝지어짐
async def test_pairing_uses_stronger_follow_up_sighting():
    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        await _sight(ac, token_a, code_b, rssi=-61)
        weak = await _sight(ac, token_b, code_a, rssi=-60)
        strong = await _sight(ac, token_a, code_b, rssi=-50)
    assert weak.json()["status"] == "waiting"
    assert strong.json()["status"] == "pending"


# 두 사람이 거의 동시에 확인해도 연결됨 (둘 다 "확인 기다리는 중"에 멈췄던 경합)
async def test_simultaneous_confirm_connects():
    from app.services.connection import confirm_connection_request

    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        user_a, user_b = await _user_id(ac, token_a), await _user_id(ac, token_b)
        code_b = await _code(ac, token_b)
        code_a = await _code(ac, token_a)
        await _sight(ac, token_a, code_b)
        pending = await _sight(ac, token_b, code_a)
    connection_id = uuid.UUID(pending.json()["connection_id"])

    barrier = asyncio.Barrier(2)

    async def confirm(user_id: uuid.UUID):
        async with AsyncSessionLocal() as db:
            await db.execute(select(1))  # 연결을 미리 맺어 두 확인이 실제로 겹치게
            await barrier.wait()
            return await confirm_connection_request(db, user_id, connection_id)

    results = await asyncio.gather(confirm(user_a), confirm(user_b))

    assert "connected" in {r.status for r in results}
    async with AsyncSessionLocal() as db:
        row = await db.get(UserConnection, connection_id)
    assert row.connected_at is not None


# 이미 연결된 사이가 연달아 맞대도 직전 시도 판정과는 짝짓지 않음 - 이번 시도에서 둘 다 봐야 다시 만남
async def test_previous_attempt_sighting_not_paired():
    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await _connect(ac, token_a, token_b)
        # 1회차 다시 만남
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        await _sight(ac, token_b, code_a)
        first = await _sight(ac, token_a, code_b)
        # 2회차: 둘 다 화면을 다시 엶 → 1회차 판정은 무효
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        only_a = await _sight(ac, token_a, code_b)
        both = await _sight(ac, token_b, code_a)

    assert first.json()["status"] == "connected"
    assert only_a.json()["status"] == "waiting"  # 상대의 1회차 판정과 짝지어지면 안 됨
    assert both.json()["status"] == "connected"


# 오프라인 때 모아 늦게 올린 판정은 상대가 화면을 다시 열었어도 짝지어짐
async def test_late_offline_upload_still_pairs():
    token_a, token_b = await _get_token(), await _get_token()
    met_at = datetime.now(timezone.utc) - timedelta(minutes=5)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        code_a, code_b = await _code(ac, token_a), await _code(ac, token_b)
        # 방금 발급한 테스트 코드라 5분 전 판정도 풀리게 유효 시작을 앞당김
        async with AsyncSessionLocal() as db:
            await db.execute(
                update(NearbyCode)
                .where(NearbyCode.code.in_([code_a, code_b]))
                .values(valid_from=met_at - timedelta(minutes=1))
            )
            await db.commit()
        late_b = await _sight(ac, token_b, code_a, seen_at=met_at)
        await _code(ac, token_b)  # B가 그 뒤 화면을 다시 열어도
        late_a = await _sight(ac, token_a, code_b, seen_at=met_at + timedelta(seconds=3))

    assert late_b.json()["status"] == "waiting"
    assert late_a.json()["status"] == "pending"


# 정리 배치: 72시간 넘은 판정·만료된 지 72시간 넘은 코드·하루 넘게 방치된 요청만 지우고 나머지는 둠
async def test_cleanup_nearby_records():
    from app.models.connection import NearbySighting
    from app.services.connection import cleanup_nearby_records

    token_a, token_b = await _get_token(), await _get_token()
    now = datetime.now(timezone.utc)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        user_a, user_b = await _user_id(ac, token_a), await _user_id(ac, token_b)
        code_b = await _code(ac, token_b)
        fresh = await _sight(ac, token_a, code_b)
    assert fresh.status_code == 200
    a, b = sorted([user_a, user_b], key=str)
    async with AsyncSessionLocal() as db:
        old_code = NearbyCode(
            user_id=user_a, code=uuid.uuid4().hex[:8],
            valid_from=now - timedelta(days=6), valid_until=now - timedelta(days=5),
        )
        old_sighting = NearbySighting(
            observer_user_id=user_b, observed_user_id=user_a, rssi=-50, seen_at=now - timedelta(days=4)
        )
        stale_request = UserConnection(user_a_id=a, user_b_id=b, requested_at=now - timedelta(days=2))
        db.add_all([old_code, old_sighting, stale_request])
        await db.commit()
        ids = (old_code.id, old_sighting.id, stale_request.id)

        await cleanup_nearby_records(db)

        assert await db.get(NearbyCode, ids[0]) is None
        assert await db.get(NearbySighting, ids[1]) is None
        assert await db.get(UserConnection, ids[2]) is None
        # 방금 올린 판정과 지금 쓰는 코드는 남음
        remaining = (await db.execute(
            select(NearbySighting).where(NearbySighting.observer_user_id == user_a)
        )).scalars().all()
        assert len(remaining) == 1
        assert (await db.execute(select(NearbyCode).where(NearbyCode.code == code_b))).first() is not None


# 판정 등록은 유저당 시간당 300회까지 - 넘으면 429
async def test_sighting_rate_limited_per_user():
    import time

    from app.core.deps import _rate_limit_hits

    token_a, token_b = await _get_token(), await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        code_b = await _code(ac, token_b)
        user_a = await _user_id(ac, token_a)
        _rate_limit_hits[f"nearby_sighting:{user_a}"].extend([time.monotonic()] * 300)
        res = await _sight(ac, token_a, code_b)

    assert res.status_code == 429
