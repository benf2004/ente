import 'package:ente_auth/core/configuration.dart';
import 'package:ente_auth/l10n/l10n.dart';
import 'package:ente_auth/models/profile.dart';
import 'package:ente_auth/onboarding/view/onboarding_page.dart';
import 'package:ente_auth/services/profile_service.dart';
import 'package:ente_auth/ui/home_page.dart';
import 'package:ente_auth/ui/settings/components/auth_settings_item.dart';
import 'package:ente_auth/ui/settings/components/auth_settings_page_scaffold.dart';
import 'package:ente_auth/utils/dialog_util.dart';
import 'package:ente_components/ente_components.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:logging/logging.dart';

/// Lists the vaults the user is signed in to, and switches between them.
class ProfilesSettingsPage extends StatefulWidget {
  const ProfilesSettingsPage({super.key});

  @override
  State<ProfilesSettingsPage> createState() => _ProfilesSettingsPageState();
}

class _ProfilesSettingsPageState extends State<ProfilesSettingsPage> {
  final _logger = Logger('ProfilesSettingsPage');
  bool _isBusy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final service = ProfileService.instance;
    final contents = <Widget>[];

    for (final profile in service.profiles) {
      final isActive = profile.scope == service.activeScope;
      contents.addAll([
        AuthSettingsItem(
          title: profile.email ?? l10n.offlineVault,
          icon: profile.isOffline
              ? HugeIcons.strokeRoundedCloudOff
              : HugeIcons.strokeRoundedUser,
          showChevron: false,
          trailing: isActive
              ? Icon(
                  Icons.check,
                  color: context.componentColors.primary,
                  size: IconSizes.medium,
                )
              : null,
          onTap: isActive ? null : () => _switchTo(profile),
        ),
        const SizedBox(height: Spacing.sm),
      ]);
    }

    contents.addAll([
      const SizedBox(height: Spacing.md),
      AuthSettingsItem(
        title: l10n.addAccount,
        icon: HugeIcons.strokeRoundedUserAdd01,
        semanticsIdentifier: 'auth_settings_add_account',
        onTap: _isBusy ? null : _addAccount,
      ),
    ]);

    return AuthSettingsPageScaffold(title: l10n.accounts, children: contents);
  }

  Future<void> _switchTo(Profile profile) async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    final dialog = createProgressDialog(context, context.l10n.pleaseWait);
    await dialog.show();
    try {
      await ProfileService.instance.switchTo(profile.scope);
    } catch (e, s) {
      _logger.severe("Failed to switch to $profile", e, s);
      await dialog.hide();
      if (mounted) {
        setState(() => _isBusy = false);
        await showGenericErrorDialog(context: context, error: e);
      }
      return;
    }
    await dialog.hide();
    if (!mounted) return;
    // Rebuild from the root: every page below holds the previous vault's codes.
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomePage()),
      (route) => false,
    );
  }

  Future<void> _addAccount() async {
    setState(() => _isBusy = true);
    final scope = await ProfileService.instance.beginAdd(ProfileKind.online);
    if (!mounted) return;
    // The sign in flow navigates to the home page itself once it completes,
    // and ProfileService commits the new profile when it sees the sign in.
    final signedIn = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const OnboardingPage()));
    if (!mounted) return;
    setState(() => _isBusy = false);
    if (ProfileService.instance.consumeRejectedDuplicateAdd()) {
      // Already signed in as this user; ProfileService put us back on the
      // profile that owns it.
      await showErrorDialog(
        context,
        context.l10n.accounts,
        context.l10n.alreadySignedInToAccount,
      );
      if (mounted) setState(() {});
      return;
    }
    if (signedIn == true || Configuration.instance.hasConfiguredAccount()) {
      return;
    }
    // The user backed out; drop the half configured scope.
    await ProfileService.instance.abortAdd(scope);
    if (mounted) setState(() {});
  }
}
