import 'package:flutter/material.dart';

// Was `const String kToday = '2026-09-19'` - a date frozen at whatever day
// this was first written, so every date-driven feature (attendance,
// leave, fee due dates, syllabus pacing, promotion eligibility) was keyed
// off a permanently fixed fake "today" instead of the real one. A getter
// recomputes it from the device clock on every read.
String get kToday => fd(DateTime.now());
const List<String> kMon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const List<String> kBranches = ['Hanfi', 'Jama', 'Khwajapiya', 'Bagwanpura'];
const List<String> kBatches = ['Morning', 'Afternoon', 'Evening'];

// Who the "father's name" field actually names for this student - picked
// by the admitting teacher/admin, defaults to 'Father'. Lets an adult
// student admitted under her husband's guardianship (not every student is
// a minor admitted under her father) be recorded correctly instead of
// forcing every admission into a father relationship. See Student.
// guardianRelation / public.students.guardian_relation.
const List<String> kGuardianRelations = ['Father', 'Husband'];
// Fixed list of values (LOV) for Maktab Category - public.madrasas.category.
// Not free text: every place that lets a user set this must offer exactly
// these three and nothing else.
const List<String> kMadrasaCategories = ['Boys', 'Girls', 'Children'];
// The 10 granular Result Manager permissions (public.user_extra_permissions
// / public.role_permissions screen_key values) - see results.dart.
const List<String> kResultPerms = [
  'Results View',
  'Results Create',
  'Results Enter Marks',
  'Results Edit Unpublished',
  'Results Submit',
  'Results Publish',
  'Results Correct Published',
  'Results Delete',
  'Results View Reports',
  'Results Export',
];

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

// Normalizes a human/place/other-entity name to Init Cap (e.g.
// "mohd  aamir shaikh" -> "Mohd Aamir Shaikh") as it's saved, so data is
// stored consistently without the person having to type it that way or
// seeing any hint/warning at entry time. Collapses repeated whitespace and
// also capitalizes after a hyphen or apostrophe (e.g. "abdul-rahman" ->
// "Abdul-Rahman", "o'brien" -> "O'Brien") so compound names read right.
String toTitleCase(String input) {
  final trimmed = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (trimmed.isEmpty) return trimmed;
  String capSegment(String seg) => seg.isEmpty ? seg : seg[0].toUpperCase() + seg.substring(1).toLowerCase();
  return trimmed.split(' ').map((word) {
    return word.split('-').map((hyphenPart) {
      return hyphenPart.split("'").map(capSegment).join("'");
    }).join('-');
  }).join(' ');
}

// ---------------- class / syllabus model ----------------
class Chapter {
  String title;
  int days;
  // public.chapters row id, once loaded from (or saved to) the database.
  String? dbId;
  Chapter(this.title, this.days, {this.dbId});
}

class ClassDef {
  final int id;
  String name;
  final bool pageBased;
  String? bookName;
  int totalPages;
  final int paceDays; // expected days per page, page-based classes only
  bool active;
  // Classes 1-3 (Noorani Qaeda, Muallimul Qur'an Qaeda, Hafeezi Qur'an) are
  // fixed/core classes: they can never be renamed, have their book details
  // edited, be deleted, or have their Para structure changed (Class 3
  // specifically), and no duplicate of one can be created. Mirrors
  // public.classes.is_core - the actual enforcement is a DB trigger
  // (fn_protect_core_classes), this flag just drives hiding the
  // now-pointless edit controls in the UI. Defaults to false so any
  // locally-created class (not yet synced) is editable like every other
  // non-core class.
  bool isCore;
  // The matching row's id in Supabase public.classes, once this record has
  // been loaded from (or successfully saved to) the real database. Null
  // means this is still local-only demo data that hasn't been synced.
  String? dbId;
  // Optional Para structure for a page-based book that's split into named
  // sections with their own page count each (e.g. a Qur'an with 30 Para -
  // Para 1 might be 40 pages, Para 2 a different count). When this list is
  // non-empty, totalPages is kept as the sum of every Para's pageCount and
  // a flat page number is shown to users as "Para N, Page M of <count>"
  // instead of one long flat count - see AppState.paraPosition. When empty,
  // the class behaves exactly as a plain flat page-based book always has.
  List<ParaDef> paras;
  // Book Management (Class 4 onward): a class can have several independent
  // books, each with its own page count/sequence/active status, tracked
  // separately per student (AppState.bookProg et al) - unlike `paras`
  // above, which splits ONE book's single flat page range into named
  // sections. Always empty for Classes 1-3 (enforced server-side too).
  List<ClassBook> books;
  ClassDef(this.id, this.name,
      {this.pageBased = false, this.bookName, this.totalPages = 0, this.paceDays = 2, this.active = true, this.isCore = false, this.dbId, List<ParaDef>? paras, List<ClassBook>? books})
      : paras = paras ?? [],
        books = books ?? [];
}

// One Book under a class's Book Management (Class 4 onward) -
// public.class_books. Independent of the single bookName/totalPages a
// page-based class (Classes 1-3) already has, and independent of other
// Books under the same class - each has its own 1..totalPages range.
class ClassBook {
  final int id;
  String name;
  String description;
  int totalPages;
  int sequenceOrder;
  bool active;
  // public.class_books row id, once loaded from (or saved to) the database.
  String? dbId;
  ClassBook(this.id, this.name, {this.description = '', this.totalPages = 0, this.sequenceOrder = 0, this.active = true, this.dbId});
}

// One Para (section) of a Para-wise book - public.class_paras.
class ParaDef {
  final int paraNo;
  int pageCount;
  // The order this Para is taught/displayed in, independent of its number -
  // e.g. the Hafizi Qur'an course teaches Para 30 first, then 1-29, so
  // Para 30's sequenceOrder is 1 while its paraNo (identity) stays 30.
  // Defaults to paraNo, which reproduces plain ascending order for every
  // class that has no special sequence (Classes 1, 2, and Para 1..30 of
  // Class 3 before this field existed).
  int sequenceOrder;
  // public.class_paras row id, once loaded from (or saved to) the database.
  String? dbId;
  ParaDef(this.paraNo, this.pageCount, {this.dbId, int? sequenceOrder}) : sequenceOrder = sequenceOrder ?? paraNo;
}

// Where a flat, book-wide page number falls inside a Para-wise book: which
// Para it's in, and its 1-based page number within just that Para.
class ParaPos {
  final int paraNo;
  final int pageInPara;
  final int paraPageCount;
  const ParaPos(this.paraNo, this.pageInPara, this.paraPageCount);
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
  bool aadhaar; // true when a valid 12-digit aadhaarNumber is on file
  String aadhaarNumber; // 12 digits, or '' for older records not yet filled in
  String address;
  String status;
  String? dob; // yyyy-MM-dd, matches public.students.dob
  String fatherName;
  // 'Father' (default) or 'Husband' - whether fatherName above is the
  // student's father's name or, for an adult student admitted under her
  // husband's guardianship, her husband's name. The admitting
  // teacher/admin picks this at admission time (kGuardianRelations); it's
  // never guessed from the name or anything else - public.students.
  // guardian_relation.
  String guardianRelation;
  // 'Morning' / 'Afternoon' / 'Evening' - same class, split by session, so
  // Mark Attendance can group students who attend different times of day
  // instead of silently defaulting everyone to Present on Final Submit.
  String batch;
  // page-based progress (Classes 1-3): pageNo -> date / grade / remark
  Map<int, String> pageDate;
  Map<int, String> pageGrade;
  // chapter-based progress (Class 4+): chapterIndex -> date / grade
  Map<int, String> chDate;
  Map<int, String> chGrade;
  // Book Management progress (Class 4+ books): keyed by "bookId:pageNo"
  // since each Book under a class has its own independent 1..totalPages
  // range (unlike pageDate/pageGrade above, which assume one flat range
  // per class and would collide across several Books).
  Map<String, String> bookPageDate;
  Map<String, String> bookPageGrade;
  List<String> absent;
  List<String> history;
  // The matching row's id in Supabase public.students, once this record has
  // been loaded from (or successfully saved to) the real database. Null
  // means this is still local-only demo data that hasn't been synced.
  // Attendance/syllabus/fees still live only in the fields above for every
  // student, database-backed or not - those haven't been wired up yet.
  String? dbId;
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
    this.aadhaarNumber = '',
    this.address = '',
    this.status = 'Active',
    this.dob,
    this.fatherName = '',
    this.guardianRelation = 'Father',
    this.batch = 'Morning',
    Map<int, String>? pageDate,
    Map<int, String>? pageGrade,
    Map<int, String>? chDate,
    Map<int, String>? chGrade,
    Map<String, String>? bookPageDate,
    Map<String, String>? bookPageGrade,
    List<String>? absent,
    List<String>? history,
    this.dbId,
  })  : pageDate = pageDate ?? {},
        pageGrade = pageGrade ?? {},
        chDate = chDate ?? {},
        chGrade = chGrade ?? {},
        bookPageDate = bookPageDate ?? {},
        bookPageGrade = bookPageGrade ?? {},
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

// A Maktab Event/Holiday recorded against an attendance date - public.
// maktab_events. `batch` null means it covers every session that day;
// otherwise it only affects that one batch (Morning/Afternoon/Evening),
// so a partial-day event doesn't block unrelated sessions on the same
// date (see AppState.blockingEventFor).
class MaktabEvent {
  final String? dbId;
  final String madrasa;
  String name;
  String type; // 'event' | 'holiday' | 'other'
  String date; // yyyy-MM-dd
  String? startTime; // 'HH:mm'
  String? endTime;
  String? batch;
  String description;
  String? createdByName;
  bool cancelled;
  String? cancelReason;
  MaktabEvent({
    this.dbId,
    required this.madrasa,
    required this.name,
    required this.type,
    required this.date,
    this.startTime,
    this.endTime,
    this.batch,
    this.description = '',
    this.createdByName,
    this.cancelled = false,
    this.cancelReason,
  });
}

// Mirrors one row of public.attendance_sessions: whether a Teacher
// Attendance session (one Maktab + class + batch + date) has already been
// finally submitted via submit_attendance_session, and if so by whom/when
// and how many authorized corrections it has had. This is display/decision
// data only (e.g. whether the next submit for this exact session should be
// worded as a first submission or a correction, and whether a reason is
// required) - the actual completeness/lock enforcement lives entirely in
// the database function, not here.
class AttendanceSessionMeta {
  String? dbId;
  int totalExpected;
  int presentCount;
  int absentCount;
  String? submittedByName;
  DateTime? submittedAt;
  int correctionCount;
  AttendanceSessionMeta({
    this.dbId,
    this.totalExpected = 0,
    this.presentCount = 0,
    this.absentCount = 0,
    this.submittedByName,
    this.submittedAt,
    this.correctionCount = 0,
  });
}

// One calendar day's classification for a student's attendance history -
// used by the Parent attendance report. Exactly one of these per date
// (never double-counted across categories - see computeMonthAttendance).
class DayAttendance {
  final String date;
  final String status; // Present | Absent | Event | Holiday | Weekend | Not Recorded
  final String? eventName;
  const DayAttendance(this.date, this.status, {this.eventName});
}

class MonthAttendanceSummary {
  final int year;
  final int month;
  final int totalCalendarDays;
  final int present;
  final int absent;
  final int eventDays;
  final int holidayDays;
  final int weekendDays;
  final int notRecorded;
  final List<DayAttendance> days;
  MonthAttendanceSummary({
    required this.year,
    required this.month,
    required this.totalCalendarDays,
    required this.present,
    required this.absent,
    required this.eventDays,
    required this.holidayDays,
    required this.weekendDays,
    required this.notRecorded,
    required this.days,
  });
  // "Present / Eligible Scheduled Sessions x 100" - eligible is only days
  // attendance was actually recorded (present+absent). Events, holidays,
  // weekends and never-recorded days are excluded from the denominator
  // entirely, per spec, rather than counted against the student.
  int get eligibleScheduledDays => present + absent;
  int get pct => eligibleScheduledDays == 0 ? 0 : (present * 100 / eligibleScheduledDays).round();
}

// Classifies every calendar day of (year, month) - from the student's
// admission date (s.start) up to today for the current month, or the
// whole month for a past one - into exactly one category. Friday is the
// Maktab's weekly off day (the same convention the Islamic Calendar tool
// already highlights). `attendanceByDate` only holds FINAL-submitted
// (is_draft=false) rows: a date with no entry there is "Not Recorded",
// never assumed Absent.
MonthAttendanceSummary computeMonthAttendance({
  required String studentStart,
  required int year,
  required int month,
  required Map<String, String> attendanceByDate, // date -> 'present'/'absent'
  required List<MaktabEvent> events, // already filtered to this student's madrasa, not cancelled
  required String batch,
}) {
  final firstOfMonth = DateTime(year, month, 1);
  final lastOfMonth = DateTime(year, month + 1, 0);
  final today = DateTime.now();
  final rangeEnd = (year == today.year && month == today.month) ? DateTime(today.year, today.month, today.day) : lastOfMonth;
  final admission = pd(validDate(studentStart) ? studentStart : fd(firstOfMonth));

  final eventsByDate = <String, MaktabEvent>{};
  for (final e in events) {
    if (e.cancelled) continue;
    if (e.batch != null && e.batch != batch) continue;
    // Holiday takes precedence over a plain Event/Other if both were
    // somehow recorded for the same date (shouldn't happen given the
    // unique index, but stay deterministic either way).
    final existing = eventsByDate[e.date];
    if (existing == null || (existing.type != 'holiday' && e.type == 'holiday')) eventsByDate[e.date] = e;
  }

  var present = 0, absent = 0, eventDays = 0, holidayDays = 0, weekendDays = 0, notRecorded = 0;
  final days = <DayAttendance>[];
  for (var d = firstOfMonth; !d.isAfter(rangeEnd); d = d.add(const Duration(days: 1))) {
    if (d.isBefore(DateTime(admission.year, admission.month, admission.day))) continue; // not yet admitted
    final ds = fd(d);
    if (d.weekday == DateTime.friday) {
      weekendDays++;
      days.add(DayAttendance(ds, 'Weekend'));
      continue;
    }
    final ev = eventsByDate[ds];
    if (ev != null) {
      if (ev.type == 'holiday') {
        holidayDays++;
        days.add(DayAttendance(ds, 'Holiday', eventName: ev.name));
      } else {
        eventDays++;
        days.add(DayAttendance(ds, 'Event', eventName: ev.name));
      }
      continue;
    }
    final att = attendanceByDate[ds];
    if (att == 'present') {
      present++;
      days.add(DayAttendance(ds, 'Present'));
    } else if (att == 'absent') {
      absent++;
      days.add(DayAttendance(ds, 'Absent'));
    } else {
      notRecorded++;
      days.add(DayAttendance(ds, 'Not Recorded'));
    }
  }

  return MonthAttendanceSummary(
    year: year,
    month: month,
    totalCalendarDays: lastOfMonth.day,
    present: present,
    absent: absent,
    eventDays: eventDays,
    holidayDays: holidayDays,
    weekendDays: weekendDays,
    notRecorded: notRecorded,
    days: days,
  );
}

// A single (Maktab, class) pair a teacher is actually assigned to -
// loaded from public.teacher_class_assignments, not invented locally.
class ClassAssignment {
  final String madrasa;
  final int cls;
  const ClassAssignment(this.madrasa, this.cls);
}

class Account {
  String phone;
  String name;
  String role;
  String roleName;
  List<String> branches; // committee / custom role scope
  List<String> teachMadrasas; // teacher: madrasas they teach in
  List<ClassAssignment> myClasses; // teacher: (madrasa, class) pairs they're actually assigned to
  bool active;
  // user_profiles.id once this teacher has actually signed in for the
  // first time and a real row exists. Null means this is still just a
  // pending invite (public.pending_role_invites) - the phone number is
  // queued for a role, but nobody has logged in with it yet, so there's
  // no real account to activate/deactivate.
  String? dbId;
  bool pending;
  // Extra screen permissions granted on TOP of this account's base role
  // (public.user_extra_permissions) - e.g. a Teacher additionally given
  // "Fees" access. Always additive: granting or revoking one of these
  // never touches `role`/`roleName`/`branches`, unlike assigning a whole
  // new role which replaces them.
  Set<String> extraPerms;
  Account(this.phone, this.name, this.role,
      {this.roleName = '', List<String>? branches, List<String>? teachMadrasas, List<ClassAssignment>? myClasses, this.active = true, this.dbId, this.pending = false, Set<String>? extraPerms})
      : branches = branches ?? [],
        teachMadrasas = teachMadrasas ?? [],
        myClasses = myClasses ?? [],
        extraPerms = extraPerms ?? {};
}

// ---------------- master data: madrasas / courses ----------------
class MadrasaRec {
  String name;
  bool active;
  // 'Boys' / 'Girls' / 'Children' - public.madrasas.category, one of
  // kMadrasaCategories. Null means an existing Maktab created before this
  // field existed and not yet categorized - never invented, always shown
  // as "Not set" rather than guessed.
  String? category;
  // The matching row's id in Supabase public.madrasas, once this record has
  // been loaded from (or successfully saved to) the real database. Null
  // means this is still local-only demo data that hasn't been synced -
  // Supabase calls in main.dart use this to know which row to update.
  String? dbId;
  MadrasaRec(this.name, {this.active = true, this.category, this.dbId});
}

class Course {
  final int id;
  String name;
  String description;
  // "Course Code or ID" - a short human-assigned code (e.g. "ADN-01"),
  // separate from the database row id. Optional.
  String code;
  bool active;
  // Same purpose as MadrasaRec.dbId above, for public.courses.
  String? dbId;
  Course(this.id, this.name, this.description, {this.code = '', this.active = true, this.dbId});
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
  // public.course_enrollments row id, once loaded from (or saved to) the
  // database - needed to update (submit/approve/reject) this exact row.
  String? dbId;
  CourseEnrollment(this.courseId, this.studentId, {this.status = 'in_progress', this.completedOn, this.dbId});
}

// Which add-on Course is required for which class (public.class_course_assignments).
// Every assignment is mandatory - the course must be completed by every
// student in that class before the class itself can be marked Completed
// (see AppState.pendingMandatoryCourses / canCompleteClass).
class ClassCourseAssignment {
  final int classId;
  final int courseId;
  String? dbId;
  ClassCourseAssignment(this.classId, this.courseId, {this.dbId});
}

class Note {
  String phone;
  String text;
  Note(this.phone, this.text);
}

// ---------------- Notification Templates ----------------
// Mirrors public.notification_templates: Super-Admin-editable message
// formats for every notification channel actually used in the app
// (Student Absent, Monthly Fee Reminder, Sadqa Peti Collection, Course
// Completion, Event/Holiday). `variables` lists the {placeholder} names
// this template supports; renderTemplate() below fills them in.
class NotifTemplate {
  String? dbId;
  String key; // template_key, e.g. 'student_absent'
  String name;
  String notifType;
  String channel; // whatsapp | sms | in_app
  String body;
  List<String> variables;
  bool active;
  String? updatedByName;
  DateTime? updatedAt;
  NotifTemplate({
    this.dbId,
    required this.key,
    required this.name,
    required this.notifType,
    required this.channel,
    required this.body,
    required this.variables,
    this.active = true,
    this.updatedByName,
    this.updatedAt,
  });
}

// One saved-history snapshot of a template, shown in "Version history".
class NotifTemplateVersion {
  final String body;
  final List<String> variables;
  final bool active;
  final String? changedByName;
  final DateTime changedAt;
  const NotifTemplateVersion({
    required this.body,
    required this.variables,
    required this.active,
    required this.changedByName,
    required this.changedAt,
  });
}

// Fills {placeholder} tokens in [body] from [vars]. Any placeholder the
// template references but [vars] doesn't supply is left as-is and
// reported in `missing`, so a Preview screen can warn about it instead
// of silently sending a half-filled message.
class RenderedTemplate {
  final String text;
  final List<String> missing;
  const RenderedTemplate(this.text, this.missing);
}

RenderedTemplate renderTemplate(String body, Map<String, String> vars) {
  final missing = <String>[];
  final text = body.replaceAllMapped(RegExp(r'\{([a-zA-Z0-9_]+)\}'), (m) {
    final key = m.group(1)!;
    if (vars.containsKey(key) && vars[key]!.isNotEmpty) return vars[key]!;
    missing.add(key);
    return '{$key}';
  });
  return RenderedTemplate(text, missing);
}

// ---------------- About Us ----------------
// Mirrors public.about_us: a single editable row replacing what used to
// be hardcoded Hindi text directly in guest_tools.dart. Kept as titled
// sections (each with optional paragraphs and/or bullet points) rather
// than flat name/mission/vision fields, because that is the actual shape
// of the organization's existing content and flattening it would lose
// structure the Super Admin still needs to edit paragraph-by-paragraph.
class AboutUsSection {
  String title;
  List<String> paras;
  List<String> bullets;
  AboutUsSection({required this.title, this.paras = const [], this.bullets = const []});
  factory AboutUsSection.fromJson(Map<String, dynamic> j) => AboutUsSection(
        title: (j['title'] as String?) ?? '',
        paras: ((j['paras'] as List?) ?? const []).map((e) => e.toString()).toList(),
        bullets: ((j['bullets'] as List?) ?? const []).map((e) => e.toString()).toList(),
      );
  Map<String, dynamic> toJson() => {'title': title, 'paras': paras, 'bullets': bullets};
}

class AboutUsContent {
  String heading;
  String subheading;
  List<AboutUsSection> sections;
  List<String> contactLines;
  DateTime? updatedAt;
  AboutUsContent({
    required this.heading,
    required this.subheading,
    required this.sections,
    required this.contactLines,
    this.updatedAt,
  });
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
  // public.complaints row id, once loaded from (or saved to) the database.
  String? dbId;
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
  // Section 7: which Maktab this leave is for - a teacher who works at
  // more than one Maktab applies for leave at one of them at a time, and
  // it must only affect that Maktab's view/approval, not every Maktab
  // they're assigned to.
  String madrasa;
  String? dbId;
  Leave(this.id, this.teacher, this.type, this.from, this.to, this.reason, {this.madrasa = '', this.dbId});
}

class Announcement {
  String title;
  String msg;
  String priority;
  bool active = true;
  // Date range this announcement should actually be shown in, yyyy-MM-dd
  // (same convention as every other date field in this app - Student.dob,
  // Leave.from/to, etc.) - null startDate means "show immediately", null
  // endDate means "never auto-expire" (only possible for a row posted
  // before this feature existed). The banner filters by these against
  // kToday on every read, client-side, so an announcement disappears the
  // day after endDate with no server job needed - `active` stays a
  // separate, manual "Withdraw" flag.
  String? startDate;
  String? endDate;
  // public.announcements row id, once loaded from (or saved to) the database.
  String? dbId;
  Announcement(this.title, this.msg, this.priority, {this.dbId, this.startDate, this.endDate});
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
      return 'Maktab Admin (Hanfi)';
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

  // False until the first full loadMasterData() (students, attendance,
  // syllabus, etc.) finishes after login, success or failure. Dashboards
  // check this before showing a count, so the brief window where
  // st.students/st.classDefs still hold their built-in placeholder/demo
  // values doesn't flash a misleading "0" before the real data arrives.
  bool dataLoaded = false;

  // True for the moment right after a parent logs in, while _LoginSplash
  // (main.dart) plays its zoom-out logo animation; cleared by that
  // widget via dismissLoginSplash() once the animation finishes.
  bool showLoginSplash = false;

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
  String? addMadrasa(String name, {String? dbId, String? category}) {
    final n = name.trim();
    if (n.isEmpty) return 'Enter a Maktab name';
    if (madrasas.any((m) => m.name.toLowerCase() == n.toLowerCase())) return 'This Maktab already exists';
    madrasas.add(MadrasaRec(n, dbId: dbId, category: category));
    notifyListeners();
    return null;
  }

  void setMadrasaActive(MadrasaRec m, bool v) {
    m.active = v;
    notifyListeners();
  }

  void renameMadrasa(MadrasaRec m, String name) {
    m.name = name;
    notifyListeners();
  }

  void setMadrasaCategoryLocal(MadrasaRec m, String category) {
    m.category = category;
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

  String? addCourse(String name, String description, {String code = '', String? dbId}) {
    final n = name.trim();
    if (n.isEmpty) return 'Enter an Add-on Course name';
    courses.add(Course(nextCourseId++, n, description.trim(), code: code.trim(), dbId: dbId));
    notifyListeners();
    return null;
  }

  void setCourseActive(Course c, bool v) {
    c.active = v;
    notifyListeners();
  }

  void renameCourse(Course c, String name, {String? description, String? code}) {
    c.name = name;
    if (description != null) c.description = description;
    if (code != null) c.code = code;
    notifyListeners();
  }

  // ---------- class <-> course assignments (public.class_course_assignments) ----------
  final List<ClassCourseAssignment> classCourseAssignments = [];

  // Every add-on Course assigned to a given class (ClassDef.id), in the
  // order they were assigned - what requirement 8's "students see only the
  // add-on courses assigned to their class" and the mandatory-completion
  // check are both built on.
  List<Course> coursesForClass(int classId) {
    final ids = classCourseAssignments.where((a) => a.classId == classId).map((a) => a.courseId).toSet();
    return courses.where((c) => ids.contains(c.id)).toList();
  }

  bool courseAssignedToClass(int classId, int courseId) => classCourseAssignments.any((a) => a.classId == classId && a.courseId == courseId);

  void setClassCourseAssignmentsFromDb(List<ClassCourseAssignment> list) {
    classCourseAssignments
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  void addClassCourseAssignmentLocal(ClassCourseAssignment a) {
    if (courseAssignedToClass(a.classId, a.courseId)) return;
    classCourseAssignments.add(a);
    notifyListeners();
  }

  void removeClassCourseAssignmentLocal(int classId, int courseId) {
    classCourseAssignments.removeWhere((a) => a.classId == classId && a.courseId == courseId);
    notifyListeners();
  }

  // ---------- course enrollments / completion approval ----------
  // Populated from public.course_enrollments by loadCourseEnrollments() in
  // main.dart after login - empty until then (no fake seed data, since
  // this is real per-student progress, not a UI mock).
  final List<CourseEnrollment> courseEnrollments = [];

  void setCourseEnrollmentsFromDb(List<CourseEnrollment> list) {
    courseEnrollments
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  List<CourseEnrollment> enrollmentsFor(Student s) => courseEnrollments.where((e) => e.studentId == s.id).toList();

  String? enrollCourse(Student s, int courseId, {String? dbId}) {
    if (courseEnrollments.any((e) => e.studentId == s.id && e.courseId == courseId)) return 'Already assigned to this student';
    courseEnrollments.add(CourseEnrollment(courseId, s.id, dbId: dbId));
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
      final tpl = templateFor('course_completion');
      final body = tpl?.body ?? '{course_name} marked Completed for {student_name} on {completion_date}.';
      final r = renderTemplate(body, {
        'course_name': c?.name ?? 'Add-on Course',
        'student_name': s.name,
        'completion_date': nice(kToday),
      });
      notes.add(Note(s.parentPhone, r.text));
    } else {
      e.status = 'in_progress';
      e.rejectReason = reason;
    }
    notifyListeners();
  }

  bool isCourseCompletedFor(Student s, int courseId) =>
      courseEnrollments.any((e) => e.studentId == s.id && e.courseId == courseId && e.status == 'completed');

  // Every add-on Course assigned to this student's class that is NOT yet
  // completed+approved for them - empty means nothing is blocking class
  // completion. Shown to Teacher/Admin so they know exactly what's left
  // (requirement 5), and is what canCompleteClass gates on.
  List<Course> pendingMandatoryCourses(Student s) {
    final cd = classDefs[s.cls];
    if (cd == null) return const [];
    return coursesForClass(cd.id).where((c) => !isCourseCompletedFor(s, c.id)).toList();
  }

  // Whether this student can actually be promoted/graduated right now:
  // their syllabus is done (eligible) AND every add-on course assigned to
  // their class is completed+approved. Kept separate from eligible() so
  // the Students & Promotion screen can still show WHY a syllabus-ready
  // student is blocked (which pending courses) instead of just silently
  // hiding them.
  bool canCompleteClass(Student s) => eligible(s) && pendingMandatoryCourses(s).isEmpty;

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

  void renameClass(ClassDef cd, String name) {
    cd.name = name;
    notifyListeners();
  }

  // Edits an existing class's book details (requirement 1: "edit, update,
  // and save existing class details", not just rename). totalPages is
  // ignored when this class has a Para structure - there, the total is
  // always kept as the sum of each Para's own page count (see
  // setParasFromDb/addParaLocal/updateParaLocal), so it isn't a
  // independently-editable field in that case.
  void updateClassDetails(ClassDef cd, {String? bookName, int? totalPages}) {
    if (bookName != null) cd.bookName = bookName;
    if (totalPages != null && cd.paras.isEmpty) cd.totalPages = totalPages;
    notifyListeners();
  }

  // ---------- Para-wise book structure (optional, page-based classes) ----------
  // Replaces one class's whole Para list with what the database has, and
  // keeps totalPages in sync (sum of every Para's page count) so every
  // existing page-based calculation - pageProg, currentPageNo, eligible,
  // promotion - keeps working unchanged against one flat page count.
  void setParasFromDb(ClassDef cd, List<ParaDef> list) {
    list.sort((a, b) => a.paraNo.compareTo(b.paraNo));
    cd.paras = list;
    if (list.isNotEmpty) cd.totalPages = list.fold(0, (t, p) => t + p.pageCount);
    notifyListeners();
  }

  void addParaLocal(ClassDef cd, ParaDef p) {
    cd.paras.add(p);
    cd.paras.sort((a, b) => a.paraNo.compareTo(b.paraNo));
    cd.totalPages = cd.paras.fold(0, (t, x) => t + x.pageCount);
    notifyListeners();
  }

  void updateParaLocal(ClassDef cd, ParaDef p, int pageCount) {
    p.pageCount = pageCount;
    cd.totalPages = cd.paras.fold(0, (t, x) => t + x.pageCount);
    notifyListeners();
  }

  // Converts a flat 1-based page number into which Para it falls in and the
  // 1-based page number within just that Para, using each Para's own page
  // count. Returns null when this class has no Para structure (plain flat
  // pages) or the number is out of range.
  ParaPos? paraPosition(ClassDef cd, int flatPageNo) {
    if (cd.paras.isEmpty) return null;
    var seen = 0;
    for (final p in cd.paras) {
      if (flatPageNo <= seen + p.pageCount) {
        return ParaPos(p.paraNo, flatPageNo - seen, p.pageCount);
      }
      seen += p.pageCount;
    }
    return null;
  }

  // cd.paras in TEACHING/display order (e.g. Para 30, 1, 2, ..., 29 for the
  // Hafizi Qur'an) - used anywhere Para are listed or presented to a
  // person. Never used for page-number math: the physical page a Para
  // starts on is fixed by the real printed book regardless of the order
  // it's taught in, so page-number calculations always walk cd.paras
  // itself (kept in paraNo/physical order - see setParasFromDb).
  List<ParaDef> parasInSequence(ClassDef cd) => List<ParaDef>.from(cd.paras)..sort((a, b) => a.sequenceOrder.compareTo(b.sequenceOrder));

  // The physical (real book) starting page number of a given Para, found by
  // summing page counts of every Para before it in paraNo order - this is
  // independent of teaching/display sequence.
  int? paraStartPage(ClassDef cd, int paraNo) {
    var seen = 0;
    for (final p in cd.paras) {
      if (p.paraNo == paraNo) return seen + 1;
      seen += p.pageCount;
    }
    return null;
  }

  // Every physical page number of this class's book, in the order it
  // should actually be taught/completed - for a plain flat book (no Para
  // structure) this is just 1..totalPages, unchanged from before. For a
  // Para-wise book it walks the Para in sequenceOrder (not paraNo order),
  // expanding each into its own physical page range (still ascending
  // within that one Para - only the Para-to-Para order changes).
  List<int> pageSequence(ClassDef cd) {
    if (cd.paras.isEmpty) return List<int>.generate(cd.totalPages, (i) => i + 1);
    final seq = <int>[];
    for (final p in parasInSequence(cd)) {
      final start = paraStartPage(cd, p.paraNo);
      if (start == null) continue;
      for (var i = 0; i < p.pageCount; i++) {
        seq.add(start + i);
      }
    }
    return seq;
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
  // Replaces the old fixed Jun-Sep-only window: fees are Rs. 200/month
  // starting the month a student is admitted (or promoted - admission_date
  // resets then) and continuing every month after, indefinitely, not just
  // within one hardcoded 4-month range. Keys are "Mon YYYY" (e.g. "Oct
  // 2026") so they stay unique across year boundaries - plain "Oct" alone
  // would collide between this year's October and next year's.
  static const List<String> kMonthAbbrevs = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static int monthNumFromKey(String key) => kMonthAbbrevs.indexOf(key.split(' ').first) + 1;
  static int yearFromKey(String key) => int.parse(key.split(' ').last);

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
    final tpl = templateFor('student_absent');
    final body = tpl?.body ??
        'Dear Parent/Guardian, your child {student_name} was marked absent at {maktab_name} on {attendance_date}. Please contact the Maktab if you need any clarification. Thank you.';
    final r = renderTemplate(body, {
      'student_name': s.name,
      'maktab_name': madrasa,
      'attendance_date': nice(date),
    });
    whatsappLog.add('[${nice(date)}] To ${s.parentPhone}: "${r.text}"');
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
      final tpl = templateFor('fee_reminder');
      final body = tpl?.body ??
          'Dear Parent/Guardian, fee of Rs. {fee_amount} for {due_months} is due for {student_name}. QR code: {qr_info}.';
      final r = renderTemplate(body, {
        'student_name': s.name,
        'fee_amount': '200',
        'due_months': due.join(', '),
        'qr_info': feeQrPath ?? 'not uploaded yet',
      });
      feeReminderLog.add('[${nice(kToday)}] To ${s.parentPhone}: "${r.text}"');
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
    return '${s.name} deactivated. Attendance, fee and add-on course history is kept.';
  }

  String reactivateStudent(Student s) {
    s.status = 'Active';
    s.history.add('Reactivated ${nice(kToday)} by ${user?.name ?? ''}');
    notifyListeners();
    return '${s.name} reactivated.';
  }

  void editStudent(Student s, {String? name, String? parentPhone, String? address, String? madrasa, int? cls, String? dob, String? fatherName, String? guardianRelation, String? batch, String? aadhaarNumber}) {
    if (aadhaarNumber != null && RegExp(r'^[0-9]{12}$').hasMatch(aadhaarNumber)) {
      s.aadhaarNumber = aadhaarNumber;
      s.aadhaar = true;
    }
    if (name != null && name.trim().isNotEmpty) s.name = name.trim();
    if (parentPhone != null && parentPhone.trim().isNotEmpty) s.parentPhone = parentPhone.trim();
    if (address != null) s.address = address.trim();
    if (madrasa != null) s.madrasa = madrasa;
    if (cls != null) s.cls = cls;
    if (dob != null) s.dob = dob.trim().isEmpty ? null : dob.trim();
    if (fatherName != null) s.fatherName = fatherName.trim();
    if (guardianRelation != null && kGuardianRelations.contains(guardianRelation)) s.guardianRelation = guardianRelation;
    if (batch != null && batch.isNotEmpty) s.batch = batch;
    notifyListeners();
  }

  // Section 3.2.3: duplicate check on Name + DOB among ACTIVE students only
  // (an inactive record with the same name/DOB is not a duplicate - it's
  // history). excludeId lets Edit Student skip matching itself.
  Student? findActiveDuplicate(String name, String? dob, {int? excludeId}) {
    final n = name.trim().toLowerCase();
    if (n.isEmpty || dob == null || dob.isEmpty) return null;
    for (final s in students) {
      if (s.id == excludeId) continue;
      if (s.status != 'Active') continue;
      if (s.name.trim().toLowerCase() == n && s.dob == dob) return s;
    }
    return null;
  }

  // Section 4.3: warn when deactivating a student who has an active
  // sibling (same parent mobile number) still enrolled, in case it's a
  // mistake (e.g. the wrong one of two siblings was picked).
  List<Student> activeSiblings(Student s) => students.where((x) => x.id != s.id && x.status == 'Active' && x.parentPhone.isNotEmpty && x.parentPhone == s.parentPhone).toList();

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
  final List<Announcement> announcements = [Announcement('Maktab closed on 02-Oct-2026', 'Friday holiday for all Makatib.', 'Important')];
  final List<String> viewLog = [];

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
    // A parent landing straight on their child's Home screen with no
    // transition at all felt abrupt - shown briefly by _LoginSplash (in
    // main.dart) right after login, then dismissed via
    // dismissLoginSplash() once its animation finishes.
    showLoginSplash = a.role == 'parent';
    notifyListeners();
  }

  void dismissLoginSplash() {
    showLoginSplash = false;
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

  // Was keyed off `teacherAssignments`, a map that only ever had one
  // hardcoded demo entry ('Ustaad Salman') and was never written to by any
  // real save path - so for every actual teacher this returned nothing,
  // regardless of what they were really assigned to in the database. Now
  // sourced from Account.myClasses (loaded from teacher_class_assignments
  // at login). There's no real per-period timetable in the database, so
  // this no longer invents clock times - it lists the teacher's real
  // (Maktab, class) assignments, grouped by Maktab.
  List<DayEntry> myDay() {
    final u = user;
    if (u == null) return [];
    final list = List<ClassAssignment>.from(u.myClasses)
      ..sort((a, b) {
        final m = a.madrasa.compareTo(b.madrasa);
        return m != 0 ? m : a.cls.compareTo(b.cls);
      });
    return [for (final c in list) DayEntry('', c.madrasa, c.cls)];
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

  // The next page the student should do: the first page, walked in
  // teaching-sequence order (see pageSequence), that isn't marked complete
  // yet - NOT simply "completedPages + 1". A plain count would be wrong
  // the moment the sequence doesn't start at physical page 1 (e.g. Hafizi
  // Qur'an's Para 30 first): it would point at the physical next page
  // instead of the next page in the required teaching order. Walking for
  // the first gap also means it keeps working correctly for students who
  // already had progress recorded before a class's sequence was
  // introduced/changed - their completed pages stay exactly as recorded,
  // and this simply resumes wherever the new sequence is still incomplete.
  int? currentPageNo(Student s) {
    final cd = classDefs[s.cls]!;
    if (!cd.pageBased) return null;
    for (final pageNo in pageSequence(cd)) {
      if (!s.pageDate.containsKey(pageNo)) return pageNo;
    }
    return null;
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
    String label;
    if (cur == null) {
      label = 'All pages complete';
    } else {
      final pos = paraPosition(cd, cur);
      label = pos != null ? 'Para ${pos.paraNo}, Page ${pos.pageInPara} of ${pos.paraPageCount}' : 'Page $cur of ${cd.totalPages}';
    }
    return Prog(n, cd.totalPages, behind, label: label);
  }

  void markPageComplete(Student s, int pageNo, String date, String grade, String remark) {
    final d = validDate(date) ? date : kToday;
    s.pageDate[pageNo] = d;
    s.pageGrade[pageNo] = grade;
    final cd = classDefs[s.cls]!;
    notes.add(Note(s.parentPhone, '${cd.bookName} page $pageNo completed for ${s.name} on ${nice(d)} - $grade'));
    notifyListeners();
  }

  // Replaces a student's page-progress with what the database has, called
  // after loading or saving so refreshes/other devices see the same thing.
  void setPageProgressFromDb(Student s, Map<int, String> dates, Map<int, String> grades) {
    s.pageDate = dates;
    s.pageGrade = grades;
    notifyListeners();
  }

  // ---------- Book Management (Class 4+ books) ----------
  List<ClassBook> booksForClass(int classId) {
    final cd = classDefs[classId];
    if (cd == null) return const [];
    final list = cd.books.where((b) => b.active).toList()..sort((a, b) => a.sequenceOrder.compareTo(b.sequenceOrder));
    return list;
  }

  String _bookKey(int bookId, int pageNo) => '$bookId:$pageNo';

  // First not-yet-completed page of this Book, 1..totalPages in plain
  // order (a Book has no reordered teaching sequence like Hafizi Qur'an's
  // Para do - "display/learning sequence" for a Book is which Book comes
  // first among several, not a reorder of its own pages).
  int? currentBookPageNo(Student s, ClassBook b) {
    for (var p = 1; p <= b.totalPages; p++) {
      if (!s.bookPageDate.containsKey(_bookKey(b.id, p))) return p;
    }
    return null;
  }

  String bookPageStatus(Student s, ClassBook b, int pageNo) {
    if (s.bookPageDate.containsKey(_bookKey(b.id, pageNo))) return 'Completed';
    if (pageNo == currentBookPageNo(s, b)) return 'In progress';
    return 'Pending';
  }

  Prog bookProg(Student s, ClassBook b) {
    var n = 0;
    for (var p = 1; p <= b.totalPages; p++) {
      if (s.bookPageDate.containsKey(_bookKey(b.id, p))) n++;
    }
    final cur = currentBookPageNo(s, b);
    final label = cur == null ? 'All pages complete' : 'Page $cur of ${b.totalPages}';
    return Prog(n, b.totalPages, 0, label: label);
  }

  void markBookPageComplete(Student s, ClassBook b, int pageNo, String date, String grade) {
    final d = validDate(date) ? date : kToday;
    s.bookPageDate[_bookKey(b.id, pageNo)] = d;
    s.bookPageGrade[_bookKey(b.id, pageNo)] = grade;
    notes.add(Note(s.parentPhone, '${b.name} page $pageNo completed for ${s.name} on ${nice(d)} - $grade'));
    notifyListeners();
  }

  // Replaces a student's Book-progress for every Book of their class with
  // what the database has (same reload/refresh/other-device purpose as
  // setPageProgressFromDb).
  void setBookProgressFromDb(Student s, Map<String, String> dates, Map<String, String> grades) {
    s.bookPageDate = dates;
    s.bookPageGrade = grades;
    notifyListeners();
  }

  void setClassBooksFromDb(ClassDef cd, List<ClassBook> books) {
    cd.books = books;
    notifyListeners();
  }

  void addClassBookLocal(ClassDef cd, ClassBook b) {
    cd.books.add(b);
    notifyListeners();
  }

  void updateClassBookLocal(ClassBook b, {String? name, String? description, int? totalPages, int? sequenceOrder}) {
    if (name != null) b.name = name;
    if (description != null) b.description = description;
    if (totalPages != null) b.totalPages = totalPages;
    if (sequenceOrder != null) b.sequenceOrder = sequenceOrder;
    notifyListeners();
  }

  void setClassBookActiveLocal(ClassBook b, bool active) {
    b.active = active;
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

  // Replaces the whole chapter plan (all chapter-based classes) with what
  // the database has - called after loading or adding a chapter.
  void setChaptersFromDb(Map<int, List<Chapter>> byClass) {
    chapters
      ..clear()
      ..addAll(byClass);
    notifyListeners();
  }

  // Replaces one student's chapter-progress with what the database has.
  void setChapterProgressFromDb(Student s, Map<int, String> dates, Map<int, String> grades) {
    s.chDate = dates;
    s.chGrade = grades;
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

  // Pushes database-loaded attendance (today's marks + each student's
  // historical absent dates) into the in-memory model in one go, replacing
  // the old local-only, resets-on-refresh version of the same data.
  void setTodayAttendanceFromDb(Map<int, String> att) {
    todayAtt
      ..clear()
      ..addAll(att);
    notifyListeners();
  }

  // Attendance for dates other than today (last few days, so a Teacher can
  // review/edit recent attendance from the Mark Attendance screen). todayAtt
  // above stays the live, realtime-synced view of just today's marks; this
  // cache additionally holds whichever other recent dates have been loaded.
  // attForDate/setAttOneForDate route through todayAtt for kToday so there
  // is exactly one source of truth for "today", never two copies that could
  // drift apart.
  final Map<String, Map<int, String>> attByDate = {};

  Map<int, String> attForDate(String date) => date == kToday ? todayAtt : (attByDate[date] ?? const {});

  void setAttByDateFromDb(String date, Map<int, String> att) {
    if (date == kToday) {
      setTodayAttendanceFromDb(att);
    } else {
      attByDate[date] = att;
      notifyListeners();
    }
  }

  void setAttOneForDate(String date, int studentId, String v) {
    if (date == kToday) {
      setAtt(studentId, v);
    } else {
      (attByDate[date] ??= {})[studentId] = v;
      notifyListeners();
    }
  }

  void setAbsentHistoryFromDb(Map<int, List<String>> byLocalId) {
    for (final s in students) {
      s.absent = List<String>.from(byLocalId[s.id] ?? []);
    }
    notifyListeners();
  }

  void setTeacherAttFromDb(String teacherName, String status) {
    teacherAtt[teacherName] = status;
    notifyListeners();
  }

  // ---------- Maktab Events / Holidays ----------
  final List<MaktabEvent> events = [];

  void setEventsFromDb(List<MaktabEvent> list) {
    events
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  void addEventLocal(MaktabEvent e) {
    events.add(e);
    notifyListeners();
  }

  void cancelEventLocal(MaktabEvent e, String reason) {
    e.cancelled = true;
    e.cancelReason = reason;
    notifyListeners();
  }

  List<MaktabEvent> eventsFor(String madrasa, {bool includeCancelled = true}) =>
      events.where((e) => e.madrasa == madrasa && (includeCancelled || !e.cancelled)).toList()..sort((a, b) => b.date.compareTo(a.date));

  // The active Event/Holiday (if any) blocking normal attendance for this
  // Maktab/date/batch - null means attendance can be submitted normally.
  MaktabEvent? blockingEventFor(String madrasa, String date, String batch) {
    for (final e in events) {
      if (e.cancelled || e.madrasa != madrasa || e.date != date) continue;
      if (e.batch == null || e.batch == batch) return e;
    }
    return null;
  }

  // ---------- Attendance Sessions (final-submission lock + correction audit) ----------
  // Keyed by Maktab name + local class id + batch + date so the UI can look
  // up "has this exact session already been finally submitted" without a
  // round trip, right next to todayAtt (which only tracks each student's
  // own Present/Absent/Pending mark, not the session as a whole).
  final Map<String, AttendanceSessionMeta> attendanceSessions = {};

  String attSessionKey(String madrasa, int cls, String batch, String date) => '$madrasa|$cls|$batch|$date';

  AttendanceSessionMeta? sessionFor(String madrasa, int cls, String batch, String date) => attendanceSessions[attSessionKey(madrasa, cls, batch, date)];

  void setAttendanceSessionsFromDb(Map<String, AttendanceSessionMeta> map) {
    attendanceSessions
      ..clear()
      ..addAll(map);
    notifyListeners();
  }

  void setAttendanceSessionLocal(String madrasa, int cls, String batch, String date, AttendanceSessionMeta meta) {
    attendanceSessions[attSessionKey(madrasa, cls, batch, date)] = meta;
    notifyListeners();
  }

  // The Teacher assigned to this Maktab+class, if teacher_class_assignments
  // has one on file - display only (Working Committee Maktab Timings
  // screen); attendance submission itself doesn't depend on this.
  String? teacherNameFor(String madrasa, int cls) {
    for (final t in teacherAccounts) {
      if (t.myClasses.any((a) => a.madrasa == madrasa && a.cls == cls)) return t.name;
    }
    return null;
  }

  // Updates the in-memory model with the outcome of a successful
  // submit_attendance_session call: every submitted student's status is no
  // longer Pending, and each Absent student's date is recorded in their
  // local absent-history (kept in sync with the database so attPct and
  // other already-loaded summaries don't wait for the next full reload).
  void recordSessionSubmission({required List<Student> present, required List<Student> absent, required String date}) {
    final map = date == kToday ? todayAtt : (attByDate[date] ??= {});
    for (final s in present) {
      map[s.id] = 'P';
      s.absent.remove(date);
    }
    for (final s in absent) {
      map[s.id] = 'A';
      if (!s.absent.contains(date)) s.absent.add(date);
    }
    notifyListeners();
  }

  // Public entry point for the new session-based submit flow to send (and
  // log) the absence WhatsApp alert for one student, after the caller has
  // already claimed the send via student_attendance.absence_notified_at so
  // it can only happen once per student+date, across devices and retries.
  void sendAbsenceNotification(Student s, String madrasa, String date) => _sendAbsenceWhatsApp(s, madrasa, date);

  // ---------- Notification Templates ----------
  // Loaded from public.notification_templates after login. Every real or
  // simulated notification send site (absence, fee reminder, Sadqa Peti,
  // course completion, event/holiday) looks up the active template for
  // its key here instead of using a hardcoded string, falling back to the
  // original hardcoded wording only if the row is somehow missing.
  final List<NotifTemplate> notifTemplates = [];

  void setNotifTemplatesFromDb(List<NotifTemplate> list) {
    notifTemplates
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  NotifTemplate? templateFor(String key) {
    for (final t in notifTemplates) {
      if (t.key == key && t.active) return t;
    }
    return null;
  }

  void updateNotifTemplateLocal(NotifTemplate t, {String? body, List<String>? variables, bool? active}) {
    if (body != null) t.body = body;
    if (variables != null) t.variables = variables;
    if (active != null) t.active = active;
    notifyListeners();
  }

  // ---------- About Us ----------
  // Loaded from public.about_us - replaces the hardcoded _aboutSections
  // list that used to live directly in guest_tools.dart.
  AboutUsContent? aboutUs;

  void setAboutUsFromDb(AboutUsContent c) {
    aboutUs = c;
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
  // Replaces the whole list with what was just loaded from Supabase
  // (public.students). Called after login, same pattern as
  // setMadrasasFromDb/setClassDefsFromDb. Keeps using a local incrementing
  // int id (not the database's uuid) because that int id is already the
  // key for attendance, fees and course-enrollment data elsewhere in this
  // file - those still live only in memory and aren't wired to the
  // database yet, so they need a stable local key to keep working.
  void setStudentsFromDb(List<Student> list) {
    students
      ..clear()
      ..addAll(list);
    nextId = (students.map((s) => s.id).fold(0, (a, b) => a > b ? a : b)) + 1;
    notifyListeners();
  }

  // Adds one student that was just saved to Supabase, assigning it a fresh
  // local id the same way addStudent does for the pure-demo path.
  void addStudentFromRemote({
    required String key,
    required String name,
    required String gender,
    required int cls,
    required String madrasa,
    required String start,
    required String parentPhone,
    String studentPhone = '',
    bool aadhaar = true,
    String aadhaarNumber = '',
    String address = '',
    String? dob,
    String fatherName = '',
    String guardianRelation = 'Father',
    String batch = 'Morning',
    String? dbId,
  }) {
    final id = nextId++;
    students.add(Student(
        id: id,
        key: key,
        name: name,
        gender: gender,
        cls: cls,
        madrasa: madrasa,
        start: start,
        parentPhone: parentPhone,
        studentPhone: studentPhone,
        aadhaar: aadhaar,
        aadhaarNumber: aadhaarNumber,
        address: address,
        dob: dob,
        fatherName: fatherName,
        guardianRelation: guardianRelation,
        batch: batch,
        dbId: dbId));
    notifyListeners();
  }

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
    notes.add(Note(parentPhone, '${s.name} was added to $madrasa Maktab. ID ${s.key}'));
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
  // Every month from the student's own admission (or last promotion, which
  // resets admission_date to a fresh start) through the current real month,
  // inclusive - not a fixed list, so this keeps working next year without
  // another code change.
  List<String> feeMonths(Student s) {
    final start = pd(s.start);
    final now = pd(kToday);
    var y = start.year, m = start.month;
    final months = <String>[];
    while (y < now.year || (y == now.year && m <= now.month)) {
      months.add('${kMonthAbbrevs[m - 1]} $y');
      m++;
      if (m > 12) {
        m = 1;
        y++;
      }
    }
    return months;
  }

  bool isPaid(int id, String m) => paid[id]?.contains(m) ?? false;

  // Replaces the whole paid-months model with what the database has.
  void setPaidFromDb(Map<int, Set<String>> byStudentId) {
    paid
      ..clear()
      ..addAll(byStudentId);
    notifyListeners();
  }

  String pay(Student s, String m) {
    paid.putIfAbsent(s.id, () => <String>{}).add(m);
    receiptNo++;
    final yr = pd(kToday).year;
    notes.add(Note(s.parentPhone, 'Fee for $m received (Rs. 200). $m is complete.'));
    notifyListeners();
    return 'Receipt R-$yr-$receiptNo created. $m marked Complete for ${s.name}.';
  }

  int completeCount(String m) => inBranch('Hanfi').where((s) => feeMonths(s).contains(m) && isPaid(s.id, m)).length;
  int totalFor(String m) => inBranch('Hanfi').where((s) => feeMonths(s).contains(m)).length;

  // ---------- leave ----------
  String? applyLeave(String type, String from, String to, String reason, {String madrasa = ''}) {
    if (!validDate(from) || !validDate(to)) return 'Enter dates as yyyy-mm-dd';
    if (reason.trim().length < 5) return 'Reason is required';
    leaves.add(Leave(leaves.length + 1, user!.name, type, from, to, reason.trim(), madrasa: madrasa));
    notifyListeners();
    return null;
  }

  void decideLeave(Leave l, bool ok, String remark) {
    l.status = ok ? 'Approved' : 'Rejected';
    l.remark = remark;
    l.by = user!.name;
    notifyListeners();
  }

  void setLeavesFromDb(List<Leave> list) {
    leaves
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  // ---------- complaints ----------
  void setComplaintsFromDb(List<Complaint> list) {
    complaints
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

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
  void setAnnouncementsFromDb(List<Announcement> list) {
    announcements
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  void postAnnouncement(String title, String msg, String priority) {
    announcements.add(Announcement(title, msg, priority));
    notifyListeners();
  }

  void withdraw(Announcement a) {
    a.active = false;
    notifyListeners();
  }

  // ---------- roles and committee ----------
  void setCustomRolesFromDb(Map<String, Set<String>> roles) {
    customRoles
      ..clear()
      ..addAll(roles);
    notifyListeners();
  }

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

  // Real committee members (same shape as teacherAccounts below - real
  // accounts from public.user_profiles plus anyone invited but not yet
  // joined from public.pending_role_invites).
  final List<Account> committeeAccounts = [];
  void setCommitteeFromDb(List<Account> list) {
    committeeAccounts
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  // Real teachers (from public.user_profiles, once they've logged in at
  // least once) plus anyone invited but not yet joined (from
  // public.pending_role_invites) - what the Master Data screen's Teachers
  // section actually shows, replacing the old local-demo list above.
  final List<Account> teacherAccounts = [];
  void setTeachersFromDb(List<Account> list) {
    teacherAccounts
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  void setTeacherActive(Account a, bool v) {
    a.active = v;
    notifyListeners();
  }

  // Real Maktab Admins (same shape as committeeAccounts/teacherAccounts
  // above: real accounts from public.user_profiles, base_role =
  // 'madrasa_admin', plus anyone invited but not yet joined from
  // public.pending_role_invites). Lets Master Data's "Maktab Admins"
  // section show and deactivate/reactivate them, the same as Teachers and
  // Committee Members already could - previously this section only had an
  // invite form, with no way to see who already had admin access or to
  // revoke it short of the Roles & Permissions phone-number lookup tool.
  final List<Account> maktabAdminAccounts = [];
  void setMaktabAdminsFromDb(List<Account> list) {
    maktabAdminAccounts
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  // Generic active/inactive flip for an already-real account of any role
  // (Maktab Admin, Committee Member - Teacher keeps its own
  // setTeacherActive for the message it fires on an attendance-related
  // screen elsewhere). Used by Master Data's Maktab Admins/Committee
  // Members switches so toggling back on (reactivating) is just as easy as
  // toggling off, instead of the one-way "Remove" button that used to be
  // the only option for Committee Members.
  void setAccountActive(Account a, bool v) {
    a.active = v;
    notifyListeners();
  }

  String? addTeacher(String phone, String name, List<String> madrasasList) {
    if (phone.length != 10) return 'Enter a 10-digit mobile number';
    if (name.trim().isEmpty) return 'Enter the name';
    if (madrasasList.isEmpty) return 'Choose at least one Maktab';
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
    if (madrasa.isEmpty || classIds.isEmpty) return 'Choose a Maktab and at least one class';
    final acc = users.values.firstWhere((u) => u.name == teacherName && u.role == 'teacher', orElse: () => Account('', '', ''));
    if (acc.phone.isEmpty) return 'Teacher not found';
    if (!acc.teachMadrasas.contains(madrasa)) acc.teachMadrasas.add(madrasa);
    teacherAssignments.putIfAbsent(teacherName, () => {})[madrasa] = classIds;
    notifyListeners();
    return null;
  }

  // ---------- Sadqa Peti (donation box) module ----------
  final List<SadqaPeti> sadqaPetis = [];
  final List<SadqaCollection> sadqaCollections = [];
  // Every collector-access row this account can see: Super Admin sees all
  // (RLS: sadqa_collectors_super_all), anyone else only sees their own
  // (RLS: sadqa_collectors_self_read) - which is exactly what's needed to
  // decide whether to show the "Sadqa Peti Collection" entry to them.
  final List<SadqaCollector> sadqaCollectors = [];

  void setSadqaPetisFromDb(List<SadqaPeti> list) {
    sadqaPetis
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  void setSadqaCollectionsFromDb(List<SadqaCollection> list) {
    sadqaCollections
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  void setSadqaCollectorsFromDb(List<SadqaCollector> list) {
    sadqaCollectors
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  // Whether the current account may open the Sadqa Peti Collection screen
  // at all: Super Admin always can; anyone else needs at least one
  // collector-access row (global, peti_id == null, or for a specific box).
  bool get canRecordSadqaCollections => user?.role == 'super' || sadqaCollectors.isNotEmpty;

  bool isSadqaCollectorFor(String petiId) =>
      user?.role == 'super' || sadqaCollectors.any((c) => c.petiId == null || c.petiId == petiId);

  // ---------- Monthly Member Contribution module (Super Admin only) ----------
  final List<MonthlyMember> monthlyMembers = [];
  // Every due row for every member, across every month - small enough a
  // dataset for one Maktab community that loading it all at once (same as
  // teachers/students elsewhere in this app) keeps the dashboard and
  // reports simple, instead of re-querying per screen.
  final List<MonthlyDue> monthlyDues = [];

  void setMonthlyMembersFromDb(List<MonthlyMember> list) {
    monthlyMembers
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  void setMonthlyDuesFromDb(List<MonthlyDue> list) {
    monthlyDues
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  List<MonthlyDue> duesForMember(String memberId) => monthlyDues.where((d) => d.memberId == memberId).toList()
    ..sort((a, b) => (a.year * 12 + a.month).compareTo(b.year * 12 + b.month));

  MonthlyMember? monthlyMemberById(String id) {
    for (final m in monthlyMembers) {
      if (m.id == id) return m;
    }
    return null;
  }

  // ---------- Student Results Management module ----------
  // Academic Years: public.academic_years already existed in the database
  // before this feature (0 rows, never wired to any screen) - this is the
  // first thing that actually reads/writes it, not a new invented concept.
  final List<AcademicYear> academicYears = [];
  // Examinations this account is allowed to see (RLS: Super Admin sees
  // everything, a Result Manager sees their branch(es), a student/parent
  // only ever sees Published ones with a result of their own - see
  // loadMyResults() in results.dart, which queries exam_results directly
  // rather than populating this list).
  final List<Examination> examinations = [];
  // "Published"/"corrected" notifications for the signed-in student or
  // the child(ren) linked to a signed-in parent - public.result_notifications.
  final List<ResultNotif> resultNotifs = [];

  void setAcademicYearsFromDb(List<AcademicYear> list) {
    academicYears
      ..clear()
      ..addAll(list..sort((a, b) => b.startsOn.compareTo(a.startsOn)));
    notifyListeners();
  }

  void setExaminationsFromDb(List<Examination> list) {
    examinations
      ..clear()
      ..addAll(list..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
    notifyListeners();
  }

  void setResultNotifsFromDb(List<ResultNotif> list) {
    resultNotifs
      ..clear()
      ..addAll(list..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
    notifyListeners();
  }

  int get unreadResultNotifCount => resultNotifs.where((n) => !n.isRead).length;

  // ---------- Super Admin "missing attendance" notifications ----------
  // Generated server-side by the nightly 11:00 PM IST pg_cron job
  // (public.run_missing_attendance_check) - this list is just what got
  // loaded from public.admin_notifications. Empty/untouched for any
  // non-Super-Admin account (loadAdminNotifications() below is a no-op
  // for them, and RLS would refuse the query anyway).
  final List<AdminNotification> adminNotifications = [];

  void setAdminNotificationsFromDb(List<AdminNotification> list) {
    adminNotifications
      ..clear()
      ..addAll(list..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
    notifyListeners();
  }

  int get unreadAdminNotifCount => adminNotifications.where((n) => !n.isRead).length;

  void markAdminNotificationReadLocal(String id) {
    for (final n in adminNotifications) {
      if (n.id == id) n.isRead = true;
    }
    notifyListeners();
  }

  void markAllAdminNotificationsReadLocal() {
    for (final n in adminNotifications) {
      n.isRead = true;
    }
    notifyListeners();
  }
}

class ChapPlan {
  final String title;
  final String plan;
  final String? done;
  final String grade;
  ChapPlan(this.title, this.plan, this.done, this.grade);
}

// One row of public.admin_notifications - a missing-attendance (or
// timing-not-configured) alert for Super Admin, generated server-side.
// Marking it read only flips is_read/read_at; it's never deleted, and a
// later-submitted session flips status to 'Resolved' without touching the
// original record - so this is real history, not a disappearing toast.
class AdminNotification {
  final String id;
  final String notifType; // 'missing_attendance' | 'configuration_missing'
  final String title;
  final String message;
  final String madrasaName;
  final String? category;
  final String? className;
  final String? batch; // Morning/Afternoon/Evening; null for configuration_missing
  final String attendanceDate; // yyyy-mm-dd
  final String? teacherName; // null => no teacher is assigned
  final String status; // 'Unresolved' | 'Resolved'
  bool isRead;
  final DateTime createdAt;

  AdminNotification({
    required this.id,
    required this.notifType,
    required this.title,
    required this.message,
    required this.madrasaName,
    this.category,
    this.className,
    this.batch,
    required this.attendanceDate,
    this.teacherName,
    required this.status,
    required this.isRead,
    required this.createdAt,
  });

  factory AdminNotification.fromJson(Map<String, dynamic> j) => AdminNotification(
        id: j['id'] as String,
        notifType: (j['notif_type'] as String?) ?? 'missing_attendance',
        title: (j['title'] as String?) ?? '',
        message: (j['message'] as String?) ?? '',
        madrasaName: (j['madrasa_name'] as String?) ?? '',
        category: j['category'] as String?,
        className: j['class_name'] as String?,
        batch: j['batch'] as String?,
        attendanceDate: (j['attendance_date'] as String?) ?? '',
        teacherName: j['teacher_name'] as String?,
        status: (j['status'] as String?) ?? 'Unresolved',
        isRead: (j['is_read'] as bool?) ?? false,
        createdAt: DateTime.tryParse('${j['created_at']}') ?? DateTime.now(),
      );
}

// ---------------- Student Results Management module models ----------------
// public.academic_years - existed before this feature, never used.
class AcademicYear {
  final String id;
  String label;
  String startsOn;
  String endsOn;
  bool active;
  AcademicYear({required this.id, required this.label, required this.startsOn, required this.endsOn, this.active = true});
  factory AcademicYear.fromJson(Map<String, dynamic> j) => AcademicYear(
        id: j['id'] as String,
        label: (j['label'] as String?) ?? '',
        startsOn: (j['starts_on'] as String?) ?? '',
        endsOn: (j['ends_on'] as String?) ?? '',
        active: (j['is_active'] as bool?) ?? true,
      );
}

// One examination/result record for one class in one Maktab in one
// academic year - public.examinations. The subjects tested and the
// marks themselves are loaded separately, on demand, by the exam detail
// screen (see ExamSubject/ExamResultRow below and results.dart).
class Examination {
  final String id;
  final String madrasaId;
  final String madrasaName;
  final String classId;
  final int classNo;
  final String className;
  final String academicYearId;
  final String academicYearLabel;
  String name;
  String startsOn;
  String? endsOn;
  String? remarks;
  String status; // Draft | Ready for Review | Published
  final DateTime createdAt;
  final String? submittedAt;
  final String? publishedAt;
  Examination({
    required this.id,
    required this.madrasaId,
    required this.madrasaName,
    required this.classId,
    required this.classNo,
    required this.className,
    required this.academicYearId,
    required this.academicYearLabel,
    required this.name,
    required this.startsOn,
    this.endsOn,
    this.remarks,
    this.status = 'Draft',
    required this.createdAt,
    this.submittedAt,
    this.publishedAt,
  });
  factory Examination.fromJson(Map<String, dynamic> j) => Examination(
        id: j['id'] as String,
        madrasaId: (j['madrasa_id'] as String?) ?? '',
        madrasaName: ((j['madrasas'] as Map?)?['name'] as String?) ?? '',
        classId: (j['class_id'] as String?) ?? '',
        classNo: ((j['classes'] as Map?)?['class_no'] as int?) ?? 0,
        className: ((j['classes'] as Map?)?['name'] as String?) ?? '',
        academicYearId: (j['academic_year_id'] as String?) ?? '',
        academicYearLabel: ((j['academic_years'] as Map?)?['label'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        startsOn: (j['starts_on'] as String?) ?? '',
        endsOn: j['ends_on'] as String?,
        remarks: j['remarks'] as String?,
        status: (j['status'] as String?) ?? 'Draft',
        createdAt: DateTime.tryParse('${j['created_at']}') ?? DateTime.now(),
        submittedAt: j['submitted_at'] as String?,
        publishedAt: j['published_at'] as String?,
      );
}

// One subject tested within an examination - public.exam_subjects. Built
// from the class's own existing Books (class_books) or Add-on Courses,
// never invented - see "Subject/Course" picker in results.dart.
class ExamSubject {
  final String id;
  final String examId;
  String subjectName;
  final String? sourceBookId;
  final String? sourceCourseId;
  num maxMarks;
  num? passingMarks;
  int sortOrder;
  ExamSubject({required this.id, required this.examId, required this.subjectName, this.sourceBookId, this.sourceCourseId, required this.maxMarks, this.passingMarks, this.sortOrder = 0});
  factory ExamSubject.fromJson(Map<String, dynamic> j) => ExamSubject(
        id: j['id'] as String,
        examId: (j['exam_id'] as String?) ?? '',
        subjectName: (j['subject_name'] as String?) ?? '',
        sourceBookId: j['source_book_id'] as String?,
        sourceCourseId: j['source_course_id'] as String?,
        maxMarks: (j['max_marks'] as num?) ?? 0,
        passingMarks: j['passing_marks'] as num?,
        sortOrder: (j['sort_order'] as int?) ?? 0,
      );
}

// One student's mark for one subject within an examination -
// public.exam_results. `id` is null when nothing has been entered yet for
// this student/subject pair - the UI fetches the full class roster and
// fills in a blank row for anyone without a saved result, per "Clearly
// identify students whose marks have not yet been entered."
class ExamResultRow {
  final String? id;
  final String examSubjectId;
  final String studentId;
  num? marksObtained;
  bool isAbsent;
  String? remarks;
  bool isDeleted;
  String? deleteReason;
  ExamResultRow({this.id, required this.examSubjectId, required this.studentId, this.marksObtained, this.isAbsent = false, this.remarks, this.isDeleted = false, this.deleteReason});
  factory ExamResultRow.fromJson(Map<String, dynamic> j) => ExamResultRow(
        id: j['id'] as String?,
        examSubjectId: (j['exam_subject_id'] as String?) ?? '',
        studentId: (j['student_id'] as String?) ?? '',
        marksObtained: j['marks_obtained'] as num?,
        isAbsent: (j['is_absent'] as bool?) ?? false,
        remarks: j['remarks'] as String?,
        isDeleted: (j['is_deleted'] as bool?) ?? false,
        deleteReason: j['delete_reason'] as String?,
      );
}

// One correction/delete/restore history entry - public.exam_result_audit.
class ResultAuditRow {
  final int id;
  final String? studentId;
  final String action;
  final num? oldMarks;
  final num? newMarks;
  final String reason;
  final String? actorRole;
  final DateTime createdAt;
  ResultAuditRow({required this.id, this.studentId, required this.action, this.oldMarks, this.newMarks, required this.reason, this.actorRole, required this.createdAt});
  factory ResultAuditRow.fromJson(Map<String, dynamic> j) => ResultAuditRow(
        id: j['id'] as int,
        studentId: j['student_id'] as String?,
        action: (j['action'] as String?) ?? '',
        oldMarks: j['old_marks'] as num?,
        newMarks: j['new_marks'] as num?,
        reason: (j['reason'] as String?) ?? '',
        actorRole: j['actor_role'] as String?,
        createdAt: DateTime.tryParse('${j['created_at']}') ?? DateTime.now(),
      );
}

// "Your result has been published/corrected" - public.result_notifications,
// for the Student / Parent "My Results" bell. Never carries marks.
class ResultNotif {
  final String id;
  final String examId;
  String examName;
  final String studentId;
  final String kind; // published | corrected
  bool isRead;
  final DateTime createdAt;
  ResultNotif({required this.id, required this.examId, this.examName = '', required this.studentId, required this.kind, this.isRead = false, required this.createdAt});
  factory ResultNotif.fromJson(Map<String, dynamic> j) => ResultNotif(
        id: j['id'] as String,
        examId: (j['exam_id'] as String?) ?? '',
        examName: ((j['examinations'] as Map?)?['name'] as String?) ?? '',
        studentId: (j['student_id'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'published',
        isRead: (j['is_read'] as bool?) ?? false,
        createdAt: DateTime.tryParse('${j['created_at']}') ?? DateTime.now(),
      );
}

// ---------------- Sadqa Peti (donation box) module models ----------------
// One donation box placed at a shop - public.sadqa_petis.
class SadqaPeti {
  final String id;
  final String petiCode;
  String shopkeeperName;
  String shopkeeperPhone;
  String shopName;
  String? shopAddress;
  String? area;
  String boxGivenDate;
  String? boxNumber;
  int frequencyMonths;
  String? lastCollectionDate;
  String? nextCollectionDate;
  String status; // 'Active' | 'Inactive'
  String? remarks;

  SadqaPeti({
    required this.id,
    required this.petiCode,
    required this.shopkeeperName,
    required this.shopkeeperPhone,
    required this.shopName,
    this.shopAddress,
    this.area,
    required this.boxGivenDate,
    this.boxNumber,
    this.frequencyMonths = 2,
    this.lastCollectionDate,
    this.nextCollectionDate,
    this.status = 'Active',
    this.remarks,
  });

  factory SadqaPeti.fromJson(Map<String, dynamic> j) => SadqaPeti(
        id: j['id'] as String,
        petiCode: (j['peti_code'] as String?) ?? '',
        shopkeeperName: (j['shopkeeper_name'] as String?) ?? '',
        shopkeeperPhone: (j['shopkeeper_phone'] as String?) ?? '',
        shopName: (j['shop_name'] as String?) ?? '',
        shopAddress: j['shop_address'] as String?,
        area: j['area'] as String?,
        boxGivenDate: (j['box_given_date'] as String?) ?? '',
        boxNumber: j['box_number'] as String?,
        frequencyMonths: (j['collection_frequency_months'] as int?) ?? 2,
        lastCollectionDate: j['last_collection_date'] as String?,
        nextCollectionDate: j['next_collection_date'] as String?,
        status: (j['status'] as String?) ?? 'Active',
        remarks: j['remarks'] as String?,
      );

  // Derived schedule status (separate from the box's own Active/Inactive
  // lifecycle status) - req: Upcoming / Due / Overdue / Collected, computed
  // live from the stored dates rather than kept as another stored column
  // that could drift out of sync with them.
  String get scheduleStatus {
    if (status == 'Inactive') return 'Inactive';
    if (nextCollectionDate == null) return 'Upcoming';
    final next = DateTime.tryParse(nextCollectionDate!);
    if (next == null) return 'Upcoming';
    final today = DateTime.now();
    final d0 = DateTime(today.year, today.month, today.day);
    final diff = d0.difference(next).inDays;
    if (diff > 7) return 'Overdue';
    if (diff >= 0) return 'Due';
    return 'Upcoming';
  }
}

// One recorded collection transaction - public.sadqa_peti_collections.
class SadqaCollection {
  final String id;
  final String petiId;
  final String txnNo;
  final String receiptNo;
  final String collectedAt;
  final double amount;
  final String collectorId;
  String? collectorName; // filled in client-side from a known accounts list
  final String? remarks;
  final String status; // 'Confirmed' | 'Reversed'
  final String? reversalReason;

  SadqaCollection({
    required this.id,
    required this.petiId,
    required this.txnNo,
    required this.receiptNo,
    required this.collectedAt,
    required this.amount,
    required this.collectorId,
    this.collectorName,
    this.remarks,
    this.status = 'Confirmed',
    this.reversalReason,
  });

  factory SadqaCollection.fromJson(Map<String, dynamic> j) => SadqaCollection(
        id: j['id'] as String,
        petiId: j['peti_id'] as String,
        txnNo: (j['txn_no'] as String?) ?? '',
        receiptNo: (j['receipt_no'] as String?) ?? '',
        collectedAt: (j['collected_at'] as String?) ?? '',
        amount: double.tryParse('${j['amount']}') ?? 0,
        collectorId: (j['collector_id'] as String?) ?? '',
        remarks: j['remarks'] as String?,
        status: (j['status'] as String?) ?? 'Confirmed',
        reversalReason: j['reversal_reason'] as String?,
      );
}

// One collector-access grant - public.sadqa_peti_collectors.
// petiId == null means access to every Sadqa Peti (a global collector).
class SadqaCollector {
  final String id;
  final String? petiId;
  final String userId;
  String userName; // filled in client-side from a known accounts list

  SadqaCollector({required this.id, this.petiId, required this.userId, this.userName = ''});

  factory SadqaCollector.fromJson(Map<String, dynamic> j) => SadqaCollector(
        id: j['id'] as String,
        petiId: j['peti_id'] as String?,
        userId: (j['user_id'] as String?) ?? '',
      );
}

// ---------------- Monthly Member Contribution module models ----------------
// One standing community member who pays an ongoing monthly contribution -
// public.monthly_members. Not a student and not an app user (no login) -
// just a name, phone and amount the Super Admin tracks and messages.
class MonthlyMember {
  final String id;
  String fullName;
  String phone;
  double monthlyAmount;
  String joiningDate; // yyyy-mm-dd
  String? address;
  String? remarks;
  bool isActive;

  MonthlyMember({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.monthlyAmount,
    required this.joiningDate,
    this.address,
    this.remarks,
    this.isActive = true,
  });

  factory MonthlyMember.fromJson(Map<String, dynamic> j) => MonthlyMember(
        id: j['id'] as String,
        fullName: (j['full_name'] as String?) ?? '',
        phone: (j['phone'] as String?) ?? '',
        monthlyAmount: double.tryParse('${j['monthly_amount']}') ?? 0,
        joiningDate: (j['joining_date'] as String?) ?? '',
        address: j['address'] as String?,
        remarks: j['remarks'] as String?,
        isActive: (j['is_active'] as bool?) ?? true,
      );
}

// One member's contribution obligation for one calendar month -
// public.monthly_dues. amount_paid/status are derived server-side (a
// trigger on monthly_payments) from the actual saved payments, never set
// directly by the client, so they can't drift out of sync with reality.
class MonthlyDue {
  final String id;
  final String memberId;
  final int year;
  final int month;
  double amountDue;
  double amountPaid;
  String status; // due | part_paid | complete | overdue

  MonthlyDue({
    required this.id,
    required this.memberId,
    required this.year,
    required this.month,
    required this.amountDue,
    required this.amountPaid,
    required this.status,
  });

  factory MonthlyDue.fromJson(Map<String, dynamic> j) => MonthlyDue(
        id: j['id'] as String,
        memberId: (j['member_id'] as String?) ?? '',
        year: (j['year'] as int?) ?? (j['year'] is num ? (j['year'] as num).toInt() : 0),
        month: (j['month'] as int?) ?? (j['month'] is num ? (j['month'] as num).toInt() : 0),
        amountDue: double.tryParse('${j['amount_due']}') ?? 0,
        amountPaid: double.tryParse('${j['amount_paid']}') ?? 0,
        status: (j['status'] as String?) ?? 'due',
      );

  double get outstanding => amountDue - amountPaid < 0 ? 0 : amountDue - amountPaid;

  String get displayStatus {
    switch (status) {
      case 'complete':
        return 'Paid';
      case 'part_paid':
        return 'Partially Paid';
      case 'overdue':
        return 'Overdue';
      default:
        return 'Due';
    }
  }

  String get monthLabel => '${AppState.kMonthAbbrevs[month - 1]} $year';
}

// One recorded installment against a due - public.monthly_payments.
class MonthlyPayment {
  final String id;
  final String dueId;
  final String memberId;
  final double amount;
  final String method; // cash | bank_transfer | upi | other
  final String? txnRef;
  final String? remarks;
  final String paidAt;

  MonthlyPayment({
    required this.id,
    required this.dueId,
    required this.memberId,
    required this.amount,
    required this.method,
    this.txnRef,
    this.remarks,
    required this.paidAt,
  });

  factory MonthlyPayment.fromJson(Map<String, dynamic> j) => MonthlyPayment(
        id: j['id'] as String,
        dueId: (j['due_id'] as String?) ?? '',
        memberId: (j['member_id'] as String?) ?? '',
        amount: double.tryParse('${j['amount']}') ?? 0,
        method: (j['method'] as String?) ?? 'cash',
        txnRef: j['txn_ref'] as String?,
        remarks: j['remarks'] as String?,
        paidAt: (j['paid_at'] as String?) ?? '',
      );
}

// One WhatsApp/SMS send attempt (receipt or reminder) - public.monthly_notifications.
class MonthlyNotificationLog {
  final String id;
  final String memberId;
  final String? dueId;
  final String? paymentId;
  final String notifType; // payment_receipt | due_reminder
  final String channel;
  final String status; // Pending | Sent | Delivered | Failed
  final String? errorDetail;
  final String createdAt;

  MonthlyNotificationLog({
    required this.id,
    required this.memberId,
    this.dueId,
    this.paymentId,
    required this.notifType,
    required this.channel,
    required this.status,
    this.errorDetail,
    required this.createdAt,
  });

  factory MonthlyNotificationLog.fromJson(Map<String, dynamic> j) => MonthlyNotificationLog(
        id: j['id'] as String,
        memberId: (j['member_id'] as String?) ?? '',
        dueId: j['due_id'] as String?,
        paymentId: j['payment_id'] as String?,
        notifType: (j['notif_type'] as String?) ?? '',
        channel: (j['channel'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'Pending',
        errorDetail: j['error_detail'] as String?,
        createdAt: (j['created_at'] as String?) ?? '',
      );
}
