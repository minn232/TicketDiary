"""백테스트 공용: 캐시 로드와 (예측 시점 이전 이력, 정답 공연) 분할.

핵심 규칙 - 정답 공연 날짜 "이전" 데이터만 이력으로 씀(같은 날 다른 공연도 제외). 이게 새면
적중률이 부풀려지므로 split_cases 한 곳에서만 자르고, 예측기는 history만 받음.
"""

import json
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

from app.services.setlist_model import normalize_title

CACHE_DIR = Path(__file__).resolve().parent / "cache"

# pre_setlist._top_songs_for_artist가 실제로 받는 양(3페이지 x 20공연, 곡 없는 공연 포함)
LIVE_HISTORY_SHOWS = 60
# 정답이 되려면 곡이 이만큼은 있어야 함(부분 입력/불량 셋리 제외)
MIN_SONGS = 3


@dataclass
class Show:
    id: str
    date: date
    tour: str | None
    songs: list[dict]  # [{"name", "encore", "tape"}] 셋리 순서 그대로

    @property
    def names(self) -> list[str]:
        return [s["name"] for s in self.songs]


@dataclass
class ArtistData:
    mbid: str
    name: str
    aliases: list[str]
    shows: list[Show]  # 최신순, 곡 없는 공연 포함(원본 그대로)
    lastfm: list[tuple[str, int]]
    itunes: dict | None
    meta: dict = field(default_factory=dict)


@dataclass
class Case:
    artist: ArtistData
    target: Show
    history: list[Show]  # 정답 날짜 이전 공연, 최신순, 곡 없는 공연 포함


def _parse_show(raw: dict) -> Show:
    songs = []
    for s in raw.get("sets", {}).get("set", []):
        is_encore = s.get("encore") is not None
        for song in s.get("song", []):
            name = (song.get("name") or "").strip()
            if name:
                songs.append({"name": name, "encore": is_encore, "tape": bool(song.get("tape"))})
    return Show(
        id=raw["id"],
        date=datetime.strptime(raw["eventDate"], "%d-%m-%Y").date(),
        tour=((raw.get("tour") or {}).get("name") or None),
        songs=songs,
    )


def load_artist(mbid: str) -> ArtistData:
    d = CACHE_DIR / mbid
    meta = json.loads((d / "meta.json").read_text("utf-8"))
    shows = [_parse_show(r) for r in json.loads((d / "setlistfm.json").read_text("utf-8"))]
    # 원본이 최신순이지만 같은 날짜 순서를 건드리지 않게 안정 정렬
    shows.sort(key=lambda s: s.date, reverse=True)
    lastfm_path, itunes_path = d / "lastfm.json", d / "itunes.json"
    return ArtistData(
        mbid=mbid,
        name=meta["canonical_name"],
        aliases=meta.get("aliases", []),
        shows=shows,
        lastfm=[tuple(t) for t in json.loads(lastfm_path.read_text("utf-8"))] if lastfm_path.exists() else [],
        itunes=json.loads(itunes_path.read_text("utf-8")) if itunes_path.exists() else None,
        meta=meta,
    )


def load_all_artists() -> list[ArtistData]:
    return [load_artist(p.name) for p in sorted(CACHE_DIR.iterdir()) if (p / "meta.json").exists()]


# 곡 있는 공연 중 최신 n개를 정답으로, 각각 그 날짜 이전 이력만 붙임. 이력의 usable(곡 3개+) 공연이
# min_history 미만이면 그 정답은 제외(이력이 너무 얇아 예측 의미가 없음)
def split_cases(artist: ArtistData, n_targets: int = 5, min_history: int = 5) -> list[Case]:
    usable = [s for s in artist.shows if len([x for x in s.songs if not x["tape"]]) >= MIN_SONGS]
    cases = []
    for target in usable[:n_targets]:
        history = [s for s in artist.shows if s.date < target.date]
        usable_history = [s for s in history if len(s.songs) >= MIN_SONGS]
        if len(usable_history) < min_history:
            continue
        cases.append(Case(artist=artist, target=target, history=history))
    return cases


# 정답/예측 곡을 같은 곡으로 보는 키 - 모델의 집계 키와 같은 함수를 씀
title_key = normalize_title
