import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import '../native_bridge_service.dart';
import 'desktop_token_store.dart';

/// The publisher supplies its own OAuth clients at build time. End users only
/// choose an account and grant Drive access in Google's UI.
class GoogleAccountService {
  static const desktopClientId =
      String.fromEnvironment('SCANORA_GOOGLE_DESKTOP_CLIENT_ID');
  static const _desktopSecret =
      String.fromEnvironment('SCANORA_GOOGLE_DESKTOP_CLIENT_SECRET');
  static const _androidServerId =
      String.fromEnvironment('SCANORA_GOOGLE_WEB_CLIENT_ID');
  static const scopes = ['https://www.googleapis.com/auth/drive.file'];
  static bool get desktopConfigured =>
      desktopClientId.isNotEmpty && _desktopSecret.isNotEmpty;
  static bool get androidConfigured => _androidServerId.isNotEmpty;

  static Uri authorizationUri(
          {required String redirectUri,
          required String state,
          required String challenge,
          bool isPersian = false}) =>
      Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': desktopClientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': scopes.join(' '),
        'access_type': 'offline',
        'prompt': 'select_account consent',
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'hl': isPersian ? 'fa' : 'en',
      });
  static String configurationMissing(bool isPersian) => isPersian
      ? 'اتصال گوگل در این نسخه پیکربندی نشده است. از OCR آفلاین استفاده کنید.'
      : 'Google sign-in is not configured in this build. Use offline OCR.';

  static String callbackPage({required bool success, required bool isPersian}) {
    final message = success
        ? (isPersian
            ? 'اتصال گوگل تأیید شد. به Scanora برگردید.'
            : 'Google access verified. Return to Scanora.')
        : (isPersian
            ? 'اتصال گوگل انجام نشد. به Scanora برگردید و دوباره تلاش کنید.'
            : 'Google sign-in failed. Return to Scanora and try again.');
    return '<!doctype html><html lang="${isPersian ? 'fa' : 'en'}" dir="${isPersian ? 'rtl' : 'ltr'}"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Scanora</title><main><h1>Scanora</h1><p>$message</p></main></html>';
  }

  static Map<String, dynamic>? _session;
  static GoogleSignInAccount? _androidAccount;
  static Future<void>? _androidInit;
  static Future<String?>? _refreshing;

  static Future<void> _initializeAndroid() =>
      _androidInit ??= GoogleSignIn.instance.initialize(
          serverClientId: _androidServerId.isEmpty ? null : _androidServerId);

  static Future<Map<String, dynamic>?> _load() async {
    if (_session != null) return _session;
    final raw = await DesktopTokenStore.read();
    if (raw != null) _session = jsonDecode(raw) as Map<String, dynamic>;
    return _session;
  }

  static Future<void> _save(Map<String, dynamic> value) async {
    await DesktopTokenStore.write(jsonEncode(value));
    _session = value;
  }

  static Future<String?> accessToken() =>
      _refreshing ??= _accessToken().whenComplete(() => _refreshing = null);

  static Future<String?> _accessToken() async {
    if (Platform.isAndroid) {
      if (_androidServerId.isEmpty) return null;
      await _initializeAndroid();
      _androidAccount ??=
          await GoogleSignIn.instance.attemptLightweightAuthentication();
      return (await _androidAccount?.authorizationClient
              .authorizationForScopes(scopes))
          ?.accessToken;
    }
    final session = await _load();
    if (session == null || session['clientId'] != desktopClientId) return null;
    if ((session['expiry'] as int? ?? 0) >
        DateTime.now().millisecondsSinceEpoch + 60000) {
      return session['accessToken'] as String?;
    }
    final refresh = session['refreshToken'] as String?;
    if (refresh == null || refresh.isEmpty) return null;
    final client = http.Client();
    try {
      final response = await client
          .post(Uri.https('oauth2.googleapis.com', '/token'), body: {
        'client_id': desktopClientId,
        if (_desktopSecret.isNotEmpty) 'client_secret': _desktopSecret,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
      }).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      final tokens = jsonDecode(response.body) as Map<String, dynamic>;
      final access = tokens['access_token'] as String?;
      if (access == null || access.isEmpty) return null;
      await _save({
        ...session,
        'accessToken': access,
        'expiry': DateTime.now().millisecondsSinceEpoch +
            ((tokens['expires_in'] as num?)?.toInt() ?? 3600) * 1000
      });
      return access;
    } finally {
      client.close();
    }
  }

  /// Verifies Drive access and obtains the profile from Google, never from a
  /// locally entered email address or a manufactured token.
  static Future<Map<String, String>?> verifiedProfile() async {
    final access = await accessToken();
    if (access == null) return null;
    return _profile(access);
  }

  static Future<Map<String, String>> _profile(String access) async {
    final client = http.Client();
    try {
      final response = await client.get(
        Uri.https('www.googleapis.com', '/drive/v3/about', {'fields': 'user'}),
        headers: {'Authorization': 'Bearer $access'},
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw StateError(
            'Google Drive authorization check failed (HTTP ${response.statusCode}).');
      }
      final user = (jsonDecode(response.body) as Map<String, dynamic>)['user']
          as Map<String, dynamic>;
      final email = user['emailAddress'] as String?;
      if (email == null || email.isEmpty) {
        throw StateError('Google returned no account profile.');
      }
      return {'email': email, 'name': user['displayName'] as String? ?? email};
    } finally {
      client.close();
    }
  }

  static Future<Map<String, String>> authorize({bool isPersian = false}) async {
    if (Platform.isAndroid) {
      if (_androidServerId.isEmpty) {
        throw StateError(configurationMissing(isPersian));
      }
      await _initializeAndroid();
      // Explicit sign-in shows the native device account chooser.
      await GoogleSignIn.instance.signOut();
      final account =
          await GoogleSignIn.instance.authenticate(scopeHint: scopes);
      final auth = await account.authorizationClient.authorizeScopes(scopes);
      final profile = await _profile(auth.accessToken);
      _androidAccount = account;
      return profile;
    }
    if (!Platform.isWindows) {
      throw StateError('Google sign-in is supported on Android and Windows.');
    }
    if (desktopClientId.isEmpty) {
      throw StateError(configurationMissing(isPersian));
    }
    final random = Random.secure();
    String nonce() =>
        base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
            .replaceAll('=', '');
    final state = nonce();
    final verifier = nonce();
    final challenge =
        base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final callback = 'http://127.0.0.1:${server.port}/oauth2/callback';
    final result = Completer<Map<String, String>>();
    final client = http.Client();
    final subscription = server.listen((request) async {
      if (request.uri.path != '/oauth2/callback' ||
          request.uri.queryParameters['state'] != state) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      if (result.isCompleted) {
        await request.response.close();
        return;
      }
      try {
        final code = request.uri.queryParameters['code'];
        if (code == null || code.isEmpty) {
          throw StateError('Google sign-in was cancelled or denied.');
        }
        final response = await client
            .post(Uri.https('oauth2.googleapis.com', '/token'), body: {
          'client_id': desktopClientId,
          if (_desktopSecret.isNotEmpty) 'client_secret': _desktopSecret,
          'code': code,
          'code_verifier': verifier,
          'redirect_uri': callback,
          'grant_type': 'authorization_code',
        }).timeout(const Duration(seconds: 25));
        if (response.statusCode != 200) {
          throw StateError(
              'Google authorization code exchange failed (HTTP ${response.statusCode}).');
        }
        final tokens = jsonDecode(response.body) as Map<String, dynamic>;
        final access = tokens['access_token'] as String?;
        if (access == null || access.isEmpty) {
          throw StateError('Google returned no access token.');
        }
        final profile = await _profile(access);
        await _save({
          'clientId': desktopClientId,
          'accessToken': access,
          'refreshToken': tokens['refresh_token'],
          'expiry': DateTime.now().millisecondsSinceEpoch +
              ((tokens['expires_in'] as num?)?.toInt() ?? 3600) * 1000
        });
        request.response.headers.contentType = ContentType.html;
        request.response
            .write(callbackPage(success: true, isPersian: isPersian));
        await request.response.close();
        result.complete(profile);
      } catch (error, stack) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.headers.contentType = ContentType.html;
        request.response
            .write(callbackPage(success: false, isPersian: isPersian));
        await request.response.close();
        if (!result.isCompleted) result.completeError(error, stack);
      }
    });
    try {
      final launched = await NativeBridgeService.openUrlInBrowser(
          authorizationUri(
                  redirectUri: callback,
                  state: state,
                  challenge: challenge,
                  isPersian: isPersian)
              .toString());
      if (!launched) throw StateError('Could not open the system browser.');
      final profile = await result.future.timeout(const Duration(minutes: 4));
      await NativeBridgeService.bringAppToFront();
      return profile;
    } finally {
      client.close();
      await subscription.cancel();
      await server.close(force: true);
    }
  }

  static Future<void> disconnect() async {
    if (Platform.isAndroid) {
      await _initializeAndroid();
      await GoogleSignIn.instance.disconnect();
      _androidAccount = null;
    }
    _session = null;
    if (Platform.isWindows) await DesktopTokenStore.clear();
  }
}
