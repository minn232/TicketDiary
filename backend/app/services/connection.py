import secrets
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import delete, func, or_, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.connection import NearbyCode, NearbySighting, UserConnection
from app.models.user import User
from app.schemas.connection import (
    ConnectionConfirmResponse,
    ConnectionPeer,
    ConnectionRequestResponse,
    ConnectionResponse,
    NearbyCodeResponse,
    NearbySightingCreate,
    NearbySightingResponse,
)

# 코드는 하루 쓰고, 만료 1시간 전부터는 새 코드를 줌 (오프라인 현장에서 만료되지 않게)
_CODE_TTL = timedelta(hours=24)
_CODE_RENEW_BEFORE = timedelta(hours=1)
# 공연장에서 오프라인으로 저장한 판정을 다음날 올려도 받아줌
_SIGHTING_MAX_AGE = timedelta(hours=72)
_SIGHTING_MAX_FUTURE = timedelta(minutes=5)
# 두 폰 시계 차이 + 맞대고 있던 시간 - 실측상 판정은 1초 안에 나지만 시계가 어긋난 폰을 감안
_PAIR_WINDOW = timedelta(seconds=60)
# 판정 시각보다 이만큼 넘게 늦게 올라온 판정은 오프라인 때 모아둔 것 - 이번 시도 제한을 안 받음
_LATE_UPLOAD = timedelta(seconds=30)
# 확인 화면을 띄운 채 오래 방치된 요청은 무효 (다시 맞대면 새로 시작)
_PENDING_TTL = timedelta(minutes=10)
# 맞댐 판정 RSSI(1초 평균) - 기기마다 송신 세기가 달라(태블릿↔폰 8~9dB) 한쪽은 강하게, 다른 쪽은
# 조금 약하게 받아도 인정. 폰끼리 5cm(-60~-62)는 강한 쪽이 없어 탈락
_RSSI_STRONG = -55
_RSSI_WEAK = -62
# 짝지어진 뒤 두 폰이 애니메이션을 시작하기까지 여유 - 기다리던 쪽이 폴링으로 알아챌 시간
_SYNC_DELAY = timedelta(milliseconds=1200)


def _rssi_pair_ok(mine: int | None, theirs: int | None) -> bool:
    # RSSI 없이 올린 판정(구버전 앱)은 기준 검사 없이 인정
    if mine is None or theirs is None:
        return True
    return max(mine, theirs) >= _RSSI_STRONG and min(mine, theirs) >= _RSSI_WEAK


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _ordered(user_id: UUID, peer_id: UUID) -> tuple[UUID, UUID]:
    return (user_id, peer_id) if str(user_id) < str(peer_id) else (peer_id, user_id)


def _is_a(row: UserConnection, user_id: UUID) -> bool:
    return row.user_a_id == user_id


def _peer_id(row: UserConnection, user_id: UUID) -> UUID:
    return row.user_b_id if _is_a(row, user_id) else row.user_a_id


def _confirmed_by(row: UserConnection, user_id: UUID) -> bool:
    return (row.a_confirmed_at if _is_a(row, user_id) else row.b_confirmed_at) is not None


async def _session_started_at(db: AsyncSession, user_id: UUID) -> datetime | None:
    return (
        await db.execute(select(func.max(NearbyCode.session_started_at)).where(NearbyCode.user_id == user_id))
    ).scalar_one_or_none()


def _sighting_response(row: UserConnection, user_id: UUID, peer: ConnectionPeer | None) -> NearbySightingResponse:
    return NearbySightingResponse(
        status="connected" if row.connected_at is not None else "pending",
        connection_id=row.id,
        peer=peer,
        confirmed_by_me=_confirmed_by(row, user_id),
        reveal_at=row.matched_at + _SYNC_DELAY if row.matched_at is not None else None,
        server_time=_now(),
    )


def _pending_expired(row: UserConnection, now: datetime) -> bool:
    return row.connected_at is None and row.requested_at < now - _PENDING_TTL


async def _peers(db: AsyncSession, user_ids: list[UUID]) -> dict[UUID, ConnectionPeer]:
    if not user_ids:
        return {}
    result = await db.execute(select(User).where(User.id.in_(user_ids)))
    return {
        u.id: ConnectionPeer(user_id=u.id, nickname=u.nickname, profile_image_url=u.profile_image_url)
        for u in result.scalars().all()
    }


# 내 BLE 광고 코드 - 유효한 코드가 1시간 넘게 남았으면 그대로, 아니면 새로 발급
async def get_or_issue_nearby_code(db: AsyncSession, user_id: UUID) -> NearbyCodeResponse:
    now = _now()
    result = await db.execute(
        select(NearbyCode)
        .where(NearbyCode.user_id == user_id, NearbyCode.valid_until > now + _CODE_RENEW_BEFORE)
        .order_by(NearbyCode.valid_until.desc())
        .limit(1)
    )
    row = result.scalar_one_or_none()
    if row is not None:
        # 화면을 열 때마다 불리므로 여기서 이번 시도 시작을 기록
        row.session_started_at = now
        await db.commit()
        return NearbyCodeResponse(code=row.code, valid_until=row.valid_until)

    # 늦게 올라오는 오프라인 판정이 다른 사람 코드로 풀리지 않게, 그 기간 안에 쓰인 코드와 겹치지 않게 뽑음
    for _ in range(5):
        code = secrets.token_hex(4)
        taken = await db.execute(
            select(NearbyCode.id).where(
                NearbyCode.code == code, NearbyCode.valid_until > now - _SIGHTING_MAX_AGE
            )
        )
        if taken.first() is None:
            break
    else:
        raise HTTPException(status_code=503, detail="코드 발급에 실패했습니다. 다시 시도해주세요.")

    row = NearbyCode(
        user_id=user_id, code=code, valid_from=now, valid_until=now + _CODE_TTL, session_started_at=now
    )
    db.add(row)
    await db.commit()
    return NearbyCodeResponse(code=row.code, valid_until=row.valid_until)


# 맞댐 판정 등록 - 상대도 짧은 시간 안에 나를 봤다고 올렸으면 연결 요청을 만들거나(첫 만남)
# 다시 만난 시각을 갱신(이미 연결). 두 폰이 동시에 올려도 서로를 놓치지 않게 쌍 단위로 잠금
async def report_sighting(db: AsyncSession, user_id: UUID, body: NearbySightingCreate) -> NearbySightingResponse:
    now = _now()
    seen_at = body.seen_at if body.seen_at.tzinfo else body.seen_at.replace(tzinfo=timezone.utc)
    if seen_at > now + _SIGHTING_MAX_FUTURE or seen_at < now - _SIGHTING_MAX_AGE:
        raise HTTPException(status_code=400, detail="판정 시각이 허용 범위를 벗어났습니다.")

    result = await db.execute(
        select(NearbyCode.user_id).where(
            NearbyCode.code == body.code,
            NearbyCode.valid_from <= seen_at,
            NearbyCode.valid_until >= seen_at,
        )
    )
    peer_id = result.scalar_one_or_none()
    if peer_id is None:
        raise HTTPException(status_code=404, detail="알 수 없는 코드입니다.")
    if peer_id == user_id:
        raise HTTPException(status_code=400, detail="자기 자신과는 연결할 수 없습니다.")

    user_a_id, user_b_id = _ordered(user_id, peer_id)
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))"),
        {"key": f"user_connection:{user_a_id}:{user_b_id}"},
    )
    db.add(NearbySighting(observer_user_id=user_id, observed_user_id=peer_id, rssi=body.rssi, seen_at=seen_at))

    # 상대의 이번 시도(화면을 마지막으로 연 뒤) 판정만 짝지음 - 직전 시도 판정과 짝지어지면 한쪽만 바로
    # 끝나고 상대는 계속 찾는 중으로 남았음. 오프라인 때 모아 늦게 올린 판정은 예외
    peer_session = await _session_started_at(db, peer_id)
    reverse_query = select(NearbySighting.rssi).where(
        NearbySighting.observer_user_id == peer_id,
        NearbySighting.observed_user_id == user_id,
        NearbySighting.seen_at.between(seen_at - _PAIR_WINDOW, seen_at + _PAIR_WINDOW),
    )
    if peer_session is not None:
        reverse_query = reverse_query.where(
            or_(
                NearbySighting.created_at >= peer_session,
                NearbySighting.created_at - NearbySighting.seen_at > _LATE_UPLOAD,
            )
        )
    reverse = await db.execute(reverse_query)
    if not any(_rssi_pair_ok(body.rssi, theirs) for theirs in reverse.scalars().all()):
        await db.commit()
        return NearbySightingResponse(status="waiting", server_time=_now())

    result = await db.execute(
        select(UserConnection).where(
            UserConnection.user_a_id == user_a_id, UserConnection.user_b_id == user_b_id
        )
    )
    row = result.scalar_one_or_none()
    if row is None:
        row = UserConnection(
            user_a_id=user_a_id,
            user_b_id=user_b_id,
            requested_at=now,
            a_confirmed_at=None,
            b_confirmed_at=None,
            connected_at=None,
            last_met_at=None,
        )
        db.add(row)
    elif row.connected_at is not None:
        row.last_met_at = now
    elif _pending_expired(row, now):
        row.requested_at = now
        row.a_confirmed_at = None
        row.b_confirmed_at = None
    # 기다리던 쪽이 더 강한 판정을 다시 올려도 같은 시도면 시작 시각을 옮기지 않음 - 옮기면 먼저 받은
    # 폰과 어긋남. 둘 중 하나라도 화면을 다시 열었으면 새 시도
    my_session = await _session_started_at(db, user_id)
    if row.matched_at is None or any(s is not None and row.matched_at < s for s in (my_session, peer_session)):
        row.matched_at = now
    await db.commit()

    peer = (await _peers(db, [peer_id])).get(peer_id)
    return _sighting_response(row, user_id, peer)


# 판정을 올리고 waiting을 받은 폰이 상대 판정이 모였는지 확인 (판정을 새로 남기지 않음) - 본 코드의
# 주인과의 짝만 보므로 다른 친구와의 연결 변화를 이번 만남으로 오인하지 않음
async def get_match_status(db: AsyncSession, user_id: UUID, code: str) -> NearbySightingResponse:
    now = _now()
    peer_id = (
        await db.execute(
            select(NearbyCode.user_id).where(
                NearbyCode.code == code, NearbyCode.valid_from <= now, NearbyCode.valid_until >= now
            )
        )
    ).scalar_one_or_none()
    if peer_id is None:
        raise HTTPException(status_code=404, detail="알 수 없는 코드입니다.")

    user_a_id, user_b_id = _ordered(user_id, peer_id)
    row = (
        await db.execute(
            select(UserConnection).where(
                UserConnection.user_a_id == user_a_id, UserConnection.user_b_id == user_b_id
            )
        )
    ).scalar_one_or_none()
    my_session = await _session_started_at(db, user_id)
    if row is None or row.matched_at is None or (my_session is not None and row.matched_at < my_session):
        return NearbySightingResponse(status="waiting", server_time=_now())
    peer = (await _peers(db, [peer_id])).get(peer_id)
    return _sighting_response(row, user_id, peer)


async def _get_my_connection(
    db: AsyncSession, user_id: UUID, connection_id: UUID, *, for_update: bool = False
) -> UserConnection:
    query = select(UserConnection).where(
        UserConnection.id == connection_id,
        or_(UserConnection.user_a_id == user_id, UserConnection.user_b_id == user_id),
    )
    if for_update:
        query = query.with_for_update()
    result = await db.execute(query)
    row = result.scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="연결 요청을 찾을 수 없습니다.")
    return row


# 확인 대기 중인 연결 요청 (만료된 요청 제외) - 판정을 올린 뒤 상대 판정을 기다리는 동안 앱이 폴링
async def list_connection_requests(db: AsyncSession, user_id: UUID) -> list[ConnectionRequestResponse]:
    now = _now()
    result = await db.execute(
        select(UserConnection)
        .where(
            or_(UserConnection.user_a_id == user_id, UserConnection.user_b_id == user_id),
            UserConnection.connected_at.is_(None),
            UserConnection.requested_at >= now - _PENDING_TTL,
        )
        .order_by(UserConnection.requested_at.desc())
    )
    rows = result.scalars().all()
    peers = await _peers(db, [_peer_id(r, user_id) for r in rows])
    return [
        ConnectionRequestResponse(
            connection_id=r.id,
            peer=peers[_peer_id(r, user_id)],
            requested_at=r.requested_at,
            confirmed_by_me=_confirmed_by(r, user_id),
        )
        for r in rows
    ]


# "OO님 맞나요?" 확인 - 양쪽 모두 확인하면 연결 완료
async def confirm_connection_request(
    db: AsyncSession, user_id: UUID, connection_id: UUID
) -> ConnectionConfirmResponse:
    # 거의 동시에 확인하면 서로 상대 확인을 못 본 채 각자 커밋해 연결이 안 됐음 → 행을 잠가
    # 나중 확인이 먼저 확인을 보고 연결하게 함
    row = await _get_my_connection(db, user_id, connection_id, for_update=True)
    now = _now()
    if row.connected_at is None:
        if _pending_expired(row, now):
            raise HTTPException(status_code=410, detail="만료된 연결 요청입니다. 다시 맞대주세요.")
        if _is_a(row, user_id):
            row.a_confirmed_at = row.a_confirmed_at or now
        else:
            row.b_confirmed_at = row.b_confirmed_at or now
        if row.a_confirmed_at is not None and row.b_confirmed_at is not None:
            row.connected_at = now
            row.last_met_at = now
        await db.commit()
    # 나중 확인 쪽은 응답으로, 먼저 확인한 쪽은 재전송으로 같은 시각을 받아 동시에 시작
    return ConnectionConfirmResponse(
        status="connected" if row.connected_at is not None else "pending",
        connection_id=row.id,
        finish_at=row.connected_at + _SYNC_DELAY if row.connected_at is not None else None,
        server_time=_now(),
    )


# 연결 요청 거절 - 아직 연결 전인 요청만 지움 (이미 연결된 사이는 연결 끊기로)
async def reject_connection_request(db: AsyncSession, user_id: UUID, connection_id: UUID) -> None:
    row = await _get_my_connection(db, user_id, connection_id)
    if row.connected_at is not None:
        raise HTTPException(status_code=400, detail="이미 연결된 사이입니다.")
    await db.delete(row)
    await db.commit()


# 연결 목록 (최근에 만난 순)
async def list_connections(db: AsyncSession, user_id: UUID) -> list[ConnectionResponse]:
    result = await db.execute(
        select(UserConnection)
        .where(
            or_(UserConnection.user_a_id == user_id, UserConnection.user_b_id == user_id),
            UserConnection.connected_at.is_not(None),
        )
        .order_by(func.coalesce(UserConnection.last_met_at, UserConnection.connected_at).desc())
    )
    rows = result.scalars().all()
    peers = await _peers(db, [_peer_id(r, user_id) for r in rows])
    return [
        ConnectionResponse(
            connection_id=r.id,
            peer=peers[_peer_id(r, user_id)],
            connected_at=r.connected_at,
            last_met_at=r.last_met_at,
        )
        for r in rows
    ]


# 연결 끊기 - 다시 맞대면 처음부터 확인을 거쳐 새로 연결됨
async def delete_connection(db: AsyncSession, user_id: UUID, peer_user_id: UUID) -> None:
    user_a_id, user_b_id = _ordered(user_id, peer_user_id)
    result = await db.execute(
        delete(UserConnection).where(
            UserConnection.user_a_id == user_a_id,
            UserConnection.user_b_id == user_b_id,
            UserConnection.connected_at.is_not(None),
        )
    )
    if result.rowcount == 0:
        raise HTTPException(status_code=404, detail="연결된 상대가 아닙니다.")
    await db.commit()


# 만료된 요청을 지우기 전 여유 - 만료(10분) 직후 확인 버튼을 누른 쪽이 410을 받을 수 있게 하루 남겨 둠
_EXPIRED_REQUEST_KEEP = timedelta(days=1)


# 오래된 맞대기 기록 정리(매일) - 판정은 늦은 업로드 허용(72시간)+짝짓기 창이 지나면 짝지을 일이 없고,
# 코드는 그 기간 안의 판정 해석·코드 중복 확인에만 쓰임. 확인 안 된 채 만료된 연결 요청도 지움
async def cleanup_nearby_records(db: AsyncSession) -> dict[str, int]:
    now = _now()
    sightings = await db.execute(
        delete(NearbySighting).where(NearbySighting.seen_at < now - _SIGHTING_MAX_AGE - _PAIR_WINDOW)
    )
    codes = await db.execute(delete(NearbyCode).where(NearbyCode.valid_until < now - _SIGHTING_MAX_AGE))
    requests = await db.execute(
        delete(UserConnection).where(
            UserConnection.connected_at.is_(None),
            UserConnection.requested_at < now - _PENDING_TTL - _EXPIRED_REQUEST_KEEP,
        )
    )
    await db.commit()
    return {"sightings": sightings.rowcount, "codes": codes.rowcount, "requests": requests.rowcount}
