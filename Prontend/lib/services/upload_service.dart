import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';

import 'api_client.dart';
import 'auth_service.dart';
import 'local_ticket_store.dart';

/// 이미지 파일을 업로드해 접근 가능한 URL(또는 로컬 경로)을 받아오는
/// 서비스의 인터페이스.
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

/// 게스트 로그인 상태면 서버에 업로드하지 않고 기기 로컬에만 사진을
/// 저장합니다(앱을 지우면 함께 사라짐). 카카오 로그인 상태면 그대로
/// [BackendUploadService]로 S3에 업로드합니다.
///
/// Flutter Web은 파일 시스템이 없어 [LocalTicketStore.saveImageLocally]를
/// 쓸 수 없으므로, 웹에서는 게스트여도 그냥 백엔드 업로드로 동작합니다.
class GuestAwareUploadService implements UploadService {
  GuestAwareUploadService({UploadService? backend})
    : _backend = backend ?? BackendUploadService();

  final UploadService _backend;

  @override
  Future<String> uploadConcertPhoto(XFile image) async {
    if (!kIsWeb && AuthService.instance.isGuest) {
      return LocalTicketStore.instance.saveImageLocally(image);
    }
    return _backend.uploadConcertPhoto(image);
  }
}
