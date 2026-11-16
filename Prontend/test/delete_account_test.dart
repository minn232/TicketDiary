import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/services/auth_service.dart';
import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('삭제 실패 시 세션 유지, 삭제 후 게스트 접속 실패 시 탈퇴 성공', () async {
    mockStorage();
    var failDelete = true;
    var deleted = false;
    installApi((request) {
      if (request.path == '/auth/me' && request.method == 'DELETE') {
        if (failDelete) return ResponseBody.fromString('{}', 500);
        deleted = true;
        return ResponseBody.fromString('', 204);
      }
      if (request.path == '/auth/guest' && deleted) {
        return ResponseBody.fromString('{}', 503);
      }
      return sessionResponse(request);
    });
    final auth = AuthService.instance;
    await auth.ensureSession();
    final originalId = auth.userId;
    await expectLater(auth.deleteAccount(), throwsException);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.userId, originalId);
    var notified = false;
    void listener() => notified = true;
    auth.addListener(listener);
    addTearDown(() => auth.removeListener(listener));
    failDelete = false;
    await auth.deleteAccount();
    expect(deleted, isTrue);
    expect(auth.isLoggedIn, isFalse);
    expect(auth.currentUser, isNull);
    expect(auth.refreshToken, isNull);
    expect(notified, isTrue);
  });
}
