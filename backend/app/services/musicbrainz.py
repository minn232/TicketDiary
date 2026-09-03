import asyncio
import logging
from dataclasses import dataclass

import httpx

from app.core.config import settings

logger = logging.getLogger(__name__)

# 공식 정책: 인증 없는 공개 API는 IP당 초당 1요청. 2초 간격 + 실패 시 최대 2회 재시도(3초 대기)로
# 503 발생률을 크게 낮춤(docs/musicbrainz_integration_review.md 실측 검증)
_MIN_REQUEST_INTERVAL = 2.0
_MAX_RETRIES = 2
_RETRY_BACKOFF_SECONDS = 3.0

_request_lock = asyncio.Lock()
_last_request_at = 0.0


async def _throttle() -> None:
    global _last_request_at
    async with _request_lock:
        loop = asyncio.get_event_loop()
        now = loop.time()
        wait = _last_request_at + _MIN_REQUEST_INTERVAL - now
        if wait > 0:
            await asyncio.sleep(wait)
        _last_request_at = loop.time()


# Lucene 쿼리 안에 그대로 들어갈 문자열이라, 따옴표로 감싼 구문 검색을 깨뜨릴 수 있는 문자만
# 최소한으로 이스케이프한다(백슬래시/큰따옴표) - 그 외 특수문자는 따옴표 안에서는 리터럴로 처리됨
def _escape_lucene_phrase(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


@dataclass
class ArtistCandidate:
    mbid: str
    name: str
    score: int
    country: str | None
    # "country_kr"(country:KR로 찾음, 신뢰도 높음) | "general"(country 필터 없이 찾음, 동명이인 위험 있음)
    source: str


# "member of band" 관계 1건 - 관계의 상대방(멤버라면 밴드, 밴드라면 멤버) 정보
@dataclass
class BandRelation:
    mbid: str
    name: str
    type: str | None  # "Person" | "Group"
    is_current: bool  # 관계에 end 날짜가 없으면 현재도 소속 중이라는 뜻


# 스로틀+재시도를 공통으로 처리하는 GET 헬퍼. 검색(/artist?query=)과 단건 조회(/artist/{mbid})
# 둘 다 이걸 통해서 나간다 - 실패 로그 문구만 호출부가 붙여서 넘김
async def _get_with_retry(client: httpx.AsyncClient, path: str, params: dict, log_label: str) -> dict:
    last_error: Exception | None = None
    for attempt in range(_MAX_RETRIES + 1):
        await _throttle()
        try:
            response = await client.get(
                f"{settings.MUSICBRAINZ_BASE_URL}{path}",
                params=params,
                headers={"User-Agent": settings.MUSICBRAINZ_USER_AGENT},
            )
            if response.status_code == 200:
                return response.json()
            last_error = Exception(f"HTTP {response.status_code}")
        except httpx.HTTPError as e:
            last_error = e

        if attempt < _MAX_RETRIES:
            await asyncio.sleep(_RETRY_BACKOFF_SECONDS)

    logger.warning(f"MusicBrainz 조회 실패 ({log_label}): {last_error}")
    return {}


async def _run_query(client: httpx.AsyncClient, query: str) -> list[dict]:
    data = await _get_with_retry(client, "/artist", {"query": query, "fmt": "json", "limit": 5}, query)
    return data.get("artists", [])


# 이름 하나를 MusicBrainz에서 검색해 후보 목록을 반환한다. artist: 필드만으론 별칭 등록(예:
# Jae Joong -> 김재중)을 놓쳐서 alias: 필드도 같이 검색. country:KR을 먼저 시도하고 없으면
# country 필터 없는 일반 검색으로 폴백(폴백 결과는 candidate.source로 구분해 반환)
async def search_artist(name: str, client: httpx.AsyncClient | None = None) -> list[ArtistCandidate]:
    escaped = _escape_lucene_phrase(name)
    base_query = f'(artist:"{escaped}" OR alias:"{escaped}")'

    async def _search(c: httpx.AsyncClient) -> list[ArtistCandidate]:
        kr_results = await _run_query(c, f"{base_query} AND country:KR")
        if kr_results:
            return [
                ArtistCandidate(
                    mbid=a["id"], name=a["name"], score=a.get("score", 0),
                    country=a.get("country"), source="country_kr",
                )
                for a in kr_results
            ]

        general_results = await _run_query(c, base_query)
        return [
            ArtistCandidate(
                mbid=a["id"], name=a["name"], score=a.get("score", 0),
                country=a.get("country"), source="general",
            )
            for a in general_results
        ]

    if client is not None:
        return await _search(client)
    async with httpx.AsyncClient(timeout=10.0) as c:
        return await _search(c)


# canonical 하나(mbid)가 Wikidata 항목과 연결돼 있으면 그 QID(예: "Q165193")를 반환. 관계가
# 없거나 조회 실패 시 None - 호출부(artist_normalization._register_wikidata_korean_alias)가
# 조용히 건너뛴다
async def fetch_wikidata_qid(mbid: str, client: httpx.AsyncClient | None = None) -> str | None:
    async def _fetch(c: httpx.AsyncClient) -> str | None:
        data = await _get_with_retry(
            c, f"/artist/{mbid}", {"inc": "url-rels", "fmt": "json"}, f"wikidata qid mbid={mbid}"
        )
        for rel in data.get("relations", []):
            if rel.get("type") != "wikidata":
                continue
            resource = (rel.get("url") or {}).get("resource", "")
            qid = resource.rsplit("/", 1)[-1]
            if qid:
                return qid
        return None

    if client is not None:
        return await _fetch(client)
    async with httpx.AsyncClient(timeout=10.0) as c:
        return await _fetch(c)


# 아티스트 하나(mbid)의 "member of band" 관계를 전부 가져온다. 밴드를 조회하면 멤버 목록이,
# 멤버를 조회하면 소속 밴드가 나오는 대칭 관계(실측으로 잔나비 조회해서 확인: 밴드 조회 시
# direction="backward"로 5명의 현재/과거 멤버가 나옴). relations[].end 필드로 탈퇴 여부를 구분.
async def fetch_member_of_band_relations(mbid: str, client: httpx.AsyncClient | None = None) -> list[BandRelation]:
    async def _fetch(c: httpx.AsyncClient) -> list[BandRelation]:
        data = await _get_with_retry(
            c, f"/artist/{mbid}", {"inc": "artist-rels", "fmt": "json"}, f"relations mbid={mbid}"
        )
        results = []
        for rel in data.get("relations", []):
            if rel.get("type") != "member of band":
                continue
            other = rel.get("artist") or {}
            if not other.get("id"):
                continue
            results.append(
                BandRelation(
                    mbid=other["id"], name=other.get("name", ""),
                    type=other.get("type"), is_current=rel.get("end") is None,
                )
            )
        return results

    if client is not None:
        return await _fetch(client)
    async with httpx.AsyncClient(timeout=10.0) as c:
        return await _fetch(c)
