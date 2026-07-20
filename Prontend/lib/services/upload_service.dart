import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import 'api_client.dart';

/// 이미지 파일을 업로드해 접근 가능한 URL을 받아오는 서비스의 인터페이스.
abstract class UploadService {
  /// 공연 사진 업로드(`POST /upload/concert-photo`).
  Future<String> uploadConcertPhoto(XFile image);
}

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
}
