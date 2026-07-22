import 'package:ente_auth/l10n/l10n.dart';
import 'package:ente_auth/services/profile_service.dart';
import 'package:ente_auth/ui/settings/account_settings_page.dart';
import 'package:ente_auth/ui/settings/profiles_settings_page.dart';
import 'package:ente_components/ente_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the wiring of the account switcher's entry point.
///
/// Note on what this cannot cover: the switcher originally lived in the
/// settings drawer, where it received almost no pointer events at all while
/// still painting and reacting to hover. Every widget test written against
/// that arrangement passed, so these tests prove the row is wired up — not
/// that it is hit testable in a real window.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({
      "profilesV1": [
        '{"scope":"","kind":"online","userID":1,"email":"first@example.org"}',
      ],
      "profilesActiveScope": "",
    });
    await ProfileService.instance.init();
  });

  testWidgets('the account page opens the switcher', (tester) async {
    await _pumpAccountPage(tester);

    await tester.tap(find.text('Switch account'));
    await tester.pumpAndSettle();

    expect(find.byType(ProfilesSettingsPage), findsOneWidget);
  });

  testWidgets('the switcher row keeps working after going back', (
    tester,
  ) async {
    await _pumpAccountPage(tester);

    // The original symptom was intermittency, so a single successful tap
    // proves nothing.
    for (var attempt = 0; attempt < 5; attempt++) {
      await tester.tap(find.text('Switch account'));
      await tester.pumpAndSettle();
      expect(
        find.byType(ProfilesSettingsPage),
        findsOneWidget,
        reason: 'row did not open the switcher on attempt ${attempt + 1}',
      );

      // Popped directly: the settings scaffold uses a custom back button, so
      // tester.pageBack() cannot find one.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(ProfilesSettingsPage), findsNothing);
    }
  });

  testWidgets('the switcher row sits above the account actions', (
    tester,
  ) async {
    await _pumpAccountPage(tester);

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final switcher = tester.getTopLeft(find.text(l10n.switchAccount));
    final changeEmail = tester.getTopLeft(find.text(l10n.changeEmail));

    expect(switcher.dy, lessThan(changeEmail.dy));
  });
}

Future<void> _pumpAccountPage(WidgetTester tester) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ComponentTheme.lightTheme(app: ComponentApp.auth),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const AccountSettingsPage(),
    ),
  );
}
