import 'package:ente_auth/models/code.dart';

/// Which websites a code should be offered for by iOS AutoFill.
///
/// A code carries an issuer ("GitHub"), not a domain, and iOS matches on
/// domains — so this is the whole of the mapping. Two sources, in order:
///
/// 1. the websites the user attached to the code, which sync with it, and
/// 2. the issuer itself when it already reads as a host ("Crypto.com",
///    "Battle.net", "Addy.io").
///
/// Codes that match neither are still offered; they just show up in the
/// extension's searchable list instead of the QuickType bar.
List<String> serviceIdentifiersFor(Code code) {
  final domains = <String>{};
  for (final website in code.display.websites) {
    final normalized = normalizeDomain(website);
    if (normalized != null) domains.add(normalized);
  }
  final fromIssuer = domainFromIssuer(code.issuer);
  if (fromIssuer != null) domains.add(fromIssuer);
  return domains.toList();
}

/// Reduces anything host-shaped the user might type — `https://github.com/login`,
/// `www.GitHub.com`, `github.com` — to the bare host iOS compares against.
/// Returns null for input that cannot be one.
String? normalizeDomain(String input) {
  var value = input.trim().toLowerCase();
  if (value.isEmpty) return null;

  final schemeSeparator = value.indexOf('://');
  if (schemeSeparator != -1) {
    value = value.substring(schemeSeparator + 3);
  }
  // Anything after the host is noise for matching purposes.
  value = value.split('/').first.split('?').first.split('#').first;
  // Credentials and ports, in case a full URL was pasted.
  value = value.split('@').last.split(':').first;
  if (value.startsWith('www.')) {
    value = value.substring(4);
  }
  return _looksLikeHost(value) ? value : null;
}

/// Only issuers that are already domains are converted. Guessing at one for
/// "GitHub" would be wrong more often than right, and a wrong domain means
/// offering the wrong account's code on a login page.
String? domainFromIssuer(String issuer) => normalizeDomain(issuer);

bool _looksLikeHost(String value) {
  if (value.contains(' ') || !value.contains('.')) return false;
  final labels = value.split('.');
  if (labels.length < 2 || labels.any((label) => label.isEmpty)) return false;
  if (!_hostLabel.hasMatch(value)) return false;
  // A letters-only last label, which rejects version-like issuers ("v2.0").
  // Issuers that merely look like hosts without being one ("Node.js") still
  // slip through; they cost nothing beyond an identity that never matches.
  return _tld.hasMatch(labels.last);
}

final _hostLabel = RegExp(r'^[a-z0-9.-]+$');
final _tld = RegExp(r'^[a-z]{2,24}$');
