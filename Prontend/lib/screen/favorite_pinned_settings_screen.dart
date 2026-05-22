import 'package:flutter/material.dart';

import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';

/// 설정 > 선호 아티스트 / 찜 공연 설정 화면
class FavoritePinnedSettingsScreen extends StatefulWidget {
  const FavoritePinnedSettingsScreen({super.key});

  @override
  State<FavoritePinnedSettingsScreen> createState() =>
      _FavoritePinnedSettingsScreenState();
}

class _FavoritePinnedSettingsScreenState
    extends State<FavoritePinnedSettingsScreen> {
  String? selectedArtist;
  String? selectedConcert;

  static const _artistOptions = <String>[
    'Artist',
    'Artist A',
    'Artist B',
    'Artist C',
  ];
  static const _concertOptions = <String>[
    'Concert',
    'Concert A',
    'Concert B',
    'Concert C',
  ];

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
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
              children: [
                _TopBar(
                  title: '선호 아티스트 / 찜 공연 설정',
                  onBack: () => Navigator.pop(context),
                ),
                const Divider(height: 1, thickness: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionTitle('선호 아티스트'),
                        const SizedBox(height: 10),
                        _DropdownField<String>(
                          hintText: 'Artist',
                          value: selectedArtist,
                          items: _artistOptions,
                          onChanged: (v) => setState(() => selectedArtist = v),
                        ),
                        const SizedBox(height: 14),
                        const _ThumbRow(labels: ['Artist', 'Artist', 'Artist']),
                        const SizedBox(height: 22),

                        const _SectionTitle('찜 공연'),
                        const SizedBox(height: 10),
                        _DropdownField<String>(
                          hintText: 'Concert',
                          value: selectedConcert,
                          items: _concertOptions,
                          onChanged: (v) => setState(() => selectedConcert = v),
                        ),
                        const SizedBox(height: 14),
                        const _ThumbRow(
                          labels: ['Concert', 'Concert', 'Concert'],
                        ),
                      ],
                    ),
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

class _TopBar extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _TopBar({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 10, 10, 10),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.chevron_left),
            color: Colors.black.withValues(alpha: 0.75),
          ),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w900,
        color: Colors.black.withValues(alpha: 0.35),
      ),
    );
  }
}

class _DropdownField<T> extends StatelessWidget {
  final String hintText;
  final T? value;
  final List<T> items;
  final ValueChanged<T?> onChanged;

  const _DropdownField({
    required this.hintText,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.black.withValues(alpha: 0.22),
          width: 1.3,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isExpanded: true,
          value: value,
          hint: Text(
            hintText,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: Colors.black.withValues(alpha: 0.25),
            ),
          ),
          icon: Icon(
            Icons.keyboard_arrow_down,
            color: Colors.black.withValues(alpha: 0.45),
          ),
          items: items
              .map(
                (e) => DropdownMenuItem<T>(
                  value: e,
                  child: Text(
                    e.toString(),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: Colors.black87,
                    ),
                  ),
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _ThumbRow extends StatelessWidget {
  final List<String> labels;

  const _ThumbRow({required this.labels});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          Expanded(child: _ThumbCard(label: labels[i])),
          if (i != labels.length - 1) const SizedBox(width: 12),
        ],
      ],
    );
  }
}

class _ThumbCard extends StatelessWidget {
  final String label;

  const _ThumbCard({required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.black.withValues(alpha: 0.20),
                width: 1.2,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            color: Colors.black.withValues(alpha: 0.25),
          ),
        ),
      ],
    );
  }
}
