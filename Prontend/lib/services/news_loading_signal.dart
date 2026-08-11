import 'package:flutter/foundation.dart';

/// "소식 탭 데이터를 아직 불러오는 중" 신호.
///
/// [NewsScreen]이 로딩을 시작/종료할 때 이 값을 true/false로 바꿉니다.
/// [DiaryTabFlipTransition]은 목적지가 소식 탭일 때만 이 값을 지켜보다가,
/// true인 동안은 전환 애니메이션(페이지 넘김)을 계속 재생해 소식 탭 자체의
/// 로딩 스피너가 화면에 보이지 않도록 합니다. 안전장치로 10초가 지나면
/// [NewsScreen]이 스스로 false로 되돌려 무한 대기를 막습니다.
class NewsLoadingSignal {
  NewsLoadingSignal._();

  static final ValueNotifier<bool> isLoading = ValueNotifier<bool>(false);
}
