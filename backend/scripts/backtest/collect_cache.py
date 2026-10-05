"""예상 셋리 백테스트용 외부 API 응답을 로컬 JSON 캐시로 모으는 스크립트 (DB 안 씀).

이후 백테스트는 이 캐시만 읽어서 API 호출 없이 반복 실험함. 두 단계:

  probe - input/artist_candidates.json의 각 아티스트를 Setlist.fm mbid 검색 1번씩(공연 수 total 확인)
          -> input/probe.json (공연 수 내림차순). 30공연 이상만 백테스트 대상 후보
  fetch - 고른 아티스트의 Setlist.fm 원본(최대 --pages 페이지) + Last.fm 인기곡 + iTunes 곡/발매일을
          cache/<mbid>/ 아래에 저장. 이미 있는 파일은 건너뜀(--force로 덮어쓰기)

캐시 파일 (cache/<mbid>/):
  meta.json      - 이름/별칭/iTunes ID/수집 시각
  setlistfm.json - Setlist.fm search/setlists 원본 setlist 배열 (최신순, 아티스트 mbid 검색이라 본인 셋리만)
  lastfm.json    - [[곡명, 청취자 수], ...] (지금 시점 기준이라 과거 시점 재현은 안 됨)
  itunes.json    - us 스토어 곡 원본(releaseDate 포함) + kr 스토어 제목(trackId -> 제목)

사용법 (로컬, backend/에서):
    python scripts/backtest/collect_cache.py probe --limit 80
    python scripts/backtest/collect_cache.py fetch --min-total 30 --top 30
    python scripts/backtest/collect_cache.py fetch --mbid <mbid> --force
"""

import argparse
import asyncio
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_BACKEND_ROOT))

import httpx  # noqa: E402

from app.core.config import settings  # noqa: E402
from app.services.lastfm import fetch_top_tracks  # noqa: E402
from app.services.musicbrainz import fetch_apple_music_artist_id  # noqa: E402
from app.services.setlistfm import _HEADERS  # noqa: E402

_DIR = Path(__file__).resolve().parent
_INPUT_DIR = _DIR / "input"
_CACHE_DIR = _DIR / "cache"

# Setlist.fm은 초당 2회 제한이라 여유를 두고, 429가 오면 늘려가며 재시도
_SETLISTFM_DELAY = 0.7
_RETRY_DELAYS = (5, 15, 45)
_ITUNES_LOOKUP_URL = "https://itunes.apple.com/lookup"
_HANGUL_RE = re.compile(r"[가-힣]")


def _read_json(path: Path):
    return json.loads(path.read_text("utf-8"))


def _write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1), "utf-8")


# Setlist.fm 한 페이지 요청 - 404는 (빈 응답)으로, 429는 대기 후 재시도, 그 외 실패는 예외
async def _setlistfm_page(client: httpx.AsyncClient, mbid: str, page: int) -> dict:
    url = f"{settings.SETLISTFM_BASE_URL}/search/setlists"
    for delay in (*_RETRY_DELAYS, None):
        response = await client.get(url, headers=_HEADERS, params={"artistMbid": mbid, "p": page})
        if response.status_code == 404:
            return {"setlist": [], "total": 0}
        if response.status_code == 429 and delay is not None:
            await asyncio.sleep(delay)
            continue
        response.raise_for_status()
        return response.json()
    raise RuntimeError("unreachable")


async def cmd_probe(limit: int) -> None:
    candidates = _read_json(_INPUT_DIR / "artist_candidates.json")[:limit]
    probed = []
    async with httpx.AsyncClient(timeout=15.0) as client:
        for i, a in enumerate(candidates, 1):
            try:
                data = await _setlistfm_page(client, a["mbid"], 1)
                total = data.get("total", 0)
            except (httpx.HTTPError, RuntimeError) as e:
                print(f"[{i}/{len(candidates)}] {a['canonical_name']}: 실패 {e}")
                total = None
            names = [a["canonical_name"], a.get("display_name") or "", *a["aliases"]]
            probed.append({
                **a,
                "setlistfm_total": total,
                "has_hangul_alias": any(_HANGUL_RE.search(n) for n in names),
            })
            print(f"[{i}/{len(candidates)}] {a['canonical_name']}: {total}")
            await asyncio.sleep(_SETLISTFM_DELAY)
    probed.sort(key=lambda a: -(a["setlistfm_total"] or 0))
    _write_json(_INPUT_DIR / "probe.json", probed)
    eligible = [a for a in probed if (a["setlistfm_total"] or 0) >= 30]
    print(f"30공연 이상 {len(eligible)}명 -> {_INPUT_DIR / 'probe.json'}")


async def _fetch_setlistfm(client: httpx.AsyncClient, mbid: str, pages: int) -> list[dict]:
    setlists: list[dict] = []
    for page in range(1, pages + 1):
        data = await _setlistfm_page(client, mbid, page)
        setlists.extend(data.get("setlist", []))
        if page * data.get("itemsPerPage", 20) >= data.get("total", 0):
            break
        await asyncio.sleep(_SETLISTFM_DELAY)
    return setlists


# us 스토어 곡 원본(발매일 필요) + kr 스토어 제목. 피처링 참여 곡은 아티스트 ID로 거름
async def _fetch_itunes(client: httpx.AsyncClient, itunes_artist_id: str) -> dict:
    response = await client.get(
        _ITUNES_LOOKUP_URL, params={"id": itunes_artist_id, "entity": "song", "limit": 200, "country": "us"}
    )
    response.raise_for_status()
    tracks = [
        r for r in response.json().get("results", [])
        if r.get("wrapperType") == "track" and str(r.get("artistId")) == itunes_artist_id
    ]
    kr_titles: dict[str, str] = {}
    if tracks:
        ids = ",".join(str(t["trackId"]) for t in tracks if t.get("trackId"))
        kr = await client.get(_ITUNES_LOOKUP_URL, params={"id": ids, "country": "kr"})
        if kr.status_code == 200:
            kr_titles = {
                str(r["trackId"]): r["trackName"]
                for r in kr.json().get("results", [])
                if r.get("wrapperType") == "track" and r.get("trackId") and r.get("trackName")
            }
    return {
        "tracks": [
            {
                "trackId": t.get("trackId"),
                "trackName": t.get("trackName"),
                "collectionName": t.get("collectionName"),
                "releaseDate": t.get("releaseDate"),
                "trackNumber": t.get("trackNumber"),
            }
            for t in tracks
        ],
        "kr_titles": kr_titles,
    }


async def _fetch_artist(client: httpx.AsyncClient, a: dict, pages: int, force: bool) -> None:
    out = _CACHE_DIR / a["mbid"]
    name = a["canonical_name"]

    if force or not (out / "setlistfm.json").exists():
        _write_json(out / "setlistfm.json", await _fetch_setlistfm(client, a["mbid"], pages))
    if force or not (out / "lastfm.json").exists():
        _, tracks = await fetch_top_tracks(mbid=a["mbid"], limit=100)
        _write_json(out / "lastfm.json", tracks)

    itunes_artist_id = a.get("itunes_artist_id")
    if not itunes_artist_id and a.get("anchor_confirmed_by") != "none":
        itunes_artist_id = await fetch_apple_music_artist_id(a["mbid"])
    if itunes_artist_id and (force or not (out / "itunes.json").exists()):
        _write_json(out / "itunes.json", await _fetch_itunes(client, itunes_artist_id))
        await asyncio.sleep(3.0)  # iTunes 분당 약 20회 제한

    _write_json(out / "meta.json", {
        "canonical_name": name,
        "display_name": a.get("display_name"),
        "aliases": a["aliases"],
        "mbid": a["mbid"],
        "itunes_artist_id": itunes_artist_id,
        "setlistfm_total": a.get("setlistfm_total"),
        "fetched_at": datetime.now(timezone.utc).isoformat(),
    })


async def cmd_fetch(min_total: int, top: int, mbids: list[str], pages: int, force: bool) -> None:
    probed = _read_json(_INPUT_DIR / "probe.json")
    if mbids:
        targets = [a for a in probed if a["mbid"] in mbids]
    else:
        # 국내/해외는 자동 구분이 안 돼서(한글 별칭은 해외 아티스트에도 있음) 보통은 --mbid로 직접 고름
        targets = [a for a in probed if (a["setlistfm_total"] or 0) >= min_total][:top]

    async with httpx.AsyncClient(timeout=20.0) as client:
        for i, a in enumerate(targets, 1):
            print(f"[{i}/{len(targets)}] {a['canonical_name']} (total={a['setlistfm_total']})")
            try:
                await _fetch_artist(client, a, pages, force)
            except (httpx.HTTPError, RuntimeError) as e:
                print(f"  실패, 다음으로: {e}")
            await asyncio.sleep(_SETLISTFM_DELAY)
    print(f"완료 -> {_CACHE_DIR}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("probe")
    p.add_argument("--limit", type=int, default=80, help="공연 수 많은 순으로 몇 명까지 확인할지")
    f = sub.add_parser("fetch")
    f.add_argument("--min-total", type=int, default=30)
    f.add_argument("--top", type=int, default=30, help="수집할 아티스트 수(공연 수 많은 순)")
    f.add_argument("--mbid", action="append", default=[], help="지정하면 그 아티스트만(여러 번 가능)")
    f.add_argument("--pages", type=int, default=5, help="Setlist.fm 페이지 수(페이지당 20공연)")
    f.add_argument("--force", action="store_true")
    args = parser.parse_args()

    if args.command == "probe":
        asyncio.run(cmd_probe(args.limit))
    else:
        asyncio.run(cmd_fetch(args.min_total, args.top, args.mbid, args.pages, args.force))


if __name__ == "__main__":
    main()
