import 'dart:async';
import 'dart:io';

import 'package:ente_accounts/services/user_service.dart';
import 'package:ente_auth/core/configuration.dart';
import 'package:ente_auth/l10n/l10n.dart';
import 'package:ente_auth/models/profile.dart';
import 'package:ente_auth/onboarding/view/onboarding_page.dart';
import 'package:ente_auth/services/profile_service.dart';
import 'package:ente_auth/store/code_store.dart';
import 'package:ente_auth/ui/components/buttons/button_widget.dart';
import 'package:ente_auth/ui/settings/about_settings_page.dart';
import 'package:ente_auth/ui/settings/account_settings_page.dart';
import 'package:ente_auth/ui/settings/app_version_widget.dart';
import 'package:ente_auth/ui/settings/components/auth_settings_item.dart';
import 'package:ente_auth/ui/settings/components/auth_settings_navigation.dart';
import 'package:ente_auth/ui/settings/components/auth_settings_page_scaffold.dart';
import 'package:ente_auth/ui/settings/data/data_settings_page.dart';
import 'package:ente_auth/ui/settings/data/export_widget.dart';
import 'package:ente_auth/ui/settings/developer_settings_widget.dart';
import 'package:ente_auth/ui/settings/general_settings_page.dart';
import 'package:ente_auth/ui/settings/more_from_ente_section.dart';
import 'package:ente_auth/ui/settings/notification_banner_widget.dart';
import 'package:ente_auth/ui/settings/security_settings_page.dart';
import 'package:ente_auth/ui/settings/social_icons_row.dart';
import 'package:ente_auth/ui/settings/support_settings_page.dart';
import 'package:ente_auth/ui/settings/theme_settings_page.dart';
import 'package:ente_auth/utils/dialog_util.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_lock_screen/local_authentication_service.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// What to show under the Settings title.
///
/// The active profile is the source of truth, as it is for the home app bar.
/// [email] comes from a process wide notifier that the sign in flow writes the
/// moment an address is typed, so on its own it will happily show another
/// profile's email — or one that was never signed in to.
String? settingsSubtitle({
  required Profile? profile,
  required String? email,
  required bool hasLoggedIn,
  required String offlineFallback,
}) {
  if (profile != null) {
    return profile.displayName(offlineFallback);
  }
  return hasLoggedIn ? email : null;
}

/// Whether the Account row (and the switcher behind it) should be shown.
///
/// Any registered profile is enough — in particular a single offline vault,
/// which is not logged in but still needs the switcher to add or reach other
/// vaults; without this row an offline-only user could never add an account.
bool showAccountSection({
  required bool hasLoggedIn,
  required int profileCount,
}) {
  return hasLoggedIn || profileCount > 0;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.emailNotifier,
    required this.scaffoldKey,
  });

  final ValueNotifier<String?> emailNotifier;
  final GlobalKey<ScaffoldState> scaffoldKey;

  @override
  Widget build(BuildContext context) {
    final hasLoggedIn = Configuration.instance.hasConfiguredAccount();
    if (hasLoggedIn) {
      UserService.instance.getUserDetailsV2().ignore();
    }
    return ValueListenableBuilder<String?>(
      valueListenable: emailNotifier,
      builder: (context, email, _) => _buildSettings(
        context,
        hasLoggedIn: hasLoggedIn,
        email: settingsSubtitle(
          profile: ProfileService.instance.activeProfile,
          email: email,
          hasLoggedIn: hasLoggedIn,
          offlineFallback: context.l10n.offlineVault,
        ),
      ),
    );
  }

  Widget _buildSettings(
    BuildContext context, {
    required bool hasLoggedIn,
    required String? email,
  }) {
    final l10n = context.l10n;
    final contents = <Widget>[];
    final showAccount = showAccountSection(
      hasLoggedIn: hasLoggedIn,
      profileCount: ProfileService.instance.profiles.length,
    );
    if (showAccount) {
      contents.add(
        AuthSettingsItem(
          title: l10n.account,
          icon: HugeIcons.strokeRoundedUser,
          semanticsIdentifier: 'auth_settings_account',
          onTap: () =>
              pushAuthSettingsPage(context, const AccountSettingsPage()),
        ),
      );
      contents.add(const SizedBox(height: Spacing.sm));
    }
    if (!hasLoggedIn) {
      contents.add(
        BannerComponent(
          title: l10n.signInToBackup,
          leadingIcon: HugeIcons.strokeRoundedCloudUpload,
          state: BannerComponentState.informative,
          onTap: () => _showBackupReminder(context),
        ),
      );
      contents.add(const SizedBox(height: Spacing.lg));
    }

    contents.addAll([
      AuthSettingsItem(
        title: l10n.data,
        icon: HugeIcons.strokeRoundedDatabase01,
        semanticsIdentifier: 'auth_settings_data',
        onTap: () => _openDataSettings(context),
      ),
      const SizedBox(height: Spacing.sm),
      AuthSettingsItem(
        title: l10n.security,
        icon: HugeIcons.strokeRoundedSecurityCheck,
        semanticsIdentifier: 'auth_settings_security',
        onTap: () =>
            pushAuthSettingsPage(context, const SecuritySettingsPage()),
      ),
    ]);

    if (Platform.isAndroid ||
        Platform.isWindows ||
        Platform.isLinux ||
        kDebugMode) {
      contents.addAll([
        const SizedBox(height: Spacing.sm),
        AuthSettingsItem(
          title: l10n.theme,
          icon: Theme.of(context).brightness == Brightness.light
              ? HugeIcons.strokeRoundedSun03
              : HugeIcons.strokeRoundedMoon02,
          semanticsIdentifier: 'auth_settings_theme',
          onTap: () => pushAuthSettingsPage(context, const ThemeSettingsPage()),
        ),
      ]);
    }

    contents.addAll([
      const SizedBox(height: Spacing.sm),
      AuthSettingsItem(
        title: l10n.general,
        icon: HugeIcons.strokeRoundedSettings01,
        semanticsIdentifier: 'auth_settings_general',
        onTap: () => pushAuthSettingsPage(context, const GeneralSettingsPage()),
      ),
      const SizedBox(height: Spacing.sm),
      AuthSettingsItem(
        title: l10n.support,
        icon: HugeIcons.strokeRoundedHelpCircle,
        semanticsIdentifier: 'auth_settings_support',
        onTap: () => pushAuthSettingsPage(context, const SupportSettingsPage()),
      ),
      const SizedBox(height: Spacing.sm),
      AuthSettingsItem(
        title: l10n.about,
        icon: HugeIcons.strokeRoundedInformationCircle,
        semanticsIdentifier: 'auth_settings_about',
        onTap: () => pushAuthSettingsPage(context, const AboutSettingsPage()),
      ),
    ]);

    if (hasLoggedIn) {
      contents.addAll([
        const SizedBox(height: Spacing.sm),
        AuthSettingsItem(
          title: l10n.logout,
          icon: HugeIcons.strokeRoundedLogout05,
          semanticsIdentifier: 'auth_settings_logout',
          isDestructive: true,
          onTap: () => _logout(context),
        ),
      ]);
    }

    final showMoreFromEnte = Platform.isIOS || Platform.isAndroid;
    if (showMoreFromEnte) {
      contents.addAll([
        const SizedBox(height: 40),
        MoreFromEnteSection(
          currentApp: ComponentApp.auth,
          moreFromLabel: context.strings.moreFrom,
          onAppTap: (app) {
            launchUrlString(
              moreFromEnteUri(
                sourceApp: ComponentApp.auth,
                destinationApp: app,
              ).toString(),
              mode: LaunchMode.externalApplication,
            ).ignore();
          },
        ),
      ]);
    }

    contents.addAll([
      SizedBox(height: showMoreFromEnte ? 40 : Spacing.xxl),
      const SocialIconsRow(),
      const SizedBox(height: Spacing.md),
      const AppVersionWidget(),
      const SizedBox(height: Spacing.xxl),
      const DeveloperSettingsWidget(),
      const NotificationBannerWidget(),
      const SizedBox(height: 60),
    ]);

    return AuthSettingsPageScaffold(
      title: l10n.settings,
      subtitle: email,
      backButton: _closeButton(context),
      children: contents,
    );
  }

  Widget _closeButton(BuildContext context) {
    return Semantics(
      identifier: 'auth_settings_close',
      child: IconButtonComponent(
        tooltip: context.l10n.close,
        variant: IconButtonComponentVariant.unfilled,
        shouldSurfaceExecutionStates: false,
        icon: const HugeIcon(icon: HugeIcons.strokeRoundedCancel01),
        onTap: () => scaffoldKey.currentState?.closeDrawer(),
      ),
    );
  }

  Future<void> _openDataSettings(BuildContext context) async {
    final completed = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const DataSettingsPage()));
    if (completed == true) {
      scaffoldKey.currentState?.closeDrawer();
    }
  }

  Future<void> _showBackupReminder(BuildContext context) async {
    final l10n = context.l10n;
    final result = await showChoiceActionSheet(
      context,
      title: l10n.note,
      body: l10n.sigInBackupReminder,
      secondButtonLabel: l10n.singIn,
      secondButtonAction: ButtonAction.second,
      firstButtonLabel: l10n.exportCodes,
    );
    if (result == null || !context.mounted) return;
    if (result.action == ButtonAction.first) {
      await handleExportClick(context);
      return;
    }
    if (result.action != ButtonAction.second) return;
    final hasCodes = (await CodeStore.instance.getAllCodes()).any(
      (code) => !code.hasError,
    );
    if (!context.mounted) return;
    if (hasCodes) {
      final authenticated = await LocalAuthenticationService.instance
          .requestLocalAuthentication(context, l10n.authToInitiateSignIn);
      if (!authenticated) return;
    }
    if (context.mounted) {
      await pushAuthSettingsPage(context, const OnboardingPage());
    }
  }

  Future<void> _logout(BuildContext context) {
    final l10n = context.l10n;
    // Captured up front: by the time the logout completes this page has been
    // torn down along with the drawer that hosted it.
    final navigator = Navigator.of(context, rootNavigator: true);
    return showChoiceActionSheet(
      context,
      title: l10n.logout,
      body: l10n.areYouSureYouWantToLogout,
      firstButtonLabel: l10n.yesLogout,
      secondButtonLabel: l10n.cancel,
      isCritical: true,
      firstButtonOnTap: () async {
        // Navigation is ours: only after the profile record is gone do we know
        // whether to land on the next profile's home or on onboarding — and
        // the '/' route works that out from the configuration by itself. A
        // thrown logout (server error) skips the removal, as it should.
        await UserService.instance.logout(context, navigate: false);
        // Always remove, even for the last profile: the record must not
        // outlive the account's data, or it shows up as a vault that can
        // never be opened.
        await ProfileService.instance.removeActive();
        unawaited(navigator.pushNamedAndRemoveUntil('/', (route) => false));
      },
    );
  }
}
