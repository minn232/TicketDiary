import asyncio
import difflib
import logging
import re
from contextlib import asynccontextmanager
from datetime import datetime, date, timedelta, timezone
from xml.etree import ElementTree as ET

import httpx
from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.concert import Concert
from app.models.social import ArtistFollow, NewsFeed
from app.services.artist_matching import get_known_artist_names, normalize_artist_names
from app.services.notification import schedule_new_concert_notifications
from app.services.site_aliases import find_site_key
from app.services.text_utils import min_len_ok

logger = logging.getLogger(__name__)

# KOPIS Open API 이용제한 공식 정책: IP당 초당 10회 초과 호출 시 서비스 중지됨
# 안전마진을 두고 초당 약 2.8회로 제한 (list/detail 등 KOPIS로 나가는 모든 요청에 공통 적용)
_KOPIS_MIN_REQUEST_INTERVAL = 0.35
_kopis_request_lock = asyncio.Lock()
_kopis_last_request_at = 0.0


# KOPIS로 나가는 모든 HTTP 요청 직전에 호출 -> IP당 초당 10회 제한을 넘지 않도록 간격 보장
async def _throttle_kopis_request() -> None:
    global _kopis_last_request_at
    async with _kopis_request_lock:
        loop = asyncio.get_event_loop()
        now = loop.time()
        wait = _kopis_last_request_at + _KOPIS_MIN_REQUEST_INTERVAL - now
        if wait > 0:
            await asyncio.sleep(wait)
        _kopis_last_request_at = loop.time()


# client가 주어지면 그대로 재사용(연결 재사용으로 매 호출마다 새 TCP/TLS 핸드셰이크 방지),
# 없으면 이 스코프에서만 쓸 임시 client를 새로 만듦 - 여러 후보를 순차 조회하는 상위 호출부
# (search_concerts_multi 등)가 client 하나를 만들어 하위 함수들에 공유시키기 위한 헬퍼
@asynccontextmanager
async def _kopis_client(client: httpx.AsyncClient | None):
    if client is not None:
        yield client
    else:
        async with httpx.AsyncClient(timeout=10.0) as new_client:
            yield new_client


_DATE_FMT = "%Y.%m.%d"

_FESTIVAL_KEYWORDS = [
    "festival", "fest", "페스티벌", "페스", "뮤직페스",
]


# 공연명 기반 단독 공연 / 페스티벌 분류
def _classify_event_type(name: str) -> str:
    lower = name.lower()
    if any(kw in lower for kw in _FESTIVAL_KEYWORDS):
        return "FESTIVAL"
    return "SOLO"


# 공연 기간 파싱 ("YYYY.MM.DD" -> datetime)
def _parse_date(s: str) -> datetime:
    return datetime.strptime(s.strip(), _DATE_FMT).replace(tzinfo=timezone.utc)


_TIME_RE = re.compile(r"(\d{1,2}):(\d{2})")


# 공연시간 안내 파싱 ("월~금 20:00 / 토 15:00,19:00" -> None, "화~금 19:30" -> "19:30")
# 요일/회차별로 시간이 여러 개 섞여 있으면 대표값을 하나로 정할 수 없으므로 모호한 경우 None 반환
def _parse_start_time(dtguidance: str) -> str | None:
    times = {f"{int(h):02d}:{m}" for h, m in _TIME_RE.findall(dtguidance)}
    return times.pop() if len(times) == 1 else None


# 가격 파싱 ("VIP석 150,000원, R석 110,000원" -> [{"seat_type": "VIP석", "price": 150000}])
def _parse_price(text: str) -> list[dict] | None:
    prices = []
    for match in re.finditer(r"([^\s,]+)\s+([\d,]+)원", text):
        prices.append({
            "seat_type": match.group(1),
            "price": int(match.group(2).replace(",", "")),
        })
    return prices or None


# 아티스트 파싱 (KOPIS 출연진(prfcast) 필드는 콤마로 구분된 이름 목록이며, 목록이 길면 마지막
# 항목에 "등"을 붙여 생략을 표시함 -> 이름이 아니므로 제거) ("김가은, 우리라, 이정민 등" -> ["김가은", "우리라", "이정민"])
def _parse_artists(prfcast: str) -> list[str]:
    names = [a.strip() for a in prfcast.split(",") if a.strip()]
    if names and names[-1].endswith(" 등"):
        names[-1] = names[-1][: -len(" 등")].strip()
    return [n for n in names if n]


# concert 정보 DB upsert
async def _upsert_concert(
    db: AsyncSession, data: dict, known_artist_names: set[str] | None = None
) -> Concert:
    if data.get("artist_name"):
        if known_artist_names is None:
            known_artist_names = await get_known_artist_names(db)
        data["artist_name"] = normalize_artist_names(data["artist_name"], known_artist_names)

    result = await db.execute(
        select(Concert).where(Concert.kopis_id == data["kopis_id"])
    )
    concert = result.scalar_one_or_none()

    # 공연이 없으면 새로 생성
    if concert is None:
        concert = Concert(**data)
        db.add(concert)
    # 공연이 있으면 덮어쓰기
    else:
        for key, value in data.items():
            existing = getattr(concert, key, None)
            # 빈 배열로 기존 데이터 덮어쓰기 방지
            if isinstance(value, list) and not value and existing:
                continue
            if value is not None:
                setattr(concert, key, value)

    return concert


# KOPIS 공연 목록 API 호출 + 파싱 + DB upsert 공통 로직 (검색 파라미터만 다르게 받음)
async def _fetch_and_upsert_concerts(
    db: AsyncSession, extra_params: dict, client: httpx.AsyncClient | None = None
) -> list[Concert]:
    today = date.today()
    params = {
        "service": settings.KOPIS_API_KEY,
        "stdate": today.strftime("%Y%m%d"),
        "eddate": (today + timedelta(days=365)).strftime("%Y%m%d"),
        "rows": 50,
        "cpage": 1,
        **extra_params,
    }

    await _throttle_kopis_request()
    async with _kopis_client(client) as c:
        response = await c.get(f"{settings.KOPIS_BASE_URL}/pblprfr", params=params)

    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="KOPIS API 호출에 실패했습니다.")

    root = ET.fromstring(response.content)
    kopis_ids: list[str] = []

    for elem in root.findall("db"):
        kopis_id = (elem.findtext("mt20id") or "").strip()
        start_raw = (elem.findtext("prfpdfrom") or "").strip()
        end_raw = (elem.findtext("prfpdto") or "").strip()

        if not kopis_id or not start_raw or not end_raw:
            continue

        # 요청 파라미터로는 KOPIS가 장르를 걸러주지 않으므로(뮤지컬/연극 등이 섞여 들어옴)
        # 목록/검색 계열 API 전부 여기서 공통으로 클라이언트 사이드 필터링
        genre_name = elem.findtext("genrenm") or ""
        if not _is_allowed_genre(genre_name):
            continue

        name = elem.findtext("prfnm") or ""
        data = {
            "kopis_id": kopis_id,
            "name": name,
            "artist_name": [],
            "venue": elem.findtext("fcltynm") or None,
            "start_date": _parse_date(start_raw),
            "end_date": _parse_date(end_raw),
            "genre": [g for g in [genre_name] if g],
            "poster_url": elem.findtext("poster") or None,
            "event_type": _classify_event_type(name),
        }
        await _upsert_concert(db, data)
        kopis_ids.append(kopis_id)

    if not kopis_ids:
        return []

    await db.commit()

    result = await db.execute(
        select(Concert).where(Concert.kopis_id.in_(kopis_ids))
    )
    return list(result.scalars().all())


# KOPIS 공연 검색 단일 호출 (keyword 그대로 사용)
async def _search_concerts_once(
    db: AsyncSession,
    keyword: str,
    start_date: date | None,
    end_date: date | None,
    client: httpx.AsyncClient | None = None,
) -> list[Concert]:
    today = date.today()
    return await _fetch_and_upsert_concerts(
        db,
        {
            # start_date 미지정 시 오늘부터로 제한 -> 종료된 공연은 검색되지 않음(찜 대상은 항상 예정 공연)
            # OCR 스캔 매칭(search_concerts_multi)은 항상 명시적 start_date를 넘기므로 이 기본값의 영향을 받지 않음
            "stdate": (start_date or today).strftime("%Y%m%d"),
            "eddate": (end_date or today + timedelta(days=365)).strftime("%Y%m%d"),
            "shprfnm": keyword,
        },
        client=client,
    )


# OCR 공연장 텍스트와 KOPIS fcltynm이 실질적으로 같은 장소인지 확인 (공백/기호 무시, 4글자 이상의
# 최장 공통 부분열 기준). 완전 포함(substring)만 보면 "잠실실내체육관"(OCR) vs "잠실종합운동장
# (실내체육관)"(KOPIS)처럼 중간에 다른 단어가 낀 같은 장소를 다르다고 오판하므로 이렇게 완화함
def _venue_overlaps(a: str, b: str) -> bool:
    a_norm = re.sub(r"[^\w가-힣]", "", a)
    b_norm = re.sub(r"[^\w가-힣]", "", b)
    if not a_norm or not b_norm:
        return False
    if a_norm in b_norm or b_norm in a_norm:
        return True
    match = difflib.SequenceMatcher(None, a_norm, b_norm).find_longest_match(0, len(a_norm), 0, len(b_norm))
    return match.size >= 4


# OCR 공연장 텍스트에서 KOPIS 시설 검색(/prfplc)에 걸릴 만한 후보를 순서대로 생성
# KOPIS는 "인터파크 유니플렉스 2관" 같은 전체 문구로는 안 걸리고 "유니플렉스"처럼 시설 본체
# 이름만으로 걸리는 경우가 많아 -> 끝의 세부관(N관/N홀 등) 제거 + 단어 단위 접미사를 순서대로 시도
# 숫자가 붙은 경우만 세부관으로 보고 제거함("2관") - 숫자 없이 관/홀/층/실로 끝나는 이름은
# "세종문화회관"처럼 시설 본체 이름 자체인 경우가 많아 그대로 두지 않으면 엉뚱한 시설이 걸릴 수 있음
def _venue_candidates(location: str) -> list[str]:
    location = location.strip()
    if not location:
        return []
    candidates = [location]
    stripped = re.sub(r"\s*\d+\s*(관|홀|층|실)$", "", location).strip()
    if stripped and stripped not in candidates:
        candidates.append(stripped)
    words = (stripped or location).split()
    for i in range(1, len(words)):
        w = " ".join(words[i:])
        if w not in candidates:
            candidates.append(w)
    return candidates


# 공연장 후보명을 순서대로 시도해서 KOPIS 시설 코드(mt10id)를 반환 (실패 시 None)
async def _resolve_venue_facility_code(
    venue_candidates: list[str], client: httpx.AsyncClient | None = None
) -> str | None:
    async with _kopis_client(client) as c:
        for name in venue_candidates:
            if not name or len(name) < 2:
                continue
            await _throttle_kopis_request()
            response = await c.get(
                f"{settings.KOPIS_BASE_URL}/prfplc",
                params={"service": settings.KOPIS_API_KEY, "shprfnmfct": name, "rows": 1, "cpage": 1},
            )
            if response.status_code != 200:
                continue
            root = ET.fromstring(response.content)
            elem = root.find("db")
            if elem is None:
                continue
            code = (elem.findtext("mt10id") or "").strip()
            if code:
                return code
    return None


# start_date~end_date 구간의 중간값(=OCR로 뽑은 실제 공연일 추정치) 계산 (구간이 없으면 None)
def _midpoint(start_date: date | None, end_date: date | None) -> date | None:
    if not (start_date and end_date):
        return None
    return start_date + (end_date - start_date) / 2


# 공연장 + 날짜만으로 공연 검색 (제목 후보가 전부 실패했을 때의 최후 수단, 혹은 유저가 후보 목록에서
# 원하는 걸 못 찾았을 때의 재검색용). 장소+날짜 조합은 보통 1~2건으로 좁혀지는 강한 필터라
# 제목 표기가 KOPIS 등록명과 완전히 달라도(예: 부제만 있거나 조사가 붙어 분리 안 되는 경우) 찾아낼 수 있음
async def search_concerts_by_venue(
    db: AsyncSession,
    location: str,
    start_date: date | None = None,
    end_date: date | None = None,
    client: httpx.AsyncClient | None = None,
) -> list[Concert]:
    venue_candidates = _venue_candidates(location)
    if not venue_candidates:
        return []

    async with _kopis_client(client) as c:
        facility_code = await _resolve_venue_facility_code(venue_candidates, client=c)
        if not facility_code:
            return []

        today = date.today()
        concerts = await _fetch_and_upsert_concerts(
            db,
            {
                "stdate": (start_date or today - timedelta(days=30)).strftime("%Y%m%d"),
                "eddate": (end_date or today + timedelta(days=30)).strftime("%Y%m%d"),
                "prfplccd": facility_code,
                "rows": 30,
            },
            client=c,
        )

    target_date = _midpoint(start_date, end_date)
    if target_date is not None:
        concerts = _sort_by_date_match(concerts, target_date, location)
    return concerts


# start_date~end_date 구간의 중간값(=OCR로 뽑은 실제 공연일 추정치)과 가장 가깝게 겹치는 공연이
# 후보 목록 앞쪽에 오도록 정렬. 날짜가 동률이면 OCR 공연장 텍스트와 겹치는 공연을 우선함
# (동명이인/유사 제목 + 여러 도시 투어로 여러 건이 잡혔을 때 정확한 회차를 우선 노출)
def _sort_by_date_match(
    concerts: list[Concert], target_date: date, target_venue: str | None = None
) -> list[Concert]:
    def _key(c: Concert):
        start = c.start_date.date()
        end = c.end_date.date()
        contains = start <= target_date <= end
        distance = min(abs((start - target_date).days), abs((end - target_date).days))
        venue_match = 0 if target_venue and c.venue and _venue_overlaps(target_venue, c.venue) else 1
        return (0 if contains else 1, distance, venue_match)

    return sorted(concerts, key=_key)


# 검색 결과가 OCR로 뽑은 날짜와 실제로 겹치는지 확인 (추가 API 호출 없이 이미 받아온
# concert.start_date/end_date만으로 교차검증).
#
# 장소는 확신 여부의 필수 조건으로 쓰지 않는다 - KOPIS 목록 검색(/pblprfr)이 돌려주는 fcltynm은
# "잠실종합운동장"처럼 상위 시설명만 주는 경우가 많아, OCR이 뽑은 "잠실실내체육관"(구체적 홀 이름
# 포함) 같은 표기와는 실제로 같은 장소여도 텍스트가 거의 안 겹칠 수 있다 (상세 API를 호출해야만
# "잠실종합운동장 (실내체육관)"처럼 홀 이름까지 나옴 - 그런데 이건 후보를 이미 고른 뒤에나 부르는
# API라 여기서는 쓸 수 없음). 장소는 _sort_by_date_match의 동률 tie-break 용도로만 사용한다.
def _is_confident_match(concert: Concert, target_date: date) -> bool:
    return concert.start_date.date() <= target_date <= concert.end_date.date()


# KOPIS 공연 검색 (keyword, start_date, end_date -> Concert 목록 + DB upsert)
# 결과 없으면 keyword 끝 단어를 하나씩 줄여 재시도 (최소 1단어까지 - 보통 맨 앞 단어가 아티스트명이라
# 나머지 문구가 KOPIS 등록명과 표기/구두점이 달라도 아티스트명만으로는 후보 목록에 걸리는 경우가 많음)
async def search_concerts(
    db: AsyncSession,
    keyword: str,
    start_date: date | None = None,
    end_date: date | None = None,
    venue: str | None = None,
    client: httpx.AsyncClient | None = None,
) -> list[Concert]:
    words = keyword.split()
    # "2025 렛츠락 페스티벌"처럼 맨 앞이 연도면 끝단어 축소로는 절대 못 떼어내고 "2025"만 남을 수 있는데,
    # 연도 하나는 너무 광범위해서 무관한 결과가 대량으로 걸림 -> 실제 식별력 있는 뒷부분을 위해 미리 제거
    if len(words) > 1 and re.fullmatch(r"(19|20)\d{2}", words[0]):
        words = words[1:]
    min_words = min(1, len(words))
    target_date = _midpoint(start_date, end_date)
    for end in range(len(words), min_words - 1, -1):
        q = " ".join(words[:end])
        # 축소 도중 연도 하나만 남는 경우도 방어적으로 건너뜀 (위 처리로 보통 발생하지 않지만 안전장치)
        if re.fullmatch(r"(19|20)\d{2}", q):
            continue
        # 너무 짧은 단어까지 줄어들면 KOPIS 부분일치 특성상 무관한 결과가 대량으로 걸림
        # (예: 로마자 아티스트명이 "HA/HYUN/SANG"처럼 쪼개진 경우 "HA"만으로는 식별력이 없음.
        # 한글은 2글자도 유의미한 경우가 많아 예외로 허용, 예: "빨래")
        if not min_len_ok(q):
            continue
        concerts = await _search_concerts_once(db, q, start_date, end_date, client=client)
        # 결과가 API 상한(rows=50)에 도달하면 실제로는 더 많은 무관한 결과가 잘려나간 것 -> 검색어가
        # 너무 광범위하다는 뜻이라 못 믿고 버림 (예: "ONE"이 "TONE"/"Resone" 등에 부분일치해서 50건 걸림)
        if len(concerts) >= 50:
            logger.info(f"KOPIS 검색어가 너무 광범위함(결과 {len(concerts)}건, 상한 도달): {q!r} - 건너뜀")
            continue
        if concerts:
            if q != keyword:
                logger.info(f"KOPIS 검색어 축소: {keyword!r} → {q!r} ({len(concerts)}건)")
            if target_date is not None:
                concerts = _sort_by_date_match(concerts, target_date, venue)
            return concerts
    return []


_PAREN_RE = re.compile(r"[\(（][^\)）]*[\)）]")


# "Yuuri(유우리) Live in Seoul"처럼 영문명 바로 뒤에 괄호로 한글 병기가 붙어있으면, 끝단어부터
# 잘라내는 축소 검색으로는 이 괄호를 절대 못 떼어낼 수 있음 (예: 축소해도 "Yuuri(유우리) Live in
# Seoul"까지만 남고 실제 등록명 "Yuuri Live in Seoul"과는 괄호 때문에 영영 안 겹침). 괄호 안 내용을
# 통째로 제거한 버전을 추가 후보로 넣어주면 이런 케이스를 추가 API 호출 없이 커버할 수 있음
def _strip_parenthetical(s: str) -> str:
    stripped = _PAREN_RE.sub("", s)
    return re.sub(r"\s+", " ", stripped).strip()


# OCR 후보 줄이 많을 때 KOPIS 호출이 무한정 늘어나지 않도록 제목 후보 자체를 상한선까지만 시도
# (보통 앞쪽 후보일수록 실제 제목일 확률이 높으므로 순서상 앞쪽만 남겨도 실효성 손실이 적음)
_MAX_TITLE_KEYWORDS = 6


# 제목 후보를 순서대로 시도. 이미 받아온 응답의 날짜+장소만으로(추가 API 호출 없이) 교차검증해서
# 실제로 일치하는("확신 가능한") 결과가 나오면 즉시 반환하고, 그렇지 않으면(예: "우리들의 이야기다"
# -> "우리들의"처럼 흔한 구절이라 무관한 결과만 걸리거나, 날짜만 우연히 겹치고 장소가 전혀 다른 경우)
# 다음 후보로 계속 넘어감 (예: "빨래는 오늘을 살아가는" 실패 -> 원본 텍스트 뒷줄의 "빨래"로 재시도).
# 끝까지 확신 가능한 결과가 없으면 틀린 결과를 성공으로 오인하지 않도록 폴백 없이 실패 처리.
# 날짜 정보가 아예 없으면 교차검증 자체가 불가능하므로("아이유 콘서트"라고만 적힌 메모도 실제
# 등록된 공연과 우연히 제목이 겹치면 검증 없이 통과해버리는 문제가 있었음) 첫 매칭을 그대로
# 받아들이지 않고 실패 처리(빈 목록) - 실사용 샘플 54개 중 53개(98%)가 날짜를 정상 추출해서
# 실질적인 인식률 손실은 거의 없는 것으로 확인함.
# 중복 키워드는 한 번만 시도해서 불필요한 KOPIS 호출을 줄임.
# 후보들 전체가 KOPIS HTTP client 하나를 공유해서 매 시도마다 새 연결을 맺지 않도록 함
async def search_concerts_multi(
    db: AsyncSession,
    keywords: list[str],
    start_date: date | None = None,
    end_date: date | None = None,
    venue: str | None = None,
) -> list[Concert]:
    tried: set[str] = set()
    target_date = _midpoint(start_date, end_date)
    expanded_keywords: list[str] = []
    for kw in keywords[:_MAX_TITLE_KEYWORDS]:
        expanded_keywords.append(kw)
        stripped = _strip_parenthetical(kw)
        if stripped and stripped != kw.strip():
            expanded_keywords.append(stripped)

    async with httpx.AsyncClient(timeout=10.0) as client:
        for kw in expanded_keywords:
            kw = kw.strip()
            if not kw or kw in tried:
                continue
            tried.add(kw)
            concerts = await search_concerts(db, kw, start_date, end_date, venue, client=client)
            if not concerts:
                continue
            # 날짜가 없으면 이 후보가 맞는지 검증할 방법이 없으므로 다음 후보로 넘어감
            # (모든 후보가 같은 target_date=None을 공유하므로, 결국 아래 최종 실패 처리로 귀결됨)
            if target_date is None:
                continue
            # concerts는 이미 날짜/장소 매칭 순으로 정렬돼 있으므로 1순위만 확인하면 됨
            if _is_confident_match(concerts[0], target_date):
                return concerts
            # 날짜가 안 맞으면 신뢰할 수 없는 매칭(예: "스탠딩"이 "스탠딩에그"에 우연히 걸린 경우)이므로
            # 폴백으로 쓰지 않고 버리고 다음 후보로 계속 진행

        # 제목 후보를 전부 시도해도 확신 가능한 결과가 없으면 마지막 수단으로 장소+날짜 검색
        # (장소+날짜 조합은 보통 1~2건으로 좁혀지는 강한 필터라 제목 표기가 완전히 어긋나도 찾아낼 수 있음)
        if venue and (start_date or end_date):
            try:
                venue_concerts = await search_concerts_by_venue(db, venue, start_date, end_date, client=client)
            except HTTPException:
                venue_concerts = []
            if venue_concerts:
                logger.info(f"KOPIS 제목 후보 전부 실패 → 장소+날짜 검색으로 대체 ({venue!r})")
                return venue_concerts

    # 확신 가능한 매칭이 끝까지 없으면 틀린 결과를 성공으로 오인하지 않도록 빈 목록 반환
    return []


# 아티스트명(소문자) -> [(user_id, 원본 아티스트명), ...] 역인덱스 구축
# 배치 1회 실행당 한 번만 호출해서 공연마다 팔로우 테이블을 재조회하지 않도록 함
async def _build_follow_index(db: AsyncSession) -> dict[str, list[tuple]]:
    result = await db.execute(
        select(ArtistFollow).where(
            func.jsonb_array_length(ArtistFollow.artists) > 0
        )
    )
    follows = result.scalars().all()

    index: dict[str, list[tuple]] = {}
    for follow in follows:
        for entry in follow.artists or []:
            name = entry.get("artist_name")
            if not name:
                continue
            index.setdefault(name.lower(), []).append((follow.user_id, name))
    return index


# concert.artist_name 기반으로 팔로우 유저들에게 뉴스피드 생성 (중복 제외)
# follow_index를 넘기면 재조회 없이 재사용, 없으면 단발 호출로 간주해 직접 구축
# 매칭된 (user_id, artist_name) 목록을 반환함 - 호출부에서 NEW_CONCERT 알림 생성 시
# 아티스트 매칭을 다시 계산하지 않고 재사용하기 위함(신규 공연 배치 루프에서만 사용)
async def _create_news_feeds_for_concert(
    db: AsyncSession, concert: Concert, follow_index: dict[str, list[tuple]] | None = None
) -> list[tuple]:
    if not concert.artist_name:
        return []

    if follow_index is None:
        follow_index = await _build_follow_index(db)

    # 매칭되는 팔로워 및 아티스트명 수집
    matched: list[tuple] = []
    for artist in concert.artist_name:
        matched.extend(follow_index.get(artist.lower(), []))

    if not matched:
        return []

    # 이미 존재하는 뉴스피드 일괄 조회 (N+1 방지)
    matched_user_ids = [uid for uid, _ in matched]
    existing_result = await db.execute(
        select(NewsFeed.user_id).where(
            NewsFeed.concert_id == concert.id,
            NewsFeed.user_id.in_(matched_user_ids),
        )
    )
    existing_user_ids = set(existing_result.scalars().all())

    for user_id, artist_name in matched:
        if user_id not in existing_user_ids:
            db.add(NewsFeed(user_id=user_id, concert_id=concert.id, artist_name=artist_name))

    return matched


# 배치 1회당 최대 조회 페이지 수 (무한 루프 방지용 안전장치, rows=100 기준 최대 20000건)
_MAX_KOPIS_LIST_PAGES = 200

# 공연장 규모로 대상을 좁히고 싶을 때 키워드를 채워 넣으면 됨 (비어있으면 필터 비활성화)
# 속도 제한(_throttle_kopis_request) + 1회당 처리 상한(_MAX_NEW_CONCERTS_PER_RUN)으로
# API 이용제한 문제는 이미 방어되므로 현재는 필터링하지 않음
_LARGE_VENUE_KEYWORDS: list[str] = []

# 요청 파라미터 genrenm은 KOPIS 쪽에서 실제로 필터링해주지 않는 것으로 확인됨(연극/뮤지컬 등이 섞여 들어옴)
# 그래서 응답의 genrenm 필드값을 클라이언트에서 직접 걸러냄 (비어있으면 필터 비활성화)
_ALLOWED_GENRES: list[str] = ["대중음악"]


# fcltynm(공연장명)에 대형 공연장 키워드가 포함되는지 확인 (키워드 목록이 비면 전체 통과)
def _is_large_venue(fclty_name: str) -> bool:
    if not _LARGE_VENUE_KEYWORDS:
        return True
    return any(keyword in fclty_name for keyword in _LARGE_VENUE_KEYWORDS)


# genrenm(장르명)이 허용 목록에 포함되는지 확인 (목록이 비면 전체 통과)
def _is_allowed_genre(genre_name: str) -> bool:
    if not _ALLOWED_GENRES:
        return True
    return genre_name in _ALLOWED_GENRES


# KOPIS 목록 API 전체 페이지 순회하여 대형 공연장 kopis_id만 수집
async def _fetch_all_kopis_ids(client: httpx.AsyncClient, today: date, end_date: date) -> list[str]:
    kopis_ids: list[str] = []
    cpage = 1

    while cpage <= _MAX_KOPIS_LIST_PAGES:
        params = {
            "service": settings.KOPIS_API_KEY,
            "stdate": today.strftime("%Y%m%d"),
            "eddate": end_date.strftime("%Y%m%d"),
            "genrenm": "대중음악",
            "rows": 100,
            "cpage": cpage,
        }
        await _throttle_kopis_request()
        try:
            response = await client.get(f"{settings.KOPIS_BASE_URL}/pblprfr", params=params)
        except httpx.HTTPError as e:
            logger.warning(f"KOPIS 배치 목록 조회 실패 (cpage={cpage}): {e}")
            break

        if response.status_code != 200:
            logger.warning(f"KOPIS 배치 목록 조회 실패 (cpage={cpage})")
            break

        # 응답이 200이어도 몸체가 깨져있으면(순간 오류 등) 그 페이지만 포기하고 지금까지
        # 모은 kopis_id는 반환 -> 한 페이지 파싱 실패로 그날 배치 전체가 죽는 것을 방지
        try:
            root = ET.fromstring(response.content)
        except ET.ParseError as e:
            logger.warning(f"KOPIS 배치 목록 응답 파싱 실패 (cpage={cpage}): {e}")
            break

        entries = root.findall("db")
        page_ids = [
            elem.findtext("mt20id", "").strip()
            for elem in entries
            if elem.findtext("mt20id", "").strip()
            and _is_large_venue(elem.findtext("fcltynm", "") or "")
            and _is_allowed_genre(elem.findtext("genrenm", "") or "")
        ]
        kopis_ids.extend(page_ids)

        # 마지막 페이지 판단은 필터링 전 원본 응답 건수 기준 (필터링 후 건수로 판단하면 조기 종료될 수 있음)
        if len(entries) < 100:
            break
        cpage += 1

    return kopis_ids


# 신규 공연 상세 조회 동시 요청 수 제한 (KOPIS API 레이트리밋 고려)
_KOPIS_DETAIL_CONCURRENCY = 4


# 배치로 대량 상세 조회 시 KOPIS 쪽에서 순간적으로 거부(400)하는 경우가 있어 재시도로 흡수
_KOPIS_DETAIL_MAX_RETRIES = 3
_KOPIS_DETAIL_RETRY_BACKOFF = 1.0


# 세마포어로 동시성 제한하며 상세 조회 (DB 접근 없이 fetch+파싱만 수행, 실패 시 None)
async def _fetch_new_concert_data(
    client: httpx.AsyncClient, kopis_id: str, semaphore: asyncio.Semaphore
) -> dict | None:
    async with semaphore:
        last_error: Exception | None = None
        for attempt in range(_KOPIS_DETAIL_MAX_RETRIES):
            try:
                return await _fetch_kopis_detail_data(client, kopis_id)
            except Exception as e:
                last_error = e
                if attempt < _KOPIS_DETAIL_MAX_RETRIES - 1:
                    await asyncio.sleep(_KOPIS_DETAIL_RETRY_BACKOFF * (attempt + 1))
        logger.warning(f"KOPIS 상세 조회 실패 ({kopis_id}): {last_error}")
        return None


# 1회 실행당 상세조회할 신규 공연 최대 건수 (초기 대량 백필을 여러 날에 나눠 처리하기 위한 상한)
_MAX_NEW_CONCERTS_PER_RUN = 3000


# KOPIS 일별 배치: 신규 공연 수집 + 뉴스피드 생성
async def sync_daily_concerts(db: AsyncSession) -> None:
    today = date.today()
    end_date = today + timedelta(days=365)

    async with httpx.AsyncClient(timeout=10.0) as client:
        kopis_ids = await _fetch_all_kopis_ids(client, today, end_date)

    if not kopis_ids:
        return

    # DB에 이미 있는 공연 조회
    result = await db.execute(
        select(Concert).where(Concert.kopis_id.in_(kopis_ids))
    )
    existing = {c.kopis_id: c for c in result.scalars().all()}

    # 팔로우 역인덱스를 배치 1회당 한 번만 구축해 공연마다 재조회하지 않도록 함
    follow_index = await _build_follow_index(db)

    new_kopis_ids = [kid for kid in kopis_ids if kid not in existing]
    logger.info(
        f"KOPIS 조회 대상 총 {len(kopis_ids)}건 (기존 {len(existing)}건, 신규 {len(new_kopis_ids)}건)"
    )

    # 1회 실행당 처리량 상한 (초기 대량 백필을 여러 날에 걸쳐 나눠 처리하기 위함)
    # 상한에 걸려 못 받은 나머지는 계속 "신규" 상태로 남아 다음 실행(다음날 자정 배치 등)에서 이어서 처리됨
    if len(new_kopis_ids) > _MAX_NEW_CONCERTS_PER_RUN:
        logger.info(
            f"신규 공연 {len(new_kopis_ids)}건 중 {_MAX_NEW_CONCERTS_PER_RUN}건만 이번 실행에서 처리, 나머지는 다음 실행에서 처리"
        )
        new_kopis_ids = new_kopis_ids[:_MAX_NEW_CONCERTS_PER_RUN]

    # 신규 공연 상세 조회는 동시성 제한을 걸어 병렬로 수행 (DB 세션은 공유하지 않음)
    if new_kopis_ids:
        semaphore = asyncio.Semaphore(_KOPIS_DETAIL_CONCURRENCY)
        async with httpx.AsyncClient(timeout=10.0) as client:
            results = await asyncio.gather(
                *(_fetch_new_concert_data(client, kid, semaphore) for kid in new_kopis_ids)
            )

        # 아티스트명 정규화용 기존 아티스트 집합도 배치 1회당 한 번만 구축해 재사용
        # (건마다 재조회하면 신규 공연이 많은 초기 백필에서 DB 왕복이 크게 늘어남)
        known_artist_names = await get_known_artist_names(db)

        # DB upsert + 뉴스피드 생성은 세션이 공유되므로 순차 처리
        for data in results:
            if data is None:
                continue
            concert = await _upsert_concert(db, data, known_artist_names)
            matched = await _create_news_feeds_for_concert(db, concert, follow_index)
            # NEW_CONCERT 알림은 여기(진짜 신규 공연)에서만 생성 - 아래 기존 공연
            # 백필 루프나 온디맨드 상세조회에서는 생성하지 않음(schedule_new_concert_notifications 문서 참고)
            await schedule_new_concert_notifications(db, concert, matched)
            await db.commit()

    for kopis_id in kopis_ids:
        concert = existing.get(kopis_id)
        if concert is not None and concert.artist_name:
            # 이미 있고 아티스트 정보 있음: API 재호출 없이 뉴스피드만 생성
            await _create_news_feeds_for_concert(db, concert, follow_index)
            await db.commit()


# KOPIS 상세 API 호출 + XML 파싱만 수행 (DB 접근 없음 -> 병렬 호출 가능)
async def _fetch_kopis_detail_data(client: httpx.AsyncClient, kopis_id: str) -> dict:
    await _throttle_kopis_request()
    response = await client.get(
        f"{settings.KOPIS_BASE_URL}/pblprfr/{kopis_id}",
        params={"service": settings.KOPIS_API_KEY},
    )

    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="KOPIS API 호출에 실패했습니다.")

    root = ET.fromstring(response.content)
    elem = root.find("db")
    if elem is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    # 목록/검색 계열 API는 장르를 클라이언트 사이드에서 걸러내지만(_fetch_all_kopis_ids,
    # _fetch_and_upsert_concerts), 이 상세 조회는 kopis_id 하나만 알면 어디서든(스캔 후보 검색,
    # 공연장 검색 등을 거치지 않고도) 호출될 수 있어 그 필터를 안 거칠 수 있다. 그래서 여기서도
    # 한 번 더 확인 - 그래야 대중음악이 아닌 공연(클래식/발레/연극 등)이 이 경로로 새어 들어오지 않음
    if not _is_allowed_genre(elem.findtext("genrenm") or ""):
        raise HTTPException(status_code=404, detail="대중음악 공연만 등록할 수 있습니다.")

    # 공연 상세 정보 파싱
    start_raw = (elem.findtext("prfpdfrom") or "").strip()
    end_raw = (elem.findtext("prfpdto") or "").strip()
    prfcast = (elem.findtext("prfcast") or "").strip()
    pcseguidance = (elem.findtext("pcseguidance") or "").strip()
    dtguidance = (elem.findtext("dtguidance") or "").strip()

    # relates 파싱: 예매 사이트 링크 추출
    ticketing_links: dict[str, str] = {}
    relates_elem = elem.find("relates")
    if relates_elem is not None:
        for relate in relates_elem.findall("relate"):
            site_name = (relate.findtext("relatenm") or "").strip()
            site_url = (relate.findtext("relateurl") or "").strip()
            if site_name and site_url:
                key = find_site_key(site_name)
                if key:
                    ticketing_links[key] = site_url

    name = elem.findtext("prfnm") or ""
    return {
        "kopis_id": kopis_id,
        "name": name,
        "artist_name": _parse_artists(prfcast) if prfcast else [],
        "venue": elem.findtext("fcltynm") or None,
        "start_date": _parse_date(start_raw),
        "start_time": _parse_start_time(dtguidance) if dtguidance else None,
        "end_date": _parse_date(end_raw),
        "genre": [g for g in [elem.findtext("genrenm")] if g],
        "poster_url": elem.findtext("poster") or None,
        "description": elem.findtext("sty") or None,
        "price": _parse_price(pcseguidance),
        "event_type": _classify_event_type(name),
        "ticketing_links": ticketing_links or None,
        "kopis_detail_synced_at": datetime.now(timezone.utc),
    }


# KOPIS 공연 상세 조회 (kopis_id -> Concert + DB upsert)
async def get_concert_detail(
    db: AsyncSession, kopis_id: str, follow_index: dict[str, list[tuple]] | None = None
) -> Concert:
    async with httpx.AsyncClient(timeout=10.0) as client:
        data = await _fetch_kopis_detail_data(client, kopis_id)

    concert = await _upsert_concert(db, data)
    await _create_news_feeds_for_concert(db, concert, follow_index)
    await db.commit()
    await db.refresh(concert)
    return concert
