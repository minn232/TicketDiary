import 'package:flutter/material.dart';
import 'concert_before_screen.dart';

/// 앱 실행을 담당.
/// 로그인 유지나 초기 설정을 저장해서 사용하는 경우,
/// const를 제외.
void main() {
  runApp(const TicketDiaryApp());
}

/// flutter에서 제공하는 기본 StatelessWidget을 상속받음.
/// UI가 고정되어 있는 경우에 사용.
class TicketDiaryApp extends StatelessWidget {
  const TicketDiaryApp({super.key});

  /// 앱의 전체적인 테마와 초기 화면을 설정하는 부분.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(     /// MaterialApp은 구글의 디자인 테마.
      debugShowCheckedModeBanner: false,  /// 앱 실행 시 자꾸 오른쪽 위에 Debug라고 뜨는거 제거
      title: 'Ticket Diary',  /// 앱의 이름
      theme: ThemeData(       /// 앱의 세부 테마를 설정.
        fontFamily: 'Roboto', /// 글꼴을 Roboto로 설정.
      ),
      home: const DiaryScreen(),  /// 앱 실행시 가장 먼저 보이는 기본 화면. 이것 또한 statelesswidget으로 만들어짐.
    );
  }
}

/// 앱의 다이어리 화면을 구성하기 위해 class생성.
/// const로 화면 UI는 고정.
class DiaryScreen extends StatelessWidget {
  const DiaryScreen({super.key});

  /// 앱의 다이어리 화면을 구성하는 부분.
  /// 다이어리 페이지, 인덱스 탭, 왼쪽 바인더 링의 배치
  @override
    Widget build(BuildContext context) {
      return Scaffold(  /// 빈 도화지
        backgroundColor: const Color(0xFF5C4033), /// 다이어리 가죽 색상
        body: SafeArea(
          child: Stack( /// 레이어를 겹쳐서 배치할 수 있게 해줌
            children: [
              /// 다이어리 페이지 레이어 (겹쳐서 깊이감 표현)
              _buildPageLayer(right: 35, bottom: 20),
              _buildPageLayer(right: 38, bottom: 20),
              _buildPageLayer(right: 41, bottom: 20),
              _buildPageLayer(right: 44, bottom: 20),

              /// 우측 인덱스 탭 레이어
              Positioned( /// 특정 위치에 고정해서 배치할 수 있게 해줌
                /// 첫번째 탭: 다이어리 탭 (맨 뒤 페이지)
                right: 4,
                top: 80,
                child: _buildIndexTab(const Color(0xFFE8AE75), "다이어리"),
              ),
              Positioned(
                /// 두번째 탭: 소식 탭 (맨 뒤에서 3번째 페이지)
                right: 7,
                top: 175,
                child: _buildIndexTab(const Color(0xFF9CB8A7), "소식"),
              ),
              Positioned(
                  /// 세번째 탭: 결산 탭 (맨 뒤에서 2번째 페이지)
                right: 10,
                top: 270,
                child: _buildIndexTab(const Color(0xFFD3A39B), "결산"),
              ),
              Positioned(
                  /// 네번째 탭: 설정 탭 (맨 뒤에서 1번째 페이지)
                right: 13,
                top: 380,
                child: _buildIndexTab(const Color(0xFFB0B0B0), "설정"),
              ),

              /// 다이어리 페이지 레이어 (실제 티켓이 들어가는 페이지)
              Positioned(

                /// 메인 페이지 레이어 설정
                top: 10,
                bottom: 10,
                left: 30, /// 왼쪽 바인더 링을 위한 여백
                right: 45, /// 오른쪽 인덱스 탭을 위한 여백

                /// 설정을 마쳤으니 페이지 레이어 구성
                child: Container( /// 페이지 네모 상자 만들기
                  decoration: BoxDecoration(  /// 페이지 디자인 도구 열기
                    color: const Color(0xFFF4F1E1), /// 빈티지 종이 색상
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(15), /// 페이지 오른쪽만 둥글게 처리
                    ),
                    boxShadow: [  /// 그림자 효과
                      BoxShadow(  /// 페이지 가장자리 그림자 설정
                        color: Colors.black.withValues(alpha: 0.3), /// 그림자 투명도 30%
                        blurRadius: 10, /// 그림자 흐림 정도
                        offset: const Offset(5, 5), /// 그림자 위치 (오른쪽 아래로 5픽셀 이동)
                      ),
                    ],
                  ),

                  /// 페이지 레이어 안에 티켓이 들어가는 부분
                  child: LayoutBuilder( /// 페이지 크기 안에서 레이아웃을 조정할 수 있게 함
                    builder: (context, constraints) { /// constraints로 페이지의 크기를 가져옴
                      return SingleChildScrollView( /// 페이지 스크롤이 가능하게 함
                        padding: const EdgeInsets.symmetric(horizontal: 25),  /// 페이지 양쪽에 여백 설정
                        child: ConstrainedBox(  /// 페이지 크기에 맞춰 자식 위젯의 크기 제한
                          constraints: BoxConstraints(minHeight: constraints.maxHeight),  /// 페이지가 위젯이 얼마만큼 차있는 지와 관계없이 꽉 채우도록 설정
                          child: Column(  /// 페이지 안 위젯들을 세로로 배치
                            mainAxisAlignment: MainAxisAlignment.center,  /// 페이지 안 위젯들을 중앙으로 배치
                            children: [ /// 티켓들을 배치
                              /// 1. 티켓 추가 위젯
                              _buildAddTicketButton(),  /// 티켓 추가 버튼
                              const SizedBox(height: 30),

                              /// 2. 배송 날짜 티켓 위젯
                              _buildTicketPocket(
                                child: _buildTicketBeforeDelivery(),  /// 배송 티켓
                              ),
                              const SizedBox(height: 20),

                              /// 3. 공연전 티켓 위젯
                              GestureDetector(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => const ConcertBeforeScreen(concertTitle: "공연전"),
                                  ),
                                ),
                                child: _buildTicketPocket(
                                  child: _buildTicketBeforeConcert(), /// 공연 전 티켓
                                ),
                              ),
                              const SizedBox(height: 20),

                              /// 4. 공연후 티켓 위젯
                              _buildTicketPocket(
                                child: _buildTicketAfterConcert(),  /// 공연 후 티켓
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

              /// 다이어리 느낌 나도록 왼쪽 바인더 링 레이어
              Positioned( /// 위젯 위치 고정
                left: 15,
                top: 50,
                bottom: 50,
                child: Column(  /// 세로로 배치
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly, /// 바인더 링 사이 간격을 자동으로 균등하게 배치
                  children: List.generate(6, (index) => _buildBinderRing()),  /// 6개의 바인더 링을 일일이 생성하지 않고 반복문으로 생성
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
   *   각 위젯은 다이어리 페이지 안에서 티켓을 표현하기 위한 위젯들로 구성되어 있음
   *
   *   no.1 _buildPageLayer: 다이어리 페이지의 겹치는 레이어를 만들어 깊이감을 표현
   *   no.2 _buildAddTicketButton: 티켓 추가 버튼을 만들어주는 위젯
   *   no.3 _buildTicketPocket: 티켓 배경느낌의 포켓을 만들어주는 래퍼 위젯
   *   no.4 _buildTicketBeforeDelivery: 배송 전 티켓 UI를 만들어주는 위젯
   *   no.5 _buildTicketBeforeConcert: 공연 전 티켓 UI를 만들어주는 위젯
   *   no.6 _buildTicketAfterConcert: 공연 후 티켓 UI를 만들어주는 위젯 (뜯어진 효과 포함)
   *   no.7 _buildBinderRing: 다이어리 왼쪽 바인더 링 UI를 만들어주는 위젯
   *   no.8 _buildIndexTab: 우측 인덱스 탭 UI를 만들어주는 위젯
    */

  /// no.1 다이어리 페이지의 겹치는 레이어를 만들어 깊이감을 표현하는 위젯
  Widget _buildPageLayer({required double right, required double bottom}) { /// 페이지 레이어의 오른쪽, 아래쪽 여백을 받아옴
    return Positioned(  /// 위치 고정
      top: 10,
      bottom: bottom,
      left: 30,
      right: right,
      child: Container( /// 페이지 네모 상자 만들기
        decoration: BoxDecoration(  /// 디자인 도구 열기
          color: const Color(0xFFF4F1E1), /// 종이 색상
          borderRadius: const BorderRadius.horizontal(  /// 페이지 오른쪽만 둥글게 처리
            right: Radius.circular(15), /// 둥근 정도
          ),
          boxShadow: [  /// 그림자 효과 추가
            BoxShadow(  /// 그림자 효과 함수
              color: Colors.black.withValues(alpha: 0.2), /// 그림자 투명도
              blurRadius: 8,  /// 그림자 흐림 정도
              offset: const Offset(4, 4), /// 그림자 위치 (오른쪽 아래)
            ),
          ],
        ),
      ),
    );
  }

  /// no.2 티켓 추가 버튼을 만들어주는 위젯
  Widget _buildAddTicketButton() {  /// 티켓 추가 버튼 함수
    return Container( /// 버튼 네모 상자 만들기
      height: 100,
      decoration: BoxDecoration(  /// 디자인 도구 열기
        color: Colors.white.withValues(alpha: 0.5), /// 티켓 색상
        borderRadius: BorderRadius.circular(15),  /// 모서리 둥글기 정도
        border: Border.all(color: Colors.grey.shade400, width: 2, style: BorderStyle.solid),  /// 테두리 회색, 두께, 실선 설정
      ),
      child: const Center(  /// 정중앙 배치
        child: Text(
          "티켓  추가",
          style: TextStyle( /// 텍스트 스타일 설정
            fontSize: 26, /// 폰트 사이즈
            fontWeight: FontWeight.bold,  /// 폰트 굵기
            color: Colors.black87,  /// 폰트 색상
            letterSpacing: 4.0, /// 글자 간격
          ),
        ),
      ),
    );
  }

  /// no.3 티켓 포켓 생성 위젯
  Widget _buildTicketPocket({required Widget child}) {  /// 티켓 위젯을 받아온 후, 포켓을 감싸는 구조
    return Container( /// 네모 상자 만들기
      height: 120,
      decoration: BoxDecoration(  /// 디자인 도구 열기
        color: Colors.white.withValues(alpha: 0.4), /// 티켓 포켓 회색 배경
        borderRadius: BorderRadius.circular(10),  /// 모서리 둥글기 정도
        border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 2), /// 테두리 흰색, 두께
        boxShadow: [  /// 그림자 설정
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 5, offset: const Offset(2, 2)),  /// 그림자 정도, 범위, 위치
        ],
        gradient: LinearGradient( /// 티켓의 아날로그 느낌을 위한 빛 반사 그라데이션 추가
          begin: Alignment.topLeft, /// 왼쪽 위에서
          end: Alignment.bottomRight, /// 오른쪽 아래로
          colors: [
            Colors.white.withValues(alpha: 0.6),  /// 왼쪽 위 밝게
            Colors.white.withValues(alpha: 0.0),  /// 중간은 그대로
            Colors.white.withValues(alpha: 0.2),  /// 오른쪽 아래에서 다시 살짝 밝게
          ],
        ),
      ),
      child: Padding( /// 티켓과 티켓 포켓 사이 여백 기능
        padding: const EdgeInsets.all(10.0),  /// 여백 너비
        child: child, /// 실제 티켓이 들어갈 부분
      ),
    );
  }

  /// no.4 배송 전 티켓 UI를 만들어주는 위젯
  Widget _buildTicketBeforeDelivery() { /// 배송 전 티켓 UI 함수
    return Row( /// 티켓 가로로 배치
      children: [ /// 왼쪽 티켓과 오른쪽 찢어진 부분 나누기
        Expanded( /// 왼쪽 티켓의 텍스트가 티켓 안에서 남은 공간을 모두 차지하도록 설정
          flex: 3,  /// 왼쪽 티켓과 오른쪽 티켓 크기 배수
          child: Container( /// 왼쪽 티켓 네모 상자 만들기
            decoration: const BoxDecoration(  /// 디자인 도구 열기
              color: Colors.white,  /// 티켓의 색상
              borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),  /// 왼쪽만 둥글게 처리
            ),
            padding: const EdgeInsets.all(12),  /// 티켓 안쪽 내용 채우기 전 여백 설정
            child: const Column(  /// 티켓 안 내용 세로로 배치
              crossAxisAlignment: CrossAxisAlignment.start, /// 내용 왼쪽 정렬
              mainAxisAlignment: MainAxisAlignment.center,  /// 내용 수직 중앙 정렬
              children: [ /// 티켓 안 내용 배치
                Text("배송전", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)), /// 왼쪽 위 티켓 상태 텍스트
                Spacer(), /// 배송 전 텍스트와 배송날짜 텍스트 사이 공간 자동 채우기
                Center( /// 배송 날짜 텍스트 중앙 정렬
                  child: Text("배송 날짜\n(D-day)", textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),  /// 줄 바꿈 포함하여 배송 날짜와 D-day 텍스트 배치
                ),
                Spacer(), /// 배송 날짜 텍스트와 아래 빈 공간 사이 자동 채우기
              ],
            ),
          ),
        ),
        /// 절취선 효과를 위한 회색 선과 오른쪽 티켓 부분
        Container(width: 1, color: Colors.grey.shade400), /// 절취선 느낌의 회색 선
        Expanded( /// 예매처 아이콘 텍스트가 빈 공간 모두 차지하도록 설정
          flex: 1,  /// 오른쪽 티켓과 비례한 크기 배수
          child: Container( /// 오른쪽 티켓 네모 상자 만들기
            decoration: const BoxDecoration(  /// 디자인 도구 열기
              color: Colors.white,  /// 티켓 색상
              borderRadius: BorderRadius.horizontal(right: Radius.circular(8)), /// 오른쪽만 둥글게 처리
            ),
            child: const Center(  /// 오른쪽 티켓 내용 중앙 정렬
              child: Text("예매처\n아이콘", textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.black54)),  /// 줄 바꿈 포함하여 예매처 아이콘 텍스트 배치
            ),
          ),
        ),
      ],
    );
  }

  /// no.5 공연 전 티켓 UI를 만들어주는 위젯
  Widget _buildTicketBeforeConcert() {  /// 공연 전 티켓의 UI 함수
    return Row( /// 티켓 가로로 배치
      children: [ /// 왼쪽 티켓과 오른쪽 찢어진 부분 나누기
        Expanded( /// 왼쪽 티켓 설정
          flex: 3,  /// 왼쪽 티켓과 오른쪽 티켓 크기 배수
          child: Container( /// 왼쪽 티켓 네모 상자 만들기
            decoration: const BoxDecoration( /// 디자인 도구 열기
              color: Colors.white, ///  티켓 색상
              borderRadius: BorderRadius.horizontal(left: Radius.circular(8)), /// 왼쪽만 둥글게 처리
            ),
            padding: const EdgeInsets.all(12), /// 티켓 안쪽 내용 채우기 전 여백 설정
            child: const Column( /// 티켓 안 내용 세로로 배치
              crossAxisAlignment: CrossAxisAlignment.start, /// 내용 왼쪽 정렬
              children: [ /// 티켓 안 내용 배치
                Text("공연전", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)), /// 왼쪽 위 티켓 상태 텍스트
                Expanded( /// 공연 전 텍스트가 티켓 안에서 남은 공간을 모두 차지하도록 설정
                  child: Center(  /// 공연 전 텍스트 중앙 정렬
                    child: Text("공연전", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)), /// 공연 전 텍스트 배치
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(width: 1, color: Colors.grey.shade400), /// 절취선 느낌의 회색 선
        Expanded( /// 오른쪽 티켓의 텍스트가 티켓 안에서 남은 공간을 모두 차지하도록 설정
          flex: 1,  /// 오른쪽 티켓과 비례한 크기 배수
          child: Container( /// 오른쪽 티켓 네모 상자 만들기
            decoration: const BoxDecoration(  /// 디자인 도구 열기
              color: Colors.white,  /// 티켓 색상
              borderRadius: BorderRadius.horizontal(right: Radius.circular(8)), /// 오른쪽만 둥글게 처리
            ),
          ),
        ),
      ],
    );
  }

  /// no.6 공연 후 티켓 UI를 만들어주는 위젯
  Widget _buildTicketAfterConcert() { /// 공연 후 티켓 UI 함수
    return Row( /// 티켓 가로로 배치
      children: [ /// 왼쪽 티켓과 오른쪽 찢어진 부분 나누기
        Expanded( /// 왼쪽 티켓 설정
          flex: 3,  /// 왼쪽 티켓과 오른쪽 티켓 크기 배수
          child: Container( /// 왼쪽 티켓 네모 상자 만들기
            decoration: BoxDecoration(  /// 디자인 도구 열기
              color: Colors.white, /// 티켓 색상
              borderRadius: BorderRadius.circular(8), /// 모서리 둥글기 정도
              border: Border.all(color: Colors.grey.shade300),  /// 테두리 회색
            ),
            padding: const EdgeInsets.all(12),  /// 티켓 안쪽 내용 채우기 전 여백
            child: const Column(  /// 티켓 안 내용 세로로 배치
              crossAxisAlignment: CrossAxisAlignment.start, /// 내용 왼쪽 정렬
              children: [ /// 티켓 안 내용 배치
                Text("공연후", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)), /// 왼쪽 위 티켓 상태 텍스트
                Expanded( /// 공연 후 텍스트가 빈 공간 모두 차지
                  child: Center(  /// 공연 후 텍스트 중앙 정렬
                    child: Text("공연후", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)), /// 공연 후 텍스트 배치
                  ),
                ),
              ],
            ),
          ),
        ),

        /// 찢어진 느낌을 위한 빈 공간
        const SizedBox(width: 8),

        /// 오른쪽 티켓 부분
        Expanded( /// 오른쪽 티켓 설정
          flex: 1, /// 오른쪽 티켓과 비례한 크기 배수
          child: Container( /// 오른쪽 티켓 네모 상자 만들기
            decoration: BoxDecoration( /// 디자인 도구 열기
              color: Colors.white, /// 티켓 색상
              borderRadius: BorderRadius.circular(8), /// 모서리 둥글기 정도 (모든 방향)
              border: Border.all(color: Colors.grey.shade300),  /// 테두리 회색
            ),
            child: const Center(  /// 오른쪽 티켓 내용 중앙 정렬
              child: Text("공연전", style: TextStyle(fontSize: 12, color: Colors.black54)), /// 공연 전 텍스트 배치
            ),
          ),
        ),
      ],
    );
  }

  /// no.7 다이어리 느낌 나도록 왼쪽 바인더 링 UI를 만들어주는 위젯
  Widget _buildBinderRing() { /// 바인더 링 UI 함수
    return Row( /// 바인더 링 가로로 배치
      children: [ /// 링과 구멍을 각각 배치
        Container(  /// 링 네모 상자 만들기
          width: 15, height: 15,
          decoration: const BoxDecoration(color: Color(0xFF3E2723), shape: BoxShape.circle), /// 링이 들어가는 구멍 색상과 모양 설정
        ),
        Container(  /// 링 디자인
          width: 25, height: 6,
          decoration: BoxDecoration( /// 디자인 도구 열기
            color: Colors.grey.shade300, /// 링 색깔 회색
            borderRadius: BorderRadius.circular(3), /// 네모 박스의 모서리 둥글기 설정으로 링 느낌을 표현
            boxShadow: [  /// 링에 그림자 효과
              BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 2, offset: const Offset(1, 1)), /// 링 그림자 설정
            ],
          ),
        ),
      ],
    );
  }

  /// no.8 우측 인덱스 탭 UI를 만들어주는 위젯
  Widget _buildIndexTab(Color color, String text) { /// 인덱스 탭 UI 함수 (색상과 텍스트를 받아옴)
    return Container( /// 인덱스 탭 네모 상자 만들기
      width: 40,
      height: 85,
      decoration: BoxDecoration(  /// 디자인 도구 열기
        color: color, /// 인덱스 탭 색상 설정
        borderRadius: const BorderRadius.horizontal( /// 인덱스 탭 오른쪽만 둥글게 처리
          right: Radius.circular(5), /// 오른쪽을 둥글게 처리
        ),
        boxShadow: [  /// 인덱스 탭에 그림자 효과 추가 (그림자 효과 두 방향 입체감)
          BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 4, offset: const Offset(-2, 2)), /// 왼쪽 아래로 그림자
          BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 3, offset: const Offset(2, 2)),  /// 오른쪽 아래로 그림자
        ],
      ),
      child: Center(  /// 텍스트 중앙 정렬
        child: RotatedBox(  /// 텍스트 회전 도구
          quarterTurns: 1, /// 텍스트를 90도 회전하여 세로로 배치
          child: Text(  /// 인덱스 탭 텍스트 배치
            text, /// 인덱스 탭 텍스트
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87), /// 인덱스 탭 텍스트 폰트 사이즈, 굵기, 색상
          ),
        ),
      ),
    );
  }
}