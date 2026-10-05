# 결산 지도

## 화면 그림

`lib/models/summary_map_drawing.dart`에서 실제 지역 윤곽을 Douglas–Peucker로 단순화합니다.
화면에서 폭/높이 24px 미만 또는 면적 576px² 미만으로 표시되는 부속 도서는 생략하고 남은 도형으로 배율을 다시 계산합니다. 각 행정구역의 주된 육지는 보존하므로 제주도처럼 섬으로 이루어진 지역도 선택할 수 있습니다. 시·도/시·군·구의 원래 배치와 윤곽을 보존합니다.
경도는 해당 화면의 평균 위도에 맞춰 보정하고, 전체 화면에 하나의 확대 배율만 적용합니다.
가로·세로를 따로 늘리거나 기울이지 않으며, 원래 비율을 유지한 채 가운데에 최대 크기로 배치합니다.
데이터 출처/이용 조건은 LICENSE-DATA.txt와 Flutter 라이선스 등록에 보존합니다.

## 내부 관람 위치 판정

`korea.json`의 원본 경계는 공연장 위치 판정에, 단순화한 경계는 화면 표시에 사용합니다.
원자료: 통계청 SGIS (공공누리 제1유형).
가공: https://github.com/vuski/admdongkor (CC BY 4.0).
원본: ver20260701/HangJeongDong_ver20260701.geojson.
출처/이용 조건은 LICENSE-DATA.txt와 Flutter 라이선스 등록에 보존합니다.
재생성: Shapely가 설치된 Python으로
`python scripts/build_summary_map.py /path/to/HangJeongDong_ver20260701.geojson`.
단순화 허용 오차는 0.0005도이며 경계 부근 좌표 판정에 영향을 줄 수 있습니다.

지역별 관람 횟수는 `/summary/regions?period=6m|1y|all`을 사용합니다.
서버 변경을 함께 배포해야 하며 DB 마이그레이션은 필요하지 않습니다.
공연 후 티켓만 집계하고 관람일(없으면 공연 시작일)로 기간을 필터링합니다.
KOPIS 공연 ID → 공연시설 ID → 시설 좌표로 확인하며 이름만으로 위치를 추측하지 않습니다.
결산 보고서는 기존 `/summary` API를 그대로 사용합니다.
