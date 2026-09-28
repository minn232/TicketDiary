from unittest.mock import patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app


# 배치 가중치 파일 내용을 인증 없이 그대로 내려주는지 테스트 (게스트도 사용)
@pytest.mark.asyncio
async def test_layout_weights_returns_file_content(tmp_path):
    path = tmp_path / "layout_weights.json"
    path.write_text('{"maxOverlap": 0.15, "iterations": 1200}', encoding="utf-8")

    with patch("app.api.v1.endpoints.app_config._LAYOUT_WEIGHTS_PATH", path):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get("/api/v1/app-config/layout-weights")

    assert response.status_code == 200
    assert response.json() == {"maxOverlap": 0.15, "iterations": 1200}


# 파일이 없거나 깨졌거나 객체가 아니어도 500 대신 빈 객체 -> 앱은 기본값으로 동작
@pytest.mark.asyncio
@pytest.mark.parametrize("content", [None, "{broken", "[1, 2]"])
async def test_layout_weights_falls_back_to_empty(tmp_path, content):
    path = tmp_path / "layout_weights.json"
    if content is not None:
        path.write_text(content, encoding="utf-8")

    with patch("app.api.v1.endpoints.app_config._LAYOUT_WEIGHTS_PATH", path):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get("/api/v1/app-config/layout-weights")

    assert response.status_code == 200
    assert response.json() == {}
