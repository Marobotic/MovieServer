import 'package:media_kit/media_kit.dart';

Future<void> applySubtitleDelay(Player player, Duration delay) async {
  final p = player.platform;
  if (p is NativePlayer) {
    await p.setProperty(
        'sub-delay', (delay.inMilliseconds / 1000.0).toStringAsFixed(3));
  }
}