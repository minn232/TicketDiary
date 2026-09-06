from pydantic import BaseModel


class ArtistSearchResult(BaseModel):
    # 검색 결과 아티스트 1명
    name: str
    profile_image_url: str | None = None


class ArtistSearchResponse(BaseModel):
    results: list[ArtistSearchResult]
