// ============================================================
// In-app Help: a free, offline, non-AI "screen guide + error help +
// user manual" - no API key, no per-query cost, no network dependency.
// A curated list of topics (what a screen does, how to use it, what its
// common errors mean), searchable by keyword, with a direct "Open this
// screen" jump for whichever topics the signed-in account can actually
// reach (reusing the same role/permission checks the real navigation
// uses - see visibleTo()below - so Help never offers a shortcut into
// something this account isn't allowed to open).
// ============================================================
import 'package:flutter/material.dart';

import 'state.dart';
import 'main.dart';
import 'guest_tools.dart';
import 'results.dart';
import 'sadqa_peti.dart';
import 'monthly_members.dart';

class HelpTopic {
  final String title;
  final String category;
  final List<String> keywords;
  final String body;
  // Which accounts can even see an "Open this screen" button for this
  // topic - plain role names ('super','admin','teacher','parent',
  // 'student','committee'), or 'custom' combined with customPerm (checked
  // the same way the real tab list decides access: userHasPerm).
  final Set<String> roles;
  final String? customPerm;
  // The screen to jump to, if any (some topics - e.g. "Common errors" -
  // are explanation-only). `ownScaffold: true` means the widget already
  // supplies its own Scaffold/AppBar (a guest tool, a standalone report
  // screen) and is pushed as-is; false means it's a plain tab-body widget
  // (the same kind _baseTabsFor hands to the Shell) and gets wrapped in
  // one via pushPage.
  final Widget Function()? screenBuilder;
  final bool ownScaffold;
  HelpTopic({
    required this.title,
    required this.category,
    required this.keywords,
    required this.body,
    this.roles = const {},
    this.customPerm,
    this.screenBuilder,
    this.ownScaffold = false,
  });

  bool visibleTo(Account u) {
    if (roles.contains(u.role)) return true;
    if (u.role == 'custom' && customPerm != null && userHasPerm(u, customPerm!)) return true;
    return false;
  }

  bool matches(String q) {
    final needle = q.toLowerCase();
    if (title.toLowerCase().contains(needle)) return true;
    if (category.toLowerCase().contains(needle)) return true;
    if (keywords.any((k) => k.toLowerCase().contains(needle))) return true;
    if (body.toLowerCase().contains(needle)) return true;
    return false;
  }
}

const Set<String> _allStaff = {'super', 'admin', 'teacher'};
const Set<String> _superOnly = {'super'};
const Set<String> _everyone = {'super', 'admin', 'teacher', 'parent', 'student', 'committee'};

final List<HelpTopic> kHelpTopics = [
  // ---------------- Getting started ----------------
  HelpTopic(
    title: 'Logging in with OTP',
    category: 'Getting started',
    keywords: ['login', 'otp', 'sign in', 'phone', 'password'],
    body: 'There is no password - enter your registered mobile number and you will receive a one-time code (OTP) to sign in. '
        'If you never receive the code: double-check the number is exactly the one a Super Admin registered you with (10 digits, no country code typed twice), '
        'check your SMS inbox/spam, and make sure you have signal. If the number is wrong, ask your Super Admin to correct it from Master Data - Teachers, '
        'or from the Roles screen if you were given a custom role.',
    roles: _everyone,
  ),
  HelpTopic(
    title: 'Switching between my children (Parent)',
    category: 'Getting started',
    keywords: ['parent', 'child', 'kid', 'switch student', 'multiple children'],
    body: 'If more than one of your children is admitted, a child picker appears at the top of Home, Attendance, Syllabus, Fees, and My Child\'s Results. '
        'Tap it to switch which child you are viewing - every screen updates to that child only. Each child\'s attendance, syllabus, fees, and results are kept completely separate.',
    roles: {'parent'},
    screenBuilder: () => const KidHome(),
  ),

  // ---------------- Master Data / setup ----------------
  HelpTopic(
    title: 'Master Data: Makatib, Classes, Books, Add-on Courses',
    category: 'Setup',
    keywords: ['madrasa', 'maktab', 'branch', 'class', 'book', 'course', 'master data'],
    body: 'Master Data is where the building blocks of the whole app are set up: which Makatib (branches) exist, which Classes each one runs, '
        'the Books taught in each class (Class 4 onward), and optional Add-on Courses. Everything else - students, attendance, syllabus, results - '
        'is built on top of these, so get this right first. Only a Super Admin can add/rename a Maktab; Teachers can add/edit Classes and Books from Class 4 onward.',
    roles: _allStaff,
    screenBuilder: () => const MasterDataDashboard(),
  ),
  HelpTopic(
    title: 'Setting up Academic Years',
    category: 'Setup',
    keywords: ['academic year', 'session', 'exam year'],
    body: 'An Academic Year (e.g. "2026-27") must exist before you can create any examination. Super Admin only: open this screen and add a year with a start and end date. '
        'A year is never invented automatically - if the list is empty, add one here first.',
    roles: _superOnly,
    screenBuilder: () => const AcademicYearsAdmin(),
  ),
  HelpTopic(
    title: 'Roles & Permissions / Result Manager',
    category: 'Setup',
    keywords: ['role', 'permission', 'access', 'result manager', 'custom role', 'grant', 'revoke'],
    body: 'Super Admin only. Two ways to give someone access: (1) create a named custom role (e.g. "Accountant") with a fixed set of screens ticked, then assign it to a phone number; '
        'or (2) search a phone number directly and tick individual extra screens for just that person - this never removes any access they already have. '
        'The same screen is used to set up a Result Manager: tick only the specific result permissions that person needs (e.g. Enter Marks but not Publish).',
    roles: _superOnly,
    screenBuilder: () => const RolesView(),
  ),

  // ---------------- Students ----------------
  HelpTopic(
    title: 'Adding a new student',
    category: 'Students',
    keywords: ['admit', 'add student', 'new student', 'registration', 'enrol'],
    body: 'Fill in name, Maktab, gender, class, batch, and a 10-digit parent mobile number (mandatory) - everything else is optional. A 12-digit Aadhaar number is mandatory before saving. '
        'Pick "Father" or "Husband" under Guardian relation before typing the name there - it decides whether that field is treated as the student\'s father\'s or husband\'s name everywhere it is shown, including reports.',
    roles: _allStaff,
    customPerm: 'Students',
    screenBuilder: () => const StudentsView(),
  ),
  HelpTopic(
    title: 'Editing, deactivating or reactivating a student',
    category: 'Students',
    keywords: ['edit student', 'deactivate', 'reactivate', 'inactive', 'delete student'],
    body: 'Open the student from the Students list and tap Edit to fix any detail, including moving them to a different Maktab/Class. '
        'Deactivate (Admin/Super Admin) marks a student Inactive without deleting their record or history - use this for a student who has left, not Delete. '
        'Reactivate is Super Admin only.',
    roles: _allStaff,
    customPerm: 'Students',
    screenBuilder: () => const StudentsView(),
  ),
  HelpTopic(
    title: 'Bulk importing students from a CSV file',
    category: 'Students',
    keywords: ['import', 'csv', 'bulk', 'excel upload'],
    body: 'From the Students screen, tap "Import students from CSV". Download the sample template first - it shows the exact column names expected '
        '(name, gender, class, dob, father_name, guardian_relation, parent_phone, student_phone, address). guardian_relation is optional; leave it blank for "Father". '
        'The app previews every row and flags errors or possible duplicates before anything is saved, so nothing is imported silently wrong.',
    roles: _allStaff,
    customPerm: 'Students',
  ),
  HelpTopic(
    title: 'Possible duplicate student warning',
    category: 'Troubleshooting',
    keywords: ['duplicate', 'already exists', 'error', 'same name'],
    body: 'This warning means an active student with the same name and date of birth already exists. It is not an error - it is a check before you accidentally admit the same child twice. '
        'Verify the details; if it really is a different child, tap "Save anyway". If it is the same child re-entered by mistake, cancel and use the existing record instead, '
        'or ask a Super Admin to deactivate the wrong one and merge any missing details onto the one you keep.',
    roles: _everyone,
  ),

  // ---------------- Attendance & Syllabus ----------------
  HelpTopic(
    title: 'Marking daily attendance',
    category: 'Attendance',
    keywords: ['attendance', 'present', 'absent', 'mark attendance'],
    body: 'Pick the class and batch (Morning/Afternoon/Evening), then mark each student Present or Absent and tap Final Submit. '
        'Once submitted, a session is locked - correcting it afterwards needs a reason and is recorded as a correction, not a silent edit. '
        'Fridays and any recorded Maktab holiday/event are automatically excluded from eligible sessions, so they never count against anyone\'s percentage.',
    roles: {'teacher'},
  ),
  HelpTopic(
    title: 'My child\'s attendance (Parent)',
    category: 'Attendance',
    keywords: ['parent attendance', 'absent history', 'monthly attendance'],
    body: 'Shows your child\'s day-by-day attendance and a monthly summary. "Attendance Not Submitted" is tracked separately from Absent - it means the teacher hasn\'t recorded that session yet, '
        'not that your child missed it.',
    roles: {'parent'},
    screenBuilder: () => const KidAttendance(),
  ),
  HelpTopic(
    title: 'Tracking syllabus / page progress',
    category: 'Syllabus',
    keywords: ['syllabus', 'progress', 'page', 'chapter', 'completed'],
    body: 'Classes 1-3 track progress page by page through the Qaeda/Qur\'an; Class 4 onward tracks chapter by chapter per Book. Mark a page/chapter Completed as the student finishes it - '
        'this is also what drives "Pass and promote" eligibility on the Students screen.',
    roles: _allStaff,
    screenBuilder: () => const TeacherSyllabus(),
  ),

  // ---------------- Fees ----------------
  HelpTopic(
    title: 'Managing student fees',
    category: 'Fees',
    keywords: ['fee', 'payment', 'dues', 'qr code', 'reminder'],
    body: 'Record a fee payment against a student, see who has dues pending, and generate a QR code for parents to pay by scanning. '
        'Only Admin/Super Admin can access this by default; a custom role needs the "Fees" permission explicitly granted on the Roles screen.',
    roles: {'admin', 'super'},
    customPerm: 'Fees',
    screenBuilder: () => const FeesAdmin(),
  ),
  HelpTopic(
    title: 'My child\'s fees (Parent)',
    category: 'Fees',
    keywords: ['parent fees', 'pay fees', 'due amount'],
    body: 'Shows what has been paid and what is still due for your child, with a QR code you can scan to pay directly if your Maktab has that set up.',
    roles: {'parent'},
    screenBuilder: () => const KidFees(),
  ),

  // ---------------- Results ----------------
  HelpTopic(
    title: 'Student Results: creating an examination',
    category: 'Results',
    keywords: ['exam', 'examination', 'marks', 'result', 'create exam'],
    body: 'Needs the "Results Create" permission (or Super Admin). Pick the Maktab, Class and Academic Year, name the examination, then add one or more subjects '
        'with a Maximum Marks and Passing Marks each - subjects are pulled from that class\'s real Books, never invented. An examination stays Draft until you Submit it for review, '
        'and stays invisible to students/parents until someone with Publish permission publishes it.',
    roles: _superOnly,
    customPerm: 'Results Create',
    screenBuilder: () => const ResultsHub(),
  ),
  HelpTopic(
    title: 'Student Results: entering marks',
    category: 'Results',
    keywords: ['enter marks', 'class wise marks', 'marks entry'],
    body: 'Open the examination, tap a subject, and the full eligible class roster loads automatically - you only type the marks (or mark a student Absent). '
        'Percentage and Pass/Fail are calculated live. A student with no marks yet is clearly shown as "not entered", never silently treated as failed.',
    roles: _superOnly,
    customPerm: 'Results Enter Marks',
    screenBuilder: () => const ResultsHub(),
  ),
  HelpTopic(
    title: 'Student Results: submitting, publishing, correcting, deleting',
    category: 'Results',
    keywords: ['publish result', 'submit for review', 'correct marks', 'delete result', 'audit'],
    body: 'Submit moves an examination from Draft to Ready for Review; Publish makes it visible to the affected students/parents. Each needs its own permission. '
        'Correcting a mark on an already-Published exam always asks for a reason and is recorded in the Audit history (old value, new value, who, when, why) - nothing is a silent overwrite. '
        'Delete is soft (recoverable) and also requires a reason; only someone with the Results Delete permission (or Super Admin) can do it.',
    roles: _superOnly,
    customPerm: 'Results Publish',
    screenBuilder: () => const ResultsHub(),
  ),
  HelpTopic(
    title: 'My Results (Student)',
    category: 'Results',
    keywords: ['my results', 'pass fail', 'marksheet'],
    body: 'Shows only your own officially Published results - a Draft or Ready-for-Review examination never appears here, even briefly. You\'ll see a short notification banner when a new result is published or corrected; tap it to dismiss.',
    roles: {'student'},
    screenBuilder: () => const StudentMyResultsScreen(),
  ),
  HelpTopic(
    title: 'My Child\'s Results (Parent)',
    category: 'Results',
    keywords: ['child results', 'pass fail', 'marksheet'],
    body: 'Shows only officially Published results for the child selected in the picker - a Draft or Ready-for-Review examination never appears here, even briefly. You\'ll see a short notification banner when a new result is published or corrected; tap it to dismiss.',
    roles: {'parent'},
    screenBuilder: () => const ParentChildResultsScreen(),
  ),

  // ---------------- Complaints, Sadqa Peti, Monthly Members ----------------
  HelpTopic(
    title: 'Filing or resolving a complaint',
    category: 'Complaints',
    keywords: ['complaint', 'grievance', 'issue', 'report problem'],
    body: 'Anyone can file a complaint describing an issue; it routes to the right role to resolve and tracks status (Open/Resolved). Parents can see the status of complaints they filed.',
    roles: _everyone,
    screenBuilder: () => const ComplaintsView(),
  ),
  HelpTopic(
    title: 'Sadqa Peti (donation box) collection',
    category: 'Sadqa Peti',
    keywords: ['sadqa', 'donation', 'collection box', 'collector'],
    body: 'Super Admin sets up donation boxes and assigns a Collector. The Collector records each collection with a photo-receipt; Super Admin can reverse an entry if it was recorded in error. '
        'A custom role needs the "Sadqa Peti" permission to access any of this.',
    roles: _superOnly,
    customPerm: 'Sadqa Peti',
    screenBuilder: () => const SadqaPetiDashboardView(),
  ),
  HelpTopic(
    title: 'Monthly Members (recurring donors)',
    category: 'Monthly Members',
    keywords: ['monthly member', 'recurring donation', 'dues', 'member payment'],
    body: 'Track members who commit to a monthly donation: add a member, record each month\'s payment, see who is overdue, and send reminders. '
        'A custom role needs the "Monthly Members" permission to access this.',
    roles: _superOnly,
    customPerm: 'Monthly Members',
    screenBuilder: () => const MonthlyMembersDashboard(),
  ),

  // ---------------- Reports ----------------
  HelpTopic(
    title: 'Generating reports (Excel/PDF)',
    category: 'Reports',
    keywords: ['report', 'export', 'excel', 'pdf', 'student history'],
    body: 'The Reports centre generates ready-to-share files: attendance Excel sheets, and a full per-student "Complete History" PDF covering personal details, class, syllabus progress, '
        'course completion, month-wise attendance, and every Published examination result. A custom role needs the "Reports" permission.',
    roles: _superOnly,
    customPerm: 'Reports',
    screenBuilder: () => const ReportsView(),
  ),

  // ---------------- Guest tools ----------------
  HelpTopic(
    title: 'Prayer times, Qibla, Islamic calendar, Yaseen/Durood',
    category: 'Guest tools',
    keywords: ['prayer times', 'qibla', 'calendar', 'yaseen', 'durood', 'tasbeeh'],
    body: 'Available to everyone regardless of role, from the compass/tools icon: Hanafi prayer times, Qibla direction, the Islamic calendar, a Tasbeeh counter, and readers for Surah Yaseen and Durood-e-Taj.',
    roles: _everyone,
    screenBuilder: () => const PrayerTimesScreen(),
    ownScaffold: true,
  ),

  // ---------------- Troubleshooting / common errors ----------------
  HelpTopic(
    title: '"You don\'t have access to save that change"',
    category: 'Troubleshooting',
    keywords: ['row-level security', 'no access', 'permission denied', 'rls'],
    body: 'This means the database itself refused the change, usually because you tried to move a student/record outside a Maktab or class you\'re actually assigned to. '
        'It is a safety feature, not a bug - check which Maktab(s) you\'re scoped to, or ask a Super Admin to widen your access on the Roles screen.',
    roles: _everyone,
  ),
  HelpTopic(
    title: '"This Maktab/Class was not saved to the database yet"',
    category: 'Troubleshooting',
    keywords: ['not synced', 'sync error', 'database yet'],
    body: 'A brand-new Maktab, Class or Course needs a moment to finish syncing to the database after you create it. Wait a few seconds and try again; if it persists, check your internet connection.',
    roles: _everyone,
  ),
  HelpTopic(
    title: '"Could not save. Check your internet connection and try again"',
    category: 'Troubleshooting',
    keywords: ['network error', 'no internet', 'could not save', 'connection'],
    body: 'A generic message shown whenever a save couldn\'t reach the server - almost always a network hiccup. Check your connection and retry; nothing was saved, so it\'s always safe to try again.',
    roles: _everyone,
  ),
  HelpTopic(
    title: 'A number or marks field rejects what I typed',
    category: 'Troubleshooting',
    keywords: ['invalid marks', 'numeric error', 'validation'],
    body: 'Marks/amount fields only accept numbers within the allowed range (e.g. marks between 0 and Maximum Marks). If a save is blocked, check for a message explaining exactly what\'s wrong - '
        'it will name the specific rule that failed rather than just saying "invalid".',
    roles: _everyone,
  ),
];

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});
  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final _search = TextEditingController();
  String q = '';

  void _open(HelpTopic t) {
    if (t.screenBuilder == null) return;
    if (t.ownScaffold) {
      openTool(context, t.screenBuilder!());
    } else {
      pushPage(context, t.title, t.screenBuilder!());
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    final needle = q.trim();
    final matching = needle.isEmpty ? kHelpTopics : kHelpTopics.where((t) => t.matches(needle)).toList();
    final byCategory = <String, List<HelpTopic>>{};
    for (final t in matching) {
      byCategory.putIfAbsent(t.category, () => []).add(t);
    }
    return page([
      h('Help & User Guide', icon: Icons.help_outline),
      const Text(
        'Search for what you\'re trying to do (e.g. "attendance", "add student", "publish result") or an error message you saw.',
        style: TextStyle(color: Colors.black54, fontSize: 12.5),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _search,
        decoration: InputDecoration(
          hintText: 'Search help topics or errors...',
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          suffixIcon: q.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() {
                    _search.clear();
                    q = '';
                  }),
                ),
        ),
        onChanged: (v) => setState(() => q = v),
      ),
      const SizedBox(height: 10),
      if (matching.isEmpty) const Text('No help topic matches that search. Try a different word.', style: TextStyle(color: Colors.black54)),
      ...byCategory.entries.expand((entry) => [
            Padding(padding: const EdgeInsets.only(top: 10, bottom: 2), child: Text(entry.key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black54))),
            ...entry.value.map((t) {
              final canOpen = t.screenBuilder != null && t.visibleTo(u);
              return Card(
                child: ListTile(
                  title: Text(t.title),
                  subtitle: Text(
                    t.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => HelpTopicScreen(topic: t, canOpen: canOpen, onOpen: () => _open(t)))),
                  trailing: canOpen
                      ? IconButton(
                          icon: const Icon(Icons.arrow_forward_ios, size: 16, color: kGreen),
                          tooltip: 'Open this screen now',
                          onPressed: () => _open(t),
                        )
                      : null,
                ),
              );
            }),
          ]),
    ]);
  }
}

class HelpTopicScreen extends StatelessWidget {
  final HelpTopic topic;
  final bool canOpen;
  final VoidCallback onOpen;
  const HelpTopicScreen({super.key, required this.topic, required this.canOpen, required this.onOpen});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(topic.title), backgroundColor: kGreen, foregroundColor: Colors.white),
        body: page([
          Chip(label: Text(topic.category)),
          const SizedBox(height: 10),
          Text(topic.body, style: const TextStyle(fontSize: 14, height: 1.4)),
          const SizedBox(height: 16),
          if (canOpen)
            ElevatedButton.icon(onPressed: onOpen, icon: const Icon(Icons.open_in_new), label: const Text('Open this screen now'))
          else if (topic.screenBuilder != null)
            const Text(
              'You don\'t currently have access to this screen. Ask your Super Admin if you believe you should.',
              style: TextStyle(color: Colors.black54, fontSize: 12.5),
            ),
        ]),
      );
}
