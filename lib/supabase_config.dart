// Project URL and anon public key only - both are meant to ship inside the
// app (Row-Level Security in the database is the real access boundary, not
// secrecy of these two values). The service-role key and database password
// must NEVER be placed in this file or anywhere else in the app.
class SupabaseConfig {
  static const String url = 'https://wlfyurewbkwxyboxiabl.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndsZnl1cmV3Ymt3eHlib3hpYWJsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI1NjgyODcsImV4cCI6MjEwODE0NDI4N30.ieUCojLiQc4XwnfZk6f3AjnJxe8jkvUysZQB2GWKjIQ';
}
