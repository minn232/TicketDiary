"""콜드스타트(Setlist.fm 과거 셋리 없음) 백테스트 - 대표곡 방식(B0) vs iTunes 신곡 가중(B1).

정답은 Setlist.fm의 최근 공연이고, 그 아티스트의 Setlist.fm 이력은 아예 쓰지 않음(없다고 가정).
예측은 정답 공연 "날짜 이전에 발매된" iTunes 곡과 Last.fm 인기곡만 씀.

제약 - Last.fm 인기곡은 지금 시점 스냅샷이라 과거 시점 재현이 안 됨. 공연 이후에 뜬 곡이 섞이는
누수를 줄이려고 정답을 최근 6개월(--since) 공연으로 한정함. iTunes는 발매일로 자를 수 있음.
B2(유저 확정 셋리)는 서버 RealSetlist가 7건뿐이라 통계 불가 - 여기서 다루지 않음.

사용법 (backend/에서):
    python scripts/backtest/run_cold_start.py
    python scripts/backtest/run_cold_start.py --grid    # 신곡 가중 파라미터 격자(탐색용)
"""

import argparse
import json
import re
import sys
from datetime import date, datetime
from pathlib import Path
from statistics import mean

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_BACKEND_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from app.services.representative_songs import (  # noqa: E402
    _LASTFM_MIN_TOP_LISTENERS,
    _LASTFM_MIN_TRACKS,
    _dedupe_titles,
    _rank_by_listeners,
    _title_key,
)
from data import MIN_SONGS, ArtistData, Show, load_all_artists, title_key  # noqa: E402

ALIGNMENT_PATH = Path(__file__).resolve().parent / "alignment.json"
# 메들리(A / B / C)는 곡별로 쪼개서 봄. 인트로/아웃트로/인터루드 트랙은 곡이 아니라 뺌
_MEDLEY_SPLIT = " / "
_NON_SONG_RE = re.compile(r"(intro|outro|interlude)", re.IGNORECASE)

TOP_N = 20  # 운영 representative_songs_for_artist 호출값(generate_pre_setlist top_n)
LASTFM_LIMIT = 50  # 운영 fetch_top_tracks 기본 limit


class Song:
    def __init__(self, name: str, variants: list[str], released: date | None = None):
        self.name = name
        self.keys = {title_key(v) for v in variants if v}
        self.released = released


# 정답 공연 날짜 이전에 발매된 iTunes 곡(운영 fetch_itunes_artist_song_titles와 같은 순서/중복 제거).
# 같은 제목이 여러 앨범(베스트/재발매)에 있으면 가장 이른 발매일을 씀
def itunes_catalog(artist: ArtistData, as_of: date) -> list[Song]:
    if artist.itunes is None:
        return []
    kr_titles = artist.itunes.get("kr_titles", {})
    pairs: list[tuple[str, str, date | None]] = []
    for t in artist.itunes["tracks"]:
        released = datetime.fromisoformat(t["releaseDate"].replace("Z", "+00:00")).date() if t.get("releaseDate") else None
        if released is not None and released >= as_of:
            continue
        us = t.get("trackName")
        kr = kr_titles.get(str(t.get("trackId"))) or us
        if kr and us:
            pairs.append((kr, us, released))
    kept = set(_dedupe_titles([kr for kr, _, _ in pairs]))
    earliest: dict[str, date] = {}
    for kr, _, released in pairs:
        if released is not None:
            key = _title_key(kr)
            earliest[key] = min(released, earliest.get(key, released))
    songs, seen = [], set()
    for kr, us, _ in pairs:
        if kr in kept and kr not in seen:
            seen.add(kr)
            songs.append(Song(kr, [kr, us], earliest.get(_title_key(kr))))
    return songs


def lastfm_tracks(artist: ArtistData) -> list[tuple[str, int]]:
    return artist.lastfm[:LASTFM_LIMIT]


# 운영 representative_songs_for_artist와 같은 규칙: iTunes 곡을 Last.fm 청취자 순으로, iTunes가 없으면
# Last.fm 품질 기준을 넘을 때만 Last.fm 인기곡
def predict_b0(artist: ArtistData, as_of: date) -> list[Song]:
    catalog = itunes_catalog(artist, as_of)
    tracks = lastfm_tracks(artist)
    if catalog:
        by_kr = {s.name: s for s in catalog}
        return [by_kr[t] for t in _rank_by_listeners([s.name for s in catalog], tracks)[:TOP_N]]
    if len(tracks) >= _LASTFM_MIN_TRACKS and max(c for _, c in tracks) >= _LASTFM_MIN_TOP_LISTENERS:
        return [Song(n, [n]) for n in _dedupe_titles([n for n, _ in tracks])[:TOP_N]]
    return []


# B1 - B0의 인기도 점수(청취자 / 최대 청취자)에 최근 발매 가산점 b * (1 - 경과일/window)를 더함.
# 인기도가 0인 신곡(Last.fm에 아직 안 잡힘)도 가산점으로 올라올 수 있게 덧셈으로 함
def predict_b1(artist: ArtistData, as_of: date, boost: float, window_days: int) -> list[Song]:
    catalog = itunes_catalog(artist, as_of)
    if not catalog:
        return predict_b0(artist, as_of)
    listeners = {_title_key(n): c for n, c in lastfm_tracks(artist)}
    top = max((listeners.get(_title_key(s.name), 0) for s in catalog), default=0) or 1
    scored = []
    for idx, song in enumerate(catalog):
        pop = listeners.get(_title_key(song.name), 0) / top
        recent = 0.0
        if song.released is not None:
            recent = max(0.0, 1 - (as_of - song.released).days / window_days)
        scored.append((pop + boost * recent, -idx, song))  # 동점은 iTunes 원래 순서
    scored.sort(key=lambda x: (-x[0], -x[1]))
    return [s for _, _, s in scored[:TOP_N]]


def load_alignment(enabled: bool) -> dict[str, dict[str, str]]:
    if not enabled:
        return {}
    return json.loads(ALIGNMENT_PATH.read_text("utf-8"))["artists"]


# 정답 곡 -> 같은 곡으로 인정할 키 집합(자기 제목 + 사람이 짝지은 후보 풀 제목)
def truth_map(artist: ArtistData, show: Show, alignment: dict[str, dict[str, str]]) -> dict[str, set[str]]:
    aliases = alignment.get(artist.name, {})
    result: dict[str, set[str]] = {}
    for song in show.songs:
        if song["tape"]:
            continue
        name = song["name"]
        parts = [name] if aliases.get(name) else name.split(_MEDLEY_SPLIT)
        for part in parts:
            part = part.strip()
            key = title_key(part)
            if not key or _NON_SONG_RE.search(part):
                continue
            accepted = result.setdefault(key, {key})
            if part in aliases:
                accepted.add(title_key(aliases[part]))
    return result


def evaluate(pred: list[Song], truth: dict[str, set[str]]) -> dict:
    accepted_all = set().union(*truth.values()) if truth else set()
    pred_keys = {k for s in pred for k in s.keys}
    matched_pred = sum(1 for s in pred if s.keys & accepted_all)
    matched_truth = sum(1 for accepted in truth.values() if accepted & pred_keys)
    precision = matched_pred / len(pred) if pred else 0.0
    recall = matched_truth / len(truth)
    f1 = 2 * precision * recall / (precision + recall) if matched_pred else 0.0
    return {"precision": precision, "recall": recall, "f1": f1, "pred_n": len(pred)}


# 후보 풀(iTunes 전체 + Last.fm 100곡)에 정답 곡이 얼마나 있는지 - 어떤 순위 조정으로도 못 넘는 recall 상한
def pool_keys(artist: ArtistData, as_of: date) -> set[str]:
    return {k for s in itunes_catalog(artist, as_of) for k in s.keys} | {title_key(n) for n, _ in artist.lastfm}


def pool_coverage(artist: ArtistData, as_of: date, truth: dict[str, set[str]]) -> float:
    keys = pool_keys(artist, as_of)
    return sum(1 for accepted in truth.values() if accepted & keys) / len(truth)


def build_cases(artists: list[ArtistData], since: date, per_artist: int) -> list[tuple[ArtistData, Show]]:
    cases = []
    for a in artists:
        usable = [s for s in a.shows if s.date >= since and len([x for x in s.songs if not x["tape"]]) >= MIN_SONGS]
        cases.extend((a, s) for s in usable[:per_artist])
    return cases


def macro(rows: list[tuple[str, dict]], metric: str) -> float:
    by_artist: dict[str, list[float]] = {}
    for name, e in rows:
        by_artist.setdefault(name, []).append(e[metric])
    return mean(mean(v) for v in by_artist.values())


# 짝지은 제목이 그 아티스트 후보 풀(iTunes 전체 + Last.fm 100곡)에 실제로 있는지 - 오타/오짝 방지
def check_alignment(alignment: dict[str, dict[str, str]]) -> None:
    artists = {a.name: a for a in load_all_artists()}
    bad = total = 0
    for name, pairs in alignment.items():
        keys = pool_keys(artists[name], date(2100, 1, 1))
        for truth_title, alias in pairs.items():
            total += 1
            if title_key(alias) not in keys:
                bad += 1
                print(f"풀에 없음: {name}: {truth_title} -> {alias}")
    print(f"짝 {total}개 중 풀에 없는 것 {bad}개")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", default="2026-03-29", help="정답 공연 시작일(Last.fm 스냅샷 누수 완화)")
    parser.add_argument("--per-artist", type=int, default=5)
    parser.add_argument("--boost", type=float, default=0.5)
    parser.add_argument("--window", type=int, default=365)
    parser.add_argument("--grid", action="store_true")
    parser.add_argument("--no-alignment", action="store_true", help="사람이 만든 곡명 짝짓기 표/메들리 분리 없이(기존 방식)")
    parser.add_argument("--check-alignment", action="store_true", help="짝의 제목이 실제 후보 풀에 있는지만 검증")
    args = parser.parse_args()
    alignment = load_alignment(not args.no_alignment)

    if args.check_alignment:
        check_alignment(load_alignment(True))
        return
    cases = build_cases(load_all_artists(), date.fromisoformat(args.since), args.per_artist)
    with_itunes = [(a, s) for a, s in cases if a.itunes is not None]
    print(f"정답 공연 {len(cases)}개 / 아티스트 {len({a.name for a, _ in cases})}명 (iTunes 있는 쪽 {len(with_itunes)}개 / {len({a.name for a, _ in with_itunes})}명)\n")

    def run(subset, predict):
        return [(a.name, evaluate(predict(a, s.date), truth_map(a, s, alignment))) for a, s in subset]

    def b1(a, d):
        return predict_b1(a, d, args.boost, args.window)

    coverage = [(a.name, {"c": pool_coverage(a, s.date, truth_map(a, s, alignment))}) for a, s in cases]
    print(f"후보 풀 커버리지(정답 곡이 iTunes/Last.fm 풀에 있는 비율, recall 상한): {macro(coverage, 'c'):.3f}\n")

    print(f"{'':<22}{'n':>4}{'precision':>11}{'recall':>9}{'f1':>8}")
    for label, subset in (("전체", cases), ("iTunes 있는 아티스트", with_itunes)):
        for pname, predict in (("B0 대표곡", predict_b0), (f"B1 신곡가중 b={args.boost}", b1)):
            rows = run(subset, predict)
            print(f"{label:<12}{pname:<14}{len(rows):>4}"
                  f"{macro(rows, 'precision'):>11.3f}{macro(rows, 'recall'):>9.3f}{macro(rows, 'f1'):>8.3f}")

    changed = sum(
        1 for a, s in with_itunes
        if [x.name for x in predict_b0(a, s.date)] != [x.name for x in b1(a, s.date)]
    )
    print(f"\nB1이 B0와 목록이 달라진 정답: {changed}/{len(with_itunes)}개")

    if args.grid:
        print("\n[격자 - 탐색용, iTunes 있는 아티스트 F1 (macro)]  행=boost, 열=window(일)")
        windows = (180, 365, 730)
        print(f"{'':<8}" + "".join(f"{w:>8}" for w in windows))
        for boost in (0.0, 0.25, 0.5, 1.0, 2.0):
            cells = []
            for w in windows:
                rows = [(a.name, evaluate(predict_b1(a, s.date, boost, w), truth_map(a, s, alignment))) for a, s in with_itunes]
                cells.append(macro(rows, "f1"))
            print(f"{boost:<8}" + "".join(f"{c:>8.3f}" for c in cells))


if __name__ == "__main__":
    main()
