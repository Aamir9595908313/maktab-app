import 'dart:async';
import 'dart:convert';
import 'dart:math' show pi;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'state.dart';
import 'guest_tools.dart';
import 'supabase_config.dart';
import 'sadqa_peti.dart';
import 'prayer_notifications.dart';
import 'monthly_members.dart';

final AppState st = AppState();
const Color kGreen = Color(0xFF054D00);
const Color kGold = Color(0xFFD4A72C);

SupabaseClient get sb => Supabase.instance.client;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Registers the notification channel/plugin so the OS already knows
  // about it by the time the user opens Prayer Times and turns the toggle
  // on. Deliberately not awaited - this must never delay the first screen,
  // and it does no network I/O of its own (that only happens when
  // PrayerNotificationService.scheduleUpcoming() is actually called).
  unawaited(PrayerNotificationService.initialize());
  // Connecting to Supabase must never block the app from showing a screen:
  // if it's awaited directly in main() and the connection is slow, blocked,
  // or the device has no network yet, the app sits on a blank screen with
  // nothing to show and no way to retry, which looks exactly like a freeze.
  // Instead, runApp() happens immediately and MaktabApp itself shows a
  // small splash while connecting, with a hard timeout and a Retry screen
  // if it fails.
  runApp(const MaktabApp());
}

Future<void> _connectSupabase() =>
    Supabase.initialize(url: SupabaseConfig.url, anonKey: SupabaseConfig.anonKey).timeout(const Duration(seconds: 12));

// Maps the Supabase schema's role names to the names the rest of this app
// already uses everywhere (tabsFor, roleLabel, etc.) - only 'super_admin'
// and 'madrasa_admin' differ, every other role name matches as-is.
String _mapDbRole(String dbRole) {
  switch (dbRole) {
    case 'super_admin':
      return 'super';
    case 'madrasa_admin':
      return 'admin';
    default:
      return dbRole;
  }
}

// Called right after Supabase Auth confirms the OTP. Reads the matching
// user_profiles row (created automatically by the on_auth_user_created
// database trigger the first time this phone number signs in) plus any
// madrasa scope/teacher assignment rows, and turns all of that into the
// same Account object the rest of the app already expects. Returns null if
// no user_profiles row exists yet (should not normally happen - the
// trigger creates it - but a network hiccup right after sign-up could
// beat it, so the caller retries a couple of times before giving up).
Future<Account?> loadSupabaseProfile(String uid) async {
  final profile = await sb.from('user_profiles').select().eq('id', uid).maybeSingle();
  if (profile == null) return null;

  String roleName = '';
  if (profile['custom_role_id'] != null) {
    final roleRow = await sb.from('roles').select('name').eq('id', profile['custom_role_id'] as Object).maybeSingle();
    roleName = (roleRow?['name'] as String?) ?? '';
  }

  final scopeRows = await sb.from('user_madrasa_scope').select('madrasas(name)').eq('user_id', uid);
  final branches = [for (final r in (scopeRows as List)) ((r['madrasas'] as Map?)?['name'] as String?) ?? ''].where((n) => n.isNotEmpty).toList();

  // Ordered (this join table has no created_at to order by, so madrasa_id
  // is the next best stable key): without an explicit order, Postgres
  // doesn't guarantee row order, so which Maktab lands first in
  // teachMadrasas (and therefore which one teacherMadrasa defaults to on
  // login, further down) was effectively random from one load to the
  // next - a multi-Maktab teacher could land on a branch with zero
  // students and see "0" where they expected their usual one. Ordering
  // makes it the same Maktab every time, even if not always "the first
  // one assigned".
  final tcaRows = await sb.from('teacher_class_assignments').select('madrasas(name), classes(class_no)').eq('teacher_id', uid).order('madrasa_id');
  final teachMadrasas = <String>{for (final r in (tcaRows as List)) ((r['madrasas'] as Map?)?['name'] as String?) ?? ''}..removeWhere((n) => n.isEmpty);
  // Real (Maktab, class) pairs this teacher is actually assigned to, for
  // the My Day screen - see ClassAssignment/myDay() in state.dart.
  final myClasses = <ClassAssignment>[
    for (final r in (tcaRows as List))
      if (((r['madrasas'] as Map?)?['name'] as String?)?.isNotEmpty == true && (r['classes'] as Map?)?['class_no'] != null)
        ClassAssignment((r['madrasas'] as Map)['name'] as String, (r['classes'] as Map)['class_no'] as int),
  ];

  return Account(
    // Supabase Auth always stores phone with the country code
    // (919595908315), but every student record's parent_phone/
    // student_phone is saved as a plain 10-digit number via this app's
    // own digits() normalizer (see addStudentRemote/editStudentRemote).
    // Without normalizing here too, st.kids() (parentPhone == u.phone)
    // could never match, so a parent or student login always showed "No
    // child is linked to this number." even though the right student
    // existed - this is the actual fix for that, not a data problem.
    digits((profile['phone'] as String?) ?? ''),
    (profile['full_name'] as String?) ?? 'User',
    _mapDbRole((profile['base_role'] as String?) ?? 'student'),
    roleName: roleName,
    branches: branches,
    teachMadrasas: teachMadrasas.toList(),
    myClasses: myClasses,
    active: (profile['is_active'] as bool?) ?? true,
    dbId: uid,
  );
}

// Loads Master Data (Madrasas and Courses) from Supabase and replaces the
// app's in-memory copies with it. Called right after a successful login.
// Students, Classes and Teachers stay on in-memory demo data for now - this
// is the first slice of Master Data to move to the real database; the rest
// follow in later rounds once this one is confirmed working.
//
// Deliberately non-fatal: if this fails (e.g. a brief network hiccup right
// after login), the app keeps showing whatever it already had (the demo
// seed data on first run, or the last successful load) rather than
// blocking or crashing - the Master Data screen's pull-to-refresh-style
// "Add" buttons will simply fail with a clear message if Supabase truly
// isn't reachable, which is enough signal to retry.
Future<void> loadMasterData() async {
  try {
    final madrasaRows = await sb.from('madrasas').select().order('name');
    st.setMadrasasFromDb([
      for (final r in (madrasaRows as List))
        MadrasaRec((r['name'] as String?) ?? '', active: (r['is_active'] as bool?) ?? true, category: r['category'] as String?, dbId: r['id'] as String?),
    ]);

    final courseRows = await sb.from('courses').select().order('name');
    var i = 1;
    st.setCoursesFromDb([
      for (final r in (courseRows as List))
        Course(
          i++,
          (r['name'] as String?) ?? '',
          (r['description'] as String?) ?? '',
          code: (r['course_code'] as String?) ?? '',
          active: (r['is_active'] as bool?) ?? true,
          dbId: r['id'] as String?,
        ),
    ]);

    final classRows = await sb.from('classes').select().order('class_no');
    st.setClassDefsFromDb([
      for (final r in (classRows as List))
        ClassDef(
          r['class_no'] as int,
          (r['name'] as String?) ?? '',
          pageBased: (r['page_based'] as bool?) ?? false,
          bookName: r['book_name'] as String?,
          totalPages: (r['total_pages'] as int?) ?? 0,
          active: (r['is_active'] as bool?) ?? true,
          isCore: (r['is_core'] as bool?) ?? false,
          dbId: r['id'] as String?,
        ),
    ]);

    // Classes must already be loaded (just above) to turn each row's
    // class_id (a uuid) back into the class number (1, 2, 3...) the rest
    // of the app keys everything off; same idea for madrasa_id -> name.
    final madrasaNameById = {for (final m in st.madrasas) if (m.dbId != null) m.dbId!: m.name};
    final classNoById = {for (final cd in st.classDefs.values) if (cd.dbId != null) cd.dbId!: cd.id};
    final studentRows = await sb.from('students').select().order('created_at');
    var sid = 1;
    st.setStudentsFromDb([
      for (final r in (studentRows as List))
        Student(
          id: sid++,
          key: (r['student_key'] as String?) ?? '',
          name: (r['name'] as String?) ?? '',
          gender: (r['gender'] as String?) ?? 'Male',
          cls: classNoById[r['class_id'] as String?] ?? 1,
          madrasa: madrasaNameById[r['madrasa_id'] as String?] ?? 'Hanfi',
          start: (r['admission_date'] as String?) ?? kToday,
          parentPhone: (r['parent_phone'] as String?) ?? '',
          studentPhone: (r['student_phone'] as String?) ?? '',
          aadhaar: (r['aadhaar_file_ref'] as String?) != null && r['aadhaar_file_ref'] != 'not_uploaded',
          address: (r['address'] as String?) ?? '',
          status: (r['is_active'] as bool?) ?? true ? 'Active' : 'Inactive',
          dob: r['dob'] as String?,
          fatherName: (r['father_name'] as String?) ?? '',
          batch: (r['batch'] as String?) ?? 'Morning',
          dbId: r['id'] as String?,
        ),
    ]);

    await loadTeachers();
    await loadChapters();
    await loadClassParas();
    await loadClassBooks();
    await loadClassCourseAssignments();
    await loadAttendance();
    await loadAttendanceSessions();
    await loadEvents();
    await loadNotifTemplates();
    await loadAboutUsData();
    await loadSyllabusProgress();
    await loadBookProgress();
    await loadCourseEnrollments();
    await loadMyTeacherAttendance();
    await loadAllTeacherAttendanceToday();
    await loadComplaints();
    await loadCustomRoles();
    await loadCommitteeMembers();
    await loadFees();
    await loadAnnouncements();
    await loadLeaves();
    await loadSadqaCollectors(); // needed first: decides whether this account can even see Sadqa Peti screens
    await loadSadqaPetis();
    await loadSadqaCollections();
    await loadAdminNotifications();
  } catch (_) {
    // Swallow - see note above. The Master Data screen still works off
    // whatever was already loaded; a retry happens next time this is
    // called (e.g. next login) or the user can be told to check their
    // connection if "Add" keeps failing.
  } finally {
    // Set even on failure, so a dashboard gated on dataLoaded doesn't get
    // stuck on a permanent loading screen if Supabase genuinely couldn't
    // be reached - it falls through to showing whatever counts it has
    // (0, if nothing loaded) same as before this flag existed.
    if (!st.dataLoaded) {
      st.dataLoaded = true;
      st.notifyListeners();
    }
  }
}

// ---------------- Realtime: live updates across devices ----------------
// Without this, two people testing at the same time only see each other's
// changes after a manual refresh/re-login. This listens for any insert,
// update or delete on the tables the app cares about and reloads
// everything shortly after - a little wasteful compared to patching just
// the one changed row, but far more robust with 11 students and a handful
// of madrasas/classes: nothing to get subtly out of sync.
bool _realtimeStarted = false;
Timer? _realtimeDebounce;

void _scheduleRealtimeReload() {
  _realtimeDebounce?.cancel();
  _realtimeDebounce = Timer(const Duration(milliseconds: 500), () {
    unawaited(loadMasterData());
  });
}

void subscribeRealtime() {
  if (_realtimeStarted) return;
  _realtimeStarted = true;
  const tables = [
    'madrasas',
    'classes',
    'courses',
    'class_course_assignments',
    'course_enrollments',
    'class_books',
    'book_progress',
    'maktab_events',
    'notification_templates',
    'about_us',
    'students',
    'teacher_class_assignments',
    'user_profiles',
    'pending_role_invites',
    'student_attendance',
    'attendance_sessions',
    'teacher_attendance',
    'syllabus_progress',
    'complaints',
    'chapters',
    'roles',
    'role_permissions',
    'fees_monthly',
    'receipts',
    'announcements',
    'teacher_leaves',
    'admin_notifications',
  ];
  var channel = sb.channel('app-data-sync');
  for (final t in tables) {
    channel = channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: t,
      callback: (payload) => _scheduleRealtimeReload(),
    );
  }
  channel.subscribe();
}

String? _madrasaDbId(String name) {
  for (final m in st.madrasas) {
    if (m.name == name) return m.dbId;
  }
  return null;
}

String? _classDbId(int cls) => st.classDefs[cls]?.dbId;

// ---------------- Student attendance (public.student_attendance) ----------------
//
// Loads today's marks (draft or final) for whichever students are already
// in memory, plus each student's full history of final-submitted absent
// days (what KidAttendance / attPct show). RLS already scopes this
// correctly per role (teacher/admin see their madrasa, a parent sees only
// their own child's rows, super admin sees everything), so one unfiltered
// query is enough - the database does the filtering.
Future<void> loadAttendance() async {
  final idByDbId = {for (final s in st.students) if (s.dbId != null) s.dbId!: s};
  if (idByDbId.isEmpty) return;

  final todayRows = await sb.from('student_attendance').select('student_id, status').eq('attendance_date', kToday);
  final today = <int, String>{};
  for (final r in (todayRows as List)) {
    final s = idByDbId[r['student_id'] as String?];
    if (s != null) today[s.id] = (r['status'] as String?) == 'absent' ? 'A' : 'P';
  }
  st.setTodayAttendanceFromDb(today);

  final historyRows = await sb.from('student_attendance').select('student_id, attendance_date').eq('status', 'absent').eq('is_draft', false);
  final history = <int, List<String>>{};
  for (final r in (historyRows as List)) {
    final s = idByDbId[r['student_id'] as String?];
    if (s == null) continue;
    final d = r['attendance_date'] as String?;
    if (d == null) continue;
    history.putIfAbsent(s.id, () => []).add(d);
  }
  st.setAbsentHistoryFromDb(history);
}

// One tap = one upsert (draft). Updates the local view first so the button
// highlights instantly, then saves - if the save fails, Final Submit will
// retry it, and the tap already reflected locally so the teacher sees no
// difference. Nothing to save for a student who isn't in the database yet.
Future<void> setAttRemote(Student s, String v) async {
  st.setAtt(s.id, v);
  if (s.dbId == null) return;
  try {
    await sb.from('student_attendance').upsert({
      'student_id': s.dbId,
      'madrasa_id': _madrasaDbId(s.madrasa),
      'class_id': _classDbId(s.cls),
      'attendance_date': kToday,
      'status': v == 'A' ? 'absent' : 'present',
      'is_draft': true,
    }, onConflict: 'student_id,attendance_date');
  } catch (_) {
    // Will be retried as part of Final Submit's own upsert.
  }
}

// ---------------- Teacher Attendance: session verify & final submit (public.attendance_sessions) ----------------
//
// Loads every attendance session already on file (so the UI knows, per
// Maktab+class+batch+date, whether the next submit is a first-time
// submission or an authorized correction over something already locked).
Future<void> loadAttendanceSessions() async {
  try {
    final rows = await sb
        .from('attendance_sessions')
        .select('madrasa_id, class_id, batch, attendance_date, total_expected, present_count, absent_count, correction_count, submitted_at, submitted_by, madrasas(name)');
    final clsIdByDbId = {for (final e in st.classDefs.entries) if (e.value.dbId != null) e.value.dbId!: e.key};
    final userIds = <String>{for (final r in (rows as List)) if (r['submitted_by'] != null) r['submitted_by'] as String};
    final nameByUser = <String, String>{};
    if (userIds.isNotEmpty) {
      final profRows = await sb.from('user_profiles').select('id, name').inFilter('id', userIds.toList());
      for (final r in (profRows as List)) {
        nameByUser[r['id'] as String] = (r['name'] as String?) ?? '';
      }
    }
    final map = <String, AttendanceSessionMeta>{};
    for (final r in rows) {
      final madrasaName = (r['madrasas'] as Map?)?['name'] as String?;
      final cls = clsIdByDbId[r['class_id'] as String?];
      final batch = r['batch'] as String?;
      final date = r['attendance_date'] as String?;
      if (madrasaName == null || cls == null || batch == null || date == null) continue;
      map[st.attSessionKey(madrasaName, cls, batch, date)] = AttendanceSessionMeta(
        totalExpected: (r['total_expected'] as int?) ?? 0,
        presentCount: (r['present_count'] as int?) ?? 0,
        absentCount: (r['absent_count'] as int?) ?? 0,
        correctionCount: (r['correction_count'] as int?) ?? 0,
        submittedByName: nameByUser[r['submitted_by'] as String?],
        submittedAt: DateTime.tryParse((r['submitted_at'] as String?) ?? ''),
      );
    }
    st.setAttendanceSessionsFromDb(map);
  } catch (_) {}
}

// ---------------- Super Admin: missing-attendance notifications (public.admin_notifications) ----------------
//
// Only a Super Admin account can ever see rows here - RLS (`admin_notifications_super_read`)
// refuses the select for anyone else, so this is a safe no-op for every other role rather than
// something that needs a role check here too. Before loading, asks the backend to resolve any
// missing_attendance/configuration_missing alerts that are now stale (attendance since submitted,
// or the class now has a batch configured) - cheap, safe to call every time, and keeps what the
// Super Admin sees in sync with reality without waiting for tonight's job.
Future<void> loadAdminNotifications() async {
  if (st.user?.role != 'super') {
    st.setAdminNotificationsFromDb(const []);
    return;
  }
  try {
    try {
      await sb.rpc('resolve_missing_attendance_notifications');
    } catch (_) {
      // Best-effort freshen; the list below still loads whatever is on file.
    }
    final rows = await sb.from('admin_notifications').select().order('created_at', ascending: false);
    st.setAdminNotificationsFromDb([for (final r in (rows as List)) AdminNotification.fromJson(r as Map<String, dynamic>)]);
  } catch (_) {
    // Swallow, same as the rest of loadMasterData - whatever was already
    // loaded (or nothing, on first run) stays as-is until the next reload.
  }
}

Future<void> markAdminNotificationRead(String id) async {
  st.markAdminNotificationReadLocal(id);
  try {
    await sb.from('admin_notifications').update({'is_read': true, 'read_at': DateTime.now().toIso8601String()}).eq('id', id);
  } catch (_) {}
}

Future<void> markAllAdminNotificationsRead() async {
  st.markAllAdminNotificationsReadLocal();
  try {
    await sb.from('admin_notifications').update({'is_read': true, 'read_at': DateTime.now().toIso8601String()}).eq('is_read', false);
  } catch (_) {}
}

// sentNow: this call did the claiming, caller should send the alert now.
// alreadySent: some earlier call (individual submission, or an earlier
// final submit) already claimed and sent it - correctly deduplicated, not
// a failure, nothing to retry.
// failed: the claim attempt itself errored (e.g. offline) - a real
// candidate for "Retry failed notifications".
enum NotifyOutcome { sentNow, alreadySent, failed }

// Claims the one-time right to send the absence alert for one student on
// one date by flipping student_attendance.absence_notified_at from null to
// now() - the update only matches (and only one caller ever gets a
// non-empty result back) the first time this is attempted for that exact
// student+date, so a retried submission, a second device, or the later
// final batch submission re-covering a student already individually
// submitted can never send the same alert twice.
Future<NotifyOutcome> _claimAbsenceNotification(Student s, String date) async {
  if (s.dbId == null) return NotifyOutcome.failed;
  try {
    final claimed = await sb
        .from('student_attendance')
        .update({'absence_notified_at': DateTime.now().toIso8601String()})
        .eq('student_id', s.dbId as Object)
        .eq('attendance_date', date)
        .isFilter('absence_notified_at', null)
        .select();
    if (claimed is List && claimed.isNotEmpty) return NotifyOutcome.sentNow;
    final row = await sb.from('student_attendance').select('absence_notified_at').eq('student_id', s.dbId as Object).eq('attendance_date', date).maybeSingle();
    if (row != null && row['absence_notified_at'] != null) return NotifyOutcome.alreadySent;
    return NotifyOutcome.failed;
  } catch (_) {
    return NotifyOutcome.failed;
  }
}

// Individual per-student attendance submission (the Submit button next to
// one student, independent of the rest of the class/batch): saves that
// student's Present/Absent as a draft row right away - the same row the
// later final submit_attendance_session call will lock - and, only for
// Absent, claims and sends the parent notification immediately rather than
// waiting for the final batch submission. Safe to call again for the same
// student+date: the upsert simply re-saves the same row, and the
// notification claim only succeeds once.
// date defaults to today, but the Mark Attendance screen also uses this for
// the previous two days (its "last 3 days" edit window) - for a date whose
// session isn't finalized yet this plain upsert is exactly right, whether
// it's a first submission or the Teacher editing their own earlier choice,
// since the backend lock (fn_lock_submitted_attendance) only blocks writes
// to a row that's already final. Editing a row in an already-finalized
// session must go through editFinalizedStudentRemote below instead.
Future<String?> submitOneAttendanceRemote(Student s, String status, {required String madrasa, required int cls, required String date}) async {
  if (s.dbId == null) return 'This student is not saved to the database yet.';
  try {
    await sb.from('student_attendance').upsert({
      'student_id': s.dbId,
      'madrasa_id': _madrasaDbId(madrasa),
      'class_id': _classDbId(cls),
      'attendance_date': date,
      'status': status == 'A' ? 'absent' : 'present',
      'is_draft': true,
    }, onConflict: 'student_id,attendance_date');
  } on PostgrestException catch (e) {
    return e.message;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
  st.setAttOneForDate(date, s.id, status);
  if (status == 'A' && s.status == 'Active') {
    if (await _claimAbsenceNotification(s, date) == NotifyOutcome.sentNow) {
      st.sendAbsenceNotification(s, madrasa, date);
    }
  }
  return null;
}

// Loads one past date's attendance for whichever students are already in
// memory, caching it in st.attByDate - used by the Mark Attendance screen's
// "last 3 days" date switcher. Today itself is never loaded here; todayAtt
// already stays current via loadAttendance()/realtime sync.
Future<void> loadAttendanceForDate(String date) async {
  if (date == kToday) return;
  final idByDbId = {for (final s in st.students) if (s.dbId != null) s.dbId!: s};
  if (idByDbId.isEmpty) return;
  try {
    final rows = await sb.from('student_attendance').select('student_id, status').eq('attendance_date', date);
    final map = <int, String>{};
    for (final r in (rows as List)) {
      final s = idByDbId[r['student_id'] as String?];
      if (s != null) map[s.id] = (r['status'] as String?) == 'absent' ? 'A' : 'P';
    }
    st.setAttByDateFromDb(date, map);
  } catch (_) {}
}

// Result of a Verify and Submit Attendance attempt: a null error means the
// database accepted the submission (completeness, scope and batch were all
// valid) - notifiedCount/retryNeeded report how the absence alerts went,
// separately, since a notification failure must never be treated as the
// submission itself having failed.
class AttendanceSubmitResult {
  final String? error;
  final int notifiedCount;
  final List<Student> retryNeeded;
  AttendanceSubmitResult({this.error, this.notifiedCount = 0, List<Student>? retryNeeded}) : retryNeeded = retryNeeded ?? [];
}

// The single path to finally submit (or correct) a Teacher Attendance
// session. All completeness/scope/batch validation happens inside the
// submit_attendance_session database function - this wrapper never decides
// those things itself, it only calls the function, reflects what it did
// into the local model, and then (only for students marked Absent, and
// only once the call itself succeeded) attempts the parent notification.
Future<AttendanceSubmitResult> submitAttendanceSessionRemote({
  required String madrasa,
  required int cls,
  required String batch,
  required String date,
  required List<Student> present,
  required List<Student> absent,
  String? reason,
}) async {
  final madrasaId = _madrasaDbId(madrasa);
  final classId = _classDbId(cls);
  if (madrasaId == null || classId == null) {
    return AttendanceSubmitResult(error: 'This Maktab or class is not saved to the database yet.');
  }
  final presentIds = [for (final s in present) if (s.dbId != null) s.dbId!];
  final absentIds = [for (final s in absent) if (s.dbId != null) s.dbId!];
  Map<String, dynamic> map;
  try {
    final res = await sb.rpc('submit_attendance_session', params: {
      'p_madrasa_id': madrasaId,
      'p_class_id': classId,
      'p_batch': batch,
      'p_date': date,
      'p_present_ids': presentIds,
      'p_absent_ids': absentIds,
      'p_reason': reason,
    });
    map = (res as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
  } on PostgrestException catch (e) {
    return AttendanceSubmitResult(error: e.message);
  } catch (_) {
    return AttendanceSubmitResult(error: 'Could not submit. Check your internet connection and try again.');
  }

  st.recordSessionSubmission(present: present, absent: absent, date: date);
  final wasCorrection = map['was_correction'] == true;
  final prevCorrections = st.sessionFor(madrasa, cls, batch, date)?.correctionCount ?? 0;
  st.setAttendanceSessionLocal(
    madrasa,
    cls,
    batch,
    date,
    AttendanceSessionMeta(
      dbId: map['session_id'] as String?,
      totalExpected: present.length + absent.length,
      presentCount: present.length,
      absentCount: absent.length,
      submittedByName: st.user?.name,
      submittedAt: DateTime.now(),
      correctionCount: wasCorrection ? prevCorrections + 1 : 0,
    ),
  );

  // Parent absence notifications: only for students marked Absent. Most
  // will already have been notified during their own individual Submit -
  // that's the normal case now and is never treated as a failure or
  // offered a retry; only an actual claim error counts as something to
  // retry.
  var notified = 0;
  final retryNeeded = <Student>[];
  for (final s in absent) {
    if (s.status != 'Active' || s.dbId == null) continue;
    final outcome = await _claimAbsenceNotification(s, date);
    if (outcome == NotifyOutcome.sentNow) {
      st.sendAbsenceNotification(s, madrasa, date);
      notified++;
    } else if (outcome == NotifyOutcome.failed) {
      retryNeeded.add(s);
    }
  }
  return AttendanceSubmitResult(error: null, notifiedCount: notified, retryNeeded: retryNeeded);
}

// Lets an authorized user (the screen that shows this is Teacher-only
// already) retry absence notifications that didn't go out the first time -
// reuses the exact same claim-first logic, so retrying one that actually
// did already send simply does nothing instead of sending a duplicate.
Future<int> retryAbsenceNotificationsRemote(List<Student> list, String madrasa, String date) async {
  var n = 0;
  for (final s in list) {
    if (await _claimAbsenceNotification(s, date) == NotifyOutcome.sentNow) {
      st.sendAbsenceNotification(s, madrasa, date);
      n++;
    }
  }
  return n;
}

// Edits one student's status within a session for a recent (last 3 days)
// date that has ALREADY been finalized (Verify and Submit already run).
// Per the "no separate correction workflow" rule, this does not surface any
// reason prompt to the Teacher - it just recomputes the full expected
// roster for that madrasa+class+batch+date with the one student's status
// swapped in, then resubmits through the same submit_attendance_session
// path everything else uses, so the backend's existing correction-logging
// (attendance_correction_log) still captures the audit trail automatically.
Future<String?> editFinalizedStudentRemote(Student edited, String newStatus, {required String madrasa, required int cls, required String batch, required String date}) async {
  final roster = st.students.where((s) => s.madrasa == madrasa && s.cls == cls && s.batch == batch && s.status == 'Active').toList();
  final present = <Student>[];
  final absent = <Student>[];
  for (final s in roster) {
    final status = s.id == edited.id ? newStatus : st.attForDate(date)[s.id];
    if (status == 'A') {
      absent.add(s);
    } else if (status == 'P') {
      present.add(s);
    }
    // A roster member with no recorded status and not the one being edited
    // is left out of both lists entirely - that should not happen for an
    // already-finalized session (every expected student was required to be
    // Submitted before it could finalize), but if it ever does, this never
    // silently invents a status for them.
  }
  final res = await submitAttendanceSessionRemote(
    madrasa: madrasa,
    cls: cls,
    batch: batch,
    date: date,
    present: present,
    absent: absent,
    reason: 'Edited via Mark Attendance (${st.user?.name ?? 'Teacher'})',
  );
  return res.error;
}

// ---------------- Maktab Events / Holidays (public.maktab_events) ----------------
Future<void> loadEvents() async {
  final madrasaNameById = {for (final m in st.madrasas) if (m.dbId != null) m.dbId!: m.name};
  try {
    final rows = await sb.from('maktab_events').select().order('event_date', ascending: false);
    final userIds = <String>{for (final r in (rows as List)) if (r['created_by'] != null) r['created_by'] as String};
    final nameByUser = <String, String>{};
    if (userIds.isNotEmpty) {
      final profRows = await sb.from('user_profiles').select('id, name').inFilter('id', userIds.toList());
      for (final r in (profRows as List)) {
        nameByUser[r['id'] as String] = (r['name'] as String?) ?? '';
      }
    }
    st.setEventsFromDb([
      for (final r in rows)
        MaktabEvent(
          dbId: r['id'] as String?,
          madrasa: madrasaNameById[r['madrasa_id'] as String?] ?? '',
          name: (r['event_name'] as String?) ?? '',
          type: (r['event_type'] as String?) ?? 'event',
          date: (r['event_date'] as String?) ?? kToday,
          startTime: r['start_time'] as String?,
          endTime: r['end_time'] as String?,
          batch: r['batch'] as String?,
          description: (r['description'] as String?) ?? '',
          createdByName: nameByUser[r['created_by'] as String?],
          cancelled: r['cancelled_at'] != null,
          cancelReason: r['cancel_reason'] as String?,
        ),
    ]);
  } catch (_) {}
}

Future<String?> addEventRemote(String madrasa, String name, String type, String date, {String? startTime, String? endTime, String? batch, String description = ''}) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter an Event/Holiday name';
  final madrasaId = _madrasaDbId(madrasa);
  if (madrasaId == null) return 'This Maktab is not saved to the database yet.';
  try {
    final row = await sb.from('maktab_events').insert({
      'madrasa_id': madrasaId,
      'event_name': n,
      'event_type': type,
      'event_date': date,
      'start_time': startTime,
      'end_time': endTime,
      'batch': batch,
      'description': description.trim(),
      'created_by': sb.auth.currentUser?.id,
    }).select().single();
    st.addEventLocal(MaktabEvent(
      dbId: row['id'] as String?,
      madrasa: madrasa,
      name: n,
      type: type,
      date: date,
      startTime: startTime,
      endTime: endTime,
      batch: batch,
      description: description.trim(),
      createdByName: st.user?.name,
    ));
    // In-app notice to every active student's parent in this Maktab,
    // rendered from the Super-Admin-configured 'event_holiday' template
    // (requirement: use the configured template when an event/holiday is
    // recorded). Deduplicated by phone so a household with two children
    // here doesn't get the same note twice.
    final tpl = st.templateFor('event_holiday');
    final tplBody = tpl?.body ?? '{maktab_name}: {event_type} "{event_name}" recorded for {event_date}.';
    final r = renderTemplate(tplBody, {
      'maktab_name': madrasa,
      'event_type': type[0].toUpperCase() + type.substring(1),
      'event_name': n,
      'event_date': nice(date),
    });
    final phones = <String>{
      for (final s in st.students)
        if (s.madrasa == madrasa && s.status == 'Active' && s.parentPhone.isNotEmpty) s.parentPhone,
    };
    for (final p in phones) {
      st.notes.add(Note(p, r.text));
    }
    if (phones.isNotEmpty) st.notifyListeners();
    return null;
  } on PostgrestException catch (e) {
    // The unique index on (madrasa, date, batch) surfaces here as a plain
    // Postgres duplicate-key message, which is exact and honest enough to
    // show as-is rather than needing a separate pre-check query first.
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> cancelEventRemote(MaktabEvent e, String reason) async {
  if (e.dbId == null) return 'This Event/Holiday was not saved to the database yet.';
  try {
    await sb.from('maktab_events').update({
      'cancelled_at': DateTime.now().toIso8601String(),
      'cancelled_by': sb.auth.currentUser?.id,
      'cancel_reason': reason,
    }).eq('id', e.dbId as Object);
    st.cancelEventLocal(e, reason);
    return null;
  } on PostgrestException catch (ex) {
    return 'Could not save: ${ex.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// ---------------- Notification Template Management (public.notification_templates) ----------------
Future<void> loadNotifTemplates() async {
  try {
    final rows = await sb.from('notification_templates').select().order('notif_type');
    final userIds = <String>{for (final r in (rows as List)) if (r['updated_by'] != null) r['updated_by'] as String};
    final nameByUser = <String, String>{};
    if (userIds.isNotEmpty) {
      final profRows = await sb.from('user_profiles').select('id, name').inFilter('id', userIds.toList());
      for (final r in (profRows as List)) {
        nameByUser[r['id'] as String] = (r['name'] as String?) ?? '';
      }
    }
    st.setNotifTemplatesFromDb([
      for (final r in rows)
        NotifTemplate(
          dbId: r['id'] as String?,
          key: (r['template_key'] as String?) ?? '',
          name: (r['name'] as String?) ?? '',
          notifType: (r['notif_type'] as String?) ?? '',
          channel: (r['channel'] as String?) ?? 'in_app',
          body: (r['body'] as String?) ?? '',
          variables: ((r['variables'] as List?) ?? const []).map((e) => e.toString()).toList(),
          active: (r['is_active'] as bool?) ?? true,
          updatedByName: nameByUser[r['updated_by'] as String?],
          updatedAt: DateTime.tryParse((r['updated_at'] as String?) ?? ''),
        ),
    ]);
  } catch (_) {}
}

// Only a Super Admin can succeed here - enforced again by the
// fn_notification_template_audit trigger (backend, not just this screen
// being hidden from other roles), which also snapshots the previous body
// into notification_template_history automatically.
Future<String?> updateNotifTemplateRemote(NotifTemplate t, {String? body, List<String>? variables, bool? active}) async {
  if (t.dbId == null) return 'This template is not saved to the database yet.';
  final patch = <String, dynamic>{};
  if (body != null) patch['body'] = body;
  if (variables != null) patch['variables'] = variables;
  if (active != null) patch['is_active'] = active;
  if (patch.isEmpty) return null;
  try {
    await sb.from('notification_templates').update(patch).eq('id', t.dbId as Object);
    st.updateNotifTemplateLocal(t, body: body, variables: variables, active: active);
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<List<NotifTemplateVersion>> loadTemplateHistory(NotifTemplate t) async {
  if (t.dbId == null) return const [];
  try {
    final rows = await sb
        .from('notification_template_history')
        .select()
        .eq('template_id', t.dbId as Object)
        .order('changed_at', ascending: false);
    final userIds = <String>{for (final r in (rows as List)) if (r['changed_by'] != null) r['changed_by'] as String};
    final nameByUser = <String, String>{};
    if (userIds.isNotEmpty) {
      final profRows = await sb.from('user_profiles').select('id, name').inFilter('id', userIds.toList());
      for (final r in (profRows as List)) {
        nameByUser[r['id'] as String] = (r['name'] as String?) ?? '';
      }
    }
    return [
      for (final r in rows)
        NotifTemplateVersion(
          body: (r['body'] as String?) ?? '',
          variables: ((r['variables'] as List?) ?? const []).map((e) => e.toString()).toList(),
          active: (r['is_active'] as bool?) ?? true,
          changedByName: nameByUser[r['changed_by'] as String?],
          changedAt: DateTime.tryParse((r['changed_at'] as String?) ?? '') ?? DateTime.now(),
        ),
    ];
  } catch (_) {
    return const [];
  }
}

// ---------------- About Us (public.about_us) ----------------
Future<void> loadAboutUsData() async {
  try {
    final row = await sb.from('about_us').select().eq('id', 1).maybeSingle();
    if (row == null) return;
    st.setAboutUsFromDb(AboutUsContent(
      heading: (row['heading'] as String?) ?? '',
      subheading: (row['subheading'] as String?) ?? '',
      sections: ((row['sections'] as List?) ?? const [])
          .map((e) => AboutUsSection.fromJson(e as Map<String, dynamic>))
          .toList(),
      contactLines: ((row['contact_lines'] as List?) ?? const []).map((e) => e.toString()).toList(),
      updatedAt: DateTime.tryParse((row['updated_at'] as String?) ?? ''),
    ));
  } catch (_) {}
}

// Only a Super Admin can succeed - enforced again by the about_us_super_write
// RLS policy at the database level, not just by hiding the edit screen.
Future<String?> updateAboutUsRemote(AboutUsContent c) async {
  try {
    await sb.from('about_us').update({
      'heading': c.heading,
      'subheading': c.subheading,
      'sections': [for (final s in c.sections) s.toJson()],
      'contact_lines': c.contactLines,
      'updated_by': sb.auth.currentUser?.id,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', 1);
    st.setAboutUsFromDb(c);
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// On-demand, month-scoped query for the Parent attendance report (not
// loaded into the global model at login like loadAttendance's "today +
// absent history only" - a full month's Present AND Absent rows for one
// student, fetched only when that report screen is actually opened).
Future<MonthAttendanceSummary?> loadMonthAttendance(Student s, int year, int month) async {
  if (s.dbId == null) return null;
  final firstOfMonth = DateTime(year, month, 1);
  final lastOfMonth = DateTime(year, month + 1, 0);
  try {
    final rows = await sb
        .from('student_attendance')
        .select('attendance_date, status')
        .eq('student_id', s.dbId as Object)
        .eq('is_draft', false)
        .gte('attendance_date', fd(firstOfMonth))
        .lte('attendance_date', fd(lastOfMonth));
    final attendanceByDate = <String, String>{
      for (final r in (rows as List)) (r['attendance_date'] as String): (r['status'] as String? ?? ''),
    };
    final eventRows = await sb
        .from('maktab_events')
        .select('event_date, event_name, event_type, batch, cancelled_at')
        .eq('madrasa_id', _madrasaDbId(s.madrasa) as Object)
        .gte('event_date', fd(firstOfMonth))
        .lte('event_date', fd(lastOfMonth));
    final events = [
      for (final r in (eventRows as List))
        MaktabEvent(
          madrasa: s.madrasa,
          name: (r['event_name'] as String?) ?? '',
          type: (r['event_type'] as String?) ?? 'event',
          date: (r['event_date'] as String?) ?? '',
          batch: r['batch'] as String?,
          cancelled: r['cancelled_at'] != null,
        ),
    ];
    return computeMonthAttendance(studentStart: s.start, year: year, month: month, attendanceByDate: attendanceByDate, events: events, batch: s.batch);
  } catch (_) {
    return null;
  }
}

// ---------------- Teacher self-attendance (public.teacher_attendance) ----------------

Future<void> loadMyTeacherAttendance() async {
  final u = st.user;
  if (u == null || u.dbId == null || u.role != 'teacher') return;
  try {
    final row = await sb.from('teacher_attendance').select('status').eq('teacher_id', u.dbId as Object).eq('attendance_date', kToday).maybeSingle();
    if (row != null) {
      final status = row['status'] as String?;
      st.setTeacherAttFromDb(u.name, status == 'absent' ? 'Absent' : (status == 'on_leave' ? 'On leave' : 'Present 07:05'));
    }
  } catch (_) {}
}

// For Teachers & Leave (admin view): every teacher's status for today, not
// just the viewer's own - loadMyTeacherAttendance above only covers a
// teacher checking their own status.
Future<void> loadAllTeacherAttendanceToday() async {
  try {
    final rows = await sb.from('teacher_attendance').select('teacher_id, status').eq('attendance_date', kToday);
    final byTeacherDbId = {for (final t in st.teacherAccounts) if (t.dbId != null) t.dbId!: t.name};
    for (final r in (rows as List)) {
      final name = byTeacherDbId[r['teacher_id'] as String?];
      if (name == null) continue;
      final status = r['status'] as String?;
      st.setTeacherAttFromDb(name, status == 'absent' ? 'Absent' : (status == 'on_leave' ? 'On leave' : 'Present 07:05'));
    }
  } catch (_) {
    // Admin/super sees whatever was already loaded; a Madrasa Admin viewing
    // another madrasa's teacher simply sees "Not marked" instead of erroring.
  }
}

Future<void> markSelfRemote(String v) async {
  final u = st.user;
  if (u == null) return;
  st.markSelf(v);
  if (u.dbId == null) return;
  try {
    await sb.from('teacher_attendance').upsert({
      'teacher_id': u.dbId,
      'madrasa_id': _madrasaDbId(st.teacherMadrasa),
      'attendance_date': kToday,
      'status': v == 'Absent' ? 'absent' : 'present',
      'marked_by': sb.auth.currentUser?.id,
    }, onConflict: 'teacher_id,attendance_date');
  } catch (_) {}
}

// ---------------- Teacher leave, per-Maktab (public.teacher_leaves) ----------------
// Section 7: a teacher who works at more than one Maktab applies for leave
// against one specific Maktab; RLS scopes what each admin sees to their
// own Maktab(s), so approval/reporting naturally uses the right context.
Future<void> loadLeaves() async {
  final rows = await sb
      .from('teacher_leaves')
      .select('id, teacher_id, madrasa_id, leave_type, from_date, to_date, reason, status, decision_remark, teacher:user_profiles!teacher_leaves_teacher_id_fkey(full_name), decider:user_profiles!teacher_leaves_decided_by_fkey(full_name), madrasas(name)')
      .order('created_at', ascending: false);
  final madrasaNameById = {for (final m in st.madrasas) if (m.dbId != null) m.dbId!: m.name};
  var lid = 1;
  st.setLeavesFromDb([
    for (final r in (rows as List))
      Leave(
        lid++,
        ((r['teacher'] as Map?)?['full_name'] as String?) ?? '',
        (r['leave_type'] as String?) ?? '',
        (r['from_date'] as String?) ?? '',
        (r['to_date'] as String?) ?? '',
        (r['reason'] as String?) ?? '',
        madrasa: ((r['madrasas'] as Map?)?['name'] as String?) ?? madrasaNameById[r['madrasa_id'] as String?] ?? '',
        dbId: r['id'] as String?,
      )..status = (r['status'] as String?) == 'approved'
          ? 'Approved'
          : (r['status'] as String?) == 'rejected'
              ? 'Rejected'
              : 'Pending'
        ..remark = (r['decision_remark'] as String?) ?? ''
        ..by = ((r['decider'] as Map?)?['full_name'] as String?) ?? '',
  ]);
}

Future<String?> applyLeaveRemote(String type, String madrasa, String from, String to, String reason) async {
  final u = st.user;
  if (u == null) return 'Not logged in';
  final local = st.applyLeave(type, from, to, reason, madrasa: madrasa);
  if (local != null) return local;
  if (u.dbId == null) return null;
  final madrasaId = _madrasaDbId(madrasa);
  if (madrasaId == null) return 'That Maktab is not saved to the database yet.';
  try {
    await sb.from('teacher_leaves').insert({
      'teacher_id': u.dbId,
      'madrasa_id': madrasaId,
      'leave_type': type,
      'from_date': from,
      'to_date': to,
      'reason': reason.trim(),
    });
    await loadLeaves();
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> decideLeaveRemote(Leave l, bool ok, String remark) async {
  st.decideLeave(l, ok, remark);
  if (l.dbId == null) return null;
  try {
    await sb.from('teacher_leaves').update({
      'status': ok ? 'approved' : 'rejected',
      'decision_remark': remark.trim().isEmpty ? null : remark.trim(),
      'decided_by': sb.auth.currentUser?.id,
    }).eq('id', l.dbId as Object);
    await loadLeaves();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only an admin for that Maktab (or Super Admin) can decide this leave request.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// ---------------- Syllabus (public.syllabus_progress / public.chapters) ----------------
// Page-based (Classes 1-3) writes page_no rows; chapter-based (Class 4+)
// writes chapter_id rows against public.chapters (seeded below). Both live
// in the same syllabus_progress table.

Future<void> loadChapters() async {
  try {
    final rows = await sb.from('chapters').select('id, class_id, title, days, sort_order').eq('is_active', true).order('sort_order');
    final classNoById = {for (final cd in st.classDefs.values) if (cd.dbId != null) cd.dbId!: cd.id};
    final byClass = <int, List<Chapter>>{};
    for (final r in (rows as List)) {
      final cls = classNoById[r['class_id'] as String?];
      if (cls == null) continue;
      byClass.putIfAbsent(cls, () => []).add(Chapter((r['title'] as String?) ?? '', (r['days'] as int?) ?? 30, dbId: r['id'] as String?));
    }
    st.setChaptersFromDb(byClass);
  } catch (_) {}
}

Future<String?> addChapterRemote(int cls, String title, int days) async {
  final classId = _classDbId(cls);
  if (classId == null) return 'That class is not saved to the database yet.';
  try {
    final sortOrder = (st.chapters[cls] ?? []).length;
    await sb.from('chapters').insert({'class_id': classId, 'title': title, 'days': days, 'sort_order': sortOrder});
    await loadChapters();
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Para-wise book structure (public.class_paras) - optional, for a
// page-based class whose book is split into named sections (e.g. a Qur'an
// with 30 Para) each with its own page count, instead of one flat count.
Future<void> loadClassParas() async {
  try {
    final rows = await sb.from('class_paras').select('id, class_id, para_no, page_count, sequence_order').order('para_no');
    final classByDbId = {for (final cd in st.classDefs.values) if (cd.dbId != null) cd.dbId!: cd};
    final byClass = <ClassDef, List<ParaDef>>{};
    for (final r in (rows as List)) {
      final cd = classByDbId[r['class_id'] as String?];
      if (cd == null) continue;
      final paraNo = (r['para_no'] as int?) ?? 0;
      byClass.putIfAbsent(cd, () => []).add(ParaDef(
            paraNo,
            (r['page_count'] as int?) ?? 0,
            dbId: r['id'] as String?,
            sequenceOrder: r['sequence_order'] as int? ?? paraNo,
          ));
    }
    for (final cd in st.classDefs.values) {
      st.setParasFromDb(cd, byClass[cd] ?? []);
    }
  } catch (_) {}
}

Future<String?> addParaRemote(ClassDef cd, int pageCount) async {
  if (cd.dbId == null) return 'This class is not saved to the database yet.';
  final paraNo = cd.paras.isEmpty ? 1 : (cd.paras.map((p) => p.paraNo).reduce((a, b) => a > b ? a : b) + 1);
  try {
    final row = await sb.from('class_paras').insert({'class_id': cd.dbId, 'para_no': paraNo, 'page_count': pageCount, 'sequence_order': paraNo}).select().single();
    st.addParaLocal(cd, ParaDef(paraNo, pageCount, dbId: row['id'] as String?));
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> updateParaPageCountRemote(ClassDef cd, ParaDef p, int pageCount) async {
  if (p.dbId == null) return 'This Para is not saved to the database yet.';
  try {
    await sb.from('class_paras').update({'page_count': pageCount}).eq('id', p.dbId as Object);
    st.updateParaLocal(cd, p, pageCount);
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// ---------------- Add-on Course class assignments (public.class_course_assignments) ----------------
Future<void> loadClassCourseAssignments() async {
  try {
    final rows = await sb.from('class_course_assignments').select('id, class_id, course_id');
    final classNoByDbId = {for (final cd in st.classDefs.values) if (cd.dbId != null) cd.dbId!: cd.id};
    final courseIdByDbId = {for (final c in st.courses) if (c.dbId != null) c.dbId!: c.id};
    final list = <ClassCourseAssignment>[];
    for (final r in (rows as List)) {
      final classId = classNoByDbId[r['class_id'] as String?];
      final courseId = courseIdByDbId[r['course_id'] as String?];
      if (classId == null || courseId == null) continue;
      list.add(ClassCourseAssignment(classId, courseId, dbId: r['id'] as String?));
    }
    st.setClassCourseAssignmentsFromDb(list);
  } catch (_) {}
}

Future<String?> assignCourseToClassRemote(ClassDef cd, Course c) async {
  if (cd.dbId == null || c.dbId == null) return 'This class or Add-on Course was not saved to the database yet.';
  try {
    final row = await sb
        .from('class_course_assignments')
        .insert({'class_id': cd.dbId, 'course_id': c.dbId, 'assigned_by': sb.auth.currentUser?.id})
        .select()
        .single();
    st.addClassCourseAssignmentLocal(ClassCourseAssignment(cd.id, c.id, dbId: row['id'] as String?));
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> unassignCourseFromClassRemote(ClassDef cd, Course c) async {
  if (cd.dbId == null || c.dbId == null) return null;
  try {
    await sb.from('class_course_assignments').delete().eq('class_id', cd.dbId as Object).eq('course_id', c.dbId as Object);
    st.removeClassCourseAssignmentLocal(cd.id, c.id);
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// ---------------- Course enrollments (public.course_enrollments) ----------------
// Resolves the handful of distinct submitted_by/approved_by user ids
// actually present in this batch of enrollment rows to display names, in
// one query - cheap, and avoids showing a raw uuid in the Approvals/Course
// tabs for progress loaded from the database (rather than just acted on
// in this session, where the name is already known locally).
Future<void> loadCourseEnrollments() async {
  final studentByDbId = {for (final s in st.students) if (s.dbId != null) s.dbId!: s};
  final courseIdByDbId = {for (final c in st.courses) if (c.dbId != null) c.dbId!: c.id};
  if (studentByDbId.isEmpty) return;
  try {
    final rows = await sb.from('course_enrollments').select();
    final rowList = (rows as List).cast<Map<String, dynamic>>();
    final userIds = <String>{
      for (final r in rowList) ...[
        if (r['submitted_by'] != null) r['submitted_by'] as String,
        if (r['approved_by'] != null) r['approved_by'] as String,
      ],
    };
    final nameById = <String, String>{};
    if (userIds.isNotEmpty) {
      final profRows = await sb.from('user_profiles').select('id, full_name').inFilter('id', userIds.toList());
      for (final r in (profRows as List)) {
        nameById[r['id'] as String] = (r['full_name'] as String?) ?? '';
      }
    }
    final list = <CourseEnrollment>[];
    for (final r in rowList) {
      final s = studentByDbId[r['student_id'] as String?];
      final courseId = courseIdByDbId[r['course_id'] as String?];
      if (s == null || courseId == null) continue;
      final e = CourseEnrollment(
        courseId,
        s.id,
        status: (r['status'] as String?) ?? 'in_progress',
        completedOn: (r['completed_at'] as String?)?.split('T').first,
        dbId: r['id'] as String?,
      );
      e.submittedBy = nameById[r['submitted_by'] as String?];
      e.approvedBy = nameById[r['approved_by'] as String?];
      e.rejectReason = r['reject_reason'] as String?;
      list.add(e);
    }
    st.setCourseEnrollmentsFromDb(list);
  } catch (_) {}
}

Future<String?> enrollCourseRemote(Student s, Course c) async {
  if (s.dbId == null || c.dbId == null) return 'This student or Add-on Course was not saved to the database yet.';
  try {
    final row = await sb
        .from('course_enrollments')
        .insert({'student_id': s.dbId, 'course_id': c.dbId, 'status': 'in_progress', 'created_by': sb.auth.currentUser?.id})
        .select()
        .single();
    final e = st.enrollCourse(s, c.id, dbId: row['id'] as String?);
    return e;
  } on PostgrestException catch (e) {
    if (e.code == '23505') return 'Already assigned to this student';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> submitCourseCompletionRemote(CourseEnrollment e) async {
  st.submitCourseCompletion(e);
  if (e.dbId == null) return 'This Add-on Course enrollment was not saved to the database yet.';
  try {
    await sb.from('course_enrollments').update({
      'status': 'awaiting_approval',
      'submitted_by': sb.auth.currentUser?.id,
      'submitted_at': DateTime.now().toIso8601String(),
    }).eq('id', e.dbId as Object);
    return null;
  } catch (_) {
    return 'Could not save - this will revert on refresh. Check your connection and try again.';
  }
}

Future<String?> decideCourseCompletionRemote(Student s, CourseEnrollment e, bool approve, {String reason = ''}) async {
  st.decideCourseCompletion(s, e, approve, reason: reason);
  if (e.dbId == null) return 'This Add-on Course enrollment was not saved to the database yet.';
  try {
    if (approve) {
      await sb.from('course_enrollments').update({
        'status': 'completed',
        'completed_at': DateTime.now().toIso8601String(),
        'approved_by': sb.auth.currentUser?.id,
        'approved_at': DateTime.now().toIso8601String(),
      }).eq('id', e.dbId as Object);
      await sb.from('course_approval_log').insert({'enrollment_id': e.dbId, 'action': 'approved', 'actor_id': sb.auth.currentUser?.id});
    } else {
      await sb.from('course_enrollments').update({'status': 'in_progress', 'reject_reason': reason}).eq('id', e.dbId as Object);
      await sb
          .from('course_approval_log')
          .insert({'enrollment_id': e.dbId, 'action': 'rejected', 'actor_id': sb.auth.currentUser?.id, 'remark': reason});
    }
    return null;
  } on PostgrestException catch (ex) {
    // The class-completion-guard trigger lives on `students`, not here, but
    // keep the message pass-through pattern consistent in case any future
    // DB-level check on course_enrollments itself raises one.
    return 'Could not save: ${ex.message}';
  } catch (_) {
    return 'Could not save - this will revert on refresh. Check your connection and try again.';
  }
}

Future<void> loadSyllabusProgress() async {
  final idByDbId = {for (final s in st.students) if (s.dbId != null) s.dbId!: s};
  if (idByDbId.isEmpty) return;
  try {
    final rows = await sb.from('syllabus_progress').select('student_id, page_no, chapter_id, completed_on, grade');
    final byStudent = <int, List<Map<String, dynamic>>>{};
    for (final r in (rows as List)) {
      final s = idByDbId[r['student_id'] as String?];
      if (s != null) byStudent.putIfAbsent(s.id, () => []).add(r as Map<String, dynamic>);
    }
    final chapterIndexByDbId = <String, int>{};
    for (final list in st.chapters.values) {
      for (var i = 0; i < list.length; i++) {
        final dbId = list[i].dbId;
        if (dbId != null) chapterIndexByDbId[dbId] = i;
      }
    }
    for (final s in st.students) {
      final rs = byStudent[s.id];
      if (rs == null) continue;
      final pageDates = <int, String>{};
      final pageGrades = <int, String>{};
      final chDates = <int, String>{};
      final chGrades = <int, String>{};
      for (final r in rs) {
        final no = r['page_no'] as int?;
        final chapterId = r['chapter_id'] as String?;
        if (no != null) {
          pageDates[no] = (r['completed_on'] as String?) ?? kToday;
          pageGrades[no] = (r['grade'] as String?) ?? '';
        } else if (chapterId != null && chapterIndexByDbId.containsKey(chapterId)) {
          final i = chapterIndexByDbId[chapterId]!;
          chDates[i] = (r['completed_on'] as String?) ?? kToday;
          chGrades[i] = (r['grade'] as String?) ?? '';
        }
      }
      st.setPageProgressFromDb(s, pageDates, pageGrades);
      st.setChapterProgressFromDb(s, chDates, chGrades);
    }
  } catch (_) {}
}

// Returns null on success, or an error message to show the teacher. A
// failed save used to be swallowed silently: the tap looked like it
// worked (local state updated optimistically) but nothing reached the
// database, so the next full data reload quietly reverted it - exactly
// the "page resets to 1 after Final Submit" bug. Now the teacher is told
// immediately instead of finding out later via a silent revert.
Future<String?> tickChapterRemote(Student s, int i, String date, String grade) async {
  st.tickChapter(s, i, date, grade);
  if (s.dbId == null) return null;
  final chapterId = st.chapters[s.cls]?[i].dbId;
  if (chapterId == null) return null;
  try {
    await sb.from('syllabus_progress').upsert({
      'student_id': s.dbId,
      'chapter_id': chapterId,
      'status': 'completed',
      'completed_on': validDate(date) ? date : kToday,
      'grade': grade,
      'created_by': sb.auth.currentUser?.id,
    }, onConflict: 'student_id,chapter_id');
    return null;
  } catch (e) {
    return 'Could not save - this chapter will revert on refresh. Check your connection and try again.';
  }
}

Future<String?> markPageCompleteRemote(Student s, int pageNo, String date, String grade, String remark) async {
  st.markPageComplete(s, pageNo, date, grade, remark);
  if (s.dbId == null) return null;
  try {
    await sb.from('syllabus_progress').upsert({
      'student_id': s.dbId,
      'page_no': pageNo,
      'status': 'completed',
      'completed_on': validDate(date) ? date : kToday,
      'grade': grade,
      'remark': remark,
      'created_by': sb.auth.currentUser?.id,
    }, onConflict: 'student_id,page_no');
    return null;
  } catch (e) {
    return 'Could not save - this page will revert on refresh. Check your connection and try again.';
  }
}

// ---------------- Complaints (public.complaints) ----------------

Future<void> loadComplaints() async {
  try {
    final rows = await sb.from('complaints').select().order('created_at');
    var i = 12;
    final list = <Complaint>[
      for (final r in (rows as List))
        Complaint(
          i++,
          (r['phone'] as String?) ?? '',
          (r['by_name'] as String?) ?? '',
          (r['to_role'] as String?) ?? 'teacher',
          (r['subject'] as String?) ?? '',
          (r['body'] as String?) ?? '',
        )
          ..status = (r['status'] as String?) ?? 'Submitted'
          ..replies = List<String>.from((r['replies'] as List?) ?? [])
          ..dbId = r['id'] as String?,
    ];
    st.setComplaintsFromDb(list);
  } catch (_) {
    // Not every role can see complaints (RLS) - an empty/unchanged list is fine.
  }
}

Future<String?> addComplaintRemote(String to, String subject, String text) async {
  final u = st.user;
  if (u == null) return 'Not signed in';
  if (subject.trim().isEmpty) return 'Enter a subject';
  try {
    await sb.from('complaints').insert({
      'phone': u.phone,
      'by_name': u.name,
      'to_role': to,
      'subject': subject.trim(),
      'body': text.trim(),
      'created_by': sb.auth.currentUser?.id,
    });
    await loadComplaints();
    return null;
  } on PostgrestException catch (e) {
    return 'Could not submit: ${e.message}';
  } catch (_) {
    return 'Could not submit. Check your internet connection and try again.';
  }
}

Future<void> replyRemote(Complaint c, String text) async {
  if (text.trim().isEmpty) return;
  if (c.dbId != null) {
    final newReplies = [...c.replies, '${roleLabel(st.user!)}: ${text.trim()}'];
    try {
      await sb.from('complaints').update({'replies': newReplies, 'status': 'In progress'}).eq('id', c.dbId as Object);
    } catch (_) {}
  }
  st.reply(c, text);
}

Future<void> resolveRemote(Complaint c) async {
  if (c.dbId != null) {
    try {
      await sb.from('complaints').update({'status': 'Resolved'}).eq('id', c.dbId as Object);
    } catch (_) {}
  }
  st.resolve(c);
}

// ---------------- Fees (public.fees_monthly / public.receipts) ----------------
// Rs. 200/month flat, same as the old local demo (public.fee_plans has
// that seeded per class). Only "paid in full" is tracked here, matching
// what the UI actually shows (Complete vs due) - partial payments aren't
// a thing in this app yet.
Future<void> loadFees() async {
  final idByDbId = {for (final s in st.students) if (s.dbId != null) s.dbId!: s};
  if (idByDbId.isEmpty) return;
  try {
    // No .eq('year', ...) - fees aren't limited to one hardcoded year any
    // more, so every year a student has a complete row for is loaded.
    final rows = await sb.from('fees_monthly').select('student_id, month, year, status').eq('status', 'complete');
    final byStudent = <int, Set<String>>{};
    for (final r in (rows as List)) {
      final s = idByDbId[r['student_id'] as String?];
      if (s == null) continue;
      final mNo = r['month'] as int?;
      final yr = r['year'] as int?;
      if (mNo == null || mNo < 1 || mNo > 12 || yr == null) continue;
      byStudent.putIfAbsent(s.id, () => {}).add('${AppState.kMonthAbbrevs[mNo - 1]} $yr');
    }
    st.setPaidFromDb(byStudent);
  } catch (_) {
    // Not every role can see fees (RLS) - the screen just shows nothing
    // marked paid instead of erroring.
  }
}

Future<String> payRemote(Student s, String m) async {
  final msg = st.pay(s, m);
  final monthNo = AppState.monthNumFromKey(m);
  final year = AppState.yearFromKey(m);
  if (s.dbId != null && monthNo >= 1) {
    try {
      final row = await sb.from('fees_monthly').upsert({
        'student_id': s.dbId,
        'year': year,
        'month': monthNo,
        'amount_due': 200,
        'amount_paid': 200,
        'status': 'complete',
      }, onConflict: 'student_id,year,month').select().single();
      await sb.from('receipts').insert({
        'receipt_no': 'R-$year-${st.receiptNo}',
        'fees_monthly_id': row['id'],
        'amount': 200,
        'mode': 'cash',
        'collected_by': sb.auth.currentUser?.id,
      });
    } catch (_) {
      // Already reflected locally; the next reload (realtime or manual)
      // will just show it still due if this save actually failed.
    }
  }
  return msg;
}

// ---------------- Committee members ----------------
// Same shape as loadTeachers above: real accounts (base_role='committee')
// plus anyone invited but who hasn't signed in yet.
Future<void> loadCommitteeMembers() async {
  final list = <Account>[];
  try {
    final profRows = await sb.from('user_profiles').select('id, full_name, phone, is_active').eq('base_role', 'committee');
    for (final r in (profRows as List)) {
      final scopeRows = await sb.from('user_madrasa_scope').select('madrasas(name)').eq('user_id', r['id'] as Object);
      final branches = [for (final s in (scopeRows as List)) ((s['madrasas'] as Map?)?['name'] as String?) ?? ''].where((n) => n.isNotEmpty).toList();
      list.add(Account(
        (r['phone'] as String?) ?? '',
        (r['full_name'] as String?) ?? 'Committee',
        'committee',
        branches: branches,
        active: (r['is_active'] as bool?) ?? true,
        dbId: r['id'] as String?,
      ));
    }
  } catch (_) {}
  try {
    final inviteRows = await sb.from('pending_role_invites').select().eq('base_role', 'committee');
    for (final r in (inviteRows as List)) {
      list.add(Account(
        (r['phone'] as String?) ?? '',
        (r['full_name'] as String?) ?? 'Committee',
        'committee',
        branches: List<String>.from((r['madrasa_names'] as List?) ?? []),
        pending: true,
      ));
    }
  } catch (_) {}
  st.setCommitteeFromDb(list);
}

Future<String?> addCommitteeRemote(String phone, String name, List<String> branches) async {
  if (branches.isEmpty) return 'Choose at least one Maktab';
  final e = await addRoleInviteRemote(name: name, phone: phone, dbRole: 'committee', madrasaNames: branches);
  if (e == null) await loadCommitteeMembers();
  return e;
}

// "Remove" means different things depending on whether this person has
// ever actually logged in: a real account is deactivated (same as
// deactivating a teacher - keeps history, just revokes access), while a
// still-pending invite can simply be deleted since nothing was ever
// created for it.
Future<String?> removeCommitteeRemote(Account m) async {
  try {
    if (m.dbId != null) {
      await sb.from('user_profiles').update({'is_active': false}).eq('id', m.dbId as Object);
    } else {
      await sb.from('pending_role_invites').delete().eq('phone', m.phone);
    }
    await loadCommitteeMembers();
    return null;
  } catch (_) {
    return 'Could not remove. Check your internet connection and try again.';
  }
}

// ---------------- Announcements (public.announcements) ----------------
// Was entirely local-only - postAnnouncement() just pushed to an in-memory
// list, so only the Super Admin's own session ever saw it, which is why
// it looked like "posting" did nothing: nobody else's screen could
// possibly show it.
Future<void> loadAnnouncements() async {
  try {
    final rows = await sb.from('announcements').select().order('created_at', ascending: false);
    final list = <Announcement>[
      for (final r in (rows as List))
        Announcement((r['title'] as String?) ?? '', (r['msg'] as String?) ?? '', (r['priority'] as String?) ?? 'Normal', dbId: r['id'] as String?)
          ..active = (r['active'] as bool?) ?? true,
    ];
    st.setAnnouncementsFromDb(list);
  } catch (_) {}
}

Future<String?> postAnnouncementRemote(String title, String msg, String priority) async {
  if (title.trim().isEmpty) return 'Enter a title';
  try {
    await sb.from('announcements').insert({
      'title': title.trim(),
      'msg': msg.trim(),
      'priority': priority,
      'created_by': sb.auth.currentUser?.id,
    });
    await loadAnnouncements();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only a Super Admin can post an announcement.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<void> withdrawAnnouncementRemote(Announcement a) async {
  st.withdraw(a);
  if (a.dbId != null) {
    try {
      await sb.from('announcements').update({'active': false}).eq('id', a.dbId as Object);
    } catch (_) {}
  }
}

// ---------------- Custom roles (public.roles / public.role_permissions) ----------------
// A Super Admin can read/write every custom role (RLS: roles_super_all /
// role_permissions_super_all); anyone holding a custom role can read only
// their own role's permissions (roles_self_read / role_permissions_self_read)
// - enough for tabsFor() to work out which screens to show them.
Future<void> loadCustomRoles() async {
  final u = st.user;
  if (u == null) return;
  try {
    if (u.role == 'super') {
      final roleRows = await sb.from('roles').select('id, name').eq('is_builtin', false);
      final byName = <String, Set<String>>{};
      for (final r in (roleRows as List)) {
        final permRows = await sb.from('role_permissions').select('screen_key').eq('role_id', r['id'] as Object).eq('can_view', true);
        byName[(r['name'] as String?) ?? ''] = {for (final p in (permRows as List)) (p['screen_key'] as String?) ?? ''}..removeWhere((x) => x.isEmpty);
      }
      st.setCustomRolesFromDb(byName);
    } else if (u.role == 'custom' && u.roleName.isNotEmpty) {
      final roleRow = await sb.from('roles').select('id').eq('name', u.roleName).maybeSingle();
      if (roleRow != null) {
        final permRows = await sb.from('role_permissions').select('screen_key').eq('role_id', roleRow['id'] as Object).eq('can_view', true);
        final perms = {for (final p in (permRows as List)) (p['screen_key'] as String?) ?? ''}..removeWhere((x) => x.isEmpty);
        st.setCustomRolesFromDb({u.roleName: perms});
      }
    }
  } catch (_) {}
}

Future<String?> createRoleRemote(String name, Set<String> perms) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a role name';
  if (perms.isEmpty) return 'Tick at least one screen';
  try {
    final row = await sb.from('roles').insert({'name': n, 'is_builtin': false}).select().single();
    final roleId = row['id'];
    await sb.from('role_permissions').insert([
      for (final p in perms) {'role_id': roleId, 'screen_key': p, 'can_view': true, 'can_edit': true},
    ]);
    await loadCustomRoles();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '23505') return 'A role with that name already exists.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Gives a person ANY role in the system - Super Admin, Maktab Admin,
// Teacher, Committee Member, or any existing Custom Role - including
// promoting someone to Super Admin, which (before this) was impossible
// anywhere in the app.
//
// Handles both cases a phone number can be in:
//  - It already belongs to a real, signed-in account (public.user_profiles)
//    - this updates that row directly (base_role/custom_role_id), and
//    replaces its Maktab scope (public.user_madrasa_scope) and, if the
//    account is moving away from being a teacher, clears any class
//    assignments (public.teacher_class_assignments) left over from that -
//    a Super Admin or Committee Member has no classes to assign.
//  - It hasn't signed in yet - this queues a public.pending_role_invites
//    row (same mechanism Teacher/Admin/Committee invites already use) that
//    becomes a real account, with this exact role, the moment that phone
//    number completes its first OTP sign-in.
// Every table involved already grants a Super Admin full access via RLS
// (confirmed: profiles_super_all / scope_super_all / tca_super_all /
// invites_super_all), so this is plain client calls - no Edge Function.
Future<String?> setUserRoleRemote({
  required String phone,
  required String name,
  required String dbRole,
  String? customRoleName,
  List<String> branches = const [],
}) async {
  final p = digits(phone);
  if (p.length != 10) return 'Enter a 10-digit mobile number';
  final n = name.trim();
  if (n.isEmpty) return 'Enter the name';
  final needsBranches = dbRole != 'super_admin';
  if (needsBranches && branches.isEmpty) return 'Choose at least one Maktab';

  try {
    String? customRoleId;
    if (dbRole == 'custom') {
      if (customRoleName == null || customRoleName.isEmpty) return 'Choose a role';
      final roleRow = await sb.from('roles').select('id').eq('name', customRoleName).maybeSingle();
      if (roleRow == null) return 'That role was not found - try Create role again.';
      customRoleId = roleRow['id'] as String?;
    }

    final fullPhone = '91$p';
    final existing = await sb.from('user_profiles').select('id').eq('phone', fullPhone).maybeSingle();

    if (existing != null) {
      final uid = existing['id'];
      await sb.from('user_profiles').update({
        'full_name': n,
        'base_role': dbRole,
        'custom_role_id': customRoleId,
      }).eq('id', uid as Object);

      await sb.from('user_madrasa_scope').delete().eq('user_id', uid);
      if (branches.isNotEmpty) {
        final rows = <Map<String, Object?>>[];
        for (final bname in branches) {
          final mid = st.madrasas.firstWhere((m) => m.name == bname, orElse: () => st.madrasas.first).dbId;
          if (mid != null) rows.add({'user_id': uid, 'madrasa_id': mid});
        }
        if (rows.isNotEmpty) await sb.from('user_madrasa_scope').insert(rows);
      }

      if (dbRole != 'teacher') {
        await sb.from('teacher_class_assignments').delete().eq('teacher_id', uid);
      }

      await loadTeachers();
      await loadCommitteeMembers();
      return null;
    }

    await sb.from('pending_role_invites').upsert({
      'phone': fullPhone,
      'base_role': dbRole,
      'full_name': n,
      'madrasa_names': branches,
      'custom_role_id': customRoleId,
    });
    if (dbRole == 'teacher') await loadTeachers();
    if (dbRole == 'committee') await loadCommitteeMembers();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only a Super Admin can assign a role.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Loads the real Teachers list: actual accounts (public.user_profiles
// where base_role='teacher', once they've signed in at least once) plus
// anyone invited but who hasn't joined yet (public.pending_role_invites).
// Pending invites are only visible to a Super Admin (same RLS as the rest
// of that table), so a Madrasa Admin viewing this screen will just see the
// real teachers and no pending ones - not an error, just narrower access.
Future<void> loadTeachers() async {
  final list = <Account>[];

  final profRows = await sb.from('user_profiles').select('id, full_name, phone, is_active').eq('base_role', 'teacher');
  for (final r in (profRows as List)) {
    final tcaRows = await sb.from('teacher_class_assignments').select('madrasas(name)').eq('teacher_id', r['id'] as Object);
    final teachMadrasas = <String>{for (final t in (tcaRows as List)) ((t['madrasas'] as Map?)?['name'] as String?) ?? ''}..removeWhere((x) => x.isEmpty);
    list.add(Account(
      (r['phone'] as String?) ?? '',
      (r['full_name'] as String?) ?? 'Teacher',
      'teacher',
      teachMadrasas: teachMadrasas.toList(),
      active: (r['is_active'] as bool?) ?? true,
      dbId: r['id'] as String?,
    ));
  }

  try {
    final inviteRows = await sb.from('pending_role_invites').select().eq('base_role', 'teacher');
    for (final r in (inviteRows as List)) {
      list.add(Account(
        (r['phone'] as String?) ?? '',
        (r['full_name'] as String?) ?? 'Teacher',
        'teacher',
        teachMadrasas: List<String>.from((r['madrasa_names'] as List?) ?? []),
        pending: true,
      ));
    }
  } catch (_) {
    // Not a Super Admin, most likely - pending invites just aren't visible
    // to this account. The real teachers above still loaded fine.
  }

  st.setTeachersFromDb(list);
}

// Queues a new teacher invite (public.pending_role_invites) for a phone
// number that hasn't signed in yet. The same mechanism already used for
// every test login in this app: the chosen name/role/madrasas apply
// automatically the first time that phone number completes a real OTP
// sign-in, same as the existing Teacher test account.
// Shared by the Teacher/Madrasa Admin/Committee "add" forms below - all
// three are really the same thing (queue a pending_role_invites row for a
// phone number that will become that role the moment it first signs in
// with a real OTP), just with a different base_role and whether a
// madrasa scope is required.
Future<String?> addRoleInviteRemote({required String name, required String phone, required String dbRole, List<String> madrasaNames = const []}) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter the name';
  final p = digits(phone);
  if (p.length != 10) return 'Enter a 10-digit mobile number';
  try {
    await sb.from('pending_role_invites').upsert({
      'phone': '91$p',
      'base_role': dbRole,
      'full_name': n,
      'madrasa_names': madrasaNames,
    });
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only a Super Admin can invite a new account.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Creates a REAL teacher account immediately (via the 'create-teacher'
// Edge Function, which uses the service role to create the auth identity
// and persist the user_profiles/Maktab-scope/class-assignment rows under
// a server-side authorization check), instead of queuing a
// pending_role_invites row that would only become a real account once the
// teacher happened to complete their first OTP login. That deferred
// design was the root cause of a newly-created teacher not showing up in
// Teacher Management, the Maktab-wise teacher list, or the
// attendance/leave screens until first login - this makes the teacher a
// real, persisted account (and fully visible everywhere) the moment the
// admin saves the form, while still requiring a real OTP for every login.
Future<String?> addTeacherInviteRemote(String name, String phone, List<String> madrasaNames) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter the name';
  final p = digits(phone);
  if (p.length != 10) return 'Enter a 10-digit mobile number';
  if (madrasaNames.isEmpty) return 'Choose at least one Maktab';
  try {
    final res = await sb.functions.invoke('create-teacher', body: {
      'name': n,
      'phone': p,
      'madrasaNames': madrasaNames,
    });
    final data = res.data;
    if (data is Map && data['ok'] == true) {
      await loadTeachers();
      return null;
    }
    return (data is Map ? data['error'] as String? : null) ?? 'Could not save the teacher.';
  } on FunctionException catch (e) {
    return friendlyFunctionError(e);
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Adds (upserts) rows into teacher_class_assignments for a real, already-
// logged-in teacher (a.dbId != null) - one row per selected class, all in
// the chosen madrasa. Safe to call again for the same teacher/madrasa with
// different classes; existing rows for other classes in that madrasa are
// left alone (use unassignTeacherClassRemote to remove one).
Future<String?> assignTeacherMadrasaRemote(Account a, String madrasaName, List<int> classNos) async {
  if (a.dbId == null) {
    return "${a.name} hasn't logged in with OTP yet, so there's no account to assign - they'll get their classes once they're invited (Master Data > Teachers) and log in.";
  }
  if (classNos.isEmpty) return 'Pick at least one class';
  final madrasaId = st.madrasas.firstWhere((m) => m.name == madrasaName, orElse: () => st.madrasas.first).dbId;
  if (madrasaId == null) return 'That Maktab is not saved to the database yet.';
  final classIds = [
    for (final no in classNos)
      if (st.classDefs[no]?.dbId != null) st.classDefs[no]!.dbId!,
  ];
  if (classIds.isEmpty) return 'Those classes are not saved to the database yet.';
  try {
    await sb.from('teacher_class_assignments').upsert([
      for (final cid in classIds) {'teacher_id': a.dbId, 'madrasa_id': madrasaId, 'class_id': cid},
    ]);
    await loadTeachers();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only a Super Admin can change teacher assignments.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> setTeacherActiveRemote(Account a, bool v) async {
  if (a.dbId == null) {
    return "This teacher hasn't logged in yet, so there's nothing to activate/deactivate - cancel the invite instead if you no longer want them to join.";
  }
  try {
    await sb.from('user_profiles').update({'is_active': v}).eq('id', a.dbId as Object);
    st.setTeacherActive(a, v);
    return null;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Edits an already-real teacher's name, phone number and Maktab assignment.
// Master Data previously could only toggle a teacher Active/Inactive once
// created - this is the missing "update the detail" path, Super Admin only
// (the 'update-teacher' Edge Function itself also enforces that, so this
// client-side check is just a faster failure, not the real gate). Changing
// the phone number updates the actual sign-in identity (not just the
// profile row), which is why this has to go through a service-role Edge
// Function rather than a plain table update, the same reason
// addTeacherInviteRemote/create-teacher does.
Future<String?> updateTeacherRemote(Account a, {required String name, required String phone, required List<String> madrasaNames}) async {
  if (st.user?.role != 'super') return 'Only a Super Admin can edit a teacher\'s details.';
  if (a.dbId == null) return "This teacher hasn't logged in yet - edit the pending invite instead.";
  final n = name.trim();
  if (n.isEmpty) return 'Enter the name';
  final p = digits(phone);
  if (p.length != 10) return 'Enter a 10-digit mobile number';
  if (madrasaNames.isEmpty) return 'Choose at least one Maktab';
  try {
    final res = await sb.functions.invoke('update-teacher', body: {
      'teacherId': a.dbId,
      'name': n,
      'phone': p,
      'madrasaNames': madrasaNames,
    });
    final data = res.data;
    if (data is Map && data['ok'] == true) {
      await loadTeachers();
      return null;
    }
    return (data is Map ? data['error'] as String? : null) ?? 'Could not save the teacher.';
  } on FunctionException catch (e) {
    return friendlyFunctionError(e);
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Edits a teacher who has only been invited, not yet logged in
// (public.pending_role_invites, keyed by phone). If the phone number is
// changing, the row has to move to the new key - delete-then-upsert so a
// failed insert never leaves the invite silently deleted.
Future<String?> updatePendingTeacherInviteRemote(Account a, {required String name, required String phone, required List<String> madrasaNames}) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter the name';
  final p = digits(phone);
  if (p.length != 10) return 'Enter a 10-digit mobile number';
  if (madrasaNames.isEmpty) return 'Choose at least one Maktab';
  final oldPhoneStored = '91${digits(a.phone)}';
  final newPhoneStored = '91$p';
  try {
    await sb.from('pending_role_invites').upsert({
      'phone': newPhoneStored,
      'base_role': 'teacher',
      'full_name': n,
      'madrasa_names': madrasaNames,
    });
    if (newPhoneStored != oldPhoneStored) {
      await sb.from('pending_role_invites').delete().eq('phone', oldPhoneStored);
    }
    await loadTeachers();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only a Super Admin can edit an invite.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Inserts a new row into public.students and, on success, adds it to the
// local list with its real database id attached. Same validation as the
// old local-only addStudent(), plus it needs the chosen Madrasa and Class
// to already have a real database id (they will, once Master Data has
// loaded) to satisfy the students table's foreign keys.
// A return value starting with "DUPLICATE:" is not an error - it's the
// Section 3.2.3 warning. The caller shows it as a confirm dialog and, if
// the person confirms, calls this again with confirmDuplicate: true to
// actually save.
Future<String?> addStudentRemote({
  required String name,
  required String gender,
  required int cls,
  required String parentPhone,
  String studentPhone = '',
  required bool aadhaar,
  String address = '',
  required String madrasa,
  String? dob,
  String fatherName = '',
  String batch = 'Morning',
  bool confirmDuplicate = false,
}) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter the student name';
  if (gender.isEmpty) return 'Select gender (Male or Female)';
  if (parentPhone.length != 10) return 'Parent mobile number is required (10 digits)';
  if (!aadhaar) return 'Aadhaar card is required';
  if (studentPhone.isNotEmpty) {
    if (studentPhone.length != 10) return 'Student mobile must be 10 digits, or leave it blank';
    if (studentPhone == parentPhone) return 'Student mobile must differ from the parent mobile';
  }
  if (!confirmDuplicate && st.findActiveDuplicate(n, dob) != null) {
    return 'DUPLICATE:A student with the same name and date of birth already exists in the system. Please verify the details before proceeding.';
  }
  final m = st.madrasas.where((x) => x.name == madrasa).toList();
  final cd = st.classDefs[cls];
  if (m.isEmpty || m.first.dbId == null || cd?.dbId == null) {
    return 'This Maktab or Class was not saved to the database yet.';
  }
  final prefix = madrasa == 'Jama'
      ? 'JAM'
      : madrasa == 'Khwajapiya'
          ? 'KHW'
          : madrasa == 'Bagwanpura'
              ? 'BAG'
              : madrasa == 'Hanfi'
                  ? 'HNF'
                  : madrasa.replaceAll(RegExp('[^A-Za-z]'), '').toUpperCase().padRight(3, 'X').substring(0, 3);
  final today = DateTime.now();
  final start = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
  final key = '$prefix-${today.year}-${today.millisecondsSinceEpoch % 100000}';
  try {
    final row = await sb.from('students').insert({
      'madrasa_id': m.first.dbId,
      'class_id': cd!.dbId,
      'student_key': key,
      'name': n,
      'gender': gender,
      'parent_phone': parentPhone,
      'student_phone': studentPhone.isEmpty ? null : studentPhone,
      'address': address.trim().isEmpty ? null : address.trim(),
      'aadhaar_file_ref': 'uploaded_demo',
      'admission_date': start,
      'dob': (dob == null || dob.trim().isEmpty) ? null : dob.trim(),
      'father_name': fatherName.trim().isEmpty ? null : fatherName.trim(),
      'batch': batch,
    }).select().single();
    st.addStudentFromRemote(
      key: key,
      name: n,
      gender: gender,
      cls: cls,
      madrasa: madrasa,
      start: start,
      parentPhone: parentPhone,
      studentPhone: studentPhone,
      aadhaar: true,
      address: address.trim(),
      dob: (dob == null || dob.trim().isEmpty) ? null : dob.trim(),
      fatherName: fatherName.trim(),
      batch: batch,
      dbId: row['id'] as String?,
    );
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '23505') return 'A student with a matching ID already exists, try again';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Deactivate/reactivate a student that has a real database row: save
// is_active to Supabase first, then update the local copy, same
// save-then-reflect order as setMadrasaActiveRemote. If this student was
// never synced to the database (dbId null), falls back to the old
// local-only behaviour so nothing breaks for leftover demo data.
// Section 4.1/4.3: who may deactivate is enforced twice now - the UI only
// shows the button to admin/super (see StudentsView), and a database
// trigger (trg_enforce_student_status_change) rejects the UPDATE outright
// for any other role, stamping deactivated_by/deactivated_at itself. The
// reason typed here is sent in the same UPDATE so it lands in
// deactivation_reason for that audit trail.
Future<String> deactivateStudentRemote(Student s, String reason) async {
  if (s.dbId != null) {
    try {
      await sb.from('students').update({
        'is_active': false,
        'deactivation_reason': reason.trim().isEmpty ? null : reason.trim(),
      }).eq('id', s.dbId as Object);
    } on PostgrestException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not save. Check your internet connection and try again.';
    }
  }
  return st.deactivateStudent(s, reason);
}

// Section 4.2: only Super Admin may reactivate - enforced in the UI (the
// button is hidden otherwise) and again by trg_enforce_student_status_change,
// which rejects the UPDATE for any other role.
Future<String> reactivateStudentRemote(Student s) async {
  if (s.dbId != null) {
    try {
      await sb.from('students').update({'is_active': true}).eq('id', s.dbId as Object);
    } on PostgrestException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not save. Check your internet connection and try again.';
    }
  }
  return st.reactivateStudent(s);
}

// Persists "Mark Passed and Promote". Previously this called st.promote(s)
// directly from the button - a purely local mutation of class/start/
// progress with no database write at all, so a promotion looked like it
// worked but silently reverted to the student's old class on the very
// next reload, realtime sync, or re-login (loadMasterData rebuilds
// st.students fresh from the database every time).
// - Moving to a next class: updates students.class_id/admission_date and
//   clears the old class's syllabus_progress rows (a fresh class starts
//   fresh), matching what st.promote already did locally.
// - No next class (graduating the highest class): the database has no
//   separate "Graduated" status of its own, so this reuses the existing
//   deactivation columns (is_active/deactivation_reason) rather than
//   inventing a new one - same audit trail Section 4 already built.
// Either way, RLS still applies: a teacher can only promote a student
// into a class they are themselves assigned to (teacher_class_assignments)
// - promoting into a class they don't teach is correctly rejected, not
// silently allowed.
Future<String> promoteRemote(Student s) async {
  final nextDef = st.classDefs[s.cls + 1];
  if (nextDef != null) {
    if (s.dbId != null) {
      if (nextDef.dbId == null) return 'The next class was not saved to the database yet.';
      try {
        await sb.from('students').update({'class_id': nextDef.dbId, 'admission_date': kToday}).eq('id', s.dbId as Object);
        await sb.from('syllabus_progress').delete().eq('student_id', s.dbId as Object);
      } on PostgrestException catch (e) {
        if (e.code == '42501' || e.message.toLowerCase().contains('row-level security')) {
          return "You don't have access to promote into ${nextDef.name} (it may not be a class you're assigned to).";
        }
        return 'Could not save: ${e.message}';
      } catch (_) {
        return 'Could not save. Check your internet connection and try again.';
      }
    }
    return st.promote(s);
  }
  if (s.dbId != null) {
    try {
      await sb.from('students').update({
        'is_active': false,
        'deactivation_reason': 'Graduated: completed ${st.className(s.cls)}',
      }).eq('id', s.dbId as Object);
    } on PostgrestException catch (e) {
      return 'Could not save: ${e.message}';
    } catch (_) {
      return 'Could not save. Check your internet connection and try again.';
    }
  }
  return st.promote(s);
}

// Section 3.2.3/5: re-runs the active-duplicate check if name or DOB
// changed. A return value starting with "DUPLICATE:" is the warning, not
// an error - same confirm-and-retry pattern as addStudentRemote.
Future<String?> editStudentRemote(Student s, {String? name, String? parentPhone, String? address, String? madrasa, int? cls, String? dob, String? fatherName, String? batch, bool confirmDuplicate = false}) async {
  final newName = (name != null && name.trim().isNotEmpty) ? name.trim() : s.name;
  final newDob = dob != null ? (dob.trim().isEmpty ? null : dob.trim()) : s.dob;
  if (!confirmDuplicate && (newName != s.name || newDob != s.dob)) {
    final dup = st.findActiveDuplicate(newName, newDob, excludeId: s.id);
    if (dup != null) {
      return 'DUPLICATE:A student with the same name and date of birth already exists in the system. Please verify the details before proceeding.';
    }
  }
  final patch = <String, Object?>{};
  if (name != null && name.trim().isNotEmpty) patch['name'] = name.trim();
  if (parentPhone != null && parentPhone.trim().isNotEmpty) {
    if (digits(parentPhone).length != 10) return 'Parent mobile must be 10 digits';
    patch['parent_phone'] = digits(parentPhone);
  }
  if (address != null) patch['address'] = address.trim().isEmpty ? null : address.trim();
  if (dob != null) patch['dob'] = dob.trim().isEmpty ? null : dob.trim();
  if (fatherName != null) patch['father_name'] = fatherName.trim().isEmpty ? null : fatherName.trim();
  if (batch != null && batch.isNotEmpty) patch['batch'] = batch;
  if (madrasa != null) {
    final m = st.madrasas.where((x) => x.name == madrasa).toList();
    if (m.isEmpty || m.first.dbId == null) return 'This Maktab was not saved to the database yet.';
    patch['madrasa_id'] = m.first.dbId;
  }
  if (cls != null) {
    final cd = st.classDefs[cls];
    if (cd?.dbId == null) return 'This class was not saved to the database yet.';
    patch['class_id'] = cd!.dbId;
  }
  if (patch.isEmpty) return null;
  if (s.dbId != null) {
    try {
      await sb.from('students').update(patch).eq('id', s.dbId as Object);
    } on PostgrestException catch (e) {
      if (e.code == '42501' || e.message.toLowerCase().contains('row-level security')) {
        return "You don't have access to save that change (it may be moving the student outside a Maktab/class you're assigned to).";
      }
      return 'Could not save: ${e.message}';
    } catch (_) {
      return 'Could not save. Check your internet connection and try again.';
    }
  }
  st.editStudent(s, name: name, parentPhone: parentPhone == null ? null : digits(parentPhone), address: address, madrasa: madrasa, cls: cls, dob: dob, fatherName: fatherName, batch: batch);
  return null;
}

// Inserts a new row into public.madrasas and, on success, adds it to the
// local list with its real database id attached. Returns null on success
// or a short message to show the user on failure.
Future<String?> addMadrasaRemote(String name, String? category) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a Maktab name';
  if (category == null || !kMadrasaCategories.contains(category)) return 'Choose a Maktab Category (Boys, Girls, or Children)';
  if (st.madrasas.any((m) => m.name.toLowerCase() == n.toLowerCase())) return 'This Maktab already exists';
  try {
    final row = await sb.from('madrasas').insert({'name': n, 'category': category}).select().single();
    st.addMadrasa(n, dbId: row['id'] as String?, category: category);
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '23505') return 'This Maktab already exists';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Updates a madrasa's active flag in Supabase first, then reflects it
// locally only once that succeeds, so a failed save never leaves the app
// showing something the database doesn't actually have.
Future<String?> setMadrasaActiveRemote(MadrasaRec m, bool v) async {
  if (m.dbId == null) {
    // Shouldn't happen once master data is loaded from Supabase, but guard
    // against toggling a row that was never actually saved.
    return 'This Maktab was not saved to the database yet.';
  }
  try {
    await sb.from('madrasas').update({'is_active': v}).eq('id', m.dbId as Object);
    st.setMadrasaActive(m, v);
    return null;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> renameMadrasaRemote(MadrasaRec m, String name) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a Maktab name';
  if (m.dbId == null) return 'This Maktab was not saved to the database yet.';
  try {
    await sb.from('madrasas').update({'name': n}).eq('id', m.dbId as Object);
    st.renameMadrasa(m, n);
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '23505') return 'This Maktab already exists';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Sets (or changes) a Maktab's category to one of the three fixed values.
// The database's check constraint is the real guard against an invalid
// value getting in by any other route (direct API calls included) - this
// is just the same validation given back early, before a network round
// trip, for a friendlier message.
Future<String?> setMadrasaCategoryRemote(MadrasaRec m, String category) async {
  if (!kMadrasaCategories.contains(category)) return 'Choose Boys, Girls, or Children.';
  if (m.dbId == null) return 'This Maktab was not saved to the database yet.';
  try {
    await sb.from('madrasas').update({'category': category}).eq('id', m.dbId as Object);
    st.setMadrasaCategoryLocal(m, category);
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Same pattern as addMadrasaRemote, for public.classes. class_no is picked
// as one past the highest class number currently loaded, matching how the
// app already uses that number everywhere else (promotion moves a student
// from classDefs[n] to classDefs[n+1], so classes must stay numbered in
// order with no gaps).
Future<String?> addClassRemote(String name, {required bool pageBased, String? bookName, int totalPages = 0}) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a class name';
  final nextNo = (st.classDefs.keys.isEmpty ? 0 : st.classDefs.keys.reduce((a, b) => a > b ? a : b)) + 1;
  try {
    final row = await sb.from('classes').insert({
      'class_no': nextNo,
      'name': n,
      'page_based': pageBased,
      'book_name': pageBased ? bookName?.trim() : null,
      'total_pages': pageBased ? totalPages : null,
    }).select().single();
    st.setClassDefsFromDb([
      ...st.classDefs.values,
      ClassDef(nextNo, n, pageBased: pageBased, bookName: pageBased ? bookName?.trim() : null, totalPages: pageBased ? totalPages : 0, dbId: row['id'] as String?),
    ]);
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> setClassActiveRemote(ClassDef cd, bool v) async {
  if (cd.dbId == null) {
    return 'This class was not saved to the database yet.';
  }
  try {
    await sb.from('classes').update({'is_active': v}).eq('id', cd.dbId as Object);
    st.setClassActive(cd, v);
    return null;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> renameClassRemote(ClassDef cd, String name) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a class name';
  if (cd.dbId == null) return 'This class was not saved to the database yet.';
  try {
    await sb.from('classes').update({'name': n}).eq('id', cd.dbId as Object);
    st.renameClass(cd, n);
    return null;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Edits an existing class's book name / total pages (requirement 1 -
// previously only the class name itself could be changed after creation).
Future<String?> updateClassDetailsRemote(ClassDef cd, {String? bookName, int? totalPages}) async {
  if (cd.dbId == null) return 'This class was not saved to the database yet.';
  try {
    final payload = <String, dynamic>{};
    if (bookName != null) payload['book_name'] = bookName;
    if (totalPages != null && cd.paras.isEmpty) payload['total_pages'] = totalPages;
    if (payload.isNotEmpty) await sb.from('classes').update(payload).eq('id', cd.dbId as Object);
    st.updateClassDetails(cd, bookName: bookName, totalPages: totalPages);
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// ---------------- Book Management (public.class_books / public.book_progress) ----------------
// Book Management (Class 4 onward): a class can have several independent
// Books, each with its own name/description/page count/display sequence/
// active status (requirement 4). Classes 1-3 never have rows here - a DB
// trigger (fn_block_books_on_core_classes) blocks it regardless of who
// tries, same defence-in-depth pattern already used for the Hafizi Para
// lock and mandatory-course class completion.
Future<void> loadClassBooks() async {
  try {
    final rows = await sb.from('class_books').select('id, class_id, name, description, total_pages, sequence_order, is_active').order('sequence_order');
    final byClass = <ClassDef, List<ClassBook>>{};
    final classByDbId = {for (final cd in st.classDefs.values) if (cd.dbId != null) cd.dbId!: cd};
    var nextId = 1;
    for (final r in (rows as List)) {
      final cd = classByDbId[r['class_id'] as String?];
      if (cd == null) continue;
      byClass.putIfAbsent(cd, () => []).add(ClassBook(
            nextId++,
            (r['name'] as String?) ?? '',
            description: (r['description'] as String?) ?? '',
            totalPages: (r['total_pages'] as int?) ?? 0,
            sequenceOrder: (r['sequence_order'] as int?) ?? 0,
            active: (r['is_active'] as bool?) ?? true,
            dbId: r['id'] as String?,
          ));
    }
    for (final cd in st.classDefs.values) {
      st.setClassBooksFromDb(cd, byClass[cd] ?? []);
    }
  } catch (_) {}
}

Future<String?> addClassBookRemote(ClassDef cd, String name, String description, int totalPages, int sequenceOrder) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a Book name';
  if (cd.dbId == null) return 'This class is not saved to the database yet.';
  try {
    final row = await sb.from('class_books').insert({
      'class_id': cd.dbId,
      'name': n,
      'description': description.trim(),
      'total_pages': totalPages,
      'sequence_order': sequenceOrder,
      'created_by': sb.auth.currentUser?.id,
    }).select().single();
    final localId = cd.books.isEmpty ? 1 : (cd.books.map((b) => b.id).reduce((a, b) => a > b ? a : b) + 1);
    st.addClassBookLocal(
        cd, ClassBook(localId, n, description: description.trim(), totalPages: totalPages, sequenceOrder: sequenceOrder, dbId: row['id'] as String?));
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> updateClassBookRemote(ClassBook b, {String? name, String? description, int? totalPages, int? sequenceOrder}) async {
  if (b.dbId == null) return 'This Book is not saved to the database yet.';
  try {
    final payload = <String, dynamic>{};
    if (name != null) payload['name'] = name.trim();
    if (description != null) payload['description'] = description.trim();
    if (totalPages != null) payload['total_pages'] = totalPages;
    if (sequenceOrder != null) payload['sequence_order'] = sequenceOrder;
    if (payload.isNotEmpty) await sb.from('class_books').update(payload).eq('id', b.dbId as Object);
    st.updateClassBookLocal(b, name: name?.trim(), description: description?.trim(), totalPages: totalPages, sequenceOrder: sequenceOrder);
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> setClassBookActiveRemote(ClassBook b, bool active) async {
  if (b.dbId == null) return 'This Book is not saved to the database yet.';
  try {
    await sb.from('class_books').update({'is_active': active}).eq('id', b.dbId as Object);
    st.setClassBookActiveLocal(b, active);
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<void> loadBookProgress() async {
  final studentByDbId = {for (final s in st.students) if (s.dbId != null) s.dbId!: s};
  if (studentByDbId.isEmpty) return;
  // Local Book id -> db id and back, across every class, so a loaded row's
  // uuid book_id can be turned back into the local int id Student's
  // bookPageDate/bookPageGrade maps are keyed with.
  final bookByDbId = {for (final cd in st.classDefs.values) for (final b in cd.books) if (b.dbId != null) b.dbId!: b};
  if (bookByDbId.isEmpty) return;
  try {
    final rows = await sb.from('book_progress').select('student_id, book_id, page_no, completed_on, grade');
    final byStudent = <int, List<Map<String, dynamic>>>{};
    for (final r in (rows as List)) {
      final s = studentByDbId[r['student_id'] as String?];
      if (s != null) byStudent.putIfAbsent(s.id, () => []).add(r as Map<String, dynamic>);
    }
    for (final s in st.students) {
      final rs = byStudent[s.id];
      if (rs == null) continue;
      final dates = <String, String>{};
      final grades = <String, String>{};
      for (final r in rs) {
        final b = bookByDbId[r['book_id'] as String?];
        final pageNo = r['page_no'] as int?;
        if (b == null || pageNo == null) continue;
        final key = '${b.id}:$pageNo';
        dates[key] = (r['completed_on'] as String?) ?? kToday;
        grades[key] = (r['grade'] as String?) ?? '';
      }
      st.setBookProgressFromDb(s, dates, grades);
    }
  } catch (_) {}
}

Future<String?> markBookPageCompleteRemote(Student s, ClassBook b, int pageNo, String date, String grade) async {
  st.markBookPageComplete(s, b, pageNo, date, grade);
  if (s.dbId == null || b.dbId == null) return null;
  try {
    await sb.from('book_progress').upsert({
      'student_id': s.dbId,
      'book_id': b.dbId,
      'page_no': pageNo,
      'status': 'completed',
      'completed_on': validDate(date) ? date : kToday,
      'grade': grade,
      'created_by': sb.auth.currentUser?.id,
    }, onConflict: 'student_id,book_id,page_no');
    return null;
  } catch (e) {
    return 'Could not save - this page will revert on refresh. Check your connection and try again.';
  }
}

// Same pattern as addMadrasaRemote, for public.courses.
Future<String?> addCourseRemote(String name, String description, {String code = ''}) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter an Add-on Course name';
  try {
    final row = await sb.from('courses').insert({'name': n, 'description': description.trim(), 'course_code': code.trim()}).select().single();
    st.addCourse(n, description, code: code, dbId: row['id'] as String?);
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Same pattern as setMadrasaActiveRemote, for public.courses.
Future<String?> setCourseActiveRemote(Course c, bool v) async {
  if (c.dbId == null) {
    return 'This Add-on Course was not saved to the database yet.';
  }
  try {
    await sb.from('courses').update({'is_active': v}).eq('id', c.dbId as Object);
    st.setCourseActive(c, v);
    return null;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> renameCourseRemote(Course c, String name, String description, {String? code}) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter an Add-on Course name';
  if (c.dbId == null) return 'This Add-on Course was not saved to the database yet.';
  try {
    final payload = {'name': n, 'description': description.trim()};
    if (code != null) payload['course_code'] = code.trim();
    await sb.from('courses').update(payload).eq('id', c.dbId as Object);
    st.renameCourse(c, n, description: description.trim(), code: code?.trim());
    return null;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

class MaktabApp extends StatefulWidget {
  const MaktabApp({super.key});
  @override
  State<MaktabApp> createState() => _MaktabAppState();
}

class _MaktabAppState extends State<MaktabApp> {
  late Future<void> _init;

  @override
  void initState() {
    super.initState();
    _init = _connectSupabase();
  }

  void _retry() => setState(() => _init = _connectSupabase());

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Maktab-E-Tajushshriah',
      debugShowCheckedModeBanner: false,
      // themeMode defaults to following the OS; without an explicit
      // darkTheme, Flutter would otherwise keep using this same light
      // theme either way, so this alone wasn't the "black field" cause -
      // that turned out to be Android's own system-level Force Dark
      // feature (fixed in the CI workflow's AndroidManifest step, see
      // android:forceDarkAllowed). Still setting brightness explicitly and
      // giving every field a real white fill + visible border here, so the
      // look is consistent and deliberate rather than relying on Material
      // 3 defaults.
      themeMode: ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF7F8F5),
        colorScheme: ColorScheme.fromSeed(seedColor: kGreen, secondary: kGold, brightness: Brightness.light),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFBFC7BC))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFBFC7BC))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: kGreen, width: 2)),
          labelStyle: const TextStyle(color: Colors.black54),
          hintStyle: const TextStyle(color: Colors.black38),
        ),
        cardTheme: const CardThemeData(color: Colors.white),
      ),
      home: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _ConnectingScreen();
          }
          if (snap.hasError) {
            return _ConnectErrorScreen(onRetry: _retry);
          }
          return AnimatedBuilder(
            animation: st,
            builder: (c, _) => st.user == null
                ? const GuestHome()
                : st.showLoginSplash
                    ? const _LoginSplash()
                    : const Shell(),
          );
        },
      ),
    );
  }
}

// Plays once right after a parent logs in: the logo starts zoomed in and
// scales out to its normal size (with a fade), then hands off to the
// Shell on its own - nothing for the person to tap. Purely cosmetic, so
// if anything here ever throws, dismissing itself in initState's timer
// before the animation would even finish is a worse failure mode than a
// skipped animation, hence the plain Future.delayed rather than hanging
// the transition on the AnimationController's own status/listener.
class _LoginSplash extends StatefulWidget {
  const _LoginSplash();
  @override
  State<_LoginSplash> createState() => _LoginSplashState();
}

class _LoginSplashState extends State<_LoginSplash> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));

  @override
  void initState() {
    super.initState();
    _c.forward();
    Future.delayed(const Duration(milliseconds: 1050), () {
      if (mounted) st.dismissLoginSplash();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Scaled relative to the actual window/screen so the logo genuinely
    // fills it (zooms IN to full screen) on any device or browser window
    // size, rather than a fixed multiplier that overshoots on a phone and
    // undershoots on a wide desktop Chrome window.
    final size = MediaQuery.of(context).size;
    final longSide = size.width > size.height ? size.width : size.height;
    const logoHeight = 120.0;
    final targetScale = (longSide / logoHeight) * 1.3;
    final scaleAnim = Tween<double>(begin: 1.0, end: targetScale).animate(CurvedAnimation(parent: _c, curve: Curves.easeInCubic));
    // Fades out only in the final stretch, once the logo is already large
    // enough to cover the screen, so the transition to Shell underneath
    // isn't a hard cut.
    final fadeAnim = CurvedAnimation(parent: _c, curve: const Interval(0.6, 1.0, curve: Curves.easeOut));
    return Scaffold(
      backgroundColor: Colors.white,
      body: ClipRect(
        child: Center(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, child) => Opacity(opacity: 1 - fadeAnim.value, child: Transform.scale(scale: scaleAnim.value, child: child)),
            child: Image.asset('assets/logo.png', height: logoHeight),
          ),
        ),
      ),
    );
  }
}

class _ConnectingScreen extends StatelessWidget {
  const _ConnectingScreen();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: kGreen),
          SizedBox(height: 16),
          Text('Connecting...'),
        ]),
      ),
    );
  }
}

class _ConnectErrorScreen extends StatelessWidget {
  final VoidCallback onRetry;
  const _ConnectErrorScreen({required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.cloud_off, size: 56, color: Colors.black38),
              const SizedBox(height: 16),
              const Text('Could not connect to the server.', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('Check your internet connection and try again.', style: TextStyle(color: Colors.black54), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------- helpers ----------------
void toast(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m, style: const TextStyle(fontSize: 13.5))));

// Turns a FunctionException from sb.functions.invoke into a message a
// Teacher/Admin can actually act on, instead of a raw exception dump like
// "FunctionsFetchException(status: 0, details: ClientException: Failed to
// fetch, ...)". status 0 (or no status at all) means the request never
// got a response from the server at all - almost always a connectivity
// problem (or, on web, a blocked/CORS'd request) rather than anything the
// Edge Function itself returned, so that's reported as a plain
// connectivity message rather than the exception's own text.
String friendlyFunctionError(FunctionException e) {
  final details = e.details;
  final msg = (details is Map ? details['error'] as String? : null);
  if (msg != null) return msg;
  if (e.status == 0) {
    return 'Could not reach the server. Check your internet connection and try again.';
  }
  return 'Could not save: ${e.reasonPhrase ?? "the server returned an unexpected error (status ${e.status})."}';
}

// Compact, consistently-styled inline message strip for errors/warnings/
// info, instead of a bare red Text() at whatever the surrounding default
// font size happens to be (the inconsistent-size, too-much-space problem
// flagged in testing). Small icon + colored tint + tight padding, one line
// of visual hierarchy instead of plain red text competing with the form.
enum MsgKind { error, warning, info, success }

Widget msgBox(String text, {MsgKind kind = MsgKind.error}) {
  if (text.isEmpty) return const SizedBox.shrink();
  final (Color bg, Color fg, IconData icon) = switch (kind) {
    MsgKind.error => (const Color(0xFFFDEAEA), const Color(0xFFB3261E), Icons.error_outline),
    MsgKind.warning => (const Color(0xFFFFF4DE), const Color(0xFF8A5A00), Icons.warning_amber_rounded),
    MsgKind.info => (const Color(0xFFE8F0FE), const Color(0xFF1A4FAD), Icons.info_outline),
    MsgKind.success => (const Color(0xFFE6F4EA), kGreen, Icons.check_circle_outline),
  };
  return Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 16, color: fg),
      const SizedBox(width: 6),
      Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, color: fg, height: 1.3))),
    ]),
  );
}

// onTap is optional: dashboards that only show a number (e.g. "Average
// attendance") leave it out, while anything that's really a shortcut to a
// list screen (Madrasas, Students, Teachers...) passes one so the tile is
// Maps a dashboard tile's plain Material icon to a full-colour emoji that
// renders as a glossy "3D" glyph on every platform this app ships to
// (Android's system Noto Color Emoji, Chrome/desktop emoji fonts) - no new
// image assets to bundle or keep in sync. Tiles whose icon isn't in this
// (deliberately covering every icon actually passed to tile() in this
// codebase) map fall back to the plain Material icon further down.
final Map<IconData, String> _kTileEmoji = {
  Icons.search: '🔍',
  Icons.storage: '🗄️',
  Icons.account_tree: '🌳',
  Icons.groups: '👥',
  Icons.co_present: '🧑‍🏫',
  Icons.event_available: '📅',
  Icons.menu_book: '📖',
  Icons.event_busy: '🗓️',
  Icons.report_problem: '⚠️',
  Icons.diversity_3: '🤝',
  Icons.volunteer_activism: '🤲',
  Icons.payments: '💰',
  Icons.how_to_reg: '📝',
  Icons.calendar_month: '📅',
  Icons.check_circle: '✅',
  Icons.done_all: '✅',
  Icons.error_outline: '❗',
  Icons.filter_alt: '🧮',
  Icons.hourglass_top: '⏳',
  Icons.incomplete_circle: '🟠',
  Icons.inventory_2: '📦',
  Icons.savings: '🏦',
  Icons.schedule: '⏰',
  Icons.storefront: '🏪',
  Icons.task_alt: '✅',
  Icons.trending_up: '📈',
  Icons.undo: '↩️',
  Icons.warning_amber: '⚠️',
  Icons.admin_panel_settings: '🛡️',
  Icons.people: '👥',
  Icons.bar_chart: '📊',
  Icons.notifications: '🔔',
};

// One dashboard stat/shortcut card: a big glossy icon on the left, label +
// value on the right. Fixed-height icon/text blocks (rather than centering
// loosely in whatever space the grid cell happens to give it) are what
// keep this from leaving the large gaps a short label and a 16px icon used
// to leave in a much taller box - this fills that box instead of floating
// in the middle of it.
Widget tile(String label, String value, {Color? color, VoidCallback? onTap, IconData? icon}) {
  final emoji = icon == null ? null : _kTileEmoji[icon];
  final card = Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        if (icon != null) ...[
          if (emoji != null)
            Text(emoji, style: const TextStyle(fontSize: 34))
          else
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: kGreen.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 26, color: kGreen),
            ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: const TextStyle(fontSize: 11.5, color: Colors.black54), maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (onTap != null) const Icon(Icons.chevron_right, size: 16, color: Colors.black38),
      ]),
    ),
  );
  if (onTap == null) return card;
  return InkWell(borderRadius: BorderRadius.circular(4), onTap: onTap, child: card);
}

// Was a fixed crossAxisCount: 2 - fine on a phone, but on a tablet (or a
// wide Chrome window, which is what this app is actually tested in) two
// columns stretch into oversized, mostly-empty-looking tiles. Picks more
// columns as the available width grows instead, so a dashboard tile
// stays a sensible, readable size on any screen.
Widget grid(List<Widget> tiles) => LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final cols = w >= 900 ? 4 : (w >= 600 ? 3 : 2);
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.35,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: tiles,
        );
      },
    );

Widget h(String t, {IconData? icon}) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
      child: Row(children: [
        if (icon != null) ...[Icon(icon, size: 18, color: kGreen), const SizedBox(width: 6)],
        Expanded(child: Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: kGreen))),
      ]),
    );

// Every screen in the app is built from this one helper, so fixing it
// here fixes tablet layout everywhere at once rather than screen by
// screen. On a phone-width screen this is unchanged (full-width list). On
// a tablet or wide window, content is capped at a comfortable reading
// width and centered, instead of cards and text stretching edge to edge
// across the whole tablet screen, and form fields becoming awkwardly wide.
Widget page(List<Widget> children) => LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 760;
        final list = ListView(padding: const EdgeInsets.all(14), children: children);
        if (!isWide) return list;
        return Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: list));
      },
    );

// Pushes a screen built from `page([...])` as its own full page, with the
// Scaffold + AppBar it needs (the tab-hosted versions of these same screens
// get that chrome for free from the home shell they live inside, but a
// screen reached by tapping a dashboard tile is pushed on its own and has
// nothing providing it - which crashed any TextField on the page with
// "No Material widget found" and left other pages blank/looking frozen).
void pushPage(BuildContext context, String title, Widget body) {
  Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title), backgroundColor: kGreen, foregroundColor: Colors.white),
        body: body,
      ),
    ),
  );
}

Widget banner() {
  final a = st.announcements.where((x) => x.active).toList();
  if (a.isEmpty) return const SizedBox.shrink();
  final x = a.last;
  return Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(10),
    decoration: const BoxDecoration(color: Color(0xFFFFF3CF), border: Border(left: BorderSide(color: kGold, width: 4))),
    child: Text('Announcement from Super Admin (${x.priority}): ${x.title}\n${x.msg}', style: const TextStyle(fontWeight: FontWeight.w600)),
  );
}

// Shared "are you sure?" dialog for a destructive/hard-to-undo action -
// deactivating a Maktab/class/teacher/course/book, unassigning a mandatory
// Add-on Course from a class, withdrawing a live announcement, etc. Every
// call site below supplies its own specific wording for what the action
// actually does and whether it's reversible, rather than a generic "Are
// you sure?" that wouldn't tell anyone anything.
Future<bool> confirmDialog(BuildContext c, String title, String message, {String confirmLabel = 'Confirm', bool danger = true}) async {
  final ok = await showDialog<bool>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(
          style: danger ? ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600, foregroundColor: Colors.white) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

Future<String?> askText(BuildContext c, String title, {String initial = ''}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('OK')),
      ],
    ),
  );
}

// Full edit dialog for a student - name, parent mobile, address, plus the
// Madrasa/Class dropdowns that were missing entirely before (the only way
// to fix a student put under the wrong madrasa/class was to delete and
// re-add them). Stateful so the Madrasa/Class dropdown selections persist
// while the dialog is open.
Future<void> editStudentDialog(BuildContext context, Student s) async {
  final name = TextEditingController(text: s.name);
  final parent = TextEditingController(text: s.parentPhone);
  final address = TextEditingController(text: s.address);
  final fatherName = TextEditingController(text: s.fatherName);
  final dob = TextEditingController(text: s.dob ?? '');
  String madrasa = s.madrasa;
  int cls = s.cls;
  String batch = kBatches.contains(s.batch) ? s.batch : 'Morning';
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: const Text('Edit student'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            TextField(controller: fatherName, decoration: const InputDecoration(labelText: "Father's name")),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: DateTime.tryParse(dob.text) ?? DateTime(2016, 1, 1),
                  firstDate: DateTime(1990, 1, 1),
                  lastDate: DateTime.now(),
                );
                if (picked != null) {
                  setD(() => dob.text = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
                }
              },
              child: AbsorbPointer(
                child: TextField(controller: dob, decoration: const InputDecoration(labelText: 'Date of birth (tap to pick)')),
              ),
            ),
            const SizedBox(height: 8),
            TextField(controller: parent, decoration: const InputDecoration(labelText: 'Parent mobile number'), keyboardType: TextInputType.phone),
            const SizedBox(height: 8),
            TextField(controller: address, decoration: const InputDecoration(labelText: 'Address')),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              // The student's current Maktab may since have been deactivated
              // (or be a stale duplicate record) - st.activeMadrasaNames
              // alone would then not contain it, and binding `value` to a
              // name missing from `items` crashes this dialog outright. Make
              // sure the current value is always present as an item, even
              // when it's inactive, so editing never crashes; the admin can
              // still reassign to any active Maktab from the same list.
              value: madrasa,
              decoration: const InputDecoration(labelText: 'Maktab'),
              items: [
                for (final m in <String>{madrasa, ...st.activeMadrasaNames})
                  DropdownMenuItem(value: m, child: Text(st.activeMadrasaNames.contains(m) ? m : '$m (inactive)')),
              ],
              onChanged: (v) => setD(() => madrasa = v ?? madrasa),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              value: st.classDefs.containsKey(cls) ? cls : null,
              decoration: const InputDecoration(labelText: 'Class'),
              items: [for (final e in st.classDefs.entries) DropdownMenuItem(value: e.key, child: Text(e.value.name))],
              onChanged: (v) => setD(() => cls = v ?? cls),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: batch,
              decoration: const InputDecoration(labelText: 'Batch'),
              items: [for (final b in kBatches) DropdownMenuItem(value: b, child: Text(b))],
              onChanged: (v) => setD(() => batch = v ?? batch),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (result != true) return;
  var e = await editStudentRemote(s, name: name.text, parentPhone: parent.text, address: address.text, madrasa: madrasa, cls: cls, dob: dob.text, fatherName: fatherName.text, batch: batch);
  if (e != null && e.startsWith('DUPLICATE:')) {
    if (!context.mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Possible duplicate'),
        content: Text(e!.substring('DUPLICATE:'.length)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save anyway')),
        ],
      ),
    );
    if (proceed != true) return;
    if (!context.mounted) return;
    e = await editStudentRemote(s, name: name.text, parentPhone: parent.text, address: address.text, madrasa: madrasa, cls: cls, dob: dob.text, fatherName: fatherName.text, batch: batch, confirmDuplicate: true);
  }
  if (context.mounted) toast(context, e ?? 'Student updated.');
}

// Lets a Super Admin change a teacher's name, phone number and which
// Makatib they teach at from Master Data > Teachers - previously this
// screen could only toggle a teacher Active/Inactive once created, with no
// way to fix a typo'd name/number or hand them a different Maktab. Works
// for both a real account (a.dbId != null, saved via the update-teacher
// Edge Function) and a still-pending invite (saved directly to
// pending_role_invites) - same dialog either way, just a different save
// call underneath.
Future<void> editTeacherDialog(BuildContext context, Account a) async {
  final name = TextEditingController(text: a.name);
  final phone = TextEditingController(text: digits(a.phone));
  final selected = <String>{...a.teachMadrasas};
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: const Text('Edit teacher'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            TextField(controller: phone, decoration: const InputDecoration(labelText: 'Mobile number (10 digits)'), keyboardType: TextInputType.phone),
            const SizedBox(height: 10),
            const Text('Makatib this teacher will teach in:', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
            const SizedBox(height: 4),
            Wrap(spacing: 4, children: [
              for (final m in <String>{...st.activeMadrasaNames, ...a.teachMadrasas})
                FilterChip(
                  label: Text(st.activeMadrasaNames.contains(m) ? m : '$m (inactive)'),
                  selected: selected.contains(m),
                  onSelected: (v) => setD(() => v ? selected.add(m) : selected.remove(m)),
                ),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (result != true) return;
  final e = a.dbId == null
      ? await updatePendingTeacherInviteRemote(a, name: name.text, phone: phone.text, madrasaNames: selected.toList())
      : await updateTeacherRemote(a, name: name.text, phone: phone.text, madrasaNames: selected.toList());
  if (context.mounted) toast(context, e ?? 'Teacher updated.');
}

Widget field(TextEditingController c, String label, {bool number = false, int lines = 1, bool autofocus = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        autofocus: autofocus,
        maxLines: lines,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );

String digits(String s) {
  final d = s.replaceAll(RegExp(r'\D'), '');
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

void openTool(BuildContext context, Widget screen) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));

// ---------------- login / guest home (single screen, no login required for the 3 tools) ----------------
// Order per the approved UI amendment: institution name, "Powered by" line,
// logo, mobile-number field, Login button, then the 3 no-login tool icons.
class GuestHome extends StatefulWidget {
  const GuestHome({super.key});
  @override
  State<GuestHome> createState() => _GuestHomeState();
}

class _GuestHomeState extends State<GuestHome> {
  final phone = TextEditingController();
  final otp = TextEditingController();
  bool step2 = false;
  bool busy = false;
  String err = '';

  @override
  void initState() {
    super.initState();
    // Re-render as the person types so the buttons below can light up
    // only once there's something valid to submit.
    phone.addListener(() => setState(() {}));
    otp.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    phone.dispose();
    otp.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final p = digits(phone.text);
    if (p.length != 10) {
      setState(() => err = 'Enter a valid 10-digit mobile number.');
      return;
    }
    setState(() {
      busy = true;
      err = '';
    });
    try {
      await sb.auth.signInWithOtp(phone: '+91$p');
      setState(() {
        busy = false;
        step2 = true;
      });
    } on AuthException catch (e) {
      setState(() {
        busy = false;
        err = e.message;
      });
    } catch (e) {
      setState(() {
        busy = false;
        err = 'Could not reach the server. Check your internet connection and try again.';
      });
    }
  }

  // Lets someone re-request a fresh OTP without having to tap "Change
  // number" and re-type the same number, or reload the whole app - the
  // only two ways to recover before this existed once the first OTP's
  // short validity window (a minute or so) had passed.
  Future<void> _resendOtp() async {
    setState(() {
      busy = true;
      err = '';
      otp.clear();
    });
    try {
      await sb.auth.signInWithOtp(phone: '+91${digits(phone.text)}');
      if (!mounted) return;
      setState(() {
        busy = false;
        err = '';
      });
      toast(context, 'A new OTP has been sent.');
    } on AuthException catch (e) {
      setState(() {
        busy = false;
        err = e.message;
      });
    } catch (e) {
      setState(() {
        busy = false;
        err = 'Could not reach the server. Check your internet connection and try again.';
      });
    }
  }

  Future<void> _verifyOtp() async {
    final p = digits(phone.text);
    setState(() {
      busy = true;
      err = '';
    });
    try {
      final res = await sb.auth.verifyOTP(phone: '+91$p', token: otp.text.trim(), type: OtpType.sms);
      final uid = res.user?.id;
      if (uid == null) {
        setState(() {
          busy = false;
          err = 'Verification failed. Please try again.';
        });
        return;
      }
      // The database trigger that creates a user_profiles row for a new
      // sign-in runs almost instantly, but give it a couple of short
      // retries in case this request lands a moment before it does.
      Account? account;
      for (var i = 0; i < 4 && account == null; i++) {
        account = await loadSupabaseProfile(uid);
        if (account == null) await Future.delayed(const Duration(milliseconds: 500));
      }
      if (!mounted) return;
      if (account == null) {
        setState(() {
          busy = false;
          err = 'Signed in, but no role is set up for this account yet. Ask your Super Admin to assign one.';
        });
        return;
      }
      if (!account.active) {
        await sb.auth.signOut();
        setState(() {
          busy = false;
          err = 'This account has been deactivated. Contact your Maktab Admin.';
        });
        return;
      }
      st.loginWithAccount(account);
      // Fire-and-forget: Master Data (Madrasas/Courses) loads in the
      // background so login itself isn't held up by it; the Home screen
      // and Master Data screen just show demo data for a moment if this is
      // still in flight, then update once it resolves (st is a
      // ChangeNotifier, so any screen listening to it redraws).
      unawaited(loadMasterData().then((_) => subscribeRealtime()));
    } on AuthException catch (e) {
      // Supabase's own wording here ("Token has expired or is invalid") is
      // accurate but doesn't tell someone what to do about it - an OTP is
      // only valid for a short window, so this fires often simply because
      // it was typed in a bit too slowly, not because anything is broken.
      final expired = e.message.toLowerCase().contains('expired') || e.message.toLowerCase().contains('invalid');
      setState(() {
        busy = false;
        err = expired ? 'This OTP has expired or was entered incorrectly. Tap "Resend OTP" below to get a new one.' : e.message;
      });
    } catch (e) {
      setState(() {
        busy = false;
        err = 'Could not verify the OTP. Check your internet connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // The logo is the first thing someone sees on this screen, so it leads
    // (name and subtitle follow it) and scales with the screen instead of a
    // fixed 84px - a small size on a big tablet, or cramped on a small
    // phone, is what "not clearly visible" meant here. Clamped so it never
    // gets absurdly large on a tablet or too small on a narrow phone; using
    // only `height` (no `width`) keeps Image.asset's own aspect ratio, so
    // it can never stretch or distort.
    final screenW = MediaQuery.of(context).size.width;
    final logoHeight = screenW.clamp(300.0, 900.0) * 0.42;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 10),
            Center(child: Image.asset('assets/logo.png', height: logoHeight)),
            const SizedBox(height: 18),
            const Text('Maktab-e-Tajushshariah', style: TextStyle(color: kGreen, fontSize: 23, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
            const SizedBox(height: 4),
            const Text('Powered by Faiz-E-Raza Group Mehkar', style: TextStyle(color: Colors.black54, fontSize: 13), textAlign: TextAlign.center),
            const SizedBox(height: 28),
            if (!step2) ...[
              field(phone, 'Mobile number', number: true, autofocus: true),
              const SizedBox(height: 4),
              msgBox(err),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: digits(phone.text).length == 10 ? Colors.red : Colors.grey.shade300,
                    foregroundColor: digits(phone.text).length == 10 ? Colors.white : Colors.black38,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: digits(phone.text).length == 10 ? 2 : 0,
                  ),
                  onPressed: (busy || digits(phone.text).length != 10) ? null : _sendOtp,
                  child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Login'),
                ),
              ),
              const SizedBox(height: 10),
              const Text('An OTP will be sent to this number by SMS.', style: TextStyle(fontSize: 12, color: Colors.black54)),
            ] else ...[
              Text('OTP sent to +91 ${digits(phone.text)}', textAlign: TextAlign.center),
              const SizedBox(height: 10),
              field(otp, 'Enter OTP', number: true, autofocus: true),
              const SizedBox(height: 4),
              msgBox(err),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: otp.text.trim().isNotEmpty ? kGreen : Colors.grey.shade300,
                    foregroundColor: otp.text.trim().isNotEmpty ? Colors.white : Colors.black38,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: otp.text.trim().isNotEmpty ? 2 : 0,
                  ),
                  onPressed: (busy || otp.text.trim().isEmpty) ? null : _verifyOtp,
                  child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Verify & Login'),
                ),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                TextButton(onPressed: busy ? null : _resendOtp, child: const Text('Resend OTP')),
                TextButton(onPressed: busy ? null : () => setState(() => step2 = false), child: const Text('Change number')),
              ]),
            ],
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 10),
            const Text('No login needed for these tools:', style: TextStyle(color: Colors.black54), textAlign: TextAlign.center),
            const SizedBox(height: 14),
            ..._iconRows([
              _bottomIcon(context, Icons.fingerprint, 'Tasbeeh', () => openTool(context, const TasbeehScreen())),
              _bottomIcon(context, Icons.explore, 'Qibla Direction', () => openTool(context, const QiblaScreen())),
              _bottomIcon(context, Icons.calendar_month, 'Islamic Calendar', () => openTool(context, const CalendarScreen())),
              _bottomIcon(context, Icons.schedule, 'Maktab Timing', () => openTool(context, const GuestMaktabTimingScreen())),
              _bottomIcon(context, Icons.access_time, 'Prayer Times', () => openTool(context, const PrayerTimesScreen())),
              _bottomIcon(context, Icons.menu_book, 'Surah Yaseen', () => openTool(context, const SurahYaseenScreen())),
              _bottomIcon(context, Icons.info_outline, 'About Us', () => openTool(context, const AboutUsScreen())),
            ]),
          ],
        ),
      ),
    );
  }

  // Exactly 3 icons per row, each given equal width (Expanded) so they
  // stay the same size and evenly spaced regardless of label length - a
  // Wrap alone can't guarantee a fixed count per row since that depends on
  // how much text happens to fit. Extra icons beyond a multiple of 3 fall
  // onto their own row instead of being squeezed in.
  List<Widget> _iconRows(List<Widget> icons) {
    final rows = <Widget>[];
    for (var i = 0; i < icons.length; i += 3) {
      final end = i + 3 < icons.length ? i + 3 : icons.length;
      final group = icons.sublist(i, end);
      rows.add(Row(children: [for (final w in group) Expanded(child: w)]));
      if (i + 3 < icons.length) rows.add(const SizedBox(height: 14));
    }
    return rows;
  }

  Widget _bottomIcon(BuildContext context, IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(40),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(radius: 28, backgroundColor: const Color(0xFFEEF4E8), child: Icon(icon, color: kGreen, size: 28)),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center, maxLines: 2),
          ]),
        ),
      );
}

// ---------------- shell ----------------
class AppTab {
  final String title;
  final IconData icon;
  final Widget Function() build;
  AppTab(this.title, this.icon, this.build);
}

List<AppTab> tabsFor(Account u) {
  final kidTabs = <AppTab>[
    AppTab('Home', Icons.home, () => const KidHome()),
    AppTab('Attendance', Icons.event_available, () => const KidAttendance()),
    AppTab('Syllabus', Icons.menu_book, () => const KidSyllabus()),
  ];
  switch (u.role) {
    case 'parent':
      if (st.studentView) return kidTabs;
      return [
        ...kidTabs,
        AppTab('Add-on Course Progress', Icons.verified, () => const KidCourseProgress()),
        AppTab('Fees', Icons.payments, () => const KidFees()),
        AppTab('Complaints', Icons.report_problem, () => const ComplaintsView()),
        AppTab('Documents', Icons.badge, () => const KidDocs()),
      ];
    case 'student':
      return kidTabs;
    case 'teacher':
      return [
        AppTab('Home', Icons.home, () => const StaffHome()),
        AppTab('My Day', Icons.today, () => const MyDayView()),
        AppTab('My Attendance & Leave', Icons.how_to_reg, () => const TeacherSelf()),
        AppTab('Student Attendance', Icons.event_available, () => const StudentAttendanceMark()),
        AppTab('Syllabus Progress', Icons.menu_book, () => const TeacherSyllabus()),
        // Requirement 3: Teachers (not just Super Admin) can create/edit
        // classes from Class 4 onward and manage Books - reuses the same
        // MasterDataView screen Super Admin uses, which hides the
        // Maktab/Teacher-invite/Admin-invite/Roles sections for a teacher
        // and shows only Classes, Books and Add-on Courses.
        AppTab('Classes & Books', Icons.menu_book, () => const MasterDataView()),
        AppTab('Students & Promotion', Icons.school, () => const StudentsView()),
        AppTab('Add-on Course Progress', Icons.verified, () => const CourseApprovalsView()),
        AppTab('Complaints', Icons.report_problem, () => const ComplaintsView()),
      ];
    case 'admin':
      return [
        AppTab('Home', Icons.home, () => const StaffHome()),
        AppTab('Master Data', Icons.storage, () => const MasterDataDashboard()),
        AppTab('Approvals', Icons.how_to_reg, () => const ApprovalsView()),
        AppTab('Teachers & Leave', Icons.groups, () => const TeachersView()),
        AppTab('Fees', Icons.payments, () => const FeesAdmin()),
        AppTab('Students & Promotion', Icons.school, () => const StudentsView()),
        AppTab('Syllabus Progress', Icons.menu_book, () => const TeacherSyllabus()),
        AppTab('Add-on Course Approvals', Icons.verified, () => const CourseApprovalsView()),
        AppTab('Complaints', Icons.report_problem, () => const ComplaintsView()),
      ];
    case 'super':
      return [
        AppTab('Home', Icons.home, () => const StaffHome()),
        AppTab('Master Data', Icons.storage, () => const MasterDataDashboard()),
        AppTab('Classes & Syllabus', Icons.menu_book, () => const SuperSyllabus()),
        AppTab('All Students', Icons.school, () => const StudentsView()),
        AppTab('Teachers & Leave', Icons.groups, () => const TeachersView()),
        AppTab('Teacher Makatib', Icons.swap_horiz, () => const TeacherMadrasasAdmin()),
        AppTab('Add-on Course Approvals', Icons.verified, () => const CourseApprovalsView()),
        AppTab('Fee QR & Reminders', Icons.qr_code, () => const FeeQrAdmin()),
        AppTab('Reports', Icons.assessment, () => const ReportsView()),
        AppTab('Roles', Icons.admin_panel_settings, () => const RolesView()),
        AppTab('Committee Members', Icons.visibility, () => const CommitteeAdmin()),
        AppTab('Complaints', Icons.report_problem, () => const ComplaintsView()),
      ];
    case 'committee':
      return [AppTab('Dashboard', Icons.dashboard, () => const CommitteeDashboard())];
    default:
      final perms = st.customRoles[u.roleName] ?? <String>{};
      final list = <AppTab>[];
      if (perms.contains('Students')) list.add(AppTab('Students', Icons.school, () => const StudentsView()));
      if (perms.contains('Fees')) list.add(AppTab('Fees', Icons.payments, () => const FeesAdmin()));
      if (perms.contains('Reports')) list.add(AppTab('Reports', Icons.assessment, () => const ReportsView()));
      if (perms.contains('Leave')) list.add(AppTab('Teacher Leave', Icons.groups, () => const TeachersView()));
      if (list.isEmpty) list.add(AppTab('No screens', Icons.block, () => page([const Text('No screens have been given to this role.')])));
      return list;
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int idx = 0;
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(animation: st, builder: (context, _) {
      final u = st.user;
      if (u == null) return const SizedBox.shrink();
      final tabs = tabsFor(u);
      if (idx >= tabs.length) idx = 0;
      final isMultiMadrasaTeacher = u.role == 'teacher' && u.teachMadrasas.length > 1;
      return Scaffold(
        appBar: AppBar(
          backgroundColor: kGreen,
          foregroundColor: Colors.white,
          // Every tab screen except Home gets an explicit back-to-home
          // button, since switching tabs here does not use the Navigator
          // stack (so there is no automatic back arrow to rely on). The
          // drawer/menu icon moves into actions on those screens so it is
          // not lost when the leading slot is used for Back.
          leading: idx != 0
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back to Home',
                  onPressed: () => setState(() => idx = 0),
                )
              : null,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tabs[idx].title, style: const TextStyle(fontSize: 18)),
            Text('${roleLabel(u)} - ${u.name}', style: const TextStyle(fontSize: 11, color: Color(0xFFF0D98A))),
          ]),
          actions: [
            if (u.role == 'super')
              IconButton(
                icon: Badge(
                  label: Text('${st.unreadAdminNotifCount}'),
                  isLabelVisible: st.unreadAdminNotifCount > 0,
                  child: const Icon(Icons.notifications),
                ),
                tooltip: 'Notifications',
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminNotificationsScreen())),
              ),
            if (idx != 0)
              Builder(
                builder: (ctx) => IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: 'Menu',
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                ),
              ),
            if (isMultiMadrasaTeacher)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(
                  child: DropdownButton<String>(
                    value: st.teacherMadrasa,
                    dropdownColor: kGreen,
                    underline: const SizedBox.shrink(),
                    icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    items: [for (final m in u.teachMadrasas) DropdownMenuItem<String>(value: m, child: Text(m))],
                    onChanged: (v) {
                      if (v != null) st.setTeacherMadrasa(v);
                    },
                  ),
                ),
              ),
          ],
        ),
        drawer: Drawer(
          child: ListView(children: [
            DrawerHeader(
              decoration: const BoxDecoration(color: kGreen),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Image.asset('assets/logo.png', height: 64),
                const SizedBox(height: 8),
                const Text('Maktab-E-Tajushshriah', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                Text(roleLabel(u), style: const TextStyle(color: Color(0xFFF0D98A))),
              ]),
            ),
            for (var i = 0; i < tabs.length; i++)
              ListTile(
                leading: Icon(tabs[i].icon),
                title: Text(tabs[i].title),
                selected: i == idx,
                onTap: () {
                  setState(() => idx = i);
                  Navigator.pop(context);
                },
              ),
            const Divider(),
            if (u.role == 'parent')
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: Text(st.studentView ? 'Switch to Parent view' : 'Switch to Student view'),
                onTap: () {
                  st.toggleStudentView();
                  setState(() => idx = 0);
                  Navigator.pop(context);
                },
              ),
            if (u.role == 'super' || st.canRecordSadqaCollections) ...[
              const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Sadqa Peti', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54, fontSize: 12))),
              if (u.role == 'super') ...[
                ListTile(
                  leading: const Icon(Icons.inventory_2),
                  title: const Text('Manage Sadqa Peti Boxes'),
                  onTap: () {
                    Navigator.pop(context);
                    pushPage(context, 'Sadqa Peti Boxes', const SadqaPetiMasterView());
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.dashboard),
                  title: const Text('Sadqa Peti Dashboard'),
                  onTap: () {
                    Navigator.pop(context);
                    pushPage(context, 'Sadqa Peti Dashboard', const SadqaPetiDashboardView());
                  },
                ),
              ],
              if (st.canRecordSadqaCollections)
                ListTile(
                  leading: const Icon(Icons.volunteer_activism),
                  title: const Text('Sadqa Peti Collection'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SadqaCollectionScreen()));
                  },
                ),
              const Divider(),
            ],
            const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('No-login tools', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54, fontSize: 12))),
            ListTile(leading: const Icon(Icons.explore), title: const Text('Qibla Direction'), onTap: () { Navigator.pop(context); openTool(context, const QiblaScreen()); }),
            ListTile(leading: const Icon(Icons.calendar_month), title: const Text('Calendar'), onTap: () { Navigator.pop(context); openTool(context, const CalendarScreen()); }),
            ListTile(leading: const Icon(Icons.schedule), title: const Text('Maktab Timing'), onTap: () { Navigator.pop(context); openTool(context, const GuestMaktabTimingScreen()); }),
            ListTile(leading: const Icon(Icons.fingerprint), title: const Text('Tasbeeh Counter'), onTap: () { Navigator.pop(context); openTool(context, const TasbeehScreen()); }),
            ListTile(leading: const Icon(Icons.access_time), title: const Text('Prayer Times (Hanafi)'), onTap: () { Navigator.pop(context); openTool(context, const PrayerTimesScreen()); }),
            ListTile(leading: const Icon(Icons.menu_book), title: const Text('Surah Yaseen'), onTap: () { Navigator.pop(context); openTool(context, const SurahYaseenScreen()); }),
            ListTile(leading: const Icon(Icons.info_outline), title: const Text('About Us'), onTap: () { Navigator.pop(context); openTool(context, const AboutUsScreen()); }),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Logout'),
              onTap: () async {
                final nav = Navigator.of(context);
                nav.pop(); // close the drawer
                // Clear local session first and unconditionally: this used
                // to await sb.auth.signOut() with no try/catch or timeout,
                // so on any network hiccup the whole tap silently did
                // nothing and the user stayed logged in with no feedback.
                // The remote sign-out is still attempted (so the server
                // session is invalidated too when possible), but a slow or
                // failed network call can no longer block the local logout.
                st.logout();
                // Drop any screens pushed via Navigator.push (Roles,
                // student details, etc.) so the back button can't walk
                // back into authenticated screens after logging out.
                nav.popUntil((r) => r.isFirst);
                try {
                  await sb.auth.signOut().timeout(const Duration(seconds: 8));
                } catch (_) {
                  // Local session is already cleared above; a failed
                  // remote sign-out just means the old server-side session
                  // lingers until it expires on its own - not visible to
                  // this user, who is already back at the login screen.
                }
              },
            ),
          ]),
        ),
        body: tabs[idx].build(),
      );
    });
  }
}

// ---------------- parent / student ----------------
class KidPicker extends StatelessWidget {
  const KidPicker({super.key});
  @override
  Widget build(BuildContext context) {
    final ks = st.kids();
    if (ks.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<int>(
        value: st.currentKid()?.id,
        decoration: const InputDecoration(labelText: 'Child', border: OutlineInputBorder()),
        items: [for (final k in ks) DropdownMenuItem<int>(value: k.id, child: Text('${k.name} - ${st.className(k.cls)}'))],
        onChanged: (v) {
          if (v != null) st.selectKid(v);
        },
      ),
    );
  }
}

Prog progFor(Student s) {
  final cd = st.classDefs[s.cls]!;
  return cd.pageBased ? st.pageProg(s) : st.chapterProg(s);
}

// Date-wise Present/Absent/Event/Holiday/Weekend/Not-Recorded attendance
// history with month navigation and a monthly summary - shared by the
// Parent's attendance screen and the Teacher/Admin's StudentDetail
// Attendance tab, so there is one real implementation instead of two
// (one of which used to be a fabricated "Attendance Sep: X%" stat with no
// real month behind it).
class AttendanceMonthReport extends StatefulWidget {
  final Student s;
  const AttendanceMonthReport({super.key, required this.s});
  @override
  State<AttendanceMonthReport> createState() => _AttendanceMonthReportState();
}

class _AttendanceMonthReportState extends State<AttendanceMonthReport> {
  late int year;
  late int month;
  MonthAttendanceSummary? summary;
  bool loading = true;
  String filter = 'All';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    year = now.year;
    month = now.month;
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final r = await loadMonthAttendance(widget.s, year, month);
    if (!mounted) return;
    setState(() {
      summary = r;
      loading = false;
      filter = 'All';
    });
  }

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return year == now.year && month == now.month;
  }

  void _shiftMonth(int delta) {
    var m = month + delta;
    var y = year;
    if (m < 1) {
      m = 12;
      y--;
    } else if (m > 12) {
      m = 1;
      y++;
    }
    // Never navigate into a future month - nothing is scheduled yet there.
    final now = DateTime.now();
    if (y > now.year || (y == now.year && m > now.month)) return;
    setState(() {
      year = y;
      month = m;
    });
    _load();
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'Present':
        return const Color(0xFF2E7D32);
      case 'Absent':
        return const Color(0xFFC62828);
      case 'Event':
        return const Color(0xFFB8860B);
      case 'Holiday':
        return const Color(0xFF6A1B9A);
      case 'Weekend':
        return Colors.black45;
      default:
        return Colors.black38;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    const monthNames = [
      'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December' //
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: loading ? null : () => _shiftMonth(-1)),
        Expanded(
          child: Text('${monthNames[month - 1]} $year', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        ),
        IconButton(icon: const Icon(Icons.chevron_right), onPressed: (loading || _isCurrentMonth) ? null : () => _shiftMonth(1)),
      ]),
      if (loading) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
      if (!loading && summary == null) const Padding(padding: EdgeInsets.all(12), child: Text('Could not load attendance. Check your connection and try again.')),
      if (!loading && summary != null) ...() {
        final sm = summary!;
        return <Widget>[
          Card(
            color: const Color(0xFFF3F7FF),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s.name} - ${nice(fd(DateTime(sm.year, sm.month, 1)))} to ${nice(fd(DateTime(sm.year, sm.month + 1, 0)))}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 6),
                Wrap(spacing: 10, runSpacing: 6, children: [
                  Text('Present: ${sm.present}', style: TextStyle(color: _statusColor('Present'), fontWeight: FontWeight.bold)),
                  Text('Absent: ${sm.absent}', style: TextStyle(color: _statusColor('Absent'), fontWeight: FontWeight.bold)),
                  Text('Events: ${sm.eventDays}', style: TextStyle(color: _statusColor('Event'), fontWeight: FontWeight.bold)),
                  Text('Holidays: ${sm.holidayDays}', style: TextStyle(color: _statusColor('Holiday'), fontWeight: FontWeight.bold)),
                  Text('Weekends: ${sm.weekendDays}', style: TextStyle(color: _statusColor('Weekend'), fontWeight: FontWeight.bold)),
                  Text('Not Recorded: ${sm.notRecorded}', style: TextStyle(color: _statusColor('Not Recorded'), fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 8),
                Text('Attendance: ${sm.pct}% of ${sm.eligibleScheduledDays} eligible scheduled day(s) (day-based - events, holidays, weekends and not-recorded days excluded)',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final f in const ['All', 'Present', 'Absent', 'Event', 'Holiday', 'Weekend', 'Not Recorded'])
              ChoiceChip(label: Text(f), selected: filter == f, onSelected: (_) => setState(() => filter = f)),
          ]),
          const SizedBox(height: 8),
          ...sm.days.where((d) => filter == 'All' || d.status == filter).toList().reversed.map((d) => Card(
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.circle, size: 12, color: _statusColor(d.status)),
                  title: Text(nice(d.date)),
                  trailing: Text(d.status + (d.eventName != null ? ': ${d.eventName}' : ''), style: TextStyle(color: _statusColor(d.status), fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                ),
              )),
        ];
      }(),
    ]);
  }
}

class KidHome extends StatelessWidget {
  const KidHome({super.key});
  @override
  Widget build(BuildContext context) =>
      // Own AnimatedBuilder, same reason as StaffHome/StudentAttendanceMark:
      // reached via a const widget factory in tabsFor(), so without this it
      // doesn't reliably rebuild when st changes - in particular right
      // after login, when st.students is still empty/placeholder on this
      // screen's very first paint and the real data (which would turn "No
      // child is linked to this number" into the actual child) only
      // arrives a moment later once loadMasterData resolves.
      AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final k = st.currentKid();
    if (k == null) return page([banner(), const Text('No child is linked to this number.')]);
    final p = progFor(k);
    final alerts = st.notes.where((n) => n.phone == k.parentPhone).toList().reversed.take(5).toList();
    return page([
      banner(),
      KidPicker(),
      Text(k.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      Text('${st.className(k.cls)} - ${k.madrasa} - ID ${k.key}'),
      const SizedBox(height: 8),
      grid([
        tile('Attendance Sep', '${st.attPct(k)}%'),
        tile('Syllabus', p.label ?? '${p.n} of ${p.total} (${p.pct}%)'),
        tile('Plan status', p.behind > 0 ? 'Behind ${p.behind} days' : 'On pace', color: p.behind > 0 ? Colors.red : Colors.green),
        // There is no exam/marks feature anywhere in the app yet to source
        // a real result from - showing a fixed "60/70 - rank 3" here would
        // be exactly the kind of fabricated statistic flagged in testing.
        // Being honest that this isn't wired up yet, rather than a fake
        // number, until a real Exams/Results feature exists.
        tile('Latest result', 'Not recorded yet'),
      ]),
      if (st.showFees) h('Fees (month-wise)', icon: Icons.payments),
      if (st.showFees)
        Wrap(spacing: 6, children: [
          for (final m in st.feeMonths(k))
            Chip(
              label: Text(st.isPaid(k.id, m) ? '$m - Paid' : '$m due'),
              backgroundColor: st.isPaid(k.id, m) ? const Color(0xFFDFF3DA) : const Color(0xFFFFE3E0),
            ),
        ]),
      h('Alerts'),
      if (alerts.isEmpty) const Text('No alerts'),
      ...alerts.map((a) => Card(child: ListTile(title: Text(a.text)))),
    ]);
  }
}

class KidAttendance extends StatelessWidget {
  const KidAttendance({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final k = st.currentKid();
    if (k == null) return page([const Text('No child is linked to this number.')]);
    return page([
      KidPicker(),
      h('Attendance - ${k.name} - ${st.className(k.cls)}, ${k.madrasa}', icon: Icons.event_available),
      // Keyed on the student so switching between siblings (KidPicker)
      // reloads a fresh report instead of reusing the previous child's
      // already-loaded month.
      AttendanceMonthReport(key: ValueKey(k.id), s: k),
    ]);
  }
}

class KidSyllabus extends StatelessWidget {
  const KidSyllabus({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final k = st.currentKid();
    if (k == null) return page([const Text('No child is linked to this number.')]);
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 0), child: KidPicker()),
      Expanded(child: SyllabusBody(s: k, edit: false)),
    ]);
  }
}

// A single body used by parent/student (read-only) and teacher (editable),
// switching automatically between page-based (Classes 1-3) and
// chapter-based (Class 4+) rendering.
class SyllabusBody extends StatelessWidget {
  final Student s;
  final bool edit;
  const SyllabusBody({super.key, required this.s, required this.edit});
  @override
  Widget build(BuildContext context) {
    final cd = st.classDefs[s.cls]!;
    return cd.pageBased ? _pageBody(context, cd) : _chapterBody(context);
  }

  Widget _pageBody(BuildContext context, ClassDef cd) {
    final p = st.pageProg(s);
    final cur = st.currentPageNo(s);
    return page([
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s.name} - ${cd.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Book: ${cd.bookName}', style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: p.pct / 100),
            const SizedBox(height: 6),
            Text('${p.label} (${p.pct}%) - own start date ${nice(s.start)}'),
            Text(p.behind > 0 ? 'Behind pace by about ${p.behind} page(s)' : 'On pace', style: TextStyle(color: p.behind > 0 ? Colors.red : Colors.green, fontWeight: FontWeight.bold)),
          ]),
        ),
      ),
      const SizedBox(height: 4),
      const Text('Legend: green = Completed (with date), amber = In progress, grey = Pending', style: TextStyle(fontSize: 11.5, color: Colors.black54)),
      const SizedBox(height: 8),
      if (cd.paras.isNotEmpty) ..._paraPageGrids(context, cd, cur) else _flatPageGrid(context, cd, cur, 1, cd.totalPages),
      if (edit && cur != null)
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: ElevatedButton.icon(
            onPressed: () => markPageDialog(context, s, cur),
            icon: const Icon(Icons.check),
            label: Text('Mark page $cur complete'),
          ),
        ),
      if (cur == null) const Padding(padding: EdgeInsets.only(top: 14), child: Text('All pages of this book are complete.', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold))),
      ..._bookSectionWidgets(context),
    ]);
  }

  void _showPageInfo(BuildContext context, int pageNo) {
    final date = s.pageDate[pageNo];
    final grade = s.pageGrade[pageNo] ?? '';
    toast(context, 'Page $pageNo: Completed ${date != null ? nice(date) : ''} - $grade');
  }

  // One grid of `count` cells, numbered 1..count for display, but reading
  // and writing progress against the flat book-wide page number
  // (startPageNo + local index) - the same numbers pageDate/pageGrade and
  // every page-based calculation in AppState has always used. Used as-is
  // for a plain flat book (startPageNo 1, count = cd.totalPages) and once
  // per Para for a Para-wise book.
  Widget _flatPageGrid(BuildContext context, ClassDef cd, int? cur, int startPageNo, int count) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 6, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 1),
      itemCount: count,
      itemBuilder: (context, i) {
        final pageNo = startPageNo + i;
        final localNo = i + 1;
        final status = st.pageStatus(s, pageNo);
        final color = status == 'Completed' ? const Color(0xFF2E7D32) : (status == 'In progress' ? kGold : const Color(0xFFDADFD3));
        final textColor = status == 'Pending' ? Colors.black54 : Colors.white;
        return GestureDetector(
          onTap: () {
            if (status == 'Completed') {
              _showPageInfo(context, pageNo);
            } else if (edit && status == 'In progress') {
              markPageDialog(context, s, pageNo);
            } else if (status == 'Pending') {
              toast(context, 'Page $pageNo is Pending. Complete page $cur first.');
            }
          },
          child: Container(
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
            alignment: Alignment.center,
            child: Text('$localNo', style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        );
      },
    );
  }

  // One Para-labelled grid per Para, in teaching/display order (see
  // AppState.parasInSequence - plain ascending 1..30 for every class
  // except the Hafizi Qur'an, which teaches Para 30 first, then 1-29).
  // Each grid's page numbers are still that Para's real, physical book
  // page range (AppState.paraStartPage) - only which Para's grid is shown
  // first changes, never what page number a page actually is.
  List<Widget> _paraPageGrids(BuildContext context, ClassDef cd, int? cur) {
    final widgets = <Widget>[];
    for (final p in st.parasInSequence(cd)) {
      final start = st.paraStartPage(cd, p.paraNo);
      if (start == null) continue;
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Text('Para ${p.paraNo} (${p.pageCount} pages)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
      ));
      widgets.add(_flatPageGrid(context, cd, cur, start, p.pageCount));
    }
    return widgets;
  }

  Widget _chapterBody(BuildContext context) {
    final p = st.chapterPlan(s);
    final pr = st.chapterProg(s);
    return page([
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s.name} - ${st.className(s.cls)}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: pr.pct / 100),
            const SizedBox(height: 6),
            Text('${pr.pct}% complete - own start date ${nice(s.start)}'),
            Text(pr.behind > 0 ? 'Behind ${pr.behind} days' : 'On track', style: TextStyle(color: pr.behind > 0 ? Colors.red : Colors.green, fontWeight: FontWeight.bold)),
          ]),
        ),
      ),
      for (var i = 0; i < p.length; i++)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${i + 1}. ${p[i].title}', style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('Plan: ${nice(p[i].plan)}'),
              if (p[i].done != null)
                Text('Completed ${nice(p[i].done!)} - ${diffDays(p[i].done!, p[i].plan) > 0 ? '${diffDays(p[i].done!, p[i].plan)} days late' : 'on time'} - ${p[i].grade}', style: const TextStyle(color: Colors.green))
              else if (diffDays(kToday, p[i].plan) > 0)
                Text('Behind ${diffDays(kToday, p[i].plan)} days', style: const TextStyle(color: Colors.red))
              else
                const Text('In progress', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
              if (edit && p[i].done == null)
                Padding(padding: const EdgeInsets.only(top: 6), child: ElevatedButton(onPressed: () => tickChapterDialog(context, s, i), child: const Text('Mark as completed'))),
            ]),
          ),
        ),
      ..._bookSectionWidgets(context),
    ]);
  }

  // Book Management progress (Class 4+ Books, requirement 4/8) - shown
  // under whichever body (page or chapter) this class otherwise uses, for
  // every Book assigned to the student's class. Same shared widget used by
  // student/parent (read-only) and teacher (editable), so a fix here
  // reaches every screen automatically, same as the page/Para grids above.
  List<Widget> _bookSectionWidgets(BuildContext context) {
    final cd = st.classDefs[s.cls]!;
    final books = st.booksForClass(cd.id);
    if (books.isEmpty) return const [];
    final widgets = <Widget>[
      const SizedBox(height: 10),
      const Divider(),
      const Text('Books', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
    ];
    for (final b in books) {
      final prog = st.bookProg(s, b);
      final cur = st.currentBookPageNo(s, b);
      widgets.add(Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (b.description.isNotEmpty) Text(b.description, style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: b.totalPages == 0 ? 0 : prog.pct / 100),
            const SizedBox(height: 6),
            Text('${prog.label} (${prog.pct}%)'),
            const SizedBox(height: 8),
            if (b.totalPages > 0) _flatBookPageGrid(context, b, cur),
            if (edit && cur != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: ElevatedButton.icon(
                  onPressed: () => markBookPageDialog(context, s, b, cur),
                  icon: const Icon(Icons.check),
                  label: Text('Mark page $cur complete'),
                ),
              ),
            if (cur == null && b.totalPages > 0)
              const Padding(padding: EdgeInsets.only(top: 10), child: Text('All pages of this Book are complete.', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold))),
          ]),
        ),
      ));
    }
    return widgets;
  }

  Widget _flatBookPageGrid(BuildContext context, ClassBook b, int? cur) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 6, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 1),
      itemCount: b.totalPages,
      itemBuilder: (context, i) {
        final pageNo = i + 1;
        final status = st.bookPageStatus(s, b, pageNo);
        final color = status == 'Completed' ? const Color(0xFF2E7D32) : (status == 'In progress' ? kGold : const Color(0xFFDADFD3));
        final textColor = status == 'Pending' ? Colors.black54 : Colors.white;
        return GestureDetector(
          onTap: () {
            if (status == 'Completed') {
              final date = s.bookPageDate['${b.id}:$pageNo'];
              final grade = s.bookPageGrade['${b.id}:$pageNo'] ?? '';
              toast(context, 'Page $pageNo: Completed ${date != null ? nice(date) : ''} - $grade');
            } else if (edit && status == 'In progress') {
              markBookPageDialog(context, s, b, pageNo);
            } else if (status == 'Pending') {
              toast(context, 'Page $pageNo is Pending. Complete page $cur first.');
            }
          },
          child: Container(
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
            alignment: Alignment.center,
            child: Text('$pageNo', style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        );
      },
    );
  }
}

Future<void> markBookPageDialog(BuildContext c, Student s, ClassBook b, int pageNo) async {
  final date = TextEditingController(text: kToday);
  String grade = 'Good';
  await showDialog<void>(
    context: c,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text('Mark page $pageNo complete - ${b.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: date, decoration: const InputDecoration(labelText: 'Completion date (yyyy-mm-dd)')),
          const SizedBox(height: 8),
          DropdownButton<String>(
            value: grade,
            isExpanded: true,
            items: [for (final g in ['Excellent', 'Good', 'Needs practice']) DropdownMenuItem<String>(value: g, child: Text(g))],
            onChanged: (v) => setD(() => grade = v ?? grade),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final msg = await markBookPageCompleteRemote(s, b, pageNo, date.text.trim(), grade);
              if (ctx.mounted) Navigator.pop(ctx);
              if (msg != null && c.mounted) toast(c, msg);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

Future<void> markPageDialog(BuildContext c, Student s, int pageNo) async {
  final date = TextEditingController(text: kToday);
  final remark = TextEditingController();
  String grade = 'Good';
  await showDialog<void>(
    context: c,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text('Mark page $pageNo complete'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: date, decoration: const InputDecoration(labelText: 'Completion date (yyyy-mm-dd)')),
          const SizedBox(height: 8),
          DropdownButton<String>(
            value: grade,
            isExpanded: true,
            items: [for (final g in ['Excellent', 'Good', 'Needs practice']) DropdownMenuItem<String>(value: g, child: Text(g))],
            onChanged: (v) => setD(() => grade = v ?? grade),
          ),
          TextField(controller: remark, decoration: const InputDecoration(labelText: 'Remark (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final msg = await markPageCompleteRemote(s, pageNo, date.text.trim(), grade, remark.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
              if (msg != null && c.mounted) toast(c, msg);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

Future<void> tickChapterDialog(BuildContext c, Student s, int i) async {
  final date = TextEditingController(text: kToday);
  String grade = 'Good';
  await showDialog<void>(
    context: c,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text('Tick: ${st.chapters[s.cls]![i].title}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: date, decoration: const InputDecoration(labelText: 'Completion date (yyyy-mm-dd)')),
          DropdownButton<String>(
            value: grade,
            isExpanded: true,
            items: [for (final g in ['Excellent', 'Good', 'Needs practice']) DropdownMenuItem<String>(value: g, child: Text(g))],
            onChanged: (v) => setD(() => grade = v ?? grade),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final msg = await tickChapterRemote(s, i, date.text.trim(), grade);
              if (ctx.mounted) Navigator.pop(ctx);
              if (msg != null && c.mounted) toast(c, msg);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

class KidFees extends StatelessWidget {
  const KidFees({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final k = st.currentKid();
    if (k == null) return page([const Text('No child is linked to this number.')]);
    return page([
      KidPicker(),
      h('Fees - ${k.name}'),
      const Text('Monthly fee: Rs. 200. A month is Complete when fully paid.'),
      const SizedBox(height: 6),
      ...st.feeMonths(k).map((m) => Card(
            child: ListTile(
              leading: Icon(st.isPaid(k.id, m) ? Icons.check_circle : Icons.pending, color: st.isPaid(k.id, m) ? Colors.green : Colors.orange),
              title: Text(m),
              subtitle: Text(st.isPaid(k.id, m) ? 'Paid - month complete' : 'Due Rs. 200 by the 10th'),
            ),
          )),
    ]);
  }
}

class KidCourseProgress extends StatelessWidget {
  const KidCourseProgress({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final k = st.currentKid();
    if (k == null) return page([const Text('No child is linked to this number.')]);
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 0), child: KidPicker()),
      Expanded(child: CoursesTabBody(s: k)),
    ]);
  }
}

class KidDocs extends StatelessWidget {
  const KidDocs({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    return page([
      h('Student documents', icon: Icons.badge),
      ...st.kids().map((k) => Card(
            child: ListTile(
              leading: const Icon(Icons.badge),
              title: Text(k.name),
              subtitle: Text('Aadhaar card uploaded: ${k.aadhaar ? 'Yes' : 'No'} - Address: ${k.address.isEmpty ? 'not given (optional)' : k.address}'),
              trailing: TextButton(onPressed: () => toast(context, 'Demo: file picker opens here'), child: const Text('Replace')),
            ),
          )),
    ]);
  }
}

// ---------------- complaints ----------------
class ComplaintsView extends StatefulWidget {
  const ComplaintsView({super.key});
  @override
  State<ComplaintsView> createState() => _ComplaintsViewState();
}

class _ComplaintsViewState extends State<ComplaintsView> {
  final subject = TextEditingController();
  final text = TextEditingController();
  String to = 'teacher';
  static const int kComplaintMaxLen = 500;

  @override
  void initState() {
    super.initState();
    // Section 12: live "0/500" counter below the message field.
    text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    subject.dispose();
    text.dispose();
    super.dispose();
  }

  Widget card(Complaint c, bool inbox) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(child: Text(c.subject, style: const TextStyle(fontWeight: FontWeight.bold))),
            Chip(label: Text(c.status)),
          ]),
          Text('CMP-${c.id.toString().padLeft(4, '0')} - to ${c.to} - from ${c.by}'),
          Text(c.text),
          ...c.replies.map((r) => Text('- $r', style: const TextStyle(color: Colors.black54))),
          if (inbox)
            Row(children: [
              TextButton(
                onPressed: () async {
                  final r = await askText(context, 'Reply');
                  if (r != null) await replyRemote(c, r);
                },
                child: const Text('Reply'),
              ),
              TextButton(onPressed: () => resolveRemote(c), child: const Text('Resolve')),
            ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    if (u.role == 'parent') {
      final mine = st.complaints.where((c) => c.phone == u.phone).toList();
      return page([
        h('New complaint', icon: Icons.report_problem),
        DropdownButtonFormField<String>(
          value: to,
          decoration: const InputDecoration(labelText: 'Send to', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'teacher', child: Text('Teacher')),
            DropdownMenuItem(value: 'admin', child: Text('Maktab Admin')),
            DropdownMenuItem(value: 'super', child: Text('Super Admin')),
          ],
          onChanged: (v) => setState(() => to = v ?? to),
        ),
        const SizedBox(height: 8),
        field(subject, 'Subject'),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: text,
            maxLines: 3,
            maxLength: kComplaintMaxLen,
            decoration: const InputDecoration(
              labelText: 'Please describe your complaint briefly (maximum 500 characters).',
              border: OutlineInputBorder(),
              counterText: null, // use the built-in "n/500" counter maxLength already shows
            ),
          ),
        ),
        ElevatedButton(
          onPressed: () async {
            if (subject.text.trim().isEmpty) {
              toast(context, 'Enter a subject');
              return;
            }
            if (text.text.trim().isEmpty) {
              toast(context, 'Enter your complaint details (it cannot be blank)');
              return;
            }
            if (text.text.length > kComplaintMaxLen) {
              toast(context, 'Your message is over the $kComplaintMaxLen character limit - please shorten it.');
              return;
            }
            final e = await addComplaintRemote(to, subject.text.trim(), text.text.trim());
            if (e != null) {
              toast(context, e);
              return;
            }
            subject.clear();
            text.clear();
            toast(context, 'Complaint submitted');
          },
          child: const Text('Submit'),
        ),
        h('My complaints'),
        if (mine.isEmpty) const Text('None yet.'),
        ...mine.map((c) => card(c, false)),
      ]);
    }
    final inbox = st.complaints.where((c) => c.to == u.role).toList();
    return page([
      h('Complaints inbox', icon: Icons.report_problem),
      const Text('You see only complaints addressed to your level. A complaint about a teacher sent to the Admin is hidden from the teacher.'),
      if (inbox.isEmpty) const Text('Nothing here.'),
      ...inbox.map((c) => card(c, true)),
    ]);
  }
}

// A continuously spinning logo used in place of a plain
// CircularProgressIndicator on the dashboard's loading screen. Runs its
// own AnimationController rather than depending on st, so it keeps
// turning smoothly regardless of how often the surrounding screen
// rebuilds while data is still loading.
class _SpinningLogo extends StatefulWidget {
  const _SpinningLogo();
  @override
  State<_SpinningLogo> createState() => _SpinningLogoState();
}

class _SpinningLogoState extends State<_SpinningLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logo = Image.asset('assets/logo.png', height: 96);
    // A plain RotationTransition spins flat in the screen's own plane, so
    // it goes upside-down at the halfway point - a coin spin instead
    // turns around the vertical (Y) axis, narrowing to an edge-on sliver
    // at 90/270 degrees and never flipping upside-down. perspective (the
    // 0.0015 entry) is what gives that narrowing its 3D look instead of
    // just squashing flat.
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final m = Matrix4.identity()
          ..setEntry(3, 2, 0.0015)
          ..rotateY(_c.value * 2 * pi);
        return Transform(alignment: Alignment.center, transform: m, child: child);
      },
      child: logo,
    );
  }
}

// ---------------- staff ----------------
class StaffHome extends StatefulWidget {
  const StaffHome({super.key});
  @override
  State<StaffHome> createState() => _StaffHomeState();
}

class _StaffHomeState extends State<StaffHome> {
  final title = TextEditingController();
  final msg = TextEditingController();
  String priority = 'Important';

  @override
  Widget build(BuildContext context) =>
      // Own AnimatedBuilder, same reason as StudentAttendanceMark/MyDayView:
      // without it this screen (reached via a const widget factory in the
      // bottom-tab list) doesn't reliably rebuild when st changes - in
      // particular when loadMasterData's dataLoaded flag flips true just
      // after login, which is exactly the moment this screen needs to
      // swap its loading placeholder for the real counts.
      AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final u = st.user!;
    // Real counts aren't in yet (first paint right after login, before
    // loadMasterData resolves) - showing tiles now would read whatever
    // placeholder/demo data st started with, which can legitimately say
    // "0" for a Maktab that in fact has students once the real data
    // arrives a moment later.
    if (!st.dataLoaded) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const _SpinningLogo(),
            const SizedBox(height: 20),
            const Text('Loading your dashboard...'),
          ]),
        ),
      );
    }
    final open = st.complaints.where((c) => c.to == u.role && c.status != 'Resolved').length;
    final pendingLeave = st.leaves.where((l) => l.status == 'Pending').length;
    if (u.role == 'super') {
      return page([
        banner(),
        grid([
          tile('Search', 'Phone, name, Maktab', icon: Icons.search, onTap: () => pushPage(context, 'Search', const GlobalSearchView())),
          tile('Master Data', '${st.madrasas.length} Makatib', icon: Icons.storage, onTap: () => pushPage(context, 'Master Data', const MasterDataDashboard())),
          // Browse by Maktab, with each student's live attendance/syllabus
          // status (StudentDetail's Status/Syllabus/Attendance tabs) -
          // distinct from the plain "Students" tile below, which is the
          // admit/edit/promote form, not a status overview.
          tile('Students by Maktab', '${st.students.length} total', icon: Icons.account_tree, onTap: () => pushPage(context, 'Students by Maktab', const SuperMakatibOverview())),
          tile('Students', '${st.students.length}', icon: Icons.groups, onTap: () => pushPage(context, 'Students', const StudentsView())),
          tile('Teachers', '${st.teacherAccounts.where((t) => !t.pending).length}', icon: Icons.co_present, onTap: () => pushPage(context, 'Teachers & Leave', const TeachersView())),
          tile('Average attendance', '${st.avgAttAll()}%', icon: Icons.event_available),
          tile('Average syllabus', '${st.avgSylAll()}%', icon: Icons.menu_book),
          tile('Leave requests', '$pendingLeave pending', icon: Icons.event_busy, onTap: () => pushPage(context, 'Teachers & Leave', const TeachersView())),
          tile('Complaints open', '$open', icon: Icons.report_problem, onTap: () => pushPage(context, 'Complaints', const ComplaintsView())),
          tile('Committee members', '${st.committeeAccounts.where((m) => !m.pending).length}', icon: Icons.diversity_3, onTap: () => pushPage(context, 'Committee', const CommitteeAdmin())),
          tile('Monthly Members', '${st.monthlyMembers.where((m) => m.isActive).length} active', icon: Icons.volunteer_activism, onTap: () => pushPage(context, 'Monthly Members', const MonthlyMembersDashboard())),
          tile(
            'Notifications',
            st.unreadAdminNotifCount > 0 ? '${st.unreadAdminNotifCount} unread' : 'All caught up',
            icon: Icons.notifications,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminNotificationsScreen())),
          ),
        ]),
        h('Post common announcement (all Makatib, all roles)'),
        field(title, 'Title'),
        field(msg, 'Message', lines: 2),
        DropdownButtonFormField<String>(
          value: priority,
          decoration: const InputDecoration(labelText: 'Priority', border: OutlineInputBorder()),
          items: const [DropdownMenuItem(value: 'Normal', child: Text('Normal')), DropdownMenuItem(value: 'Important', child: Text('Important'))],
          onChanged: (v) => setState(() => priority = v ?? priority),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: () async {
            if (title.text.trim().isEmpty) {
              toast(context, 'Enter a title');
              return;
            }
            final e = await postAnnouncementRemote(title.text, msg.text, priority);
            if (e != null) {
              toast(context, e);
              return;
            }
            title.clear();
            msg.clear();
            toast(context, 'Announcement posted. It now shows on every dashboard.');
          },
          child: const Text('Post announcement'),
        ),
        h('Active announcements'),
        ...st.announcements.where((a) => a.active).map((a) => Card(child: ListTile(title: Text(a.title), subtitle: Text(a.msg), trailing: TextButton(onPressed: () async {
                final ok = await confirmDialog(context, 'Withdraw this announcement?', 'It will stop showing on every dashboard. This cannot be undone - posting it again would be a new announcement.', confirmLabel: 'Withdraw');
                if (!ok) return;
                if (!context.mounted) return;
                await withdrawAnnouncementRemote(a);
              }, child: const Text('Withdraw'))))),
      ]);
    }
    if (u.role == 'admin') {
      final present = st.teacherAtt.values.where((v) => v.startsWith('Present')).length;
      final onLeave = st.teacherAtt.values.where((v) => v == 'On leave').length;
      // Was hardcoded to "Hanfi" only - now scoped to whichever madrasa(s)
      // this admin actually manages (u.branches, loaded for real from
      // public.user_madrasa_scope at login).
      final myStudentsActive = st.students.where((s) => u.branches.contains(s.madrasa) && s.status == 'Active').toList();
      // Was hardcoded to 'Sep' - now whichever month it actually is, so
      // this tile still means something after September.
      final curMonth = '${AppState.kMonthAbbrevs[pd(kToday).month - 1]} ${pd(kToday).year}';
      return page([
        banner(),
        grid([
          tile('Search', 'Phone, name, Maktab', icon: Icons.search, onTap: () => pushPage(context, 'Search', const GlobalSearchView())),
          tile('Master Data', '${st.madrasas.length} Makatib', icon: Icons.storage, onTap: () => pushPage(context, 'Master Data', const MasterDataDashboard())),
          tile('Students', '${myStudentsActive.length}', icon: Icons.groups, onTap: () => pushPage(context, 'Students', const StudentsView())),
          tile('Teachers today', '$present present, $onLeave on leave', icon: Icons.co_present, onTap: () => pushPage(context, 'Teachers & Leave', const TeachersView())),
          tile('Pending registrations', '${st.pending.length}', icon: Icons.how_to_reg, onTap: () => pushPage(context, 'Pending Registrations', const ApprovalsView())),
          tile('Leave requests', '$pendingLeave pending', icon: Icons.event_busy, onTap: () => pushPage(context, 'Teachers & Leave', const TeachersView())),
          tile('Fees $curMonth', '${myStudentsActive.where((s) => st.isPaid(s.id, curMonth)).length} of ${myStudentsActive.where((s) => st.feeMonths(s).contains(curMonth)).length} complete', icon: Icons.payments, onTap: () => pushPage(context, 'Fees', const FeesAdmin())),
          tile('Complaints open', '$open', icon: Icons.report_problem, onTap: () => pushPage(context, 'Complaints', const ComplaintsView())),
        ]),
        h('Ready to promote'),
        Text('${st.students.where((s) => st.canCompleteClass(s)).length} student(s)'),
      ]);
    }
    // teacher
    final u2 = u;
    return page([
      banner(),
      if (u2.teachMadrasas.length > 1)
        Card(
          color: const Color(0xFFEEF4E8),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Text('You teach in ${u2.teachMadrasas.join(' and ')}. Currently viewing: ${st.teacherMadrasa}. Use the switcher at the top right, or open "My Day".', style: const TextStyle(fontSize: 12.5)),
          ),
        ),
      grid([
        // 'My attendance' (the teacher's own attendance) already lives in
        // the burger menu as 'My Attendance & Leave' - this tile is a
        // quicker path to what teachers actually need from the dashboard
        // day to day: marking their students' attendance for today.
        tile(
          'Student Attendance',
          '${st.myStudents().where((s) => s.status == 'Active').length} student(s)',
          icon: Icons.event_available,
          onTap: () => pushPage(context, 'Mark attendance', const StudentAttendanceMark()),
        ),
        tile(
          'Students (${st.teacherMadrasa})',
          '${st.inBranch(st.teacherMadrasa).where((s) => s.status == 'Active').length}',
          icon: Icons.groups,
          onTap: () => pushPage(context, 'Students & Promotion', const StudentsView()),
        ),
        tile('Ready to promote', '${st.students.where((s) => st.canCompleteClass(s)).length}', icon: Icons.trending_up, onTap: () => pushPage(context, 'Students & Promotion', const StudentsView())),
        tile('Complaints open', '$open', icon: Icons.report_problem, onTap: () => pushPage(context, 'Complaints', const ComplaintsView())),
      ]),
      const Text('Use the menu (top left) to open Attendance, Syllabus and more.'),
    ]);
  }
}

class MyDayView extends StatelessWidget {
  const MyDayView({super.key});
  @override
  Widget build(BuildContext context) =>
      // Own AnimatedBuilder: a const StatelessWidget returned from a bottom
      // tab is the same canonical widget instance on every rebuild, so
      // Flutter's element diffing skips calling build() again unless the
      // widget listens for changes itself (same fix already applied to
      // TeacherSelf/StudentAttendanceMark for the same reason).
      AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final entries = st.myDay();
    return page([
      h("My day - across all madrasas"),
      const Text('Real Maktab/class assignments, grouped by Maktab. Tap a row to switch to that Maktab.'),
      const SizedBox(height: 8),
      if (entries.isEmpty) const Text('No classes assigned yet.'),
      ...entries.map((e) => Card(
            child: ListTile(
              leading: CircleAvatar(backgroundColor: const Color(0xFFEEF4E8), child: Text(e.madrasa.isNotEmpty ? e.madrasa[0].toUpperCase() : '?', style: const TextStyle(color: kGreen, fontWeight: FontWeight.bold, fontSize: 13))),
              title: Text(e.madrasa),
              subtitle: Text(st.className(e.cls)),
              trailing: e.madrasa == st.teacherMadrasa ? const Chip(label: Text('Current')) : TextButton(onPressed: () => st.setTeacherMadrasa(e.madrasa), child: const Text('Switch here')),
            ),
          )),
    ]);
  }
}

class TeacherSelf extends StatefulWidget {
  const TeacherSelf({super.key});
  @override
  State<TeacherSelf> createState() => _TeacherSelfState();
}

class _TeacherSelfState extends State<TeacherSelf> {
  final from = TextEditingController(text: '2026-09-24');
  final to = TextEditingController(text: '2026-09-25');
  final reason = TextEditingController();
  String type = 'Sick';
  String? leaveMadrasa;
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    // AnimatedBuilder: this screen is reached via pushPage (its own route,
    // not a bottom tab), so it needs its own listener to redraw when
    // leaves/attendance change from realtime or this screen's own save -
    // the shell's top-level AnimatedBuilder only covers tab-hosted screens.
    return AnimatedBuilder(animation: st, builder: (context, _) => _body(context));
  }

  Widget _body(BuildContext context) {
    final u = st.user!;
    final mine = st.leaves.where((l) => l.teacher == u.name).toList();
    // Section 7: a teacher at more than one Maktab picks which one the
    // leave is for; a single-Maktab teacher has nothing to pick.
    leaveMadrasa ??= u.teachMadrasas.isNotEmpty ? u.teachMadrasas.first : st.teacherMadrasa;
    return page([
      h('My attendance - ${nice(kToday)}', icon: Icons.event_available),
      const Text('This is one record for the teacher, even when teaching at more than one Maktab.', style: TextStyle(fontSize: 12, color: Colors.black54)),
      Card(child: ListTile(title: Text(st.teacherAtt[u.name] ?? 'Not marked'), subtitle: const Text('Tap Present or Absent for today'))),
      Row(children: [
        Expanded(child: ElevatedButton(onPressed: () => markSelfRemote('Present'), child: const Text('Present'))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton(onPressed: () => markSelfRemote('Absent'), child: const Text('Absent'))),
      ]),
      h('Apply for leave'),
      if (u.teachMadrasas.length > 1) ...[
        DropdownButtonFormField<String>(
          value: leaveMadrasa,
          decoration: const InputDecoration(labelText: 'Which Maktab is this leave for?', border: OutlineInputBorder()),
          items: [for (final m in u.teachMadrasas) DropdownMenuItem<String>(value: m, child: Text(m))],
          onChanged: (v) => setState(() => leaveMadrasa = v),
        ),
        const SizedBox(height: 8),
      ],
      DropdownButtonFormField<String>(
        value: type,
        decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
        items: [for (final t in ['Casual', 'Sick', 'Other']) DropdownMenuItem<String>(value: t, child: Text(t))],
        onChanged: (v) => setState(() => type = v ?? type),
      ),
      const SizedBox(height: 8),
      field(from, 'From (yyyy-mm-dd)'),
      field(to, 'To (yyyy-mm-dd)'),
      field(reason, 'Reason (required)', lines: 2),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                final e = await applyLeaveRemote(type, leaveMadrasa ?? st.teacherMadrasa, from.text.trim(), to.text.trim(), reason.text);
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Leave request sent for $leaveMadrasa. Status: Pending');
                if (e == null) reason.clear();
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Send request'),
      ),
      h('My leaves'),
      if (mine.isEmpty) const Text('None yet.'),
      ...mine.map((l) => Card(
            child: ListTile(
              title: Text('${l.type}: ${nice(l.from)} to ${nice(l.to)}${l.madrasa.isEmpty ? '' : ' - ${l.madrasa}'}'),
              subtitle: Text('${l.reason}${l.status == 'Pending' ? '' : '\n${l.status} by ${l.by}: ${l.remark}'}'),
              trailing: Chip(label: Text(l.status)),
            ),
          )),
    ]);
  }
}

// ---------------- Section 3.2.5: bulk student import (CSV) ----------------
// One target Maktab is picked up front (scoped to the admin's own
// authorized Makatib, same list as the admission form), so there's no
// column asking which madrasa each row goes into and therefore no way to
// accidentally import into a Maktab this admin isn't authorized for.
class _ImportRow {
  final int rowNo;
  final String name;
  final String gender;
  final String dob;
  final String fatherName;
  final String parentPhone;
  final String studentPhone;
  final String address;
  final int cls;
  String? error; // non-null => this row is skipped
  bool duplicate = false;
  _ImportRow(this.rowNo, this.name, this.gender, this.dob, this.fatherName, this.parentPhone, this.studentPhone, this.address, this.cls);
}

const String kImportTemplateCsv = 'name,gender,class,dob,father_name,parent_phone,student_phone,address\n'
    'Ahmed Khan,Male,1,2017-05-12,Imran Khan,9800000111,,House 12 Station Road\n';

class BulkImportStudents extends StatefulWidget {
  final List<String> pickableMadrasas;
  const BulkImportStudents({super.key, required this.pickableMadrasas});
  @override
  State<BulkImportStudents> createState() => _BulkImportStudentsState();
}

class _BulkImportStudentsState extends State<BulkImportStudents> {
  String? madrasa;
  String? fileName;
  List<_ImportRow> rows = [];
  String? parseError;
  bool importing = false;
  int done = 0;
  List<String> importErrors = [];

  @override
  void initState() {
    super.initState();
    madrasa = widget.pickableMadrasas.isNotEmpty ? widget.pickableMadrasas.first : null;
  }

  void _parse(String content) {
    setState(() {
      rows = [];
      parseError = null;
      importErrors = [];
      done = 0;
    });
    List<List<dynamic>> table;
    try {
      // Default options only - the exact named-parameter set has changed
      // across csv package major versions, and the defaults already do
      // what this needs: cells stay as strings (no automatic number/bool
      // parsing) and \n / \r\n line endings are both handled.
      table = const CsvToListConverter().convert(content.trim());
    } catch (_) {
      setState(() => parseError = 'Could not read this file as CSV. Make sure it was saved as plain CSV (not .xlsx).');
      return;
    }
    if (table.isEmpty) {
      setState(() => parseError = 'The file is empty.');
      return;
    }
    final header = table.first.map((h) => h.toString().trim().toLowerCase()).toList();
    const expected = ['name', 'gender', 'class', 'dob', 'father_name', 'parent_phone', 'student_phone', 'address'];
    final colIndex = {for (final c in expected) c: header.indexOf(c)};
    if (colIndex['name'] == -1 || colIndex['gender'] == -1 || colIndex['class'] == -1 || colIndex['parent_phone'] == -1) {
      setState(() => parseError = 'The header row must include at least: name, gender, class, parent_phone. Download the sample template below and use it as a starting point.');
      return;
    }
    String cell(List<dynamic> r, String col) {
      final i = colIndex[col]!;
      if (i == -1 || i >= r.length) return '';
      return r[i].toString().trim();
    }

    final parsed = <_ImportRow>[];
    for (var i = 1; i < table.length; i++) {
      final r = table[i];
      if (r.every((x) => x.toString().trim().isEmpty)) continue; // skip blank lines
      final clsText = cell(r, 'class');
      final cls = int.tryParse(clsText) ?? -1;
      final row = _ImportRow(
        i + 1, // 1-based, matches what a spreadsheet shows including header row
        cell(r, 'name'),
        cell(r, 'gender'),
        cell(r, 'dob'),
        cell(r, 'father_name'),
        digits(cell(r, 'parent_phone')),
        digits(cell(r, 'student_phone')),
        cell(r, 'address'),
        cls,
      );
      if (row.name.isEmpty) {
        row.error = 'Name is required';
      } else if (row.gender != 'Male' && row.gender != 'Female') {
        row.error = 'Gender must be exactly "Male" or "Female"';
      } else if (!st.classDefs.containsKey(row.cls)) {
        row.error = 'Unknown class "$clsText"';
      } else if (row.parentPhone.length != 10) {
        row.error = 'Parent mobile number must be 10 digits';
      } else {
        // Duplicate check: against existing active students, and against
        // earlier rows already queued in this same file.
        final dup = st.findActiveDuplicate(row.name, row.dob.isEmpty ? null : row.dob) != null ||
            parsed.any((p) => p.error == null && p.name.toLowerCase() == row.name.toLowerCase() && p.dob == row.dob && row.dob.isNotEmpty);
        row.duplicate = dup;
      }
      parsed.add(row);
    }
    setState(() => rows = parsed);
  }

  Future<void> _pickFile() async {
    // file_picker v12+ dropped FilePickerResult/PlatformFile.bytes in favor
    // of a plain List<PlatformFile> and an async readAsBytes() per file.
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (files.isEmpty) return;
    final f = files.first;
    Uint8List bytes;
    try {
      bytes = await f.readAsBytes();
    } catch (_) {
      setState(() => parseError = 'Could not read that file on this platform - try a different file picker or device.');
      return;
    }
    setState(() => fileName = f.name);
    _parse(utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _import(BuildContext context) async {
    final valid = rows.where((r) => r.error == null).toList();
    if (valid.isEmpty || madrasa == null) return;
    setState(() {
      importing = true;
      done = 0;
      importErrors = [];
    });
    for (final r in valid) {
      final e = await addStudentRemote(
        name: r.name,
        gender: r.gender,
        cls: r.cls,
        parentPhone: r.parentPhone,
        studentPhone: r.studentPhone,
        aadhaar: true, // bulk import: Aadhaar is uploaded/verified separately per Section 3.2, not blocked per-row here
        address: r.address,
        madrasa: madrasa!,
        dob: r.dob,
        fatherName: r.fatherName,
        confirmDuplicate: true, // already shown and accepted in the preview step
      );
      if (!mounted) return;
      if (e != null) {
        importErrors.add('Row ${r.rowNo} (${r.name}): $e');
      } else {
        done++;
      }
      setState(() {});
    }
    setState(() => importing = false);
  }

  @override
  Widget build(BuildContext context) {
    final valid = rows.where((r) => r.error == null).toList();
    final invalid = rows.where((r) => r.error != null).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Import students from CSV')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('1. Download the sample template, fill it in (keep the header row), then upload it below.', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.description),
          label: const Text('View / copy sample template'),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Sample template (CSV)'),
              content: SelectableText(kImportTemplateCsv),
              actions: [
                TextButton(
                  onPressed: () {
                    Clipboard.setData(const ClipboardData(text: kImportTemplateCsv));
                    toast(context, 'Copied. Paste into a new text file and save it with a .csv extension.');
                  },
                  child: const Text('Copy'),
                ),
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('2. Choose the Maktab these students belong to.', style: TextStyle(fontWeight: FontWeight.w600)),
        DropdownButtonFormField<String>(
          value: madrasa,
          decoration: const InputDecoration(labelText: 'Maktab *', border: OutlineInputBorder()),
          items: [for (final m in widget.pickableMadrasas) DropdownMenuItem<String>(value: m, child: Text(m))],
          onChanged: (v) => setState(() => madrasa = v),
        ),
        const SizedBox(height: 16),
        const Text('3. Upload your filled CSV file.', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ElevatedButton.icon(icon: const Icon(Icons.upload_file), label: Text(fileName ?? 'Choose CSV file'), onPressed: _pickFile),
        if (parseError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(parseError!, style: const TextStyle(color: Colors.red))),
        if (rows.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Preview: ${valid.length} ready to import, ${invalid.length} with errors, ${valid.where((r) => r.duplicate).length} possible duplicate(s) among those ready.', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...rows.map((r) => Card(
                color: r.error != null ? Colors.red.shade50 : (r.duplicate ? Colors.orange.shade50 : null),
                child: ListTile(
                  dense: true,
                  title: Text('Row ${r.rowNo}: ${r.name.isEmpty ? '(no name)' : r.name}'),
                  subtitle: Text(r.error ?? (r.duplicate ? 'Possible duplicate - a matching active student (same name + DOB) already exists. Will still be imported.' : 'Class ${r.cls} - parent ${r.parentPhone}')),
                ),
              )),
          const SizedBox(height: 12),
          if (importing) const LinearProgressIndicator(),
          if (importing) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('Imported $done of ${valid.length}...')),
          if (!importing)
            ElevatedButton(
              onPressed: valid.isEmpty || madrasa == null ? null : () => _import(context),
              child: Text('Import ${valid.length} student(s) into ${madrasa ?? ''}'),
            ),
          if (!importing && importErrors.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Import finished: $done succeeded, ${importErrors.length} failed.', style: const TextStyle(fontWeight: FontWeight.bold)),
            ...importErrors.map((e) => Text(e, style: const TextStyle(color: Colors.red, fontSize: 12.5))),
          ] else if (!importing && done > 0) ...[
            const SizedBox(height: 12),
            Text('Import finished: all $done student(s) saved successfully.', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
          ],
        ],
      ]),
    );
  }
}

const String kBatchIncompleteMessage =
    'Batch submission cannot be completed. Please submit attendance for all remaining students before leaving the class.';

class StudentAttendanceMark extends StatefulWidget {
  const StudentAttendanceMark({super.key});
  @override
  State<StudentAttendanceMark> createState() => _StudentAttendanceMarkState();
}

class _StudentAttendanceMarkState extends State<StudentAttendanceMark> {
  // Session keys (batch||cls) for which the Teacher has already attempted
  // Verify and Submit while students were still Pending - only these get
  // the red "unmarked" highlight, so a class the Teacher hasn't touched
  // yet doesn't open already covered in red.
  final Set<String> _verifyAttempted = {};
  final Set<String> _busySessions = {};
  // Local-only Present/Absent choice a Teacher has tapped for a student but
  // not yet submitted - selecting never saves anything by itself (per the
  // workflow: select, optionally record syllabus progress, then press that
  // student's own Submit). Cleared for a student once it actually submits
  // (st.todayAtt then becomes the source of truth for them).
  final Map<int, String> _selected = {};
  final Set<int> _submittingIds = {};
  // Which date this screen is marking/editing. Defaults to today; a Teacher
  // can switch to Yesterday or 2 days ago to review or correct recent
  // attendance (per-student edits only - no separate "correction workflow"
  // dialog, just the same Present/Absent/Submit controls reopened for that
  // date). Dates beyond this 3-day window are never offered.
  String _selectedDate = kToday;
  bool _loadingDate = false;
  // Students whose individual Submit is being reopened for editing on a
  // past (already-submitted, not-yet-finalized) date.
  final Set<int> _editing = {};

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Future<void> _switchDate(String date) async {
    if (date == _selectedDate) return;
    setState(() {
      _selectedDate = date;
      _selected.clear();
      _editing.clear();
      _verifyAttempted.clear();
    });
    if (date != kToday) {
      setState(() => _loadingDate = true);
      await loadAttendanceForDate(date);
      if (mounted) setState(() => _loadingDate = false);
    }
  }

  Widget _dateSelector(BuildContext context) {
    final options = [
      (kToday, 'Today'),
      (addDays(kToday, -1), 'Yesterday'),
      (addDays(kToday, -2), '2 days ago'),
    ];
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final o in options)
        ChoiceChip(
          label: Text(o.$2),
          selected: _selectedDate == o.$1,
          onSelected: (_) => _switchDate(o.$1),
        ),
      if (_loadingDate) const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))),
    ]);
  }

  Widget _body(BuildContext context) {
    // Deactivated students never appear here, so they can't be marked and never get an alert.
    final list = st.myStudents().where((s) => s.status == 'Active').toList();
    // A Maktab class may run several sessions a day (different batches)
    // and a Teacher may be assigned more than one class, so attendance is
    // opened per Maktab + class + batch - exactly the identity
    // submit_attendance_session itself validates against - rather than one
    // undifferentiated roster.
    final groups = <String, List<Student>>{};
    for (final s in list) {
      final b = kBatches.contains(s.batch) ? s.batch : 'Morning';
      (groups['$b||${s.cls}'] ??= []).add(s);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        final pa = a.split('||');
        final pb = b.split('||');
        final bi = kBatches.indexOf(pa[0]).compareTo(kBatches.indexOf(pb[0]));
        if (bi != 0) return bi;
        return int.parse(pa[1]).compareTo(int.parse(pb[1]));
      });

    Widget progressRowFor(BuildContext context, Student s) {
      final cd = st.classDefs[s.cls]!;
      // Lets the teacher log today's syllabus page/chapter right here while
      // marking attendance, instead of having to leave this screen and find
      // the student again in the separate Syllabus tab. Reuses the same
      // markPageDialog/tickChapterDialog already used there, so progress
      // logged here shows up identically in Syllabus.
      if (cd.pageBased) {
        final cur = st.currentPageNo(s);
        final pos = cur == null ? null : st.paraPosition(cd, cur);
        final label = cur == null ? '' : (pos != null ? 'Para ${pos.paraNo}, Page ${pos.pageInPara} of ${pos.paraPageCount}' : 'Page $cur of ${cd.totalPages}');
        return cur == null
            ? const Text('All pages complete', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.green))
            : Row(children: [
                Text(label, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.black87)),
                IconButton(
                  icon: const Icon(Icons.add_circle, size: 24, color: kGreen),
                  tooltip: 'Mark page $cur complete',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => markPageDialog(context, s, cur),
                ),
              ]);
      }
      final plan = st.chapterPlan(s);
      var nextIdx = -1;
      for (var i = 0; i < plan.length; i++) {
        if (plan[i].done == null) {
          nextIdx = i;
          break;
        }
      }
      return nextIdx == -1
          ? const Text('All chapters complete', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.green))
          : Row(children: [
              Flexible(child: Text('Next: ${plan[nextIdx].title}', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.black87), overflow: TextOverflow.ellipsis)),
              IconButton(
                icon: const Icon(Icons.add_circle, size: 24, color: kGreen),
                tooltip: 'Mark chapter complete',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => tickChapterDialog(context, s, nextIdx),
              ),
            ]);
    }

    Widget studentTile(String sessionKey, Student s, String batch, int cls, {required bool sessionFinalized}) {
      final submitted = st.attForDate(_selectedDate)[s.id]; // 'P'/'A' only once actually Submitted; null until then.
      final isSubmitted = submitted != null;
      final isEditing = _editing.contains(s.id);
      // Controls reopen either because nothing has been submitted yet, or
      // because the Teacher tapped Edit on an already-submitted (but not
      // session-finalized) record for this recent date.
      final showControls = !sessionFinalized && (!isSubmitted || isEditing);
      final selected = _selected[s.id] ?? (isEditing ? submitted : null); // local choice, before Submit
      final isPending = !isSubmitted;
      final highlight = isPending && _verifyAttempted.contains(sessionKey);
      final submitting = _submittingIds.contains(s.id);

      Future<void> submitOne(String status) async {
        setState(() => _submittingIds.add(s.id));
        final err = await submitOneAttendanceRemote(s, status, madrasa: st.teacherMadrasa, cls: cls, date: _selectedDate);
        if (!mounted) return;
        setState(() {
          _submittingIds.remove(s.id);
          if (err == null) {
            _selected.remove(s.id);
            _editing.remove(s.id);
          }
        });
        if (err != null && context.mounted) toast(context, err);
      }

      Future<void> submitEditWhileFinalized(String status) async {
        setState(() => _submittingIds.add(s.id));
        final err = await editFinalizedStudentRemote(s, status, madrasa: st.teacherMadrasa, cls: cls, batch: batch, date: _selectedDate);
        if (!mounted) return;
        setState(() {
          _submittingIds.remove(s.id);
          if (err == null) {
            _selected.remove(s.id);
            _editing.remove(s.id);
          }
        });
        if (context.mounted) toast(context, err ?? 'Updated.');
      }

      Widget statusLine() {
        if (isSubmitted) {
          return Row(children: [
            Text('Submitted - ${submitted == 'P' ? 'Present' : 'Absent'}', style: TextStyle(fontWeight: FontWeight.bold, color: submitted == 'P' ? Colors.green : Colors.red)),
            if (!sessionFinalized && _selectedDate != kToday && !isEditing) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _editing.add(s.id)),
                child: const Text('Edit'),
              ),
            ],
          ]);
        }
        return Text('Pending / Not Yet Marked', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange.shade800));
      }

      Widget controls() {
        if (!showControls) return const SizedBox.shrink();
        return Row(mainAxisSize: MainAxisSize.min, children: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(backgroundColor: selected == 'P' ? Colors.green : null, foregroundColor: selected == 'P' ? Colors.white : Colors.green),
            onPressed: submitting ? null : () => setState(() => _selected[s.id] = 'P'),
            child: const Text('Present'),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            style: OutlinedButton.styleFrom(backgroundColor: selected == 'A' ? Colors.red : null, foregroundColor: selected == 'A' ? Colors.white : Colors.red),
            onPressed: submitting ? null : () => setState(() => _selected[s.id] = 'A'),
            child: const Text('Absent'),
          ),
          const SizedBox(width: 6),
          ElevatedButton(
            onPressed: (selected == null || submitting) ? null : () => submitOne(selected),
            child: submitting ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Submit'),
          ),
          if (isEditing) ...[
            const SizedBox(width: 6),
            TextButton(onPressed: submitting ? null : () => setState(() => _editing.remove(s.id)), child: const Text('Cancel')),
          ],
        ]);
      }

      Widget finalizedEditControls() {
        // Editing a student within an already-finalized session for a recent
        // date: same Present/Absent choice, but saved via
        // editFinalizedStudentRemote instead of the per-student submit path.
        if (!sessionFinalized || !isEditing) return const SizedBox.shrink();
        return Row(mainAxisSize: MainAxisSize.min, children: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(backgroundColor: selected == 'P' ? Colors.green : null, foregroundColor: selected == 'P' ? Colors.white : Colors.green),
            onPressed: submitting ? null : () => setState(() => _selected[s.id] = 'P'),
            child: const Text('Present'),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            style: OutlinedButton.styleFrom(backgroundColor: selected == 'A' ? Colors.red : null, foregroundColor: selected == 'A' ? Colors.white : Colors.red),
            onPressed: submitting ? null : () => setState(() => _selected[s.id] = 'A'),
            child: const Text('Absent'),
          ),
          const SizedBox(width: 6),
          ElevatedButton(
            onPressed: (selected == null || submitting) ? null : () => submitEditWhileFinalized(selected),
            child: submitting ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save'),
          ),
          const SizedBox(width: 6),
          TextButton(onPressed: submitting ? null : () => setState(() => _editing.remove(s.id)), child: const Text('Cancel')),
        ]);
      }

      return Card(
        color: highlight ? const Color(0xFFFFE3E0) : null,
        shape: highlight ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Colors.red, width: 1.4)) : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
              if (highlight) const Icon(Icons.error, color: Colors.red, size: 18),
              if (sessionFinalized && isSubmitted && _selectedDate != kToday && !isEditing)
                TextButton(onPressed: () => setState(() => _editing.add(s.id)), child: const Text('Edit')),
            ]),
            Text(st.className(s.cls), style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
            statusLine(),
            progressRowFor(context, s),
            const SizedBox(height: 6),
            controls(),
            finalizedEditControls(),
          ]),
        ),
      );
    }

    Widget sessionBlock(String batch, int cls, List<Student> students) {
      final sessionKey = '$batch||$cls';
      final att = st.attForDate(_selectedDate);
      final present = students.where((s) => att[s.id] == 'P').toList();
      final absent = students.where((s) => att[s.id] == 'A').toList();
      // A student counts as Pending until THEY have been individually
      // Submitted - merely tapping Present/Absent (an unsaved local
      // selection) does not remove them from this count.
      final pending = students.where((s) => att[s.id] == null).toList();
      final existing = st.sessionFor(st.teacherMadrasa, cls, batch, _selectedDate);
      final finalized = existing != null;

      Future<void> markRemainingAbsent() async {
        if (pending.isEmpty) {
          toast(context, 'No Pending students in this class/batch.');
          return;
        }
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Mark Remaining Students Absent'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('These students are still Pending. Confirm to individually submit them as Absent (each one\'s parent is notified right away) - students already Submitted as Present are never changed.'),
                const SizedBox(height: 8),
                for (final s in pending) Text('- ${s.name}'),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
            ],
          ),
        );
        if (confirmed != true) return;
        // Re-read Pending right before applying, in case something changed
        // while the confirm dialog was open - never overwrites a student
        // who was already Submitted in the meantime.
        var n = 0;
        for (final s in pending) {
          if (st.attForDate(_selectedDate)[s.id] == null) {
            final err = await submitOneAttendanceRemote(s, 'A', madrasa: st.teacherMadrasa, cls: cls, date: _selectedDate);
            if (err == null) n++;
          }
        }
        if (context.mounted) toast(context, '$n student(s) submitted as Absent.');
      }

      Future<void> verifyAndSubmit() async {
        if (pending.isNotEmpty) {
          setState(() => _verifyAttempted.add(sessionKey));
          toast(context, kBatchIncompleteMessage);
          return;
        }
        if (finalized) {
          toast(context, 'This batch has already been finalized.');
          return;
        }
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Confirm Final Submission'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Total Expected Students: ${students.length}'),
              Text('Submitted Present: ${present.length}'),
              Text('Submitted Absent: ${absent.length}'),
              const Text('Pending: 0'),
              const SizedBox(height: 8),
              const Text('This confirms every student has already been individually submitted and finalizes the batch. It will not resend any notifications already sent.', style: TextStyle(fontSize: 12, color: Colors.black54)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm Submission')),
            ],
          ),
        );
        if (confirmed != true) return;

        setState(() => _busySessions.add(sessionKey));
        final res = await submitAttendanceSessionRemote(
          madrasa: st.teacherMadrasa,
          cls: cls,
          batch: batch,
          date: _selectedDate,
          present: present,
          absent: absent,
        );
        if (!mounted) return;
        setState(() {
          _busySessions.remove(sessionKey);
          _verifyAttempted.remove(sessionKey);
        });
        if (res.error != null) {
          toast(context, res.error!);
          return;
        }
        var msg = 'Batch finalized for $batch - ${st.className(cls)}.';
        if (res.notifiedCount > 0) msg += ' ${res.notifiedCount} absence alert(s) sent.';
        if (res.retryNeeded.isNotEmpty) msg += ' ${res.retryNeeded.length} notification(s) need a retry.';
        toast(context, msg);
        if (res.retryNeeded.isNotEmpty) {
          final retryList = res.retryNeeded;
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Retry failed notifications'),
              content: Text('${retryList.length} absence notification(s) did not go out. Retry now? (Already-sent ones will never be duplicated.)'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
                ElevatedButton(
                  onPressed: () async {
                    final n = await retryAbsenceNotificationsRemote(retryList, st.teacherMadrasa, _selectedDate);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) toast(context, '$n notification(s) sent.');
                  },
                  child: const Text('Retry now'),
                ),
              ],
            ),
          );
        }
      }

      final busy = _busySessions.contains(sessionKey);
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          h('$batch - ${st.className(cls)} (${students.length})'),
          if (pending.isNotEmpty && _verifyAttempted.contains(sessionKey))
            Card(
              color: const Color(0xFFFFE3E0),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(kBatchIncompleteMessage, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              ),
            ),
          if (finalized)
            Card(
              color: const Color(0xFFEEF4E8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Finalized${existing!.submittedByName != null ? ' by ${existing!.submittedByName}' : ''}${existing!.submittedAt != null ? ' on ${nice(fd(existing!.submittedAt!))}' : ''}. This batch is locked.',
                  style: const TextStyle(color: kGreen, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          Text('Submitted Present ${present.length} - Submitted Absent ${absent.length} - Pending ${pending.length} - Total ${students.length}', style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
          const SizedBox(height: 6),
          ...students.map((s) => studentTile(sessionKey, s, batch, cls, sessionFinalized: finalized)),
          const SizedBox(height: 4),
          if (!finalized)
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.playlist_remove),
                label: const Text('Mark Remaining Students Absent'),
                onPressed: busy ? null : markRemainingAbsent,
              ),
              ElevatedButton(
                onPressed: busy ? null : verifyAndSubmit,
                child: busy
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Verify and Submit'),
              ),
            ]),
        ]),
      );
    }

    return page([
      h('Mark attendance - ${st.teacherMadrasa} - ${nice(_selectedDate)}', icon: Icons.event_available),
      const Text(
        'Select Present or Absent for a student, then press that student\'s own Submit to save it - an absent student\'s parent is notified right away. A student stays Pending until Submitted. Once every expected student is Submitted, use Verify and Submit to finalize the batch.',
        style: TextStyle(color: Colors.black54, fontSize: 12.5),
      ),
      const SizedBox(height: 8),
      _dateSelector(context),
      if (_selectedDate != kToday)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Reviewing a past date. Already-Submitted students can be edited here; this does not create a separate correction workflow - it just resubmits with the corrected status.',
            style: TextStyle(color: Colors.black54, fontSize: 12.5),
          ),
        ),
      const SizedBox(height: 8),
      if (_selectedDate == kToday)
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.event_busy),
              label: const Text('Record Event / Holiday for today'),
              onPressed: () => addEventDialog(context, st.teacherMadrasa, kToday),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.history),
            label: const Text('History'),
            onPressed: () => pushPage(context, 'Event / Holiday history', const EventHistoryView()),
          ),
        ]),
      const SizedBox(height: 8),
      for (final b in kBatches)
        if (keys.any((k) => k.startsWith('$b||'))) ...[
          () {
            final blocking = st.blockingEventFor(st.teacherMadrasa, _selectedDate, b);
            if (blocking != null) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  h('$b batch'),
                  Card(
                    color: blocking.type == 'holiday' ? const Color(0xFFFFE3E0) : const Color(0xFFFFF3CF),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${blocking.type == 'holiday' ? 'Holiday' : 'Event'}: ${blocking.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        if (blocking.startTime != null || blocking.endTime != null) Text('${blocking.startTime ?? ''} - ${blocking.endTime ?? ''}'),
                        if (blocking.description.isNotEmpty) Text(blocking.description),
                        const SizedBox(height: 6),
                        const Text(
                          'Normal Present/Absent attendance cannot be submitted for this batch today. Students are left as Not Recorded, not marked Absent.',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ]),
                    ),
                  ),
                ]),
              );
            }
            final clsKeys = keys.where((k) => k.startsWith('$b||')).toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final k in clsKeys) sessionBlock(b, int.parse(k.split('||')[1]), groups[k]!),
            ]);
          }(),
        ],
    ]);
  }
}

// Create an Event/Holiday for a Maktab+date, optionally scoped to one
// batch (leave unset for "whole day", which blocks every session).
Future<void> addEventDialog(BuildContext c, String madrasa, String initialDate) async {
  final nameCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  final startCtrl = TextEditingController();
  final endCtrl = TextEditingController();
  String type = 'holiday';
  String? batch; // null = whole day
  String date = initialDate;
  await showDialog<void>(
    context: c,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: const Text('Record Event / Holiday'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Event name')),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: type,
              decoration: const InputDecoration(labelText: 'Type'),
              items: const [
                DropdownMenuItem(value: 'holiday', child: Text('Holiday')),
                DropdownMenuItem(value: 'event', child: Text('Event')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged: (v) => setD(() => type = v ?? type),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(context: ctx, initialDate: pd(date), firstDate: DateTime(2020, 1, 1), lastDate: DateTime(2035, 12, 31));
                if (picked != null) setD(() => date = fd(picked));
              },
              child: AbsorbPointer(child: TextField(controller: TextEditingController(text: nice(date)), decoration: const InputDecoration(labelText: 'Date (tap to pick)'))),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              value: batch,
              decoration: const InputDecoration(labelText: 'Affected session (blank = whole day)'),
              items: [const DropdownMenuItem<String?>(value: null, child: Text('Whole day (all batches)')), for (final b in kBatches) DropdownMenuItem<String?>(value: b, child: Text(b))],
              onChanged: (v) => setD(() => batch = v),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: startCtrl, decoration: const InputDecoration(labelText: 'Start time (optional, HH:mm)'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: endCtrl, decoration: const InputDecoration(labelText: 'End time (optional, HH:mm)'))),
            ]),
            const SizedBox(height: 8),
            TextField(controller: descCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Description (optional)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final e = await addEventRemote(
                madrasa,
                nameCtrl.text,
                type,
                date,
                startTime: startCtrl.text.trim().isEmpty ? null : startCtrl.text.trim(),
                endTime: endCtrl.text.trim().isEmpty ? null : endCtrl.text.trim(),
                batch: batch,
                description: descCtrl.text,
              );
              if (ctx.mounted) Navigator.pop(ctx);
              if (e != null && c.mounted) toast(c, e);
              if (e == null && c.mounted) toast(c, 'Saved.');
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

class EventHistoryView extends StatelessWidget {
  const EventHistoryView({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final u = st.user!;
    final madrasa = u.role == 'teacher' ? st.teacherMadrasa : null;
    final list = madrasa != null ? st.eventsFor(madrasa) : [for (final m in st.activeMadrasaNames) ...st.eventsFor(m)]..sort((a, b) => b.date.compareTo(a.date));
    final canCancel = u.role == 'teacher' || u.role == 'admin' || u.role == 'super';
    return page([
      h('Event / Holiday history', icon: Icons.history),
      if (list.isEmpty) const Text('No Events or Holidays recorded yet.'),
      ...list.map((e) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text('${nice(e.date)} - ${e.name}',
                        style: TextStyle(fontWeight: FontWeight.bold, decoration: e.cancelled ? TextDecoration.lineThrough : null), overflow: TextOverflow.ellipsis),
                  ),
                  Chip(label: Text(e.type == 'holiday' ? 'Holiday' : (e.type == 'event' ? 'Event' : 'Other')), backgroundColor: e.type == 'holiday' ? const Color(0xFFFFE3E0) : const Color(0xFFFFF3CF)),
                ]),
                Text('${e.madrasa} - ${e.batch ?? 'Whole day'}${e.createdByName != null && e.createdByName!.isNotEmpty ? ' - by ${e.createdByName}' : ''}', style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
                if (e.description.isNotEmpty) Text(e.description, style: const TextStyle(fontSize: 12.5)),
                if (e.cancelled) Text('Cancelled${e.cancelReason != null && e.cancelReason!.isNotEmpty ? ': ${e.cancelReason}' : ''}', style: const TextStyle(color: Colors.red, fontSize: 12.5)),
                if (!e.cancelled && canCancel)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () async {
                        final reason = await askText(context, 'Reason for cancelling (optional)');
                        if (reason == null) return;
                        final err = await cancelEventRemote(e, reason);
                        if (context.mounted && err != null) toast(context, err);
                      },
                      child: const Text('Cancel this Event/Holiday'),
                    ),
                  ),
              ]),
            ),
          )),
    ]);
  }
}

// ---------------- About Us Management (Super Admin) ----------------
// Edits the same public.about_us row the public/no-login "About Us"
// screen (guest_tools.dart) reads, as structured sections (title +
// paragraphs and/or bullets) rather than flat fields, matching the shape
// of the organization's actual existing content instead of flattening it.
class _EditSection {
  final TextEditingController title;
  final TextEditingController paras; // one paragraph per blank-line-separated block
  final TextEditingController bullets; // one bullet per line
  _EditSection({String title = '', String paras = '', String bullets = ''})
      : title = TextEditingController(text: title),
        paras = TextEditingController(text: paras),
        bullets = TextEditingController(text: bullets);
  AboutUsSection toSection() => AboutUsSection(
        title: title.text.trim(),
        paras: paras.text.split('\n\n').map((p) => p.trim()).where((p) => p.isNotEmpty).toList(),
        bullets: bullets.text.split('\n').map((b) => b.trim()).where((b) => b.isNotEmpty).toList(),
      );
}

class AboutUsManagementView extends StatefulWidget {
  const AboutUsManagementView({super.key});
  @override
  State<AboutUsManagementView> createState() => _AboutUsManagementViewState();
}

class _AboutUsManagementViewState extends State<AboutUsManagementView> {
  final heading = TextEditingController();
  final subheading = TextEditingController();
  final contact = TextEditingController();
  final List<_EditSection> sections = [];
  bool _initialized = false;
  bool busy = false;
  String err = '';

  void _loadFrom(AboutUsContent c) {
    heading.text = c.heading;
    subheading.text = c.subheading;
    contact.text = c.contactLines.join('\n');
    sections
      ..clear()
      ..addAll([for (final s in c.sections) _EditSection(title: s.title, paras: s.paras.join('\n\n'), bullets: s.bullets.join('\n'))]);
  }

  AboutUsContent _current() => AboutUsContent(
        heading: heading.text.trim(),
        subheading: subheading.text.trim(),
        sections: [for (final s in sections) s.toSection()],
        contactLines: contact.text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList(),
      );

  @override
  void initState() {
    super.initState();
    if (st.aboutUs == null) {
      loadAboutUsData().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized && st.aboutUs != null) {
      _loadFrom(st.aboutUs!);
      _initialized = true;
    }
    if (st.aboutUs == null) {
      return page([h('About Us Management', icon: Icons.info_outline), const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))]);
    }
    return page([
      h('About Us Management', icon: Icons.info_outline),
      const Text('Shown on the no-login "About Us" screen and in the app drawer. Only a Super Admin can edit this.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
      field(heading, 'Heading'),
      field(subheading, 'Subheading (optional)'),
      const SizedBox(height: 8),
      ...sections.asMap().entries.map((entry) {
        final i = entry.key;
        final s = entry.value;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              Row(children: [
                Expanded(child: Text('Section ${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold))),
                IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => setState(() => sections.removeAt(i))),
              ]),
              field(s.title, 'Section title'),
              field(s.paras, 'Paragraphs (separate paragraphs with a blank line)', lines: 4),
              field(s.bullets, 'Bullet points (one per line, optional)', lines: 3),
            ]),
          ),
        );
      }),
      OutlinedButton.icon(
        icon: const Icon(Icons.add),
        label: const Text('Add section'),
        onPressed: () => setState(() => sections.add(_EditSection())),
      ),
      const SizedBox(height: 10),
      field(contact, 'Contact / footer lines (one per line)', lines: 4),
      if (err.isNotEmpty) msgBox(err),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Preview')),
                  body: ListView(padding: const EdgeInsets.all(16), children: aboutUsBodyWidgets(_current())),
                ))),
            child: const Text('Preview'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: () {
              if (st.aboutUs != null) _loadFrom(st.aboutUs!);
              setState(() => err = '');
            },
            child: const Text('Cancel'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton(
            onPressed: busy
                ? null
                : () async {
                    if (heading.text.trim().isEmpty) {
                      setState(() => err = 'Heading is required.');
                      return;
                    }
                    setState(() {
                      busy = true;
                      err = '';
                    });
                    final e = await updateAboutUsRemote(_current());
                    if (!mounted) return;
                    setState(() => busy = false);
                    if (e != null) {
                      setState(() => err = e);
                    } else {
                      toast(context, 'About Us updated.');
                    }
                  },
            child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
          ),
        ),
      ]),
    ]);
  }
}

// ---------------- Notification Template Management (Super Admin) ----------------
class NotifTemplateListView extends StatelessWidget {
  const NotifTemplateListView({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final list = [...st.notifTemplates]..sort((a, b) => a.notifType.compareTo(b.notifType));
    return page([
      h('Notification Templates', icon: Icons.campaign),
      const Text(
        'Review, correct, and preview the message format for every notification the app sends, before it reaches parents, students, or teachers. Only a Super Admin can edit these.',
        style: TextStyle(color: Colors.black54, fontSize: 12.5),
      ),
      if (list.isEmpty) const Text('No templates found yet.'),
      ...list.map((t) => Card(
            child: ListTile(
              title: Text(t.name),
              subtitle: Text(
                '${t.notifType} - ${t.channel.toUpperCase()} - ${t.active ? 'Active' : 'Inactive'}'
                '${t.updatedAt != null ? ' - updated ${nice(fd(t.updatedAt!))}' : ''}'
                '${t.updatedByName != null && t.updatedByName!.isNotEmpty ? ' by ${t.updatedByName}' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => pushPage(context, t.name, NotifTemplateEditView(dbId: t.dbId!)),
            ),
          )),
    ]);
  }
}

class NotifTemplateEditView extends StatefulWidget {
  final String dbId;
  const NotifTemplateEditView({super.key, required this.dbId});
  @override
  State<NotifTemplateEditView> createState() => _NotifTemplateEditViewState();
}

class _NotifTemplateEditViewState extends State<NotifTemplateEditView> {
  final body = TextEditingController();
  bool _initialized = false;
  bool busy = false;
  String err = '';
  Map<String, String> sampleValues = {};

  NotifTemplate? get t {
    for (final x in st.notifTemplates) {
      if (x.dbId == widget.dbId) return x;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tpl = t;
    if (tpl == null) return page([const Text('Template not found.')]);
    if (!_initialized) {
      body.text = tpl.body;
      sampleValues = {for (final v in tpl.variables) v: ''};
      _initialized = true;
    }
    final preview = renderTemplate(body.text, sampleValues);
    return page([
      h(tpl.name, icon: Icons.campaign),
      Text('${tpl.notifType} - ${tpl.channel.toUpperCase()}', style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
      const SizedBox(height: 8),
      field(body, 'Message text', lines: 8),
      const SizedBox(height: 4),
      const Text('Supported variables - tap to insert at the end of the message:', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final v in tpl.variables)
            ActionChip(
              label: Text('{$v}'),
              onPressed: () => setState(() {
                body.text = '${body.text}{$v}';
              }),
            ),
        ],
      ),
      const SizedBox(height: 14),
      SwitchListTile(
        title: const Text('Active'),
        subtitle: Text(tpl.active ? 'This template is currently used when the notification is sent.' : 'Inactive - the app falls back to its built-in default wording.'),
        value: tpl.active,
        onChanged: (v) async {
          final e = await updateNotifTemplateRemote(tpl, active: v);
          if (context.mounted && e != null) toast(context, e);
        },
      ),
      const Divider(),
      h('Preview', icon: Icons.visibility),
      const Text('Enter sample values to see exactly what will be sent:', style: TextStyle(fontSize: 12.5, color: Colors.black54)),
      for (final v in tpl.variables)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: TextField(
            decoration: InputDecoration(labelText: v, isDense: true),
            onChanged: (val) => setState(() => sampleValues[v] = val),
          ),
        ),
      Card(
        color: const Color(0xFFEEF4E8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Rendered message', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(preview.text),
            if (preview.missing.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Missing value for: ${preview.missing.join(', ')}', style: const TextStyle(color: Colors.red, fontSize: 12.5)),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 4),
      const Text(
        'This is a preview only - nothing is sent from here. Saving a template never sends a real notification by itself; it only changes the wording used the next time that workflow actually runs.',
        style: TextStyle(fontSize: 11.5, color: Colors.black45, fontStyle: FontStyle.italic),
      ),
      const SizedBox(height: 14),
      if (err.isNotEmpty) msgBox(err),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => setState(() {
              body.text = tpl.body;
              err = '';
            }),
            child: const Text('Cancel'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: () async {
              final hist = await loadTemplateHistory(tpl);
              if (!context.mounted) return;
              if (hist.isEmpty) {
                toast(context, 'No earlier versions saved yet.');
                return;
              }
              showDialog<void>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Version history'),
                  content: SizedBox(
                    width: 360,
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final v in hist)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${fmtDateTime(v.changedAt.toIso8601String())}${v.changedByName != null && v.changedByName!.isNotEmpty ? ' - ${v.changedByName}' : ''}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
                              Text(v.body, style: const TextStyle(fontSize: 12.5)),
                            ]),
                          ),
                      ],
                    ),
                  ),
                  actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
                ),
              );
            },
            child: const Text('History'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton(
            onPressed: busy
                ? null
                : () async {
                    if (body.text.trim().isEmpty) {
                      setState(() => err = 'Message text cannot be empty.');
                      return;
                    }
                    setState(() {
                      busy = true;
                      err = '';
                    });
                    final e = await updateNotifTemplateRemote(tpl, body: body.text);
                    if (!mounted) return;
                    setState(() => busy = false);
                    if (e != null) {
                      setState(() => err = e);
                    } else {
                      toast(context, 'Template saved.');
                    }
                  },
            child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
          ),
        ),
      ]),
    ]);
  }
}

// Teacher's "Syllabus Progress" screen (requirement 1): the roster of
// students in the Teacher's own Maktab, each with their admission/
// identifier key, class, and overall syllabus completion - tapping one
// opens the same StudentDetail used from Students & Promotion, landing
// directly on its Syllabus tab (which already covers books/Para/chapters
// via the shared SyllabusBody, plus a separate Add-on Courses tab) rather
// than a second, disconnected progress view.
class TeacherSyllabus extends StatelessWidget {
  const TeacherSyllabus({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    // Deactivated students are left out - there is nothing to progress or
    // approve for a student no longer attending, same scope as every
    // other student-facing screen in the app.
    final list = st.myStudents().where((s) => s.status == 'Active').toList();
    return page([
      h('Syllabus Progress - ${st.teacherMadrasa}', icon: Icons.menu_book),
      if (list.isEmpty) const Text('No students in your Maktab yet.'),
      ...list.map((s) {
        final p = progFor(s);
        final cd = st.classDefs[s.cls]!;
        return Card(
          child: ListTile(
            title: Text(s.name, overflow: TextOverflow.ellipsis),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('ID ${s.key} - ${cd.name}', overflow: TextOverflow.ellipsis),
              Text(p.label ?? '${p.n} of ${p.total}', overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              LinearProgressIndicator(value: p.pct / 100),
              Text('${p.pct}% complete', style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
            ]),
            onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StudentDetail(s: s, initialTab: 2))),
          ),
        );
      }),
    ]);
  }
}

class StudentsView extends StatefulWidget {
  const StudentsView({super.key});
  @override
  State<StudentsView> createState() => _StudentsViewState();
}

class _StudentsViewState extends State<StudentsView> {
  final name = TextEditingController();
  final parent = TextEditingController();
  final stuPhone = TextEditingController();
  final address = TextEditingController();
  final fatherName = TextEditingController();
  final dob = TextEditingController();
  final studentSearch = TextEditingController();
  String gender = '';
  int cls = 1;
  String batch = 'Morning';
  bool aadhaar = false;
  bool busy = false;
  String? regMadrasa;

  @override
  Widget build(BuildContext context) {
    // Same reason as MasterDataView: this screen reads st.students directly,
    // so without listening to st it wouldn't redraw when a student is added
    // or deactivated from somewhere else (or even by this screen's own
    // async Save button, which updates st and not local setState).
    return AnimatedBuilder(animation: st, builder: (context, _) => _body(context));
  }

  Future<void> _pickDob(BuildContext context, TextEditingController c) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(2016, 1, 1),
      firstDate: DateTime(1990, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      c.text = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      setState(() {});
    }
  }

  Widget _body(BuildContext context) {
    final u = st.user!;
    final canSeeAadhaar = u.role == 'admin' || u.role == 'super';
    // Section 3.2.1/3.2.4: Teacher and Maktab Admin can both admit/edit
    // students. Section 4.1/4.2: deactivate is admin/super only, reactivate
    // is super-admin only - two separate flags, not the old single
    // canDeactivate that incorrectly let teachers do both.
    final canEdit = u.role == 'admin' || u.role == 'super' || u.role == 'teacher';
    final canDeactivate = u.role == 'admin' || u.role == 'super';
    final canReactivate = u.role == 'super';
    final canPickMadrasa = u.role == 'admin' || u.role == 'super';
    final list = st.myStudents();
    final ready = list.where((s) => st.eligible(s)).toList();
    // Super Admin picks from every active Maktab; a Maktab Admin only from
    // the one(s) they're actually scoped to (same fix already applied to
    // Fees Admin earlier) - without this an admin could pick a Maktab that
    // RLS then silently refuses to save a student under.
    final pickableMadrasas = u.role == 'super' ? st.activeMadrasaNames : st.activeMadrasaNames.where(u.branches.contains).toList();
    regMadrasa ??= canPickMadrasa ? (pickableMadrasas.isNotEmpty ? pickableMadrasas.first : null) : st.teacherMadrasa;
    return page([
      h('Add new student', icon: Icons.school),
      // Section 3.2.5: bulk import, Maktab Admin / Super Admin only (same
      // people who can pick a Maktab here already).
      if (canPickMadrasa && pickableMadrasas.isNotEmpty) ...[
        OutlinedButton.icon(
          icon: const Icon(Icons.upload_file),
          label: const Text('Import students from CSV'),
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => BulkImportStudents(pickableMadrasas: pickableMadrasas))),
        ),
        const SizedBox(height: 12),
      ],
      field(name, 'Student name *'),
      if (canPickMadrasa) ...[
        DropdownButtonFormField<String>(
          value: regMadrasa,
          decoration: const InputDecoration(labelText: 'Maktab *', border: OutlineInputBorder()),
          items: [for (final m in pickableMadrasas) DropdownMenuItem<String>(value: m, child: Text(m))],
          onChanged: (v) => setState(() => regMadrasa = v),
        ),
        const SizedBox(height: 8),
      ],
      DropdownButtonFormField<String>(
        value: gender.isEmpty ? null : gender,
        decoration: const InputDecoration(labelText: 'Gender * (Male / Female)', border: OutlineInputBorder()),
        items: const [DropdownMenuItem(value: 'Male', child: Text('Male')), DropdownMenuItem(value: 'Female', child: Text('Female'))],
        onChanged: (v) => setState(() => gender = v ?? ''),
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<int>(
        value: cls,
        decoration: const InputDecoration(labelText: 'Class', border: OutlineInputBorder()),
        items: [for (final e in st.classDefs.entries) DropdownMenuItem<int>(value: e.key, child: Text(e.value.name))],
        onChanged: (v) => setState(() => cls = v ?? cls),
      ),
      const SizedBox(height: 8),
      // Same class can run more than one session a day - this is what lets
      // Mark Attendance group students by session instead of defaulting
      // everyone not physically in front of the current teacher to Present.
      DropdownButtonFormField<String>(
        value: batch,
        decoration: const InputDecoration(labelText: 'Batch', border: OutlineInputBorder()),
        items: [for (final b in kBatches) DropdownMenuItem<String>(value: b, child: Text(b))],
        onChanged: (v) => setState(() => batch = v ?? batch),
      ),
      const SizedBox(height: 8),
      field(parent, 'Parent mobile number * (mandatory)', number: true),
      field(stuPhone, 'Student mobile number (optional)', number: true),
      field(fatherName, "Father's name (optional)"),
      GestureDetector(
        onTap: () => _pickDob(context, dob),
        child: AbsorbPointer(
          child: field(dob, 'Date of birth (optional, tap to pick)'),
        ),
      ),
      field(address, 'Address (optional)', lines: 2),
      OutlinedButton.icon(
        onPressed: () => setState(() => aadhaar = true),
        icon: Icon(aadhaar ? Icons.check_circle : Icons.upload_file, color: aadhaar ? Colors.green : null),
        label: Text(aadhaar ? 'Aadhaar card attached (demo file)' : 'Upload Aadhaar card * (required)'),
      ),
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                final madrasaToUse = u.role == 'teacher' ? st.teacherMadrasa : (regMadrasa ?? 'Hanfi');
                var e = await addStudentRemote(
                  name: name.text,
                  gender: gender,
                  cls: cls,
                  parentPhone: digits(parent.text),
                  studentPhone: digits(stuPhone.text),
                  aadhaar: aadhaar,
                  address: address.text,
                  madrasa: madrasaToUse,
                  dob: dob.text,
                  fatherName: fatherName.text,
                  batch: batch,
                );
                if (!mounted) return;
                if (e != null && e.startsWith('DUPLICATE:')) {
                  setState(() => busy = false);
                  final proceed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Possible duplicate'),
                      content: Text(e!.substring('DUPLICATE:'.length)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save anyway')),
                      ],
                    ),
                  );
                  if (proceed != true) return;
                  if (!mounted) return;
                  setState(() => busy = true);
                  e = await addStudentRemote(
                    name: name.text,
                    gender: gender,
                    cls: cls,
                    parentPhone: digits(parent.text),
                    studentPhone: digits(stuPhone.text),
                    aadhaar: aadhaar,
                    address: address.text,
                    madrasa: madrasaToUse,
                    dob: dob.text,
                    fatherName: fatherName.text,
                    batch: batch,
                    confirmDuplicate: true,
                  );
                  if (!mounted) return;
                }
                setState(() => busy = false);
                toast(context, e ?? 'Student added and saved.');
                if (e == null) {
                  name.clear();
                  parent.clear();
                  stuPhone.clear();
                  address.clear();
                  fatherName.clear();
                  dob.clear();
                  setState(() {
                    gender = '';
                    aadhaar = false;
                  });
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save student'),
      ),
      h('Pass and promote', icon: Icons.school),
      const Text('Classes 1-3: eligible once every page of the book is Completed. Class 4+: eligible once every chapter is Completed. Any mandatory Add-on Course assigned to the class must also be completed and approved.'),
      if (ready.isEmpty) const Text('No student is eligible yet. Mark pages/chapters complete in Syllabus.'),
      ...ready.map((s) {
        // Requirement 5: syllabus/chapter progress alone (st.eligible) is
        // no longer enough - every mandatory Add-on Course assigned to the
        // student's class must also be completed and approved before class
        // completion is allowed. A syllabus-ready student with pending
        // courses still shows up here (so nobody wonders where they went),
        // but blocked, with the pending courses named instead of an active
        // promote button - the same check the database trigger enforces
        // again at the backend level regardless of what this screen shows.
        final pending = st.pendingMandatoryCourses(s);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('${st.className(s.cls)} - eligible to pass'),
              const SizedBox(height: 6),
              if (pending.isEmpty)
                ElevatedButton(
                  onPressed: () async {
                    final msg = await promoteRemote(s);
                    if (context.mounted) toast(context, msg);
                  },
                  child: const Text('Mark Passed and Promote'),
                )
              else ...[
                const Text(
                  'Class completion is not allowed. The student must complete all assigned add-on courses first.',
                  style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12.5),
                ),
                const SizedBox(height: 4),
                Text('Pending: ${pending.map((c) => c.name).join(', ')}', style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
              ],
            ]),
          ),
        );
      }),
      h('Students - ${u.role == 'teacher' ? st.teacherMadrasa : 'Hanfi'}'),
      // Super Admin (and anyone else) sees every student they're scoped to
      // in one long list with no way to jump to one - search by name,
      // unique key, student phone or parent phone narrows it down to
      // actually find the student they want to edit.
      TextField(
        controller: studentSearch,
        decoration: const InputDecoration(labelText: 'Search students by name, key or phone', border: OutlineInputBorder(), prefixIcon: Icon(Icons.search)),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 8),
      Builder(builder: (context) {
        final q = studentSearch.text.trim().toLowerCase();
        final shown = q.isEmpty
            ? list
            : list.where((s) => s.name.toLowerCase().contains(q) || s.key.toLowerCase().contains(q) || s.parentPhone.contains(q) || s.studentPhone.contains(q)).toList();
        if (q.isNotEmpty && shown.isEmpty) return const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No students match that search.', style: TextStyle(color: Colors.black54)));
        return Column(children: [for (final s in shown) _studentCard(context, s, u, canEdit: canEdit, canSeeAadhaar: canSeeAadhaar, canDeactivate: canDeactivate, canReactivate: canReactivate)]);
      }),
    ]);
  }

  // Actions used to sit in the ListTile's trailing column, which has a
  // fixed height - two or three buttons there overflowed it ("BOTTOM
  // OVERFLOWED BY 16 PIXELS"). Moved below the tile in a Wrap instead,
  // which has no fixed height and just adds a row (or wraps to a
  // second one) no matter how many buttons end up there.
  Widget _studentCard(BuildContext context, Student s, Account u, {required bool canEdit, required bool canSeeAadhaar, required bool canDeactivate, required bool canReactivate}) {
    return Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ListTile(
                  title: Text('${s.name} (${s.gender})'),
                  subtitle: Text('${s.key} - ${st.className(s.cls)} - ${s.status}\nAadhaar uploaded: ${s.aadhaar ? 'Yes' : 'No'}${canSeeAadhaar ? '' : ' (teachers see only Yes or No)'}'),
                  isThreeLine: true,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
                    if (canEdit) TextButton(onPressed: () => editStudentDialog(context, s), child: const Text('Edit')),
                    if (canSeeAadhaar) TextButton(onPressed: () => toast(context, 'Demo: Aadhaar card opens here (view is logged)'), child: const Text('View Aadhaar')),
                    if (canDeactivate && s.status == 'Active')
                      TextButton(
                        onPressed: () async {
                          // Section 4.3: warn (don't block) if an active sibling exists -
                          // might be the wrong one of two kids picked by mistake.
                          final siblings = st.activeSiblings(s);
                          if (siblings.isNotEmpty) {
                            final proceed = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Active sibling found'),
                                content: Text('${s.name} has ${siblings.length} other active student(s) under the same parent mobile number (${siblings.map((x) => x.name).join(', ')}). Deactivate ${s.name} anyway?'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                  ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Deactivate anyway')),
                                ],
                              ),
                            );
                            if (proceed != true) return;
                            if (!context.mounted) return;
                          }
                          final r = await askText(context, 'Reason for deactivating ${s.name} (optional)');
                          if (r == null) return;
                          final msg = await deactivateStudentRemote(s, r);
                          if (context.mounted) toast(context, msg);
                        },
                        child: const Text('Deactivate', style: TextStyle(color: Colors.red)),
                      ),
                    if (canReactivate && s.status == 'Inactive')
                      TextButton(
                        onPressed: () async {
                          final msg = await reactivateStudentRemote(s);
                          if (context.mounted) toast(context, msg);
                        },
                        child: const Text('Reactivate'),
                      ),
                  ]),
                ),
              ]),
            ),
    );
  }
}

class ApprovalsView extends StatelessWidget {
  const ApprovalsView({super.key});
  @override
  Widget build(BuildContext context) {
    return page([
      h('Pending registrations', icon: Icons.school),
      if (st.pending.isEmpty) const Text('No pending registrations.'),
      for (var i = 0; i < st.pending.length; i++)
        Card(
          child: ListTile(
            title: Text('${st.pending[i].name} (${st.pending[i].gender})'),
            subtitle: Text('${st.className(st.pending[i].cls)} - parent ${st.pending[i].parentPhone}\nAadhaar uploaded: ${st.pending[i].aadhaar ? 'Yes' : 'No - cannot approve'}'),
            isThreeLine: true,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(onPressed: () => toast(context, st.approve(i)), child: const Text('Approve')),
              TextButton(onPressed: () => st.reject(i), child: const Text('Reject')),
            ]),
          ),
        ),
    ]);
  }
}

class TeachersView extends StatelessWidget {
  const TeachersView({super.key});
  @override
  Widget build(BuildContext context) {
    // Same reason as MasterDataView/StudentsView: st.teacherAccounts is
    // only populated once loadTeachers() resolves after this screen first
    // renders, so without listening to st this screen would need some
    // unrelated rebuild to ever actually show the real teachers.
    return AnimatedBuilder(animation: st, builder: (context, _) => _body(context));
  }

  Widget _body(BuildContext context) {
    return page([
      h('Teacher attendance - ${nice(kToday)}', icon: Icons.groups),
      // Was reading st.teacherAtt.entries directly - a hardcoded local demo
      // map that never had any of the real teachers added through Master
      // Data in it, so only the original seed name ever showed up here.
      // The real teacher list is st.teacherAccounts; attendance marking
      // itself still isn't wired to the database, so "Not marked" is still
      // just a local default per name until that's built.
      if (st.teacherAccounts.where((t) => !t.pending).isEmpty) const Text('No teachers yet.', style: TextStyle(color: Colors.black54)),
      ...st.teacherAccounts.where((t) => !t.pending).map((t) => Card(child: ListTile(title: Text(t.name), subtitle: Text(t.teachMadrasas.join(', ')), trailing: Text(st.teacherAtt[t.name] ?? 'Not marked')))),
      h('Teacher leave requests', icon: Icons.event_busy),
      // Section 7: st.leaves is already scoped to this admin's own Maktab(s)
      // by RLS (teacher_leaves_scoped_read) - a request against a Maktab
      // this admin doesn't manage never reaches this list at all, and a
      // Super Admin sees every Maktab's requests.
      if (st.leaves.isEmpty) const Text('No leave requests yet. Log in as Teacher and apply for leave.'),
      ...st.leaves.map((l) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l.teacher} - ${l.type}: ${nice(l.from)} to ${nice(l.to)}${l.madrasa.isEmpty ? '' : ' - ${l.madrasa}'}', style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('Reason: ${l.reason}'),
                Text('Status: ${l.status}${l.status == 'Pending' ? '' : ' by ${l.by} (${l.remark})'}'),
                if (l.status == 'Pending')
                  Row(children: [
                    TextButton(
                      onPressed: () async {
                        final r = await askText(context, 'Remark', initial: 'Approved, take rest');
                        if (r == null) return;
                        final e = await decideLeaveRemote(l, true, r);
                        if (e != null && context.mounted) toast(context, e);
                      },
                      child: const Text('Approve'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final r = await askText(context, 'Reason for rejection');
                        if (r == null) return;
                        final e = await decideLeaveRemote(l, false, r);
                        if (e != null && context.mounted) toast(context, e);
                      },
                      child: const Text('Reject'),
                    ),
                  ]),
              ]),
            ),
          )),
    ]);
  }
}

class FeesAdmin extends StatelessWidget {
  const FeesAdmin({super.key});
  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    // Was hardcoded to the "Hanfi" branch only, regardless of which
    // madrasa(s) the admin actually manages - a Super Admin now sees every
    // active student, everyone else only their own madrasa(s).
    final scope = u.role == 'super' ? st.students : st.students.where((s) => u.branches.contains(s.madrasa)).toList();
    final list = scope.where((s) => s.status == 'Active').toList();
    // Was hardcoded to ['Jun','Jul','Aug','Sep'] - now every month that
    // actually applies to at least one of these students (from their own
    // admission through the current month), sorted chronologically, so
    // this keeps showing real data instead of going stale after September.
    final allMonths = list.expand((s) => st.feeMonths(s)).toSet().toList()
      ..sort((a, b) {
        final y = AppState.yearFromKey(a).compareTo(AppState.yearFromKey(b));
        return y != 0 ? y : AppState.monthNumFromKey(a).compareTo(AppState.monthNumFromKey(b));
      });
    return page([
      h('Fees (month-wise)', icon: Icons.payments),
      grid([for (final m in allMonths) tile(m, '${list.where((s) => st.isPaid(s.id, m)).length} of ${list.where((s) => st.feeMonths(s).contains(m)).length} complete')]),
      const Text('Tap a due month to record a payment of Rs. 200.'),
      ...list.map((s) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s.name} - ${s.madrasa} - ${st.className(s.cls)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                Wrap(spacing: 6, children: [
                  for (final m in st.feeMonths(s))
                    st.isPaid(s.id, m)
                        ? Chip(label: Text('$m - Complete'), backgroundColor: const Color(0xFFDFF3DA))
                        : ActionChip(
                            label: Text('$m due - Pay'),
                            backgroundColor: const Color(0xFFFFE3E0),
                            onPressed: () async {
                              final msg = await payRemote(s, m);
                              if (context.mounted) toast(context, msg);
                            },
                          ),
                ]),
              ]),
            ),
          )),
    ]);
  }
}

class TeacherMadrasasAdmin extends StatefulWidget {
  const TeacherMadrasasAdmin({super.key});
  @override
  State<TeacherMadrasasAdmin> createState() => _TeacherMadrasasAdminState();
}

class _TeacherMadrasasAdminState extends State<TeacherMadrasasAdmin> {
  // Keyed by phone, not the Account object itself: st.teacherAccounts is a
  // fresh list of new Account instances every time it reloads (after a
  // save, or a realtime update from another device), and Account has no
  // custom == - so a DropdownButtonFormField<Account> would hold a
  // selection pointing at an instance that no longer == anything in the
  // rebuilt items list ("zero or 2+ items with the same value" assertion).
  // A phone number is stable across reloads, so it survives rebuilds.
  String? teacherPhone;
  String? madrasa;
  final Set<int> classIds = {};
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) {
        final teachers = st.teacherAccounts.where((t) => !t.pending).toList();
        if (teacherPhone != null && teachers.every((t) => t.phone != teacherPhone)) teacherPhone = null;
        return page([
          h('Teacher Makatib and classes', icon: Icons.groups),
          if (teachers.isEmpty)
            const Text(
              'No teacher has logged in yet. Invite one from Master Data > Teachers first - they show up here once they sign in with OTP.',
              style: TextStyle(color: Colors.black54),
            ),
          ...teachers.map((t) => Card(
                child: ListTile(
                  title: Text(t.name),
                  subtitle: Text(t.teachMadrasas.isEmpty ? 'Not assigned to any Maktab yet' : t.teachMadrasas.join(', ')),
                  isThreeLine: false,
                ),
              )),
          h('Assign a teacher to another Maktab'),
          if (teachers.isEmpty)
            const Text('Invite and sign in a teacher first.', style: TextStyle(color: Colors.black54))
          else ...[
            DropdownButtonFormField<String>(
              value: teacherPhone,
              decoration: const InputDecoration(labelText: 'Teacher', border: OutlineInputBorder()),
              items: [for (final t in teachers) DropdownMenuItem<String>(value: t.phone, child: Text(t.name))],
              onChanged: (v) => setState(() => teacherPhone = v),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: madrasa,
              decoration: const InputDecoration(labelText: 'Maktab', border: OutlineInputBorder()),
              items: [for (final m in st.activeMadrasaNames) DropdownMenuItem<String>(value: m, child: Text(m))],
              onChanged: (v) => setState(() => madrasa = v),
            ),
            const SizedBox(height: 8),
            const Text('Classes:'),
            ...st.classDefs.entries.map((e) => CheckboxListTile(
                  title: Text(e.value.name),
                  value: classIds.contains(e.key),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      classIds.add(e.key);
                    } else {
                      classIds.remove(e.key);
                    }
                  }),
                )),
            ElevatedButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (teacherPhone == null || madrasa == null) {
                        toast(context, 'Choose a teacher and a Maktab');
                        return;
                      }
                      Account? t;
                      for (final x in teachers) {
                        if (x.phone == teacherPhone) {
                          t = x;
                          break;
                        }
                      }
                      if (t == null) {
                        toast(context, 'Pick the teacher again - the list just refreshed.');
                        return;
                      }
                      setState(() => busy = true);
                      final err = await assignTeacherMadrasaRemote(t, madrasa!, classIds.toList());
                      if (!mounted) return;
                      setState(() => busy = false);
                      toast(context, err ?? 'Assigned. The teacher sees it next time they open the app.');
                      if (err == null) setState(() => classIds.clear());
                    },
              child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Assign to another Maktab'),
            ),
          ],
        ]);
      },
    );
  }
}

class SuperSyllabus extends StatefulWidget {
  const SuperSyllabus({super.key});
  @override
  State<SuperSyllabus> createState() => _SuperSyllabusState();
}

class _SuperSyllabusState extends State<SuperSyllabus> {
  final title = TextEditingController();
  final days = TextEditingController(text: '30');
  int cls = 4;
  @override
  Widget build(BuildContext context) {
    final chapterClasses = st.classDefs.values.where((c) => !c.pageBased).toList();
    return page([
      h('Classes and syllabus', icon: Icons.menu_book),
      ...st.classDefs.values.map((cd) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: cd.pageBased
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(cd.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('Book: ${cd.bookName} - ${cd.totalPages} pages - page-wise tracking'),
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(cd.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                      for (var i = 0; i < (st.chapters[cd.id] ?? []).length; i++) Text('${i + 1}. ${st.chapters[cd.id]![i].title} - ${st.chapters[cd.id]![i].days} days'),
                    ]),
            ),
          )),
      h('Add chapter (chapter-based classes only)'),
      if (chapterClasses.isEmpty) const Text('No chapter-based class defined.'),
      if (chapterClasses.isNotEmpty) ...[
        DropdownButtonFormField<int>(
          value: cls,
          decoration: const InputDecoration(labelText: 'Class', border: OutlineInputBorder()),
          items: [for (final c in chapterClasses) DropdownMenuItem<int>(value: c.id, child: Text(c.name))],
          onChanged: (v) => setState(() => cls = v ?? cls),
        ),
        const SizedBox(height: 8),
        field(title, 'Chapter title'),
        field(days, 'Days needed', number: true),
        ElevatedButton(
          onPressed: () async {
            if (title.text.trim().isEmpty) {
              toast(context, 'Enter a title');
              return;
            }
            final e = await addChapterRemote(cls, title.text.trim(), int.tryParse(days.text) ?? 30);
            if (e != null) {
              toast(context, e);
              return;
            }
            title.clear();
            toast(context, 'Chapter added. Every student plan is recalculated from their own start date.');
          },
          child: const Text('Add and publish'),
        ),
      ],
    ]);
  }
}

class ReportsView extends StatefulWidget {
  const ReportsView({super.key});
  @override
  State<ReportsView> createState() => _ReportsViewState();
}

class _ReportsViewState extends State<ReportsView> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final rows = st.reports.where((r) => r.name.toLowerCase().contains(q.toLowerCase())).toList();
    return page([
      h('Reports centre', icon: Icons.assessment),
      TextField(decoration: const InputDecoration(labelText: 'Search report name', border: OutlineInputBorder()), onChanged: (v) => setState(() => q = v)),
      const SizedBox(height: 8),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [DataColumn(label: Text('Report name')), DataColumn(label: Text('Date / period')), DataColumn(label: Text('Maktab')), DataColumn(label: Text('Created on')), DataColumn(label: Text('Download'))],
          rows: [
            for (final r in rows)
              DataRow(cells: [
                DataCell(Text(r.name)),
                DataCell(Text(r.period)),
                DataCell(Text(r.madrasa)),
                DataCell(Text(r.created)),
                DataCell(Row(children: [
                  TextButton(onPressed: () => toast(context, 'Demo: ${r.name} PDF downloaded'), child: const Text('PDF')),
                  TextButton(onPressed: () => toast(context, 'Demo: ${r.name} Excel downloaded'), child: const Text('Excel')),
                ])),
              ]),
          ],
        ),
      ),
    ]);
  }
}

class RolesView extends StatefulWidget {
  const RolesView({super.key});
  @override
  State<RolesView> createState() => _RolesViewState();
}

class _RolesViewState extends State<RolesView> {
  final roleName = TextEditingController();
  final aPhone = TextEditingController();
  final aName = TextEditingController();
  final Set<String> perms = {};
  String? pick;
  final Set<String> branches = {};
  bool busy = false;
  static const List<String> screens = ['Students', 'Fees', 'Reports', 'Leave'];
  static const List<String> builtInRoles = ['Super Admin', 'Maktab Admin', 'Teacher', 'Committee Member'];

  @override
  Widget build(BuildContext context) {
    final names = st.customRoles.keys.toList();
    return page([
      h('Create role', icon: Icons.admin_panel_settings),
      field(roleName, 'Role name (for example Accountant)'),
      const Text('Tick the screens this role can see and add/edit:'),
      ...screens.map((s) => CheckboxListTile(
            title: Text(s == 'Students' ? 'Students and Add Student form' : s == 'Leave' ? 'Teacher leave' : s),
            value: perms.contains(s),
            onChanged: (v) => setState(() {
              if (v == true) {
                perms.add(s);
              } else {
                perms.remove(s);
              }
            }),
          )),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                final e = await createRoleRemote(roleName.text, perms);
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Role saved');
                if (e == null) {
                  roleName.clear();
                  setState(perms.clear);
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save role'),
      ),
      h('Existing custom roles', icon: Icons.admin_panel_settings),
      ...names.map((n) => Card(child: ListTile(title: Text(n), subtitle: Text('Screens: ${(st.customRoles[n] ?? <String>{}).join(', ')}')))),
      h('Assign / change role', icon: Icons.admin_panel_settings),
      const Padding(
        padding: EdgeInsets.only(bottom: 6),
        child: Text(
          "Works for anyone - a brand-new phone number, or someone who already has an account. If they're already in the system, their role changes right away. A Super Admin sees every Maktab, so no need to pick one for that role.",
          style: TextStyle(color: Colors.black54, fontSize: 12.5),
        ),
      ),
      field(aPhone, 'Mobile number', number: true),
      field(aName, 'Name'),
      DropdownButtonFormField<String>(
        value: pick,
        decoration: const InputDecoration(labelText: 'Role', border: OutlineInputBorder()),
        items: [
          for (final n in builtInRoles) DropdownMenuItem<String>(value: n, child: Text(n)),
          for (final n in names) DropdownMenuItem<String>(value: n, child: Text(n)),
        ],
        onChanged: (v) => setState(() => pick = v),
      ),
      if (pick != null && pick != 'Super Admin') ...[
        const Padding(padding: EdgeInsets.only(top: 4, bottom: 4), child: Text('Makatib this person can see:', style: TextStyle(color: Colors.black54, fontSize: 12.5))),
        Wrap(spacing: 4, children: [
          FilterChip(
            label: const Text('All Makatib'),
            selected: st.activeMadrasaNames.isNotEmpty && branches.length == st.activeMadrasaNames.length,
            onSelected: (v) => setState(() {
              if (v) {
                branches..clear()..addAll(st.activeMadrasaNames);
              } else {
                branches.clear();
              }
            }),
          ),
          for (final m in st.activeMadrasaNames)
            FilterChip(
              label: Text(m),
              selected: branches.contains(m),
              onSelected: (v) => setState(() => v ? branches.add(m) : branches.remove(m)),
            ),
        ]),
      ],
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: busy || pick == null
            ? null
            : () async {
                setState(() => busy = true);
                String dbRole;
                String? customRoleName;
                switch (pick) {
                  case 'Super Admin':
                    dbRole = 'super_admin';
                    break;
                  case 'Maktab Admin':
                    dbRole = 'madrasa_admin';
                    break;
                  case 'Teacher':
                    dbRole = 'teacher';
                    break;
                  case 'Committee Member':
                    dbRole = 'committee';
                    break;
                  default:
                    dbRole = 'custom';
                    customRoleName = pick;
                }
                final e = await setUserRoleRemote(
                  phone: aPhone.text,
                  name: aName.text,
                  dbRole: dbRole,
                  customRoleName: customRoleName,
                  branches: dbRole == 'super_admin' ? const [] : branches.toList(),
                );
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Role saved - right away for an existing account, or the moment this phone number first logs in with OTP.');
                if (e == null) {
                  aPhone.clear();
                  aName.clear();
                  setState(() {
                    pick = null;
                    branches.clear();
                  });
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save role'),
      ),
    ]);
  }
}

class CommitteeAdmin extends StatefulWidget {
  const CommitteeAdmin({super.key});
  @override
  State<CommitteeAdmin> createState() => _CommitteeAdminState();
}

class _CommitteeAdminState extends State<CommitteeAdmin> {
  final phone = TextEditingController();
  final name = TextEditingController();
  final Set<String> br = {};
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) => page([
        h('Add committee member (read-only)'),
        field(phone, 'Mobile number', number: true),
        field(name, 'Name'),
        const Text('Makatib this member can see:'),
        ...st.activeMadrasaNames.map((b) => CheckboxListTile(
              title: Text(b),
              value: br.contains(b),
              onChanged: (v) => setState(() {
                if (v == true) {
                  br.add(b);
                } else {
                  br.remove(b);
                }
              }),
            )),
        ElevatedButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  final e = await addCommitteeRemote(phone.text, name.text, br.toList());
                  if (!mounted) return;
                  setState(() => busy = false);
                  toast(context, e ?? 'Member invited. They see only student progress, the moment they log in with OTP.');
                  if (e == null) {
                    phone.clear();
                    name.clear();
                    setState(br.clear);
                  }
                },
          child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add member'),
        ),
        h('Members'),
        if (st.committeeAccounts.isEmpty) const Text('No committee members yet.', style: TextStyle(color: Colors.black54)),
        ...st.committeeAccounts.map((m) => Card(
              child: ListTile(
                title: Text(m.name),
                subtitle: Text('${m.phone} - ${m.branches.join(', ')}${m.pending ? ' - invited, waiting for first login' : ''}'),
                trailing: TextButton(
                  onPressed: () async {
                    // Section 10: confirm before removing - this revokes
                    // access (deactivates) rather than deleting history for
                    // anyone who has actually logged in; a never-activated
                    // invite has nothing to deactivate, so it's just deleted.
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Remove this member?'),
                        content: Text('${m.name} will lose access. ${m.pending ? 'Nothing has been created for them yet, so this just cancels the invite.' : 'Their account is kept and can be reactivated later by a Super Admin if needed.'}'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    if (!context.mounted) return;
                    final e = await removeCommitteeRemote(m);
                    if (context.mounted) toast(context, e ?? 'Removed.');
                  },
                  child: const Text('Remove'),
                ),
              ),
            )),
        h('View log'),
        if (st.viewLog.isEmpty) const Text('No student views yet. Log in as Working Committee and open a student.'),
        ...st.viewLog.reversed.map((l) => Text(l)),
      ]),
    );
  }
}

// ---------------- working committee (read only) ----------------
class CommitteeDashboard extends StatelessWidget {
  const CommitteeDashboard({super.key});
  @override
  Widget build(BuildContext context) {
    final totalActive = st.students.where((s) => s.status == 'Active').length;
    return page([
      h('Working Committee dashboard', icon: Icons.dashboard),
      Card(
        child: ListTile(
          leading: const CircleAvatar(backgroundColor: Color(0xFFEEF4E8), child: Icon(Icons.groups, color: kGreen)),
          title: const Text('All Maktab Students', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('$totalActive active student(s) across all Makatib'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => pushPage(context, 'All Students', const AllStudentsList()),
        ),
      ),
      Card(
        child: ListTile(
          leading: const CircleAvatar(backgroundColor: Color(0xFFEEF4E8), child: Icon(Icons.account_balance, color: kGreen)),
          title: const Text('Maktab-Wise Student Information', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: const Text('Pick a Maktab to see its students'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => pushPage(context, 'Makatib', const CommitteeBranches()),
        ),
      ),
      Card(
        child: ListTile(
          leading: const CircleAvatar(backgroundColor: Color(0xFFEEF4E8), child: Icon(Icons.schedule, color: kGreen)),
          title: const Text('Maktab Timings', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: const Text('Existing Morning/Afternoon/Evening timing by Maktab and class (view-only)'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => pushPage(context, 'Maktab Timings', const CommitteeMaktabTimings()),
        ),
      ),
    ]);
  }
}

// One row of the Working Committee's Maktab Timings view - computed from
// the existing Maktab/class/batch/student data, never a separate timing
// table. "Timing Not Set" is used rather than inventing a value when a
// student's batch field is missing.
class _TimingRow {
  final String maktab;
  final String? category;
  final int cls;
  final String className;
  final String? timing;
  final String? teacher;
  _TimingRow({required this.maktab, this.category, required this.cls, required this.className, this.timing, this.teacher});
}

class CommitteeMaktabTimings extends StatefulWidget {
  const CommitteeMaktabTimings({super.key});
  @override
  State<CommitteeMaktabTimings> createState() => _CommitteeMaktabTimingsState();
}

class _CommitteeMaktabTimingsState extends State<CommitteeMaktabTimings> {
  String? fCategory;
  String? fMaktab;
  int? fCls;
  String? fTiming;
  String q = '';

  @override
  Widget build(BuildContext context) {
    // Existing data only: every (Maktab, class, batch) combination that
    // actually has at least one active student, reusing
    // students/madrasas/classes/teacher_class_assignments as they already
    // are - no new timing fields or a separate timetable module.
    final seen = <String>{};
    final rows = <_TimingRow>[];
    for (final s in st.students.where((s) => s.status == 'Active')) {
      final cd = st.classDefs[s.cls];
      if (cd == null) continue;
      final timing = kBatches.contains(s.batch) ? s.batch : null;
      final key = '${s.madrasa}|${s.cls}|${timing ?? ''}';
      if (!seen.add(key)) continue;
      final m = st.madrasas.where((m) => m.name == s.madrasa).toList();
      rows.add(_TimingRow(
        maktab: s.madrasa,
        category: m.isNotEmpty ? m.first.category : null,
        cls: s.cls,
        className: cd.name,
        timing: timing,
        teacher: st.teacherNameFor(s.madrasa, s.cls),
      ));
    }
    rows.sort((a, b) {
      final c = a.maktab.compareTo(b.maktab);
      if (c != 0) return c;
      return a.cls.compareTo(b.cls);
    });

    final maktabs = {for (final r in rows) r.maktab}.toList()..sort();
    final classes = {for (final r in rows) r.cls}.toList()..sort();

    final filtered = rows.where((r) {
      if (fCategory != null && (r.category ?? '') != fCategory) return false;
      if (fMaktab != null && r.maktab != fMaktab) return false;
      if (fCls != null && r.cls != fCls) return false;
      if (fTiming != null && (r.timing ?? '') != fTiming) return false;
      if (q.isNotEmpty && !('${r.maktab} ${r.className}'.toLowerCase().contains(q.toLowerCase()))) return false;
      return true;
    }).toList();

    Widget dd<T>(String label, T? value, List<T> options, String Function(T) show, void Function(T?) onChanged) {
      return DropdownButtonFormField<T>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [DropdownMenuItem<T>(value: null, child: Text('All')), for (final o in options) DropdownMenuItem<T>(value: o, child: Text(show(o)))],
        onChanged: onChanged,
      );
    }

    return page([
      h('Maktab Timings', icon: Icons.schedule),
      const Text(
        'Existing Morning/Afternoon/Evening class timing, Maktab and class relationships, shown here view-only. Filtering and searching never change the underlying data.',
        style: TextStyle(color: Colors.black54, fontSize: 12.5),
      ),
      const SizedBox(height: 8),
      TextField(decoration: const InputDecoration(labelText: 'Search Maktab or class', border: OutlineInputBorder(), isDense: true), onChanged: (v) => setState(() => q = v)),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, c) {
        final narrow = c.maxWidth < 560;
        final filters = [
          SizedBox(width: narrow ? c.maxWidth : 180, child: dd<String>('Category', fCategory, kMadrasaCategories, (v) => v, (v) => setState(() => fCategory = v))),
          SizedBox(width: narrow ? c.maxWidth : 180, child: dd<String>('Maktab', fMaktab, maktabs, (v) => v, (v) => setState(() => fMaktab = v))),
          SizedBox(width: narrow ? c.maxWidth : 180, child: dd<int>('Class', fCls, classes, (v) => st.className(v), (v) => setState(() => fCls = v))),
          SizedBox(width: narrow ? c.maxWidth : 180, child: dd<String>('Timing', fTiming, kBatches, (v) => v, (v) => setState(() => fTiming = v))),
        ];
        return Wrap(spacing: 8, runSpacing: 8, children: filters);
      }),
      const SizedBox(height: 12),
      Text('${filtered.length} record(s)', style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
      const SizedBox(height: 6),
      // Cards, not a wide DataTable - stacked fields never overlap or get
      // clipped on a phone, and the whole screen scrolls normally.
      for (final r in filtered)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.maktab, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 2),
              Text('Branch: ${r.maktab}', style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
              Text('Category: ${r.category ?? 'Not set'}', style: const TextStyle(fontSize: 12.5)),
              Text('Class: ${r.className}', style: const TextStyle(fontSize: 12.5)),
              Text('Timing: ${r.timing ?? 'Timing Not Set'}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: r.timing == null ? Colors.orange.shade800 : Colors.black87)),
              if (r.teacher != null) Text('Teacher: ${r.teacher}', style: const TextStyle(fontSize: 12.5)),
            ]),
          ),
        ),
      if (filtered.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No records match these filters.')),
    ]);
  }
}

class AllStudentsList extends StatefulWidget {
  const AllStudentsList({super.key});
  @override
  State<AllStudentsList> createState() => _AllStudentsListState();
}

class _AllStudentsListState extends State<AllStudentsList> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final list = st.students
        .where((s) => s.status == 'Active')
        .where((s) => s.name.toLowerCase().contains(q.toLowerCase()) || s.key.toLowerCase().contains(q.toLowerCase()))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('All Maktab Students'), backgroundColor: kGreen, foregroundColor: Colors.white),
      body: page([
        TextField(decoration: const InputDecoration(labelText: 'Search by name or unique key', border: OutlineInputBorder()), onChanged: (v) => setState(() => q = v)),
        const SizedBox(height: 8),
        ...list.map((s) {
          final p = progFor(s);
          return Card(
            child: ListTile(
              title: Text(s.name),
              subtitle: Text('${s.key} - ${s.madrasa} - ${st.className(s.cls)} - ${p.label ?? '${p.pct}%'}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                st.logView(s);
                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StudentDetail(s: s)));
              },
            ),
          );
        }),
      ]),
    );
  }
}

// Global search for Admin/Super Admin: type a mobile number, name, student
// key or Maktab name and jump straight to it, instead of having to guess
// which of several screens (Students, Teachers & Leave, Makatib) the
// person or Maktab is on. A phone number can match a student directly
// (student_phone), a parent (parent_phone - the student is still the
// closest real record to open, there's no separate parent screen), or a
// teacher. Results stay empty until something is typed, and each list is
// capped so one very common substring can't dump the whole database.
class GlobalSearchView extends StatefulWidget {
  const GlobalSearchView({super.key});
  @override
  State<GlobalSearchView> createState() => _GlobalSearchViewState();
}

class _GlobalSearchViewState extends State<GlobalSearchView> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    final query = q.trim().toLowerCase();
    // Admin only searches within the Maktab(s) they manage; Super Admin
    // searches everything - same scoping already used for Admin's
    // dashboard counts (u.branches).
    final scoped = u.role != 'super';

    final students = query.isEmpty
        ? <Student>[]
        : st.students
            .where((s) => !scoped || u.branches.contains(s.madrasa))
            .where((s) => s.name.toLowerCase().contains(query) || s.key.toLowerCase().contains(query) || s.parentPhone.contains(query) || s.studentPhone.contains(query))
            .take(20)
            .toList();
    final teachers = query.isEmpty
        ? <Account>[]
        : st.teacherAccounts
            .where((t) => !scoped || t.teachMadrasas.any(u.branches.contains))
            .where((t) => t.name.toLowerCase().contains(query) || t.phone.contains(query))
            .take(20)
            .toList();
    final madrasas = query.isEmpty
        ? <MadrasaRec>[]
        : st.madrasas.where((m) => !scoped || u.branches.contains(m.name)).where((m) => m.name.toLowerCase().contains(query)).take(20).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Search'), backgroundColor: kGreen, foregroundColor: Colors.white),
      body: page([
        TextField(
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Mobile number, name, student key or Maktab', border: OutlineInputBorder(), prefixIcon: Icon(Icons.search)),
          onChanged: (v) => setState(() => q = v),
        ),
        const SizedBox(height: 10),
        if (query.isEmpty) const Text('Type a mobile number, name or Maktab to search.', style: TextStyle(color: Colors.black54)),
        if (query.isNotEmpty && students.isEmpty && teachers.isEmpty && madrasas.isEmpty) const Text('No matches.', style: TextStyle(color: Colors.black54)),
        if (madrasas.isNotEmpty) ...[
          h('Makatib'),
          ...madrasas.map((m) => Card(
                child: ListTile(
                  leading: const Icon(Icons.account_balance),
                  title: Text(m.name),
                  subtitle: Text(m.active ? 'Active' : 'Inactive'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => BranchStudents(branch: m.name))),
                ),
              )),
        ],
        if (students.isNotEmpty) ...[
          h('Students & parents'),
          ...students.map((s) {
            final viaParent = s.parentPhone.contains(query) && !s.studentPhone.contains(query) && !s.name.toLowerCase().contains(query) && !s.key.toLowerCase().contains(query);
            return Card(
              child: ListTile(
                leading: const Icon(Icons.person),
                title: Text(s.name),
                subtitle: Text(viaParent ? 'Parent (${s.parentPhone}) - ${s.madrasa}, ${st.className(s.cls)}' : '${s.key} - ${s.madrasa}, ${st.className(s.cls)}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  st.logView(s);
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StudentDetail(s: s)));
                },
              ),
            );
          }),
        ],
        if (teachers.isNotEmpty) ...[
          h('Teachers'),
          ...teachers.map((t) => Card(
                child: ListTile(
                  leading: const Icon(Icons.co_present),
                  title: Text(t.name),
                  subtitle: Text('${t.phone} - ${t.teachMadrasas.join(', ')}${t.pending ? ' - Invited, not joined yet' : ''}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => pushPage(context, 'Teachers & Leave', const TeachersView()),
                ),
              )),
        ],
      ]),
    );
  }
}

// Super Admin's "pick a Maktab, then see its students with live status"
// screen - same drill-down as CommitteeBranches/BranchStudents below, but
// over every Maktab (st.madrasas) rather than one account's scoped
// u.branches, since a Super Admin isn't restricted to a subset.
class SuperMakatibOverview extends StatelessWidget {
  const SuperMakatibOverview({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: st,
        builder: (context, _) => page([
          h('All Makatib'),
          ...st.madrasas.map((m) => Card(
                child: ListTile(
                  title: Text(m.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    '${m.active ? 'Active' : 'Inactive'} - ${st.inBranch(m.name).where((s) => s.status == 'Active').length} students - avg attendance ${st.avgAtt(m.name)}% - avg syllabus ${st.avgSyl(m.name)}%',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => BranchStudents(branch: m.name))),
                ),
              )),
        ]),
      );
}

class CommitteeBranches extends StatelessWidget {
  const CommitteeBranches({super.key});
  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    return page([
      h('Makatib'),
      ...u.branches.map((b) => Card(
            child: ListTile(
              title: Text(b, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${st.inBranch(b).where((s) => s.status == 'Active').length} students - avg attendance ${st.avgAtt(b)}% - avg syllabus ${st.avgSyl(b)}%'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => BranchStudents(branch: b))),
            ),
          )),
    ]);
  }
}

class BranchStudents extends StatefulWidget {
  final String branch;
  const BranchStudents({super.key, required this.branch});
  @override
  State<BranchStudents> createState() => _BranchStudentsState();
}

class _BranchStudentsState extends State<BranchStudents> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final list = st.inBranch(widget.branch).where((s) => s.status == 'Active').where((s) => s.name.toLowerCase().contains(q.toLowerCase()) || s.key.toLowerCase().contains(q.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.branch), backgroundColor: kGreen, foregroundColor: Colors.white),
      body: page([
        TextField(decoration: const InputDecoration(labelText: 'Search by name or unique key', border: OutlineInputBorder()), onChanged: (v) => setState(() => q = v)),
        const SizedBox(height: 8),
        ...list.map((s) {
          final p = progFor(s);
          return Card(
            child: ListTile(
              title: Text(s.name),
              subtitle: Text('${s.key} - ${st.className(s.cls)} - ${s.status} - ${p.label ?? '${p.pct}%'}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                st.logView(s);
                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StudentDetail(s: s)));
              },
            ),
          );
        }),
      ]),
    );
  }
}

class StudentDetail extends StatelessWidget {
  final Student s;
  // Which tab to land on (0 Status, 1 Class history, 2 Syllabus, 3
  // Attendance, 4 Results, 5 Add-on Courses) - Syllabus Progress opens
  // straight to Syllabus (2) instead of making the Teacher tap again.
  final int initialTab;
  const StudentDetail({super.key, required this.s, this.initialTab = 0});
  @override
  Widget build(BuildContext context) {
    final cd = st.classDefs[s.cls]!;
    final p = progFor(s);
    return DefaultTabController(
      length: 6,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.name),
          backgroundColor: kGreen,
          foregroundColor: Colors.white,
          bottom: const TabBar(isScrollable: true, labelColor: Colors.white, unselectedLabelColor: Colors.white70, tabs: [
            Tab(text: 'Status'),
            Tab(text: 'Class history'),
            Tab(text: 'Syllabus'),
            Tab(text: 'Attendance'),
            Tab(text: 'Results'),
            Tab(text: 'Add-on Courses'),
          ]),
        ),
        body: AnimatedBuilder(animation: st, builder: (context, _) => TabBarView(children: [
          page([
            Card(
              child: ListTile(
                title: Text('Unique key: ${s.key}', style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('${s.name} - ${s.gender} - ${s.madrasa}\nAdmitted ${nice(s.start)}'),
                isThreeLine: true,
              ),
            ),
            grid([
              tile('Current status', s.status),
              tile('Class', cd.name),
              tile('Progress', p.label ?? '${p.n} of ${p.total} (${p.pct}%)'),
              tile('Pace', p.behind > 0 ? 'Behind ${p.behind}' : 'On pace', color: p.behind > 0 ? Colors.red : Colors.green),
              tile('Attendance', '${st.attPct(s)}%'),
            ]),
          ]),
          page([
            ...s.history.map((x) => Card(child: ListTile(title: Text(x)))),
            Card(child: ListTile(title: Text('${cd.name}: started ${nice(s.start)} (${s.status == 'Active' ? 'Ongoing' : s.status})'))),
          ]),
          // Requirement 1: was a separate, simpler re-implementation that
          // ignored Para teaching order and Book Management entirely - now
          // the same SyllabusBody every other syllabus screen (student,
          // parent) uses, so a fix there reaches here too and this view
          // never drifts out of sync again.
          SyllabusBody(s: s, edit: true),
          page([AttendanceMonthReport(key: ValueKey(s.id), s: s)]),
          page([
            const Card(child: ListTile(title: Text('Exam results'), subtitle: Text('Not recorded yet - no exam/marks feature exists in the app yet'))),
            const Text('Fees, teachers, phone numbers, address, Aadhaar and complaints are never shown to committee members.'),
          ]),
          CoursesTabBody(s: s),
        ])),
      ),
    );
  }
}

// Course status badge + (for Teacher/Admin/Super) submit-for-approval and
// approve/reject actions, shown inside the student's own Courses tab.
class CoursesTabBody extends StatelessWidget {
  final Student s;
  const CoursesTabBody({super.key, required this.s});

  Widget _badge(String status) {
    switch (status) {
      case 'completed':
        return const Chip(label: Text('✓ Completed', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), backgroundColor: Color(0xFF2E7D32));
      case 'awaiting_approval':
        return const Chip(label: Text('Awaiting approval'), backgroundColor: Color(0xFFFFE9B0));
      case 'in_progress':
        return const Chip(label: Text('In progress'), backgroundColor: Color(0xFFDCE8FF));
      default:
        return const Chip(label: Text('Pending'), backgroundColor: Color(0xFFEDEDED));
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = st.user;
    final canSubmit = u != null && (u.role == 'teacher' || u.role == 'admin' || u.role == 'super');
    final canDecide = u != null && (u.role == 'admin' || u.role == 'super');
    final enrollments = st.enrollmentsFor(s);
    // Requirement 8 ("students see only the add-on courses assigned to
    // their class"): the picker only offers courses a Super Admin/Admin
    // has actually assigned to this student's class via Master Data, not
    // every active course in the system.
    final assignable = st.coursesForClass(st.classDefs[s.cls]?.id ?? -1).where((c) => c.active && !enrollments.any((e) => e.courseId == c.id));
    return page([
      if (canSubmit) ...[
        const Text('Assign an Add-on Course to this student:', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (assignable.isEmpty) const Text('No unassigned Add-on Courses for this class.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
        Wrap(
          spacing: 6,
          children: [
            for (final c in assignable)
              ActionChip(
                label: Text(c.name),
                onPressed: () async {
                  final e = await enrollCourseRemote(s, c);
                  if (context.mounted && e != null) toast(context, e);
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
      ],
      // Requirement 6 (Parent Dashboard: "show the overall progress of the
      // student's assigned courses"). This widget is shared by the
      // Teacher/Admin student-profile Courses tab AND the Parent's
      // KidCourseProgress screen, so adding the summary here surfaces it to
      // both audiences from one place instead of duplicating it.
      if (enrollments.isNotEmpty) ...[
        () {
          final total = enrollments.length;
          final done = enrollments.where((e) => e.status == 'completed').length;
          final pct = total == 0 ? 0.0 : done / total;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              color: const Color(0xFFF3F7FF),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Add-on Course progress: $done of $total completed', style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: pct, minHeight: 8)),
                ]),
              ),
            ),
          );
        }(),
      ],
      if (enrollments.isEmpty) const Text('No Add-on Courses assigned to this student yet.'),
      ...enrollments.map((e) {
        final c = st.courseById(e.courseId);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(child: Text(c?.name ?? 'Add-on Course #${e.courseId}', style: const TextStyle(fontWeight: FontWeight.bold))),
                _badge(e.status),
              ]),
              if (c != null && c.description.isNotEmpty) Text(c.description, style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
              if (e.status == 'completed' && e.completedOn != null) Text('Completed on ${nice(e.completedOn!)}', style: const TextStyle(color: Colors.green)),
              // Section 11: the certificate IS this completion record - a
              // student, Add-on Course, issue date (completedOn) and status
              // already exist; this just presents them as a certificate
              // instead of duplicating a separate certificates module.
              if (e.status == 'completed' && e.completedOn != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.verified, size: 18),
                    label: const Text('View Certificate'),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Certificate of Completion'),
                        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('This certifies that', style: TextStyle(color: Colors.black54)),
                          Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                          const SizedBox(height: 6),
                          Text('has successfully completed the Add-on Course'),
                          Text(c?.name ?? 'Add-on Course #${e.courseId}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          Text('Issue date: ${nice(e.completedOn!)}'),
                          const Text('Status: Issued', style: TextStyle(color: Colors.green)),
                        ]),
                        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                      ),
                    ),
                  ),
                ),
              if (e.status == 'in_progress' && canSubmit)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ElevatedButton(
                    onPressed: () async {
                      final msg = await submitCourseCompletionRemote(e);
                      if (context.mounted && msg != null) toast(context, msg);
                    },
                    child: const Text('Submit for completion approval'),
                  ),
                ),
              if (e.status == 'awaiting_approval' && canDecide)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    ElevatedButton(
                      onPressed: () async {
                        final msg = await decideCourseCompletionRemote(s, e, true);
                        if (context.mounted && msg != null) toast(context, msg);
                      },
                      child: const Text('Approve'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final r = await askText(context, 'Reason for rejection');
                        if (r == null) return;
                        final msg = await decideCourseCompletionRemote(s, e, false, reason: r);
                        if (context.mounted && msg != null) toast(context, msg);
                      },
                      child: const Text('Reject'),
                    ),
                  ]),
                ),
              if (e.status == 'awaiting_approval' && !canDecide) const Text('Waiting for Admin / Super Admin approval.', style: TextStyle(color: Colors.black54, fontSize: 12)),
            ]),
          ),
        );
      }),
    ]);
  }
}

// ---------------- Master Data Management (Super Admin / Admin) ----------------
// Each independently-selectable section of Master Data - drives both which
// tile MasterDataDashboard shows and which part of this same screen that
// tile opens. `null` on MasterDataView.sections (the Teacher "Classes &
// Books" tab's case) means "show everything this role is allowed to see",
// same as before this screen was split into a sub-dashboard.
enum MasterDataSection { maktab, superTools, classes, teachers, maktabAdmins, committee, usersRoles, addonCourses }

class MasterDataView extends StatefulWidget {
  const MasterDataView({super.key, this.sections});
  final Set<MasterDataSection>? sections;
  @override
  State<MasterDataView> createState() => _MasterDataViewState();
}

class _MasterDataViewState extends State<MasterDataView> {
  bool _show(MasterDataSection s) => widget.sections == null || widget.sections!.contains(s);
  final madrasaName = TextEditingController();
  String? newMadrasaCategory;
  final courseName = TextEditingController();
  final courseDesc = TextEditingController();
  final courseCode = TextEditingController();
  final className = TextEditingController();
  final classBookName = TextEditingController();
  final classTotalPages = TextEditingController();
  bool classPageBased = true;
  // One "add Para" page-count field per class, created on first use.
  final Map<int, TextEditingController> paraPageCountCtrl = {};
  TextEditingController _paraCtrl(int cls) => paraPageCountCtrl.putIfAbsent(cls, () => TextEditingController());
  bool paraBusy = false;
  // One "add Book" set of fields per class (Book Management, Class 4+).
  final Map<int, TextEditingController> bookNameCtrl = {};
  final Map<int, TextEditingController> bookDescCtrl = {};
  final Map<int, TextEditingController> bookPagesCtrl = {};
  final Map<int, TextEditingController> bookSeqCtrl = {};
  TextEditingController _bookCtrl(Map<int, TextEditingController> m, int cls) => m.putIfAbsent(cls, () => TextEditingController());
  bool bookBusy = false;
  final teacherName = TextEditingController();
  final teacherPhone = TextEditingController();
  final Set<String> teacherMadrasasSel = {};
  final adminName = TextEditingController();
  final adminPhone = TextEditingController();
  String? adminMadrasa;
  final committeeName = TextEditingController();
  final committeePhone = TextEditingController();
  String? committeeMadrasa;
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    // Toggling a switch below updates `st` (the shared app state) and
    // calls notifyListeners(), but this screen's own setState() is only
    // triggered by the Add buttons - without this AnimatedBuilder the
    // switch's real new value only became visible once something else
    // (like clicking Add Madrasa) happened to force a rebuild, which is
    // exactly the delayed-toggle behavior that was reported.
    // Shared by Super Admin/Maktab Admin (full Master Data) and Teacher
    // (reused here just for Classes/Books/Add-on Courses - requirement 3).
    // Maktab, Teacher/Admin invites, Committee Members and Roles stay
    // admin/super only, same access they've always had.
    final u = st.user;
    final canManageOrg = u?.role == 'admin' || u?.role == 'super';
    final isSuper = u?.role == 'super';
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) => page([
      if (canManageOrg && _show(MasterDataSection.maktab)) ...[
      h('Maktab', icon: Icons.account_balance),
      ...st.madrasas.map((m) => Card(
            child: SwitchListTile(
              title: Row(children: [
                Expanded(child: Text(m.name)),
                InkWell(
                  onTap: () async {
                    final n = await askText(context, 'Rename Maktab', initial: m.name);
                    if (n == null) return;
                    final e = await renameMadrasaRemote(m, n);
                    if (context.mounted && e != null) toast(context, e);
                  },
                  child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit, size: 16, color: Colors.black45)),
                ),
              ]),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.active ? 'Active - shown in registration dropdown' : 'Deactivated - hidden from new registrations'),
                const SizedBox(height: 4),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('Category: ${m.category ?? 'Not set'}', style: TextStyle(color: m.category == null ? Colors.orange.shade800 : Colors.black87, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () async {
                      final picked = await showDialog<String>(
                        context: context,
                        builder: (ctx) => SimpleDialog(
                          title: const Text('Maktab Category'),
                          children: [
                            for (final c in kMadrasaCategories)
                              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, c), child: Text(c)),
                          ],
                        ),
                      );
                      if (picked == null) return;
                      final e = await setMadrasaCategoryRemote(m, picked);
                      if (context.mounted && e != null) toast(context, e);
                    },
                    child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit, size: 14, color: Colors.black45)),
                  ),
                ]),
              ]),
              value: m.active,
              onChanged: (v) async {
                if (!v) {
                  final ok = await confirmDialog(context, 'Deactivate ${m.name}?', 'It will be hidden from the registration dropdown and from being newly assigned - existing students/teachers already there are not removed. You can reactivate it later.', confirmLabel: 'Deactivate');
                  if (!ok) return;
                  if (!context.mounted) return;
                }
                final e = await setMadrasaActiveRemote(m, v);
                if (!mounted) return;
                if (e != null) toast(context, e);
              },
            ),
          )),
      field(madrasaName, 'New Maktab name'),
      DropdownButtonFormField<String>(
        value: newMadrasaCategory,
        decoration: const InputDecoration(labelText: 'Maktab Category (required)'),
        items: [for (final c in kMadrasaCategories) DropdownMenuItem(value: c, child: Text(c))],
        onChanged: (v) => setState(() => newMadrasaCategory = v),
      ),
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                final e = await addMadrasaRemote(madrasaName.text, newMadrasaCategory);
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Maktab added. It now appears in the registration dropdown.');
                if (e == null) {
                  madrasaName.clear();
                  setState(() => newMadrasaCategory = null);
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add Maktab'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.history),
        label: const Text('Event / Holiday history (all Makatib)'),
        onPressed: () => pushPage(context, 'Event / Holiday history', const EventHistoryView()),
      ),
      ], // end canManageOrg (Maktab)
      if (isSuper && _show(MasterDataSection.superTools)) ...[
        h('Super Admin Tools', icon: Icons.admin_panel_settings),
        OutlinedButton.icon(
          icon: const Icon(Icons.info_outline),
          label: const Text('About Us Management'),
          onPressed: () => pushPage(context, 'About Us Management', const AboutUsManagementView()),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.campaign),
          label: const Text('Notification Template Management'),
          onPressed: () => pushPage(context, 'Notification Templates', const NotifTemplateListView()),
        ),
      ], // end isSuper (Super Admin Tools)
      if (_show(MasterDataSection.classes)) ...[
      h('Classes', icon: Icons.menu_book),
      const Text(
        'Classes 1-3 (Noorani Qaeda, Muallimul Qur\'an Qaeda, Hafeezi Qur\'an) are fixed: they cannot be renamed, deleted, or have their book/Para details changed. Class creation and editing is only open from Class 4 onward.',
        style: TextStyle(fontSize: 11.5, color: Colors.black54),
      ),
      const SizedBox(height: 6),
      ...st.classDefs.values.map((cd) => Card(
            child: Column(children: [
              SwitchListTile(
                title: Row(children: [
                  Expanded(child: Text(cd.isCore ? '${cd.name}  (fixed)' : cd.name)),
                  // Requirement 2/3: Classes 1-3 are fixed - no rename, no
                  // book-detail edit, by any role, for any reason.
                  if (!cd.isCore)
                    InkWell(
                      onTap: () async {
                        final n = await askText(context, 'Rename class', initial: cd.name);
                        if (n == null) return;
                        final e = await renameClassRemote(cd, n);
                        if (context.mounted && e != null) toast(context, e);
                      },
                      child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit, size: 16, color: Colors.black45)),
                    ),
                  // Requirement 1: edit an EXISTING class's book details, not
                  // just its name - previously only rename was possible after
                  // a page-based class was created.
                  if (!cd.isCore && cd.pageBased)
                    InkWell(
                      onTap: () async {
                        final bn = await askText(context, 'Book name', initial: cd.bookName ?? '');
                        if (bn == null) return;
                        if (!context.mounted) return;
                        int? tp;
                        if (cd.paras.isEmpty) {
                          final tpText = await askText(context, 'Total pages', initial: '${cd.totalPages}');
                          if (tpText == null) return;
                          tp = int.tryParse(tpText.trim());
                        }
                        if (!context.mounted) return;
                        final e = await updateClassDetailsRemote(cd, bookName: bn, totalPages: tp);
                        if (context.mounted && e != null) toast(context, e);
                      },
                      child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.menu_book, size: 16, color: Colors.black45)),
                    ),
                ]),
                subtitle: Text(cd.pageBased
                    ? 'Book: ${cd.bookName} - ${cd.totalPages} pages${cd.paras.isNotEmpty ? ' (${cd.paras.length} Para)' : ''}${cd.active ? '' : ' - Deactivated'}'
                    : 'Chapter-based${cd.active ? '' : ' - Deactivated'}'),
                value: cd.active,
                onChanged: (v) async {
                  if (!v) {
                    final ok = await confirmDialog(context, 'Deactivate ${cd.name}?', 'Students already in this class are not removed, but it can no longer be newly assigned to a student or teacher. You can reactivate it later.', confirmLabel: 'Deactivate');
                    if (!ok) return;
                    if (!context.mounted) return;
                  }
                  final e = await setClassActiveRemote(cd, v);
                  if (!mounted) return;
                  if (e != null) toast(context, e);
                },
              ),
              // Para (Juz) only ever applies to Class 3 - Hafeezi Qur'an.
              // Every other class (1, 2, or anything created from Class 4
              // onward, page-based or not) never shows the Para controls -
              // backed server-side by fn_restrict_para_to_hafizi, this is
              // just keeping the UI from offering what the database would
              // reject anyway.
              if (cd.id == 3) _paraSection(cd),
              if (!cd.isCore) _bookSection(cd),
              // Course-class assignment stays admin/super only for now
              // (same RLS as before this change) - a teacher reaching this
              // screen via the new "Classes & Books" tab sees Classes and
              // Books, not course assignment.
              if (canManageOrg) _classCourseSection(cd),
            ]),
          )),
      field(className, 'New class name (e.g. Class 5 - ...)'),
      Row(children: [
        Checkbox(value: classPageBased, onChanged: (v) => setState(() => classPageBased = v ?? true)),
        const Expanded(child: Text('Page-based (has a book with a page count). Leave unchecked for a chapter-based class.')),
      ]),
      if (classPageBased) ...[
        field(classBookName, 'Book name'),
        field(classTotalPages, 'Total pages', number: true),
      ],
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                final e = await addClassRemote(
                  className.text,
                  pageBased: classPageBased,
                  bookName: classBookName.text,
                  totalPages: int.tryParse(classTotalPages.text.trim()) ?? 0,
                );
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Class added.');
                if (e == null) {
                  className.clear();
                  classBookName.clear();
                  classTotalPages.clear();
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add Class'),
      ),
      ], // end _show(classes)
      if (canManageOrg && _show(MasterDataSection.teachers)) ...[
      h('Teachers', icon: Icons.groups),
      if (st.teacherAccounts.isEmpty) const Text('No teachers yet.', style: TextStyle(color: Colors.black54)),
      ...st.teacherAccounts.map((t) => Card(
            child: t.pending
                ? ListTile(
                    title: Text(t.name),
                    subtitle: Text('${t.phone} - ${t.teachMadrasas.join(', ')} - Invited, waiting for first login'),
                    // Requirement: Super Admin can update a teacher's detail
                    // (name/phone/Makatib), which Master Data previously had
                    // no way to do once a teacher was added - only edit this
                    // directly (not via the real account path), so a
                    // still-pending invite is editable too.
                    trailing: isSuper
                        ? InkWell(onTap: () => editTeacherDialog(context, t), child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit, size: 18, color: Colors.black45)))
                        : const Icon(Icons.hourglass_empty, color: Colors.black38),
                  )
                : SwitchListTile(
                    title: Row(children: [
                      Expanded(child: Text(t.name)),
                      if (isSuper)
                        InkWell(
                          onTap: () => editTeacherDialog(context, t),
                          child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit, size: 16, color: Colors.black45)),
                        ),
                    ]),
                    subtitle: Text('${t.phone} - ${t.teachMadrasas.join(', ')}'),
                    value: t.active,
                    onChanged: (v) async {
                      if (!v) {
                        final ok = await confirmDialog(context, 'Deactivate ${t.name}?', 'They will no longer be able to sign in. Their account and history are kept, and a Super Admin can reactivate them later.', confirmLabel: 'Deactivate');
                        if (!ok) return;
                        if (!context.mounted) return;
                      }
                      final e = await setTeacherActiveRemote(t, v);
                      if (!mounted) return;
                      if (e != null) toast(context, e);
                    },
                  ),
          )),
      field(teacherName, 'New teacher name'),
      field(teacherPhone, 'Mobile number (10 digits)', number: true),
      const Padding(padding: EdgeInsets.only(top: 4, bottom: 4), child: Text('Makatib this teacher will teach in:', style: TextStyle(color: Colors.black54, fontSize: 12.5))),
      Wrap(spacing: 4, children: [
        for (final m in st.activeMadrasaNames)
          FilterChip(
            label: Text(m),
            selected: teacherMadrasasSel.contains(m),
            onSelected: (v) => setState(() => v ? teacherMadrasasSel.add(m) : teacherMadrasasSel.remove(m)),
          ),
      ]),
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                final e = await addTeacherInviteRemote(teacherName.text, teacherPhone.text, teacherMadrasasSel.toList());
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Teacher created. They can log in now with an OTP on that number.');
                if (e == null) {
                  teacherName.clear();
                  teacherPhone.clear();
                  setState(() => teacherMadrasasSel.clear());
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Invite Teacher'),
      ),
      ], // end canManageOrg && _show(teachers)
      if (canManageOrg && _show(MasterDataSection.maktabAdmins)) ...[
      h('Maktab Admins', icon: Icons.admin_panel_settings),
      const Text('Invites a Maktab Admin for one Maktab. This list only shows who you invite this session - open Roles & Permissions below to see everyone with access.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
      field(adminName, 'New Maktab Admin name'),
      field(adminPhone, 'Mobile number (10 digits)', number: true),
      DropdownButtonFormField<String>(
        value: adminMadrasa,
        decoration: const InputDecoration(labelText: 'Maktab', border: OutlineInputBorder()),
        items: [for (final m in st.activeMadrasaNames) DropdownMenuItem<String>(value: m, child: Text(m))],
        onChanged: (v) => setState(() => adminMadrasa = v),
      ),
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                if (adminMadrasa == null) {
                  toast(context, 'Choose a Maktab');
                  return;
                }
                setState(() => busy = true);
                final e = await addRoleInviteRemote(name: adminName.text, phone: adminPhone.text, dbRole: 'madrasa_admin', madrasaNames: [adminMadrasa!]);
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Maktab Admin invited.');
                if (e == null) {
                  adminName.clear();
                  adminPhone.clear();
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Invite Maktab Admin'),
      ),
      ], // end canManageOrg && _show(maktabAdmins)
      if (canManageOrg && _show(MasterDataSection.committee)) ...[
      h('Committee Members', icon: Icons.diversity_3),
      field(committeeName, 'New Committee Member name'),
      field(committeePhone, 'Mobile number (10 digits)', number: true),
      DropdownButtonFormField<String>(
        value: committeeMadrasa,
        decoration: const InputDecoration(labelText: 'Maktab', border: OutlineInputBorder()),
        items: [for (final m in st.activeMadrasaNames) DropdownMenuItem<String>(value: m, child: Text(m))],
        onChanged: (v) => setState(() => committeeMadrasa = v),
      ),
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                if (committeeMadrasa == null) {
                  toast(context, 'Choose a Maktab');
                  return;
                }
                setState(() => busy = true);
                final e = await addRoleInviteRemote(name: committeeName.text, phone: committeePhone.text, dbRole: 'committee', madrasaNames: [committeeMadrasa!]);
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Committee Member invited.');
                if (e == null) {
                  committeeName.clear();
                  committeePhone.clear();
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Invite Committee Member'),
      ),
      ], // end canManageOrg && _show(committee)
      if (canManageOrg && _show(MasterDataSection.usersRoles)) ...[
      h('Users and Roles', icon: Icons.admin_panel_settings),
      ElevatedButton.icon(
        onPressed: () => pushPage(context, 'Roles & Permissions', const RolesView()),
        icon: const Icon(Icons.admin_panel_settings),
        label: const Text('Open Roles & Permissions'),
      ),
      ], // end canManageOrg && _show(usersRoles)
      if (canManageOrg && _show(MasterDataSection.addonCourses)) ...[
      h('Add-on Courses', icon: Icons.auto_stories),
      const Text('Status (Active/Inactive) controls whether a course can be newly assigned - deactivating one does not remove it from classes/students already assigned to it.',
          style: TextStyle(fontSize: 11.5, color: Colors.black54)),
      const SizedBox(height: 6),
      ...st.courses.map((c) => Card(
            child: Column(children: [
              SwitchListTile(
                title: Row(children: [
                  Expanded(child: Text(c.code.isEmpty ? c.name : '${c.name}  (${c.code})')),
                  InkWell(
                    onTap: () async {
                      final n = await askText(context, 'Rename Add-on Course', initial: c.name);
                      if (n == null) return;
                      if (!context.mounted) return;
                      final d = await askText(context, 'Description (optional)', initial: c.description);
                      if (d == null) return;
                      if (!context.mounted) return;
                      final code = await askText(context, 'Course Code / ID (optional)', initial: c.code);
                      if (code == null) return;
                      final e = await renameCourseRemote(c, n, d, code: code);
                      if (context.mounted && e != null) toast(context, e);
                    },
                    child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit, size: 16, color: Colors.black45)),
                  ),
                ]),
                subtitle: Text(c.description.isEmpty ? 'No description' : c.description),
                value: c.active,
                onChanged: (v) async {
                  if (!v) {
                    final ok = await confirmDialog(context, 'Deactivate ${c.name}?', 'It can no longer be newly assigned to a class - students/classes already assigned to it are not affected. You can reactivate it later.', confirmLabel: 'Deactivate');
                    if (!ok) return;
                    if (!context.mounted) return;
                  }
                  final e = await setCourseActiveRemote(c, v);
                  if (!mounted) return;
                  if (e != null) toast(context, e);
                },
              ),
              // Requirement 2: which classes this course is assigned to -
              // every assignment is mandatory (requirement 3), so there is
              // no separate "mandatory?" toggle to set here.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Assigned to classes:', style: TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final cd in st.classDefs.values)
                      FilterChip(
                        label: Text(cd.name),
                        selected: st.courseAssignedToClass(cd.id, c.id),
                        onSelected: (sel) async {
                          if (!sel) {
                            final ok = await confirmDialog(context, 'Unassign ${c.name} from ${cd.name}?', 'This Add-on Course will no longer be required for ${cd.name}\'s students. Students already tracking progress on it keep that history.', confirmLabel: 'Unassign');
                            if (!ok) return;
                            if (!context.mounted) return;
                          }
                          final e = sel ? await assignCourseToClassRemote(cd, c) : await unassignCourseFromClassRemote(cd, c);
                          if (context.mounted && e != null) toast(context, e);
                        },
                      ),
                  ]),
                ]),
              ),
            ]),
          )),
      field(courseName, 'New Add-on Course name'),
      field(courseDesc, 'Add-on Course description (optional)', lines: 2),
      field(courseCode, 'Course Code / ID (optional)'),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                final e = await addCourseRemote(courseName.text, courseDesc.text, code: courseCode.text);
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Add-on Course added. Assign it to a class above to make it required for that class\'s students.');
                if (e == null) {
                  courseName.clear();
                  courseDesc.clear();
                  courseCode.clear();
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add Add-on Course'),
      ),
      ], // end canManageOrg && _show(addonCourses)
      ]),
    );
  }

  // Mandatory Add-on Courses assigned to one class, shown under its switch
  // tile - a reverse view of the FilterChip grid in the Add-on Courses
  // section above (both edit the same class_course_assignments data), kept
  // here too so assigning a course doesn't require scrolling all the way
  // down to find it while looking at a specific class.
  Widget _classCourseSection(ClassDef cd) {
    final assigned = st.coursesForClass(cd.id);
    final unassigned = st.courses.where((c) => c.active && !assigned.any((a) => a.id == c.id)).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Mandatory Add-on Courses for this class:', style: TextStyle(fontSize: 12, color: Colors.black54)),
        const SizedBox(height: 4),
        if (assigned.isEmpty) const Text('None assigned yet.', style: TextStyle(fontSize: 12, color: Colors.black38)),
        if (assigned.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in assigned)
                InputChip(
                  label: Text(c.name),
                  onDeleted: () async {
                    final ok = await confirmDialog(context, 'Unassign ${c.name} from ${cd.name}?', 'This Add-on Course will no longer be required for ${cd.name}\'s students. Students already tracking progress on it keep that history.', confirmLabel: 'Unassign');
                    if (!ok) return;
                    if (!context.mounted) return;
                    final e = await unassignCourseFromClassRemote(cd, c);
                    if (context.mounted && e != null) toast(context, e);
                  },
                ),
            ],
          ),
        if (unassigned.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in unassigned)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text(c.name),
                  onPressed: () async {
                    final e = await assignCourseToClassRemote(cd, c);
                    if (context.mounted && e != null) toast(context, e);
                  },
                ),
            ],
          ),
        ],
      ]),
    );
  }

  // Para list + add/edit for one page-based class, shown under its switch
  // tile. A Para is a named section of the book (e.g. 1 of 30 Para in a
  // Qur'an) with its own page count - leave empty for a plain flat book.
  Widget _paraSection(ClassDef cd) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (cd.paras.isNotEmpty) ...[
          Text(cd.isCore ? 'Para (fixed at ${cd.paras.length}, cannot be added, edited, or removed):' : 'Para (book split into sections, each with its own page count):',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in cd.paras)
              InputChip(
                label: Text('Para ${p.paraNo}: ${p.pageCount}p'),
                // Requirement 1: Hafizi Qur'an's (and every other core
                // class's) Para are fixed - no add/edit/delete, so the chip
                // becomes a plain non-interactive label once isCore.
                onPressed: cd.isCore
                    ? null
                    : () async {
                        final n = await askText(context, 'Para ${p.paraNo} - page count', initial: '${p.pageCount}');
                        if (n == null) return;
                        final pc = int.tryParse(n.trim());
                        if (pc == null || pc <= 0) {
                          if (context.mounted) toast(context, 'Enter a valid page count');
                          return;
                        }
                        final e = await updateParaPageCountRemote(cd, p, pc);
                        if (context.mounted && e != null) toast(context, e);
                      },
              ),
          ]),
          const SizedBox(height: 6),
          Text('Total: ${cd.totalPages} pages across ${cd.paras.length} Para', style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
        ],
        if (!cd.isCore)
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: TextField(
                controller: _paraCtrl(cd.id),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: cd.paras.isEmpty ? 'Page count for Para 1 (leave all Para unused for a plain flat book)' : 'Page count for Para ${cd.paras.isEmpty ? 1 : cd.paras.map((p) => p.paraNo).reduce((a, b) => a > b ? a : b) + 1}'),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: paraBusy
                  ? null
                  : () async {
                      final pc = int.tryParse(_paraCtrl(cd.id).text.trim());
                      if (pc == null || pc <= 0) {
                        toast(context, 'Enter a valid page count');
                        return;
                      }
                      setState(() => paraBusy = true);
                      final e = await addParaRemote(cd, pc);
                      if (!mounted) return;
                      setState(() => paraBusy = false);
                      toast(context, e ?? 'Para ${cd.paras.last.paraNo} added.');
                      if (e == null) _paraCtrl(cd.id).clear();
                    },
              child: const Text('Add Para'),
            ),
          ]),
      ]),
    );
  }

  // Book Management (Class 4+ only - never shown for a core class, see the
  // `!cd.isCore` guard where this is called): list of Books under this
  // class, each editable (name/description/pages/sequence/active), plus an
  // "Add Book" form. Several Books can exist for the same class (e.g. Class
  // 4 may have Book 1, Book 2, Book 3, all staying associated with it).
  Widget _bookSection(ClassDef cd) {
    final books = List<ClassBook>.from(cd.books)..sort((a, b) => a.sequenceOrder.compareTo(b.sequenceOrder));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Books:', style: TextStyle(fontSize: 12, color: Colors.black54)),
        const SizedBox(height: 4),
        if (books.isEmpty) const Text('No Books added yet.', style: TextStyle(fontSize: 12, color: Colors.black38)),
        ...books.map((b) => Card(
              color: const Color(0xFFF7F7F2),
              child: ListTile(
                dense: true,
                title: Row(children: [
                  Expanded(child: Text('${b.name} - ${b.totalPages}p - seq ${b.sequenceOrder}')),
                  InkWell(
                    onTap: () async {
                      final n = await askText(context, 'Book name', initial: b.name);
                      if (n == null) return;
                      if (!context.mounted) return;
                      final d = await askText(context, 'Description (optional)', initial: b.description);
                      if (d == null) return;
                      if (!context.mounted) return;
                      final pText = await askText(context, 'Total pages', initial: '${b.totalPages}');
                      if (pText == null) return;
                      final p = int.tryParse(pText.trim());
                      if (!context.mounted) return;
                      final sText = await askText(context, 'Display/learning sequence (lower = earlier)', initial: '${b.sequenceOrder}');
                      if (sText == null) return;
                      final seq = int.tryParse(sText.trim());
                      final e = await updateClassBookRemote(b, name: n, description: d, totalPages: p, sequenceOrder: seq);
                      if (context.mounted && e != null) toast(context, e);
                    },
                    child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit, size: 16, color: Colors.black45)),
                  ),
                ]),
                subtitle: Text(b.description.isEmpty ? (b.active ? 'Active' : 'Inactive') : '${b.description} - ${b.active ? 'Active' : 'Inactive'}'),
                trailing: Switch(
                  value: b.active,
                  onChanged: (v) async {
                    if (!v) {
                      final ok = await confirmDialog(context, 'Deactivate ${b.name}?', 'It can no longer be newly assigned to track a student\'s progress - students already on it keep their progress. You can reactivate it later.', confirmLabel: 'Deactivate');
                      if (!ok) return;
                      if (!context.mounted) return;
                    }
                    final e = await setClassBookActiveRemote(b, v);
                    if (context.mounted && e != null) toast(context, e);
                  },
                ),
              ),
            )),
        const SizedBox(height: 6),
        field(_bookCtrl(bookNameCtrl, cd.id), 'New Book name'),
        field(_bookCtrl(bookDescCtrl, cd.id), 'Book description (optional)'),
        Row(children: [
          Expanded(child: field(_bookCtrl(bookPagesCtrl, cd.id), 'Total pages', number: true)),
          const SizedBox(width: 8),
          Expanded(child: field(_bookCtrl(bookSeqCtrl, cd.id), 'Sequence (optional)', number: true)),
        ]),
        ElevatedButton(
          onPressed: bookBusy
              ? null
              : () async {
                  final pages = int.tryParse(_bookCtrl(bookPagesCtrl, cd.id).text.trim()) ?? 0;
                  final seqText = _bookCtrl(bookSeqCtrl, cd.id).text.trim();
                  final seq = seqText.isEmpty ? books.length + 1 : (int.tryParse(seqText) ?? books.length + 1);
                  setState(() => bookBusy = true);
                  final e = await addClassBookRemote(cd, _bookCtrl(bookNameCtrl, cd.id).text, _bookCtrl(bookDescCtrl, cd.id).text, pages, seq);
                  if (!mounted) return;
                  setState(() => bookBusy = false);
                  toast(context, e ?? 'Book added to ${cd.name}.');
                  if (e == null) {
                    _bookCtrl(bookNameCtrl, cd.id).clear();
                    _bookCtrl(bookDescCtrl, cd.id).clear();
                    _bookCtrl(bookPagesCtrl, cd.id).clear();
                    _bookCtrl(bookSeqCtrl, cd.id).clear();
                  }
                },
          child: bookBusy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add Book'),
        ),
      ]),
    );
  }
}

// Master Data as an icon on the dashboard that opens a sub-dashboard of
// selectable sections, instead of one long scrolling screen - each tile
// opens MasterDataView scoped to just that section (MasterDataSection),
// reusing all of that screen's existing logic/state rather than
// duplicating it. Admin and Super Admin both reach this; Super Admin Tools
// only shows for Super Admin, same gating MasterDataView itself always had.
class MasterDataDashboard extends StatelessWidget {
  const MasterDataDashboard({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final u = st.user;
    final canManageOrg = u?.role == 'admin' || u?.role == 'super';
    final isSuper = u?.role == 'super';
    Widget sectionTile(String label, IconData icon, String value, MasterDataSection section) => tile(
          label,
          value,
          icon: icon,
          onTap: () => pushPage(context, label, MasterDataView(sections: {section})),
        );
    return page([
      h('Master Data', icon: Icons.storage),
      const Text('Pick what to manage.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
      const SizedBox(height: 8),
      grid([
        if (canManageOrg) sectionTile('Maktab', Icons.account_balance, '${st.madrasas.length}', MasterDataSection.maktab),
        sectionTile('Classes & Books', Icons.menu_book, '${st.classDefs.length}', MasterDataSection.classes),
        if (canManageOrg) sectionTile('Teachers', Icons.groups, '${st.teacherAccounts.where((t) => !t.pending).length}', MasterDataSection.teachers),
        if (canManageOrg) sectionTile('Maktab Admins', Icons.admin_panel_settings, 'Invite', MasterDataSection.maktabAdmins),
        if (canManageOrg) sectionTile('Committee Members', Icons.diversity_3, 'Invite', MasterDataSection.committee),
        if (canManageOrg) sectionTile('Users and Roles', Icons.admin_panel_settings, 'Permissions', MasterDataSection.usersRoles),
        if (canManageOrg) sectionTile('Add-on Courses', Icons.auto_stories, '${st.courses.length}', MasterDataSection.addonCourses),
        if (isSuper) sectionTile('Super Admin Tools', Icons.settings_suggest, 'About Us, Notifications', MasterDataSection.superTools),
      ]),
    ]);
  }
}

// ---------------- Course completion approvals (Teacher / Admin / Super Admin) ----------------
class CourseApprovalsView extends StatelessWidget {
  const CourseApprovalsView({super.key});
  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    final canDecide = u.role == 'admin' || u.role == 'super';
    final rows = <Widget>[];
    for (final s in st.students.where((s) => s.status == 'Active')) {
      final pending = st.enrollmentsFor(s).where((e) => e.status == 'awaiting_approval').toList();
      for (final e in pending) {
        final c = st.courseById(e.courseId);
        rows.add(Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s.name} - ${c?.name ?? 'Add-on Course'}', style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('${s.madrasa} - ${st.className(s.cls)} - submitted by ${e.submittedBy ?? 'teacher'}'),
              if (canDecide)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    ElevatedButton(
                      onPressed: () async {
                        final msg = await decideCourseCompletionRemote(s, e, true);
                        if (context.mounted && msg != null) toast(context, msg);
                      },
                      child: const Text('Approve'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final r = await askText(context, 'Reason for rejection');
                        if (r == null) return;
                        final msg = await decideCourseCompletionRemote(s, e, false, reason: r);
                        if (context.mounted && msg != null) toast(context, msg);
                      },
                      child: const Text('Reject'),
                    ),
                  ]),
                )
              else
                const Text('Waiting for Admin / Super Admin to approve.', style: TextStyle(color: Colors.black54, fontSize: 12)),
            ]),
          ),
        ));
      }
    }
    return page([
      h('Add-on Course completion requests', icon: Icons.verified),
      const Text('Teachers submit an add-on course as complete for a student here; Admin or Super Admin approves or rejects it. Approved courses show a green "Completed" badge in the Add-on Courses tab and the Parent Add-on Course Progress tab.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
      const SizedBox(height: 8),
      if (rows.isEmpty) const Text('Nothing is waiting for approval right now.'),
      ...rows,
    ]);
  }
}

// ---------------- Fee QR code and monthly reminder log (Super Admin) ----------------
class FeeQrAdmin extends StatefulWidget {
  const FeeQrAdmin({super.key});
  @override
  State<FeeQrAdmin> createState() => _FeeQrAdminState();
}

class _FeeQrAdminState extends State<FeeQrAdmin> {
  final qr = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return page([
      h('Fee payment QR code', icon: Icons.qr_code),
      Card(
        child: ListTile(
          leading: const Icon(Icons.qr_code_2),
          title: Text(st.feeQrPath ?? 'No QR code uploaded yet'),
          subtitle: const Text('This QR code is attached to every monthly WhatsApp fee reminder.'),
        ),
      ),
      field(qr, 'QR code file name (demo - real upload needs a storage connection)'),
      ElevatedButton.icon(
        onPressed: () {
          final e = st.uploadFeeQr(qr.text);
          toast(context, e);
        },
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload / replace QR code'),
      ),
      h('Monthly fee reminder (1st of every month)', icon: Icons.payments),
      const Text(
        'This runs automatically on the 1st once a real WhatsApp Business API provider (for example MSG91) is configured per the migration plan. Use the button below to simulate one run now.',
        style: TextStyle(color: Colors.black54, fontSize: 12.5),
      ),
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: () {
          final n = st.sendMonthlyFeeReminders();
          toast(context, '$n reminder(s) logged below.');
        },
        child: const Text('Run reminder now (demo)'),
      ),
      h('Reminder log'),
      if (st.feeReminderLog.isEmpty) const Text('No reminders sent yet.'),
      ...st.feeReminderLog.reversed.map((l) => Card(child: ListTile(title: Text(l, style: const TextStyle(fontSize: 12.5))))),
      h('Absence WhatsApp log'),
      if (st.whatsappLog.isEmpty) const Text('No absence notifications sent yet.'),
      ...st.whatsappLog.reversed.map((l) => Card(child: ListTile(title: Text(l, style: const TextStyle(fontSize: 12.5))))),
    ]);
  }
}

// ---------------- Super Admin: Notifications screen (public.admin_notifications) ----------------
//
// Lists every missing-attendance / configuration-missing alert the nightly
// 11 PM job (and the on-demand resolve called from loadAdminNotifications)
// has produced. Read-status taps call markAdminNotificationRead/
// markAllAdminNotificationsRead (local state first for an instant UI
// update, then the real update()). Nothing here is ever deleted - a
// notification that's since been fixed just shows status Resolved.

String _niceAttendanceDate(String ymd) {
  const months = ['', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  final parts = ymd.split('-');
  if (parts.length != 3) return ymd;
  final y = parts[0];
  final m = int.tryParse(parts[1]) ?? 0;
  final d = int.tryParse(parts[2]) ?? 0;
  if (m < 1 || m > 12) return ymd;
  return '$d ${months[m]} $y';
}

String _niceGeneratedAt(DateTime dt) {
  final local = dt.toLocal();
  final h24 = local.hour;
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  final mm = local.minute.toString().padLeft(2, '0');
  return '${_niceAttendanceDate('${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}')} at $h12:$mm $ampm';
}

class AdminNotificationsScreen extends StatefulWidget {
  const AdminNotificationsScreen({super.key});
  @override
  State<AdminNotificationsScreen> createState() => _AdminNotificationsScreenState();
}

class _AdminNotificationsScreenState extends State<AdminNotificationsScreen> {
  bool _unreadOnly = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) {
        final all = st.adminNotifications;
        final shown = _unreadOnly ? all.where((n) => !n.isRead).toList() : all;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: kGreen,
            foregroundColor: Colors.white,
            title: const Text('Notifications'),
            actions: [
              if (all.any((n) => !n.isRead))
                TextButton(
                  onPressed: () => markAllAdminNotificationsRead(),
                  child: const Text('Mark all read', style: TextStyle(color: Colors.white)),
                ),
            ],
          ),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                ChoiceChip(label: const Text('All'), selected: !_unreadOnly, onSelected: (_) => setState(() => _unreadOnly = false)),
                const SizedBox(width: 8),
                ChoiceChip(label: const Text('Unread'), selected: _unreadOnly, onSelected: (_) => setState(() => _unreadOnly = true)),
              ]),
            ),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        _unreadOnly ? 'No unread notifications.' : 'No notifications yet.',
                        style: const TextStyle(color: Colors.black54),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: loadAdminNotifications,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final n = shown[i];
                          final resolved = n.status == 'Resolved';
                          return Card(
                            color: n.isRead ? null : const Color(0xFFFFF8E1),
                            child: ListTile(
                              leading: Icon(
                                resolved ? Icons.check_circle : Icons.error_outline,
                                color: resolved ? Colors.green : (n.isRead ? Colors.black45 : const Color(0xFFC62828)),
                              ),
                              title: Text(
                                n.title,
                                style: TextStyle(fontWeight: n.isRead ? FontWeight.normal : FontWeight.bold),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(n.message),
                                  const SizedBox(height: 4),
                                  Wrap(spacing: 6, runSpacing: 2, children: [
                                    Text(n.madrasaName, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                    if (n.category != null) Text('• ${n.category}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                    if (n.className != null) Text('• ${n.className}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                    if (n.batch != null) Text('• ${n.batch}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                    Text('• ${_niceAttendanceDate(n.attendanceDate)}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                  ]),
                                  Text(
                                    'Teacher: ${n.teacherName ?? 'Not assigned'}',
                                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                                  ),
                                  Text(
                                    'Generated: ${_niceGeneratedAt(n.createdAt)}',
                                    style: const TextStyle(fontSize: 11, color: Colors.black38),
                                  ),
                                  if (resolved) const Text('Resolved', style: TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.bold)),
                                ]),
                              ),
                              isThreeLine: true,
                              trailing: n.isRead ? null : const Icon(Icons.circle, size: 10, color: Color(0xFFC62828)),
                              onTap: n.isRead ? null : () => markAdminNotificationRead(n.id),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ]),
        );
      },
    );
  }
}
