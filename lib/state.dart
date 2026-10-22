import 'package:flutter/material.dart';

const String kToday = '2026-09-19';
const List<String> kMon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const List<String> kBranches = ['Hanfi', 'Jama', 'Khwajapiya', 'Bagwanpura'];

DateTime pd(String s) => DateTime.parse('${s}T00:00:00Z');
String fd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String addDays(String s, int n) => fd(pd(s).add(Duration(days: n)));
int diffDays(String a, String b) => pd(a).difference(pd(b)).inDays;
String nice(String s) {
  final d = pd(s);
  return '${d.day} ${kMon[d.month - 1]} ${d.year}';
}

bool validDate(String s) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return false;
  try {
    pd(s);
    return true;
  } catch (_) {
    return false;
  }
}

// ---------------- class / syllabus model ----------------
class Chapter {
  String title;
  int days;
  Chapter(this.title, this.days);
}

class ClassDef {
  final int id;
  final String name;
  final bool pageBased;
  final String? bookName;
  int totalPages;
  final int paceDays; // expected days per page, page-based classes only
  bool active;
  // The matching row's id in Supabase public.classes, once this record has
  // been loaded from (or successfully saved to) the real database. Null
  // means this is still local-only demo data that hasn't been synced.
  String? dbId;
  ClassDef(this.id, this.name, {this.pageBased = false, this.bookName, this.totalPages = 0, this.paceDays = 2, this.active = true, this.dbId});
}

class Student {
  int id;
  String key;
  String name;
  String gender;
  int cls;
  String madrasa;
  String start;
  String parentPhone;
  String studentPhone;
  bool aadhaar;
  String address;
  String status;
  // page-based progress (Classes 1-3): pageNo -> date / grade / remark
  Map<int, String> pageDate;
  Map<int, String> pageGrade;
  // chapter-based progress (Class 4+): chapterIndex -> date / grade
  Map<int, String> chDate;
  Map<int, String> chGrade;
  List<String> absent;
  List<String> history;
  Student({
    required this.id,
    required this.key,
    required this.name,
    required this.gender,
    required this.cls,
    required this.start,
    required this.parentPhone,
    this.madrasa = 'Hanfi',
    this.studentPhone = '',
    this.aadhaar = true,
    this.address = '',
    this.status = 'Active',
    Map<int, String>? pageDate,
    Map<int, String>? pageGrade,
    Map<int, String>? chDate,
    Map<int, String>? chGrade,
    List<String>? absent,
    List<String>? history,
  })  : pageDate = pageDate ?? {},
        pageGrade = pageGrade ?? {},
        chDate = chDate ?? {},
        chGrade = chGrade ?? {},
        absent = absent ?? [],
        history = history ?? [];
}

class Prog {
  final int n;
  final int total;
  final int behind; // days, 0 = on pace / on track
  final String? label; // for page-based: "Page 14 of 32"
  Prog(this.n, this.total, this.behind, {this.label});
  int get pct => total == 0 ? 0 : (n * 100 / total).round();
}

class Account {
  String phone;
  String name;
  String role;
  String roleName;
  List<String> branches; // committee / custom role scope
  List<String> teachMadrasas; // teacher: madrasas they teach in
  bool active;
  Account(this.phone, this.name, this.role, {this.roleName = '', List<String>? branches, List<String>? teachMadrasas, this.active = true})
      : branches = branches ?? [],
        teachMadrasas = teachMadrasas ?? [];
}

// ---------------- master data: madrasas / courses ----------------
class MadrasaRec {
  String name;
  bool active;
  // The matching row's id in Supabase public.madrasas, once this record has
  // been loaded from (or successfully saved to) the real database. Null
  // means this is still local-only demo data that hasn't been synced -
  // Supabase calls in main.dart use this to know which row to update.
  String? dbId;
  MadrasaRec(this.name, {this.active = true, this.dbId});
}

class Course {
  final int id;
  String name;
  String description;
  bool active;
  // Same purpose as MadrasaRec.dbId above, for public.courses.
  String? dbId;
  Course(this.id, this.name, this.description, {this.active = true, this.dbId});
}

// status: in_progress, awaiting_approval, completed
class CourseEnrollment {
  final int courseId;
  final int studentId;
  String status;
  String? completedOn;
  String? submittedBy;
  String? approvedBy;
  String? rejectReason;
  CourseEnrollment(this.courseId, this.studentId, {this.status = 'in_progress', this.completedOn});
}

class Note {
  String phone;
  String text;
  Note(this.phone, this.text);
}

class Pending {
  String name;
  String gender;
  int cls;
  String parentPhone;
  bool aadhaar;
  Pending(this.name, this.gender, this.cls, this.parentPhone, this.aadhaar);
}

class Complaint {
  int id;
  String phone;
  String by;
  String to;
  String subject;
  String text;
  String status = 'Submitted';
  List<String> replies = [];
  Complaint(this.id, this.phone, this.by, this.to, this.subject, this.text);
}

class Leave {
  int id;
  String teacher;
  String type;
  String from;
  String to;
  String reason;
  String status = 'Pending';
  String remark = '';
  String by = '';
  Leave(this.id, this.teacher, this.type, this.from, this.to, this.reason);
}

class Announcement {
  String title;
  String msg;
  String priority;
  bool active = true;
  Announcement(this.title, this.msg, this.priority);
}

class ReportRow {
  final String name;
  final String period;
  final String madrasa;
  final String created;
  const ReportRow(this.name, this.period, this.madrasa, this.created);
}

class DayEntry {
  final String time;
  final String madrasa;
  final int cls;
  const DayEntry(this.time, this.madrasa, this.cls);
}

String roleLabel(Account u) {
  switch (u.role) {
    case 'super':
      return 'Super Admin';
    case 'admin':
      return 'Madrasa Admin (Hanfi)';
    case 'teacher':
      return 'Teacher';
    case 'parent':
      return 'Parent';
    case 'student':
      return 'Student';
    case 'committee':
      return 'Working Committee';
    default:
      return u.roleName;
  }
}

class AppState extends ChangeNotifier {
  Account? user;
  int? kidId;
  bool studentView = false;
  int nextId = 46;
  int receiptNo = 200;
  String teacherMadrasa = 'Hanfi'; // currently selected madrasa for a multi-madrasa teacher

  final Map<String, Account> users = {
    '9800000001': Account('9800000001', 'Faiz Raza', 'super'),
    '9800000101': Account('9800000101', 'Imam Abdul Kareem', 'admin'),
    '9800000201': Account('9800000201', 'Ustaad Salman', 'teacher', teachMadrasas: ['Hanfi', 'Jama']),
    '9800000301': Account('9800000301', 'Mohd Rashid', 'parent'),
    '9800000302': Account('9800000302', 'Shabana Bano', 'parent'),
    '9800000401': Account('9800000401', 'Zainab Rashid', 'student'),
    '9800000501': Account('9800000501', 'Fatima Bibi', 'custom', roleName: 'Accountant', branches: ['Hanfi']),
    '9800000601': Account('9800000601', 'Haji Anwar Khan', 'committee', branches: ['Hanfi', 'Jama']),
  };

  final Map<String, Set<String>> customRoles = {
    'Accountant': {'Fees', 'Reports'},
  };

  // ---------- master data: madrasas ----------
  // Seeded with the same demo branches so the app still looks right before
  // Supabase data has loaded (or if it can't load). setMadrasasFromDb()
  // below replaces this list wholesale once the real data arrives.
  final List<MadrasaRec> madrasas = [for (final b in kBranches) MadrasaRec(b)];
  List<String> get activeMadrasaNames => madrasas.where((m) => m.active).map((m) => m.name).toList();

  // Replaces the whole list with what was just loaded from Supabase
  // (public.madrasas). Called after login and after a manual refresh.
  void setMadrasasFromDb(List<MadrasaRec> list) {
    madrasas
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  // Local-only add (used as a fallback, and by setMadrasasFromDb's caller
  // pattern before this round existed). Prefer addMadrasaRemote in
  // main.dart, which writes to Supabase first and then calls this with the
  // new row's dbId so the local list and the database agree.
  String? addMadrasa(String name, {String? dbId}) {
    final n = name.trim();
    if (n.isEmpty) return 'Enter a Madrasa / Branch name';
    if (madrasas.any((m) => m.name.toLowerCase() == n.toLowerCase())) return 'This Madrasa already exists';
    madrasas.add(MadrasaRec(n, dbId: dbId));
    notifyListeners();
    return null;
  }

  void setMadrasaActive(MadrasaRec m, bool v) {
    m.active = v;
    notifyListeners();
  }

  // ---------- master data: courses ----------
  int nextCourseId = 3;
  final List<Course> courses = [
    Course(1, 'Hifz Preparatory Batch', 'Extra memorisation practice for advanced students'),
    Course(2, 'Qaida Revision Workshop', 'Short revision course for students who need extra practice'),
  ];

  Course? courseById(int id) {
    for (final c in courses) {
      if (c.id == id) return c;
    }
    return null;
  }

  // Replaces the whole list with what was just loaded from Supabase
  // (public.courses). Local integer ids are reassigned sequentially since
  // course_enrollments (still in-memory/demo until a later round) key off
  // them, not off the database uuid.
  void setCoursesFromDb(List<Course> list) {
    courses
      ..clear()
      ..addAll(list);
    nextCourseId = (courses.map((c) => c.id).fold(0, (a, b) => a > b ? a : b)) + 1;
    notifyListeners();
  }

  String? addCourse(String name, String description, {String? dbId}) {
    final n = name.trim();
    if (n.isEmpty) return 'Enter a course name';
    courses.add(Course(nextCourseId++, n, description.trim(), dbId: dbId));
    notifyListeners();
    return null;
  }

  void setCourseActive(Course c, bool v) {
    c.active = v;
    notifyListeners();
  }

  // ---------- course enrollments / completion approval ----------
  final List<CourseEnrollment> courseEnrollments = [
    CourseEnrollment(1, 41, status: 'completed', completedOn: '2026-08-20'),
    CourseEnrollment(2, 41, status: 'in_progress'),
    CourseEnrollment(2, 42, status: 'awaiting_approval'),
  ];

  List<CourseEnrollment> enrollmentsFor(Student s) => courseEnrollments.where((e) => e.studentId == s.id).toList();

  String? enrollCourse(Student s, int courseId) {
    if (courseEnrollments.any((e) => e.studentId == s.id && e.courseId == courseId)) return 'Already assigned to this student';
    courseEnrollments.add(CourseEnrollment(courseId, s.id));
    notifyListeners();
    return null;
  }

  void submitCourseCompletion(CourseEnrollment e) {
    e.status = 'awaiting_approval';
    e.submittedBy = user?.name;
    notifyListeners();
  }

  void decideCourseCompletion(Student s, CourseEnrollment e, bool approve, {String reason = ''}) {
    if (approve) {
      e.status = 'completed';
      e.completedOn = kToday;
      e.approvedBy = user?.name;
      final c = courseById(e.courseId);
      notes.add(Note(s.parentPhone, '${c?.name ?? 'Course'} marked Completed for ${s.name} on ${nice(kToday)}.'));
    } else {
      e.status = 'in_progress';
      e.rejectReason = reason;
    }
    notifyListeners();
  }

  // Classes 1-3 are book/page based; Class 4 is chapter based (Deeniyat)
  final Map<int, ClassDef> classDefs = {
    1: ClassDef(1, 'Class 1 - Noorani Qaeda', pageBased: true, bookName: 'Noorani Qaeda', totalPages: 32),
    2: ClassDef(2, "Class 2 - Muallimul Qur'an Qaeda", pageBased: true, bookName: "Muallimul Qur'an Qaeda", totalPages: 40),
    3: ClassDef(3, "Class 3 - Hafeezi Qur'an", pageBased: true, bookName: "Hafeezi Qur'an", totalPages: 40),
    4: ClassDef(4, 'Class 4 - Deeniyat', pageBased: false),
  };
  final Map<int, List<Chapter>> chapters = {
    4: [Chapter('Namaz basics', 30), Chapter('Duas', 30)],
  };

  // Replaces classDefs wholesale with what was just loaded from Supabase
  // (public.classes), keyed by the same class_no the rest of the app
  // already uses as the map key (student.cls, promotion logic, etc).
  void setClassDefsFromDb(List<ClassDef> list) {
    classDefs.clear();
    for (final cd in list) {
      classDefs[cd.id] = cd;
    }
    notifyListeners();
  }

  void setClassActive(ClassDef cd, bool v) {
    cd.active = v;
    notifyListeners();
  }

  // Which classes a teacher is assigned to, per madrasa
  final Map<String, Map<String, List<int>>> teacherAssignments = {
    'Ustaad Salman': {
      'Hanfi': [1, 4],
      'Jama': [2],
    },
  };

  final List<Student> students = [
    Student(id: 41, key: 'HNF-2026-0041', name: 'Ahmed Rashid', gender: 'Male', cls: 1, start: '2026-06-05', parentPhone: '9800000301', pageDate: {for (var i = 1; i <= 13; i++) i: '2026-0${(6 + i ~/ 10)}-${(5 + i % 28).toString().padLeft(2, '0')}'}, pageGrade: {13: 'Good'}, absent: ['2026-09-12', '2026-09-15']),
    Student(id: 42, key: 'HNF-2026-0042', name: 'Bilal Yusuf', gender: 'Male', cls: 1, start: '2026-08-12', parentPhone: '9800000302', pageDate: {1: '2026-08-14', 2: '2026-08-16', 3: '2026-08-19', 4: '2026-08-22'}, pageGrade: {4: 'Excellent'}),
    Student(id: 43, key: 'HNF-2026-0043', name: 'Yusuf Ali', gender: 'Male', cls: 1, start: '2026-06-05', parentPhone: '9800000303', pageDate: {for (var i = 1; i <= 20; i++) i: '2026-0${(6 + i ~/ 12)}-${(5 + i % 25).toString().padLeft(2, '0')}'}, pageGrade: {20: 'Excellent'}, absent: ['2026-09-08']),
    Student(id: 44, key: 'HNF-2026-0044', name: 'Zainab Rashid', gender: 'Female', cls: 2, start: '2026-08-20', parentPhone: '9800000301', studentPhone: '9800000401'),
    Student(id: 11, key: 'JAM-2026-0011', name: 'Sara Bano', gender: 'Female', cls: 2, start: '2026-07-01', parentPhone: '9800000310', madrasa: 'Jama', pageDate: {1: '2026-07-05', 2: '2026-07-09'}, pageGrade: {2: 'Good'}),
    Student(id: 45, key: 'HNF-2026-0045', name: 'Imran Sheikh', gender: 'Male', cls: 4, start: '2026-06-05', parentPhone: '9800000320', chDate: {0: '2026-07-05'}, chGrade: {0: 'Good'}),
  ];

  final List<Pending> pending = [
    Pending('Hamza Imran', 'Male', 1, '9800000304', true),
    Pending('Sara Imran', 'Female', 1, '9800000305', false),
  ];

  final Map<int, Set<String>> paid = {
    41: {'Jun', 'Jul', 'Aug'},
    42: {'Aug'},
    43: {'Jun', 'Jul', 'Aug', 'Sep'},
    44: {'Aug'},
    11: {'Jul', 'Aug', 'Sep'},
    45: {'Jun', 'Jul', 'Aug'},
  };
  static const Map<String, int> monthNo = {'Jun': 6, 'Jul': 7, 'Aug': 8, 'Sep': 9};

  // ---------- WhatsApp notifications (stub) ----------
  // No real WhatsApp Business API provider is configured yet - sending here
  // only appends a formatted log entry, matching the message template and
  // duplicate-prevention rules the amendment document asked for. Wiring an
  // actual provider (e.g. MSG91/Meta Cloud API) is a backend/Edge Function
  // task for a later phase, once that is approved and paid for separately.
  final List<String> whatsappLog = [];
  final Set<String> _absenceSentKeys = {};

  void _sendAbsenceWhatsApp(Student s, String madrasa, String date) {
    final key = '${s.id}|$date';
    if (_absenceSentKeys.contains(key)) return; // duplicate-prevention
    _absenceSentKeys.add(key);
    whatsappLog.add(
      '[${nice(date)}] To ${s.parentPhone}: "Dear Parent/Guardian, your child ${s.name} was marked absent at $madrasa on ${nice(date)}. Please contact the madarsa if you need any clarification. Thank you."',
    );
  }

  String? feeQrPath; // demo: display name/path only, no real file storage yet
  final List<String> feeReminderLog = [];
  final Set<String> _feeReminderSentKeys = {};

  String uploadFeeQr(String label) {
    if (label.trim().isEmpty) return 'Enter a file name / path for the QR code image';
    feeQrPath = label.trim();
    notifyListeners();
    return 'QR code updated. It will be used in the next monthly reminder run.';
  }

  // Simulates the 1st-of-month run: eligible active students with a due
  // amount get one WhatsApp reminder + QR, never more than one per student
  // per billing month.
  int sendMonthlyFeeReminders() {
    int n = 0;
    for (final s in students.where((s) => s.status == 'Active')) {
      final due = feeMonths(s).where((m) => !isPaid(s.id, m));
      if (due.isEmpty) continue;
      final key = '${s.id}|$kToday';
      if (_feeReminderSentKeys.contains(key)) continue;
      _feeReminderSentKeys.add(key);
      feeReminderLog.add(
        '[${nice(kToday)}] To ${s.parentPhone}: "Dear Parent/Guardian, fee of Rs. 200 for ${due.join(', ')} is due for ${s.name}. QR code: ${feeQrPath ?? 'not uploaded yet'}."',
      );
      n++;
    }
    notifyListeners();
    return n;
  }

  // ---------- student deactivation ----------
  List<Student> activeOnly(List<Student> list) => list.where((s) => s.status == 'Active').toList();

  String deactivateStudent(Student s, String reason) {
    s.status = 'Inactive';
    s.history.add('Deactivated ${nice(kToday)} by ${user?.name ?? ''}${reason.trim().isEmpty ? '' : ': ${reason.trim()}'}');
    notifyListeners();
    return '${s.name} deactivated. Attendance, fee and course history is kept.';
  }

  String reactivateStudent(Student s) {
    s.status = 'Active';
    s.history.add('Reactivated ${nice(kToday)} by ${user?.name ?? ''}');
    notifyListeners();
    return '${s.name} reactivated.';
  }

  final Map<int, String> todayAtt = {};
  final Map<String, String> teacherAtt = {
    'Ustaad Salman': 'Not marked',
    'Ustaad Tariq': 'Present 07:02',
    'Ustaad Hasan': 'Present 07:10',
    'Ustaad Ibrahim': 'Present 07:04',
    'Ustaad Yaqoob': 'On leave',
  };
  final List<Leave> leaves = [];
  final List<Complaint> complaints = [];
  final List<Note> notes = [Note('9800000301', 'Noorani Qaeda page 12 completed for Ahmed on 1 Aug 2026')];
  final List<Announcement> announcements = [Announcement('Madrasa closed on 02-Oct-2026', 'Friday holiday for all madrasas.', 'Important')];
  final List<String> viewLog = [];
  final List<ReportRow> reports = const [
    ReportRow('Daily Student Attendance', '19-09-2026', 'All', '19-09-2026 18:00'),
    ReportRow('Teacher Attendance', '19-09-2026', 'All', '19-09-2026 18:00'),
    ReportRow('Teacher Leave', 'Sep 2026', 'All', '19-09-2026 18:00'),
    ReportRow('Monthly Fees', 'Sep 2026', 'Hanfi', '19-09-2026 18:00'),
    ReportRow('Syllabus Progress', '19-09-2026', 'All', '19-09-2026 18:00'),
    ReportRow('Results', 'Monthly Test Sep 2026', 'Hanfi', '19-09-2026 18:00'),
    ReportRow('Complaints', 'Sep 2026', 'All', '19-09-2026 18:00'),
    ReportRow('Admissions and Promotions', 'Sep 2026', 'All', '19-09-2026 18:00'),
  ];

  // ---------- login ----------
  // Demo-data login (kept for reference / offline testing only - no longer
  // reachable from the UI now that login goes through Supabase OTP).
  void login(String phone) {
    user = users[phone];
    kidId = null;
    studentView = false;
    if (user != null && user!.role == 'teacher') {
      teacherMadrasa = user!.teachMadrasas.isNotEmpty ? user!.teachMadrasas.first : 'Hanfi';
    }
    notifyListeners();
  }

  // Real login: called once Supabase Auth has verified the OTP and the
  // matching user_profiles row (plus madrasa scope) has been loaded and
  // built into an Account by loadSupabaseProfile() in main.dart.
  void loginWithAccount(Account a) {
    user = a;
    kidId = null;
    studentView = false;
    if (a.role == 'teacher') {
      teacherMadrasa = a.teachMadrasas.isNotEmpty ? a.teachMadrasas.first : 'Hanfi';
    }
    notifyListeners();
  }

  void logout() {
    user = null;
    notifyListeners();
  }

  void setTeacherMadrasa(String m) {
    teacherMadrasa = m;
    notifyListeners();
  }

  List<DayEntry> myDay() {
    final u = user;
    if (u == null) return [];
    final a = teacherAssignments[u.name] ?? {};
    final times = ['7:00', '9:00', '11:00', '2:00'];
    final out = <DayEntry>[];
    int t = 0;
    a.forEach((m, list) {
      for (final c in list) {
        out.add(DayEntry(times[t % times.length], m, c));
        t++;
      }
    });
    return out;
  }

  bool get showFees => user != null && user!.role == 'parent' && !studentView;

  List<Student> kids() {
    final u = user;
    if (u == null) return [];
    if (u.role == 'student') return students.where((s) => s.studentPhone == u.phone).toList();
    return students.where((s) => s.parentPhone == u.phone).toList();
  }

  Student? currentKid() {
    final ks = kids();
    if (ks.isEmpty) return null;
    for (final k in ks) {
      if (k.id == kidId) return k;
    }
    return ks.first;
  }

  void selectKid(int id) {
    kidId = id;
    notifyListeners();
  }

  void toggleStudentView() {
    studentView = !studentView;
    notifyListeners();
  }

  String className(int c) => classDefs[c]?.name ?? 'Class $c';
  List<Student> inBranch(String b) => students.where((s) => s.madrasa == b).toList();

  List<Student> myStudents() {
    final u = user;
    if (u == null) return [];
    if (u.role == 'super') return students;
    if (u.role == 'teacher') return inBranch(teacherMadrasa);
    return inBranch('Hanfi');
  }

  // ---------- syllabus: page-based (Classes 1-3) ----------
  int completedPages(Student s) => s.pageDate.length;

  int? currentPageNo(Student s) {
    final cd = classDefs[s.cls]!;
    if (!cd.pageBased) return null;
    final n = completedPages(s) + 1;
    return n <= cd.totalPages ? n : null;
  }

  String pageStatus(Student s, int pageNo) {
    if (s.pageDate.containsKey(pageNo)) return 'Completed';
    if (pageNo == currentPageNo(s)) return 'In progress';
    return 'Pending';
  }

  Prog pageProg(Student s) {
    final cd = classDefs[s.cls]!;
    final n = completedPages(s);
    final expected = (diffDays(kToday, s.start) / cd.paceDays).floor();
    final behind = expected > n ? expected - n : 0;
    final cur = currentPageNo(s);
    return Prog(n, cd.totalPages, behind, label: cur != null ? 'Page $cur of ${cd.totalPages}' : 'All pages complete');
  }

  void markPageComplete(Student s, int pageNo, String date, String grade, String remark) {
    final d = validDate(date) ? date : kToday;
    s.pageDate[pageNo] = d;
    s.pageGrade[pageNo] = grade;
    final cd = classDefs[s.cls]!;
    notes.add(Note(s.parentPhone, '${cd.bookName} page $pageNo completed for ${s.name} on ${nice(d)} - $grade'));
    notifyListeners();
  }

  // ---------- syllabus: chapter-based (Class 4+) ----------
  List<ChapPlan> chapterPlan(Student s) {
    int c = 0;
    final list = <ChapPlan>[];
    final chs = chapters[s.cls] ?? [];
    for (var i = 0; i < chs.length; i++) {
      c += chs[i].days;
      list.add(ChapPlan(chs[i].title, addDays(s.start, c), s.chDate[i], s.chGrade[i] ?? ''));
    }
    return list;
  }

  Prog chapterProg(Student s) {
    final p = chapterPlan(s);
    final n = p.where((x) => x.done != null).length;
    ChapPlan? next;
    for (final x in p) {
      if (x.done == null) {
        next = x;
        break;
      }
    }
    int behind = 0;
    if (next != null) {
      final d = diffDays(kToday, next.plan);
      if (d > 0) behind = d;
    }
    return Prog(n, p.length, behind);
  }

  void tickChapter(Student s, int i, String date, String grade) {
    final d = validDate(date) ? date : kToday;
    s.chDate[i] = d;
    s.chGrade[i] = grade;
    final title = chapters[s.cls]![i].title;
    notes.add(Note(s.parentPhone, 'Chapter ${i + 1} ($title) completed for ${s.name} on ${nice(d)} - $grade'));
    notifyListeners();
  }

  void addChapter(int cls, String title, int days) {
    chapters.putIfAbsent(cls, () => <Chapter>[]).add(Chapter(title, days));
    notifyListeners();
  }

  bool eligible(Student s) {
    if (s.status != 'Active') return false;
    final cd = classDefs[s.cls]!;
    if (cd.pageBased) return cd.totalPages > 0 && completedPages(s) == cd.totalPages;
    final p = chapterProg(s);
    return p.total > 0 && p.n == p.total;
  }

  String promote(Student s) {
    final old = className(s.cls);
    s.history.add('$old: ${nice(s.start)} to ${nice(kToday)} (Passed)');
    if (classDefs.containsKey(s.cls + 1)) {
      s.cls += 1;
      s.start = kToday;
      s.pageDate = {};
      s.pageGrade = {};
      s.chDate = {};
      s.chGrade = {};
      notes.add(Note(s.parentPhone, '${s.name} passed $old and moved to ${className(s.cls)}. Certificate created.'));
      notifyListeners();
      return '${s.name} moved to ${className(s.cls)}. New syllabus starts ${nice(kToday)}.';
    }
    s.status = 'Graduated';
    notes.add(Note(s.parentPhone, '${s.name} passed $old and graduated.'));
    notifyListeners();
    return '${s.name} graduated.';
  }

  // ---------- attendance ----------
  int attPct(Student s) => ((24 - s.absent.length) * 100 / 24).round();

  void setAtt(int id, String v) {
    todayAtt[id] = v;
    notifyListeners();
  }

  int submitAtt(List<Student> list) {
    int n = 0;
    for (final s in list) {
      if (s.status != 'Active') continue; // deactivated students are excluded
      final v = todayAtt[s.id] ?? 'P';
      if (v == 'A') {
        if (!s.absent.contains(kToday)) s.absent.add(kToday);
        notes.add(Note(s.parentPhone, '${s.name} was absent on ${nice(kToday)}'));
        _sendAbsenceWhatsApp(s, s.madrasa, kToday);
        n++;
      } else {
        s.absent.remove(kToday);
      }
    }
    notifyListeners();
    return n;
  }

  void markSelf(String v) {
    final u = user;
    if (u == null) return;
    teacherAtt[u.name] = v == 'Present' ? 'Present 07:05' : 'Absent';
    notifyListeners();
  }

  // ---------- students ----------
  String? addStudent({required String name, required String gender, required int cls, required String parentPhone, String studentPhone = '', required bool aadhaar, String address = '', String madrasa = 'Hanfi'}) {
    if (name.trim().isEmpty) return 'Enter the student name';
    if (gender.isEmpty) return 'Select gender (Male or Female)';
    if (parentPhone.length != 10) return 'Parent mobile number is required (10 digits)';
    if (!aadhaar) return 'Aadhaar card is required';
    if (studentPhone.isNotEmpty) {
      if (studentPhone.length != 10) return 'Student mobile must be 10 digits, or leave it blank';
      if (studentPhone == parentPhone) return 'Student mobile must differ from the parent mobile';
      if (users.containsKey(studentPhone)) return 'This student mobile is already used';
    }
    final id = nextId++;
    final prefix = madrasa == 'Jama' ? 'JAM' : madrasa == 'Khwajapiya' ? 'KHW' : madrasa == 'Bagwanpura' ? 'BAG' : 'HNF';
    final s = Student(id: id, key: '$prefix-2026-${id.toString().padLeft(4, '0')}', name: name.trim(), gender: gender, cls: cls, madrasa: madrasa, start: kToday, parentPhone: parentPhone, studentPhone: studentPhone, aadhaar: true, address: address.trim());
    students.add(s);
    users.putIfAbsent(parentPhone, () => Account(parentPhone, 'Parent', 'parent'));
    if (studentPhone.isNotEmpty) users[studentPhone] = Account(studentPhone, s.name, 'student');
    notes.add(Note(parentPhone, '${s.name} was added to $madrasa madrasa. ID ${s.key}'));
    notifyListeners();
    return null;
  }

  String approve(int i) {
    final p = pending[i];
    final err = addStudent(name: p.name, gender: p.gender, cls: p.cls, parentPhone: p.parentPhone, aadhaar: p.aadhaar);
    if (err != null) return err;
    pending.removeAt(i);
    notifyListeners();
    return '${p.name} approved and added.';
  }

  void reject(int i) {
    pending.removeAt(i);
    notifyListeners();
  }

  // ---------- fees ----------
  List<String> feeMonths(Student s) {
    final start = pd(s.start).month;
    return monthNo.keys.where((m) => monthNo[m]! >= start).toList();
  }

  bool isPaid(int id, String m) => paid[id]?.contains(m) ?? false;

  String pay(Student s, String m) {
    paid.putIfAbsent(s.id, () => <String>{}).add(m);
    receiptNo++;
    notes.add(Note(s.parentPhone, 'Fee for $m 2026 received (Rs. 200). $m is complete.'));
    notifyListeners();
    return 'Receipt R-2026-$receiptNo created. $m marked Complete for ${s.name}.';
  }

  int completeCount(String m) => inBranch('Hanfi').where((s) => feeMonths(s).contains(m) && isPaid(s.id, m)).length;
  int totalFor(String m) => inBranch('Hanfi').where((s) => feeMonths(s).contains(m)).length;

  // ---------- leave ----------
  String? applyLeave(String type, String from, String to, String reason) {
    if (!validDate(from) || !validDate(to)) return 'Enter dates as yyyy-mm-dd';
    if (reason.trim().length < 5) return 'Reason is required';
    leaves.add(Leave(leaves.length + 1, user!.name, type, from, to, reason.trim()));
    notifyListeners();
    return null;
  }

  void decideLeave(Leave l, bool ok, String remark) {
    l.status = ok ? 'Approved' : 'Rejected';
    l.remark = remark;
    l.by = user!.name;
    notifyListeners();
  }

  // ---------- complaints ----------
  void addComplaint(String to, String subject, String text) {
    complaints.add(Complaint(complaints.length + 12, user!.phone, user!.name, to, subject, text));
    notifyListeners();
  }

  void reply(Complaint c, String text) {
    if (text.trim().isEmpty) return;
    c.replies.add('${roleLabel(user!)}: ${text.trim()}');
    c.status = 'In progress';
    notes.add(Note(c.phone, 'Reply to your complaint CMP-${c.id.toString().padLeft(4, '0')}'));
    notifyListeners();
  }

  void resolve(Complaint c) {
    c.status = 'Resolved';
    notifyListeners();
  }

  // ---------- announcements ----------
  void postAnnouncement(String title, String msg, String priority) {
    announcements.add(Announcement(title, msg, priority));
    notifyListeners();
  }

  void withdraw(Announcement a) {
    a.active = false;
    notifyListeners();
  }

  // ---------- roles and committee ----------
  String? createRole(String name, Set<String> perms) {
    if (name.trim().isEmpty) return 'Enter a role name';
    if (perms.isEmpty) return 'Tick at least one screen';
    customRoles[name.trim()] = Set<String>.from(perms);
    notifyListeners();
    return null;
  }

  String? assignRole(String phone, String name, String roleName, String branch) {
    if (phone.length != 10) return 'Enter a 10-digit mobile number';
    if (name.trim().isEmpty) return 'Enter the name';
    if (!customRoles.containsKey(roleName)) return 'Choose a role';
    users[phone] = Account(phone, name.trim(), 'custom', roleName: roleName, branches: [branch]);
    notifyListeners();
    return null;
  }

  List<Account> committee() => users.values.where((u) => u.role == 'committee').toList();

  String? addCommittee(String phone, String name, List<String> branches) {
    if (phone.length != 10) return 'Enter a 10-digit mobile number';
    if (name.trim().isEmpty) return 'Enter the name';
    if (branches.isEmpty) return 'Choose at least one branch';
    users[phone] = Account(phone, name.trim(), 'committee', branches: branches);
    notifyListeners();
    return null;
  }

  void removeMember(String phone) {
    users.remove(phone);
    notifyListeners();
  }

  // ---------- master data: teachers ----------
  List<Account> teachers() => users.values.where((u) => u.role == 'teacher').toList();

  void setTeacherActive(Account a, bool v) {
    a.active = v;
    notifyListeners();
  }

  String? addTeacher(String phone, String name, List<String> madrasasList) {
    if (phone.length != 10) return 'Enter a 10-digit mobile number';
    if (name.trim().isEmpty) return 'Enter the name';
    if (madrasasList.isEmpty) return 'Choose at least one madrasa';
    users[phone] = Account(phone, name.trim(), 'teacher', teachMadrasas: madrasasList);
    notifyListeners();
    return null;
  }

  void logView(Student s) {
    viewLog.add('${nice(kToday)} - ${user?.name ?? ''} viewed ${s.key}');
    notifyListeners();
  }

  int avgAtt(String b) {
    final l = inBranch(b);
    if (l.isEmpty) return 0;
    int t = 0;
    for (final s in l) {
      t += attPct(s);
    }
    return (t / l.length).round();
  }

  int avgSyl(String b) {
    final l = inBranch(b);
    if (l.isEmpty) return 0;
    int t = 0;
    for (final s in l) {
      final cd = classDefs[s.cls]!;
      t += cd.pageBased ? pageProg(s).pct : chapterProg(s).pct;
    }
    return (t / l.length).round();
  }

  // Same as avgAtt/avgSyl above but across every madrasa, for the Super
  // Admin dashboard - that tile used to show a hardcoded "86%"/"68%"
  // regardless of the real data.
  int avgAttAll() {
    if (students.isEmpty) return 0;
    var t = 0;
    for (final s in students) {
      t += attPct(s);
    }
    return (t / students.length).round();
  }

  int avgSylAll() {
    if (students.isEmpty) return 0;
    var t = 0;
    for (final s in students) {
      final cd = classDefs[s.cls]!;
      t += cd.pageBased ? pageProg(s).pct : chapterProg(s).pct;
    }
    return (t / students.length).round();
  }

  // ---------- teacher: assign to another madrasa ----------
  String? assignTeacherMadrasa(String teacherName, String madrasa, List<int> classIds) {
    if (madrasa.isEmpty || classIds.isEmpty) return 'Choose a madrasa and at least one class';
    final acc = users.values.firstWhere((u) => u.name == teacherName && u.role == 'teacher', orElse: () => Account('', '', ''));
    if (acc.phone.isEmpty) return 'Teacher not found';
    if (!acc.teachMadrasas.contains(madrasa)) acc.teachMadrasas.add(madrasa);
    teacherAssignments.putIfAbsent(teacherName, () => {})[madrasa] = classIds;
    notifyListeners();
    return null;
  }
}

class ChapPlan {
  final String title;
  final String plan;
  final String? done;
  final String grade;
  ChapPlan(this.title, this.plan, this.done, this.grade);
}
