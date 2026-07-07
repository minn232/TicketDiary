/// 스캔한 티켓의 공연 이름이 백엔드에 등록된 공연과 일치하는지 확인하는 서비스의 인터페이스.
///
/// 실제 백엔드 API가 준비되면, 이 인터페이스를 구현하는 새 클래스로
/// 교체하기만 하면 다이어리 화면 쪽 코드는 그대로 재사용할 수 있습니다.
abstract class ConcertLookupService {
  /// [concertName]이 백엔드에 등록된 공연 목록에 존재하면 true를 반환합니다.
  Future<bool> exists(String concertName);
}

/// 실제 백엔드 연동 전까지 사용하는 목(mock) 구현체.
/// 아래 목록에 있는 이름만 "등록된 공연"으로 간주합니다.
class MockConcertLookupService implements ConcertLookupService {
  const MockConcertLookupService();

  static const List<String> _mockRegisteredConcerts = [
    '알 수 없는 공연',
  ];

  @override
  Future<bool> exists(String concertName) async {
    // 실제 서버 조회 지연 시뮬레이션
    await Future.delayed(const Duration(milliseconds: 400));

    final normalized = concertName.trim();
    if (normalized.isEmpty) return false;

    return _mockRegisteredConcerts.any(
      (name) => name.toLowerCase() == normalized.toLowerCase(),
    );
  }
}
