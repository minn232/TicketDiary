import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/services/auth_service.dart';
import 'package:ticketdiary/widgets/member_settings_sheet.dart';
import 'package:ticketdiary/widgets/local_profile_editor.dart';
import 'support/fake_api.dart';

void main() {
  testWidgets('게스트 로그인 안내에서 회원 프로필로 갱신되고 로그아웃 취소는 세션을 유지한다', (tester) async {
    mockStorage();
    var guest = true;
    final api = installApi((r) {
      if (r.path == '/auth/me') {
        return {
          'id': 'member',
          'nickname': '닉네임',
          'is_guest': guest,
          'role': 'user',
        };
      }
      return sessionResponse(r);
    });
    await tester.runAsync(() => AuthService.instance.ensureSession());
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MemberSettingsSheet())),
    );
    await tester.pumpAndSettle();
    expect(find.text('카카오로 로그인'), findsOneWidget);
    expect(find.byType(LocalProfileEditor), findsNothing);
    guest = false;
    await tester.runAsync(() => AuthService.instance.refreshCurrentUser());
    await tester.pumpAndSettle();
    expect(find.byType(LocalProfileEditor), findsOneWidget);
    expect(find.text('닉네임'), findsOneWidget);
    expect(find.text('카카오로 로그인'), findsNothing);
    await tester.tap(find.text('로그아웃'));
    await tester.pumpAndSettle();
    expect(find.text('로그아웃할까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(find.text('로그아웃할까요?'), findsNothing);
    expect(AuthService.instance.isLoggedIn, isTrue);
    expect(api.requests.where((r) => r.path == '/auth/logout'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
