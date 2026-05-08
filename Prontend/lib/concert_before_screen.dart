import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 기본 StatelessWidget을 상속받음.
/// UI를 일단 고정시킬거기 때문에 사용.
/// 공연 전 상세 정보 페이지를 표시하는 화면.
class ConcertBeforeScreen extends StatelessWidget { /// 공연 전 class
  final String concertTitle; /// 공연의 제목을 저장하는 변수. final로 변경 불가능을 명시

  /// 생성자에서 공연 제목을 받아옴.
  const ConcertBeforeScreen({
    super.key,  /// flutter에서 위젯을 식별하기 위한 key
    required this.concertTitle, /// 공연 제목은 필수적으로 받기 위해 required 사용
  });

  /*
  *     공연 정보의 다이어리 페이지, 인덱스 탭, 왼쪽 바인더 링의 배치
  *     공연 정보 상세 페이지를 구성하는 부분.
   */

  @override
  Widget build(BuildContext context) {  /// 공연 전 화면의 UI를 구성하는 함수
    return Scaffold( /// 빈 도화지
      backgroundColor: const Color(0xFF5C4033), /// 다이어리 가죽 색상
      body: SafeArea(
        child: Stack( /// 레이어를 겹쳐서 배치할 수 있게 해줌
          children: [
            /// 공연 정보 페이지 레이어 (겹쳐서 깊이감 표현)
            _buildPageLayer(right: 35, bottom: 20),
            _buildPageLayer(right: 38, bottom: 20),
            _buildPageLayer(right: 41, bottom: 20),
            _buildPageLayer(right: 44, bottom: 20),

            /// 우측 인덱스 탭 레이어 (뒤로 가기 용도)
            Positioned( /// 특정 위치에 고정해서 배치할 수 있게 해줌
              right: 4,
              top: 80,
              child: GestureDetector( /// 탭 제스처 감지
                onTap: () => Navigator.pop(context), /// 탭하면 이전 화면으로 돌아감
                child: _buildIndexTab(const Color(0xFFE8AE75), "◀"), /// 뒤로 가기 버튼
              ),
            ),

            /// 공연 정보 페이지 레이어 (실제 공연 정보가 들어가는 페이지)
            Positioned(
              /// 메인 페이지 레이어 설정
              top: 10,
              bottom: 10,
              left: 30, /// 왼쪽 바인더 링을 위한 여백
              right: 45, /// 오른쪽 인덱스 탭을 위한 여백

              /// 설정을 마쳤으니 페이지 레이어 구성
              child: Container( /// 페이지 네모 상자 만들기
                decoration: BoxDecoration( /// 페이지 디자인 도구 열기
                  color: const Color(0xFFF4F1E1), /// 빈티지 종이 색상
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(15), /// 페이지 오른쪽만 둥글게 처리
                  ),
                  boxShadow: [ /// 그림자 효과
                    BoxShadow( /// 페이지 가장자리 그림자 설정
                      color: Colors.black.withValues(alpha: 0.3), /// 그림자 투명도 30%
                      blurRadius: 10, /// 그림자 흐림 정도
                      offset: const Offset(5, 5), /// 그림자 위치 (오른쪽 아래로 5픽셀 이동)
                    ),
                  ],
                ),

                /// 페이지 레이어 안에 공연 정보가 들어가는 부분
                child: Padding( /// 페이지 안쪽 여백 설정
                  /// 왼쪽은 바인더 링(구멍) 영역과 겹치지 않도록 여백을 더 줌
                  padding: const EdgeInsets.fromLTRB(32, 15, 15, 15),
                  child: Column( /// 페이지 안 위젯들을 세로로 배치
                    children: [ /// 공연 정보들을 배치
                      /// 1. 2x2 그리드 레이아웃 (공연 정보/타임테이블/예상 셋 리스트/D-day)
                      Expanded( /// 남은 공간을 모두 차지
                        child: Row( /// 좌우로 배치
                          children: [ /// 왼쪽과 오른쪽 열
                            /// 왼쪽 열 (공연 정보, D-day)
                            Expanded(
                              child: Column(
                                children: [
                                  /// (좌상) 공연 정보
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 7.5),
                                      child: _buildInfoCard(
                                        title: "공연 정보",
                                        noteColor: const Color(0xFFFFD6E8), /// 포스트잇 핑크
                                        angle: 0.012,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                          children: [
                                            _buildInfoRow("공연명", concertTitle),
                                            _buildInfoRow("공연장", "콘서트홀"),
                                            _buildInfoRow("공연일", "2024.06.15"),
                                            _buildInfoRow("예매처", "예매 링크"),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 15),

                                  /// (좌하) D-day - 다른 포스트잇보다 작고 귀여운 버전 (약 30도 회전)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 7.5),
                                      /// 좌하단 영역의 "중앙"에 오도록 배치
                                      child: Center(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: _buildCuteDDayNote(
                                            title: "D-day",
                                            ddayText: "D-12",
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            /// 오른쪽 열 (타임테이블, 예상 셋 리스트)
                            Expanded(
                              child: Column(
                                children: [
                                  /// (우상) 타임테이블
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 7.5),
                                      child: _buildInfoCard(
                                        title: "타임테이블",
                                        noteColor: const Color(0xFFCFF5E7), /// 포스트잇 민트
                                        angle: -0.012,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                          children: const [
                                            _TimeRow(time: "16:00", label: "입장"),
                                            _TimeRow(time: "17:00", label: "오프닝"),
                                            _TimeRow(time: "18:30", label: "메인"),
                                            _TimeRow(time: "20:30", label: "종료"),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 15),

                                  /// (우하) 예상 셋 리스트
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 7.5),
                                      child: _buildInfoCard(
                                        title: "예상 셋 리스트",
                                        noteColor: const Color(0xFFD9E8FF), /// 포스트잇 블루
                                        angle: 0.01,
                                        /// 내용이 짧더라도 다른 포스트잇과 동일한 크기를 유지하도록 Expanded 영역을 그대로 사용
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                          children: const [
                                            Text("01. Intro", style: TextStyle(fontSize: 12, color: Colors.black87)),
                                            Text("02. Title Song", style: TextStyle(fontSize: 12, color: Colors.black87)),
                                            Text("03. Fan Favorite", style: TextStyle(fontSize: 12, color: Colors.black87)),
                                            Text("04. Encore", style: TextStyle(fontSize: 12, color: Colors.black87)),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),


                    ],
                  ),
                ),
              ),
            ),

            /// 다이어리 느낌 나도록 왼쪽 바인더 링 레이어
            Positioned( /// 위젯 위치 고정
              left: 15,
              top: 50,
              bottom: 50,
              child: Column( /// 세로로 배치
                mainAxisAlignment: MainAxisAlignment.spaceEvenly, /// 바인더 링 사이 간격을 자동으로 균등하게 배치
                children: List.generate(6, (index) => _buildBinderRing()), /// 6개의 바인더 링을 일일이 생성하지 않고 반복문으로 생성
              ),
            ),
          ],
        ),
      ),
    );
  }

  /*
   *   UI 빌더 위젯들
   *   위젯들의 constructor들을 모아 놓음
   *   각 위젯은 공연 정보 페이지 안에서 정보를 표현하기 위한 위젯들로 구성되어 있음
   *
   *   no.1 _buildPageLayer: 공연 정보 페이지의 겹치는 레이어를 만들어 깊이감을 표현
   *   no.2 _buildInfoCard: 공연 정보를 카드 형태로 표현해주는 래퍼 위젯
   *   no.3 _buildInfoRow: 정보의 라벨과 값을 한 줄로 표현해주는 위젯
   *   no.4 _buildBinderRing: 다이어리 왼쪽 바인더 링 UI를 만들어주는 위젯
   *   no.5 _buildIndexTab: 우측 인덱스 탭 UI를 만들어주는 위젯
  */

  /// no.1 공연 정보 페이지의 겹치는 레이어를 만들어 깊이감을 표현하는 위젯
  Widget _buildPageLayer({required double right, required double bottom}) { /// 페이지 레이어의 오른쪽, 아래쪽 여백을 받아옴
    return Positioned( /// 위치 고정
      top: 10,
      bottom: bottom,
      left: 30,
      right: right,
      child: Container( /// 페이지 네모 상자 만들기
        decoration: BoxDecoration( /// 디자인 도구 열기
          color: const Color(0xFFF4F1E1), /// 종이 색상
          borderRadius: const BorderRadius.horizontal( /// 페이지 오른쪽만 둥글게 처리
            right: Radius.circular(15), /// 둥근 정도
          ),
          boxShadow: [ /// 그림자 효과 추가
            BoxShadow( /// 그림자 효과 함수
              color: Colors.black.withValues(alpha: 0.2), /// 그림자 투명도
              blurRadius: 8, /// 그림자 흐림 정도
              offset: const Offset(4, 4), /// 그림자 위치 (오른쪽 아래)
            ),
          ],
        ),
      ),
    );
  }

  /// no.2 공연 정보를 카드 형태로 표현해주는 래퍼 위젯
  Widget _buildInfoCard({
    required String title, /// 카드 제목을 받아옴
    required Widget child, /// 카드 안에 들어갈 위젯을 받아옴
    Color noteColor = const Color(0xFFFFF6A6), /// 포스트잇 기본 색상
    double angle = 0.0, /// 포스트잇이 자연스럽게 보이도록 살짝 기울이는 각도(라디안)
  }) {
    /// 포스트잇 느낌을 위해 살짝 회전 + 접힌 모서리 + 테이프(상단) 효과 적용
    return Transform.rotate(
      angle: angle,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              color: noteColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Colors.black.withValues(alpha: 0.12),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 10,
                  offset: const Offset(3, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(child: child),
                ],
              ),
            ),
          ),

          /// 상단 테이프 느낌
          Positioned(
            top: -8,
            left: 20,
            right: 20,
            child: Container(
              height: 16,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.06),
                  width: 1,
                ),
              ),
            ),
          ),

          /// 접힌 모서리 (오른쪽 위)
          Positioned(
            top: 0,
            right: 0,
            child: ClipPath(
              clipper: _PostItCornerClipper(),
              child: Container(
                width: 26,
                height: 26,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// no.2-1 D-day 전용 "작고 귀여운" 포스트잇
  /// - 다른 포스트잇보다 작게
  /// - 약 30도 회전
  /// - 둥글둥글한 모서리와 더 부드러운 그림자
  Widget _buildCuteDDayNote({required String title, required String ddayText}) {
    return Transform.rotate(
      angle: math.pi / 6, /// 약 30도
      child: SizedBox(
        width: 140,
        height: 90,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFFFF6A6),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.12),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.14),
                    blurRadius: 12,
                    offset: const Offset(3, 6),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.favorite, size: 14, color: Colors.pinkAccent),
                      ],
                    ),
                    const Spacer(),
                    Center(
                      child: Text(
                        ddayText,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Colors.black87,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ),

            /// 작은 테이프 느낌
            Positioned(
              top: -7,
              left: 30,
              right: 30,
              child: Container(
                height: 14,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: Colors.black.withValues(alpha: 0.05),
                    width: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// no.3 정보의 라벨과 값을 한 줄로 표현해주는 위젯
  Widget _buildInfoRow(String label, String value) { /// 라벨과 값을 받아옴
    return Row( /// 라벨과 값을 가로로 배치
      mainAxisAlignment: MainAxisAlignment.spaceBetween, /// 양 끝으로 멀리 떨어지게 배치
      children: [ /// 라벨과 값 표시
        Text(
          label, /// 라벨 표시 (예: "공연명")
          style: const TextStyle(
            fontSize: 12, /// 폰트 사이즈
            fontWeight: FontWeight.bold, /// 폰트 굵기
            color: Colors.grey, /// 폰트 색상 (회색)
          ),
        ),
        Text(
          value, /// 값 표시 (예: "공연명 값")
          style: const TextStyle(
            fontSize: 13, /// 폰트 사이즈
            fontWeight: FontWeight.w500, /// 폰트 굵기
            color: Colors.black87, /// 폰트 색상
          ),
        ),
      ],
    );
  }

  /// no.4 다이어리 느낌 나도록 왼쪽 바인더 링 UI를 만들어주는 위젯
  Widget _buildBinderRing() { /// 바인더 링 UI 함수
    return Row( /// 바인더 링 가로로 배치
      children: [ /// 링과 구멍을 각각 배치
        Container( /// 링 네모 상자 만들기
          width: 15,
          height: 15,
          decoration: const BoxDecoration(color: Color(0xFF3E2723), shape: BoxShape.circle), /// 링이 들어가는 구멍 색상과 모양 설정
        ),
        Container( /// 링 디자인
          width: 25,
          height: 6,
          decoration: BoxDecoration( /// 디자인 도구 열기
            color: Colors.grey.shade300, /// 링 색깔 회색
            borderRadius: BorderRadius.circular(3), /// 네모 박스의 모서리 둥글기 설정으로 링 느낌을 표현
            boxShadow: [ /// 링에 그림자 효과
              BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 2, offset: const Offset(1, 1)), /// 링 그림자 설정
            ],
          ),
        ),
      ],
    );
  }

  /// no.5 우측 인덱스 탭 UI를 만들어주는 위젯
  Widget _buildIndexTab(Color color, String text) { /// 인덱스 탭 UI 함수 (색상과 텍스트를 받아옴)
    return Container( /// 인덱스 탭 네모 상자 만들기
      width: 40,
      height: 85,
      decoration: BoxDecoration( /// 디자인 도구 열기
        color: color, /// 인덱스 탭 색상 설정
        borderRadius: const BorderRadius.horizontal( /// 인덱스 탭 왼쪽과 오른쪽 둥글게 처리
          left: Radius.circular(8), /// 왼쪽을 둥글게 처리
          right: Radius.circular(5), /// 오른쪽을 약간만 둥글게 처리
        ),
        boxShadow: [ /// 인덱스 탭에 그림자 효과 추가 (그림자 효과 두 방향 입체감)
          BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 4, offset: const Offset(-2, 2)), /// 왼쪽 아래로 그림자
          BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 3, offset: const Offset(2, 2)), /// 오른쪽 아래로 그림자
        ],
      ),
      child: Center( /// 텍스트 중앙 정렬
        child: Text( /// 인덱스 탭 텍스트 배치
          text, /// 인덱스 탭 텍스트 (뒤로 가기 버튼: ◀)
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87), /// 인덱스 탭 텍스트 폰트 사이즈, 굵기, 색상
        ),
      ),
    );
  }
}

/// 포스트잇 접힌 모서리(오른쪽 위) 모양을 만들기 위한 클리퍼
class _PostItCornerClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    /// 오른쪽 위에서 안쪽으로 삼각형을 잘라 접힌 느낌을 만듦
    return Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, 0)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// 타임테이블 한 줄을 표현하기 위한 작은 위젯
class _TimeRow extends StatelessWidget {
  final String time;
  final String label;

  const _TimeRow({required this.time, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          time,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.black87),
        ),
      ],
    );
  }
}

