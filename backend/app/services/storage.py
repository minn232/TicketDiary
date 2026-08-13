import asyncio
import logging
import re
import uuid

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import HTTPException

from app.core.config import settings

logger = logging.getLogger(__name__)

# 허용 이미지 형식 및 확장자 매핑
ALLOWED_CONTENT_TYPES = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/heic": ".heic",
    "image/heif": ".heif",
}

_s3_client = None


# S3 클라이언트 반환 (첫 호출 시 초기화)
def _get_s3_client():
    global _s3_client
    if _s3_client is None:
        # 액세스 키가 설정된 경우에만 명시적으로 전달하고, 없으면 boto3 기본 자격증명
        # 체인(EC2 인스턴스에 연결된 IAM 역할 등)을 사용하도록 둔다.
        kwargs = {"region_name": settings.AWS_REGION}
        if settings.AWS_ACCESS_KEY_ID and settings.AWS_SECRET_ACCESS_KEY:
            kwargs["aws_access_key_id"] = settings.AWS_ACCESS_KEY_ID
            kwargs["aws_secret_access_key"] = settings.AWS_SECRET_ACCESS_KEY
        _s3_client = boto3.client("s3", **kwargs)
    return _s3_client


# S3 업로드 실행 후 URL 반환 (동기, run_in_executor 전용)
def _do_upload(image_bytes: bytes, key: str, content_type: str) -> str:
    try:
        _get_s3_client().put_object(
            Bucket=settings.S3_BUCKET_NAME,
            Key=key,
            Body=image_bytes,
            ContentType=content_type,
        )
        return f"https://{settings.S3_BUCKET_NAME}.s3.{settings.AWS_REGION}.amazonaws.com/{key}"
    except (BotoCoreError, ClientError) as e:
        logger.error(f"S3 업로드 실패: {e}")
        raise HTTPException(status_code=502, detail="이미지 업로드에 실패했습니다.")


# 이미지 S3 업로드 후 URL 반환
async def upload_image(image_bytes: bytes, folder: str, content_type: str) -> str:
    ext = ALLOWED_CONTENT_TYPES.get(content_type, ".jpg")
    key = f"{folder}/{uuid.uuid4()}{ext}"
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, _do_upload, image_bytes, key, content_type)


_S3_URL_RE = re.compile(
    rf"^https://{re.escape(settings.S3_BUCKET_NAME)}\.s3\.[^/]+\.amazonaws\.com/(?P<key>.+)$"
)


# _do_upload가 만든 URL에서 S3 key만 추출(이 버킷 URL이 아니면 None)
def _key_from_url(url: str) -> str | None:
    m = _S3_URL_RE.match(url)
    return m.group("key") if m else None


def _do_delete(key: str) -> None:
    try:
        _get_s3_client().delete_object(Bucket=settings.S3_BUCKET_NAME, Key=key)
    except (BotoCoreError, ClientError) as e:
        logger.warning(f"S3 객체 삭제 실패(무시하고 계속 진행): {key} - {e}")


# 유저가 사진을 지우거나(콘서트 사진 교체 포함) 티켓을 통째로 삭제할 때,
# S3도 같이 삭제. 실패해도 예외를 던지지 않고 로그만
# 남김(호출부의 주 작업인 DB 갱신을 막지 않기 위함).
async def delete_image(url: str) -> None:
    key = _key_from_url(url)
    if key is None:
        return
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, _do_delete, key)
