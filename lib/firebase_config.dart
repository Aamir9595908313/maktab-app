// Firebase client configuration (Phone OTP login).
//
// This committed copy is an empty stub so the project always compiles. The
// CI build overwrites this file from the GOOGLE_SERVICES_JSON GitHub secret
// before building (see .github/workflows/build-apk.yml). While [apiKey] is
// empty the app falls back to the previous Supabase OTP login.
class FirebaseConfig {
  static const String apiKey = '';
  static const String appId = '';
  static const String projectId = '';
  static const String messagingSenderId = '';
  static const String storageBucket = '';
  static bool get isConfigured => apiKey.isNotEmpty && appId.isNotEmpty && projectId.isNotEmpty;
}
