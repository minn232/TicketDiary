import 'package:flutter/material.dart';

import 'favorite_pinned_settings_screen.dart';
import '../services/api_client.dart';
import '../services/app_settings_store.dart';
import '../services/auth_service.dart';
import '../services/kakao_login_controller.dart';
import '../services/notification_settings_service.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/pressable_scale.dart';

/// 아직 백엔드와 연동되지 않은 알림 항목의 라벨 색상(회색 처리용).
const Color _unconnectedTextColor = Color(0x611A1A1A);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AppSettingsStore _appSettings = AppSettingsStore.instance;
  final NotificationSettingsService _notifSettingsService =
      NotificationSettingsService();

  bool pushExpanded = false;
  bool pushDayBefore = false;
  bool pushOnTheDay = false;
  bool pushTicketDelivery = false;
  bool pushFavArtistConcert = false;
  bool pushPinnedConcert = false;

  static const _divider = Divider(height: 1, thickness: 1);

  @override
  void initState() {
    super.initState();
    _appSettings.load();
    _appSettings.addListener(_onAppSettingsChanged);
    _loadNotificationSettings();
  }

  @override
  void dispose() {
    _appSettings.removeListener(_onAppSettingsChanged);
    super.dispose();
  }

  void _onAppSettingsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadNotificationSettings() async {
    try {
      final s = await _notifSettingsService.fetch();
      if (!mounted) return;
      setState(() {
        pushDayBefore = s.beforeConcert;
        pushOnTheDay = s.beforeConcert;
        pushTicketDelivery = s.delivery;
      });
    } catch (_) {
      // 조회에 실패하면 기본값(꺼짐)으로 남겨둡니다. 스위치를 직접 켜면
      // 다시 저장을 시도합니다.
    }
  }

  /// "하루전 알림"/"당일날 알림"은 백엔드에 `before_concert` 하나로 묶여
  /// 있어서, 둘 중 하나만 눌러도 두 스위치를 함께 갱신하고 같은 값을
  /// 서버에 저장합니다.
  Future<void> _setBeforeConcert(bool v) async {
    final prevDayBefore = pushDayBefore;
    final prevOnTheDay = pushOnTheDay;
    setState(() {
      pushDayBefore = v;
      pushOnTheDay = v;
    });
    try {
      await _notifSettingsService.update(
        delivery: pushTicketDelivery,
        beforeConcert: v,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        pushDayBefore = prevDayBefore;
        pushOnTheDay = prevOnTheDay;
      });
      _showSaveError(e);
    }
  }

  Future<void> _setDelivery(bool v) async {
    final prev = pushTicketDelivery;
    setState(() => pushTicketDelivery = v);
    try {
      await _notifSettingsService.update(
        delivery: v,
        beforeConcert: pushDayBefore,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => pushTicketDelivery = prev);
      _showSaveError(e);
    }
  }

  void _showSaveError(Object e) {
    if (!mounted) return;
    final message = e is ApiException ? e.message : '잠시 후 다시 시도해주세요.';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('알림 설정을 저장하지 못했어요: $message')));
  }

  void _openMemberSettingsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => const _MemberSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      isTabRoot: true,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.settings),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 18, 18, 18),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.black.withValues(alpha: 0.12),
              width: 1.2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: Text(
                    '설정',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Colors.black87,
                    ),
                  ),
                ),
                _divider,
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      _LoginStatusBanner(
                        onTap: () => _openMemberSettingsSheet(context),
                      ),
                      _divider,
                      _SwitchRow(
                        title: '예상 셋리 노출 여부',
                        value: _appSettings.showExpectedSetlist,
                        onChanged: (v) =>
                            _appSettings.setShowExpectedSetlist(v),
                      ),
                      _divider,

                      Theme(
                        data: Theme.of(context).copyWith(
                          dividerColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                        ),
                        child: ExpansionTile(
                          tilePadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                          childrenPadding: EdgeInsets.zero,
                          initiallyExpanded: pushExpanded,
                          onExpansionChanged: (v) =>
                              setState(() => pushExpanded = v),
                          title: const Text(
                            '푸쉬 알림',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: Colors.black87,
                            ),
                          ),
                          trailing: Icon(
                            pushExpanded
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            color: Colors.black.withValues(alpha: 0.55),
                          ),
                          children: [
                            _divider,
                            _SwitchRow(
                              title: '하루전 알림',
                              value: pushDayBefore,
                              onChanged: _setBeforeConcert,
                            ),
                            _divider,
                            _SwitchRow(
                              title: '당일날 알림',
                              value: pushOnTheDay,
                              onChanged: _setBeforeConcert,
                            ),
                            _divider,
                            _SwitchRow(
                              title: '티켓배송일 알림',
                              value: pushTicketDelivery,
                              onChanged: _setDelivery,
                            ),
                            _divider,
                            _SwitchRow(
                              title: '선호 아티스트 공연 알림',
                              value: pushFavArtistConcert,
                              onChanged: (v) =>
                                  setState(() => pushFavArtistConcert = v),
                              titleColor: _unconnectedTextColor,
                            ),
                            _divider,
                            _SwitchRow(
                              title: '찜 공연 알림',
                              value: pushPinnedConcert,
                              onChanged: (v) =>
                                  setState(() => pushPinnedConcert = v),
                              titleColor: _unconnectedTextColor,
                            ),
                          ],
                        ),
                      ),
                      _divider,

                      _MenuRow(
                        title: '선호 아티스트 / 찜 공연 설정',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              settings: const RouteSettings(
                                name: DiaryRoutes.favoritePinned,
                              ),
                              builder: (context) =>
                                  const FavoritePinnedSettingsScreen(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? titleColor;

  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: titleColor ?? Colors.black87,
                ),
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeThumbColor: const Color(0xFF4E8F5A),
              activeTrackColor: const Color(0xFF7FB77E),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final String title;
  final VoidCallback onTap;

  const _MenuRow({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      pressScale: 0.985,
      tapScale: 1.02,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Colors.black.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 설정 인덱스 최상단에서 현재 로그인 상태(게스트/닉네임)를 미리 보여주는 배지.
/// 탭하면 "회원 설정" 시트(아래 [_MemberSettingsSheet])가 그대로 열립니다.
class _LoginStatusBanner extends StatelessWidget {
  final VoidCallback onTap;

  const _LoginStatusBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthService.instance,
      builder: (context, _) {
        final auth = AuthService.instance;
        final nickname = auth.currentUser?.nickname;
        final label = !auth.isGuest && nickname != null && nickname.isNotEmpty
            ? '$nickname님으로 로그인됨'
            : '게스트로 이용 중';

        return PressableScale(
          onTap: onTap,
          pressScale: 0.985,
          tapScale: 1.02,
          child: SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    auth.isGuest ? Icons.person_outline : Icons.verified_user,
                    size: 20,
                    color: Colors.black.withValues(alpha: 0.55),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: Colors.black.withValues(alpha: 0.45),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "회원 설정"을 누르면 아래에서 올라오는 계정 시트.
///
/// 게스트/카카오 로그인 상태에 따라 프로필 한 줄 + 액션 버튼 한 개만
/// 보여줍니다(게스트면 "카카오로 로그인", 카카오 로그인 상태면 "로그아웃").
/// [AuthService]/[KakaoLoginController]에 연결되어 실제로 동작합니다.
class _MemberSettingsSheet extends StatefulWidget {
  const _MemberSettingsSheet();

  @override
  State<_MemberSettingsSheet> createState() => _MemberSettingsSheetState();
}

class _MemberSettingsSheetState extends State<_MemberSettingsSheet> {
  final AuthService _auth = AuthService.instance;
  bool _busy = false;

  // 드래그 핸들 + 프로필 + 버튼만 담을 만큼의 시트 높이(여백 최소화).
  static const double _sheetHeight = 240;

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
      await _showAlertDialog('요청에 실패했어요', e.message);
    } catch (_) {
      // 위 타입들로 잡히지 않는 예상 밖의 오류(네트워크 단절 등)도 조용히
      // 삼키지 않고 사용자에게 알립니다.
      await _showAlertDialog('오류', '알 수 없는 오류가 발생했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 비정상 종료/실패를 알리는 확인용 알림창. 확인을 누르면 닫히고, 이미
  /// 상태는 실패 이전으로 유지된 채라(성공 시에만 토큰이 갱신됨) 그대로
  /// 원래 화면으로 복귀합니다.
  Future<void> _showAlertDialog(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  void _loginWithKakao() {
    _runGuarded(
      () => KakaoLoginController.instance.login(
        context: context,
        migrateFromGuest: _auth.isGuest,
      ),
      successMessage: '로그인됐어요.',
    );
  }

  void _logout() {
    _runGuarded(_auth.logout, successMessage: '로그아웃했어요.');
  }

  @override
  Widget build(BuildContext context) {
    final isGuest = _auth.isGuest;
    final currentUser = _auth.currentUser;

    return SizedBox(
      height: _sheetHeight,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              _ProfileRow(
                isGuest: isGuest,
                nickname: currentUser?.nickname,
                profileImageUrl: currentUser?.profileImageUrl,
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: isGuest
                    ? _KakaoLoginButton(
                        onTap: _busy ? null : _loginWithKakao,
                        busy: _busy,
                      )
                    : _LogoutButton(
                        onTap: _busy ? null : _logout,
                        busy: _busy,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 현재 계정 상태를 보여주는 프로필. 큰 프로필 사진 아래에 이름처럼
/// 텍스트를 세로로 붙여 보여줍니다. 게스트면 "게스트로 로그인 중"과 함께
/// 아직 계정이 연결되지 않았음을 알리는 빨간 느낌표 배지가 뜹니다.
class _ProfileRow extends StatelessWidget {
  final bool isGuest;
  final String? nickname;
  final String? profileImageUrl;

  const _ProfileRow({
    required this.isGuest,
    this.nickname,
    this.profileImageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = !isGuest && profileImageUrl != null && profileImageUrl!.isNotEmpty;
    final label = isGuest
        ? '게스트로 로그인 중'
        : (nickname != null && nickname!.isNotEmpty ? nickname! : '카카오 계정');

    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              radius: 44,
              backgroundColor: Colors.grey.shade300,
              backgroundImage: hasImage ? NetworkImage(profileImageUrl!) : null,
              child: hasImage
                  ? null
                  : Icon(Icons.person, color: Colors.grey.shade600, size: 46),
            ),
            if (isGuest)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    '!',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
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
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
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
            : const Text(
                '카카오로 로그인',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
      ),
    );
  }
}

class _LogoutButton extends StatelessWidget {
  final VoidCallback? onTap;
  final bool busy;

  const _LogoutButton({required this.onTap, this.busy = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Colors.white,
                ),
              )
            : const Text(
                '로그아웃',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
      ),
    );
  }
}
