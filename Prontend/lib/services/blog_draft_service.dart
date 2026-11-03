import 'api_client.dart';

/// 블로그 글 정리 상태. 서버 `/tickets/{id}/blog-draft`의 status와 같음.
enum BlogDraftStatus { none, pending, done, failed }

class BlogDraft {
  const BlogDraft({
    required this.status,
    this.emotion,
    this.title,
    this.body,
    this.text,
    this.generatedAt,
  });

  static const empty = BlogDraft(status: BlogDraftStatus.none);

  final BlogDraftStatus status;

  /// 유저가 적은 감상 메모 원문.
  final String? emotion;
  final String? title;
  final String? body;

  /// 제목+본문을 합친 글(done일 때만).
  final String? text;
  final DateTime? generatedAt;

  factory BlogDraft.fromJson(Map<String, dynamic> json) => BlogDraft(
    status: BlogDraftStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => BlogDraftStatus.none,
    ),
    emotion: json['emotion'] as String?,
    title: json['title'] as String?,
    body: json['body'] as String?,
    text: json['text'] as String?,
    generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? ''),
  );
}

/// 감상 메모 저장/정리 결과 조회.
class BlogDraftService {
  BlogDraftService({ApiClient? client})
    : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  Future<BlogDraft> get(String ticketId) async =>
      BlogDraft.fromJson(await _client.get('/tickets/$ticketId/blog-draft'));

  /// 메모 저장. 실제 정리는 서버 밤 배치가 함.
  Future<BlogDraft> save(String ticketId, String emotion) async =>
      BlogDraft.fromJson(
        await _client.post(
          '/tickets/$ticketId/blog-draft',
          body: {'emotion': emotion},
        ),
      );
}
