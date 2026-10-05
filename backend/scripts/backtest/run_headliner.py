"""헤드라이너 판정(C 트랙) - 샘플 추출 / 인지도 수집 / 규칙 평가.

단독공연(SOLO)인데 아티스트가 2명 이상인 공연에서 "누가 주인공인가"를 규칙으로 맞출 수 있는지 잼.
서버에서 export_headliner_samples.py로 뽑은 input/headliner_candidates.json이 입력.

  sample     - 최근(--since 이후) 공연에서 무작위 N건 -> input/headliner_review.json (사용자가 answer를 채움)
  popularity - 샘플 아티스트의 Last.fm 청취자 수 -> cache/headliner_popularity.json
  eval       - 규칙별 판정률/정확도 (answer가 채워진 공연만 정확도 계산, 판정률은 전체 샘플 기준)

answer 작성법 (headliner_review.json):
  주인공 아티스트 번호(idx) 리스트. 예) [0] = 0번만 주인공, 나머지는 게스트/오프닝
  [0, 2] = 0번과 2번이 공동 주인공, 모든 번호를 넣으면 = 동등 출연(공동공연/멤버 전원 등)
  빈 값이나 null = 판단 불가(평가에서 제외)

사용법 (backend/에서):
    python scripts/backtest/run_headliner.py sample --n 50
    python scripts/backtest/run_headliner.py popularity
    python scripts/backtest/run_headliner.py eval
"""

import argparse
import asyncio
import json
import random
import re
import sys
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_BACKEND_ROOT))

import httpx  # noqa: E402

from app.core.config import settings  # noqa: E402

_DIR = Path(__file__).resolve().parent
_CANDIDATES = _DIR / "input" / "headliner_candidates.json"
_REVIEW = _DIR / "input" / "headliner_review.json"
_POPULARITY = _DIR / "cache" / "headliner_popularity.json"

# 공연명에서 "여기부터는 게스트"를 뜻하는 표기 (X/x/&는 동등 출연이라 여기에 없음)
_GUEST_MARKER = re.compile(r"\bwith\b|\bfeat\.?|\bft\.|\bguest\b|게스트|특별출연|스페셜\s*게스트", re.IGNORECASE)
# 이 배수 이상 차이가 나야 인지도로 주인공을 확정 (그 아래는 판정 보류)
_POPULARITY_RATIO = 3.0


def _read(path: Path):
    return json.loads(path.read_text("utf-8"))


def _write(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1), "utf-8")


def _norm(text: str) -> str:
    return re.sub(r"\W", "", text.casefold())


def cmd_sample(n: int, since: str, seed: int) -> None:
    candidates = [c for c in _read(_CANDIDATES) if c["start_date"] >= since]
    random.Random(seed).shuffle(candidates)
    sample = candidates[:n]
    review = [
        {
            "concert_id": c["concert_id"],
            "name": c["name"],
            "date": c["start_date"],
            "venue": c["venue"],
            "poster_url": c["poster_url"],
            "artists": [{"idx": i, "text": a["text"]} for i, a in enumerate(c["artists"])],
            "answer": None,
        }
        for c in sample
    ]
    _write(_REVIEW, review)
    print(f"후보 {len(candidates)}건(since {since}) 중 {len(review)}건 -> {_REVIEW}")


async def _lastfm_listeners(client: httpx.AsyncClient, name: str, mbid: str | None) -> int | None:
    params = {"method": "artist.getinfo", "api_key": settings.LASTFM_API_KEY, "format": "json", "autocorrect": 1}
    params.update({"mbid": mbid} if mbid else {"artist": name})
    for attempt in range(2):
        try:
            response = await client.get(settings.LASTFM_BASE_URL, params=params)
            if response.status_code != 200:
                return None
            info = response.json().get("artist")
            return int(info["stats"]["listeners"]) if info else None
        except (httpx.HTTPError, ValueError, KeyError):
            await asyncio.sleep(1)
    return None


async def cmd_popularity() -> None:
    candidates = {c["concert_id"]: c for c in _read(_CANDIDATES)}
    cache = _read(_POPULARITY) if _POPULARITY.exists() else {}
    async with httpx.AsyncClient(timeout=10.0) as client:
        for review in _read(_REVIEW):
            for artist in candidates[review["concert_id"]]["artists"]:
                key = artist["text"]
                if key in cache:
                    continue
                cache[key] = await _lastfm_listeners(client, artist["text"], artist["mbid"])
                await asyncio.sleep(0.3)
    _write(_POPULARITY, cache)
    found = sum(1 for v in cache.values() if v is not None)
    print(f"아티스트 {len(cache)}명 중 청취자 수 확보 {found}명 -> {_POPULARITY}")


def _artist_names(artist: dict, use_aliases: bool) -> set[str]:
    names = {artist["text"]}
    if use_aliases:
        names |= {artist.get("canonical_name") or "", *artist.get("aliases", [])}
    return {n for n in (_norm(x) for x in names) if len(n) >= 2}


# 규칙 1 - 공연명에 이름(별칭 포함)이 들어있는 아티스트. 게스트 표기(with/feat/Guest) 뒤에 나온 이름은
# 게스트로 뺌. 이름이 하나도 안 나오면 None(판정 보류)
def rule_title(review: dict, artists: list[dict], use_aliases: bool = True) -> set[int] | None:
    title = review["name"]
    marker = _GUEST_MARKER.search(title)
    full_title = _norm(title)
    head_title = _norm(title[: marker.start()]) if marker else full_title
    names = [_artist_names(a, use_aliases) for a in artists]
    found = {i for i, ns in enumerate(names) if any(n in full_title for n in ns)}
    if not found:
        return None
    if marker:
        before = {i for i in found if any(n in head_title for n in names[i])}
        if before:
            return before
    return found


# 규칙 2 - 인지도(Last.fm 청취자 수)가 가장 높은 아티스트. 2위와 _POPULARITY_RATIO배 이상 차이 날 때만 확정
def rule_popularity(artists: list[dict], popularity: dict) -> set[int] | None:
    scores = [(popularity.get(a["text"]) or 0, i) for i, a in enumerate(artists)]
    scores.sort(reverse=True)
    if scores[0][0] <= 0:
        return None
    if len(scores) > 1 and scores[0][0] < _POPULARITY_RATIO * max(scores[1][0], 1):
        return None
    return {scores[0][1]}


def cmd_eval() -> None:
    candidates = {c["concert_id"]: c for c in _read(_CANDIDATES)}
    popularity = _read(_POPULARITY) if _POPULARITY.exists() else {}
    reviews = _read(_REVIEW)
    labeled = [r for r in reviews if r["answer"]]
    print(f"샘플 {len(reviews)}건 / 라벨 채워진 {len(labeled)}건\n")

    rows = []
    for review in reviews:
        artists = candidates[review["concert_id"]]["artists"]
        r1 = rule_title(review, artists)
        r1_plain = rule_title(review, artists, use_aliases=False)
        r2 = rule_popularity(artists, popularity)
        everyone = set(range(len(artists)))
        rows.append((review, len(artists), {
            "R1 공연명(이름만)": r1_plain,
            "R1 공연명(별칭)": r1,
            "R2 인지도": r2,
            "R1→R2": r1 if r1 is not None else r2,
            "R1→전원동등": r1 if r1 is not None else everyone,
        }))

    print("[판정률] 규칙이 주인공을 정한 비율 (전체 샘플)")
    for name in rows[0][2]:
        decided = sum(1 for _, _, preds in rows if preds[name] is not None)
        print(f"  {name:<16} {decided}/{len(rows)}")

    if not labeled:
        print("\nanswer가 아직 없어서 정확도는 건너뜀")
        return

    print("\n[정확도] 라벨 있는 공연 기준")
    print(f"{'규칙':<16}{'판정':>6}{'정확일치':>10}{'주인공포함':>12}{'게스트제외':>12}   (판정한 공연 중 비율)")
    for name in rows[0][2]:
        decided = exact = includes = excludes = 0
        for review, n_artists, preds in rows:
            answer = review["answer"]
            pred = preds[name]
            if not answer or pred is None:
                continue
            truth = set(answer)
            decided += 1
            exact += pred == truth
            includes += truth <= pred
            excludes += pred <= truth
        if decided:
            print(f"{name:<16}{decided:>6}{exact / decided:>10.2f}{includes / decided:>12.2f}{excludes / decided:>12.2f}")
        else:
            print(f"{name:<16}{0:>6}")
    print("\n정확일치 = 예측 주인공 집합이 정답과 같음 / 주인공포함 = 진짜 주인공을 빠뜨리지 않음 / 게스트제외 = 게스트를 주인공으로 잘못 넣지 않음")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("sample")
    s.add_argument("--n", type=int, default=50)
    s.add_argument("--since", default="2026-01-01")
    s.add_argument("--seed", type=int, default=7)
    sub.add_parser("popularity")
    sub.add_parser("eval")
    args = parser.parse_args()
    if args.command == "sample":
        cmd_sample(args.n, args.since, args.seed)
    elif args.command == "popularity":
        asyncio.run(cmd_popularity())
    else:
        cmd_eval()


if __name__ == "__main__":
    main()
