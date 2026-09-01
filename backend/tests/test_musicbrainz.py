from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from app.services.musicbrainz import fetch_member_of_band_relations, search_artist


def _resp(status_code: int, artists: list[dict] | None = None) -> MagicMock:
    resp = MagicMock()
    resp.status_code = status_code
    resp.json.return_value = {"artists": artists or []}
    return resp


def _mb_artist(mbid: str, name: str, score: int = 100, country: str | None = "KR") -> dict:
    return {"id": mbid, "name": name, "score": score, "country": country}


@pytest.mark.asyncio
async def test_search_artist_uses_country_kr_result_without_fallback_call():
    client = MagicMock()
    client.get = AsyncMock(return_value=_resp(200, [_mb_artist("mbid-1", "Nell")]))

    with patch("app.services.musicbrainz._MIN_REQUEST_INTERVAL", 0):
        candidates = await search_artist("넬", client=client)

    assert len(candidates) == 1
    assert candidates[0].source == "country_kr"
    assert candidates[0].name == "Nell"
    assert client.get.await_count == 1  # country:KR에서 바로 찾았으면 일반 쿼리로 폴백 안 함


@pytest.mark.asyncio
async def test_search_artist_falls_back_to_general_when_country_kr_empty():
    client = MagicMock()
    client.get = AsyncMock(
        side_effect=[
            _resp(200, []),  # country:KR -> 없음
            _resp(200, [_mb_artist("mbid-2", "Nick Hakim", country="US")]),  # 일반 검색 -> 있음
        ]
    )

    with patch("app.services.musicbrainz._MIN_REQUEST_INTERVAL", 0):
        candidates = await search_artist("HAKIM", client=client)

    assert client.get.await_count == 2
    assert len(candidates) == 1
    assert candidates[0].source == "general"  # country 필터 없이 찾은 결과라고 표시됨


@pytest.mark.asyncio
async def test_search_artist_retries_on_503_then_succeeds():
    client = MagicMock()
    client.get = AsyncMock(
        side_effect=[
            _resp(503),
            _resp(200, [_mb_artist("mbid-3", "TWICE")]),
        ]
    )

    with patch("app.services.musicbrainz._MIN_REQUEST_INTERVAL", 0), patch(
        "app.services.musicbrainz._RETRY_BACKOFF_SECONDS", 0
    ):
        candidates = await search_artist("TWICE", client=client)

    assert client.get.await_count == 2
    assert candidates[0].name == "TWICE"


@pytest.mark.asyncio
async def test_search_artist_gives_up_after_max_retries():
    client = MagicMock()
    client.get = AsyncMock(side_effect=httpx.ConnectError("boom"))

    with patch("app.services.musicbrainz._MIN_REQUEST_INTERVAL", 0), patch(
        "app.services.musicbrainz._RETRY_BACKOFF_SECONDS", 0
    ):
        candidates = await search_artist("아무이름", client=client)

    assert candidates == []
    # 초기 시도 1회 + 재시도 2회 = 3회, country:KR/general 각각 시도하니 총 6회
    assert client.get.await_count == 6


# fetch_member_of_band_relations

def _rels_resp(relations: list[dict]) -> MagicMock:
    resp = MagicMock()
    resp.status_code = 200
    resp.json.return_value = {"relations": relations}
    return resp


@pytest.mark.asyncio
async def test_fetch_relations_filters_to_member_of_band_and_parses_current():
    client = MagicMock()
    client.get = AsyncMock(
        return_value=_rels_resp(
            [
                {
                    "type": "member of band",
                    "end": None,
                    "artist": {"id": "mbid-current", "name": "최정훈", "type": "Person"},
                },
                {
                    "type": "member of band",
                    "end": "2019-05-24",
                    "artist": {"id": "mbid-past", "name": "유영현", "type": "Person"},
                },
                {  # member of band가 아닌 다른 관계 타입은 무시
                    "type": "founder of",
                    "end": None,
                    "artist": {"id": "mbid-other", "name": "무관한관계", "type": "Person"},
                },
            ]
        )
    )

    with patch("app.services.musicbrainz._MIN_REQUEST_INTERVAL", 0):
        relations = await fetch_member_of_band_relations("band-mbid", client=client)

    assert len(relations) == 2
    current = next(r for r in relations if r.mbid == "mbid-current")
    past = next(r for r in relations if r.mbid == "mbid-past")
    assert current.is_current is True
    assert past.is_current is False
    assert current.name == "최정훈"
    assert current.type == "Person"
