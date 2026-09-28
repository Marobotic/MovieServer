import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../session.dart';
import '../theme/breakpoints.dart';
import '../theme/tokens.dart';
import '../widgets/wordmark.dart';
import 'home.dart';

/// Sign-in page. Deliberately knows nothing about who has an account: the
/// server no longer publishes a profile list, so both the username and the
/// password have to be typed.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  late final TextEditingController _server =
      TextEditingController(text: context.read<AppSession>().api.baseUrl);
  final _passFocus = FocusNode();

  bool _busy = false;
  bool _showServer = false;
  bool _obscure = true;
  String _error = '';

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _server.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    final username = _user.text.trim();
    if (username.isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter your username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final session = context.read<AppSession>();
    try {
      if (_showServer && _server.text.trim().isNotEmpty) {
        await session.api.saveServerUrl(_server.text.trim());
      }
      await session.login(username, _pass.text);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final boxed = size.hasTopNav;

    return Scaffold(
      backgroundColor: AppColors.black,
      body: Stack(
        children: [
          const Positioned.fill(child: _LoginBackdrop()),
          Positioned(
            top: size.isCompact ? 20 : 28,
            left: size.gutter,
            child: const Wordmark(fontSize: 30),
          ),
          Positioned.fill(
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: size.isCompact ? AppSpacing.xl : AppSpacing.lg,
                    vertical: 96,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 450),
                    child: Container(
                      padding: EdgeInsets.all(
                          boxed ? AppSpacing.xxxl : AppSpacing.sm),
                      decoration: boxed
                          ? BoxDecoration(
                              color: AppColors.black.withOpacity(0.72),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.panel),
                            )
                          : null,
                      child: _form(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _form() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Sign In',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 32,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        TextField(
          controller: _user,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _passFocus.requestFocus(),
          style: const TextStyle(fontSize: 16),
          decoration: const InputDecoration(labelText: 'Username'),
        ),
        const SizedBox(height: AppSpacing.lg),
        TextField(
          controller: _pass,
          focusNode: _passFocus,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _login(),
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(
              icon: Icon(
                _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                color: AppColors.textTertiary,
                size: 20,
              ),
              tooltip: _obscure ? 'Show password' : 'Hide password',
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.red.withOpacity(0.15),
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(color: AppColors.red.withOpacity(0.5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline,
                    color: AppColors.red, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    _error,
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: _busy ? null : _login,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.textPrimary),
                  )
                : const Text('Sign In'),
          ),
        ),
        if (!kIsWeb) ...[
          const SizedBox(height: AppSpacing.lg),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showServer = !_showServer),
              icon: Icon(
                _showServer ? Icons.expand_less : Icons.dns_outlined,
                size: 18,
                color: AppColors.textSecondary,
              ),
              label: Text(
                _showServer ? 'Hide server settings' : 'Server settings',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              ),
            ),
          ),
          if (_showServer) ...[
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _server,
              keyboardType: TextInputType.url,
              inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://host:8080',
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// Dark gradient wash behind the sign-in card. Intentionally not built from
/// library artwork, so nothing about the library reaches an unauthenticated
/// client.
class _LoginBackdrop extends StatelessWidget {
  const _LoginBackdrop();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-0.3, -0.5),
          radius: 1.3,
          colors: [AppColors.surfaceHigher, Color(0xFF0B0B0B), AppColors.black],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
    );
  }
}
