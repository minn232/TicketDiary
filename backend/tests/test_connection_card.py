import uuid
from datetime import date, datetime, timedelta, timezone

from httpx import AsyncClient, ASGITransport

from app.main import app
from app.core.database import AsyncSessionLocal
from app.models.concert import Concert
from app.models.connection import UserConnection
from app.models.setlist import RealSetlist
from app.models.social import ArtistFollow, ConcertFollow
from app.models.ticket import Ticket, TicketStatus
from conftest import _get_token


# 헬퍼

def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


# 한국 날짜를 UTC 자정으로 저장하는 공연 날짜 규칙에 맞춤
def _day(days_from_today: int) -> datetime:
    d = date.today() + timedelta(days=days_from_today)
    return datetime(d.year, d.month, d.day, tzinfo=timezone.utc)


# 다른 테스트 데이터와 섞이지 않게 아티스트명에 고유 접미사
def _artist(name: str) -> str:
    return f"{name}-{uuid.uuid4().hex[:6]}"


async def _user(ac: AsyncClient) -> tuple[str, uuid.UUID]:
    token = await _get_token()
    res = await ac.get("/api/v1/auth/me", headers=_auth(token))
    return token, uuid.UUID(res.json()["id"])


async def _connect(user_a: uuid.UUID, user_b: uuid.UUID) -> None:
    a, b = sorted([user_a, user_b], key=str)
    now = datetime.now(timezone.utc)
    async with AsyncSessionLocal() as db:
        db.add(UserConnection(user_a_id=a, user_b_id=b, requested_at=now, connected_at=now, last_met_at=now))
        await db.commit()


async def _concert(name: str, artists: list[str], start: int, end: int | None = None) -> uuid.UUID:
    async with AsyncSessionLocal() as db:
        concert = Concert(
            name=name, artist_name=artists, start_date=_day(start), end_date=_day(end if end is not None else start),
            venue="테스트홀", poster_url=f"https://example.com/{name}.jpg",
        )
        db.add(concert)
        await db.commit()
        return concert.id


async def _ticket(user_id: uuid.UUID, concert_id: uuid.UUID, *, past: bool, attended: int | None = None) -> None:
    async with AsyncSessionLocal() as db:
        db.add(Ticket(
            user_id=user_id, concert_id=concert_id,
            status=TicketStatus.AFTER_CONCERT if past else TicketStatus.BEFORE_CONCERT,
            attended_date=_day(attended) if attended is not None else None,
        ))
        await db.commit()


async def _setlist(concert_id: uuid.UUID, day: int, songs: list[str]) -> None:
    async with AsyncSessionLocal() as db:
        db.add(RealSetlist(concert_id=concert_id, performance_date=_day(day).date(), songs=[{"name": s} for s in songs]))
        await db.commit()


async def _card(ac: AsyncClient, token: str, peer_id: uuid.UUID):
    return await ac.get(f"/api/v1/social/connections/{peer_id}/card", headers=_auth(token))


# 연결된 사이가 아니면 404
async def test_card_requires_connection():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, _ = await _user(ac)
        _, user_b = await _user(ac)
        res = await _card(ac, token_a, user_b)
    assert res.status_code == 404


# 같은 날 같은 공연 → 같이 간 공연 + 둘 다 들은 곡 + 공통 아티스트 + 궁합
async def test_card_together_concert_and_shared_songs():
    singer = _artist("가수")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, user_a = await _user(ac)
        _, user_b = await _user(ac)
        await _connect(user_a, user_b)
        concert_id = await _concert("함께콘", [singer], start=-30)
        await _ticket(user_a, concert_id, past=True)
        await _ticket(user_b, concert_id, past=True)
        await _setlist(concert_id, -30, ["곡1", "곡2"])

        res = await _card(ac, token_a, user_b)

    body = res.json()
    assert res.status_code == 200
    assert body["us"]["together_count"] == 1
    assert body["us"]["latest_together_poster_url"] == "https://example.com/함께콘.jpg"
    assert body["us"]["common_artists"] == [singer]
    assert body["us"]["compatibility"]["score"] == 100
    assert [c["name"] for c in body["history"]["together_concerts"]] == ["함께콘"]
    assert body["history"]["shared_song_count"] == 2
    assert body["history"]["shared_songs"][0]["times"] == 2


# 여러 날 공연을 서로 다른 날 봤으면 같이 간 공연이 아니라 "같은 공연 다른 날"
async def test_card_same_concert_other_day():
    singer = _artist("투어")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, user_a = await _user(ac)
        _, user_b = await _user(ac)
        await _connect(user_a, user_b)
        concert_id = await _concert("이틀콘", [singer], start=-20, end=-19)
        await _ticket(user_a, concert_id, past=True, attended=-20)
        await _ticket(user_b, concert_id, past=True, attended=-19)

        body = (await _card(ac, token_a, user_b)).json()

    assert body["us"]["together_count"] == 0
    other = body["history"]["same_concert_other_days"]
    assert len(other) == 1
    assert other[0]["my_date"] == _day(-20).date().isoformat()
    assert other[0]["peer_date"] == _day(-19).date().isoformat()


# 다른 공연에서 들었어도 같은 곡이면 둘 다 라이브로 들은 곡
async def test_card_shared_songs_across_different_concerts():
    singer = _artist("가수")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, user_a = await _user(ac)
        _, user_b = await _user(ac)
        await _connect(user_a, user_b)
        first = await _concert("서울콘", [singer], start=-60)
        second = await _concert("부산콘", [singer], start=-40)
        await _ticket(user_a, first, past=True)
        await _ticket(user_b, second, past=True)
        await _setlist(first, -60, ["대표곡", "서울만"])
        await _setlist(second, -40, ["대표곡 ", "부산만"])

        body = (await _card(ac, token_a, user_b)).json()

    assert body["us"]["together_count"] == 0
    assert body["history"]["shared_song_count"] == 1
    assert body["history"]["shared_songs"][0]["name"] == "대표곡"


# 다음 공연: 서로 다르면 각자, 같으면 together_next 하나로 합침
async def test_card_next_concerts():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, user_a = await _user(ac)
        token_b, user_b = await _user(ac)
        await _connect(user_a, user_b)
        mine = await _concert("내다음", [_artist("A")], start=10)
        theirs = await _concert("상대다음", [_artist("B")], start=12)
        await _ticket(user_a, mine, past=False)
        await _ticket(user_b, theirs, past=False)
        separate = (await _card(ac, token_a, user_b)).json()["next"]

        # 상대도 내 다음 공연을 예매하면 합쳐짐
        await _ticket(user_b, mine, past=False)
        merged = (await _card(ac, token_a, user_b)).json()["next"]

    assert separate["my_next"]["name"] == "내다음"
    assert separate["peer_next"]["name"] == "상대다음"
    assert separate["together_next"] is None
    assert merged["together_next"]["name"] == "내다음"
    assert merged["my_next"] is None and merged["peer_next"] is None


# 상대가 공개를 끄면 상대 단독 다음 공연은 숨김, 둘 다 예매한 공연은 그대로 보임
async def test_card_peer_hides_next_concert():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, user_a = await _user(ac)
        token_b, user_b = await _user(ac)
        await _connect(user_a, user_b)
        await ac.patch("/api/v1/settings", json={"share_next_concert": False}, headers=_auth(token_b))
        solo = await _concert("상대혼자", [_artist("B")], start=5)
        both = await _concert("둘다예매", [_artist("C")], start=8)
        await _ticket(user_b, solo, past=False)
        await _ticket(user_a, both, past=False)
        await _ticket(user_b, both, past=False)

        res = await _card(ac, token_a, user_b)

    nxt = res.json()["next"]
    assert nxt["peer_next_hidden"] is True
    assert nxt["peer_next"] is None
    assert nxt["together_next"]["name"] == "둘다예매"
    assert "상대혼자" not in res.text


# 둘 다 관심(예매/찜) 공연은 상태와 함께, 없으면 공통 아티스트 공연을 추천
async def test_card_both_interested_and_suggestions():
    shared = _artist("공통")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, user_a = await _user(ac)
        _, user_b = await _user(ac)
        await _connect(user_a, user_b)
        upcoming = await _concert("공통아티스트콘", [shared], start=20)
        async with AsyncSessionLocal() as db:
            for user_id in (user_a, user_b):
                db.add(ArtistFollow(user_id=user_id, artists=[{"artist_name": shared}]))
            await db.commit()
        suggested = (await _card(ac, token_a, user_b)).json()["next"]

        # 내가 예매하고 상대가 찜하면 둘 다 관심 공연으로 바뀜
        await _ticket(user_a, upcoming, past=False)
        async with AsyncSessionLocal() as db:
            db.add(ConcertFollow(user_id=user_b, concerts=[{"concert_id": str(upcoming)}]))
            await db.commit()
        interested = (await _card(ac, token_a, user_b)).json()["next"]

    assert [c["name"] for c in suggested["suggestions"]] == ["공통아티스트콘"]
    assert suggested["both_interested"] == []
    assert interested["both_interested"][0]["concert"]["name"] == "공통아티스트콘"
    assert interested["both_interested"][0]["my_status"] == "ticket"
    assert interested["both_interested"][0]["peer_status"] == "follow"
    assert interested["suggestions"] == []


# 상대 혼자 본 지난 공연은 카드 어디에도 안 나옴
async def test_card_hides_peer_solo_history():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, user_a = await _user(ac)
        _, user_b = await _user(ac)
        await _connect(user_a, user_b)
        solo = await _concert("상대만본공연", [_artist("솔로")], start=-10)
        await _ticket(user_b, solo, past=True)

        res = await _card(ac, token_a, user_b)

    assert res.status_code == 200
    assert "상대만본공연" not in res.text
    assert res.json()["us"]["compatibility"] is None


# 궁합: 장르 분포가 같으면 점수가 높고 겹치는 장르를 내림, 다른 장르만 보면 낮음
async def test_card_compatibility_uses_genres():
    from app.models.artist_normalization import CanonicalArtist

    rock_a, rock_b, hiphop = _artist("록A"), _artist("록B"), _artist("힙합")
    async with AsyncSessionLocal() as db:
        for name, genres in ((rock_a, ["rock"]), (rock_b, ["indie rock"]), (hiphop, ["hip hop"])):
            db.add(CanonicalArtist(canonical_name=name, mb_genres=genres, mb_genres_fetched_at=datetime.now(timezone.utc)))
        await db.commit()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, user_a = await _user(ac)
        _, user_b = await _user(ac)
        _, user_c = await _user(ac)
        await _connect(user_a, user_b)
        await _connect(user_a, user_c)
        async with AsyncSessionLocal() as db:
            db.add(ArtistFollow(user_id=user_a, artists=[{"artist_name": rock_a}]))
            db.add(ArtistFollow(user_id=user_b, artists=[{"artist_name": rock_b}]))
            db.add(ArtistFollow(user_id=user_c, artists=[{"artist_name": hiphop}]))
            await db.commit()

        same_genre = (await _card(ac, token_a, user_b)).json()["us"]["compatibility"]
        other_genre = (await _card(ac, token_a, user_c)).json()["us"]["compatibility"]

    # 겹치는 아티스트는 없지만 장르가 같아 장르 항목만큼 점수가 남
    assert same_genre["top_shared_genre"] == "록/밴드"
    assert same_genre["shared_artist_count"] == 0
    assert other_genre["top_shared_genre"] is None
    assert same_genre["score"] > other_genre["score"]


async def _canonical(name: str, country: str | None, genres: list[str] | None = None) -> None:
    from app.models.artist_normalization import CanonicalArtist

    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(
            canonical_name=name, mb_country=country, mb_genres=genres,
            mb_genres_fetched_at=datetime.now(timezone.utc),
        ))
        await db.commit()


async def _follow(user_id: uuid.UUID, artists: list[str]) -> None:
    async with AsyncSessionLocal() as db:
        db.add(ArtistFollow(user_id=user_id, artists=[{"artist_name": a} for a in artists]))
        await db.commit()


# 취향 요약: 국적 큰 줄기 + 대표 장르, 각자 따로 계산
async def test_card_taste_summary():
    anglo_rock = [_artist("영미록") for _ in range(3)]
    kpop = [_artist("케이팝") for _ in range(3)]
    for name, country in zip(anglo_rock, ("US", "GB", "US")):
        await _canonical(name, country, ["rock"])
    for name in kpop:
        await _canonical(name, "KR", ["k-pop"])

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, user_a = await _user(ac)
        _, user_b = await _user(ac)
        await _connect(user_a, user_b)
        await _follow(user_a, anglo_rock)
        await _follow(user_b, kpop)

        us = (await _card(ac, token_a, user_b)).json()["us"]

    assert us["my_taste"] == {"origins": ["anglo"], "origin_mixed": False, "genres": ["록/밴드"]}
    assert us["peer_taste"] == {"origins": ["domestic"], "origin_mixed": False, "genres": ["K-pop"]}


# 국적이 두 줄기로 나뉘면 둘 다, 세 줄기 이상 고르면 "여러 나라", 아티스트가 적으면 판단 안 함
async def test_card_taste_origin_split_mixed_and_too_few():
    split = [_artist("반반") for _ in range(4)]
    for name, country in zip(split, ("KR", "KR", "JP", "JP")):
        await _canonical(name, country)
    mixed = [_artist("섞임") for _ in range(3)]
    for name, country in zip(mixed, ("KR", "JP", "US")):
        await _canonical(name, country)
    few = [_artist("적음") for _ in range(2)]
    for name in few:
        await _canonical(name, "KR", ["ballad"])

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        token_a, user_a = await _user(ac)
        _, user_b = await _user(ac)
        _, user_c = await _user(ac)
        await _connect(user_a, user_b)
        await _connect(user_a, user_c)
        await _follow(user_a, split)
        await _follow(user_b, mixed)
        await _follow(user_c, few)

        with_b = (await _card(ac, token_a, user_b)).json()["us"]
        with_c = (await _card(ac, token_a, user_c)).json()["us"]

    assert sorted(with_b["my_taste"]["origins"]) == ["domestic", "japan"]
    assert with_b["my_taste"]["genres"] == []  # 장르 정보 없음
    assert with_b["peer_taste"] == {"origins": [], "origin_mixed": True, "genres": []}
    assert with_c["peer_taste"] is None
