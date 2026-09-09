from pydantic import BaseModel


class ArtistSearchResult(BaseModel):
    # 검색 결과 아티스트 1명
    name: str
    profile_image_url: str | None = None


class ArtistSearchResponse(BaseModel):
    # 아티스트 검색 결과 목록 응답
    results: list[ArtistSearchResult]
