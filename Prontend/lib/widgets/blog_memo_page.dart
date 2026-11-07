import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/blog_draft_service.dart';
import 'paper_style.dart';
import 'responsive_text.dart';

const Color _ink = Color(0xFF463C2E);
const int _maxMemoLength = 2000;

/// 공연후 페이지 바깥 책상 색, 정리본 종이 색.
const Color _desk = Color(0xFF37261F);
const Color _typedPaper = Color(0xFFF3EEE3);

/// 한글이 "시/도해요"처럼 글자 중간에서 줄바꿈되지 않게 단어 안 글자 사이에 WORD JOINER(U+2060)를 끼움
/// (news_detail_overlay.dart의 _keepWords와 같음).
String _keepWords(String text) {
  const wj = '\u{2060}';
  return text.split(' ').map((token) => token.split('').join(wj)).join(' ');
}

/// [백엔드 수정] 감상 메모에 정리된 글(탭·블로그 옮기기·정리본 종이·정리 안내)을 보일지. 블로그 공유에서만 써서 끔.
bool _showDraftResult = false;

/// 정리된 글을 아직 안 열어봤는지(버튼 색 구분용).
abstract final class BlogMemoSeen {
  static String _key(String ticketId) => 'blog_draft_seen_$ticketId';

  static Future<bool> isUnseen(String ticketId, BlogDraft draft) async {
    final at = draft.generatedAt;
    if (!draft.hasResult || at == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key(ticketId)) != at.toIso8601String();
    } catch (_) {
      return false;
    }
  }

  static Future<void> markSeen(String ticketId, BlogDraft draft) async {
    final at = draft.generatedAt;
    if (at == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(ticketId), at.toIso8601String());
    } catch (_) {}
  }
}

/// 정리된 글(앱에서 고친 게 있으면 그것, 다시 정리 대기 중이면 이전 글). 공유 시트 블로그 버튼용.
Future<String?> loadBlogDraftText(String ticketId) async =>
    (await BlogDraftService().get(ticketId)).text;

/// [백엔드 수정] 공유 시트 블로그 버튼 상태용 정리 결과 조회.
Future<BlogDraft> loadBlogDraft(String ticketId) =>
    BlogDraftService().get(ticketId);

/// 네이버 블로그 글쓰기 열기. 네이버 앱 인앱브라우저 → 기본 브라우저 순.
Future<bool> openNaverBlogWrite() async {
  const writeUrl = 'https://blog.naver.com/GoBlogWrite.naver';
  // 비 HTTP 스킴의 파라미터는 공백이 +로 변환되지 않도록 직접 인코딩합니다.
  final appUri = Uri.parse(
    'naversearchapp://inappbrowser?url=${Uri.encodeComponent(writeUrl)}&target=new&version=6',
  );
  for (final uri in [appUri, Uri.parse(writeUrl)]) {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        return true;
      }
    } catch (_) {
      // 네이버 앱 실행 실패 후에는 기본 브라우저로 재시도합니다.
    }
  }
  return false;
}

/// 공연후 페이지 아래 줄 감상 메모 버튼. 테이프로 붙인 작은 괘선 메모지,
/// 정리가 끝나면 뒤에 타자기 정리본이 한 장 더 삐져나옴.
class BlogMemoButton extends StatefulWidget {
  const BlogMemoButton({
    super.key,
    required this.draft,
    required this.unseen,
    required this.onTap,
  });

  /// null이면 아직 조회 전.
  final BlogDraft? draft;

  /// 정리된 글을 아직 안 열어봄 - 장미색 테이프.
  final bool unseen;
  final VoidCallback onTap;

  @override
  State<BlogMemoButton> createState() => _BlogMemoButtonState();
}

class _BlogMemoButtonState extends State<BlogMemoButton> {
  static const _hintKey = 'blog_memo_hint_shown';
  bool _hint = false;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_maybeShowHint());
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  /// 처음 한 번만 위에 짧은 안내.
  Future<void> _maybeShowHint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_hintKey) ?? false) return;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      setState(() => _hint = true);
      await prefs.setBool(_hintKey, true);
      _hintTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _hint = false);
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        final status = widget.draft?.status ?? BlogDraftStatus.none;
        final hasResult =
            _showDraftResult && (widget.draft?.hasResult ?? false);
        final highlight = _showDraftResult && widget.unseen;
        final label = switch (status) {
          BlogDraftStatus.none => '감상 적기',
          BlogDraftStatus.done when _showDraftResult => '정리된 글',
          _ => '감상 메모',
        };
        final w = context.rs(40);
        final h = context.rs(33);
        Widget sheet({required bool typed}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: typed ? const Color(0xFFF1EDE4) : PaperColors.card,
            borderRadius: BorderRadius.circular(1.5),
            border: Border.all(color: _ink.withValues(alpha: .14)),
            boxShadow: [
              BoxShadow(
                color: _ink.withValues(alpha: .18),
                blurRadius: 3,
                offset: const Offset(1, 2),
              ),
            ],
          ),
          child: CustomPaint(
            painter: _MemoLinesPainter(
              typed: typed,
              written: status != BlogDraftStatus.none,
            ),
          ),
        );
        final tapeW = context.rs(22);
        final note = SizedBox(
          width: w + context.rs(7),
          height: h + context.rs(8),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (hasResult)
                Positioned(
                  left: context.rs(7),
                  top: context.rs(1),
                  child: Transform.rotate(
                    angle: .09,
                    child: sheet(typed: true),
                  ),
                ),
              Positioned(
                left: 0,
                top: context.rs(6),
                child: Transform.rotate(angle: -.1, child: sheet(typed: false)),
              ),
              Positioned(
                left: (w - tapeW) / 2,
                top: context.rs(2.5),
                child: MaskingTape(
                  tint: highlight
                      ? PaperColors.tapeRose
                      : PaperColors.tapeMustard,
                  width: tapeW,
                  height: context.rs(8.5),
                  angle: -.12,
                ),
              ),
            ],
          ),
        );
        return Semantics(
          button: true,
          label: label,
          child: GestureDetector(
            key: const ValueKey('after_blog_memo_button'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.rs(8),
                vertical: context.rs(2),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  note,
                  Positioned(
                    bottom: h + context.rs(16),
                    left: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _hint ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: Container(
                          width: context.rs(178),
                          padding: EdgeInsets.symmetric(
                            horizontal: context.rs(10),
                            vertical: context.rs(7),
                          ),
                          decoration: BoxDecoration(
                            color: PaperColors.card,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(
                              color: _ink.withValues(alpha: .14),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _ink.withValues(alpha: .16),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            // [백엔드 수정] 정리 안내 대신 메모 안내.
                            _showDraftResult
                                ? '감상을 적어두면 다음 날 글이 정리돼요'
                                : '공연 감상을 여기에 적어 둘 수 있어요',
                            style: TextStyle(
                              fontSize: context.sp(10.5),
                              fontWeight: FontWeight.w700,
                              color: _ink.withValues(alpha: .85),
                              height: 1.4,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                    ),
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

/// 메모지 괘선과 연필 글씨 흉내([written]), 정리본은 타자기 글줄.
class _MemoLinesPainter extends CustomPainter {
  const _MemoLinesPainter({required this.typed, required this.written});

  final bool typed;
  final bool written;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (typed) {
      final paint = Paint()
        ..color = _ink.withValues(alpha: .45)
        ..strokeWidth = 1;
      for (final (y, end) in [(.3, .8), (.48, .7), (.66, .82)]) {
        canvas.drawLine(Offset(w * .16, h * y), Offset(w * end, h * y), paint);
      }
      return;
    }
    final rule = Paint()
      ..color = _ink.withValues(alpha: .16)
      ..strokeWidth = .7;
    for (final y in [.42, .62, .82]) {
      canvas.drawLine(Offset(w * .1, h * y), Offset(w * .9, h * y), rule);
    }
    if (!written) return;
    final pencil = Paint()
      ..color = _ink.withValues(alpha: .55)
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(w * .14, h * .37), Offset(w * .78, h * .37), pencil);
    canvas.drawLine(Offset(w * .14, h * .57), Offset(w * .52, h * .57), pencil);
  }

  @override
  bool shouldRepaint(_MemoLinesPainter old) =>
      old.typed != typed || old.written != written;
}

/// 감상 메모 화면을 아래에서 올라오는 종이 한 장으로 엶. 닫힐 때 최신 상태를 돌려줌.
Future<BlogDraft?> openBlogMemoPage(
  BuildContext context, {
  required String ticketId,
  required String concertTitle,
  BlogDraft? initial,
  bool showResult = false,
}) {
  return Navigator.of(context, rootNavigator: true).push<BlogDraft>(
    PageRouteBuilder<BlogDraft>(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, _, _) => BlogMemoPage(
        ticketId: ticketId,
        concertTitle: concertTitle,
        initial: initial,
        showResult: showResult,
      ),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: child,
      ),
    ),
  );
}

class BlogMemoPage extends StatefulWidget {
  const BlogMemoPage({
    super.key,
    required this.ticketId,
    required this.concertTitle,
    this.initial,
    this.showResult = false,
  });

  final String ticketId;
  final String concertTitle;
  final BlogDraft? initial;
  final bool showResult;

  @override
  State<BlogMemoPage> createState() => _BlogMemoPageState();
}

class _BlogMemoPageState extends State<BlogMemoPage> {
  final _service = BlogDraftService();
  final _memo = TextEditingController();
  final _result = TextEditingController();
  final _memoScroll = ScrollController();
  final _resultScroll = ScrollController();

  late BlogDraft _draft = widget.initial ?? BlogDraft.empty;
  late int _tab = _showDraftResult && widget.showResult ? 1 : 0;
  bool _saving = false;

  /// 정리본을 불러온 직후 값 - 바뀌었을 때만 저장.
  String _loadedResult = '';

  @override
  void initState() {
    super.initState();
    _memo.text = _draft.emotion ?? '';
    _fillResult();
    _memo.addListener(_onMemoChanged);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _memo.dispose();
    _result.dispose();
    _memoScroll.dispose();
    _resultScroll.dispose();
    super.dispose();
  }

  void _onMemoChanged() => setState(() {});

  Future<void> _refresh() async {
    try {
      final draft = await _service.get(widget.ticketId);
      if (!mounted) return;
      final memoUntouched = _memo.text == (_draft.emotion ?? '');
      final resultUntouched = _result.text == _loadedResult;
      setState(() => _draft = draft);
      if (memoUntouched) _memo.text = draft.emotion ?? '';
      if (resultUntouched) _fillResult();
    } catch (_) {
      // 조회 실패면 들고 온 상태로 둠.
    }
  }

  void _fillResult() {
    final text = _draft.text ?? '';
    _result.text = text;
    _loadedResult = text;
    if (_tab == 1) _markSeen();
  }

  void _markSeen() {
    if (_draft.hasResult) {
      unawaited(BlogMemoSeen.markSeen(widget.ticketId, _draft));
    }
  }

  /// 메모가 바뀌었으면 저장. false면 화면에 남음.
  Future<bool> _saveMemoIfChanged() async {
    final text = _memo.text.trim();
    if (text == (_draft.emotion ?? '').trim()) return true;
    if (text.isEmpty) {
      showPaperSnackBar(context, '빈 메모는 저장하지 않았어요.');
      return true;
    }
    if (_showDraftResult && _draft.status == BlogDraftStatus.done) {
      final ok = await showPaperDialog<bool>(
        context,
        title: '메모를 고칠까요?',
        message: '고친 메모로 다음 날 다시 정리돼요. 지금 정리된 글은 새 글이 나오면 바뀌어요.',
        actions: const [
          PaperDialogAction(
            label: '취소',
            value: false,
            style: PaperButtonStyle.quiet,
          ),
          PaperDialogAction(label: '저장', value: true),
        ],
      );
      if (ok != true) return false;
    }
    return _save(text);
  }

  Future<bool> _save(String text) async {
    while (true) {
      setState(() => _saving = true);
      try {
        final draft = await _service.save(widget.ticketId, text);
        if (!mounted) return true;
        setState(() {
          _draft = draft;
          _saving = false;
        });
        return true;
      } catch (e) {
        if (!mounted) return true;
        setState(() => _saving = false);
        final detail = e is ApiException && e.statusCode == 400
            ? e.message
            : '네트워크 상태를 확인해 주세요.';
        final retry = await showPaperDialog<bool>(
          context,
          title: '메모를 저장하지 못했어요',
          message: detail,
          actions: const [
            PaperDialogAction(
              label: '그냥 닫기',
              value: false,
              style: PaperButtonStyle.quiet,
            ),
            PaperDialogAction(label: '다시 시도', value: true),
          ],
        );
        if (retry != true) return true;
      }
    }
  }

  /// 고친 정리본 서버 저장. 실패하면 안내만 하고 화면의 글은 그대로 둠.
  Future<void> _saveResultEdit() async {
    if (!_draft.hasResult) return;
    final text = _result.text;
    if (text == _loadedResult || text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      final draft = await _service.saveText(widget.ticketId, text);
      _loadedResult = text;
      if (mounted) setState(() => _draft = draft);
    } catch (_) {
      if (mounted) showPaperSnackBar(context, '고친 글을 저장하지 못했어요.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _close() async {
    if (_saving) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (!await _saveMemoIfChanged()) return;
    if (_showDraftResult) await _saveResultEdit();
    if (mounted) Navigator.of(context).pop(_draft);
  }

  /// 같은 메모를 다시 보내면 서버가 실패 횟수만 초기화함.
  Future<void> _retry() async {
    final text = (_draft.emotion ?? _memo.text).trim();
    if (text.isEmpty) return;
    await _save(text);
  }

  Future<void> _sendToBlog() async {
    final text = _result.text.trim();
    if (text.isEmpty) return;
    await _saveResultEdit();
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      if (mounted) showPaperSnackBar(context, '글을 복사하지 못했어요. 다시 시도해 주세요.');
      return;
    }
    if (!mounted) return;
    showPaperSnackBar(context, '글을 복사했어요. 네이버 블로그 본문에 붙여넣어 주세요.');
    if (!await openNaverBlogWrite() && mounted) {
      showPaperSnackBar(context, '네이버 블로그를 열지 못했어요. 브라우저에서 열어 주세요.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: paperSheetScale(
        context,
        Builder(
          builder: (context) {
            final typedPaper = _tab == 1 && _draft.hasResult;
            return Scaffold(
              backgroundColor: _desk,
              body: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _topBar(),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned.fill(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    decoration: BoxDecoration(
                                      color: typedPaper
                                          ? _typedPaper
                                          : PaperColors.card,
                                      borderRadius: BorderRadius.circular(4),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: .35,
                                          ),
                                          blurRadius: 18,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        _paperHead(context),
                                        Expanded(
                                          child: _tab == 0
                                              ? _memoTab(context)
                                              : _resultTab(context),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const Positioned(
                                  top: -9,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: MaskingTape(
                                      tint: PaperColors.tapeMustard,
                                      width: 84,
                                      height: 20,
                                      angle: -0.03,
                                    ),
                                  ),
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
          },
        ),
      ),
    );
  }

  /// 책상 위 뒤로가기 / 저장 중 표시.
  Widget _topBar() {
    // 높이 고정 - 탭마다 오른쪽 글자가 생겼다 없어져도 종이가 위아래로 안 움직이게.
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            IconButton(
              onPressed: _saving ? null : _close,
              icon: Icon(
                Icons.arrow_back,
                color: PaperColors.card.withValues(alpha: .85),
              ),
            ),
            const Spacer(),
            if (_saving)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: PaperColors.card.withValues(alpha: .7),
                ),
              )
            else if (_showDraftResult && _tab == 1 && _draft.hasResult)
              // 종이 안엔 글만 두고, 블로그에 옮기기는 책상 위에 놓인 작은 종이 쪽지로.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _sendToBlog,
                child: Center(
                  child: Transform.rotate(
                    angle: -.03,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: PaperColors.card,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .35),
                            blurRadius: 5,
                            offset: const Offset(1, 2),
                          ),
                        ],
                      ),
                      child: Text(
                        '블로그에 옮기기',
                        style: TextStyle(
                          fontSize: context.sp(11.5),
                          fontWeight: FontWeight.w800,
                          color: _ink,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 종이 머리말: 제목·공연명, 글자 탭, 구분선.
  Widget _paperHead(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '감상 메모',
            style: TextStyle(
              fontSize: context.sp(18),
              fontWeight: FontWeight.w900,
              color: _ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            widget.concertTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.sp(12),
              fontWeight: FontWeight.w600,
              color: PaperColors.muted,
            ),
          ),
          const SizedBox(height: 14),
          if (_showDraftResult) ...[
            _Tabs(
              labels: const ['내 메모', '정리된 글'],
              selected: _tab,
              dotIndex: _draft.hasResult && _tab != 1 ? 1 : null,
              onSelected: (i) {
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() => _tab = i);
                if (i == 1) _markSeen();
              },
            ),
            const SizedBox(height: 8),
          ],
          Container(height: 1, color: _ink.withValues(alpha: .14)),
        ],
      ),
    );
  }

  Widget _memoTab(BuildContext context) {
    final status = _draft.status;
    final note = switch (status) {
      BlogDraftStatus.none => '자정이 지나면 글로 정리돼요. 다 되면 알려드릴게요.',
      BlogDraftStatus.pending => '자정이 지나면 정리돼요. 그 전까지는 계속 고칠 수 있어요.',
      BlogDraftStatus.done => '정리된 글이 있어요. 메모를 고치면 다음 날 다시 정리돼요.',
      BlogDraftStatus.stale => '고친 메모는 다음 날 다시 정리돼요. 그 전까지는 이전 글을 쓸 수 있어요.',
      BlogDraftStatus.failed => '정리하지 못했어요.',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _RuledField(
            controller: _memo,
            scrollController: _memoScroll,
            hint: '오늘 공연 어땠어요?\n기억에 남는 순간이 있었나요?',
            readOnly: _saving,
            maxLength: _maxMemoLength,
          ),
        ),
        _footer(
          context,
          note: _showDraftResult ? note : '',
          counter: '${_memo.text.characters.length}/$_maxMemoLength',
          link: _showDraftResult && status == BlogDraftStatus.failed
              ? '오늘 밤 다시 정리하기'
              : null,
          onLink: _saving ? null : _retry,
        ),
      ],
    );
  }

  Widget _resultTab(BuildContext context) {
    if (!_draft.hasResult) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _draft.status == BlogDraftStatus.none
                ? '내 메모를 적으면\n다음 날 여기에 정리된 글이 채워져요.'
                : '아직 정리 전이에요.\n자정이 지나면 정리돼서 여기에 채워져요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(13.5),
              fontWeight: FontWeight.w600,
              color: PaperColors.muted,
              height: 1.6,
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _RuledField(
            controller: _result,
            scrollController: _resultScroll,
            typed: true,
          ),
        ),
        _footer(
          context,
          note: _draft.status == BlogDraftStatus.done
              ? '고친 내용은 그대로 저장돼요.'
              : '고치기 전 메모로 정리한 글이에요.',
        ),
      ],
    );
  }

  Widget _footer(
    BuildContext context, {
    required String note,
    String? counter,
    String? link,
    VoidCallback? onLink,
  }) {
    final style = TextStyle(
      fontSize: context.sp(11.5),
      fontWeight: FontWeight.w600,
      color: PaperColors.muted,
      height: 1.45,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(_keepWords(note), style: style),
                // 밑줄은 띄어쓰기에서 끊겨서 굵기·색으로만 구분.
                if (link != null)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onLink,
                    child: Text(
                      _keepWords(link),
                      style: style.copyWith(
                        fontWeight: FontWeight.w900,
                        color: _ink,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (counter != null) ...[
            const SizedBox(width: 10),
            Text(counter, style: style),
          ],
        ],
      ),
    );
  }
}

/// 괘선 종이 위 글쓰기 칸. [typed]면 정리본(괘선 없음).
class _RuledField extends StatelessWidget {
  const _RuledField({
    required this.controller,
    required this.scrollController,
    this.hint,
    this.readOnly = false,
    this.maxLength,
    this.typed = false,
  });

  final TextEditingController controller;
  final ScrollController scrollController;
  final String? hint;
  final bool readOnly;
  final int? maxLength;
  final bool typed;

  static const double _lineHeight = 1.9;
  static const double _padTop = 14;

  @override
  Widget build(BuildContext context) {
    final fontSize = context.sp(15);
    final style = TextStyle(
      fontSize: fontSize,
      height: _lineHeight,
      fontWeight: typed ? FontWeight.w500 : FontWeight.w600,
      color: _ink,
    );
    final line = MediaQuery.textScalerOf(context).scale(fontSize) * _lineHeight;
    return CustomPaint(
      painter: _RulePainter(
        scroll: scrollController,
        lineHeight: line,
        top: _padTop,
        color: typed ? null : _ink.withValues(alpha: .13),
      ),
      child: TextField(
        controller: controller,
        scrollController: scrollController,
        readOnly: readOnly,
        expands: true,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        inputFormatters: [
          if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
        ],
        cursorColor: _ink,
        style: style,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: style.copyWith(
            color: PaperColors.muted.withValues(alpha: .7),
          ),
          contentPadding: const EdgeInsets.fromLTRB(22, _padTop, 22, _padTop),
        ),
      ),
    );
  }
}

/// 글줄 아래 괘선. 글과 같이 스크롤. [color]가 null이면 안 그림(정리본은 무지).
class _RulePainter extends CustomPainter {
  _RulePainter({
    required this.scroll,
    required this.lineHeight,
    required this.top,
    required this.color,
  }) : super(repaint: scroll);

  final ScrollController scroll;
  final double lineHeight;
  final double top;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = color;
    if (c == null || lineHeight <= 0) return;
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    final paint = Paint()
      ..color = c
      ..strokeWidth = 1;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    var y = top + lineHeight - offset % lineHeight;
    while (y < size.height) {
      canvas.drawLine(Offset(20, y), Offset(size.width - 20, y), paint);
      y += lineHeight;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RulePainter old) =>
      old.lineHeight != lineHeight || old.color != color || old.top != top;
}

/// 내 메모 / 정리된 글 글자 탭. 고른 쪽만 진한 글씨에 연필 밑줄.
class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.dotIndex,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  /// 이 탭 글자 옆에 연필로 찍은 듯한 작은 점(정리된 글이 있음).
  final int? dotIndex;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: i == selected ? null : () => onSelected(i),
            // 밑줄은 TextDecoration 대신 아래 테두리 - 띄어쓰기에서 끊겨 보였음.
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 20, 4),
              child: Container(
                padding: const EdgeInsets.only(bottom: 2),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: i == selected
                          ? _ink.withValues(alpha: .55)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      labels[i],
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: context.sp(14),
                        fontWeight: i == selected
                            ? FontWeight.w900
                            : FontWeight.w700,
                        color: i == selected
                            ? _ink
                            : PaperColors.muted.withValues(alpha: .8),
                      ),
                    ),
                    if (i == dotIndex)
                      Padding(
                        padding: EdgeInsets.only(left: context.rs(3)),
                        child: Container(
                          width: context.rs(5),
                          height: context.rs(5),
                          decoration: BoxDecoration(
                            color: _ink.withValues(alpha: .6),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
