import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'presentation/screens/shell_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const ProviderScope(child: AudioUsbApp()));
}

class AudioUsbApp extends StatelessWidget {
  const AudioUsbApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Multitrack USB Audio',
      theme: appTheme(),
      themeMode: ThemeMode.dark,
      home: const ShellScreen(),
    );
  }
}