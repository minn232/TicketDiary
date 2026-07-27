from pydantic import BaseModel


class ArtistExtractionResult(BaseModel):
    # VLM팀이 공연명+포스터로 추출한 아티스트 결과 (알아낸 게 없으면 빈 배열)
    artist_name: list[str]


class ArtistExtractionResponse(BaseModel):
    # 정규화까지 반영된 최종 저장값
    artist_name: list[str]
