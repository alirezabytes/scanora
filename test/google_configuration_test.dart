import 'package:flutter_test/flutter_test.dart';
import 'package:scanora/services/cloud/google_account_service.dart';

void main() {
  test(
      'Google authorization uses official account selection and PKCE without exposing the secret',
      () {
    final uri = GoogleAccountService.authorizationUri(
        redirectUri: 'http://127.0.0.1:45678/oauth2/callback',
        state: 'test-state',
        challenge: 'test-challenge');
    expect(uri.scheme, 'https');
    expect(uri.host, 'accounts.google.com');
    expect(uri.queryParameters['prompt'], contains('select_account'));
    expect(uri.queryParameters['code_challenge_method'], 'S256');
    expect(uri.queryParameters['state'], 'test-state');
    expect(uri.queryParameters.containsKey('client_secret'), isFalse);
  });
  test('A publisher-configured test build has both platform configurations',
      () {
    const supplied = String.fromEnvironment('SCANORA_GOOGLE_DESKTOP_CLIENT_ID');
    if (supplied.isEmpty) return;
    expect(GoogleAccountService.desktopConfigured, isTrue);
    expect(GoogleAccountService.androidConfigured, isTrue);
    expect(GoogleAccountService.desktopClientId, supplied);
  });
}
