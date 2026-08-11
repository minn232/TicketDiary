import 'package:flutter/material.dart';

import '../models/notification_model.dart';
import '../services/api_client.dart';
import '../services/notifications_service.dart';

// [백엔드 수정]
// 인앱 알림함 (GET/PATCH/DELETE /notifications)
// 디자인은 신경 쓰지 않고 기본 Material 위젯으로 기능만 최소한으로 구현.
/// 인앱 알림함. 설정 화면 등에서 진입.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final NotificationsService _service = NotificationsService();
  late Future<List<NotificationModel>> _future;

  @override
  void initState() {
    super.initState();
    _future = _service.list();
  }

  Future<void> _refresh() async {
    setState(() => _future = _service.list());
    await _future;
  }

  Future<void> _markRead(NotificationModel item) async {
    if (item.isRead) return;
    try {
      await _service.markRead(item.id);
      await _refresh();
    } catch (_) {
      // 실패해도 조용히 무시 — 다음 조회 시 다시 안읽음으로 보일 뿐.
    }
  }

  Future<void> _delete(NotificationModel item) async {
    try {
      await _service.delete(item.id);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      final message = e is ApiException ? e.message : '잠시 후 다시 시도해주세요.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('삭제하지 못했어요: $message')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('알림함')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<NotificationModel>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              final error = snapshot.error;
              final message = error is ApiException
                  ? '오류 (${error.statusCode})'
                  : '오류 (연결 실패)';
              return _CenteredMessage(message: '알림을 불러오지 못했어요.\n$message');
            }
            final items = snapshot.data ?? const [];
            if (items.isEmpty) {
              return const _CenteredMessage(message: '알림이 없습니다.');
            }
            return ListView.separated(
              itemCount: items.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  title: Text(
                    item.title,
                    style: TextStyle(
                      fontWeight: item.isRead ? FontWeight.normal : FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    '${item.body}\n${item.scheduledAt.toLocal()}',
                  ),
                  isThreeLine: true,
                  onTap: () => _markRead(item),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(item),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final String message;

  const _CenteredMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}
