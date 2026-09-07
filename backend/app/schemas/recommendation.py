from pydantic import BaseModel


class ArtistRecommendation(BaseModel):
    # 추천 아티스트 단일 항목
    artist_name: str
    score: float
    # [백엔드 수정]
    # CanonicalArtist에 정규화된 이름일 때만 채워짐(그 외엔 사진 없음).
    profile_image_url: str | None = None


class ArtistRecommendationResponse(BaseModel):
    # 아티스트 추천 목록 응답
    recommendations: list[ArtistRecommendation]
