import uuid
from datetime import date, datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select, update

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_normalization import ArtistNormalizationStatus
from app.models.concert import Concert
from app.models.lineup import ConcertLineup
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
    # 둘 다 한글이면 로마자 경유 비교 자체를 안 함(아래 실사례 테스트) - 이 케이스는 글자 수/
    # 음절이 아예 달라 원문 fuzz.ratio에서도 걸릴 일이 없다는 걸 같이 확인
    known = {"김현정"}
    result = normalize_artist_names(["박보검"], known)
    assert result == ["박보검"]
    assert "박보검" in known


def test_normalize_romanization_skips_when_both_sides_are_hangul():
    # 실사례(admin 신규등록 버그): "김중연"을 신규 등록하려는데 전혀 다른 사람인 "김정균"과
    # 병합돼버림 - 원문 fuzz.ratio는 66.7%(안 걸림)인데, 로마자 변환하면 "중"/"정"처럼 다른
    # 음절이 근사 로마자표에서 우연히 겹쳐 95% 이상으로 잘못 매치됐던 게 원인. 둘 다 한글이면
    # 로마자 경유 비교를 아예 안 태우도록 고쳐서, 서로 다른 사람이 같은 canonical로 조용히
    # 흡수되지 않아야 함
    known = {"김정균"}
    result = normalize_artist_names(["김중연"], known)
    assert result == ["김중연"]
    assert "김중연" in known


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


# KOPIS 원본(실명/멤버명일 수 있음) 1명뿐인 솔로 공연에 포스터 결과가 오면 합집합이 아니라
# 교체돼야 함 - 본명/예명이 같이 남는 중복 노이즈를 막기 위함(사용자 피드백: KOPIS+LLM 병합이
# 본명/예명 중복을 만들어 수동 검수가 불편했음). 다인원/페스티벌은 여전히 합집합
# (test_artist_result_keeps_union_when_already_multi_artist 참고 - 라인업 유실 방지)
@pytest.mark.asyncio
async def test_artist_result_replaces_solo_kopis_sourced_artist():
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
    assert res.json()["artist_name"] == [poster_name]


# LLM이 블록리스트에 걸리는 이름만 줘서 정규화 후 빈 리스트가 되면 - 교체하지 않고 KOPIS 원본을
# 그대로 둬야 함(재즈/오케스트라처럼 LLM이 포스터에서 아예 못 뽑는 장르의 유일한 안전망)
@pytest.mark.asyncio
async def test_artist_result_keeps_kopis_when_llm_result_fully_blocklisted():
    token = await _get_token()
    kopis_name = f"KOPIS실명_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_AR_BLOCKLISTED_{uuid.uuid4().hex[:6]}", kopis_name, token)

    with patch("app.core.deps.settings") as mock_settings, patch(
        "app.services.artist_matching.is_blocklisted_artist_name", return_value=True
    ):
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json={"artist_name": ["사회자"]},
                headers=_llm_headers(),
            )

    assert res.status_code == 200
    assert res.json()["artist_name"] == [kopis_name]


# 4명 이상(페스티벌 추정)도 당연히 합집합 유지 (라인업 유실 방지)
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


# 이미 확정된 브랜드/공연장명 오탐(artist_blocklist.py)이 재발해도 DB엔 안 박히는지 확인
@pytest.mark.asyncio
async def test_artist_result_filters_blocklisted_names():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_AR_BLOCK_{uuid.uuid4().hex[:6]}", "", token)

    real_name = f"진짜아티스트_{uuid.uuid4().hex[:6]}"
    body = {"artist_name": ["NOL", "Various Artists", real_name]}

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json=body,
                headers=_llm_headers(),
            )

    assert res.status_code == 200
    assert res.json()["artist_name"] == [real_name]


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


# 콜백 유실 재시도 테스트 (artist_extraction_attempted_at/attempt_count 쿨다운)

async def _set_attempted(concert_id: str, attempted_at, attempt_count: int) -> None:
    async with AsyncSessionLocal() as db:
        await db.execute(
            update(Concert)
            .where(Concert.id == uuid.UUID(concert_id))
            .values(artist_extraction_attempted_at=attempted_at, artist_extraction_attempt_count=attempt_count)
        )
        await db.commit()


def _mock_llm_client():
    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(return_value=mock_response)
    return mock_client


# 이 테스트 모듈이 만든 다른 콘서트들이 같은 세션 DB에 남아 있어 같이 전송 대상에 잡힐 수
# 있으므로(파일 전체에서 DB를 공유), "아무것도 안 보냈다/딱 하나만 보냈다" 같은 전역 카운트
# 대신 특정 concert_id가 실제로 보내진 페이로드에 포함됐는지만 확인한다
def _sent_concert_ids(mock_client) -> set[str]:
    ids: set[str] = set()
    for call in mock_client.post.call_args_list:
        for item in call.kwargs["json"]:
            ids.add(item["concert_id"])
    return ids


# 쿨다운(24h) 이내에 이미 시도한 공연은 콜백이 안 왔어도 다시 대상이 되면 안 됨
# (매 배치마다 계속 재전송하면 낭비이므로 최소 간격을 둠)
@pytest.mark.asyncio
async def test_send_posters_skips_within_cooldown():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_RETRY_COOLDOWN_{uuid.uuid4().hex[:6]}", "", token)
    await _set_attempted(concert_id, datetime.now(timezone.utc) - timedelta(hours=1), 1)

    mock_client = _mock_llm_client()
    with patch("app.services.crawler.settings.LLM_ARTIST_URL", "https://llm.example.com/artist"), \
         patch("app.services.crawler.httpx.AsyncClient", return_value=mock_client):
        from app.services.crawler import send_posters_for_artist_extraction

        await send_posters_for_artist_extraction()

    assert concert_id not in _sent_concert_ids(mock_client)

    async with AsyncSessionLocal() as db:
        result = await db.execute(select_concert_by_id(concert_id))
        concert = result.scalar_one()
    assert concert.artist_extraction_attempt_count == 1  # 안 바뀜 - 재전송 안 됐다는 뜻


# 검수완료(admin_reviewed_at) 공연은 재전송 대상에서 제외돼야 함 - LLM이 다른 결과를 내면
# artist_name이 바뀌어 검수 상태가 다시 풀리는 노이즈를 막기 위함
@pytest.mark.asyncio
async def test_send_posters_skips_reviewed_concert():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_REVIEWED_{uuid.uuid4().hex[:6]}", "", token)
    async with AsyncSessionLocal() as db:
        await db.execute(
            update(Concert)
            .where(Concert.id == uuid.UUID(concert_id))
            .values(admin_reviewed_at=datetime.now(timezone.utc))
        )
        await db.commit()

    mock_client = _mock_llm_client()
    with patch("app.services.crawler.settings.LLM_ARTIST_URL", "https://llm.example.com/artist"), \
         patch("app.services.crawler.httpx.AsyncClient", return_value=mock_client):
        from app.services.crawler import send_posters_for_artist_extraction

        await send_posters_for_artist_extraction()

    assert concert_id not in _sent_concert_ids(mock_client)


# ai_reviewed_at(Claude 검수)도 admin_reviewed_at과 동일하게 재전송 대상에서 제외돼야 함
@pytest.mark.asyncio
async def test_send_posters_skips_ai_reviewed_concert():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_AIREVIEWED_{uuid.uuid4().hex[:6]}", "", token)
    async with AsyncSessionLocal() as db:
        await db.execute(
            update(Concert)
            .where(Concert.id == uuid.UUID(concert_id))
            .values(ai_reviewed_at=datetime.now(timezone.utc))
        )
        await db.commit()

    mock_client = _mock_llm_client()
    with patch("app.services.crawler.settings.LLM_ARTIST_URL", "https://llm.example.com/artist"), \
         patch("app.services.crawler.httpx.AsyncClient", return_value=mock_client):
        from app.services.crawler import send_posters_for_artist_extraction

        await send_posters_for_artist_extraction()

    assert concert_id not in _sent_concert_ids(mock_client)


# 콜백이 유실된 것으로 보이는 경우(쿨다운 지남 + 시도 횟수 상한 미만) 재전송되고,
# attempt_count가 증가하는지 테스트 - 이게 이번에 고친 핵심 동작
@pytest.mark.asyncio
async def test_send_posters_retries_after_cooldown_when_callback_lost():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_RETRY_OK_{uuid.uuid4().hex[:6]}", "", token)
    await _set_attempted(concert_id, datetime.now(timezone.utc) - timedelta(hours=25), 1)

    mock_client = _mock_llm_client()
    with patch("app.services.crawler.settings.LLM_ARTIST_URL", "https://llm.example.com/artist"), \
         patch("app.services.crawler.httpx.AsyncClient", return_value=mock_client):
        from app.services.crawler import send_posters_for_artist_extraction

        await send_posters_for_artist_extraction()

    assert concert_id in _sent_concert_ids(mock_client)

    async with AsyncSessionLocal() as db:
        result = await db.execute(select_concert_by_id(concert_id))
        concert = result.scalar_one()
    assert concert.artist_extraction_attempt_count == 2


# 시도 횟수가 상한(5회)에 도달하면 쿨다운이 지났어도 더 이상 재시도 대상이 아닌지 테스트
# (콜백이 계속 유실되는 구조적으로 안 되는 공연에 무한정 GPU 자원을 쓰지 않기 위한 상한)
@pytest.mark.asyncio
async def test_send_posters_gives_up_after_max_attempts():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_RETRY_GIVEUP_{uuid.uuid4().hex[:6]}", "", token)
    await _set_attempted(concert_id, datetime.now(timezone.utc) - timedelta(hours=25), 5)

    mock_client = _mock_llm_client()
    with patch("app.services.crawler.settings.LLM_ARTIST_URL", "https://llm.example.com/artist"), \
         patch("app.services.crawler.httpx.AsyncClient", return_value=mock_client):
        from app.services.crawler import send_posters_for_artist_extraction

        await send_posters_for_artist_extraction()

    assert concert_id not in _sent_concert_ids(mock_client)

    async with AsyncSessionLocal() as db:
        result = await db.execute(select_concert_by_id(concert_id))
        concert = result.scalar_one()
    assert concert.artist_extraction_attempt_count == 5  # 안 바뀜


# artist-result의 lineup으로 concert_lineups가 source="poster"로 채워지는지 테스트
@pytest.mark.asyncio
async def test_artist_result_lineup_upserts_with_poster_source():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_AR_LINEUP_{uuid.uuid4().hex[:6]}", "", token)

    body = {
        "artist_name": ["아티스트A"],
        "lineup": [{"artist": "아티스트A", "performance_date": "2030-06-01"}],
    }
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json=body,
                headers=_llm_headers(),
            )
    assert res.status_code == 200

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(ConcertLineup).where(ConcertLineup.concert_id == uuid.UUID(concert_id)))
        row = result.scalar_one()
    assert row.artist == "아티스트A"
    assert row.performance_date == date(2030, 6, 1)
    assert row.source == "poster"


# 포스터 추출(source=poster)이 먼저 배정을 채운 뒤, 크롤링 결과(source=crawl)가 같은
# (아티스트,날짜)를 다시 확인하면 source가 crawl로 승격되는지 테스트(병합 우선순위 확인)
@pytest.mark.asyncio
async def test_crawl_result_lineup_upgrades_poster_source():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_CR_LINEUP_UPG_{uuid.uuid4().hex[:6]}", "", token)

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result",
                json={
                    "artist_name": ["아티스트A"],
                    "lineup": [{"artist": "아티스트A", "performance_date": "2030-06-01"}],
                },
                headers=_llm_headers(),
            )
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={
                    "artist_name": ["아티스트A"],
                    "lineup": [{"artist": "아티스트A", "performance_date": "2030-06-01"}],
                },
                headers=_llm_headers(),
            )
    assert res.status_code == 200
    assert "lineup" in res.json()["updated"]

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(ConcertLineup).where(ConcertLineup.concert_id == uuid.UUID(concert_id)))
        row = result.scalar_one()
    assert row.source == "crawl"


# /crawl-result(크롤링 스크린샷)도 /artist-result(포스터 추출)와 같은 solo-replace 로직을
# 공유해야 함 - 두 웹훅 중 어느 쪽이 이 공연을 먼저 건드릴지 스케줄 순서로 보장할 수 없어서
# (실측: 매일 밤 크롤링 쪽이 포스터 추출보다 먼저 돔) 어느 쪽으로 들어와도 동일하게 KOPIS
# 원본을 교체해야 본명/예명 중복이 안 남음(merge_or_replace_solo_seed 참고)
@pytest.mark.asyncio
async def test_crawl_result_also_replaces_solo_kopis_sourced_artist():
    token = await _get_token()
    kopis_name = f"KOPIS실명_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_CR_REPLACE_{uuid.uuid4().hex[:6]}", kopis_name, token)

    crawl_name = f"크롤확인활동명_{uuid.uuid4().hex[:6]}"
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"artist_name": [crawl_name]},
                headers=_llm_headers(),
            )

    assert res.status_code == 200
    assert "artist_name" in res.json()["updated"]  # crawl-result 응답엔 필드명만 옴(artist_name 값 자체는 없음)

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        concert = result.scalar_one()
    assert concert.artist_name == [crawl_name]


# 다인원(2명+)/페스티벌 공연은 크롤링 결과를 처음 받으면 1회 교체(크롤링이 KOPIS보다 정보가
# 많고 재시도도 여러 번이라 더 신뢰할 만하다는 사용자 판단) - 그 다음부터는 합집합만
# (merge_crawl_artist_names 참고)
@pytest.mark.asyncio
async def test_crawl_result_replaces_multi_artist_seed_on_first_crawl_only():
    token = await _get_token()
    kopis_names = [f"KOPIS멤버{i}_{uuid.uuid4().hex[:4]}" for i in range(2)]
    concert_id = await _create_concert(
        f"PF_CR_MULTI_SEED_{uuid.uuid4().hex[:6]}", ",".join(kopis_names), token
    )

    # 첫 크롤링 - 기존과 동수 이상이면 통째로 교체
    crawl_names_1 = [f"크롤확인{i}_{uuid.uuid4().hex[:4]}" for i in range(2)]
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res1 = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"artist_name": crawl_names_1},
                headers=_llm_headers(),
            )
    assert res1.status_code == 200

    async with AsyncSessionLocal() as db:
        concert = (
            await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        ).scalar_one()
    assert set(concert.artist_name) == set(crawl_names_1)  # KOPIS 원본은 안 남음
    assert concert.crawl_lineup_seeded_at is not None

    # 두 번째 크롤링부터는 합집합 - 이번엔 KOPIS 이름이 다시 와도 안 지워지고 그냥 더해짐
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res2 = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"artist_name": [kopis_names[0]]},
                headers=_llm_headers(),
            )
    assert res2.status_code == 200

    async with AsyncSessionLocal() as db:
        concert = (
            await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        ).scalar_one()
    assert set(concert.artist_name) == set(crawl_names_1) | {kopis_names[0]}


# 첫 크롤링 결과가 기존(KOPIS)보다 인원이 적으면(부분적으로만 읽힌 경우) 안전하게 합집합으로
# 대체해 라인업을 줄이지 않아야 함 - 단 이번 호출로 "1회 교체" 기회는 소진됨(계속 재시도하지 않음)
@pytest.mark.asyncio
async def test_crawl_result_first_crawl_smaller_than_existing_unions_instead():
    token = await _get_token()
    kopis_names = [f"KOPIS멤버{i}_{uuid.uuid4().hex[:4]}" for i in range(3)]
    concert_id = await _create_concert(
        f"PF_CR_PARTIAL_{uuid.uuid4().hex[:6]}", ",".join(kopis_names), token
    )

    partial_name = f"크롤일부{uuid.uuid4().hex[:4]}"
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"artist_name": [partial_name]},
                headers=_llm_headers(),
            )
    assert res.status_code == 200

    async with AsyncSessionLocal() as db:
        concert = (
            await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        ).scalar_one()
    assert set(concert.artist_name) == set(kopis_names) | {partial_name}  # 안 줄어듦
    assert concert.crawl_lineup_seeded_at is not None  # 그래도 1회 기회는 소진됨


# /crawl-result 웹훅이 아티스트명을 병합하고도 정규화 큐잉을 안 해서, 크롤링으로만 들어온
# 표기가 MusicBrainz 정규화 기회를 영영 못 얻던 구조적 갭 회귀 테스트("HANRORO"가 canonical
# "한로로"로 안 바뀌던 실사례로 발견). /artist-result와 동일하게 여기서도 큐잉돼야 함
@pytest.mark.asyncio
async def test_crawl_result_queues_artist_names_for_normalization():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_CR_QUEUE_{uuid.uuid4().hex[:6]}", "", token)
    artist_name = f"크롤아티스트_{uuid.uuid4().hex[:6]}"

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"artist_name": [artist_name]},
                headers=_llm_headers(),
            )
    assert res.status_code == 200
    assert "artist_name" in res.json()["updated"]

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistNormalizationStatus).where(
                ArtistNormalizationStatus.concert_id == uuid.UUID(concert_id),
                ArtistNormalizationStatus.artist_text == artist_name,
            )
        )
        row = result.scalar_one()
    assert row.status == "pending"


# 이번 호출로 실제로 바뀐 게 하나도 없어도(이미 같은 아티스트명) 큐잉 자체는 독립적으로
# 커밋돼야 함 - "if updated: commit()"에 얹혀갔다면 updated가 비어있을 때 큐잉이 세션과 함께
# 롤백돼 유실됐을 상황을 재현한 회귀 테스트
@pytest.mark.asyncio
async def test_crawl_result_queues_even_when_nothing_else_changed():
    token = await _get_token()
    artist_name = f"이미있는아티스트_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_CR_NOOPQ_{uuid.uuid4().hex[:6]}", artist_name, token)

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"artist_name": [artist_name]},  # 이미 있는 이름 그대로 -> merge 결과 동일 -> updated 안 채워짐
                headers=_llm_headers(),
            )
    assert res.status_code == 200
    assert res.json()["updated"] == []

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistNormalizationStatus).where(
                ArtistNormalizationStatus.concert_id == uuid.UUID(concert_id),
                ArtistNormalizationStatus.artist_text == artist_name,
            )
        )
        row = result.scalar_one()
    assert row.status == "pending"


# admin이 검수 완료로 표시해둔 공연이라도, 자동 파이프라인(크롤링 웹훅)이 artist_name을 실제로
# 바꾸면 검수 상태가 무효화(admin_reviewed_at=None)돼야 함 - 최신 데이터 기준을 유지하기 위함
@pytest.mark.asyncio
async def test_crawl_result_clears_admin_review_when_artist_name_changes():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_CR_REVIEWCLEAR_{uuid.uuid4().hex[:6]}", "기존아티스트", token)

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, uuid.UUID(concert_id))
        concert.admin_reviewed_at = datetime.now(timezone.utc)
        await db.commit()

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"artist_name": ["새로크롤링된아티스트"]},
                headers=_llm_headers(),
            )

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, uuid.UUID(concert_id))
    assert concert.admin_reviewed_at is None
