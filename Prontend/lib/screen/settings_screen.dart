import 'package:flutter/material.dart';

import 'favorite_pinned_settings_screen.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/pressable_scale.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool showExpectedSetlist = true;

  bool pushExpanded = false;
  bool pushDayBefore = false;
  bool pushOnTheDay = false;
  bool pushTicketDelivery = false;
  bool pushFavArtistConcert = false;
  bool pushPinnedConcert = false;

  static const _divider = Divider(height: 1, thickness: 1);

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
                        value: showExpectedSetlist,
                        onChanged: (v) =>
                            setState(() => showExpectedSetlist = v),
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
                        onTap: () {
                          // TODO: 회원 설정 화면으로 이동
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
