import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../providers/auth_provider.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _phoneController = TextEditingController(text: '+86 ');
  final _codeController = TextEditingController();
  String _activeTab = 'sms';

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final auth = ref.watch(authProvider);
    final compact = MediaQuery.sizeOf(context).width < 480;

    return Scaffold(
      body: ColoredBox(
        color: theme.colorScheme.background,
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(compact ? 16 : 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withAlpha(80),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset(
                        'assets/branding/guangya_icon.png',
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '小黄鸭',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.foreground,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '登录以访问您的云端文件',
                    style: TextStyle(
                      fontSize: 15,
                      color: theme.colorScheme.mutedForeground,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Login card
                  ShadCard(
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 18 : 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildTabs(context),
                          const SizedBox(height: 24),
                          if (_activeTab == 'sms')
                            _buildSMSLogin(context, auth)
                          else
                            _buildQRLogin(context, auth),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabs(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.muted,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: _TabButton(
              label: '手机登录',
              isActive: _activeTab == 'sms',
              onTap: () => setState(() => _activeTab = 'sms'),
            ),
          ),
          Expanded(
            child: _TabButton(
              label: '扫码登录',
              isActive: _activeTab == 'qr',
              onTap: () {
                setState(() => _activeTab = 'qr');
                if (_activeTab == 'qr') {
                  ref.read(authProvider.notifier).initQRLogin();
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSMSLogin(BuildContext context, AuthState auth) {
    final theme = ShadTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ShadInput(
          controller: _phoneController,
          placeholder: const Text('手机号'),
          leading: Icon(
            LucideIcons.phone,
            size: 16,
            color: theme.colorScheme.mutedForeground,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ShadInput(
                controller: _codeController,
                placeholder: const Text('验证码'),
                leading: Icon(
                  LucideIcons.keyRound,
                  size: 16,
                  color: theme.colorScheme.mutedForeground,
                ),
              ),
            ),
            const SizedBox(width: 12),
            ShadButton.outline(
              onPressed: auth.codeCountdown > 0
                  ? null
                  : () {
                      ref
                          .read(authProvider.notifier)
                          .updatePhoneNumber(_phoneController.text);
                      ref.read(authProvider.notifier).sendVerificationCode();
                    },
              child: Text(
                auth.codeCountdown > 0 ? '${auth.codeCountdown}s' : '获取验证码',
              ),
            ),
          ],
        ),

        if (auth.errorMessage != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.destructive.withAlpha(20),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.destructive.withAlpha(50),
              ),
            ),
            child: Text(
              auth.errorMessage!,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.destructive,
              ),
            ),
          ),
        ],

        const SizedBox(height: 24),
        ShadButton(
          onPressed: () {
            ref
                .read(authProvider.notifier)
                .updatePhoneNumber(_phoneController.text);
            ref
                .read(authProvider.notifier)
                .updateVerificationCode(_codeController.text);
            ref.read(authProvider.notifier).verifySMSCode();
          },
          child: const Text('登录'),
        ),
      ],
    );
  }

  Widget _buildQRLogin(BuildContext context, AuthState auth) {
    final theme = ShadTheme.of(context);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (auth.qrPayload.isNotEmpty)
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              color: theme.colorScheme.background,
              border: Border.all(color: theme.colorScheme.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: auth.qrPayload,
              version: QrVersions.auto,
              size: 180,
              backgroundColor: Colors.transparent,
            ),
          )
        else
          const SizedBox(
            width: 200,
            height: 200,
            child: Center(child: ShadProgress()),
          ),
        const SizedBox(height: 16),
        Text(
          auth.qrStatus,
          style: TextStyle(
            fontSize: 14,
            color: theme.colorScheme.mutedForeground,
          ),
        ),
        const SizedBox(height: 16),
        ShadButton.outline(
          onPressed: () => ref.read(authProvider.notifier).initQRLogin(),
          leading: const Icon(LucideIcons.refreshCw, size: 16),
          child: const Text('刷新二维码'),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Semantics(
      button: true,
      selected: isActive,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: isActive
                  ? theme.colorScheme.background
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: isActive
                  ? Border.all(color: theme.colorScheme.border)
                  : null,
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                color: isActive
                    ? theme.colorScheme.foreground
                    : theme.colorScheme.mutedForeground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
