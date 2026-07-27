from pydantic import BaseModel


class ArtistRecommendation(BaseModel):
    # 추천 아티스트 단일 항목
    artist_name: str
    score: float


class ArtistRecommendationResponse(BaseModel):
    # 아티스트 추천 목록 응답
    recommendations: list[ArtistRecommendation]
