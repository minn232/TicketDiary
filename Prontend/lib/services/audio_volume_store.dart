import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AudioVolumeStore extends ChangeNotifier {
  AudioVolumeStore._();
  static final instance = AudioVolumeStore._();
  double effects = 1;
  double music = 1;
  Future<void>? _loading;
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    effects = (prefs.getDouble('effects_volume') ?? 1).clamp(0, 1);
    music = (prefs.getDouble('music_volume') ?? 1).clamp(0, 1);
    notifyListeners();
  }

  Future<void> setVolume(double value, {required bool isMusic}) async {
    await load();
    if (isMusic) {
      music = value.clamp(0, 1);
    } else {
      effects = value.clamp(0, 1);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      isMusic ? 'music_volume' : 'effects_volume',
      value.clamp(0, 1),
    );
  }
}
