enum ProfileKind { online, offline }

/// A single vault the user can switch to.
///
/// Each profile owns an isolated slice of storage, identified by [scope]: the
/// prefix applied to its preference and secure storage keys, and to its
/// database filenames. The profile that existed before multi-account support
/// uses an empty scope, so its data continues to live where it always has.
class Profile {
  final String scope;
  final ProfileKind kind;
  final int? userID;
  final String? email;

  /// A name the user gave this vault. Offline vaults have no email to identify
  /// them by, so without one they are all just "Offline vault".
  final String? label;

  const Profile({
    required this.scope,
    required this.kind,
    this.userID,
    this.email,
    this.label,
  });

  bool get isOffline => kind == ProfileKind.offline;

  /// True for the account that predates multi-account support.
  bool get isLegacy => scope.isEmpty;

  /// What to call this vault in the switcher and the app bar. [offlineFallback]
  /// is passed in rather than read here so the model stays free of l10n.
  String displayName(String offlineFallback) {
    final named = label?.trim();
    if (named != null && named.isNotEmpty) return named;
    return email ?? offlineFallback;
  }

  // No copyWith: its `?? this.x` pattern cannot clear a field, which is
  // exactly what clearing a label needs — callers build a new Profile instead.

  Map<String, dynamic> toMap() {
    return {
      'scope': scope,
      'kind': kind.name,
      'userID': userID,
      'email': email,
      'label': label,
    };
  }

  static Profile fromMap(Map<String, dynamic> map) {
    return Profile(
      scope: map['scope'] as String,
      kind: ProfileKind.values.firstWhere(
        (k) => k.name == map['kind'],
        orElse: () => ProfileKind.online,
      ),
      userID: map['userID'] as int?,
      email: map['email'] as String?,
      label: map['label'] as String?,
    );
  }

  @override
  String toString() => "Profile(scope: '$scope', kind: ${kind.name})";
}
