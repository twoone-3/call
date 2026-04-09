import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:window_size/window_size.dart';

import 'src/screens/main_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    setWindowMinSize(const Size(800, 600));
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData();
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final textTheme = baseTheme.textTheme.apply(
      fontFamily: isWindows ? 'Microsoft YaHei UI' : null,
      fontFamilyFallback: isWindows
          ? const ['Microsoft YaHei', 'SimHei', 'SimSun']
          : null,
    );

    return MaterialApp(
      title: 'LAN Chat',
      theme: baseTheme.copyWith(textTheme: textTheme),
      home: const MainScreen(),
    );
  }
}
