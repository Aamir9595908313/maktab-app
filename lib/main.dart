import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'state.dart';
import 'guest_tools.dart';
import 'supabase_config.dart';

final AppState st = AppState();
const Color kGreen = Color(0xFF054D00);
const Color kGold = Color(0xFFD4A72C);

SupabaseClient get sb => Supabase.instance.client;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
    (profile['phone'] as String?) ?? '',
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
        MadrasaRec((r['name'] as String?) ?? '', active: (r['is_active'] as bool?) ?? true, dbId: r['id'] as String?),
    ]);

    final courseRows = await sb.from('courses').select().order('name');
    var i = 1;
    st.setCoursesFromDb([
      for (final r in (courseRows as List))
        Course(
          i++,
          (r['name'] as String?) ?? '',
          (r['description'] as String?) ?? '',
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
    await loadAttendance();
    await loadSyllabusProgress();
    await loadMyTeacherAttendance();
    await loadAllTeacherAttendanceToday();
    await loadComplaints();
    await loadCustomRoles();
    await loadCommitteeMembers();
    await loadFees();
    await loadAnnouncements();
    await loadLeaves();
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
    'students',
    'teacher_class_assignments',
    'user_profiles',
    'pending_role_invites',
    'student_attendance',
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

// Final Submit: marks every row final (is_draft=false) in the database,
// same as before locally updating each student's absent list and sending
// the WhatsApp alert simulation, then returns the absence count exactly as
// the old purely-local version did so the UI/toast text is unchanged.
Future<int> submitAttRemote(List<Student> list) async {
  final rows = [
    for (final s in list)
      if (s.status == 'Active' && s.dbId != null)
        {
          'student_id': s.dbId,
          'madrasa_id': _madrasaDbId(s.madrasa),
          'class_id': _classDbId(s.cls),
          'attendance_date': kToday,
          'status': (st.todayAtt[s.id] ?? 'P') == 'A' ? 'absent' : 'present',
          'is_draft': false,
          'final_submitted_by': sb.auth.currentUser?.id,
          'final_submitted_at': DateTime.now().toIso8601String(),
        },
  ];
  if (rows.isNotEmpty) {
    try {
      await sb.from('student_attendance').upsert(rows, onConflict: 'student_id,attendance_date');
    } catch (_) {
      // Local side effects (below) still happen so the teacher isn't
      // blocked; the rows just didn't make it to the database this time.
    }
  }
  return st.submitAtt(list);
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
    final rows = await sb.from('fees_monthly').select('student_id, month, status').eq('year', 2026).eq('status', 'complete');
    final monthNameByNo = {for (final e in AppState.monthNo.entries) e.value: e.key};
    final byStudent = <int, Set<String>>{};
    for (final r in (rows as List)) {
      final s = idByDbId[r['student_id'] as String?];
      if (s == null) continue;
      final mn = monthNameByNo[r['month'] as int?];
      if (mn == null) continue;
      byStudent.putIfAbsent(s.id, () => {}).add(mn);
    }
    st.setPaidFromDb(byStudent);
  } catch (_) {
    // Not every role can see fees (RLS) - the screen just shows nothing
    // marked paid instead of erroring.
  }
}

Future<String> payRemote(Student s, String m) async {
  final msg = st.pay(s, m);
  final monthNo = AppState.monthNo[m];
  if (s.dbId != null && monthNo != null) {
    try {
      final row = await sb.from('fees_monthly').upsert({
        'student_id': s.dbId,
        'year': 2026,
        'month': monthNo,
        'amount_due': 200,
        'amount_paid': 200,
        'status': 'complete',
      }, onConflict: 'student_id,year,month').select().single();
      await sb.from('receipts').insert({
        'receipt_no': 'R-2026-${st.receiptNo}',
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

// Gives someone a custom role the same way Teacher/Admin/Committee invites
// already work: a pending_role_invites row (base_role='custom', plus the
// role's id) that the handle_new_auth_user trigger turns into a real
// account - with the right custom_role_id and madrasa scope - the moment
// that phone number signs in with OTP.
Future<String?> assignRoleRemote(String phone, String name, String roleName, List<String> branches) async {
  final p = digits(phone);
  if (p.length != 10) return 'Enter a 10-digit mobile number';
  if (name.trim().isEmpty) return 'Enter the name';
  if (roleName.isEmpty) return 'Choose a role';
  if (branches.isEmpty) return 'Choose at least one Maktab';
  try {
    final roleRow = await sb.from('roles').select('id').eq('name', roleName).maybeSingle();
    if (roleRow == null) return 'That role was not found - try Create role again.';
    await sb.from('pending_role_invites').upsert({
      'phone': '91$p',
      'base_role': 'custom',
      'full_name': name.trim(),
      'madrasa_names': branches,
      'custom_role_id': roleRow['id'],
    });
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
    final details = e.details;
    final msg = (details is Map ? details['error'] as String? : null);
    return msg ?? 'Could not save: ${e.reasonPhrase ?? e.toString()}';
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
Future<String?> addMadrasaRemote(String name) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a Maktab name';
  if (st.madrasas.any((m) => m.name.toLowerCase() == n.toLowerCase())) return 'This Maktab already exists';
  try {
    final row = await sb.from('madrasas').insert({'name': n}).select().single();
    st.addMadrasa(n, dbId: row['id'] as String?);
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

// Same pattern as addMadrasaRemote, for public.courses.
Future<String?> addCourseRemote(String name, String description) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter an Add-on Course name';
  try {
    final row = await sb.from('courses').insert({'name': n, 'description': description.trim()}).select().single();
    st.addCourse(n, description, dbId: row['id'] as String?);
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

Future<String?> renameCourseRemote(Course c, String name, String description) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter an Add-on Course name';
  if (c.dbId == null) return 'This Add-on Course was not saved to the database yet.';
  try {
    await sb.from('courses').update({'name': n, 'description': description.trim()}).eq('id', c.dbId as Object);
    st.renameCourse(c, n, description: description.trim());
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
      title: 'Maktab E Tajushshriah',
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
            builder: (c, _) => st.user == null ? const GuestHome() : const Shell(),
          );
        },
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
// an actual way to get there, not just a static stat card.
Widget tile(String label, String value, {Color? color, VoidCallback? onTap, IconData? icon}) {
  final card = Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
        Row(children: [
          if (icon != null) ...[
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: kGreen.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 16, color: kGreen),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54))),
          if (onTap != null) const Icon(Icons.chevron_right, size: 14, color: Colors.black38),
        ]),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
      ]),
    ),
  );
  if (onTap == null) return card;
  return InkWell(borderRadius: BorderRadius.circular(4), onTap: onTap, child: card);
}

Widget grid(List<Widget> tiles) => GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.1,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      children: tiles,
    );

Widget h(String t, {IconData? icon}) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
      child: Row(children: [
        if (icon != null) ...[Icon(icon, size: 18, color: kGreen), const SizedBox(width: 6)],
        Expanded(child: Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: kGreen))),
      ]),
    );

Widget page(List<Widget> children) => ListView(padding: const EdgeInsets.all(14), children: children);

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
      setState(() {
        busy = false;
        err = e.message;
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
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 6),
            const Text('Maktab-e-Tajushshariah', style: TextStyle(color: kGreen, fontSize: 23, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
            const SizedBox(height: 4),
            const Text('Powered by Faiz-E-Raza Group Mehkar', style: TextStyle(color: Colors.black54, fontSize: 13), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Center(child: Image.asset('assets/logo.png', height: 84)),
            const SizedBox(height: 24),
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
              Center(child: TextButton(onPressed: busy ? null : () => setState(() => step2 = false), child: const Text('Change number'))),
            ],
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 10),
            const Text('No login needed for these tools:', style: TextStyle(color: Colors.black54), textAlign: TextAlign.center),
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _bottomIcon(context, Icons.fingerprint, 'Tasbeeh', () => openTool(context, const TasbeehScreen())),
              _bottomIcon(context, Icons.explore, 'Qibla Direction', () => openTool(context, const QiblaScreen())),
              _bottomIcon(context, Icons.calendar_month, 'Islamic Calendar', () => openTool(context, const CalendarScreen())),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _bottomIcon(BuildContext context, IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(40),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(children: [
            CircleAvatar(radius: 26, backgroundColor: const Color(0xFFEEF4E8), child: Icon(icon, color: kGreen)),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 11.5), textAlign: TextAlign.center),
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
        AppTab('Syllabus', Icons.menu_book, () => const TeacherSyllabus()),
        AppTab('Students & Promotion', Icons.school, () => const StudentsView()),
        AppTab('Add-on Course Progress', Icons.verified, () => const CourseApprovalsView()),
        AppTab('Complaints', Icons.report_problem, () => const ComplaintsView()),
      ];
    case 'admin':
      return [
        AppTab('Home', Icons.home, () => const StaffHome()),
        AppTab('Master Data', Icons.storage, () => const MasterDataView()),
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
        AppTab('Master Data', Icons.storage, () => const MasterDataView()),
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
                const Text('Maktab E Tajushshriah', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
            const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('No-login tools', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54, fontSize: 12))),
            ListTile(leading: const Icon(Icons.explore), title: const Text('Qibla Direction'), onTap: () { Navigator.pop(context); openTool(context, const QiblaScreen()); }),
            ListTile(leading: const Icon(Icons.calendar_month), title: const Text('Calendar'), onTap: () { Navigator.pop(context); openTool(context, const CalendarScreen()); }),
            ListTile(leading: const Icon(Icons.fingerprint), title: const Text('Tasbeeh Counter'), onTap: () { Navigator.pop(context); openTool(context, const TasbeehScreen()); }),
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

class KidHome extends StatelessWidget {
  const KidHome({super.key});
  @override
  Widget build(BuildContext context) {
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
  Widget build(BuildContext context) {
    final k = st.currentKid();
    if (k == null) return page([const Text('No child is linked to this number.')]);
    return page([
      KidPicker(),
      h('Attendance - ${k.name}', icon: Icons.event_available),
      grid([tile('Attendance Sep', '${st.attPct(k)}%'), tile('Absent days', '${k.absent.length}')]),
      h('Absent days'),
      if (k.absent.isEmpty) const Text('None'),
      ...k.absent.map((d) => Card(child: ListTile(leading: const Icon(Icons.cancel, color: Colors.red), title: Text(nice(d))))),
    ]);
  }
}

class KidSyllabus extends StatelessWidget {
  const KidSyllabus({super.key});
  @override
  Widget build(BuildContext context) {
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
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 6, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 1),
        itemCount: cd.totalPages,
        itemBuilder: (context, i) {
          final pageNo = i + 1;
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
              child: Text('$pageNo', style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          );
        },
      ),
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
    ]);
  }

  void _showPageInfo(BuildContext context, int pageNo) {
    final date = s.pageDate[pageNo];
    final grade = s.pageGrade[pageNo] ?? '';
    toast(context, 'Page $pageNo: Completed ${date != null ? nice(date) : ''} - $grade');
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
    ]);
  }
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
  Widget build(BuildContext context) {
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
              title: Text('$m 2026'),
              subtitle: Text(st.isPaid(k.id, m) ? 'Paid - month complete' : 'Due Rs. 200 by 10 $m'),
            ),
          )),
    ]);
  }
}

class KidCourseProgress extends StatelessWidget {
  const KidCourseProgress({super.key});
  @override
  Widget build(BuildContext context) {
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
  Widget build(BuildContext context) {
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
  Widget build(BuildContext context) => RotationTransition(turns: _c, child: Image.asset('assets/logo.png', height: 96));
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
          tile('Makatib', '${st.madrasas.length}', icon: Icons.account_balance, onTap: () => pushPage(context, 'Makatib', const MasterDataView())),
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
        ...st.announcements.where((a) => a.active).map((a) => Card(child: ListTile(title: Text(a.title), subtitle: Text(a.msg), trailing: TextButton(onPressed: () => withdrawAnnouncementRemote(a), child: const Text('Withdraw'))))),
      ]);
    }
    if (u.role == 'admin') {
      final present = st.teacherAtt.values.where((v) => v.startsWith('Present')).length;
      final onLeave = st.teacherAtt.values.where((v) => v == 'On leave').length;
      // Was hardcoded to "Hanfi" only - now scoped to whichever madrasa(s)
      // this admin actually manages (u.branches, loaded for real from
      // public.user_madrasa_scope at login).
      final myStudentsActive = st.students.where((s) => u.branches.contains(s.madrasa) && s.status == 'Active').toList();
      return page([
        banner(),
        grid([
          tile('Search', 'Phone, name, Maktab', icon: Icons.search, onTap: () => pushPage(context, 'Search', const GlobalSearchView())),
          tile('Students', '${myStudentsActive.length}', icon: Icons.groups, onTap: () => pushPage(context, 'Students', const StudentsView())),
          tile('Teachers today', '$present present, $onLeave on leave', icon: Icons.co_present, onTap: () => pushPage(context, 'Teachers & Leave', const TeachersView())),
          tile('Pending registrations', '${st.pending.length}', icon: Icons.how_to_reg, onTap: () => pushPage(context, 'Pending Registrations', const ApprovalsView())),
          tile('Leave requests', '$pendingLeave pending', icon: Icons.event_busy, onTap: () => pushPage(context, 'Teachers & Leave', const TeachersView())),
          tile('Fees Sep', '${myStudentsActive.where((s) => st.isPaid(s.id, 'Sep')).length} of ${myStudentsActive.where((s) => st.feeMonths(s).contains('Sep')).length} complete', icon: Icons.payments, onTap: () => pushPage(context, 'Fees', const FeesAdmin())),
          tile('Complaints open', '$open', icon: Icons.report_problem, onTap: () => pushPage(context, 'Complaints', const ComplaintsView())),
        ]),
        h('Ready to promote'),
        Text('${st.students.where((s) => st.eligible(s)).length} student(s)'),
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
        tile('Ready to promote', '${st.students.where((s) => st.eligible(s)).length}', icon: Icons.trending_up, onTap: () => pushPage(context, 'Students & Promotion', const StudentsView())),
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

class StudentAttendanceMark extends StatelessWidget {
  const StudentAttendanceMark({super.key});
  @override
  Widget build(BuildContext context) =>
      // Own AnimatedBuilder: without this, tapping Present/Absent updated
      // st.todayAtt (and saved fine) but the button never visually
      // reflected it - a const StatelessWidget returned from a bottom tab
      // is the same canonical widget instance every rebuild, so Flutter's
      // element diffing skips calling build() again unless the widget
      // listens for changes itself (same fix already applied to
      // TeacherSelf/MyDayView for the same reason).
      AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    // Deactivated students never appear here, so they can't be marked and never get an alert.
    final list = st.myStudents().where((s) => s.status == 'Active').toList();
    // Same class can run more than one session a day (e.g. Morning and
    // Evening batches) - grouping by batch keeps the roster the teacher is
    // physically looking at distinct from students due in at another time,
    // so nobody gets lost in one undifferentiated list.
    final groups = <String, List<Student>>{for (final b in kBatches) b: []};
    for (final s in list) {
      (groups[kBatches.contains(s.batch) ? s.batch : 'Morning'] ??= []).add(s);
    }
    Widget studentTile(Student s) {
      final v = st.todayAtt[s.id] ?? 'P';
      final cd = st.classDefs[s.cls]!;
      // Lets the teacher log today's syllabus page/chapter right here while
      // marking attendance, instead of having to leave this screen and find
      // the student again in the separate Syllabus tab. Reuses the same
      // markPageDialog/tickChapterDialog already used there, so progress
      // logged here shows up identically in Syllabus.
      Widget progressRow;
      if (cd.pageBased) {
        final cur = st.currentPageNo(s);
        progressRow = cur == null
            ? const Text('All pages complete', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.green))
            : Row(children: [
                Text('Page $cur of ${cd.totalPages}', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.black87)),
                IconButton(
                  icon: const Icon(Icons.add_circle, size: 24, color: kGreen),
                  tooltip: 'Mark page $cur complete',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => markPageDialog(context, s, cur),
                ),
              ]);
      } else {
        final plan = st.chapterPlan(s);
        var nextIdx = -1;
        for (var i = 0; i < plan.length; i++) {
          if (plan[i].done == null) {
            nextIdx = i;
            break;
          }
        }
        progressRow = nextIdx == -1
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
      return Card(
        child: ListTile(
          title: Text(s.name),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(st.className(s.cls)),
            progressRow,
          ]),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(backgroundColor: v == 'P' ? Colors.green : null, foregroundColor: v == 'P' ? Colors.white : Colors.green),
              onPressed: () => setAttRemote(s, 'P'),
              child: const Text('Present'),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              style: OutlinedButton.styleFrom(backgroundColor: v == 'A' ? Colors.red : null, foregroundColor: v == 'A' ? Colors.white : Colors.red),
              onPressed: () => setAttRemote(s, 'A'),
              child: const Text('Absent'),
            ),
          ]),
        ),
      );
    }

    return page([
      h('Mark attendance - ${st.teacherMadrasa} - ${nice(kToday)}', icon: Icons.event_available),
      const Text(
        'Tap Present or Absent, then Final Submit for that batch once its session is over. Each batch has its own Final Submit - submitting Morning never touches Afternoon or Evening, so a batch whose session hasn\'t happened yet is left alone instead of being marked. Absent students\' parents get a WhatsApp alert only after that batch\'s Final Submit.',
        style: TextStyle(color: Colors.black54, fontSize: 12.5),
      ),
      const SizedBox(height: 8),
      for (final b in kBatches)
        if (groups[b]!.isNotEmpty) ...[
          h('$b batch (${groups[b]!.length})'),
          ...groups[b]!.map(studentTile),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton(
              onPressed: () async {
                final n = await submitAttRemote(groups[b]!);
                if (context.mounted) {
                  toast(context, '$b batch Final Submitted. $n absence WhatsApp alert(s) sent to parents.');
                }
              },
              child: Text('Final Submit - $b batch'),
            ),
          ),
          const SizedBox(height: 16),
        ],
    ]);
  }
}

class TeacherSyllabus extends StatelessWidget {
  const TeacherSyllabus({super.key});
  @override
  Widget build(BuildContext context) {
    final list = st.myStudents();
    return page([
      h('Choose a student - ${st.teacherMadrasa}'),
      ...list.map((s) {
        final p = progFor(s);
        final cd = st.classDefs[s.cls]!;
        return Card(
          child: ListTile(
            title: Text(s.name),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${cd.name} - start ${nice(s.start)} - ${p.label ?? '${p.n}/${p.total}'}'),
              LinearProgressIndicator(value: p.pct / 100),
            ]),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text(s.name), backgroundColor: kGreen, foregroundColor: Colors.white),
                  body: AnimatedBuilder(animation: st, builder: (c, _) => SyllabusBody(s: s, edit: true)),
                ),
              ),
            ),
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
      const Text('Classes 1-3: eligible once every page of the book is Completed. Class 4+: eligible once every chapter is Completed.'),
      if (ready.isEmpty) const Text('No student is eligible yet. Mark pages/chapters complete in Syllabus.'),
      ...ready.map((s) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('${st.className(s.cls)} - eligible to pass'),
                const SizedBox(height: 6),
                ElevatedButton(
                  onPressed: () async {
                    final msg = await promoteRemote(s);
                    if (context.mounted) toast(context, msg);
                  },
                  child: const Text('Mark Passed and Promote'),
                ),
              ]),
            ),
          )),
      h('Students - ${u.role == 'teacher' ? st.teacherMadrasa : 'Hanfi'}'),
      // Actions used to sit in the ListTile's trailing column, which has a
      // fixed height - two or three buttons there overflowed it ("BOTTOM
      // OVERFLOWED BY 16 PIXELS"). Moved below the tile in a Wrap instead,
      // which has no fixed height and just adds a row (or wraps to a
      // second one) no matter how many buttons end up there.
      ...list.map((s) => Card(
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
          )),
    ]);
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
    return page([
      h('Fees (month-wise)', icon: Icons.payments),
      grid([for (final m in ['Jun', 'Jul', 'Aug', 'Sep']) tile('$m 2026', '${list.where((s) => st.isPaid(s.id, m)).length} of ${list.where((s) => st.feeMonths(s).contains(m)).length} complete')]),
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
      h('Give role to a person', icon: Icons.admin_panel_settings),
      field(aPhone, 'Mobile number', number: true),
      field(aName, 'Name'),
      DropdownButtonFormField<String>(
        value: pick,
        decoration: const InputDecoration(labelText: 'Role', border: OutlineInputBorder()),
        items: [for (final n in names) DropdownMenuItem<String>(value: n, child: Text(n))],
        onChanged: (v) => setState(() => pick = v),
      ),
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
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                final e = await assignRoleRemote(digits(aPhone.text), aName.text, pick ?? '', branches.toList());
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Role given. That person now sees only the ticked screens, the moment they log in with OTP.');
                if (e == null) {
                  aPhone.clear();
                  aName.clear();
                  setState(() {
                    pick = null;
                    branches.clear();
                  });
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Assign role'),
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
  const StudentDetail({super.key, required this.s});
  @override
  Widget build(BuildContext context) {
    final cd = st.classDefs[s.cls]!;
    final p = progFor(s);
    return DefaultTabController(
      length: 6,
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
          page([
            if (cd.pageBased)
              ...List.generate(cd.totalPages, (i) {
                final pageNo = i + 1;
                final status = st.pageStatus(s, pageNo);
                return Card(
                  child: ListTile(
                    title: Text('Page $pageNo'),
                    subtitle: Text(status == 'Completed' ? 'Completed ${nice(s.pageDate[pageNo]!)} - ${s.pageGrade[pageNo] ?? ''}' : status),
                  ),
                );
              })
            else
              ...List.generate(st.chapterPlan(s).length, (i) {
                final c = st.chapterPlan(s)[i];
                return Card(child: ListTile(title: Text('${i + 1}. ${c.title}'), subtitle: Text(c.done != null ? 'Completed ${nice(c.done!)} - ${c.grade}' : 'Not completed. Plan ${nice(c.plan)}')));
              }),
          ]),
          page([
            // Only this app-tracked month has a real number behind it; the
            // other months and the "Monthly Test" card below were
            // fabricated sample figures with no data model backing them -
            // replaced with an honest "not recorded" note rather than
            // invented statistics (see the dashboard-stats fix for the
            // same issue elsewhere).
            Card(child: ListTile(title: Text('This month: ${st.attPct(s)}%'), subtitle: const Text('Attendance - prior months not tracked yet'))),
          ]),
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
    return page([
      if (canSubmit) ...[
        const Text('Assign an Add-on Course to this student:', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final c in st.courses.where((c) => c.active && !enrollments.any((e) => e.courseId == c.id)))
              ActionChip(label: Text(c.name), onPressed: () => st.enrollCourse(s, c.id)),
          ],
        ),
        const SizedBox(height: 12),
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
                Padding(padding: const EdgeInsets.only(top: 6), child: ElevatedButton(onPressed: () => st.submitCourseCompletion(e), child: const Text('Submit for completion approval'))),
              if (e.status == 'awaiting_approval' && canDecide)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    ElevatedButton(onPressed: () => st.decideCourseCompletion(s, e, true), child: const Text('Approve')),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final r = await askText(context, 'Reason for rejection');
                        if (r != null) st.decideCourseCompletion(s, e, false, reason: r);
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
class MasterDataView extends StatefulWidget {
  const MasterDataView({super.key});
  @override
  State<MasterDataView> createState() => _MasterDataViewState();
}

class _MasterDataViewState extends State<MasterDataView> {
  final madrasaName = TextEditingController();
  final courseName = TextEditingController();
  final courseDesc = TextEditingController();
  final className = TextEditingController();
  final classBookName = TextEditingController();
  final classTotalPages = TextEditingController();
  bool classPageBased = true;
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
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) => page([
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
              subtitle: Text(m.active ? 'Active - shown in registration dropdown' : 'Deactivated - hidden from new registrations'),
              value: m.active,
              onChanged: (v) async {
                final e = await setMadrasaActiveRemote(m, v);
                if (!mounted) return;
                if (e != null) toast(context, e);
              },
            ),
          )),
      field(madrasaName, 'New Maktab name'),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                final e = await addMadrasaRemote(madrasaName.text);
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Maktab added. It now appears in the registration dropdown.');
                if (e == null) madrasaName.clear();
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add Maktab'),
      ),
      h('Classes', icon: Icons.menu_book),
      ...st.classDefs.values.map((cd) => Card(
            child: SwitchListTile(
              title: Row(children: [
                Expanded(child: Text(cd.name)),
                InkWell(
                  onTap: () async {
                    final n = await askText(context, 'Rename class', initial: cd.name);
                    if (n == null) return;
                    final e = await renameClassRemote(cd, n);
                    if (context.mounted && e != null) toast(context, e);
                  },
                  child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit, size: 16, color: Colors.black45)),
                ),
              ]),
              subtitle: Text(cd.pageBased ? 'Book: ${cd.bookName} - ${cd.totalPages} pages${cd.active ? '' : ' - Deactivated'}' : 'Chapter-based${cd.active ? '' : ' - Deactivated'}'),
              value: cd.active,
              onChanged: (v) async {
                final e = await setClassActiveRemote(cd, v);
                if (!mounted) return;
                if (e != null) toast(context, e);
              },
            ),
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
      h('Teachers', icon: Icons.groups),
      if (st.teacherAccounts.isEmpty) const Text('No teachers yet.', style: TextStyle(color: Colors.black54)),
      ...st.teacherAccounts.map((t) => Card(
            child: t.pending
                ? ListTile(
                    title: Text(t.name),
                    subtitle: Text('${t.phone} - ${t.teachMadrasas.join(', ')} - Invited, waiting for first login'),
                    trailing: const Icon(Icons.hourglass_empty, color: Colors.black38),
                  )
                : SwitchListTile(
                    title: Text(t.name),
                    subtitle: Text('${t.phone} - ${t.teachMadrasas.join(', ')}'),
                    value: t.active,
                    onChanged: (v) async {
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
      h('Users and Roles', icon: Icons.admin_panel_settings),
      ElevatedButton.icon(
        onPressed: () => pushPage(context, 'Roles & Permissions', const RolesView()),
        icon: const Icon(Icons.admin_panel_settings),
        label: const Text('Open Roles & Permissions'),
      ),
      h('Add-on Courses', icon: Icons.auto_stories),
      ...st.courses.map((c) => Card(
            child: SwitchListTile(
              title: Row(children: [
                Expanded(child: Text(c.name)),
                InkWell(
                  onTap: () async {
                    final n = await askText(context, 'Rename Add-on Course', initial: c.name);
                    if (n == null) return;
                    if (!context.mounted) return;
                    final d = await askText(context, 'Description (optional)', initial: c.description);
                    if (d == null) return;
                    final e = await renameCourseRemote(c, n, d);
                    if (context.mounted && e != null) toast(context, e);
                  },
                  child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit, size: 16, color: Colors.black45)),
                ),
              ]),
              subtitle: Text(c.description.isEmpty ? 'No description' : c.description),
              value: c.active,
              onChanged: (v) async {
                final e = await setCourseActiveRemote(c, v);
                if (!mounted) return;
                if (e != null) toast(context, e);
              },
            ),
          )),
      field(courseName, 'New Add-on Course name'),
      field(courseDesc, 'Add-on Course description (optional)', lines: 2),
      ElevatedButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                final e = await addCourseRemote(courseName.text, courseDesc.text);
                if (!mounted) return;
                setState(() => busy = false);
                toast(context, e ?? 'Add-on Course added. It can now be assigned from any student\'s Add-on Courses tab.');
                if (e == null) {
                  courseName.clear();
                  courseDesc.clear();
                }
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add Add-on Course'),
      ),
      ]),
    );
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
                    ElevatedButton(onPressed: () => st.decideCourseCompletion(s, e, true), child: const Text('Approve')),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final r = await askText(context, 'Reason for rejection');
                        if (r != null) st.decideCourseCompletion(s, e, false, reason: r);
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
