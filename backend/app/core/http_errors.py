import httpx


# 422(pydantic 검증 실패) 본문은 항목마다 input(보낸 값 그대로)을 담고 있어서, 블로그 초안 요청이면
# 감상 메모 원문 조각이 로그에 남음 - 원인 파악에 필요한 위치(loc)와 사유(msg)만 남김
def _summarize_validation_detail(response: httpx.Response) -> str | None:
    try:
        detail = response.json().get("detail")
    except Exception:
        return None
    if not isinstance(detail, list):
        return None
    parts = []
    for item in detail:
        if isinstance(item, dict):
            loc = ".".join(str(p) for p in item.get("loc", []))
            parts.append(f"{loc}: {item.get('msg', '')}")
    return "; ".join(parts) if parts else None


# raise_for_status() 예외 메시지엔 상태 코드뿐이라 원인(RunPod의 GPU 부족, llm_server의 422 사유 등)이
# 안 보임 - 응답 본문 앞부분을 같이 남겨 로그만으로 원인을 볼 수 있게 함
def describe_http_error(error: Exception, max_body: int = 300) -> str:
    if isinstance(error, httpx.HTTPStatusError):
        summary = _summarize_validation_detail(error.response)
        if summary is None and error.response.status_code == 422:
            # 검증 실패 본문은 모양과 무관하게 보낸 값을 되돌려줄 수 있어 요약이 안 되면 본문을 남기지 않음
            return "422 (검증 실패, 본문 생략)"
        body = summary if summary is not None else error.response.text
        body = body.strip().replace("\n", " ")[:max_body]
        return f"{error.response.status_code} {body}"
    return f"{type(error).__name__}: {error}"
