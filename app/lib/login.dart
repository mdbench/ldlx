import 'package:flutter/material.dart';
import 'db_service.dart';

class LoginScreen extends StatefulWidget {
  final Function(UserAccount user) onLoginSuccess;

  const LoginScreen({Key? key, required this.onLoginSuccess}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _totpController = TextEditingController();
  
  String? _errorMessage;
  bool _obscurePassword = true;
  bool _isLoading = false;
  
  // State for handling 2FA challenge workflow
  bool _requiresTotp = false;
  UserAccount? _pendingUser;

  Future<void> _handleLogin() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter both username and password.';
      });
      return;
    }

    setState(() => _isLoading = true);

    final user = await DbService().authenticate(username, password);

    setState(() => _isLoading = false);

    if (user != null) {
      // Check if user requires TOTP verification
      if (user.isTotpEnabled) {
        setState(() {
          _requiresTotp = true;
          _pendingUser = user;
          _errorMessage = null;
        });
        return;
      }

      await _completeLogin(user);
    } else {
      await DbService().logFailedLogin(
        ip: '192.168.1.105',
        username: username,
        password: password,
      );

      setState(() {
        _errorMessage = 'Invalid username or password.';
      });
    }
  }

  Future<void> _handleTotpVerification() async {
    final code = _totpController.text.trim();
    if (code.length != 6 || _pendingUser == null) {
      setState(() {
        _errorMessage = 'Please enter a valid 6-digit TOTP code.';
      });
      return;
    }

    setState(() => _isLoading = true);
    final isValid = await DbService().verifyTotp(_pendingUser!, code);
    setState(() => _isLoading = false);

    if (isValid) {
      await _completeLogin(_pendingUser!);
    } else {
      await DbService().logFailedLogin(
        ip: '192.168.1.105',
        username: _pendingUser!.username,
        password: '[TOTP Failure]',
      );
      setState(() {
        _errorMessage = 'Invalid TOTP code. Please try again.';
      });
    }
  }

  Future<void> _completeLogin(UserAccount user) async {
    await DbService().logActivity(
      username: user.username,
      action: 'Authentication',
      details: 'User logged in successfully (with TOTP verification)',
    );
    widget.onLoginSuccess(user);
  }

  void _cancelTotpChallenge() {
    setState(() {
      _requiresTotp = false;
      _pendingUser = null;
      _totpController.clear();
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            width: 420,
            padding: const EdgeInsets.all(32.0),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colorScheme.outlineVariant,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 42,
                  backgroundColor: colorScheme.surface,
                  backgroundImage: const AssetImage('assets/ldlx.jpg'),
                ),
                const SizedBox(height: 16),
                Text(
                  'LDLx Security',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.secondary,
                      ),
                ),
                Text(
                  _requiresTotp ? 'Two-Factor Authentication' : 'Lady of the Data Lake Access Portal',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 32),
                if (_errorMessage != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.error.withOpacity(0.5)),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(color: colorScheme.onErrorContainer, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (!_requiresTotp) ...[
                  TextField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _handleLogin(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _handleLogin(),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: _isLoading
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: colorScheme.onPrimary),
                            )
                          : const Text(
                              'Authenticate',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ] else ...[
                  // TOTP Code Challenge Form
                  Text(
                    'Enter the 6-digit code from your authenticator app for ${_pendingUser?.username ?? ""}.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _totpController,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      labelText: 'TOTP Code',
                      prefixIcon: Icon(Icons.security),
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                    onSubmitted: (_) => _handleTotpVerification(),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleTotpVerification,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: _isLoading
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: colorScheme.onPrimary),
                            )
                          : const Text(
                              'Verify Code',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _cancelTotpChallenge,
                    child: const Text('Back to Login'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}