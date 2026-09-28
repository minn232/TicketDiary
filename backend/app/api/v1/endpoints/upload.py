import asyncio

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from pydantic import BaseModel

from app.core.deps import get_current_user
from app.models.user import User
from app.services.storage import upload_image, ALLOWED_CONTENT_TYPES

router = APIRouter()

_MAX_IMAGE_SIZE = 10 * 1024 * 1024  # 10MB


class UploadResponse(BaseModel):
    url: str
    # 공연 사진에 썸네일을 같이 보냈을 때만 채워짐
    thumb_url: str | None = None


# 이미지 크기 및 형식 검증 후 바이트 반환
async def _read_and_validate(request: Request, image: UploadFile) -> bytes:
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > _MAX_IMAGE_SIZE:
        raise HTTPException(status_code=413, detail="이미지 크기는 10MB를 초과할 수 없습니다.")

    content_type = image.content_type or ""
    if content_type not in ALLOWED_CONTENT_TYPES:
        raise HTTPException(
            status_code=415,
            detail=f"지원하지 않는 이미지 형식입니다. ({', '.join(ALLOWED_CONTENT_TYPES)})",
        )

    image_bytes = await image.read(_MAX_IMAGE_SIZE + 1)
    if len(image_bytes) > _MAX_IMAGE_SIZE:
        raise HTTPException(status_code=413, detail="이미지 크기는 10MB를 초과할 수 없습니다.")

    return image_bytes


# 티켓 이미지 업로드 (ticket-images/{uuid}.ext -> S3)
@router.post("/ticket-image", response_model=UploadResponse)
async def upload_ticket_image(
    request: Request,
    image: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
):
    image_bytes = await _read_and_validate(request, image)
    url = await upload_image(image_bytes, "ticket-images", image.content_type or "image/jpeg")
    return UploadResponse(url=url)


# 공연 사진 업로드 (concert-photos/{uuid}.ext -> S3). 썸네일은 서버가 디코딩하지 않도록
# 기기에서 만들어 같이 보냄(선택) - concert-photo-thumbs/에 저장
@router.post("/concert-photo", response_model=UploadResponse)
async def upload_concert_photo(
    request: Request,
    image: UploadFile = File(...),
    thumbnail: UploadFile | None = File(None),
    current_user: User = Depends(get_current_user),
):
    image_bytes = await _read_and_validate(request, image)
    if thumbnail is None:
        url = await upload_image(image_bytes, "concert-photos", image.content_type or "image/jpeg")
        return UploadResponse(url=url)

    thumb_bytes = await _read_and_validate(request, thumbnail)
    url, thumb_url = await asyncio.gather(
        upload_image(image_bytes, "concert-photos", image.content_type or "image/jpeg"),
        upload_image(thumb_bytes, "concert-photo-thumbs", thumbnail.content_type or "image/jpeg"),
    )
    return UploadResponse(url=url, thumb_url=thumb_url)
