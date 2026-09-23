import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import 'api_client.dart';

/// 이미지 파일을 업로드해 접근 가능한 URL을 받아오는 서비스의 인터페이스.
abstract class UploadService {
  /// 공연 사진 업로드(`POST /upload/concert-photo`).
  Future<String> uploadConcertPhoto(XFile image);

  // [백엔드 수정] 기기에서 만든 썸네일을 같이 올림 (thumbnail 필드)
  /// 공연 사진 + 썸네일 업로드. 반환값은 (원본 URL, 썸네일 URL).
  Future<(String, String?)> uploadConcertPhotoBytes(
    Uint8List image, {
    Uint8List? thumbnail,
  });
}

// [백엔드 수정]
// 게스트도 카카오와 동일하게 이 서비스로 서버(S3)에 업로드하도록 변경.
// 예전엔 게스트면 LocalTicketStore.saveImageLocally로 기기에만 저장하는
// GuestAwareUploadService를 대신 썼는데, 그 분기를 제거하고 이 클래스
// 하나로 통일함(호출부는 concert_after_page_contents.dart 참고).
/// 백엔드 `/upload/*` 연동 구현체. 업로드된 파일은 S3에 저장되고, 응답의
/// `url`을 그대로 티켓의 `concert_photo_urls`에 이어붙여 저장하면 됩니다.
class BackendUploadService implements UploadService {
  BackendUploadService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  @override
  Future<String> uploadConcertPhoto(XFile image) async {
    final Uint8List bytes = await image.readAsBytes();
    final json = await _client.postMultipart(
      '/upload/concert-photo',
      fileField: 'image', // 백엔드 upload_concert_photo(image: UploadFile = File(...))와 일치
      fileBytes: bytes,
      filename: image.name.isNotEmpty ? image.name : 'concert_photo.jpg',
    );
    return json['url'] as String;
  }

  @override
  Future<(String, String?)> uploadConcertPhotoBytes(
    Uint8List image, {
    Uint8List? thumbnail,
  }) async {
    final json = await _client.postMultipart(
      '/upload/concert-photo',
      fileField: 'image',
      fileBytes: image,
      filename: 'concert_photo.jpg',
      extraFiles: thumbnail == null
          ? null
          : {'thumbnail': (thumbnail, 'concert_photo_thumb.jpg')},
    );
    return (json['url'] as String, json['thumb_url'] as String?);
  }
}
