import math
import re
from dataclasses import dataclass
from datetime import date, datetime
from statistics import median

# 예상 셋리 확률 모델 - DB/HTTP 없는 순수 함수만 둠(백테스트 scripts/backtest와 운영이 같은 함수를 씀)


# 모델이 보는 과거 공연 하나 - 인트로 테이프 등은 호출부가 미리 빼고 곡명만 셋리 순서대로 넘김
@dataclass
class ModelShow:
    date: date
    tour: str | None
    songs: list[str]


# 모델 파라미터 - 초기값은 설계 기준이고 백테스트로 조정
@dataclass
class ModelParams:
    half_life: float = 5.0  # 최근성 반감기(공연 수 단위)
    tour_boost: float = 3.0  # 가장 최근 공연과 같은 투어
    form_mismatch: float = 0.4  # 공연 형태(short/full)가 대상과 다른 공연
    alpha: float = 2.0  # 베이즈 스무딩 강도(가상 공연 수)
    p0: float = 0.3  # 정보 없을 때 한 곡이 나올 기본 확률
    min_prob: float = 0.15
    min_songs: int = 5
    max_songs: int = 35
    fixed_songs: int = 20  # 곡 수 추정을 안 쓸 때
    short_ratio: float = 0.6  # 곡 수가 중앙값의 이 비율 미만이면 short
    min_show_songs: int = 3  # 이보다 짧은 셋리는 불량으로 보고 제외
    order_lambda: float = 2.0
    beam_width: int = 10
    transition_eps: float = 0.1


# Setlist.fm search/setlists 응답의 셋리 목록을 모델 입력(최신순)으로 - 인트로 테이프는 곡에서 뺌,
# eventDate(dd-MM-yyyy)를 못 읽는 항목은 최근성 순서를 알 수 없어 버림
def shows_from_setlistfm(raw_setlists: list[dict]) -> list[ModelShow]:
    shows = []
    for raw in raw_setlists:
        try:
            show_date = datetime.strptime(raw["eventDate"], "%d-%m-%Y").date()
        except (KeyError, ValueError, TypeError):
            continue
        songs = [
            name
            for s in raw.get("sets", {}).get("set", [])
            for song in s.get("song", [])
            if not song.get("tape") and (name := (song.get("name") or "").strip())
        ]
        shows.append(ModelShow(date=show_date, tour=(raw.get("tour") or {}).get("name") or None, songs=songs))
    shows.sort(key=lambda s: s.date, reverse=True)
    return shows


# 곡 확률 -> 화면 표시용 신뢰도 구간
def confidence_label(probability: float) -> str:
    if probability >= 0.9:
        return "high"
    return "likely" if probability >= 0.6 else "possible"


_PAREN_RE = re.compile(r"[\(\[（][^)\]）]*[\)\]）]")


# 같은 곡의 표기 차이(대소문자/공백/기호/괄호 부가표기)를 묶는 키 - 한글/일본어 제목은 유지
def normalize_title(name: str) -> str:
    stripped = _PAREN_RE.sub("", name)
    return re.sub(r"\W", "", (stripped or name).casefold())


# 곡 수가 그 아티스트 공연 곡 수 중앙값의 short_ratio 미만이면 짧은 공연(페스티벌/게스트 무대 등)
def classify_shows(shows: list[ModelShow], params: ModelParams) -> list[str]:
    if not shows:
        return []
    cutoff = median(len(s.songs) for s in shows) * params.short_ratio
    return ["short" if len(s.songs) < cutoff else "full" for s in shows]


def classify_length(length: int, shows: list[ModelShow], params: ModelParams) -> str:
    if not shows:
        return "full"
    return "short" if length < median(len(s.songs) for s in shows) * params.short_ratio else "full"


# 공연별 가중치 - 최근성(index 0이 가장 최근) x 같은 투어 x 공연 형태 일치
def show_weights(
    shows: list[ModelShow], forms: list[str], target_form: str, params: ModelParams, *, tour: bool, form: bool
) -> list[float]:
    latest_tour = shows[0].tour if shows else None
    weights = []
    for i, show in enumerate(shows):
        w = 0.5 ** (i / params.half_life)
        if tour and latest_tour and show.tour == latest_tour:
            w *= params.tour_boost
        if form and forms[i] != target_form:
            w *= params.form_mismatch
        weights.append(w)
    return weights


def weighted_median(values: list[float], weights: list[float]) -> float:
    pairs = sorted(zip(values, weights))
    half = sum(weights) / 2
    acc = 0.0
    for value, weight in pairs:
        acc += weight
        if acc >= half:
            return value
    return pairs[-1][0]


# 곡 확률 P = (등장한 공연 가중치 합 + alpha*p0) / (전체 가중치 합 + alpha). alpha=0이면 순수 가중 빈도
def song_probabilities(
    shows: list[ModelShow], weights: list[float], params: ModelParams, *, smoothing: bool
) -> tuple[dict[str, float], dict[str, str]]:
    total = sum(weights)
    alpha = params.alpha if smoothing else 0.0
    present: dict[str, float] = {}
    display: dict[str, str] = {}
    for show, w in zip(shows, weights):
        for key in dict.fromkeys(normalize_title(name) for name in show.songs):
            present[key] = present.get(key, 0.0) + w
        for name in show.songs:
            display.setdefault(normalize_title(name), name)
    denominator = total + alpha
    return {k: (v + alpha * params.p0) / denominator for k, v in present.items()}, display


# 곡별 가중 평균 상대 위치(0=오프닝, 1=마지막)
def song_positions(shows: list[ModelShow], weights: list[float]) -> dict[str, float]:
    sums: dict[str, float] = {}
    totals: dict[str, float] = {}
    for show, w in zip(shows, weights):
        n = len(show.songs)
        seen: set[str] = set()
        for idx, name in enumerate(show.songs):
            key = normalize_title(name)
            if key in seen:
                continue
            seen.add(key)
            sums[key] = sums.get(key, 0.0) + w * (idx / (n - 1) if n > 1 else 0.5)
            totals[key] = totals.get(key, 0.0) + w
    return {k: sums[k] / totals[k] for k in sums}


# 연속한 두 곡 X->Y의 가중 횟수. "" 키가 셋리 시작
def transition_counts(shows: list[ModelShow], weights: list[float]) -> dict[str, dict[str, float]]:
    counts: dict[str, dict[str, float]] = {}
    for show, w in zip(shows, weights):
        prev = ""
        seen: set[str] = set()
        for name in show.songs:
            key = normalize_title(name)
            if key in seen:
                continue
            seen.add(key)
            counts.setdefault(prev, {})
            counts[prev][key] = counts[prev].get(key, 0.0) + w
            prev = key
    return counts


# 선택된 곡들을 빔서치로 배열 - 점수 = sum log P(다음|이전) - lambda * sum |슬롯 상대위치 - 곡 평균위치|
def order_songs(
    keys: list[str],
    positions: dict[str, float],
    transitions: dict[str, dict[str, float]],
    params: ModelParams,
) -> list[str]:
    n = len(keys)
    if n <= 1:
        return list(keys)
    eps = params.transition_eps

    def log_p(prev: str, nxt: str) -> float:
        row = transitions.get(prev, {})
        denominator = sum(row.get(k, 0.0) for k in keys) + eps * n
        return math.log((row.get(nxt, 0.0) + eps) / denominator)

    beams: list[tuple[float, list[str]]] = [(0.0, [])]
    for slot in range(n):
        slot_pos = slot / (n - 1)
        candidates = []
        for score, seq in beams:
            used = set(seq)
            prev = seq[-1] if seq else ""
            for key in keys:
                if key in used:
                    continue
                gain = log_p(prev, key) - params.order_lambda * abs(slot_pos - positions.get(key, 0.5))
                candidates.append((score + gain, [*seq, key]))
        candidates.sort(key=lambda c: -c[0])
        beams = candidates[: params.beam_width]
    return beams[0][1]


# 과거 공연(최신순)으로 예상 셋리를 만듦 -> [{"name", "probability"}] (순서 = 예상 공연 순서, order=False면 확률순).
# 기능 플래그는 백테스트에서 단계별 기여를 따로 보려는 용도
def predict_setlist(
    history: list[ModelShow],
    target_form: str = "full",
    params: ModelParams | None = None,
    *,
    tour: bool = True,
    form: bool = True,
    smoothing: bool = True,
    estimate_length: bool = True,
    order: bool = True,
) -> list[dict]:
    params = params or ModelParams()
    shows = [s for s in history if len(s.songs) >= params.min_show_songs]
    if not shows:
        return []

    forms = classify_shows(shows, params)
    weights = show_weights(shows, forms, target_form, params, tour=tour, form=form)
    probs, display = song_probabilities(shows, weights, params, smoothing=smoothing)
    ranked = sorted(probs, key=lambda k: -probs[k])

    if estimate_length:
        same_form = [(len(s.songs), w) for s, f, w in zip(shows, forms, weights) if f == target_form]
        pool = same_form if len(same_form) >= 2 else [(len(s.songs), w) for s, w in zip(shows, weights)]
        n = round(weighted_median([float(v) for v, _ in pool], [w for _, w in pool]))
        n = max(params.min_songs, min(params.max_songs, n))
        picked = [k for k in ranked[:n] if probs[k] >= params.min_prob]
        if len(picked) < params.min_songs:
            picked = ranked[: params.min_songs]
    else:
        picked = ranked[: params.fixed_songs]

    if order:
        picked = order_songs(picked, song_positions(shows, weights), transition_counts(shows, weights), params)
    return [{"name": display[k], "probability": probs[k]} for k in picked]
