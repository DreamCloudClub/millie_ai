import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';

import 'pages/home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    print("[Flutter Error] ${details.exception}");
    print(details.stack);
  };

  // Allow both landscape and portrait orientations
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Show status bar (time, battery), hide navigation bar
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: [SystemUiOverlay.top],  // Show status bar only
  );

  // Keep screen awake
  WakelockPlus.enable();

  // Force max brightness
  try {
    await ScreenBrightness().setScreenBrightness(1.0);
  } catch (e) {
    debugPrint("Could not set brightness: $e");
  }

  runApp(const MillieAiApp());
}

class MillieAiApp extends StatelessWidget {
  const MillieAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Millie AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const HomePage(),
    );
  }
}
