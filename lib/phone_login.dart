// Real mobile-number OTP login: Firebase sends/verifies the SMS OTP, then the
// "firebase-phone-login" Supabase edge function checks Firebase's signed proof
// and returns a normal Supabase session - so roles, profiles and RLS work
// exactly as before. Falls back to the old Supabase OTP flow when Firebase
// is not configured in this build (see firebase_config.dart).
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'firebase_config.dart';

class PhoneLoginException implements Exception {
  final String message;
  PhoneLoginException(this.message);
  @override
  String toString() => message;
}

class FirebasePhoneLogin {
  static bool ready = false;
  static String? _verificationId;
  static int? _resendToken;

  static Future<void> init() async {
    if (!FirebaseConfig.isConfigured) return;
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: FirebaseConfig.apiKey,
          appId: FirebaseConfig.appId,
          messagingSenderId: FirebaseConfig.messagingSenderId,
          projectId: FirebaseConfig.projectId,
          storageBucket: FirebaseConfig.storageBucket,
        ),
      ).timeout(const Duration(seconds: 10));
      ready = true;
    } catch (_) {
      ready = false;
    }
  }

  static String _friendly(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-phone-number':
        return 'That mobile number is not valid.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a few minutes and try again.';
      case 'quota-exceeded':
        return 'SMS limit reached for now. Please try again later.';
      case 'invalid-verification-code':
        return 'Incorrect OTP. Please check it and try again.';
      case 'session-expired':
      case 'code-expired':
        return 'This OTP has expired. Tap "Resend OTP" to get a new one.';
      case 'network-request-failed':
        return 'No internet connection. Check your network and try again.';
      default:
        return 'Could not complete phone verification (${e.code}). Please try again.';
    }
  }

  // Sends the OTP. Returns true if the phone auto-verified the SMS and
  // Firebase is already signed in (no code entry needed); false when the
  // user should type the OTP. [onAutoVerified] fires if auto-retrieval
  // succeeds later, after the code screen is already showing.
  static Future<bool> sendCode(String phone10, {void Function()? onAutoVerified}) async {
    final done = Completer<bool>();
    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: '+91$phone10',
        timeout: const Duration(seconds: 60),
        forceResendingToken: _resendToken,
        verificationCompleted: (PhoneAuthCredential cred) async {
          try {
            await FirebaseAuth.instance.signInWithCredential(cred);
            if (!done.isCompleted) {
              done.complete(true);
            } else {
              onAutoVerified?.call();
            }
          } catch (_) {
            // Fall through to manual code entry.
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          if (!done.isCompleted) done.completeError(PhoneLoginException(_friendly(e)));
        },
        codeSent: (String id, int? token) {
          _verificationId = id;
          _resendToken = token;
          if (!done.isCompleted) done.complete(false);
        },
        codeAutoRetrievalTimeout: (String id) {
          _verificationId = id;
        },
      );
    } on FirebaseAuthException catch (e) {
      throw PhoneLoginException(_friendly(e));
    }
    return done.future.timeout(const Duration(seconds: 70), onTimeout: () => throw PhoneLoginException('Could not send the OTP. Please try again.'));
  }

  // Checks the typed OTP with Firebase, then exchanges it for a Supabase session.
  static Future<AuthResponse> verifyCode(String code) async {
    final id = _verificationId;
    if (id == null) throw PhoneLoginException('Please request an OTP first.');
    try {
      final cred = PhoneAuthProvider.credential(verificationId: id, smsCode: code);
      await FirebaseAuth.instance.signInWithCredential(cred);
    } on FirebaseAuthException catch (e) {
      throw PhoneLoginException(_friendly(e));
    }
    return exchangeForSupabaseSession();
  }

  static Future<AuthResponse> exchangeForSupabaseSession() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw PhoneLoginException('Phone verification failed. Please try again.');
    final token = await user.getIdToken(true);
    final client = Supabase.instance.client;
    Map<String, dynamic> data;
    try {
      final res = await client.functions.invoke('firebase-phone-login', body: {'idToken': token});
      data = Map<String, dynamic>.from(res.data as Map);
    } on FunctionException catch (e) {
      final d = e.details;
      throw PhoneLoginException(d is Map && d['error'] != null ? d['error'].toString() : 'Could not sign you in. Please try again.');
    }
    if (data['ok'] != true) throw PhoneLoginException((data['error'] ?? 'Could not sign you in.').toString());
    final resp = await client.auth.setSession(data['refresh_token'] as String);
    // The Firebase session has done its job; the app runs on Supabase's.
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    _verificationId = null;
    return resp;
  }
}
