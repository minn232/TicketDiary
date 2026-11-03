import 'package:flutter/material.dart';
import '../widgets/audio_volume_settings.dart';
import '../widgets/member_settings_sheet.dart';

import 'connections_screen.dart';
import 'notifications_screen.dart';
import '../services/api_client.dart';
import '../services/fcm_service.dart';
import '../services/app_settings_store.dart';
import '../services/auth_service.dart';
import '../services/music_service_links.dart';
import '../services/notification_settings_service.dart';
import '../services/notifications_service.dart';
import 'diary_screen.dart' show buildUpcomingTicketLandscapePanel;
import '../widgets/diary_landscape_cover_panel.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/paper_style.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/responsive_text.dart';

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
    FcmService.instance.changes.addListener(_loadUnreadNotifications);
  }

  @override
  void dispose() {
    FcmService.instance.changes.removeListener(_loadUnreadNotifications);
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
      builder: (context) => const MemberSettingsSheet(),
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
                              children: const [AudioVolumeSettings()],
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
                          if (FcmService.supported)
                            ValueListenableBuilder<String>(
                              valueListenable: FcmService.instance.status,
                              builder: (context, status, _) => ListTile(
                                title: Text(
                                  status,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: PaperColors.muted,
                                  ),
                                ),
                                trailing: const Icon(
                                  Icons.settings_outlined,
                                  color: PaperColors.muted,
                                  size: 20,
                                ),
                                onTap: () async {
                                  try {
                                    await FcmService.instance
                                        .openSystemSettings();
                                  } catch (_) {
                                    if (context.mounted) {
                                      showPaperSnackBar(
                                        context,
                                        '휴대폰 설정에서 알림 권한을 확인해주세요.',
                                      );
                                    }
                                  }
                                },
                              ),
                            ),
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
