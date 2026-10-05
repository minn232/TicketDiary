"""
OCR 텍스트 확인용 스크립트 (LLM 전송 전 단계)

사용법:
    python scripts/ocr_test.py                     # scripts/Image 폴더 전체 처리
    python scripts/ocr_test.py <이미지 경로>        # 파일 하나만 처리

결과 파일: scripts/Image/ocr_results.txt
"""

import asyncio
import base64
import sys
from datetime import datetime
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.core.config import settings  # noqa: E402
from app.services.ocr import _detect_format, _to_jpeg  # noqa: E402

_IMAGE_DIR = Path(__file__).resolve().parent / "Image"
_RESULT_FILE = _IMAGE_DIR / "ocr_results.txt"
_SUPPORTED_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".dng", ".tiff", ".tif", ".webp", ".bmp"}


async def process_file(path: Path) -> dict:
    image_bytes = path.read_bytes()
    content_type = f"image/{path.suffix.lstrip('.').lower()}"
    fmt = _detect_format(image_bytes, content_type)
    jpeg_bytes = _to_jpeg(image_bytes, content_type)

    payload = {
        "requests": [{
            "image": {"content": base64.b64encode(jpeg_bytes).decode()},
            "features": [{"type": "DOCUMENT_TEXT_DETECTION"}],
        }]
    }
    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.post(
            "https://vision.googleapis.com/v1/images:annotate",
            params={"key": settings.GOOGLE_VISION_API_KEY},
            json=payload,
        )

    if resp.status_code != 200:
        return {"file": path.name, "fmt": fmt, "status": "error", "text": resp.text}

    text = resp.json().get("responses", [{}])[0].get("fullTextAnnotation", {}).get("text", "")
    if not text:
        return {"file": path.name, "fmt": fmt, "status": "empty", "text": ""}

    return {"file": path.name, "fmt": fmt, "status": "ok", "text": text}


def write_results(results: list[dict]) -> None:
    lines = []
    lines.append(f"OCR 결과 — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"총 {len(results)}개 파일 처리")
    lines.append("=" * 60)

    for r in results:
        lines.append(f"\n파일: {r['file']}  [{r['fmt'].upper()}]")
        if r["status"] == "ok":
            lines.append(r["text"])
        elif r["status"] == "empty":
            lines.append("(텍스트를 인식하지 못했습니다)")
        else:
            lines.append(f"(API 오류)\n{r['text']}")
        lines.append("─" * 60)

    _RESULT_FILE.write_text("\n".join(lines), encoding="utf-8")
    print(f"결과 저장: {_RESULT_FILE}")


async def main() -> None:
    if len(sys.argv) == 2:
        targets = [Path(sys.argv[1]).expanduser().resolve()]
        if not targets[0].exists():
            print(f"[오류] 파일을 찾을 수 없습니다: {targets[0]}")
            sys.exit(1)
    else:
        if not _IMAGE_DIR.exists():
            print(f"[오류] Image 폴더가 없습니다: {_IMAGE_DIR}")
            sys.exit(1)
        targets = sorted(
            p for p in _IMAGE_DIR.iterdir()
            if p.is_file() and p.suffix.lower() in _SUPPORTED_EXTS
        )
        if not targets:
            print(f"[오류] {_IMAGE_DIR} 에 처리할 이미지가 없습니다.")
            sys.exit(1)

    print(f"{len(targets)}개 파일 처리 중...")
    results = []
    for i, path in enumerate(targets, 1):
        print(f"  ({i}/{len(targets)}) {path.name}", end="  ", flush=True)
        result = await process_file(path)
        status_label = {"ok": "완료", "empty": "텍스트 없음", "error": "오류"}[result["status"]]
        print(status_label)
        results.append(result)

    write_results(results)


if __name__ == "__main__":
    asyncio.run(main())
