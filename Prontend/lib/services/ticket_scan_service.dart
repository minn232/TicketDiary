import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../models/ticket_scan.dart';
import 'api_client.dart';

/// 티켓 이미지를 분석해 OCR 추출 결과 + KOPIS 매칭 후보를 받아오는 서비스의 인터페이스.
abstract class TicketScanService {
  Future<TicketScanResponse> scanTicket(XFile image);
}

/// 백엔드 `POST /concerts/scan` 연동 구현체.
///
/// 이미지를 그대로 업로드하면 서버가 Vision API OCR → 정규식 파싱 →
/// KOPIS 실시간 검색까지 한 번에 처리해 [TicketScanResponse]로 돌려줍니다.
class BackendTicketScanService implements TicketScanService {
  BackendTicketScanService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  @override
  Future<TicketScanResponse> scanTicket(XFile image) async {
    final Uint8List bytes = await image.readAsBytes();
    final json = await _client.postMultipart(
      '/concerts/scan',
      fileField: 'image', // 백엔드 scan_ticket(image: UploadFile = File(...))의 파라미터명과 일치
      fileBytes: bytes,
      filename: image.name.isNotEmpty ? image.name : 'ticket.jpg',
    );
    return TicketScanResponse.fromJson(json);
  }
}
