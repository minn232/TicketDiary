import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kakao_flutter_sdk_share/kakao_flutter_sdk_share.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 카카오 개발자 콘솔 "TicketDiaryAndroid" 네이티브 앱 키 (APK에 들어가는 공개값).
/// AndroidManifest의 `kakao<키>://kakaolink` 스킴과 같은 값이어야 함.
const String kKakaoNativeAppKey = '66ebd719ee4ce10d2f97764064e0351b';

/// 인스타 스토리 공유에 필요한 Meta 앱 ID.
const String kFacebookAppId = '1554560296442575';

/// 인스타 스토리 배경 (공유 카드 배경과 같은 가죽색).
const String _kStoryTopColor = '#765840';
const String _kStoryBottomColor = '#5C4033';

/// 설치 여부 (설치된 앱 아이콘만 보여줌).
typedef ShareApps = ({bool instagram, bool x, bool kakao});

/// 인스타(스토리/피드)·X·카카오톡(카드/사진)을 선택창 없이 바로 공유. 지금은 안드로이드만.
class ExternalShareService {
  ExternalShareService._();

  static const MethodChannel _channel = MethodChannel(
    'ticketdiary/share_targets',
  );

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 앱 시작 때 한 번 (실패해도 카카오 카드만 안 됨).
  static Future<void> initKakao() async {
    if (!_isAndroid) return;
    try {
      await KakaoSdk.init(nativeAppKey: kKakaoNativeAppKey);
    } catch (e) {
      debugPrint('[Kakao] 초기화 실패(무시): $e');
    }
  }

  static const ShareApps _none = (instagram: false, x: false, kakao: false);

  static Future<ShareApps> installedApps() async {
    if (!_isAndroid) return _none;
    try {
      final m = await _channel.invokeMapMethod<String, bool>('installed');
      if (m == null) return _none;
      return (
        instagram: m['instagram'] ?? false,
        x: m['x'] ?? false,
        kakao: m['kakao'] ?? false,
      );
    } catch (_) {
      return _none;
    }
  }

  /// 다음 공유 때 비움 (받는 앱이 나중에 읽을 수 있음).
  static Future<List<String>> _writeFiles(List<Uint8List> pngs) async {
    final temp = await getTemporaryDirectory();
    final dir = Directory('${temp.path}/share_export');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return [
      for (var i = 0; i < pngs.length; i++)
        (await File(
          '${dir.path}/ticketdiary_${stamp}_$i.png',
        ).writeAsBytes(pngs[i])).path,
    ];
  }

  static Future<bool> _send(
    String method,
    List<Uint8List> pngs, [
    Map<String, Object> extra = const {},
  ]) async {
    final paths = await _writeFiles(pngs);
    return await _channel.invokeMethod<bool>(method, {
          'paths': paths,
          ...extra,
        }) ??
        false;
  }

  /// [png]를 스티커로 올린 인스타 스토리 편집 화면.
  static Future<bool> instagramStory(Uint8List png) => _send(
    'instagramStory',
    [png],
    {
      'appId': kFacebookAppId,
      'topColor': _kStoryTopColor,
      'bottomColor': _kStoryBottomColor,
    },
  );

  /// 인스타 피드 게시 화면 (여러 장이면 캐러셀).
  static Future<bool> instagramFeed(List<Uint8List> pngs) =>
      _send('instagramFeed', pngs);

  /// X 글쓰기 화면에 이미지 첨부.
  static Future<bool> x(List<Uint8List> pngs) => _send('x', pngs);

  /// 카카오톡 친구 선택 화면으로 이미지 그대로.
  static Future<bool> kakaoPhoto(List<Uint8List> pngs) =>
      _send('kakaoPhoto', pngs);

  /// 카드/버튼 모두 앱을 엶 (보여줄 웹 페이지가 아직 없어 웹 주소는 안 넣음).
  static final Link _appLink = Link(
    androidExecutionParams: const {'from': 'share'},
    iosExecutionParams: const {'from': 'share'},
  );

  /// 이미지를 카카오 서버에 올린 뒤 피드 카드로 공유. 카카오톡이 없으면 웹 공유 화면.
  static Future<void> shareKakaoCard({
    required Uint8List png,
    required String title,
    required String description,
  }) async {
    final upload = await ShareClient.instance.uploadImage(byteData: png);
    final image = upload.infos.original;
    final template = FeedTemplate(
      content: Content(
        title: title,
        description: description.isEmpty ? null : description,
        imageUrl: Uri.parse(image.url),
        imageWidth: image.width,
        imageHeight: image.height,
        link: _appLink,
      ),
      buttons: [Button(title: '앱에서 보기', link: _appLink)],
    );
    if (await ShareClient.instance.isKakaoTalkSharingAvailable()) {
      await ShareClient.instance.shareDefault(template: template);
      return;
    }
    final url = await WebSharerClient.instance.makeDefaultUrl(
      template: template,
    );
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }
}
