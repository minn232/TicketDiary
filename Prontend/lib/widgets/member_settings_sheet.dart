import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/guest_migration_service.dart';
import '../services/kakao_login_controller.dart';
import '../services/local_ticket_store.dart';
import '../services/ticket_service.dart';
import 'local_profile_editor.dart';
import 'paper_style.dart';
import 'responsive_text.dart';

/// 게스트 데이터가 있는 상태에서 카카오 로그인을 시도할 때, 그 데이터를
/// 가져올지("migrate") 그대로 두고 새 카카오 계정으로 시작할지
/// ("startFresh") 사용자가 고르는 선택지.
enum _MigrationChoice { migrate, startFresh }

/// "회원 설정"을 누르면 아래에서 올라오는 계정 시트.
///
/// 게스트에게는 로그인, 카카오 사용자에게는 프로필 편집과 로그아웃을 제공합니다.
/// [AuthService]/[KakaoLoginController]에 연결되어 실제로 동작합니다.
class MemberSettingsSheet extends StatefulWidget {
  const MemberSettingsSheet({super.key});

  @override
  State<MemberSettingsSheet> createState() => _MemberSettingsSheetState();
}

class _MemberSettingsSheetState extends State<MemberSettingsSheet> {
  final AuthService _auth = AuthService.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _runGuarded(
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (successMessage != null) _showMessage(successMessage);
    } on AlreadyKakaoUserException {
      await _showAlertDialog('로그인 실패', '이미 다른 계정으로 가입된 카카오 계정이에요.');
    } on KakaoLoginCancelledException {
      // 사용자가 웹뷰를 닫거나 카카오 로그인 자체를 취소한 경우: 상태
      // 변화가 없으므로(토큰 미저장) 별도 알림 없이 조용히 원래 화면으로 복귀합니다.
    } on KakaoLoginUnsupportedOnWebException {
      await _showAlertDialog('아직 지원하지 않아요', '카카오 로그인은 현재 모바일 앱에서만 이용할 수 있어요.');
    } on ApiException catch (e) {
      await _showAlertDialog('처리하지 못했어요', e.message);
    } catch (_) {
      // 위 타입들로 잡히지 않는 예상 밖의 오류(네트워크 단절 등)도 조용히
      // 삼키지 않고 사용자에게 알립니다.
      await _showAlertDialog('문제가 생겼어요', '잠시 후 다시 해 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showPaperSnackBar(context, message);
  }

  /// 비정상 종료/실패를 알리는 확인용 알림창. 확인을 누르면 닫히고, 이미
  /// 상태는 실패 이전으로 유지된 채라(성공 시에만 토큰이 갱신됨) 그대로
  /// 원래 화면으로 복귀합니다.
  Future<void> _showAlertDialog(String title, String message) async {
    if (!mounted) return;
    await showPaperDialog<void>(
      context,
      title: title,
      message: message,
      actions: const [PaperDialogAction(label: '확인')],
    );
  }

  void _loginWithKakao() {
    _runGuarded(_loginWithKakaoFlow);
  }

  /// 카카오 로그인 진입점.
  ///
  /// - 카카오 로그인 상태(계정 전환)거나, 활성 게스트 세션 자체가 없으면
  ///   (로그아웃 등으로 완전히 로그아웃된 상태 포함) 바로 `/auth/kakao`로
  ///   로그인합니다. `/auth/migrate`는 인증(게스트 세션)이 있어야만 호출할
  ///   수 있는 엔드포인트라, 세션이 없는데 마이그레이션을 시도하면 401이
  ///   납니다 — 그래서 [AuthService.isGuest](세션이 없을 때도 기본값 true)가
  ///   아니라 [AuthService.hasActiveGuestSession]으로 판단합니다.
  /// - 활성 게스트인데 옮길 데이터가 없으면 일반 로그인
  ///   (`/auth/kakao`)으로 처리합니다. 옮길 데이터가 없는 빈 게스트를 굳이
  ///   마이그레이션(`/auth/migrate`)하면, 그 카카오 계정이 이미 다른
  ///   기기에서 가입/로그인된 적이 있을 때 "이미 다른 계정으로 가입된
  ///   카카오 계정"이라며 충돌합니다(마이그레이션은 "지금 이 게스트를 그
  ///   계정으로 승격"하는 동작이라, 이미 다른 유저에게 연결된 계정과는
  ///   병합할 수 없기 때문). 일반 로그인은 그런 경우에도 그냥 그 기존
  ///   계정으로 로그인시켜주므로, 옮길 데이터가 없다면 항상 이 경로가
  ///   안전합니다.
  /// - 활성 게스트인데 옮길 티켓이(로컬이든 서버든) 하나라도 있으면, 먼저
  ///   그 데이터를 카카오 계정으로 옮길지 물어봅니다("옮기기"/"삭제하기"/"취소").
  Future<void> _loginWithKakaoFlow() async {
    if (!_auth.hasActiveGuestSession) {
      await KakaoLoginController.instance.login(
        context: context,
        migrateFromGuest: false,
      );
      _showMessage('로그인됐어요.');
      return;
    }

    final hasDataToMigrate = await _hasGuestDataToMigrate();
    if (!hasDataToMigrate) {
      if (!mounted) return;
      await KakaoLoginController.instance.login(
        context: context,
        migrateFromGuest: false,
      );
      _showMessage('로그인됐어요.');
      return;
    }

    if (!mounted) return;
    final choice = await _showMigrationChoiceDialog();
    if (choice == null || !mounted) return; // 취소

    final code = await KakaoLoginController.instance.fetchAuthorizationCode(
      context: context,
    );

    if (choice == _MigrationChoice.startFresh) {
      await AuthService.instance.completeKakaoLogin(
        code,
        migrateFromGuest: false,
      );
      _showMessage('로그인됐어요. 게스트로 등록했던 티켓은 이 카카오 계정에 반영되지 않았어요.');
      return;
    }

    final result = await GuestMigrationService.instance.migrateGuestDataToKakao(
      code,
    );
    _showMessage(
      result.hasFailures
          ? '${result.migratedCount}개를 옮겼어요. ${result.failedCount}개는 옮기지 못해 기기에 남아있어요.'
          : '게스트로 남긴 티켓 ${result.migratedCount}개를 카카오 계정으로 옮겼어요.',
    );
  }

  // [백엔드 수정]
  // 게스트도 서버에 티켓을 저장하므로(TicketService 참고) 옮길 데이터가
  // 있는지 로컬 티켓뿐 아니라 서버 티켓 개수도 같이 확인함.
  /// 지금 게스트 계정에 카카오로 넘어갈 때 물어볼 만한 데이터(로컬 레거시
  /// 티켓이든, 서버에 이미 등록된 티켓이든)가 하나라도 있는지 확인합니다.
  Future<bool> _hasGuestDataToMigrate() async {
    if (await LocalTicketStore.instance.hasAnyTickets()) return true;

    try {
      final serverTickets = await TicketService().listTickets();
      return serverTickets.isNotEmpty;
    } catch (_) {
      // 서버 조회 실패(오프라인 등) 시엔 안전한 쪽으로 판단합니다 — 데이터가
      // 있는데 확인 없이 버리는 것보다, 없어도 한 번 더 물어보는 쪽이 낫습니다.
      return true;
    }
  }

  /// 게스트로 저장해둔 데이터를 카카오 계정으로 가져올지 물어보는 확인창.
  Future<_MigrationChoice?> _showMigrationChoiceDialog() {
    // 데이터를 잃을 수 있는 선택이라 무게를 나눔: 옮기기(주) / 삭제하기(빨간 글자) / 취소(흐림)
    return showPaperDialog<_MigrationChoice>(
      context,
      title: '게스트로 남긴 기록을 옮길까요?',
      message:
          '게스트로 쓰면서 추가한 티켓이 있어요.\n'
          '카카오 계정으로 그대로 옮길까요?\n\n'
          '옮기지 않으면 이 티켓은 게스트로 돌아갔을 때만 볼 수 있어요.',
      tapeTint: PaperColors.tapeMustard,
      actions: const [
        PaperDialogAction(label: '취소', style: PaperButtonStyle.quiet),
        PaperDialogAction(
          label: '옮기지 않기',
          value: _MigrationChoice.startFresh,
          style: PaperButtonStyle.danger,
        ),
        PaperDialogAction(label: '옮기기', value: _MigrationChoice.migrate),
      ],
    );
  }

  Future<void> _logout() async {
    final confirmed = await _showLogoutConfirmDialog();
    if (!confirmed || !mounted) return;
    _runGuarded(_auth.logout, successMessage: '로그아웃했어요.');
  }

  /// 로그아웃 전 한 번 더 확인하는 창. "예"를 왼쪽에 살짝 눈에 덜 띄는
  /// 회색으로 둬서, 실수로 로그아웃을 누르는 걸 방지합니다.
  Future<bool> _showLogoutConfirmDialog() async {
    if (!mounted) return false;
    final confirmed = await showPaperDialog<bool>(
      context,
      title: '로그아웃',
      message: '로그아웃할까요?',
      actions: const [
        PaperDialogAction(
          label: '로그아웃',
          value: true,
          style: PaperButtonStyle.danger,
        ),
        PaperDialogAction(
          label: '취소',
          value: false,
          style: PaperButtonStyle.outline,
        ),
      ],
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isGuest = _auth.isGuest;
    final currentUser = _auth.currentUser;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
        // 버튼이 작아져 시트 폭을 안 잡아주므로 직접 꽉 채움
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // stretch 안에서도 짧은 막대로 남게 가운데 고정
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: PaperColors.ink.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 카카오 프로필 사진은 안 씀(추후 앱에서 직접 등록 예정)
            // [백엔드 수정] 게스트도 카카오와 같은 편집기(닉네임·사진).
            if (currentUser != null)
              LocalProfileEditor(
                key: ValueKey(currentUser.id),
                userId: currentUser.id,
                nickname: currentUser.nickname,
                isGuest: isGuest,
              )
            else
              _ProfileRow(isGuest: isGuest, nickname: currentUser?.nickname),
            const SizedBox(height: 24),
            if (isGuest)
              SizedBox(
                width: double.infinity,
                child: _KakaoLoginButton(
                  onTap: _busy ? null : _loginWithKakao,
                  busy: _busy,
                ),
              )
            // 되돌리기 어려운 동작이라 큰 주 버튼 대신 작은 테두리 버튼
            else
              Center(
                child: PaperButton(
                  label: _busy ? '로그아웃 중…' : '로그아웃',
                  style: PaperButtonStyle.outline,
                  onTap: _busy ? null : _logout,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 현재 계정 상태를 보여주는 프로필. 큰 프로필 동그라미 아래에 이름과 계정
/// 종류를 붙여 보여줍니다. 게스트면 아직 계정이 연결되지 않았음을 알리는
/// 빨간 느낌표 도장이 뜹니다.
class _ProfileRow extends StatelessWidget {
  final bool isGuest;
  final String? nickname;

  const _ProfileRow({required this.isGuest, this.nickname});

  @override
  Widget build(BuildContext context) {
    final label = isGuest
        ? '게스트로 쓰는 중'
        : (nickname != null && nickname!.isNotEmpty ? nickname! : '카카오 계정');

    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            ProfileAvatar(size: 88, name: isGuest ? null : nickname),
            if (isGuest)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: PaperColors.stamp,
                    shape: BoxShape.circle,
                    border: Border.all(color: PaperColors.card, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '!',
                    style: TextStyle(
                      color: PaperColors.card,
                      fontSize: context.sp(14),
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: TextStyle(
            fontSize: context.sp(16),
            fontWeight: FontWeight.w900,
            color: PaperColors.ink,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          isGuest ? '아직 계정이 연결되지 않았어요' : '카카오 계정으로 로그인했어요',
          style: TextStyle(
            fontSize: context.sp(12),
            fontWeight: FontWeight.w600,
            color: PaperColors.muted,
          ),
        ),
      ],
    );
  }
}

class _KakaoLoginButton extends StatelessWidget {
  final VoidCallback? onTap;
  final bool busy;

  const _KakaoLoginButton({required this.onTap, this.busy = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFFEE500),
          foregroundColor: const Color(0xFF3C1E1E),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Color(0xFF3C1E1E),
                ),
              )
            : Text(
                '카카오로 로그인',
                style: TextStyle(
                  fontSize: context.sp(16),
                  fontWeight: FontWeight.w800,
                ),
              ),
      ),
    );
  }
}
