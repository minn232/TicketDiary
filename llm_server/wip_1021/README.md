# 병합 전 배치 결과 저장 + replay_merge.py (2026-10-21, 적용 보류)

server/에는 원래 파일이 복원돼 있고, 이 폴더에 수정본만 따로 둔다.

| 파일 | 내용 |
|---|---|
| `extract_poster.py` | 수정본 전체. `extract_poster_batches` / `extract_timetable_batches` / `merge_batches` / `batches_payload` 추가, `--out-dir`이면 `<이름>.batches.json`도 저장 |
| `extract_poster.patch` | 원본 대비 diff |
| `test_crawl_extract.py` | 수정본 전체. `<concert_id>.batches.json`도 저장 |
| `test_crawl_extract.patch` | 원본 대비 diff |
| `replay_merge.py` | 새 파일. 저장된 `.batches.json`으로 병합만 다시 돌리고 정답(`.golden.json`)과 채점 |

`extract_poster_info` / `extract_timetable_info`의 인자와 반환값은 바뀌지 않는다(검증: `/workspace/verify_20261021/검증결과.md`).
CLI에서 달라지는 것은 `--out-dir`을 줄 때 `.batches.json` 파일이 하나 더 생기는 것뿐이다.

## 다시 적용하기

`replay_merge.py`와 수정본 `test_crawl_extract.py`는 수정본 `extract_poster.py`의 새 함수를 import하므로 세 파일을 함께 적용한다.

```bash
cd /workspace/server
patch -p0 extract_poster.py < ../wip_batches_replay_20261021/extract_poster.patch
patch -p0 test_crawl_extract.py < ../wip_batches_replay_20261021/test_crawl_extract.patch
cp ../wip_batches_replay_20261021/replay_merge.py .
```

패치는 2026-10-21 시점 원본(PIPELINE_VERSION 2026-09-28-2) 기준이다. 그 사이 원본이 바뀌었으면 patch가 일부 실패할 수 있다.
