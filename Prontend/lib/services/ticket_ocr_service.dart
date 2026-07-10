import 'package:image_picker/image_picker.dart';

import '../models/ticket_info.dart';

/// 티켓 이미지를 분석해 [TicketInfo]를 추출하는 서비스의 인터페이스.
///
/// 실제 OCR/백엔드가 준비되면, 이 인터페이스를 구현하는 새 클래스로
/// 교체하기만 하면 카메라 스캔 화면과 다이어리 쪽 코드는 그대로 재사용할 수 있습니다.
abstract class TicketOcrService {
  Future<TicketInfo> extractTicketInfo(XFile image);
}

/// 실제 OCR/백엔드 연동 전까지 사용하는 목(mock) 구현체.
class MockTicketOcrService implements TicketOcrService {
  const MockTicketOcrService();

  @override
  Future<TicketInfo> extractTicketInfo(XFile image) async {
    // 실제 서버/OCR 연동 전 분석 지연 시뮬레이션
    await Future.delayed(const Duration(milliseconds: 600));

    // 실제 OCR 연동 전까지의 가짜 인식 결과.
    // 공연 날짜는 아직 지나지 않은(미래) 날짜로 둬서, 스캔해서 추가한 티켓이
    // 곧바로 "공연 후"로 자동 전환되지 않고 정상적인 "공연 전" 티켓으로 보이게 합니다.
    return TicketInfo(
      concertName: '알 수 없는 공연',
      venueName: '알 수 없는 공연장',
      date: DateTime.now().add(const Duration(days: 30)),
      price: '0',
      seat: 'A구역 00열 00번',
    );
  }
}
