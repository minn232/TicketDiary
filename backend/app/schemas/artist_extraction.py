from typing import Literal

from pydantic import BaseModel

from app.schemas.lineup import LineupEntry


class ArtistExtractionResult(BaseModel):
    # VLM팀이 공연명+포스터로 추출한 아티스트 결과 (알아낸 게 없으면 빈 배열)
    artist_name: list[str]
    # VLM이 포스터를 보고 판단한 단독/페스티벌 분류 (자신 없으면 UNKNOWN, 생략 가능).
    # 인원수 임계치(ticket.py upgrade_event_type_if_multi_artist)를 보완하는 힌트일 뿐이라
    # 그대로 신뢰하지 않고 artist_name 결과와 교차검증해서 반영함 - app/services/ticket.py 참고
    event_type: Literal["SOLO", "FESTIVAL", "UNKNOWN"] | None = None
    # 아티스트별 실제 출연일(날짜를 아는 항목만 옴) - concert_lineups에 upsert됨
    # (app/services/lineup.py). 포스터 추출 쪽 출처라 크롤링 결과가 이미 있으면 밀리지 않음
    lineup: list[LineupEntry] | None = None


class ArtistExtractionResponse(BaseModel):
    # 정규화까지 반영된 최종 저장값
    artist_name: list[str]
