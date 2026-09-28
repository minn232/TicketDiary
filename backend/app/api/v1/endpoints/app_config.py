import json
import logging
from pathlib import Path

from fastapi import APIRouter

router = APIRouter()
logger = logging.getLogger(__name__)

_LAYOUT_WEIGHTS_PATH = Path(__file__).resolve().parents[3] / "core" / "layout_weights.json"


# 공연후 페이지 자동 배치 가중치 (프론트 LayoutWeights.fromJson) - 앱 재배포 없이 서버 배포만으로
# 튜닝하기 위함. 준 키만 덮어쓰고 나머지는 앱 기본값이라 빈 객체면 기본값 그대로. 게스트도 쓰므로 인증 없음
@router.get("/layout-weights")
async def get_layout_weights() -> dict:
    try:
        weights = json.loads(_LAYOUT_WEIGHTS_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        logger.warning(f"layout_weights.json 읽기 실패, 앱 기본값 사용: {e}")
        return {}
    return weights if isinstance(weights, dict) else {}
