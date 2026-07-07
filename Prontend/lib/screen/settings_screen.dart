import 'package:flutter/material.dart';

import 'favorite_pinned_settings_screen.dart';
import '../services/app_settings_store.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/pressable_scale.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AppSettingsStore _appSettings = AppSettingsStore.instance;

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
                              onChanged: (v) =>
                                  setState(() => pushDayBefore = v),
                            ),
                            _divider,
                            _SwitchRow(
                              title: '당일날 알림',
                              value: pushOnTheDay,
                              onChanged: (v) =>
                                  setState(() => pushOnTheDay = v),
                            ),
                            _divider,
                            _SwitchRow(
                              title: '티켓배송일 알림',
                              value: pushTicketDelivery,
                              onChanged: (v) =>
                                  setState(() => pushTicketDelivery = v),
                            ),
                            _divider,
                            _SwitchRow(
                              title: '선호 아티스트 공연 알림',
                              value: pushFavArtistConcert,
                              onChanged: (v) =>
                                  setState(() => pushFavArtistConcert = v),
                            ),
                            _divider,
                            _SwitchRow(
                              title: '찜 공연 알림',
                              value: pushPinnedConcert,
                              onChanged: (v) =>
                                  setState(() => pushPinnedConcert = v),
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
                      _divider,
                      _MenuRow(
                        title: '회원 설정',
                        onTap: () => _openMemberSettingsSheet(context),
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

  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
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
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Colors.black87,
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

/// "회원 설정"을 누르면 아래에서 올라오는 계정 전환/로그인 시트.
///
/// 계정 목록(Profile/Guest)과 카카오 OAuth/Login 버튼은 레이아웃만 준비된
/// 상태이며, 실제 로그인/계정 전환/로그아웃 로직은 아직 연결되지 않았습니다.
class _MemberSettingsSheet extends StatelessWidget {
  const _MemberSettingsSheet();

  // 원래 내용물 높이(약 260) 대비 1.5배로 시트 높이를 키웁니다.
  static const double _baseHeight = 260;
  static const double _heightScale = 1.5;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _baseHeight * _heightScale,
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
              _AccountRow(
                label: 'Profile',
                isActive: true,
                onRemove: () {
                  // TODO: 계정 로그아웃/제거 연동
                },
              ),
              const SizedBox(height: 14),
              _AccountRow(
                label: 'Guest',
                isActive: false,
                onRemove: () {
                  // TODO: 게스트 계정 제거 연동
                },
              ),
              const Spacer(),
              Row(
                children: [
                  _KakaoOAuthButton(
                    onTap: () {
                      // TODO: 카카오 OAuth 로그인 연동
                    },
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _LoginButton(
                      onTap: () {
                        // TODO: 로그인 화면/로직 연동
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onRemove;

  const _AccountRow({
    required this.label,
    required this.isActive,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: Colors.grey.shade300,
          child: Icon(Icons.person, color: Colors.grey.shade600, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        if (isActive) ...[
          const Icon(Icons.check, color: Color(0xFF34C759)),
          const SizedBox(width: 10),
        ],
        IconButton(
          onPressed: onRemove,
          icon: const Icon(Icons.close, size: 20),
          color: Colors.black.withValues(alpha: 0.55),
        ),
      ],
    );
  }
}

class _KakaoOAuthButton extends StatelessWidget {
  final VoidCallback onTap;

  const _KakaoOAuthButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: const BoxDecoration(
          color: Color(0xFFFEE500),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.chat_bubble,
          color: Color(0xFF3C1E1E),
          size: 24,
        ),
      ),
    );
  }
}

class _LoginButton extends StatelessWidget {
  final VoidCallback onTap;

  const _LoginButton({required this.onTap});

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
        child: const Text(
          'Login',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}
