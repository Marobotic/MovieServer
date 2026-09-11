import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../session.dart';
import 'home.dart';

class LoginScreen extends StatefulWidget {
  final String initialUsername;

  const LoginScreen({super.key, this.initialUsername = ''});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _user =
      TextEditingController(text: widget.initialUsername);
  final _pass = TextEditingController();
  late final TextEditingController _server =
      TextEditingController(text: context.read<AppSession>().api.baseUrl);
  bool _busy = false;
  bool _showServer = false;
  String _error = '';

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    final session = context.read<AppSession>();
    try {
      if (_showServer && _server.text.trim().isNotEmpty) {
        await session.api.saveServerUrl(_server.text.trim());
      }
      await session.login(_user.text.trim(), _pass.text);
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'MOVIESERVER',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFE50914),
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _user,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _pass,
                    obscureText: true,
                    onSubmitted: (_) => _login(),
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(_error,
                        style: const TextStyle(color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 22),
                  ElevatedButton(
                    onPressed: _busy ? null : _login,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Sign in'),
                  ),
                  if (!kIsWeb) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => setState(() => _showServer = !_showServer),
                      child: Text(_showServer ? 'Hide server settings' : 'Server settings'),
                    ),
                    if (_showServer) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _server,
                        decoration: const InputDecoration(
                          labelText: 'Server URL (http://host:port)',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                        keyboardType: TextInputType.url,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}