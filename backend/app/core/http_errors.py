import httpx


# raise_for_status() 예외 메시지엔 상태 코드뿐이라 원인(RunPod의 GPU 부족, llm_server의 422 사유 등)이
# 안 보임 - 응답 본문 앞부분을 같이 남겨 로그만으로 원인을 볼 수 있게 함
def describe_http_error(error: Exception, max_body: int = 300) -> str:
    if isinstance(error, httpx.HTTPStatusError):
        body = error.response.text.strip().replace("\n", " ")[:max_body]
        return f"{error.response.status_code} {body}"
    return f"{type(error).__name__}: {error}"
