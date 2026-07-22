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

  const Profile({
    required this.scope,
    required this.kind,
    this.userID,
    this.email,
  });

  bool get isOffline => kind == ProfileKind.offline;

  /// True for the account that predates multi-account support.
  bool get isLegacy => scope.isEmpty;

  Profile copyWith({int? userID, String? email}) {
    return Profile(
      scope: scope,
      kind: kind,
      userID: userID ?? this.userID,
      email: email ?? this.email,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'scope': scope,
      'kind': kind.name,
      'userID': userID,
      'email': email,
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
    );
  }

  @override
  String toString() => "Profile(scope: '$scope', kind: ${kind.name})";
}
