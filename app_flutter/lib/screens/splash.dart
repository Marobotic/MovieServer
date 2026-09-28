import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../session.dart';
import '../theme/tokens.dart';
import '../widgets/wordmark.dart';
import 'setup.dart';
import 'home.dart';
import 'login.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final session = context.read<AppSession>();
    // main() already kicked off init(); await that same future instead of
    // firing a second round of /api/capabilities + /api/me.
    await session.ready;
    if (!mounted) return;
    final Widget next;
    if (session.needsSetup) {
      next = const SetupScreen();
    } else if (session.user != null) {
      next = const HomeScreen();
    } else {
      next = const LoginScreen();
    }
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Wordmark(fontSize: 42),
            SizedBox(height: AppSpacing.xxl),
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                color: AppColors.red,
                strokeWidth: 2.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
