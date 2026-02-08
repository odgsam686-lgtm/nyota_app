class GoogleSignInAccount {
  final String? displayName;
  final String? email;

  GoogleSignInAccount({this.displayName, this.email});
}

class GoogleSignIn {
  GoogleSignInAccount? _user;

  Future<GoogleSignInAccount?> signInSilently() async {
    return _user;
  }

  Future<GoogleSignInAccount?> signIn() async {
    _user = GoogleSignInAccount(displayName: "User Stub", email: "user@stub.com");
    return _user;
  }
}
