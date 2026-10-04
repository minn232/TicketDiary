import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/external_share_service.dart';
import 'concert_after_share_card.dart';
import 'responsive_text.dart';

typedef ShareSheetPageBuilder =
    Widget Function({required bool back, required bool hideMemos});

enum ShareCardSides {
  front('앞면'),
  back('뒷면'),
  both('앞+뒤');

  final String label;
  const ShareCardSides(this.label);
}

const Color _ink = Color(0xFF463C2E);
const Color _sheetColor = Color(0xFFF6EFE0);

/// 공연후 페이지 공유 시트. 미리보기 카드를 그대로 찍어 저장/공유.
/// [frameScale]은 시트 안에서 다시 제공 (새 라우트라 [DiaryFrameScale]을 못 찾음).
Future<void> showConcertAfterShareSheet(
  BuildContext context, {
  required Size pageSize,
  required ShareSheetPageBuilder pageBuilder,
  required List<ImageProvider> images,
  required List<Future<Object?>> pending,
  required String title,
  required String infoText,
  required String fileStem,
  DiaryFrameScale? frameScale,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: _sheetColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ConcertAfterShareSheet(
      pageSize: pageSize,
      pageBuilder: pageBuilder,
      images: images,
      pending: pending,
      title: title,
      infoText: infoText,
      fileStem: fileStem,
      frameScale: frameScale,
    ),
  );
}

class ConcertAfterShareSheet extends StatefulWidget {
  final Size pageSize;
  final ShareSheetPageBuilder pageBuilder;
  final List<ImageProvider> images;
  final List<Future<Object?>> pending;

  /// 카카오톡 카드 제목 (공연명).
  final String title;
  final String infoText;
  final String fileStem;
  final DiaryFrameScale? frameScale;

  const ConcertAfterShareSheet({
    super.key,
    required this.pageSize,
    required this.pageBuilder,
    required this.images,
    required this.pending,
    this.title = '',
    required this.infoText,
    required this.fileStem,
    this.frameScale,
  });

  @override
  State<ConcertAfterShareSheet> createState() => _ConcertAfterShareSheetState();
}

class _ConcertAfterShareSheetState extends State<ConcertAfterShareSheet> {
  ShareCardAspect _aspect = ShareCardAspect.original;
  ShareCardSides _sides = ShareCardSides.front;
  bool _hideMemos = false;
  bool _ready = false;
  bool _busy = false;
  String? _message;
  late final Future<void> _loaded = _load();
  final GlobalKey _frontKey = GlobalKey();
  final GlobalKey _backKey = GlobalKey();
  final GlobalKey _moreKey = GlobalKey();
  final GlobalKey _instagramKey = GlobalKey();
  final GlobalKey _kakaoKey = GlobalKey();
  ShareApps _apps = (instagram: false, x: false, kakao: false);

  /// 채널 비율(인스타 피드 4:5, 카카오 카드 3:4)로 미리보기 뒤에 잠깐 그릴 때 그 비율.
  ShareCardAspect? _hiddenAspect;
  final GlobalKey _hiddenFrontKey = GlobalKey();
  final GlobalKey _hiddenBackKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    unawaited(
      ExternalShareService.installedApps().then((apps) {
        if (mounted) setState(() => _apps = apps);
      }),
    );
    unawaited(
      _loaded.whenComplete(() {
        if (mounted) setState(() => _ready = true);
      }),
    );
  }

  /// 사진 원본과 뒷면 데이터(타임테이블/셋리스트)가 다 올 때까지. 실패는 무시.
  Future<void> _load() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final waits = <Future<void>>[
      for (final image in widget.images)
        precacheImage(image, context, onError: (_, _) {}),
      for (final f in widget.pending) f.then<void>((_) {}, onError: (_) {}),
    ];
    await Future.wait(
      waits,
    ).timeout(const Duration(seconds: 10), onTimeout: () => const []);
  }

  List<(String, GlobalKey)> get _targets => [
    if (_sides != ShareCardSides.back) ('front', _frontKey),
    if (_sides != ShareCardSides.front) ('back', _backKey),
  ];

  /// 로딩과 자유메모 위치 복원이 끝난 뒤 찍음.
  Future<List<(String, Uint8List)>> _capture({
    double width = kShareImageWidth,
    List<(String, GlobalKey)>? targets,
  }) async {
    await _loaded;
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await WidgetsBinding.instance.endOfFrame;
    final shots = <(String, Uint8List)>[];
    for (final (name, key) in targets ?? _targets) {
      final boundary = key.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) continue;
      shots.add((name, await captureShareCardPng(boundary, width: width)));
    }
    return shots;
  }

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    String message;
    try {
      message = await action();
    } catch (_) {
      message = '이미지를 만들지 못했어요. 다시 시도해 주세요.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = message;
    });
  }

  Future<String> _save() async {
    final shots = await _capture();
    if (shots.isEmpty) return '이미지를 만들지 못했어요. 다시 시도해 주세요.';
    try {
      if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
        return '사진 저장 권한이 필요해요.';
      }
      final stamp = DateTime.now().millisecondsSinceEpoch;
      for (final (name, bytes) in shots) {
        await Gal.putImageBytes(
          bytes,
          name: '${widget.fileStem}_${name}_$stamp',
        );
      }
    } on GalException catch (e) {
      return e.type == GalExceptionType.accessDenied
          ? '사진 저장 권한이 필요해요.'
          : '사진첩에 저장하지 못했어요.';
    }
    return shots.length > 1 ? '사진첩에 2장 저장했어요.' : '사진첩에 저장했어요.';
  }

  /// 시스템 공유창 (인스타 DM, 그 밖의 앱).
  Future<String> _more() async {
    final shots = await _capture();
    if (shots.isEmpty) return '이미지를 만들지 못했어요. 다시 시도해 주세요.';
    // 다음 공유 때 비움 (받는 앱이 나중에 읽을 수 있음).
    final temp = await getTemporaryDirectory();
    final dir = Directory('${temp.path}/share_export');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final files = <XFile>[];
    for (final (name, bytes) in shots) {
      final file = File('${dir.path}/${widget.fileStem}_$name.png');
      await file.writeAsBytes(bytes);
      files.add(XFile(file.path, mimeType: 'image/png'));
    }
    // 아이패드는 공유창 위치 필수.
    final box = _moreKey.currentContext?.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: files,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
    return '';
  }

  /// 채널 비율로 미리보기 뒤에 그린 카드를 찍음. [firstOnly]면 첫 번째 면만.
  Future<List<(String, Uint8List)>> _captureAs(
    ShareCardAspect aspect, {
    double width = kShareImageWidth,
    bool firstOnly = false,
  }) async {
    setState(() => _hiddenAspect = aspect);
    try {
      final targets = [
        for (final (name, _) in _targets)
          (name, name == 'back' ? _hiddenBackKey : _hiddenFrontKey),
      ];
      return await _capture(
        width: width,
        targets: firstOnly ? targets.take(1).toList() : targets,
      );
    } finally {
      if (mounted) setState(() => _hiddenAspect = null);
    }
  }

  static const String _failed = '이미지를 만들지 못했어요. 다시 시도해 주세요.';

  /// 스토리는 스티커 한 장만 받아서 앞+뒤면 기울여 겹친 한 장으로 합침 (폭 900).
  Future<String> _story() async {
    final shots = await _capture(width: 900);
    if (shots.isEmpty) return _failed;
    final sticker = shots.length > 1
        ? await composeTiltedPairPng(shots[0].$2, shots[1].$2)
        : shots.first.$2;
    final ok = await ExternalShareService.instagramStory(sticker);
    return ok ? '' : '인스타그램 스토리를 열지 못했어요.';
  }

  /// 인스타 피드는 항상 4:5 (더 긴 세로는 잘림). 앞+뒤면 캐러셀.
  Future<String> _feed() async {
    final shots = await _captureAs(ShareCardAspect.feed);
    if (shots.isEmpty) return _failed;
    final ok = await ExternalShareService.instagramFeed([
      for (final (_, png) in shots) png,
    ]);
    return ok ? '' : '인스타그램 피드를 열지 못했어요.';
  }

  Future<String> _x() async {
    final shots = await _capture();
    if (shots.isEmpty) return _failed;
    final ok = await ExternalShareService.x([
      for (final (_, png) in shots) png,
    ]);
    return ok ? '' : 'X를 열지 못했어요.';
  }

  /// 이미지 그대로 (원본 비율, 앞+뒤면 2장).
  Future<String> _kakaoPhoto() async {
    final shots = await _capture();
    if (shots.isEmpty) return _failed;
    final ok = await ExternalShareService.kakaoPhoto([
      for (final (_, png) in shots) png,
    ]);
    return ok ? '' : '카카오톡을 열지 못했어요.';
  }

  /// 카카오 카드는 3:4 (더 긴 세로는 잘림). 업로드 한도(5MB) 때문에 폭 800, 첫 번째 면만.
  Future<String> _kakaoCard() async {
    final shots = await _captureAs(
      ShareCardAspect.kakao,
      width: 800,
      firstOnly: true,
    );
    if (shots.isEmpty) return _failed;
    try {
      await ExternalShareService.shareKakaoCard(
        png: shots.first.$2,
        title: widget.title,
        description: widget.infoText,
      );
    } catch (e) {
      // 콘솔 설정 문제를 알 수 있게 원문도 표시.
      debugPrint('[Kakao] 공유 실패: $e');
      return '카카오톡 공유를 열지 못했어요.\n$e';
    }
    return '';
  }

  /// 아이콘 위에 띄우는 두 갈래 선택 (인스타 스토리/피드, 카톡 카드/사진).
  Future<void> _choose(
    GlobalKey anchor,
    List<(String, IconData, String, Future<String> Function())> options,
  ) async {
    final box = anchor.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final picked = await showMenu<Future<String> Function()>(
      context: context,
      color: _sheetColor,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: [
        for (final (title, icon, subtitle, action) in options)
          PopupMenuItem(
            value: action,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon, color: _ink),
              title: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _ink,
                ),
              ),
              subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
            ),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked == _feed && !await _confirmFeedRatio()) return;
    await _run(picked);
  }

  static const String _feedHintHiddenKey =
      'share_instagram_feed_ratio_hint_hidden';

  /// 인스타로 넘어가기 전 '비율'을 눌러 4:5로 바꾸라는 안내 ("다시 보지 않기" 가능).
  Future<bool> _confirmFeedRatio() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_feedHintHiddenKey) ?? false) return true;
    } catch (_) {}
    if (!mounted) return false;
    var hide = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: _sheetColor,
          title: const Text('인스타에서 비율을 바꿔주세요'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '인스타 편집 화면은 처음에 정사각형으로 잘라서 보여줘요.\n'
                "아래쪽 도구 줄의 '비율'을 눌러 4:5로 바꾸면 페이지 전체가 올라가요.",
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: hide,
                onChanged: (v) => setDialogState(() => hide = v ?? false),
                title: const Text('다시 보지 않기'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('인스타로 가기'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && hide) {
      try {
        await prefs?.setBool(_feedHintHiddenKey, true);
      } catch (_) {}
    }
    return ok == true;
  }

  Widget _card(bool back, GlobalKey key, {ShareCardAspect? aspect}) {
    Widget card = RepaintBoundary(
      key: key,
      child: ConcertAfterShareCard(
        pageSize: widget.pageSize,
        aspect: aspect ?? _aspect,
        infoText: widget.infoText,
        page: widget.pageBuilder(back: back, hideMemos: _hideMemos),
      ),
    );
    final scale = widget.frameScale;
    if (scale != null) {
      card = DiaryFrameScale(
        scale: scale.scale,
        marginEachSide: scale.marginEachSide,
        child: card,
      );
    }
    return card;
  }

  Widget _preview(double height) {
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          // 미리보기 뒤에 가려서 그림.
          if (_hiddenAspect != null)
            Positioned.fill(
              child: Row(
                children: [
                  for (final (name, _) in _targets)
                    Expanded(
                      child: FittedBox(
                        child: _card(
                          name == 'back',
                          name == 'back' ? _hiddenBackKey : _hiddenFrontKey,
                          aspect: _hiddenAspect,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          IgnorePointer(
            child: ColoredBox(
              color: _sheetColor,
              child: Row(
                children: [
                  for (final (name, key) in _targets)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: FittedBox(child: _card(name == 'back', key)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!_ready)
            const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
        ],
      ),
    );
  }

  Widget _options<T>(
    String title,
    List<T> values,
    T selected,
    String Function(T) label,
    ValueChanged<T> onSelected,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            children: [
              for (final v in values)
                ChoiceChip(
                  label: Text(label(v)),
                  selected: v == selected,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: _busy
                      ? null
                      : (_) {
                          // 이전 결과 문구 지움.
                          _message = null;
                          onSelected(v);
                        },
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final enabled = _ready && !_busy;
    // 제스처 바/내비게이션 바 위로.
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: _ink.withValues(alpha: .25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '공유하기',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: _ink,
            ),
          ),
          const SizedBox(height: 12),
          // 화면이 낮으면(폰 가로 등) 미리보기가 줄어듦.
          Flexible(child: _preview(height * .48)),
          const SizedBox(height: 14),
          _options<ShareCardAspect>(
            '비율',
            ShareCardAspect.choices,
            _aspect,
            (v) => v.label,
            (v) => setState(() => _aspect = v),
          ),
          _options<ShareCardSides>(
            '면',
            ShareCardSides.values,
            _sides,
            (v) => v.label,
            (v) => setState(() => _sides = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text(
              '자유메모 숨기기',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _ink,
              ),
            ),
            value: _hideMemos,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _message = null;
                    _hideMemos = v;
                  }),
          ),
          if (_busy || (_message != null && _message!.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _busy ? '이미지를 만드는 중이에요…' : _message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: _ink.withValues(alpha: .8),
                ),
              ),
            ),
          // 설치된 앱만. 누르면 그 앱의 게시/보내기 화면으로 바로.
          Row(
            children: [
              _ShareTarget(
                label: '사진첩 저장',
                icon: const _TargetIcon(
                  color: _ink,
                  child: Icon(Icons.download_rounded, color: Colors.white),
                ),
                onTap: enabled ? () => _run(_save) : null,
              ),
              if (_apps.instagram)
                _ShareTarget(
                  key: _instagramKey,
                  label: '인스타그램',
                  icon: _TargetIcon(
                    child: SvgPicture.asset(
                      'assets/images/share/instagram.svg',
                    ),
                  ),
                  onTap: enabled
                      ? () => _choose(_instagramKey, [
                          (
                            '스토리',
                            Icons.amp_stories_outlined,
                            '스티커로 올리기',
                            _story,
                          ),
                          ('피드', Icons.grid_on, '4:5 게시물 (앞+뒤는 여러 장)', _feed),
                        ])
                      : null,
                ),
              if (_apps.x)
                _ShareTarget(
                  label: 'X',
                  icon: _TargetIcon(
                    color: Colors.black,
                    padding: 12,
                    child: SvgPicture.asset(
                      'assets/images/share/x.svg',
                      colorFilter: const ColorFilter.mode(
                        Colors.white,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                  onTap: enabled ? () => _run(_x) : null,
                ),
              if (_apps.kakao)
                _ShareTarget(
                  key: _kakaoKey,
                  label: '카카오톡',
                  icon: _TargetIcon(
                    child: SvgPicture.asset(
                      'assets/images/share/kakaotalk.svg',
                    ),
                  ),
                  onTap: enabled
                      ? () => _choose(_kakaoKey, [
                          (
                            '카드',
                            Icons.style_outlined,
                            '앱에서 보기 버튼이 있는 카드',
                            _kakaoCard,
                          ),
                          (
                            '사진',
                            Icons.image_outlined,
                            '이미지 그대로 보내기',
                            _kakaoPhoto,
                          ),
                        ])
                      : null,
                ),
              _ShareTarget(
                key: _moreKey,
                label: '더보기',
                icon: _TargetIcon(
                  color: Colors.white,
                  border: _ink.withValues(alpha: .2),
                  child: const Icon(Icons.more_horiz, color: _ink),
                ),
                onTap: enabled ? () => _run(_more) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 공유 대상 아이콘 + 이름.
class _ShareTarget extends StatelessWidget {
  final String label;
  final Widget icon;
  final VoidCallback? onTap;

  const _ShareTarget({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Opacity(
        opacity: onTap == null ? .45 : 1,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: _ink,
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

/// 둥근 사각형 아이콘 틀 (브랜드 로고는 자체 배경이라 색 없음).
class _TargetIcon extends StatelessWidget {
  final Widget child;
  final Color? color;
  final Color? border;
  final double padding;

  const _TargetIcon({
    required this.child,
    this.color,
    this.border,
    this.padding = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      padding: EdgeInsets.all(padding),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: border == null ? null : Border.all(color: border!),
      ),
      child: child,
    );
  }
}
