import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/widgets/ticket_scan_camera_screen.dart';

/// 태블릿에서 카메라 스캔 가이드 박스 비율이 깨지던 버그의 원인이었던
/// [fitPreviewRect](화면비가 카메라 비율과 다를 때의 레터박스 계산)를 검증합니다.
void main() {
  const aspectRatio = 3 / 4; // 세로 3:4 카메라(width/height) 가정.

  test('화면비가 카메라 비율과 똑같으면 레터박스 없이 꽉 채운다', () {
    final rect = fitPreviewRect(const Size(300, 400), aspectRatio);
    expect(rect, const Rect.fromLTWH(0, 0, 300, 400));
  });

  test('화면이 카메라보다 상대적으로 더 세로로 길면(태블릿처럼 정사각형에 가까운 화면), '
      '폭이 기준이 되어 위아래로 레터박스된다', () {
    final rect = fitPreviewRect(const Size(1000, 1000), aspectRatio);
    expect(rect.width, closeTo(750, 0.01));
    expect(rect.height, closeTo(1000, 0.01));
    expect(rect.top, closeTo(0, 0.01)); // 세로를 다 채우니 위아래 여백 없음
    expect(rect.left, closeTo(125, 0.01)); // 좌우로 레터박스
  });

  test('화면이 카메라보다 상대적으로 훨씬 가로로 넓으면, 높이가 기준이 되어 좌우로 레터박스된다', () {
    final rect = fitPreviewRect(const Size(1600, 400), aspectRatio);
    expect(rect.height, closeTo(400, 0.01)); // 세로를 다 채움
    expect(rect.width, closeTo(300, 0.01));
    expect(rect.top, closeTo(0, 0.01));
    expect(rect.left, closeTo(650, 0.01)); // 좌우로 크게 레터박스
  });

  test('결과 사각형은 화면 크기와 무관하게 항상 요청한 비율을 유지한다', () {
    for (final size in [
      const Size(402, 874), // 폰 근사치
      const Size(768, 1024), // 태블릿 세로
      const Size(1024, 768), // 태블릿 가로
    ]) {
      final rect = fitPreviewRect(size, aspectRatio);
      expect(rect.width / rect.height, closeTo(aspectRatio, 0.001));
      expect(rect.width, lessThanOrEqualTo(size.width + 0.01));
      expect(rect.height, lessThanOrEqualTo(size.height + 0.01));
    }
  });
}
