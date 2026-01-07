import 'dart:convert';
import 'dart:io';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

class GreetingService {
  static final AudioPlayer _player = AudioPlayer();

  static Future<void> speakGreeting(String text) async {
    if (text.trim().isEmpty) return;

    final apiKey = dotenv.env['OPENAI_API_KEY']?.trim();
    if (apiKey == null || apiKey.isEmpty) return;

    // stop any previous playback
    try {
      if (_player.playing) await _player.stop();
    } catch (_) {}

    try {
      final uri = Uri.parse('https://api.openai.com/v1/audio/speech');

      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'gpt-4o-mini-tts',
          'voice': 'alloy',
          'input': text,
        }),
      );

      if (resp.statusCode < 200 || resp.statusCode >= 300) return;

      final tmp = await getTemporaryDirectory();
      final file = File(
        '${tmp.path}/greeting_${DateTime.now().millisecondsSinceEpoch}.mp3',
      );
      await file.writeAsBytes(resp.bodyBytes, flush: true);

      await _player.setFilePath(file.path);
      await _player.play();
    } catch (_) {}
  }
}
