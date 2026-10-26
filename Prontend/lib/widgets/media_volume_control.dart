import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The operating system's media volume, shared with the hardware buttons.
/// No independent per-player volume is stored or restored on startup.
class MediaVolumeControl extends StatelessWidget {
  const MediaVolumeControl({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('미디어 볼륨'),
      const SizedBox(height: 8),
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
        const SizedBox(
          height: 44,
          child: UiKitView(viewType: 'ticketdiary/media_volume'),
        )
      else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
        const SizedBox(
          height: 44,
          child: AndroidView(viewType: 'ticketdiary/media_volume'),
        )
      else
        const Text('기기의 미디어 볼륨으로 조절해 주세요'),
    ],
  );
}
