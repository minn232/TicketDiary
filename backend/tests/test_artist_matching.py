import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.concert import Concert
from app.models.social import ArtistFollow
from app.services.artist_matching import normalize_artist_names
from conftest import _get_token, kopis_mock


# 헬퍼

def _make_detail_xml(kopis_id: str, artist: str, poster: str = "https://example.com/poster.jpg") -> bytes:
    poster_tag = f"<poster>{poster}</poster>" if poster else "<poster></poster>"
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.30</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f"{poster_tag}"
        f"<genrenm>대중음악</genrenm>"
        f"<prfcast>{artist}</prfcast>"
        f"<pcseguidance></pcseguidance>"
        f"<sty></sty>"
        f"</db></dbs>"
    ).encode("utf-8")


async def _create_concert(kopis_id: str, artist: str, token: str, poster: str = "https://example.com/poster.jpg") -> str:
    with kopis_mock(_make_detail_xml(kopis_id, artist, poster)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert res.status_code == 200
    return res.json()["id"]


# normalize_artist_names 단위 테스트 (순수 함수, DB 불필요)

def test_normalize_reuses_similar_existing_name():
    known = {"10cm"}
    result = normalize_artist_names(["10CM"], known)
    assert result == ["10cm"]


def test_normalize_keeps_genuinely_new_name():
    known = {"10cm"}
    result = normalize_artist_names(["완전히다른아티스트"], known)
    assert result == ["완전히다른아티스트"]
    assert "완전히다른아티스트" in known  # known_names에도 반영되어야 다음 매칭에 재사용됨


def test_normalize_cross_script_not_merged():
    # 알려진 한계: 한글/영문처럼 스크립트가 다른 별칭은 문자열 유사도로 못 잡음
    known = {"방탄소년단"}
    result = normalize_artist_names(["BTS"], known)
    assert result == ["BTS"]


def test_normalize_reuses_within_same_batch():
    known: set[str] = set()
    result = normalize_artist_names(["10cm", "10CM"], known)
    assert result == ["10cm", "10cm"]


# 한글↔로마자 표기 매칭 (통용 표기: 김→Kim, 현→Hyun, 정→Jung 등)

def test_normalize_matches_hangul_to_informal_romanization():
    known = {"Kim Hyunjung"}
    result = normalize_artist_names(["김현정"], known)
    assert result == ["Kim Hyunjung"]


def test_normalize_matches_hangul_to_formal_romanization():
    known = {"Jin Hyeon Jun"}
    result = normalize_artist_names(["진현준"], known)
    assert result == ["Jin Hyeon Jun"]


def test_normalize_matches_romanization_reverse_direction():
    known = {"김현정"}
    result = normalize_artist_names(["Kim Hyunjung"], known)
    assert result == ["김현정"]


def test_normalize_romanization_does_not_false_positive_different_person():
    known = {"김현정"}
    result = normalize_artist_names(["박보검"], known)
    assert result == ["박보검"]
    assert "박보검" in known


def test_normalize_romanization_still_misses_semantic_alias():
    # 로마자 변환은 발음 표기 차이만 잡음 - 의미가 다른 별칭(방탄소년단 vs BTS)은 여전히 못 잡힘
    known = {"방탄소년단"}
    result = normalize_artist_names(["BTS"], known)
    assert result == ["BTS"]


# KOPIS 상세 조회 경로에 정규화가 반영되는지 통합 테스트

@pytest.mark.asyncio
async def test_kopis_detail_normalizes_against_existing_artist():
    token = await _get_token()
    # _parse_artists가 이미 공백은 strip하므로, 그것과 구분되게 대소문자 차이로 검증
    # (fuzzy matching의 대소문자 무시 정규화가 실제로 동작하는지 확인)
    base = f"Artist{uuid.uuid4().hex[:6]}"

    await _create_concert(f"PF_AM_BASE_{uuid.uuid4().hex[:6]}", base, token)
    concert_id = await _create_concert(f"PF_AM_DUP_{uuid.uuid4().hex[:6]}", base.upper(), token)

    async with AsyncSessionLocal() as db:
        result = await db.execute(select_concert_by_id(concert_id))
        concert = result.scalar_one()
        assert concert.artist_name == [base]


def select_concert_by_id(concert_id: str):
    from sqlalchemy import select

    return select(Concert).where(Concert.id == uuid.UUID(concert_id))


# POST /concerts/{concert_id}/artist-result 테스트

_LLM_API_KEY = "test-llm-key"


def _llm_headers():
    return {"Authorization": f"Bearer {_LLM_API_KEY}"}


@pytest.mark.asyncio
async def test_artist_result_normalizes_and_saves():
    token = await _get_token()
    existing = f"기존아티스트_{uuid.uuid4().hex}"
    await _create_concert(f"PF_AR_EXIST_{uuid.uuid4().hex[:6]}", existing, token)

    concert_id = await _create_concert(f"PF_AR_TARGET_{uuid.uuid4().hex[:6]}", "", token)

    body = {"artist_name": [f" {existing} ", "신규아티스트"]}

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json=body,
                headers=_llm_headers(),
            )

    assert res.status_code == 200
    assert res.json()["artist_name"] == [existing, "신규아티스트"]


# KOPIS 원본(실명/멤버명일 수 있음)이 채운 소규모 공연에 포스터 결과가 오면 합집합이 아니라
# 교체되는지 테스트 (예: 존박→박성규 케이스 - 포스터가 더 신뢰할 수 있는 활동명을 준다고 가정)
@pytest.mark.asyncio
async def test_artist_result_replaces_small_kopis_sourced_artist():
    token = await _get_token()
    kopis_name = f"KOPIS실명_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_AR_REPLACE_{uuid.uuid4().hex[:6]}", kopis_name, token)

    poster_name = f"포스터활동명_{uuid.uuid4().hex[:6]}"
    body = {"artist_name": [poster_name]}

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json=body,
                headers=_llm_headers(),
            )

    assert res.status_code == 200
    # KOPIS 이름은 사라지고 포스터 결과로 교체됨 (합집합이었다면 둘 다 남았을 것)
    assert res.json()["artist_name"] == [poster_name]


# 이미 4명 이상(페스티벌 추정)이면 라인업 유실 방지를 위해 교체 대신 기존처럼 합집합 유지
@pytest.mark.asyncio
async def test_artist_result_keeps_union_when_already_multi_artist():
    token = await _get_token()
    existing_names = [f"멤버{i}_{uuid.uuid4().hex[:4]}" for i in range(4)]
    concert_id = await _create_concert(
        f"PF_AR_UNION_{uuid.uuid4().hex[:6]}", ",".join(existing_names), token
    )

    new_name = f"추가아티스트_{uuid.uuid4().hex[:6]}"
    body = {"artist_name": [new_name]}

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json=body,
                headers=_llm_headers(),
            )

    assert res.status_code == 200
    assert set(res.json()["artist_name"]) == set(existing_names) | {new_name}


# 포스터 추출로 아티스트가 임계치(5명) 이상 확인되면 event_type이 SOLO->FESTIVAL로 승격되는지 테스트
@pytest.mark.asyncio
async def test_artist_result_upgrades_event_type_at_threshold():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_AR_UPGRADE_{uuid.uuid4().hex[:6]}", "", token)

    artists = [f"아티스트{uuid.uuid4().hex}" for _ in range(5)]
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json={"artist_name": artists},
                headers=_llm_headers(),
            )

    async with AsyncSessionLocal() as db:
        result = await db.execute(select_concert_by_id(concert_id))
        concert = result.scalar_one()
    assert concert.event_type == "FESTIVAL"


# VLM이 event_type=FESTIVAL로 판단하고 artist_name도 2명 이상이면, 5명 임계치 전이라도 승격됨
@pytest.mark.asyncio
async def test_artist_result_llm_festival_hint_upgrades_below_threshold():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_AR_LLMFES_{uuid.uuid4().hex[:6]}", "", token)

    artists = [f"아티스트{uuid.uuid4().hex}" for _ in range(2)]
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json={"artist_name": artists, "event_type": "FESTIVAL"},
                headers=_llm_headers(),
            )

    async with AsyncSessionLocal() as db:
        result = await db.execute(select_concert_by_id(concert_id))
        concert = result.scalar_one()
    assert concert.event_type == "FESTIVAL"


# VLM이 FESTIVAL이라고 판단해도 artist_name이 1명뿐이면(자기모순) 무시하고 승격 안 됨
@pytest.mark.asyncio
async def test_artist_result_llm_festival_hint_ignored_without_corroboration():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_AR_LLMFESNO_{uuid.uuid4().hex[:6]}", "", token)

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json={"artist_name": ["단독아티스트"], "event_type": "FESTIVAL"},
                headers=_llm_headers(),
            )

    async with AsyncSessionLocal() as db:
        result = await db.execute(select_concert_by_id(concert_id))
        concert = result.scalar_one()
    assert concert.event_type == "SOLO"


@pytest.mark.asyncio
async def test_artist_result_generates_news_feed_for_existing_follower():
    token = await _get_token()
    artist = f"소급알림아티스트_{uuid.uuid4().hex}"

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        follow_res = await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist}]},
            headers={"Authorization": f"Bearer {token}"},
        )
    assert follow_res.status_code == 200

    concert_id = await _create_concert(f"PF_AR_NF_{uuid.uuid4().hex[:6]}", "", token)

    body = {"artist_name": [artist]}
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json=body,
                headers=_llm_headers(),
            )
    assert res.status_code == 200

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        feed_res = await ac.get("/api/v1/social/feed", headers={"Authorization": f"Bearer {token}"})
    assert feed_res.status_code == 200
    matched = [f for f in feed_res.json() if f["artist_name"] == artist and f["concert_id"] == concert_id]
    assert len(matched) == 1


@pytest.mark.asyncio
async def test_artist_result_empty_body_no_change():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_AR_EMPTY_{uuid.uuid4().hex[:6]}", "", token)

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json={"artist_name": []},
                headers=_llm_headers(),
            )

    assert res.status_code == 200
    assert res.json()["artist_name"] == []


@pytest.mark.asyncio
async def test_artist_result_concert_not_found_404():
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{uuid.uuid4()}/artist-result",
                json={"artist_name": ["아티스트"]},
                headers=_llm_headers(),
            )

    assert res.status_code == 404


@pytest.mark.asyncio
async def test_artist_result_wrong_api_key_401():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_AR_AUTH_{uuid.uuid4().hex[:6]}", "", token)

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json={"artist_name": ["아티스트"]},
                headers={"Authorization": "Bearer wrong-key"},
            )

    assert res.status_code == 401


# send_posters_for_artist_extraction 배치 테스트

@pytest.mark.asyncio
async def test_send_posters_marks_attempted_only_on_success():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_SEND_{uuid.uuid4().hex[:6]}", "", token)

    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(return_value=mock_response)

    with patch("app.services.crawler.settings.LLM_ARTIST_URL", "https://llm.example.com/artist"), \
         patch("app.services.crawler.httpx.AsyncClient", return_value=mock_client):
        from app.services.crawler import send_posters_for_artist_extraction

        await send_posters_for_artist_extraction()

    async with AsyncSessionLocal() as db:
        result = await db.execute(select_concert_by_id(concert_id))
        concert = result.scalar_one()
        assert concert.artist_extraction_attempted_at is not None

    sent_payload = mock_client.post.call_args.kwargs["json"]
    assert any(item["concert_id"] == concert_id for item in sent_payload)


@pytest.mark.asyncio
async def test_send_posters_skips_when_no_url_configured():
    with patch("app.services.crawler.settings.LLM_ARTIST_URL", ""):
        from app.services.crawler import send_posters_for_artist_extraction

        # 예외 없이 조용히 리턴되는지만 확인
        await send_posters_for_artist_extraction()


@pytest.mark.asyncio
async def test_send_posters_respects_limit():
    # 수동 트리거 스크립트(scripts/send_artist_extraction_now.py)의 --limit 옵션이 실제로
    # 전송 대상을 제한하는지 확인 - 자정 배치 호출부는 limit을 안 넘기므로 영향 없음
    token = await _get_token()
    concert_id_1 = await _create_concert(f"PF_LIMIT_{uuid.uuid4().hex[:6]}", "", token)
    concert_id_2 = await _create_concert(f"PF_LIMIT_{uuid.uuid4().hex[:6]}", "", token)

    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(return_value=mock_response)

    with patch("app.services.crawler.settings.LLM_ARTIST_URL", "https://llm.example.com/artist"), \
         patch("app.services.crawler.httpx.AsyncClient", return_value=mock_client):
        from app.services.crawler import send_posters_for_artist_extraction

        sent = await send_posters_for_artist_extraction(limit=1)

    assert sent == 1
    assert len(mock_client.post.call_args.kwargs["json"]) == 1

    async with AsyncSessionLocal() as db:
        result = await db.execute(select_concert_by_id(concert_id_1))
        c1 = result.scalar_one()
        result = await db.execute(select_concert_by_id(concert_id_2))
        c2 = result.scalar_one()
    # 둘 중 하나만 attempted_at이 찍혀야 함(어느 쪽이 뽑히는지는 정렬 순서에 안 묶어둠)
    attempted_count = sum(1 for c in (c1, c2) if c.artist_extraction_attempted_at is not None)
    assert attempted_count == 1
