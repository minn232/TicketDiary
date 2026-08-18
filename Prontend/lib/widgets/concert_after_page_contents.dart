import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/setlist.dart';
import '../models/ticket_info.dart';
import '../services/api_client.dart';
import '../services/concert_detail_service.dart';
import '../services/ticket_service.dart';
import '../services/upload_service.dart';
import 'responsive_text.dart';

/// 게스트 로그인 상태에서 로컬에 저장된 사진은 절대 파일 경로 문자열이라
/// `http(s)`로 시작하지 않습니다 — 이 차이로 [Image.network]/[Image.file] 중
/// 무엇을 쓸지 결정합니다.
bool _isNetworkUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

Widget _buildFullPhoto(String url) {
  const errorIcon = Icon(
    Icons.broken_image_outlined,
    size: 48,
    color: Colors.white54,
  );
  return _isNetworkUrl(url)
      ? Image.network(
          url,
          fit: BoxFit.contain,
          webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
          errorBuilder: (context, error, stackTrace) => errorIcon,
        )
      : Image.file(
          File(url),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => errorIcon,
        );
}

/// 폴라로이드 썸네일을 눌렀을 때, 원본 사진을 화면 전체에 크게 보여줍니다.
/// 바깥(사진 바깥 여백)을 누르면 닫힙니다.
void _openFullPhoto(BuildContext context, String url) {
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: '사진 확대 닫기',
    barrierColor: Colors.black.withValues(alpha: 0.85),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: GestureDetector(
                // 사진 자체를 눌렀을 때는 닫히지 않도록 이벤트를 흡수합니다.
                onTap: () {},
                child: _buildFullPhoto(url),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}

/// "공연 후" 페이지 콘텐츠.
///
/// - 상단에 일기장 표제처럼 공연 제목/날짜/공연장 + 빨간 "관람 완료" 도장
/// - 사진/공연 소감/업적 도장/실제 셋리스트 4개 기능을 스크롤·스와이프 없이
///   한 화면에 2x2 포스트잇 색 카드로 모두 보여줌
///
/// NOTE ([ConcertBeforePageContents]와 동일한 규칙)
/// - 오버레이에서는 [postItOpacity]에 애니메이션을 넘기면 2x2 카드 영역이
///   Fade-in 됩니다(헤더는 즉시 보임). 일반 스크린에서는 null로 두면
///   즉시 표시됩니다.
/// - [ticketInfo]가 있어야 사진/소감/실제 셋리스트를 서버에 반영할 수
///   있습니다(없으면 로컬 예시 티켓이라 조회/편집 없이 안내 문구만 표시).
class ConcertAfterPageContents extends StatefulWidget {
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final Animation<double>? postItOpacity;
  final bool showCloseHint;

  /// 사진 추가/소감 저장이 성공해 [ticketInfo]가 최신화될 때마다 호출됩니다.
  /// 호출자(다이어리 화면)가 원본 티켓 데이터를 같이 갱신해야, 이 오버레이를
  /// 닫은 뒤에도 앱 재시작 없이 바로 최신 내용이 보입니다.
  final ValueChanged<TicketInfo>? onTicketInfoChanged;

  const ConcertAfterPageContents({
    super.key,
    required this.concertTitle,
    this.ticketInfo,
    this.postItOpacity,
    this.showCloseHint = true,
    this.onTicketInfoChanged,
  });

  @override
  State<ConcertAfterPageContents> createState() =>
      _ConcertAfterPageContentsState();
}

class _ConcertAfterPageContentsState extends State<ConcertAfterPageContents> {
  final TicketService _ticketService = TicketService();
  final UploadService _uploadService = BackendUploadService();
  final ImagePicker _imagePicker = ImagePicker();

  late TicketInfo? _ticketInfo = widget.ticketInfo;
  bool _savingReview = false;
  bool _uploadingPhoto = false;

  String? get _ticketId => _ticketInfo?.ticketId;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 로컬 예시 티켓 등 서버에 등록되지 않은 티켓은 편집할 수 없음을 안내합니다.
  bool _ensureEditable() {
    if (_ticketId != null) return true;
    _showSnack('실제 등록된 티켓만 편집할 수 있어요.');
    return false;
  }

  Future<void> _editReview() async {
    if (!_ensureEditable() || _savingReview) return;

    final controller = TextEditingController(text: _ticketInfo?.review ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('공연 소감'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          minLines: 3,
          maxLength: 500,
          decoration: const InputDecoration(
            hintText: '오늘 공연은 어떠셨나요?',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (result == null) return; // 취소

    setState(() => _savingReview = true);
    try {
      final updated = await _ticketService.updateTicket(_ticketId!, review: result);
      if (!mounted) return;
      setState(() {
        _ticketInfo = _ticketInfo?.copyWith(review: updated.review ?? '');
      });
      if (_ticketInfo != null) widget.onTicketInfoChanged?.call(_ticketInfo!);
      _showSnack('소감을 저장했어요.');
    } on TicketNotFoundException {
      _showSnack('티켓을 찾을 수 없어요.');
    } on ApiException catch (e) {
      _showSnack('저장에 실패했어요: ${e.message}');
    } catch (_) {
      _showSnack('저장 중 오류가 발생했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _savingReview = false);
    }
  }

  Future<void> _addPhoto() async {
    if (!_ensureEditable() || _uploadingPhoto) return;

    final XFile? picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return; // 취소

    setState(() => _uploadingPhoto = true);
    try {
      final url = await _uploadService.uploadConcertPhoto(picked);
      final List<String> nextUrls = [
        ...(_ticketInfo?.concertPhotoUrls ?? const <String>[]),
        url,
      ];
      final updated = await _ticketService.updateTicket(
        _ticketId!,
        concertPhotoUrls: nextUrls,
      );
      if (!mounted) return;
      setState(() {
        _ticketInfo = _ticketInfo?.copyWith(
          concertPhotoUrls: updated.concertPhotoUrls ?? nextUrls,
        );
      });
      if (_ticketInfo != null) widget.onTicketInfoChanged?.call(_ticketInfo!);
    } on TicketNotFoundException {
      _showSnack('티켓을 찾을 수 없어요.');
    } on ApiException catch (e) {
      _showSnack('사진 추가에 실패했어요: ${e.message}');
    } catch (_) {
      _showSnack('사진 추가 중 오류가 발생했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  // [백엔드 수정]
  // 사진을 꾹 눌러서 삭제할 수 있는 기능.
  // 확인 팝업 후 서버에서 삭제.
  Future<void> _confirmDeletePhoto(String url) async {
    if (!_ensureEditable() || _uploadingPhoto) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('사진 삭제'),
        content: const Text('이 사진을 삭제할까요? 되돌릴 수 없어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final List<String> nextUrls = [
      ...(_ticketInfo?.concertPhotoUrls ?? const <String>[]),
    ]..remove(url);

    try {
      final updated = await _ticketService.updateTicket(
        _ticketId!,
        concertPhotoUrls: nextUrls,
      );
      if (!mounted) return;
      setState(() {
        _ticketInfo = _ticketInfo?.copyWith(
          concertPhotoUrls: updated.concertPhotoUrls ?? nextUrls,
        );
      });
      if (_ticketInfo != null) widget.onTicketInfoChanged?.call(_ticketInfo!);
      _showSnack('사진을 삭제했어요.');
    } on TicketNotFoundException {
      _showSnack('티켓을 찾을 수 없어요.');
    } on ApiException catch (e) {
      _showSnack('사진 삭제에 실패했어요: ${e.message}');
    } catch (_) {
      _showSnack('사진 삭제 중 오류가 발생했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final grid = Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: _DashedPhotoCard(
                  icon: Icons.photo_camera_outlined,
                  label: '사진',
                  child: _PhotoBoard(
                    photoUrls: _ticketInfo?.concertPhotoUrls ?? const [],
                    uploading: _uploadingPhoto,
                    onAddTap: _uploadingPhoto ? null : _addPhoto,
                    onDeleteTap: _uploadingPhoto ? null : _confirmDeletePhoto,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _MemoryCard(
                  icon: Icons.edit_note,
                  label: '공연 소감',
                  color: const Color(0xFFFFD6E8),
                  onTap: _savingReview ? null : _editReview,
                  child: _savingReview
                      ? const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        )
                      : _ReviewContent(review: _ticketInfo?.review),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: _MemoryCard(
                  icon: Icons.workspace_premium_outlined,
                  label: '업적 도장',
                  color: const Color(0xFFCFF5E7),
                  child: const _StampsPlaceholder(),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _MemoryCard(
                  icon: Icons.queue_music,
                  label: '실제 셋리스트',
                  color: const Color(0xFFD9E8FF),
                  // [백엔드 수정]
                  // concertId → ticketId 기준 조회로 바뀜.
                  child: _RealSetlistContent(ticketId: _ticketId),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    // 공연 포스터는 이 위젯(패딩 안쪽) 대신, 호출부가 페이지 컨테이너 자체의
    // 배경으로 겹쳐줍니다(페이지의 둥근 모서리 모양 그대로 꽉 채우기 위해).
    // 여기서는 카드(_MemoryCard)들만 완전 불투명이 아니라 살짝 비치게 해서,
    // 뒤에 깔린 포스터가 카드 영역에서도 고르게 드러나 보이게 합니다.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 헤더는 순전히 표시용이라 히트테스트에서 제외합니다(IgnorePointer) —
        // 그래야 이 자리를 눌렀을 때 뒤에 겹친 포스터의 "바깥 탭으로 닫기"
        // 감지기까지 탭이 그대로 통과합니다.
        IgnorePointer(
          child: _DiaryHeader(
            title: widget.concertTitle,
            date: _ticketInfo?.date,
          ),
        ),
        const SizedBox(height: 16),
        // 4개 기능(사진/공연 소감/업적 도장/실제 셋리스트)을 스크롤도
        // 스와이프도 없이 한 화면에 2x2로 모두 보여줍니다.
        Expanded(
          child: widget.postItOpacity == null
              ? grid
              : FadeTransition(opacity: widget.postItOpacity!, child: grid),
        ),
        if (widget.showCloseHint) ...[
          const SizedBox(height: 10),
          Container(height: 1, color: Colors.black.withValues(alpha: 0.08)),
          const SizedBox(height: 10),
          IgnorePointer(
            child: Text(
              '닫기: 페이지 바깥을 눌러주세요.',
              style: TextStyle(
                fontSize: context.sp(12),
                color: Colors.black.withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 포스트잇 색을 입힌 카드 한 장. [onTap]을 주면 카드 전체를 눌러 편집할
/// 수 있습니다(예: 공연 소감).
class _MemoryCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Widget child;
  final VoidCallback? onTap;

  const _MemoryCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.child,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        // 완전 불투명 — 뒤에 겹친 포스터가 카드 영역까지 옅게 비쳐 보이면
        // 포스트잇이 지저분해 보인다는 피드백으로, 포스트잇 부분은 포스터와
        // 무관하게 온전한 색으로만 보이도록 바꿨습니다.
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 15, color: Colors.black.withValues(alpha: 0.65)),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.sp(13),
                          fontWeight: FontWeight.w900,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "사진" 칸 전용 카드. 다른 3장(공연 소감/업적 도장/실제 셋리스트)과 달리
/// 포스트잇 색 배경을 쓰지 않고, 다이어리 페이지 위에 직접 사진을 붙여둔
/// 자리처럼 경계를 점선으로만 표시합니다. 경계 위쪽엔 찢어진 마스킹테이프
/// 조각([_TornTapePiece])을 겹쳐서 "종이를 여기 붙여뒀다"는 느낌을 냅니다.
/// (디자인 초안 — 사용자 확인 후 조정 예정)
class _DashedPhotoCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget child;

  const _DashedPhotoCard({
    required this.icon,
    required this.label,
    required this.child,
  });

  static const double _radius = 14;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CustomPaint(
          painter: const _DashedBorderPainter(
            color: Color(0x59000000), // Colors.black.withValues(alpha: 0.35)
            radius: _radius,
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 15, color: Colors.black.withValues(alpha: 0.65)),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.sp(13),
                          fontWeight: FontWeight.w900,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(child: child),
              ],
            ),
          ),
        ),

        // 위쪽 경계선에 걸쳐 붙인 찢어진 테이프 조각.
        const Positioned(
          top: -9,
          left: 0,
          right: 0,
          child: Center(child: _TornTapePiece()),
        ),
      ],
    );
  }
}

/// 찢어진 마스킹테이프 한 조각. 위/아래 변은 곧고, 좌/우 짧은 변은 손으로
/// 뜯은 것처럼 삐죽삐죽한 지그재그로 그립니다.
class _TornTapePiece extends StatelessWidget {
  const _TornTapePiece();

  static const double _width = 50;
  static const double _height = 18;
  static const double _angle = -0.035;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: _angle,
      child: CustomPaint(
        size: const Size(_width, _height),
        painter: const _TornTapePainter(),
      ),
    );
  }
}

class _TornTapePainter extends CustomPainter {
  const _TornTapePainter();

  /// 지그재그 삐죽함(짧은 변에서 안쪽으로 파고드는 최대 깊이).
  static const double _notch = 3.2;

  /// 짧은 변 하나에 들어가는 지그재그 산의 개수.
  static const int _teeth = 4;

  Path _tornPath(Size size) {
    final path = Path()..moveTo(0, 0);
    path.lineTo(size.width, 0); // 위쪽 변(곧음)

    // 오른쪽 변: 위 -> 아래로 내려가며 안쪽/바깥쪽을 번갈아 찔러 톱니를 만듦.
    for (var i = 1; i <= _teeth; i++) {
      final y = size.height * i / _teeth;
      final x = size.width - (i.isOdd ? _notch : 0.0);
      path.lineTo(x, y);
    }

    path.lineTo(0, size.height); // 아래쪽 변(곧음)

    // 왼쪽 변: 아래 -> 위로 올라가며 마찬가지로 톱니를 만듦.
    for (var i = _teeth - 1; i >= 0; i--) {
      final y = size.height * i / _teeth;
      final x = i.isOdd ? _notch : 0.0;
      path.lineTo(x, y);
    }
    path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _tornPath(size);
    canvas.drawPath(path, Paint()..color = Colors.white.withValues(alpha: 0.68));
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(covariant _TornTapePainter oldDelegate) => false;
}

/// 공연 후 페이지 전반에서 쓰는 포인트 색(빨간 도장 잉크 색과 통일).
const Color _memoryAccent = Color(0xFFD64545);

/// 일기장 표제 느낌의 상단 헤더: 날짜, 공연 제목, 빨간 "관람 완료" 도장.
class _DiaryHeader extends StatelessWidget {
  final String title;
  final DateTime? date;

  const _DiaryHeader({required this.title, this.date});

  // 원래는 날짜 · 공연장을 함께 보여줬지만, 날짜만 남기기로 했습니다.
  String? get _metaLine {
    final d = date;
    if (d == null) return null;
    return '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final meta = _metaLine;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (meta != null) ...[
                Text(
                  meta,
                  style: TextStyle(
                    fontSize: context.sp(12),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.sp(20),
                  fontWeight: FontWeight.w900,
                  color: Colors.black87,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 6),
              // 손으로 그은 밑줄 느낌
              Container(
                width: 132,
                height: 3,
                decoration: BoxDecoration(
                  color: const Color(0xFFD64545).withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        const _WatchedStamp(),
      ],
    );
  }
}

/// 여권 도장처럼 비스듬히 찍힌 빨간 "관람 완료" 도장.
class _WatchedStamp extends StatelessWidget {
  const _WatchedStamp();

  @override
  Widget build(BuildContext context) {
    const inkColor = _memoryAccent;

    return Transform.rotate(
      angle: -0.20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: inkColor.withValues(alpha: 0.75), width: 2.4),
          borderRadius: BorderRadius.circular(8),
          color: inkColor.withValues(alpha: 0.06),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '관람 완료',
              style: TextStyle(
                fontSize: context.sp(14),
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                color: inkColor.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(height: 1),
            Text(
              'TICKET DIARY',
              style: TextStyle(
                fontSize: context.sp(7),
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
                color: inkColor.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "공연 소감" 포스트잇 내용. 줄노트 위에 쓴 손글씨 느낌으로 보여주고,
/// 아직 없으면 살짝 흐린 안내 문구를 보여줍니다.
class _ReviewContent extends StatelessWidget {
  final String? review;

  const _ReviewContent({required this.review});

  @override
  Widget build(BuildContext context) {
    final text = review;
    final hasReview = text != null && text.isNotEmpty;

    return CustomPaint(
      painter: _RuledPaperPainter(),
      child: SizedBox.expand(
        child: hasReview
            ? SingleChildScrollView(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: context.sp(13),
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                    height: 22 / 13, // 줄노트 간격(22px)에 맞춤
                  ),
                ),
              )
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.mode_edit_outline_outlined,
                      size: 22,
                      color: Colors.black.withValues(alpha: 0.3),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '탭해서 오늘의\n감상을 적어보세요',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: context.sp(12),
                        fontWeight: FontWeight.w700,
                        color: Colors.black.withValues(alpha: 0.35),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// 줄노트처럼 옅은 가로줄을 일정 간격으로 긋는 페인터.
class _RuledPaperPainter extends CustomPainter {
  static const double lineGap = 22;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    for (double y = lineGap; y < size.height; y += lineGap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RuledPaperPainter oldDelegate) => false;
}

/// "사진" 카드 내용. 추가한 사진들은 다이어리 종이 위에 직접 붙인
/// 폴라로이드처럼 보여줍니다(흰 테두리 + 위쪽 테이프 + 삐뚤빼뚤한 기울기).
/// 카드 배경/테두리는 [_MemoryCard]가 이미 그려주므로 여기선 내용만 둡니다.
class _PhotoBoard extends StatelessWidget {
  final List<String> photoUrls;
  final bool uploading;
  final VoidCallback? onAddTap;
  final ValueChanged<String>? onDeleteTap;

  const _PhotoBoard({
    required this.photoUrls,
    required this.uploading,
    required this.onAddTap,
    required this.onDeleteTap,
  });

  @override
  Widget build(BuildContext context) {
    final isEmpty = photoUrls.isEmpty && !uploading;

    if (isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onAddTap,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_a_photo_outlined,
                size: 26,
                color: Colors.black.withValues(alpha: 0.35),
              ),
              const SizedBox(height: 8),
              Text(
                '탭해서 사진을\n붙여보세요',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.sp(12),
                  fontWeight: FontWeight.w700,
                  color: Colors.black.withValues(alpha: 0.4),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      child: Wrap(
        spacing: 10,
        runSpacing: 14,
        children: [
          for (var i = 0; i < photoUrls.length; i++)
            _PolaroidThumb(
              url: photoUrls[i],
              // 번갈아 살짝 기울여 실제로 붙인 느낌을 냅니다.
              angle: i.isEven ? -0.05 : 0.045,
              onLongPress: onDeleteTap == null
                  ? null
                  : () => onDeleteTap!(photoUrls[i]),
            ),
          if (uploading)
            const SizedBox(
              width: 58,
              height: 70,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            _AddPhotoTile(onTap: onAddTap),
        ],
      ),
    );
  }
}

/// 둥근 모서리 사각형을 점선으로 그리는 페인터(사진 붙이는 자리 표시).
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double dashLength;
  final double gapLength;

  const _DashedBorderPainter({
    required this.color,
    required this.radius,
    this.dashLength = 7,
    this.gapLength = 5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          Radius.circular(radius),
        ),
      );

    // 경로를 따라가며 dash/gap 간격으로 잘라 그립니다.
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final end = (distance + dashLength).clamp(0, metric.length).toDouble();
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}

/// 다이어리에 직접 붙인 폴라로이드 사진. 흰 테두리(아래쪽이 더 두꺼움) +
/// 그림자 + 위쪽 가운데 반투명 테이프로 "붙어있는" 느낌을 냅니다.
//
// [백엔드 수정]
// 사진 프레임이 정사각형 고정이라 가로/세로로 긴 사진은 억지로 잘려
// 보이던 문제 - 실제 이미지 비율을 읽어와 프레임 크기를 그에 맞게
// 조절(짧은 변은 고정, 긴 변만 비율만큼 늘어나되 상한 있음).
class _PolaroidThumb extends StatefulWidget {
  final String url;
  final double angle;
  final VoidCallback? onLongPress;

  const _PolaroidThumb({
    required this.url,
    required this.angle,
    this.onLongPress,
  });

  @override
  State<_PolaroidThumb> createState() => _PolaroidThumbState();
}

class _PolaroidThumbState extends State<_PolaroidThumb> {
  static const double _shortSide = 50;
  static const double _maxLongSide = 88;

  double? _aspectRatio; // width / height
  ImageStream? _stream;
  late ImageStreamListener _listener;

  @override
  void initState() {
    super.initState();
    _resolveAspectRatio();
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  void _resolveAspectRatio() {
    final provider = _isNetworkUrl(widget.url)
        ? NetworkImage(widget.url) as ImageProvider
        : FileImage(File(widget.url));
    _listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() {
          _aspectRatio = info.image.width / info.image.height;
        });
      },
      onError: (_, _) {}, // 실패하면 정사각형 기본값 유지
    );
    _stream = provider.resolve(const ImageConfiguration())
      ..addListener(_listener);
  }

  Size get _frameSize {
    final ratio = _aspectRatio;
    if (ratio == null || ratio == 1) return const Size(_shortSide, _shortSide);
    if (ratio > 1) {
      // 가로로 긴 사진: 세로를 고정하고 가로만 비율만큼 늘림
      return Size((_shortSide * ratio).clamp(_shortSide, _maxLongSide), _shortSide);
    }
    // 세로로 긴 사진: 가로를 고정하고 세로만 비율만큼 늘림
    return Size(_shortSide, (_shortSide / ratio).clamp(_shortSide, _maxLongSide));
  }

  @override
  Widget build(BuildContext context) {
    final size = _frameSize;
    return Transform.rotate(
      angle: widget.angle,
      child: GestureDetector(
        onTap: () => _openFullPhoto(context, widget.url),
        onLongPress: widget.onLongPress,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(4, 5, 4, 13),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 5,
                    offset: const Offset(1.5, 2.5),
                  ),
                ],
              ),
              child: _isNetworkUrl(widget.url)
                  ? Image.network(
                      widget.url,
                      width: size.width,
                      height: size.height,
                      fit: BoxFit.cover,
                      webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: size.width,
                        height: size.height,
                        color: Colors.black12,
                        child: const Icon(Icons.broken_image_outlined, size: 18),
                      ),
                    )
                  // 게스트 로그인 상태에서 로컬(기기)에 저장된 사진 경로.
                  : Image.file(
                      File(widget.url),
                      width: size.width,
                      height: size.height,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: size.width,
                        height: size.height,
                        color: Colors.black12,
                        child: const Icon(Icons.broken_image_outlined, size: 18),
                      ),
                    ),
            ),

            // 위쪽 가운데 테이프 — 포스트잇처럼 종이에 붙여둔 느낌
            Positioned(
              top: -6,
              left: 0,
              right: 0,
              child: Center(
                child: Transform.rotate(
                  angle: -0.08,
                  child: Container(
                    width: 30,
                    height: 11,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(2),
                      border: Border.all(
                        color: Colors.black.withValues(alpha: 0.08),
                        width: 1,
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
}

class _AddPhotoTile extends StatelessWidget {
  final VoidCallback? onTap;

  const _AddPhotoTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: CustomPaint(
        painter: _DashedBorderPainter(
          color: Colors.black.withValues(alpha: 0.30),
          radius: 4,
          dashLength: 5,
          gapLength: 4,
        ),
        child: const SizedBox(
          width: 58,
          height: 70,
          child: Icon(
            Icons.add,
            size: 22,
            color: Colors.black38,
          ),
        ),
      ),
    );
  }
}

/// "업적 도장" 카드 내용. 아직 기능 연동 전이라, 도장이 찍힐 자리를
/// 흐린 원 두 개로 보여주는 장식용 placeholder입니다.
class _StampsPlaceholder extends StatelessWidget {
  const _StampsPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                _StampCircle(label: '첫콘', color: Color(0xFFD64545), angle: -0.12),
                SizedBox(width: 10),
                _StampCircle(label: '막콘', color: Color(0xFF4A5FBF), angle: 0.10),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '도장 기능 준비 중',
            style: TextStyle(
              fontSize: context.sp(11),
              fontWeight: FontWeight.w700,
              color: Colors.black.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// 도장이 찍힐 자리(흐린 잉크 원) placeholder.
class _StampCircle extends StatelessWidget {
  final String label;
  final Color color;
  final double angle;

  const _StampCircle({
    required this.label,
    required this.color,
    required this.angle,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.3), width: 2.2),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: context.sp(13),
              fontWeight: FontWeight.w900,
              letterSpacing: 1,
              color: color.withValues(alpha: 0.35),
            ),
          ),
        ),
      ),
    );
  }
}

// [백엔드 수정]
// /concerts/{concertId}/setlist → /tickets/{ticketId}/setlist.
// 티켓 기준 라우트로 날짜를 자동으로 확인. 게스트도 이제 서버 ticketId를
// 가지므로, 예전에 있던 concertId 기준 게스트 전용 폴백은 제거.
/// "실제 셋리스트" 포스트잇 안에 들어가는 내용. ticketId가 있으면
/// `GET /tickets/{ticketId}/setlist`로 실제 데이터를 불러오고, 없거나
/// 아직 등록 전이면 안내 문구 표시.
class _RealSetlistContent extends StatefulWidget {
  final String? ticketId;

  const _RealSetlistContent({required this.ticketId});

  @override
  State<_RealSetlistContent> createState() => _RealSetlistContentState();
}

class _RealSetlistContentState extends State<_RealSetlistContent> {
  final ConcertDetailService _service = ConcertDetailService();
  List<SongEntry>? _songs;
  List<String> _artistNames = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ticketId = widget.ticketId;
    if (ticketId == null) return;
    try {
      final res = await _service.getRealSetlist(ticketId);
      if (!mounted) return;
      setState(() {
        // [백엔드 수정]
        // 앙코르가 시작되는 지점에 구분선(build에서 처리).
        _songs = res.songs;
        // [백엔드 수정] artistNames도 같이 저장(build()에서 아티스트별 그룹핑에 사용).
        _artistNames = res.artistNames;
      });
    } on ApiException catch (_) {
      // 조회 자체가 실패하면(네트워크 오류 등) 조용히 안내 문구를 유지합니다.
    } catch (_) {}
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.music_note_outlined,
            size: 22,
            color: Colors.black.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 6),
          Text(
            '아직 등록되지\n않았어요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(12),
              fontWeight: FontWeight.w700,
              color: Colors.black.withValues(alpha: 0.35),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final songs = _songs ?? const <SongEntry>[];
    if (songs.isEmpty && _artistNames.length <= 1) return _buildEmptyState();

    final songsByArtist = <String, List<SongEntry>>{};
    final untaggedSongs = <SongEntry>[];
    for (final song in songs) {
      final artist = song.artist;
      if (artist != null && artist.isNotEmpty) {
        songsByArtist.putIfAbsent(artist, () => []).add(song);
      } else {
        untaggedSongs.add(song);
      }
    }

    // [백엔드 수정] artistNames와 songs의 아티스트 태그를 합쳐서 그룹 뼈대를 만듦.
    final allArtists = [
      ..._artistNames,
      for (final name in songsByArtist.keys)
        if (!_artistNames.contains(name)) name,
    ];

    // 아티스트가 1명 이하(단독 공연, 또는 아티스트 태그 정보 자체가 없는 옛날
    // 데이터)면 기존처럼 번호 목록.
    if (allArtists.length <= 1 && untaggedSongs.isEmpty) {
      final only = allArtists.isEmpty ? songs : songsByArtist[allArtists.first]!;
      if (only.isEmpty) return _buildEmptyState();
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _buildRealSongRows(context, only),
        ),
      );
    }

    final groupList = [
      for (final name in allArtists)
        MapEntry<String?, List<SongEntry>>(name, songsByArtist[name] ?? const []),
      if (untaggedSongs.isNotEmpty)
        MapEntry<String?, List<SongEntry>>(null, untaggedSongs),
    ];

    return SingleChildScrollView(
      child: _RealSetlistGroupedByArtist(groups: groupList),
    );
  }
}

// [백엔드 수정]
// 곡마다 번호 매긴 Row + 앙코르 시작 지점 구분선을 만드는 헬퍼.
// 단독 공연 목록/아코디언 펼친 목록 둘 다 재사용
List<Widget> _buildRealSongRows(BuildContext context, List<SongEntry> songs) {
  return [
    for (var i = 0; i < songs.length; i++) ...[
      if (songs[i].encore && (i == 0 || !songs[i - 1].encore))
        const _EncoreDivider(),
      Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              (i + 1).toString().padLeft(2, '0'),
              style: TextStyle(
                fontSize: context.sp(11),
                fontWeight: FontWeight.w900,
                color: Colors.black.withValues(alpha: 0.35),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                songs[i].name,
                style: TextStyle(
                  fontSize: context.sp(12),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  ];
}

// [백엔드 수정]
/// 페스티벌 실제 셋리 - 아티스트 이름을 나열해두고, 누른 아티스트만 곡
/// 목록이 펼쳐지는 아코디언(예상 셋리와 동일한 UX). 
/// 한 번에 하나만 펼쳐지고, 목록 순서는 그대로 유지한 채 
/// 펼친 아티스트 위치로 화면 스크롤.
class _RealSetlistGroupedByArtist extends StatefulWidget {
  final List<MapEntry<String?, List<SongEntry>>> groups;

  const _RealSetlistGroupedByArtist({required this.groups});

  @override
  State<_RealSetlistGroupedByArtist> createState() =>
      _RealSetlistGroupedByArtistState();
}

class _RealSetlistGroupedByArtistState
    extends State<_RealSetlistGroupedByArtist> {
  int? _expandedIndex;
  late final List<GlobalKey> _sectionKeys = [
    for (var _ in widget.groups) GlobalKey(),
  ];

  void _toggle(int index) {
    final willExpand = _expandedIndex != index;
    setState(() => _expandedIndex = willExpand ? index : null);
    if (!willExpand) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _sectionKeys[index].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var g = 0; g < widget.groups.length; g++)
          Padding(
            key: _sectionKeys[g],
            padding: EdgeInsets.only(
              bottom: g == widget.groups.length - 1 ? 0 : 4,
            ),
            child: _RealSetlistArtistSection(
              artistName: widget.groups[g].key ?? '아티스트 미상',
              songs: widget.groups[g].value,
              expanded: g == _expandedIndex,
              onTap: () => _toggle(g),
            ),
          ),
      ],
    );
  }
}

class _RealSetlistArtistSection extends StatelessWidget {
  final String artistName;
  final List<SongEntry> songs;
  final bool expanded;
  final VoidCallback onTap;

  const _RealSetlistArtistSection({
    required this.artistName,
    required this.songs,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Icon(
                  expanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 16,
                  color: Colors.black.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(
                    artistName,
                    style: TextStyle(
                      fontSize: context.sp(12.5),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2, bottom: 8),
            // [백엔드 수정] songs가 비면 빈 공간 대신 안내 문구 표시.
            child: songs.isEmpty
                ? Text(
                    '아직 채워지지 않았어요',
                    style: TextStyle(
                      fontSize: context.sp(11.5),
                      fontWeight: FontWeight.w600,
                      color: Colors.black.withValues(alpha: 0.35),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildRealSongRows(context, songs),
                  ),
          ),
      ],
    );
  }
}

// [백엔드 수정]
/// 실제 셋리 곡 목록 중 앙코르가 시작되는 지점에 한 번만 표시하는 구분선.
class _EncoreDivider extends StatelessWidget {
  const _EncoreDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Container(height: 1, color: Colors.black.withValues(alpha: 0.15)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              'ENCORE',
              style: TextStyle(
                fontSize: context.sp(9.5),
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
                color: Colors.black.withValues(alpha: 0.4),
              ),
            ),
          ),
          Expanded(
            child: Container(height: 1, color: Colors.black.withValues(alpha: 0.15)),
          ),
        ],
      ),
    );
  }
}
