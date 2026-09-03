from pydantic import BaseModel


class LineupEntry(BaseModel):
    # 아티스트 1명의 실제 출연일. LLM팀 크롤링(/crawl-result)·포스터 추출(/artist-result)
    # 웹훅에서 lineup[].artist+performance_date가 둘 다 채워진 항목만 이 형태로 옴(날짜를
    # 모르는 항목은 llm_server/normalize.py가 애초에 걸러냄 - app/services/lineup.py 참고)
    artist: str
    performance_date: str  # YYYY-MM-DD
