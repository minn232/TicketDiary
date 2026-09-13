from pydantic import BaseModel


class MusicLinkResolveResponse(BaseModel):
    # 못 찾으면(비공식/미발매곡, API 키 미설정 등) null - 프론트가 검색화면으로 폴백.
    url: str | None = None
