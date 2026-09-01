import uuid
from datetime import date
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_normalization import (
    ArtistAlias,
    ArtistGroupMembership,
    ArtistNormalizationStatus,
    CanonicalArtist,
)
from app.models.concert import Concert
from app.models.lineup import ConcertLineup
from app.services.artist_normalization import (
    apply_canonical_replacement,
    decide_match,
    expand_follow_index_with_group_relations,
    find_canonical_by_alias,
    normalize_pending_artists,
    normalize_specific_artists,
    queue_for_normalization,
)
from app.services.kopis import _build_follow_index, _create_news_feeds_for_concert
from app.services.musicbrainz import ArtistCandidate, BandRelation
from conftest import _get_token, kopis_mock

_LLM_API_KEY = "test-llm-key"


async def _get_user_id(token: str) -> uuid.UUID:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    return uuid.UUID(res.json()["id"])


async def _follow_artist(token: str, artist_name: str) -> None:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers={"Authorization": f"Bearer {token}"},
        )
    assert res.status_code == 200, res.text


def _llm_headers():
    return {"Authorization": f"Bearer {_LLM_API_KEY}"}


def _make_detail_xml(kopis_id: str, artist: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.30</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f"<poster>https://example.com/poster.jpg</poster>"
        f"<genrenm>대중음악</genrenm>"
        f"<prfcast>{artist}</prfcast>"
        f"<pcseguidance></pcseguidance>"
        f"<sty></sty>"
        f"</db></dbs>"
    ).encode("utf-8")


async def _create_concert(kopis_id: str, artist: str, token: str) -> str:
    with kopis_mock(_make_detail_xml(kopis_id, artist)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(f"/api/v1/concerts/{kopis_id}", headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 200
    return res.json()["id"]


def _kr_candidate(name: str, score: int = 100, mbid: str | None = None) -> ArtistCandidate:
    return ArtistCandidate(mbid=mbid or uuid.uuid4().hex, name=name, score=score, country="KR", source="country_kr")


def _general_candidate(name: str, score: int = 100, mbid: str | None = None) -> ArtistCandidate:
    return ArtistCandidate(mbid=mbid or uuid.uuid4().hex, name=name, score=score, country=None, source="general")


# normalize_pending_artists()는 concert_id로 스코프되지 않고 큐 전체를 처리하는 배치라, 세션
# 스코프로 공유되는 테스트 DB에서 다른 테스트가 남겨둔 pending row까지 같이 집어갈 수 있다.
# 배치를 직접 호출하는 테스트는 실행 전에 이걸로 큐를 비워서 자기 데이터만 처리되게 한다.
async def _clear_pending_queue() -> None:
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistNormalizationStatus).where(ArtistNormalizationStatus.status == "pending")
        )
        for row in result.scalars().all():
            await db.delete(row)
        await db.commit()


# decide_match - 순수 함수, DB/네트워크 불필요. country:KR 여부가 아니라 "후보 유일성"이
# 확정 기준(2026-08-31), 2026-09-01엔 부분 문자열 오탐 방지 검증도 추가됨(아래)

def test_decide_match_single_high_score_country_kr_matches():
    status, winner = decide_match([_kr_candidate("Nell", score=100)], "Nell")
    assert status == "matched"
    assert winner.name == "Nell"


def test_decide_match_single_high_score_general_also_matches():
    # 실측 회귀 케이스: Konomi Suzuki/Alessia Cara처럼 country:KR은 없지만 후보가 유일하면
    # 확정돼야 함 - 국적이 아니라 "동명이인 후보가 없다"가 진짜 안전 신호였음
    status, winner = decide_match([_general_candidate("Konomi Suzuki", score=100)], "Konomi Suzuki")
    assert status == "matched"
    assert winner.name == "Konomi Suzuki"


def test_decide_match_single_low_score_unconfirmed():
    status, winner = decide_match([_kr_candidate("Nell", score=50)], "Nell")
    assert status == "unconfirmed"
    assert winner is None


def test_decide_match_close_scores_is_ambiguous():
    # HAKIM 실측 사례 재현: 후보 여럿이 점수 차이 없이(100/98) 몰려있으면 애매함으로 남김
    status, winner = decide_match(
        [_general_candidate("Hakim Norbert", score=100), _general_candidate("Hakim", score=98)], "HAKIM"
    )
    assert status == "ambiguous"
    assert winner is None


def test_decide_match_clear_score_gap_matches_despite_multiple_candidates():
    # 후보가 여럿이어도 1등이 압도적으로 두드러지면(점수 차이 큼) 확정
    status, winner = decide_match(
        [_general_candidate("정확한이름", score=100), _general_candidate("전혀다른사람", score=60)], "정확한이름"
    )
    assert status == "matched"
    assert winner.name == "정확한이름"


def test_decide_match_no_candidates_unconfirmed():
    status, winner = decide_match([], "아무개")
    assert status == "unconfirmed"
    assert winner is None


# 실측 발견(2026-09-01): 후보 이름이 쿼리한 이름의 부분 문자열일 때 점수/후보수만으로는
# 못 걸러지던 오탐 - 확정 직전에 이름 유사도를 한 번 더 검증

def test_decide_match_rejects_truncated_surname_match():
    # 실측: 최정철 검색 시 유일 후보가 "정철"(성 소실)로 나와 잘못 확정되던 사례
    status, winner = decide_match([_kr_candidate("정철", score=100)], "최정철")
    assert status == "ambiguous"
    assert winner is None


def test_decide_match_rejects_generic_word_matched_to_unrelated_famous_artist():
    # 실측: METHOD(메탈 밴드로 추정) 검색이 점수차 15(임계치)로 유명 일렉트로닉 듀오
    # The Crystal Method에 잘못 확정되던 사례
    status, winner = decide_match(
        [_general_candidate("The Crystal Method", score=100), _general_candidate("Method Man", score=85)], "METHOD"
    )
    assert status == "ambiguous"
    assert winner is None


def test_decide_match_allows_cross_script_alias_despite_dissimilar_strings():
    # 문자열은 전혀 안 닮았어도 스크립트가 다르면(권지용/G-DRAGON처럼) 정상 별칭 매치일 수
    # 있으니 부분 문자열 검사를 적용하지 않음
    status, winner = decide_match([_kr_candidate("G-DRAGON", score=100)], "권지용")
    assert status == "matched"
    assert winner.name == "G-DRAGON"


def test_decide_match_allows_same_script_alias_that_is_not_a_substring():
    # 같은 스크립트라도 부분 문자열 관계가 아니면(진짜 본명<->활동명 별칭) 그대로 확정
    status, winner = decide_match([_general_candidate("Freddie Gibbs", score=100)], "Fredrick Tipton")
    assert status == "matched"
    assert winner.name == "Freddie Gibbs"


# queue_for_normalization

@pytest.mark.asyncio
async def test_queue_for_normalization_is_idempotent():
    token = await _get_token()
    concert_id = uuid.UUID(await _create_concert(f"PF_QN_{uuid.uuid4().hex[:6]}", "아티스트A", token))

    async with AsyncSessionLocal() as db:
        await queue_for_normalization(db, concert_id, ["아티스트A", "아티스트B"])
        await queue_for_normalization(db, concert_id, ["아티스트B", "아티스트C"])  # 일부 중복

        result = await db.execute(
            select(ArtistNormalizationStatus.artist_text).where(ArtistNormalizationStatus.concert_id == concert_id)
        )
        texts = sorted(result.scalars().all())
    assert texts == ["아티스트A", "아티스트B", "아티스트C"]


# apply_canonical_replacement

@pytest.mark.asyncio
async def test_apply_canonical_replacement_updates_artist_name_and_lineup():
    token = await _get_token()
    concert_id = uuid.UUID(await _create_concert(f"PF_ACR_{uuid.uuid4().hex[:6]}", "넬", token))

    async with AsyncSessionLocal() as db:
        db.add(ConcertLineup(concert_id=concert_id, artist="넬", performance_date=date(2030, 6, 1), source="poster"))
        await db.commit()

        await apply_canonical_replacement(db, concert_id, "넬", "Nell")
        await db.commit()

        concert = await db.get(Concert, concert_id)
        assert concert.artist_name == ["Nell"]

        lineup_result = await db.execute(select(ConcertLineup).where(ConcertLineup.concert_id == concert_id))
        lineup_rows = lineup_result.scalars().all()
        assert [row.artist for row in lineup_rows] == ["Nell"]


@pytest.mark.asyncio
async def test_apply_canonical_replacement_dedups_lineup_conflict():
    token = await _get_token()
    concert_id = uuid.UUID(await _create_concert(f"PF_ACRD_{uuid.uuid4().hex[:6]}", "넬,Nell", token))

    async with AsyncSessionLocal() as db:
        # 같은 날짜에 "넬"(poster)과 "Nell"(crawl)이 이미 둘 다 있는 상황(치환 전 중복 발생 케이스)
        d = date(2030, 6, 1)
        db.add(ConcertLineup(concert_id=concert_id, artist="넬", performance_date=d, source="poster"))
        db.add(ConcertLineup(concert_id=concert_id, artist="Nell", performance_date=d, source="crawl"))
        await db.commit()

        await apply_canonical_replacement(db, concert_id, "넬", "Nell")
        await db.commit()

        lineup_result = await db.execute(
            select(ConcertLineup).where(ConcertLineup.concert_id == concert_id, ConcertLineup.performance_date == d)
        )
        rows = lineup_result.scalars().all()
        # 중복 row 없이 하나만 남아야 하고, source는 더 신뢰도 높은 "crawl"이 유지돼야 함
        assert len(rows) == 1
        assert rows[0].artist == "Nell"
        assert rows[0].source == "crawl"


# normalize_pending_artists (배치 본체, search_artist는 mock)

# KOPIS 원본 라인업 보강(_supplement_from_kopis_originals)이 매 배치 실행마다 실제 KOPIS API를
# 조회하지 않도록 - 그 동작 자체를 검증하는 테스트가 아니면 빈 결과로 무력화해서 테스트가
# 네트워크에 의존하지 않고 빠르게 끝나게 함(_create_concert의 KOPIS 목킹과는 별개 지점)
def _no_kopis_supplement():
    return patch("app.services.kopis._fetch_kopis_detail_data", new=AsyncMock(return_value={"artist_name": []}))


# 새로 매치된 canonical마다 _process_one이 관계 조회(fetch_member_of_band_relations)를 같이
# 트리거하는데, 관계 자체를 검증하지 않는 테스트에서 안 막아두면 매번 가짜 mbid로 실제
# MusicBrainz에 조회를 나가서(404 -> 재시도 2회+백오프) 테스트가 수 초씩 느려짐
def _no_relation_fetch():
    return patch("app.services.artist_normalization.fetch_member_of_band_relations", new=AsyncMock(return_value=[]))


@pytest.mark.asyncio
async def test_normalize_pending_artists_matches_via_musicbrainz():
    await _clear_pending_queue()
    token = await _get_token()
    concert_id = uuid.UUID(await _create_concert(f"PF_NP_MATCH_{uuid.uuid4().hex[:6]}", "넬", token))

    async with AsyncSessionLocal() as db:
        await queue_for_normalization(db, concert_id, ["넬"])

    with _no_kopis_supplement(), _no_relation_fetch(), patch(
        "app.services.artist_normalization.search_artist",
        new=AsyncMock(return_value=[_kr_candidate("Nell", score=100)]),
    ):
        stats = await normalize_pending_artists(limit=10)

    assert stats["matched"] == 1

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        assert concert.artist_name == ["Nell"]

        status_result = await db.execute(
            select(ArtistNormalizationStatus).where(ArtistNormalizationStatus.concert_id == concert_id)
        )
        row = status_result.scalar_one()
        assert row.status == "matched"
        assert row.attempt_count == 1

        canonical = await find_canonical_by_alias(db, "넬")
        assert canonical is not None
        assert canonical.canonical_name == "Nell"
        # canonical_name 자체로도 바로 찾아져야 함(별도 alias row 없이도)
        canonical_by_own_name = await find_canonical_by_alias(db, "Nell")
        assert canonical_by_own_name.id == canonical.id


@pytest.mark.asyncio
async def test_normalize_pending_artists_local_alias_skips_api_call():
    await _clear_pending_queue()
    token = await _get_token()
    concert_id = uuid.UUID(await _create_concert(f"PF_NP_LOCAL_{uuid.uuid4().hex[:6]}", "넬", token))

    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid="mbid-nell", canonical_name="Nell")
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text="넬", source="musicbrainz"))
        await db.commit()

        await queue_for_normalization(db, concert_id, ["넬"])

    mock_search = AsyncMock(side_effect=AssertionError("로컬 alias가 있으면 API를 호출하면 안 됨"))
    with _no_kopis_supplement(), patch("app.services.artist_normalization.search_artist", new=mock_search):
        stats = await normalize_pending_artists(limit=10)

    assert stats["matched"] == 1
    mock_search.assert_not_called()

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        assert concert.artist_name == ["Nell"]


@pytest.mark.asyncio
async def test_normalize_pending_artists_no_match_keeps_raw_name():
    await _clear_pending_queue()
    token = await _get_token()
    raw_name = f"인디밴드_{uuid.uuid4().hex[:6]}"
    concert_id = uuid.UUID(await _create_concert(f"PF_NP_NOMATCH_{uuid.uuid4().hex[:6]}", raw_name, token))

    async with AsyncSessionLocal() as db:
        await queue_for_normalization(db, concert_id, [raw_name])

    with _no_kopis_supplement(), patch("app.services.artist_normalization.search_artist", new=AsyncMock(return_value=[])):
        stats = await normalize_pending_artists(limit=10)

    assert stats["unconfirmed"] == 1

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        assert concert.artist_name == [raw_name]  # 원본 표기 그대로 유지, 삭제/숨김 없음

        status_result = await db.execute(
            select(ArtistNormalizationStatus).where(ArtistNormalizationStatus.concert_id == concert_id)
        )
        assert status_result.scalar_one().status == "unconfirmed"


@pytest.mark.asyncio
async def test_normalize_pending_artists_dry_run_does_not_persist():
    await _clear_pending_queue()
    token = await _get_token()
    concert_id = uuid.UUID(await _create_concert(f"PF_NP_DRY_{uuid.uuid4().hex[:6]}", "넬", token))

    async with AsyncSessionLocal() as db:
        await queue_for_normalization(db, concert_id, ["넬"])

    with _no_kopis_supplement(), _no_relation_fetch(), patch(
        "app.services.artist_normalization.search_artist",
        new=AsyncMock(return_value=[_kr_candidate("Nell", score=100)]),
    ):
        stats = await normalize_pending_artists(limit=10, dry_run=True)

    assert stats["matched"] == 1  # 통계는 집계되지만

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        assert concert.artist_name == ["넬"]  # DB엔 반영 안 됨(롤백)

        status_result = await db.execute(
            select(ArtistNormalizationStatus).where(ArtistNormalizationStatus.concert_id == concert_id)
        )
        assert status_result.scalar_one().status == "pending"  # 상태도 그대로


# normalize_specific_artists - 웹훅 도착 직후 즉시 트리거되는 좁은 범위 정규화 (pending
# 전체를 훑는 normalize_pending_artists와 달리 concert_id+이름 목록으로 좁혀서 처리)

@pytest.mark.asyncio
async def test_normalize_specific_artists_only_processes_given_names():
    await _clear_pending_queue()
    token = await _get_token()
    concert_id = uuid.UUID(await _create_concert(f"PF_NSA_{uuid.uuid4().hex[:6]}", "넬,다른아티스트", token))

    async with AsyncSessionLocal() as db:
        await queue_for_normalization(db, concert_id, ["넬", "다른아티스트"])

    with _no_relation_fetch(), patch(
        "app.services.artist_normalization.search_artist",
        new=AsyncMock(return_value=[_kr_candidate("Nell", score=100)]),
    ):
        stats = await normalize_specific_artists(concert_id, ["넬"])

    assert stats["matched"] == 1

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistNormalizationStatus).where(ArtistNormalizationStatus.concert_id == concert_id)
        )
        rows = {r.artist_text: r.status for r in result.scalars().all()}
    assert rows["넬"] == "matched"
    assert rows["다른아티스트"] == "pending"  # 목록에 없는 이름은 안 건드림


@pytest.mark.asyncio
async def test_normalize_specific_artists_ignores_other_concerts():
    await _clear_pending_queue()
    token = await _get_token()
    concert_a = uuid.UUID(await _create_concert(f"PF_NSA_A_{uuid.uuid4().hex[:6]}", "같은이름", token))
    concert_b = uuid.UUID(await _create_concert(f"PF_NSA_B_{uuid.uuid4().hex[:6]}", "같은이름", token))

    async with AsyncSessionLocal() as db:
        await queue_for_normalization(db, concert_a, ["같은이름"])
        await queue_for_normalization(db, concert_b, ["같은이름"])

    mock_search = AsyncMock(return_value=[_general_candidate("Same Name", score=100)])
    with _no_relation_fetch(), patch("app.services.artist_normalization.search_artist", new=mock_search):
        stats = await normalize_specific_artists(concert_a, ["같은이름"])

    assert stats["matched"] == 1
    mock_search.assert_awaited_once()  # concert_b 것까지 같이 처리하지 않음(호출 1회로 끝)

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistNormalizationStatus).where(ArtistNormalizationStatus.concert_id == concert_b)
        )
        assert result.scalar_one().status == "pending"


@pytest.mark.asyncio
async def test_normalize_specific_artists_empty_names_is_noop():
    stats = await normalize_specific_artists(uuid.uuid4(), [])
    assert stats["processed"] == 0


# 웹훅(/artist-result)이 정규화 큐를 적립하는지

@pytest.mark.asyncio
async def test_artist_result_queues_pending_normalization():
    token = await _get_token()
    concert_id = uuid.UUID(await _create_concert(f"PF_AR_QUEUE_{uuid.uuid4().hex[:6]}", "", token))

    body = {"artist_name": ["신규아티스트"]}
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result", json=body, headers=_llm_headers()
            )
    assert res.status_code == 200

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistNormalizationStatus).where(ArtistNormalizationStatus.concert_id == concert_id)
        )
        rows = result.scalars().all()
    assert [r.artist_text for r in rows] == ["신규아티스트"]
    assert rows[0].status == "pending"


# 웹훅이 큐잉 직후 normalize_specific_artists를 백그라운드로 스케줄하는지 (conftest의 autouse
# 스텁을 이 테스트에서만 해제하고 호출 여부/인자를 직접 검증)
@pytest.mark.asyncio
async def test_artist_result_schedules_immediate_normalization():
    token = await _get_token()
    concert_id = uuid.UUID(await _create_concert(f"PF_AR_TRIGGER_{uuid.uuid4().hex[:6]}", "", token))

    body = {"artist_name": ["즉시아티스트"]}
    mock_normalize = AsyncMock()
    with patch("app.api.v1.endpoints.crawl.normalize_specific_artists", new=mock_normalize), patch(
        "app.core.deps.settings"
    ) as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/artist-result", json=body, headers=_llm_headers()
            )
    assert res.status_code == 200
    mock_normalize.assert_awaited_once_with(concert_id, ["즉시아티스트"])


# PATCH /concerts/{concert_id}/artist-name/confirm (유저 프로모션 API)

@pytest.mark.asyncio
async def test_confirm_artist_name_success():
    token = await _get_token()
    raw_name = f"미확정_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_CONFIRM_{uuid.uuid4().hex[:6]}", raw_name, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            f"/api/v1/concerts/{concert_id}/artist-name/confirm",
            json={"original_name": raw_name, "confirmed_name": "확정된이름"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert res.status_code == 200
    assert res.json()["artist_name"] == ["확정된이름"]

    async with AsyncSessionLocal() as db:
        canonical = await find_canonical_by_alias(db, raw_name)
        assert canonical is not None
        assert canonical.canonical_name == "확정된이름"
        assert canonical.mbid is None  # 유저 입력 기반, MusicBrainz mbid 없음


@pytest.mark.asyncio
async def test_confirm_artist_name_rejects_name_not_on_concert():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_CONFIRM_BAD_{uuid.uuid4().hex[:6]}", "실제아티스트", token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            f"/api/v1/concerts/{concert_id}/artist-name/confirm",
            json={"original_name": "존재하지않는이름", "confirmed_name": "아무거나"},
            headers={"Authorization": f"Bearer {token}"},
        )
    assert res.status_code == 400


@pytest.mark.asyncio
async def test_confirm_artist_name_requires_auth():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_CONFIRM_AUTH_{uuid.uuid4().hex[:6]}", "아티스트", token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            f"/api/v1/concerts/{concert_id}/artist-name/confirm",
            json={"original_name": "아티스트", "confirmed_name": "새이름"},
        )
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_confirm_artist_name_reuses_existing_canonical_on_near_duplicate():
    token = await _get_token()
    raw_name = f"오타있음_{uuid.uuid4().hex[:6]}"
    canonical_name = f"ExistingArtist{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_CONFIRM_DUP_{uuid.uuid4().hex[:6]}", raw_name, token)

    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid=None, canonical_name=canonical_name)
        db.add(canonical)
        await db.commit()
        canonical_id = canonical.id

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            f"/api/v1/concerts/{concert_id}/artist-name/confirm",
            # 대소문자만 다른 근접 중복 - normalize_artist_names의 퍼지매칭으로 기존 canonical 재사용돼야 함
            json={"original_name": raw_name, "confirmed_name": canonical_name.upper()},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert res.status_code == 200
    async with AsyncSessionLocal() as db:
        # 다른 테스트가 병행으로 만든 canonical_artists와 섞여도 안전하게, 이 이름으로만 스코프해서 확인
        matches = (
            await db.execute(select(CanonicalArtist).where(CanonicalArtist.canonical_name == canonical_name))
        ).scalars().all()
        assert len(matches) == 1
        assert matches[0].id == canonical_id  # 새로 안 만들고 기존 것 재사용


# 밴드<->멤버 관계 저장 (normalize_pending_artists가 새로 매치된 canonical의 관계까지 저장하는지)

@pytest.mark.asyncio
async def test_normalize_pending_artists_stores_current_member_relations():
    await _clear_pending_queue()
    token = await _get_token()
    band_name = f"밴드_{uuid.uuid4().hex[:6]}"
    concert_id = uuid.UUID(await _create_concert(f"PF_REL_{uuid.uuid4().hex[:6]}", band_name, token))

    async with AsyncSessionLocal() as db:
        await queue_for_normalization(db, concert_id, [band_name])

    band_mbid = uuid.uuid4().hex
    relations = [
        BandRelation(mbid=uuid.uuid4().hex, name="현역멤버1", type="Person", is_current=True),
        BandRelation(mbid=uuid.uuid4().hex, name="현역멤버2", type="Person", is_current=True),
        BandRelation(mbid=uuid.uuid4().hex, name="탈퇴멤버", type="Person", is_current=False),
    ]

    with _no_kopis_supplement(), patch(
        "app.services.artist_normalization.search_artist",
        new=AsyncMock(return_value=[_kr_candidate(band_name, score=100, mbid=band_mbid)]),
    ), patch(
        "app.services.artist_normalization.fetch_member_of_band_relations",
        new=AsyncMock(return_value=relations),
    ):
        stats = await normalize_pending_artists(limit=10)

    assert stats["matched"] == 1

    async with AsyncSessionLocal() as db:
        band_canonical = await find_canonical_by_alias(db, band_name)
        assert band_canonical is not None

        memberships = (
            await db.execute(
                select(ArtistGroupMembership).where(ArtistGroupMembership.group_canonical_id == band_canonical.id)
            )
        ).scalars().all()
        assert len(memberships) == 2  # 현역 멤버 2명만 저장, 탈퇴 멤버는 저장 안 됨

        member_canonicals = {m.member_canonical_id for m in memberships}
        member_names = (
            await db.execute(select(CanonicalArtist.canonical_name).where(CanonicalArtist.id.in_(member_canonicals)))
        ).scalars().all()
        assert set(member_names) == {"현역멤버1", "현역멤버2"}

        # 탈퇴 멤버는 canonical조차 안 만들어짐(관계 저장 단계에서 통째로 건너뜀)
        departed = await find_canonical_by_alias(db, "탈퇴멤버")
        assert departed is None


@pytest.mark.asyncio
async def test_normalize_pending_artists_skips_relation_fetch_for_known_canonical():
    await _clear_pending_queue()
    token = await _get_token()
    band_name = f"밴드_{uuid.uuid4().hex[:6]}"
    concert_id = uuid.UUID(await _create_concert(f"PF_REL_SKIP_{uuid.uuid4().hex[:6]}", band_name, token))

    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid="known-mbid", canonical_name=band_name)
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=band_name, source="musicbrainz"))
        await db.commit()
        await queue_for_normalization(db, concert_id, [band_name])

    mock_relations = AsyncMock(side_effect=AssertionError("이미 아는 canonical은 관계를 다시 조회하면 안 됨"))
    with _no_kopis_supplement(), patch(
        "app.services.artist_normalization.fetch_member_of_band_relations", new=mock_relations
    ):
        stats = await normalize_pending_artists(limit=10)

    assert stats["matched"] == 1
    mock_relations.assert_not_called()


@pytest.mark.asyncio
async def test_normalize_pending_artists_backfills_group_roster_from_member_side():
    # 멤버 쪽에서 그룹을 처음 발견해도(그룹 자체는 안 나옴) 그룹의 전체 로스터를 알아야
    # 표기 통합(_collapse_members_to_group_names)을 판단할 수 있으므로, 그룹 쪽 관계도
    # 자동으로 한 번 더 조회돼서 멤버B까지 저장되는지 확인
    await _clear_pending_queue()
    token = await _get_token()
    member_a_name = f"멤버A_{uuid.uuid4().hex[:6]}"
    concert_id = uuid.UUID(await _create_concert(f"PF_ROSTER_{uuid.uuid4().hex[:6]}", member_a_name, token))

    async with AsyncSessionLocal() as db:
        await queue_for_normalization(db, concert_id, [member_a_name])

    member_a_mbid = uuid.uuid4().hex
    group_mbid = uuid.uuid4().hex
    member_b_mbid = uuid.uuid4().hex
    group_name = f"밴드X_{uuid.uuid4().hex[:6]}"
    member_b_name = f"멤버B_{uuid.uuid4().hex[:6]}"

    async def _fake_relations(mbid, client=None):
        if mbid == member_a_mbid:
            return [BandRelation(mbid=group_mbid, name=group_name, type="Group", is_current=True)]
        if mbid == group_mbid:
            return [
                BandRelation(mbid=member_a_mbid, name=member_a_name, type="Person", is_current=True),
                BandRelation(mbid=member_b_mbid, name=member_b_name, type="Person", is_current=True),
            ]
        return []

    with _no_kopis_supplement(), patch(
        "app.services.artist_normalization.search_artist",
        new=AsyncMock(return_value=[_kr_candidate(member_a_name, score=100, mbid=member_a_mbid)]),
    ), patch(
        "app.services.artist_normalization.fetch_member_of_band_relations", new=AsyncMock(side_effect=_fake_relations)
    ):
        stats = await normalize_pending_artists(limit=10)

    assert stats["matched"] == 1

    async with AsyncSessionLocal() as db:
        group_canonical = await find_canonical_by_alias(db, group_name)
        assert group_canonical is not None

        memberships = (
            await db.execute(
                select(ArtistGroupMembership).where(ArtistGroupMembership.group_canonical_id == group_canonical.id)
            )
        ).scalars().all()
        member_names = (
            await db.execute(
                select(CanonicalArtist.canonical_name).where(
                    CanonicalArtist.id.in_({m.member_canonical_id for m in memberships})
                )
            )
        ).scalars().all()
        # 콘서트에 한 번도 안 나온 멤버B도 그룹 쪽 로스터 조회로 같이 저장됨
        assert set(member_names) == {member_a_name, member_b_name}


# _collapse_members_to_group_names - 멤버 표기를 그룹명으로 정리하는 정책

async def _seed_group_with_members(db, group_name: str, member_names: list[str]) -> None:
    group = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=group_name)
    db.add(group)
    await db.flush()
    db.add(ArtistAlias(canonical_artist_id=group.id, alias_text=group_name, source="musicbrainz"))
    for name in member_names:
        member = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=name)
        db.add(member)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=member.id, alias_text=name, source="musicbrainz"))
        db.add(ArtistGroupMembership(member_canonical_id=member.id, group_canonical_id=group.id, is_current=True))


@pytest.mark.asyncio
async def test_collapse_to_group_name_when_group_text_present():
    await _clear_pending_queue()
    token = await _get_token()
    group_name = f"밴드X_{uuid.uuid4().hex[:6]}"
    m1, m2 = (f"멤버{i}_{uuid.uuid4().hex[:4]}" for i in range(2))
    concert_id = uuid.UUID(
        await _create_concert(f"PF_COLL_TXT_{uuid.uuid4().hex[:6]}", f"{group_name},{m1},{m2}", token)
    )

    async with AsyncSessionLocal() as db:
        await _seed_group_with_members(db, group_name, [m1, m2])
        await db.commit()
        await queue_for_normalization(db, concert_id, [group_name, m1, m2])

    with _no_kopis_supplement():
        await normalize_pending_artists(limit=10)

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        assert concert.artist_name == [group_name]  # 멤버는 빠지고 그룹명만 남음


@pytest.mark.asyncio
async def test_collapse_to_group_name_when_all_members_present_without_group_text():
    await _clear_pending_queue()
    token = await _get_token()
    group_name = f"밴드Y_{uuid.uuid4().hex[:6]}"
    m1, m2 = (f"멤버{i}_{uuid.uuid4().hex[:4]}" for i in range(2))
    concert_id = uuid.UUID(await _create_concert(f"PF_COLL_ALL_{uuid.uuid4().hex[:6]}", f"{m1},{m2}", token))

    async with AsyncSessionLocal() as db:
        await _seed_group_with_members(db, group_name, [m1, m2])
        await db.commit()
        await queue_for_normalization(db, concert_id, [m1, m2])

    with _no_kopis_supplement():
        await normalize_pending_artists(limit=10)

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        assert concert.artist_name == [group_name]  # 그룹명 텍스트 없이도 로스터 전원 일치로 통합됨


@pytest.mark.asyncio
async def test_collapse_skipped_when_member_missing_and_title_silent():
    await _clear_pending_queue()
    token = await _get_token()
    group_name = f"밴드Z_{uuid.uuid4().hex[:6]}"
    m1, m2, m3 = (f"멤버{i}_{uuid.uuid4().hex[:4]}" for i in range(3))
    concert_id = uuid.UUID(await _create_concert(f"PF_COLL_MISS_{uuid.uuid4().hex[:6]}", f"{m1},{m2}", token))

    async with AsyncSessionLocal() as db:
        await _seed_group_with_members(db, group_name, [m1, m2, m3])  # m3는 이 콘서트에 없음
        await db.commit()
        await queue_for_normalization(db, concert_id, [m1, m2])

    with _no_kopis_supplement():
        await normalize_pending_artists(limit=10)

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        assert set(concert.artist_name) == {m1, m2}  # 근거(그룹명 텍스트) 없어서 개별 표기 유지


@pytest.mark.asyncio
async def test_collapse_applies_when_member_missing_but_title_mentions_group():
    await _clear_pending_queue()
    token = await _get_token()
    group_name = f"밴드W_{uuid.uuid4().hex[:6]}"
    m1, m2, m3 = (f"멤버{i}_{uuid.uuid4().hex[:4]}" for i in range(3))
    concert_id = uuid.UUID(await _create_concert(f"PF_COLL_TITLE_{uuid.uuid4().hex[:6]}", f"{m1},{m2}", token))

    async with AsyncSessionLocal() as db:
        await _seed_group_with_members(db, group_name, [m1, m2, m3])  # m3는 이 콘서트에 없음
        concert = await db.get(Concert, concert_id)
        concert.name = f"{group_name} 단독 콘서트"  # 제목에 그룹명 언급
        await db.commit()
        await queue_for_normalization(db, concert_id, [m1, m2])

    with _no_kopis_supplement():
        await normalize_pending_artists(limit=10)

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        assert concert.artist_name == [group_name]  # 제목 교차검증으로 누락 허용, 그룹명으로 통합


# expand_follow_index_with_group_relations - 팔로우 인덱스를 밴드<->현재 멤버 관계로 확장

@pytest.mark.asyncio
async def test_expand_follow_index_lets_group_follow_match_member_name():
    band_name = f"밴드_{uuid.uuid4().hex[:6]}"
    member_name = f"멤버_{uuid.uuid4().hex[:6]}"

    async with AsyncSessionLocal() as db:
        band = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=band_name)
        member = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=member_name)
        db.add_all([band, member])
        await db.flush()
        db.add(ArtistGroupMembership(member_canonical_id=member.id, group_canonical_id=band.id, is_current=True))
        await db.commit()

        user_id = uuid.uuid4()
        index = {band_name.lower(): [(user_id, band_name)]}
        await expand_follow_index_with_group_relations(db, index)

    assert index[member_name.lower()] == [(user_id, band_name)]


@pytest.mark.asyncio
async def test_expand_follow_index_lets_member_follow_match_group_name():
    band_name = f"밴드_{uuid.uuid4().hex[:6]}"
    member_name = f"멤버_{uuid.uuid4().hex[:6]}"

    async with AsyncSessionLocal() as db:
        band = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=band_name)
        member = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=member_name)
        db.add_all([band, member])
        await db.flush()
        db.add(ArtistGroupMembership(member_canonical_id=member.id, group_canonical_id=band.id, is_current=True))
        await db.commit()

        user_id = uuid.uuid4()
        index = {member_name.lower(): [(user_id, member_name)]}
        await expand_follow_index_with_group_relations(db, index)

    assert index[band_name.lower()] == [(user_id, member_name)]


@pytest.mark.asyncio
async def test_expand_follow_index_excludes_former_members():
    band_name = f"밴드_{uuid.uuid4().hex[:6]}"
    former_member_name = f"탈퇴멤버_{uuid.uuid4().hex[:6]}"

    async with AsyncSessionLocal() as db:
        band = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=band_name)
        member = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=former_member_name)
        db.add_all([band, member])
        await db.flush()
        db.add(ArtistGroupMembership(member_canonical_id=member.id, group_canonical_id=band.id, is_current=False))
        await db.commit()

        user_id = uuid.uuid4()
        index = {band_name.lower(): [(user_id, band_name)]}
        await expand_follow_index_with_group_relations(db, index)

    assert former_member_name.lower() not in index


# _create_news_feeds_for_concert 종단 테스트 - 밴드명을 팔로우했는데 콘서트엔 멤버명만 있어도 매칭돼야 함

@pytest.mark.asyncio
async def test_news_feed_matches_group_follow_against_member_only_concert():
    token = await _get_token()
    user_id = await _get_user_id(token)
    band_name = f"밴드_{uuid.uuid4().hex[:6]}"
    member_name = f"멤버_{uuid.uuid4().hex[:6]}"

    async with AsyncSessionLocal() as db:
        band = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=band_name)
        member = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=member_name)
        db.add_all([band, member])
        await db.flush()
        db.add(ArtistGroupMembership(member_canonical_id=member.id, group_canonical_id=band.id, is_current=True))
        await db.commit()

    await _follow_artist(token, band_name)

    # KOPIS 원본에 멤버명만 있는 콘서트 (밴드명은 어디에도 등장하지 않음)
    concert_id = uuid.UUID(await _create_concert(f"PF_NF_{uuid.uuid4().hex[:6]}", member_name, token))

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        follow_index = await _build_follow_index(db)
        matched = await _create_news_feeds_for_concert(db, concert, follow_index)
        await db.commit()

    assert (user_id, band_name) in matched


# KOPIS 원본 라인업 보강 (_supplement_from_kopis_originals) - LLM이 일부 멤버만 추출해도
# KOPIS API를 재조회해서 나머지 멤버까지 정규화 큐에 채워 넣는지

@pytest.mark.asyncio
async def test_normalize_pending_artists_supplements_missing_kopis_members():
    await _clear_pending_queue()
    token = await _get_token()
    kopis_id = f"PF_SUPP_{uuid.uuid4().hex[:6]}"
    m1, m2, m3 = (f"멤버{i}_{uuid.uuid4().hex[:4]}" for i in range(3))
    concert_id = uuid.UUID(await _create_concert(kopis_id, f"{m1},{m2},{m3}", token))

    # LLM이 포스터에서 3명 중 1명만 인식해 concert.artist_name에 1명만 있는 상황을 재현
    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        concert.artist_name = [m1]
        await db.commit()
        await queue_for_normalization(db, concert_id, [m1])

    kopis_detail_mock = AsyncMock(return_value={"artist_name": [m1, m2, m3]})
    with patch("app.services.kopis._fetch_kopis_detail_data", new=kopis_detail_mock), _no_relation_fetch(), patch(
        "app.services.artist_normalization.search_artist",
        new=AsyncMock(side_effect=lambda name, client=None: [_kr_candidate(name, score=100)]),
    ):
        stats = await normalize_pending_artists(limit=10)

    kopis_detail_mock.assert_awaited_once()
    assert stats["matched"] == 3  # m1(원래 큐잉분) + m2, m3(KOPIS 보강분) 전부 처리됨

    async with AsyncSessionLocal() as db:
        texts = (
            await db.execute(
                select(ArtistNormalizationStatus.artist_text).where(
                    ArtistNormalizationStatus.concert_id == concert_id
                )
            )
        ).scalars().all()
        assert set(texts) == {m1, m2, m3}

        # concert.artist_name은 그대로 - m2/m3는 애초에 배열에 없었으니 표시엔 영향 없음
        # (canonical/관계 데이터만 보강됨)
        concert = await db.get(Concert, concert_id)
        assert concert.artist_name == [m1]


@pytest.mark.asyncio
async def test_normalize_pending_artists_dry_run_does_not_persist_kopis_supplement():
    await _clear_pending_queue()
    token = await _get_token()
    kopis_id = f"PF_SUPPDRY_{uuid.uuid4().hex[:6]}"
    m1, m2 = (f"멤버{i}_{uuid.uuid4().hex[:4]}" for i in range(2))
    concert_id = uuid.UUID(await _create_concert(kopis_id, f"{m1},{m2}", token))

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        concert.artist_name = [m1]
        await db.commit()
        await queue_for_normalization(db, concert_id, [m1])

    with patch(
        "app.services.kopis._fetch_kopis_detail_data", new=AsyncMock(return_value={"artist_name": [m1, m2]})
    ), _no_relation_fetch(), patch(
        "app.services.artist_normalization.search_artist",
        new=AsyncMock(side_effect=lambda name, client=None: [_kr_candidate(name, score=100)]),
    ):
        await normalize_pending_artists(limit=10, dry_run=True)

    async with AsyncSessionLocal() as db:
        texts = (
            await db.execute(
                select(ArtistNormalizationStatus.artist_text).where(
                    ArtistNormalizationStatus.concert_id == concert_id
                )
            )
        ).scalars().all()
        assert set(texts) == {m1}  # 보강 큐잉도 dry-run이면 같이 롤백돼야 함 (m2는 안 남음)
