import 'package:flutter/material.dart';
import '../widgets/media_volume_control.dart';

import 'connections_screen.dart';
import 'notifications_screen.dart';
import '../services/api_client.dart';
import '../services/app_settings_store.dart';
import '../services/auth_service.dart';
import '../services/guest_migration_service.dart';
import '../services/kakao_login_controller.dart';
import '../services/local_ticket_store.dart';
import '../services/music_service_links.dart';
import '../services/notification_settings_service.dart';
import '../services/notifications_service.dart';
import '../services/ticket_service.dart';
import 'diary_screen.dart' show buildUpcomingTicketLandscapePanel;
import '../widgets/diary_landscape_cover_panel.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/paper_style.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/responsive_text.dart';

/// 게스트 데이터가 있는 상태에서 카카오 로그인을 시도할 때, 그 데이터를
/// 가져올지("migrate") 그대로 두고 새 카카오 계정으로 시작할지
/// ("startFresh") 사용자가 고르는 선택지.
enum _MigrationChoice { migrate, startFresh }

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AppSettingsStore _appSettings = AppSettingsStore.instance;
  final NotificationSettingsService _notifSettingsService =
      NotificationSettingsService();

  // 하위 알림 5개를 바로 볼 수 있도록 기본값을 펼친 상태로 둡니다.
  bool pushExpanded = false;
  bool _audioExpanded = false;
  bool _listeningExpanded = false;
  bool pushDayBefore = false;
  bool pushOnTheDay = false;
  bool pushTicketDelivery = false;
  bool pushFavArtistConcert = false;
  bool pushPinnedConcert = false;

  static const _divider = Divider(
    height: 1,
    thickness: 1,
    color: Color(0x143B2A20),
  );

  // [백엔드 수정] 알림함 메뉴 배지 - 안 읽은 알림 수(실패하면 배지 없이).
  int _unreadNotifications = 0;

  Future<void> _loadUnreadNotifications() async {
    try {
      final count = await NotificationsService().unreadCount();
      if (mounted) setState(() => _unreadNotifications = count);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _appSettings.load();
    _appSettings.addListener(_onAppSettingsChanged);
    _loadNotificationSettings();
    _loadUnreadNotifications();
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

  // [백엔드 수정]
  // show_predicted_setlist가 이제 백엔드에 저장되므로, 다른 알림 토글들과
  // 마찬가지로 저장 실패 시 안내를 띄웁니다(값 되돌리기는 AppSettingsStore가
  // 이미 처리해 _onAppSettingsChanged로 반영됨).
  Future<void> _setShowExpectedSetlist(bool v) async {
    try {
      await _appSettings.setShowExpectedSetlist(v);
    } catch (e) {
      _showSaveError(e, label: '예상 셋리 노출 여부');
    }
  }

  // 기기 로컬 저장이라 실패할 일이 거의 없지만(서버 왕복 없음), 다른 설정들과
  // 형태를 맞춰 실패 안내만 동일하게 남겨둠.
  Future<void> _setPreferredMusicService(MusicService v) async {
    try {
      await _appSettings.setPreferredMusicService(v);
    } catch (e) {
      _showSaveError(e, label: '기본 음악 앱');
    }
  }

  // [백엔드 수정] 티켓 열 때 노래 재생 토글 추가.
  Future<void> _setPlayTicketPreview(bool v) async {
    try {
      await _appSettings.setPlayTicketPreview(v);
    } catch (e) {
      _showSaveError(e, label: '티켓 열 때 노래 재생');
    }
  }

  Future<void> _loadNotificationSettings() async {
    try {
      final s = await _notifSettingsService.fetch();
      if (!mounted) return;
      setState(() {
        pushDayBefore = s.dayBefore;
        pushOnTheDay = s.concertDay;
        pushTicketDelivery = s.delivery;
        pushFavArtistConcert = s.newConcert;
        pushPinnedConcert = s.ticketing;
      });
    } catch (_) {
      // 조회에 실패하면 기본값(꺼짐)으로 남겨둡니다. 스위치를 직접 켜면
      // 다시 저장을 시도합니다.
    }
  }

  /// [백엔드 수정]
  /// - `before_concert` → `day_before`/`concert_day`로 분리
  Future<void> _setDayBefore(bool v) async {
    final prev = pushDayBefore;
    setState(() => pushDayBefore = v);
    try {
      await _notifSettingsService.update(dayBefore: v);
    } catch (e) {
      if (!mounted) return;
      setState(() => pushDayBefore = prev);
      _showSaveError(e);
    }
  }

  Future<void> _setConcertDay(bool v) async {
    final prev = pushOnTheDay;
    setState(() => pushOnTheDay = v);
    try {
      await _notifSettingsService.update(concertDay: v);
    } catch (e) {
      if (!mounted) return;
      setState(() => pushOnTheDay = prev);
      _showSaveError(e);
    }
  }

  Future<void> _setDelivery(bool v) async {
    final prev = pushTicketDelivery;
    setState(() => pushTicketDelivery = v);
    try {
      await _notifSettingsService.update(delivery: v);
    } catch (e) {
      if (!mounted) return;
      setState(() => pushTicketDelivery = prev);
      _showSaveError(e);
    }
  }

  /// [백엔드 수정]
  /// 선호 아티스트 공연 알림 서버 저장
  Future<void> _setFavArtistConcert(bool v) async {
    final prev = pushFavArtistConcert;
    setState(() => pushFavArtistConcert = v);
    try {
      await _notifSettingsService.update(newConcert: v);
    } catch (e) {
      if (!mounted) return;
      setState(() => pushFavArtistConcert = prev);
      _showSaveError(e);
    }
  }

  /// [백엔드 수정]
  /// 찜 공연 알림 서버 저장
  Future<void> _setPinnedConcert(bool v) async {
    final prev = pushPinnedConcert;
    setState(() => pushPinnedConcert = v);
    try {
      await _notifSettingsService.update(ticketing: v);
    } catch (e) {
      if (!mounted) return;
      setState(() => pushPinnedConcert = prev);
      _showSaveError(e);
    }
  }

  void _showSaveError(Object e, {String label = '알림 설정'}) {
    if (!mounted) return;
    final message = e is ApiException ? e.message : '잠시 후 다시 시도해주세요.';
    showPaperSnackBar(context, '$label 저장에 실패했어요: $message');
  }

  void _openMemberSettingsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: PaperColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => const _MemberSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      pageTextureEnabled: false,
      isTabRoot: true,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.settings),
      landscapeCompanionPanel: DiaryLandscapeCoverPanel(
        child: buildUpcomingTicketLandscapePanel(),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 18, 18, 18),
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.passthrough,
          children: [
            Container(
              decoration: BoxDecoration(
                color: PaperColors.card,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: PaperColors.ink.withValues(alpha: 0.10),
                ),
                boxShadow: [
                  BoxShadow(
                    color: PaperColors.ink.withValues(alpha: 0.12),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // [백엔드 수정]
                    // Builder로 감싸 DiaryPageFrame 자손 context에서 sp()를 계산하도록
                    // 수정 — 이전엔 State 레벨 context를 써서 DiaryFrameScale을 못 찾고
                    // MediaQuery 폭(가로모드 2페이지 스프레드에선 페이지 한 장이 아니라
                    // 전체 화면 폭)으로 fallback해, 가로모드에서 이 글자만 과하게 커지던
                    // 버그가 있었음([[diary_frame_scale_context_scoping_bug]] 패턴).
                    Builder(
                      builder: (innerContext) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                        child: Text(
                          '설정',
                          style: TextStyle(
                            fontSize: innerContext.sp(18),
                            fontWeight: FontWeight.w900,
                            color: PaperColors.ink,
                          ),
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
                          const _SectionLabel('소리·감상'),
                          Theme(
                            data: Theme.of(
                              context,
                            ).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              key: const PageStorageKey(
                                'audio-volume-settings',
                              ),
                              initiallyExpanded: _audioExpanded,
                              onExpansionChanged: (value) =>
                                  setState(() => _audioExpanded = value),
                              tilePadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              childrenPadding: const EdgeInsets.fromLTRB(
                                16,
                                8,
                                16,
                                8,
                              ),
                              title: Builder(
                                builder: (innerContext) => Text(
                                  '소리 설정',
                                  style: TextStyle(
                                    fontSize: innerContext.sp(15),
                                    fontWeight: FontWeight.w800,
                                    color: PaperColors.ink,
                                  ),
                                ),
                              ),
                              trailing: Icon(
                                _audioExpanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_right,
                                color: PaperColors.muted,
                              ),
                              children: const [MediaVolumeControl()],
                            ),
                          ),
                          _divider,
                          Theme(
                            data: Theme.of(context).copyWith(
                              dividerColor: Colors.transparent,
                              splashColor: Colors.transparent,
                              highlightColor: Colors.transparent,
                            ),
                            child: ExpansionTile(
                              key: const PageStorageKey(
                                'concert-listening-settings',
                              ),
                              initiallyExpanded: _listeningExpanded,
                              onExpansionChanged: (value) =>
                                  setState(() => _listeningExpanded = value),
                              trailing: Icon(
                                _listeningExpanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_right,
                                color: PaperColors.muted,
                              ),
                              tilePadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              childrenPadding: EdgeInsets.zero,
                              title: Builder(
                                builder: (innerContext) => Text(
                                  '공연 감상 설정',
                                  style: TextStyle(
                                    fontSize: innerContext.sp(15),
                                    fontWeight: FontWeight.w800,
                                    color: PaperColors.ink,
                                  ),
                                ),
                              ),
                              children: [
                                _SwitchRow(
                                  title: '예상 셋리 노출 여부',
                                  value: _appSettings.showExpectedSetlist,
                                  onChanged: _setShowExpectedSetlist,
                                  indent: true,
                                ),
                                _divider,
                                _SwitchRow(
                                  title: '티켓 열 때 노래 재생',
                                  value: _appSettings.playTicketPreview,
                                  onChanged: _setPlayTicketPreview,
                                  indent: true,
                                ),
                                _divider,
                                _MusicServiceRow(
                                  value: _appSettings.preferredMusicService,
                                  onChanged: _setPreferredMusicService,
                                ),
                              ],
                            ),
                          ),
                          const _SectionLabel('알림'),
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
                              // [백엔드 수정] "설정" 타이틀과 같은 이유로 Builder 추가.
                              title: Builder(
                                builder: (innerContext) => Text(
                                  '푸시 알림',
                                  style: TextStyle(
                                    fontSize: innerContext.sp(15),
                                    fontWeight: FontWeight.w800,
                                    color: PaperColors.ink,
                                  ),
                                ),
                              ),
                              trailing: Icon(
                                pushExpanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_right,
                                color: PaperColors.muted,
                              ),
                              children: [
                                _divider,
                                _SwitchRow(
                                  title: '하루 전 알림',
                                  value: pushDayBefore,
                                  onChanged: _setDayBefore,
                                  indent: true,
                                ),
                                _divider,
                                _SwitchRow(
                                  title: '공연 당일 알림',
                                  value: pushOnTheDay,
                                  onChanged: _setConcertDay,
                                  indent: true,
                                ),
                                _divider,
                                _SwitchRow(
                                  title: '티켓 배송일 알림',
                                  value: pushTicketDelivery,
                                  onChanged: _setDelivery,
                                  indent: true,
                                ),
                                _divider,
                                // [백엔드 수정]
                                // new_concert로 서버 저장
                                _SwitchRow(
                                  title: '선호 아티스트 공연 알림',
                                  value: pushFavArtistConcert,
                                  onChanged: _setFavArtistConcert,
                                  indent: true,
                                ),
                                _divider,
                                // [백엔드 수정]
                                // ticketing으로 서버 저장
                                _SwitchRow(
                                  title: '찜 공연 알림',
                                  value: pushPinnedConcert,
                                  onChanged: _setPinnedConcert,
                                  indent: true,
                                ),
                              ],
                            ),
                          ),
                          _divider,
                          // [백엔드 수정]
                          // GET/PATCH/DELETE /notifications 신규 진입 메뉴 추가.
                          // Builder로 감싼 이유: DiaryFrameScale 조회에 필요한
                          // 자손 context를 얻기 위함.
                          Builder(
                            builder: (menuContext) => _MenuRow(
                              title: '알림함',
                              badgeCount: _unreadNotifications,
                              // [백엔드 수정] 닫고 나면 읽은 만큼 배지 갱신.
                              onTap: () async {
                                await NotificationsScreen.show(
                                  menuContext,
                                  frameScale:
                                      DiaryFrameScale.maybeOf(menuContext) ??
                                      diaryScaleFromMediaQuery(menuContext),
                                );
                                _loadUnreadNotifications();
                              },
                            ),
                          ),
                          const _SectionLabel('친구'),
                          // [백엔드 수정]
                          // 폰 맞대기로 연결된 친구 목록·연결 카드.
                          Builder(
                            builder: (menuContext) => _MenuRow(
                              title: '연결된 친구',
                              onTap: () => ConnectionsScreen.show(
                                menuContext,
                                frameScale:
                                    DiaryFrameScale.maybeOf(menuContext) ??
                                    diaryScaleFromMediaQuery(menuContext),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Positioned(
              top: -7,
              left: 0,
              right: 0,
              child: Center(child: MaskingTape(width: 64, height: 16)),
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
  // [백엔드 수정] 0보다 크면 오른쪽에 숫자 배지(알림함 안 읽은 수).
  final int badgeCount;

  const _MenuRow({
    required this.title,
    required this.onTap,
    this.badgeCount = 0,
  });

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
                  style: TextStyle(
                    fontSize: context.sp(15),
                    fontWeight: FontWeight.w800,
                    color: PaperColors.ink,
                  ),
                ),
              ),
              if (badgeCount > 0)
                Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: PaperColors.stamp,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badgeCount > 99 ? '99+' : '$badgeCount',
                    style: TextStyle(
                      fontSize: context.sp(11),
                      fontWeight: FontWeight.w900,
                      color: PaperColors.card,
                    ),
                  ),
                ),
              const Icon(Icons.chevron_right, color: PaperColors.muted),
            ],
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
  // "푸쉬 알림" 하위 항목처럼 상위 줄과 구분되게 왼쪽으로 들여써야 할 때 true.
  final bool indent;

  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.indent = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: EdgeInsets.only(left: indent ? 32 : 16, right: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: context.sp(indent ? 14 : 15),
                  fontWeight: indent ? FontWeight.w700 : FontWeight.w800,
                  color: PaperColors.ink,
                ),
              ),
            ),
            // 초록 기본 스위치 대신 갈색 잉크
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeThumbColor: PaperColors.card,
              activeTrackColor: PaperColors.ink.withValues(alpha: 0.8),
              inactiveThumbColor: PaperColors.muted,
              inactiveTrackColor: PaperColors.tile,
              trackOutlineColor: WidgetStatePropertyAll(
                PaperColors.ink.withValues(alpha: 0.18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 셋리스트 포스트잇/기사 아이콘에 쓰일 기본 음악 서비스 선택.
/// 포스트잇에서 꾹 눌러 바꾸는 건 화면 하나짜리 임시값이고, 여기서 바꾸는
/// 값만 앱 전역 기본값으로 저장됨([AppSettingsStore.preferredMusicService]).
class _MusicServiceRow extends StatelessWidget {
  final MusicService value;
  final ValueChanged<MusicService> onChanged;

  const _MusicServiceRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 32, right: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '기본 음악 앱',
                style: TextStyle(
                  fontSize: context.sp(14),
                  fontWeight: FontWeight.w700,
                  color: PaperColors.ink,
                ),
              ),
            ),
            for (final service in MusicService.values) ...[
              _ServiceIconButton(
                service: service,
                selected: service == value,
                onTap: () => onChanged(service),
              ),
              if (service != MusicService.values.last) const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class _ServiceIconButton extends StatelessWidget {
  final MusicService service;
  final bool selected;
  final VoidCallback onTap;

  const _ServiceIconButton({
    required this.service,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: selected
              ? service.color.withValues(alpha: 0.15)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? service.color
                : PaperColors.ink.withValues(alpha: 0.15),
            width: selected ? 1.4 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Opacity(
          opacity: selected ? 1 : 0.55,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.asset(service.iconAsset, width: 18, height: 18),
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
            ? nickname
            : '게스트로 이용 중';

        final isGuest = auth.isGuest;
        return PressableScale(
          onTap: onTap,
          pressScale: 0.985,
          tapScale: 1.02,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
            decoration: BoxDecoration(
              color: PaperColors.tile,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: PaperColors.ink.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              children: [
                ProfileAvatar(
                  size: context.rs(46),
                  name: isGuest ? null : nickname,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.sp(15),
                          fontWeight: FontWeight.w900,
                          color: PaperColors.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isGuest ? '눌러서 카카오로 로그인' : '카카오 계정',
                        style: TextStyle(
                          fontSize: context.sp(12),
                          fontWeight: FontWeight.w600,
                          color: isGuest
                              ? PaperColors.stamp
                              : PaperColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: PaperColors.muted),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 설정 묶음 제목(소리·감상 / 알림 / 친구). 줄마다 아이콘을 다는 대신 묶음
/// 위에 테이프 라벨을 붙여 구분함.
class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 20, 16, 2),
      child: Align(alignment: Alignment.centerLeft, child: TapeLabel(text)),
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
  // 게스트도 이제 서버에 티켓을 저장하므로(TicketService 참고), 옮길 데이터가
  // 있는지 로컬(LocalTicketStore, 레거시 전용)만 보면 안 되고 서버 티켓
  // 개수도 같이 확인해야 함. 이전엔 로컬만 봐서, 게스트 기능 동등화 이후
  // 서버에만 티켓이 있는(=지금은 거의 항상 이 경우) 상황에서 이 다이얼로그가
  // 아예 안 뜨고 조용히 일반 로그인으로 빠지면서 그 티켓들이 버려지는
  // 버그가 있었음(사용자가 실기기 테스트로 발견).
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
      title: '게스트로 등록된 데이터를 옮기시겠습니까?',
      message:
          '게스트로 이용하며 추가한 티켓이 있어요.\n'
          '카카오 계정으로 로그인하면서 이 데이터를 그대로 옮길까요?\n\n'
          '삭제하기를 선택하면 이 티켓들은 카카오 계정에 반영되지 않아요(다시 게스트로 돌아가야 확인할 수 있어요).',
      tapeTint: PaperColors.tapeMustard,
      actions: const [
        PaperDialogAction(label: '취소', style: PaperButtonStyle.quiet),
        PaperDialogAction(
          label: '삭제하기',
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
      message: '정말 로그아웃 하시겠습니까?',
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
        ? '게스트로 로그인 중'
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
          isGuest ? '아직 계정이 연결되지 않았어요' : '카카오 계정으로 로그인됨',
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
