import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'api.dart';
import 'session.dart';
import 'theme.dart';
import 'screens/splash.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final baseUrl = await Api.defaultBaseUrl();
  final api = Api(baseUrl: baseUrl);
  runApp(
    Provider<Api>.value(
      value: api,
      child: ChangeNotifierProvider(
        create: (_) => AppSession(api)..init(),
        child: const MovieServerApp(),
      ),
    ),
  );
}

class MovieServerApp extends StatelessWidget {
  const MovieServerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MovieServer',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const SplashScreen(),
    );
  }
}