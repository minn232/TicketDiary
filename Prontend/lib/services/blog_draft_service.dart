import 'api_client.dart';

/// 블로그 글 정리 상태. 서버 `/tickets/{id}/blog-draft`의 status와 같음.
/// stale: 메모를 고쳐서 다시 정리 대기(이전 정리본은 그대로 있음).
enum BlogDraftStatus { none, pending, done, stale, failed }

class BlogDraft {
  const BlogDraft({
    required this.status,
    this.emotion,
    this.title,
    this.body,
    this.text,
    this.edited = false,
    this.generatedAt,
  });

  static const empty = BlogDraft(status: BlogDraftStatus.none);

  final BlogDraftStatus status;

  /// 유저가 적은 감상 메모 원문.
  final String? emotion;
  final String? title;
  final String? body;

  /// 붙여넣을 글 - 앱에서 고친 게 있으면 그것, 없으면 제목+본문. 정리본이 있으면 상태와 상관없이 옴.
  final String? text;

  /// [text]가 앱에서 고친 글인지.
  final bool edited;
  final DateTime? generatedAt;

  /// 이전에라도 정리된 글이 있는지(stale·failed여도 이전 정리본은 볼 수 있음).
  bool get hasResult => text != null;

  factory BlogDraft.fromJson(Map<String, dynamic> json) => BlogDraft(
    status: BlogDraftStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => BlogDraftStatus.none,
    ),
    emotion: json['emotion'] as String?,
    title: json['title'] as String?,
    body: json['body'] as String?,
    text: json['text'] as String?,
    edited: json['edited'] as bool? ?? false,
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

  /// 메모 저장. 실제 정리는 서버 밤 배치가 함. 같은 메모를 다시 보내면 실패 상태일 때만 다시 정리 대기.
  Future<BlogDraft> save(String ticketId, String emotion) async =>
      BlogDraft.fromJson(
        await _client.post(
          '/tickets/$ticketId/blog-draft',
          body: {'emotion': emotion},
        ),
      );

  /// 앱에서 고친 정리본 저장. 원래 글과 같으면 서버가 고친 기록을 지움.
  Future<BlogDraft> saveText(String ticketId, String text) async =>
      BlogDraft.fromJson(
        await _client.put(
          '/tickets/$ticketId/blog-draft/text',
          body: {'text': text},
        ),
      );
}
