import 'package:flutter/widgets.dart';

/// 아이폰 17(기본 모델) 논리 화면 폭(pt, 1206px 스크린샷 ÷ 3x = 402)을
/// 1.0배율 기준으로 삼습니다. 앱 안의 모든 `fontSize`/레이아웃 치수
/// 디자인값은 이 기준(아이폰 17 크기)에서 보이는 크기로 정해졌다고
/// 가정하고, [ResponsiveFontSize.sp]/[ResponsiveFontSize.rs]가 실제
/// 기기/프레임 폭에 맞게 그 값을 확대·축소합니다.
const double kReferenceFrameWidth = 402.0;

/// 화면/프레임이 기준보다 아주 작거나 커도 글자가 지나치게 쪼그라들거나
/// 커지지 않도록 배율을 이 범위로 묶습니다.
const double kMinTextScale = 0.85;
const double kMaxTextScale = 1.8;

/// [DiaryPageFrame]이 자신의 실제 렌더링 폭(frameWidth)을 기준으로 계산한
/// 글자 확대 배율을 하위 위젯 트리에 전달합니다. 다이어리 프레임 폭은
/// 기기별로(아이폰 vs 아이패드) 크게 달라지는데, `fontSize`는 원래 고정
/// 숫자라 프레임이 넓어져도 글자 크기가 그대로라 아이패드에서 상대적으로
/// 너무 작아 보였습니다 — 프레임 폭에 비례해 같이 커지게 합니다.
class DiaryFrameScale extends InheritedWidget {
  final double scale;

  /// [DiaryPageFrame]이 자신의 실제 프레임 폭 기준으로 계산한, 좌우로 남는
  /// 갈색 여백(한쪽 기준) 폭. 인덱스 탭이 이 여백 쪽으로 얼마나 튀어나갈
  /// 수 있는지 계산할 때(예: 페이지에 붙어 넘어가는 "다이어리" 활성 탭)
  /// [scale]과 함께 씁니다.
  final double marginEachSide;

  const DiaryFrameScale({
    super.key,
    required this.scale,
    required this.marginEachSide,
    required super.child,
  });

  static double? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DiaryFrameScale>()?.scale;
  }

  static DiaryFrameScale? maybeWidgetOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DiaryFrameScale>();
  }

  @override
  bool updateShouldNotify(DiaryFrameScale oldWidget) =>
      oldWidget.scale != scale || oldWidget.marginEachSide != marginEachSide;
}

/// [context.sp]/[context.rs]와 같은 배율 계산이지만, [DiaryFrameScale]을
/// (있어도) 전혀 조회하지 않고 항상 화면 폭만 봅니다. [DiaryPageFrame]이
/// 아직 만들어지기 전(그 생성자 인자를 준비하는 단계)에 쓰는 화면 바깥
/// 코드(예: `buildDiarySideTabs`)에서, 나중에 트리에 실제로 들어갈지 알 수
/// 없는 조상 위젯을 조회하지 않도록 이 함수를 씁니다.
double diaryScaleFromMediaQuery(BuildContext context) {
  return (MediaQuery.sizeOf(context).width / kReferenceFrameWidth)
      .clamp(kMinTextScale, kMaxTextScale);
}

extension ResponsiveFontSize on BuildContext {
  /// 가장 가까운 [DiaryPageFrame] 안이면 그 프레임의 실제 렌더링 폭 기준
  /// 배율을, 프레임 밖(로그인, 카메라 스캔 등 [DiaryPageFrame]을 쓰지
  /// 않는 화면)이면 화면 폭 기준으로 계산합니다 — [DiaryPageFrame]은
  /// 설계상 프레임 폭이 화면 폭과 거의 같아서(diaryAspectRatio가 실기기
  /// 화면비보다 덜 좁고 길어, 항상 가로폭이 꽉 차게 배치됨) 화면 폭이
  /// 합리적인 대체 기준이 됩니다.
  double get _diaryScale {
    final scale = DiaryFrameScale.maybeOf(this) ??
        (MediaQuery.sizeOf(this).width / kReferenceFrameWidth);
    return scale.clamp(kMinTextScale, kMaxTextScale);
  }

  /// [base](아이폰 17 기준 디자인 폰트 크기)를 현재 기기에 맞게 조절합니다.
  double sp(double base) => base * _diaryScale;

  /// [base](아이폰 17 기준 디자인 크기 — 너비/높이/여백 등)를 현재 기기에
  /// 맞게 조절합니다. [sp]와 같은 배율을 쓰지만, 인덱스 탭 같은 레이아웃
  /// 치수(폰트가 아닌 것)에 쓴다는 의미를 명확히 하기 위한 별도 이름입니다.
  double rs(double base) => base * _diaryScale;
}
