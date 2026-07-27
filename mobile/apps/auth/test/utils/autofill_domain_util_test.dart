import 'package:ente_auth/models/code.dart';
import 'package:ente_auth/models/code_display.dart';
import 'package:ente_auth/utils/autofill_domain_util.dart';
import 'package:flutter_test/flutter_test.dart';

Code _code(String issuer, {List<String> websites = const []}) =>
    Code.fromAccountAndSecret(
      Type.totp,
      'person@example.com',
      issuer,
      'JBSWY3DPEHPK3PXP',
      CodeDisplay(websites: websites),
      Code.defaultDigits,
    );

void main() {
  group('normalizeDomain', () {
    test('reduces a pasted URL to its host', () {
      expect(normalizeDomain('https://www.GitHub.com/login?x=1'), 'github.com');
      expect(normalizeDomain('http://example.com:8443/path'), 'example.com');
      expect(normalizeDomain('user@example.com:443'), 'example.com');
    });

    test('accepts a bare host', () {
      expect(normalizeDomain('accounts.google.com'), 'accounts.google.com');
      expect(normalizeDomain('  Crypto.com '), 'crypto.com');
    });

    test('rejects anything that is not a host', () {
      expect(normalizeDomain('GitHub'), isNull);
      expect(normalizeDomain('Amazon Web Services'), isNull);
      expect(normalizeDomain('v2.0'), isNull);
      expect(normalizeDomain(''), isNull);
      expect(normalizeDomain('example.'), isNull);
    });
  });

  group('serviceIdentifiersFor', () {
    test('uses the issuer when it already reads as a host', () {
      expect(serviceIdentifiersFor(_code('Crypto.com')), ['crypto.com']);
    });

    test('leaves a plain issuer unmatched rather than guessing a domain', () {
      // Such codes are still reachable through the extension's search.
      expect(serviceIdentifiersFor(_code('GitHub')), isEmpty);
    });

    test('normalises and de-duplicates the user supplied websites', () {
      final identifiers = serviceIdentifiersFor(
        _code(
          'GitHub',
          websites: ['https://github.com/login', 'www.github.com', 'gist.github.com'],
        ),
      );
      expect(identifiers, ['github.com', 'gist.github.com']);
    });

    test('combines the issuer host with the user supplied websites', () {
      final identifiers = serviceIdentifiersFor(
        _code('Battle.net', websites: ['blizzard.com']),
      );
      expect(identifiers, containsAll(['blizzard.com', 'battle.net']));
    });
  });
}
