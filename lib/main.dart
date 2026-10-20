import 'package:flutter/material.dart';
import 'state.dart';
import 'guest_tools.dart';

final AppState st = AppState();
const Color kGreen = Color(0xFF054D00);
const Color kGold = Color(0xFFD4A72C);

void main() => runApp(const MaktabApp());

class MaktabApp extends StatelessWidget {
  const MaktabApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Maktab E Tajushshriah',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kGreen, secondary: kGold),
      ),
      home: AnimatedBuilder(
        animation: st,
        builder: (c, _) => st.user == null ? const GuestHome() : const Shell(),
      ),
    );
  }
}

// ---------------- helpers ----------------
void toast(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

Widget tile(String label, String value, {Color? color}) => Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
        ]),
      ),
    );

Widget grid(List<Widget> tiles) => GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.1,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      children: tiles,
    );

Widget h(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
      child: Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: kGreen)),
    );

Widget page(List<Widget> children) => ListView(padding: const EdgeInsets.all(14), children: children);

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

Widget field(TextEditingController c, String label, {bool number = false, int lines = 1}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
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
  final otp = TextEditingController(text: '123456');
  bool step2 = false;
  String err = '';

  static const List<List<String>> testUsers = [
    ['Parent (Rashid, 2 children)', '9800000301'],
    ['Parent (Shabana)', '9800000302'],
    ['Student (Zainab own login)', '9800000401'],
    ['Teacher (Hanfi + Jama)', '9800000201'],
    ['Madrasa Admin', '9800000101'],
    ['Super Admin', '9800000001'],
    ['Working Committee', '9800000601'],
    ['Accountant (custom role)', '9800000501'],
  ];

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
            const Text('Powered by Faiz-e-Raza Group', style: TextStyle(color: Colors.black54, fontSize: 13), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Center(child: Image.asset('assets/logo.png', height: 84)),
            const SizedBox(height: 24),
            if (!step2) ...[
              field(phone, 'Mobile number', number: true),
              if (err.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(err, style: const TextStyle(color: Colors.red))),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: kGreen, padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () {
                    final p = digits(phone.text);
                    if (p.length != 10) {
                      setState(() => err = 'Enter a valid 10-digit mobile number.');
                    } else if (!st.users.containsKey(p)) {
                      setState(() => err = 'This number is not registered. Use a test user below.');
                    } else if (st.users[p]!.active == false) {
                      setState(() => err = 'This account has been deactivated. Contact your Madrasa Admin.');
                    } else {
                      setState(() {
                        err = '';
                        step2 = true;
                      });
                    }
                  },
                  child: const Text('Login'),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Test users (tap to fill). Test OTP is 123456.', style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final u in testUsers) ActionChip(label: Text(u[0]), onPressed: () => setState(() => phone.text = u[1])),
              ]),
            ] else ...[
              Text('OTP sent to ${digits(phone.text)} (test OTP: 123456)', textAlign: TextAlign.center),
              const SizedBox(height: 10),
              field(otp, 'Enter OTP', number: true),
              if (err.isNotEmpty) Text(err, style: const TextStyle(color: Colors.red)),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: kGreen, padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () {
                    if (otp.text.trim() == '123456') {
                      st.login(digits(phone.text));
                    } else {
                      setState(() => err = 'OTP is wrong.');
                    }
                  },
                  child: const Text('Verify & Login'),
                ),
              ),
              Center(child: TextButton(onPressed: () => setState(() => step2 = false), child: const Text('Change number'))),
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
        AppTab('Course Progress', Icons.verified, () => const KidCourseProgress()),
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
        AppTab('Course Progress', Icons.verified, () => const CourseApprovalsView()),
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
        AppTab('Course Approvals', Icons.verified, () => const CourseApprovalsView()),
        AppTab('Complaints', Icons.report_problem, () => const ComplaintsView()),
      ];
    case 'super':
      return [
        AppTab('Home', Icons.home, () => const StaffHome()),
        AppTab('Master Data', Icons.storage, () => const MasterDataView()),
        AppTab('Classes & Syllabus', Icons.menu_book, () => const SuperSyllabus()),
        AppTab('All Students', Icons.school, () => const StudentsView()),
        AppTab('Teachers & Leave', Icons.groups, () => const TeachersView()),
        AppTab('Teacher Madrasas', Icons.swap_horiz, () => const TeacherMadrasasAdmin()),
        AppTab('Course Approvals', Icons.verified, () => const CourseApprovalsView()),
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
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tabs[idx].title, style: const TextStyle(fontSize: 18)),
            Text('${roleLabel(u)} - ${u.name}', style: const TextStyle(fontSize: 11, color: Color(0xFFF0D98A))),
          ]),
          actions: [
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
            ListTile(leading: const Icon(Icons.logout), title: const Text('Logout'), onTap: () => st.logout()),
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
        tile('Latest result', '60 / 70 - rank 3'),
      ]),
      if (st.showFees) h('Fees (month-wise)'),
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
      h('Attendance - ${k.name}'),
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
            onPressed: () {
              st.markPageComplete(s, pageNo, date.text.trim(), grade, remark.text.trim());
              Navigator.pop(ctx);
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
            onPressed: () {
              st.tickChapter(s, i, date.text.trim(), grade);
              Navigator.pop(ctx);
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
      h('Student documents'),
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
                  if (r != null) st.reply(c, r);
                },
                child: const Text('Reply'),
              ),
              TextButton(onPressed: () => st.resolve(c), child: const Text('Resolve')),
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
        h('New complaint'),
        DropdownButtonFormField<String>(
          value: to,
          decoration: const InputDecoration(labelText: 'Send to', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'teacher', child: Text('Teacher')),
            DropdownMenuItem(value: 'admin', child: Text('Madrasa Admin')),
            DropdownMenuItem(value: 'super', child: Text('Super Admin')),
          ],
          onChanged: (v) => setState(() => to = v ?? to),
        ),
        const SizedBox(height: 8),
        field(subject, 'Subject'),
        field(text, 'Details', lines: 3),
        ElevatedButton(
          onPressed: () {
            if (subject.text.trim().isEmpty) {
              toast(context, 'Enter a subject');
              return;
            }
            st.addComplaint(to, subject.text.trim(), text.text.trim());
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
      h('Complaints inbox'),
      const Text('You see only complaints addressed to your level. A complaint about a teacher sent to the Admin is hidden from the teacher.'),
      if (inbox.isEmpty) const Text('Nothing here.'),
      ...inbox.map((c) => card(c, true)),
    ]);
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
  Widget build(BuildContext context) {
    final u = st.user!;
    final open = st.complaints.where((c) => c.to == u.role && c.status != 'Resolved').length;
    final pendingLeave = st.leaves.where((l) => l.status == 'Pending').length;
    if (u.role == 'super') {
      return page([
        banner(),
        grid([
          tile('Madrasas', '4'),
          tile('Students', '${st.students.length}'),
          tile('Teachers', '5'),
          tile('Average attendance', '86%'),
          tile('Average syllabus', '68%'),
          tile('Leave requests', '$pendingLeave pending'),
          tile('Complaints open', '$open'),
          tile('Committee members', '${st.committee().length}'),
        ]),
        h('Post common announcement (all madrasas, all roles)'),
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
          onPressed: () {
            if (title.text.trim().isEmpty) {
              toast(context, 'Enter a title');
              return;
            }
            st.postAnnouncement(title.text.trim(), msg.text.trim(), priority);
            title.clear();
            msg.clear();
            toast(context, 'Announcement posted. It now shows on every dashboard.');
          },
          child: const Text('Post announcement'),
        ),
        h('Active announcements'),
        ...st.announcements.where((a) => a.active).map((a) => Card(child: ListTile(title: Text(a.title), subtitle: Text(a.msg), trailing: TextButton(onPressed: () => st.withdraw(a), child: const Text('Withdraw'))))),
      ]);
    }
    if (u.role == 'admin') {
      final present = st.teacherAtt.values.where((v) => v.startsWith('Present')).length;
      final onLeave = st.teacherAtt.values.where((v) => v == 'On leave').length;
      return page([
        banner(),
        grid([
          tile('Students', '${st.inBranch('Hanfi').length}'),
          tile('Teachers today', '$present present, $onLeave on leave'),
          tile('Pending registrations', '${st.pending.length}'),
          tile('Leave requests', '$pendingLeave pending'),
          tile('Fees Sep', '${st.completeCount('Sep')} of ${st.totalFor('Sep')} complete'),
          tile('Complaints open', '$open'),
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
        tile('My attendance', st.teacherAtt[u.name] ?? 'Not marked'),
        tile('Students (${st.teacherMadrasa})', '${st.inBranch(st.teacherMadrasa).length}'),
        tile('Ready to promote', '${st.students.where((s) => st.eligible(s)).length}'),
        tile('Complaints open', '$open'),
      ]),
      const Text('Use the menu (top left) to open Attendance, Syllabus and more.'),
    ]);
  }
}

class MyDayView extends StatelessWidget {
  const MyDayView({super.key});
  @override
  Widget build(BuildContext context) {
    final entries = st.myDay();
    return page([
      h("My day - across all madrasas"),
      const Text('Classes today, in time order. Tap a row to switch to that madrasa.'),
      const SizedBox(height: 8),
      if (entries.isEmpty) const Text('No classes assigned yet.'),
      ...entries.map((e) => Card(
            child: ListTile(
              leading: CircleAvatar(backgroundColor: const Color(0xFFEEF4E8), child: Text(e.time.split(':')[0], style: const TextStyle(color: kGreen, fontWeight: FontWeight.bold, fontSize: 11))),
              title: Text('${e.time} - ${e.madrasa}'),
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

  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    final mine = st.leaves.where((l) => l.teacher == u.name).toList();
    return page([
      h('My attendance - ${nice(kToday)}'),
      const Text('This is one record for the teacher, even when teaching at more than one madrasa.', style: TextStyle(fontSize: 12, color: Colors.black54)),
      Card(child: ListTile(title: Text(st.teacherAtt[u.name] ?? 'Not marked'), subtitle: const Text('Tap Present or Absent for today'))),
      Row(children: [
        Expanded(child: ElevatedButton(onPressed: () => st.markSelf('Present'), child: const Text('Present'))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton(onPressed: () => st.markSelf('Absent'), child: const Text('Absent'))),
      ]),
      h('Apply for leave (sent to Super Admin)'),
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
        onPressed: () {
          final e = st.applyLeave(type, from.text.trim(), to.text.trim(), reason.text);
          toast(context, e ?? 'Leave request sent. Status: Pending');
          if (e == null) reason.clear();
        },
        child: const Text('Send request'),
      ),
      h('My leaves'),
      if (mine.isEmpty) const Text('None yet.'),
      ...mine.map((l) => Card(
            child: ListTile(
              title: Text('${l.type}: ${nice(l.from)} to ${nice(l.to)}'),
              subtitle: Text('${l.reason}${l.status == 'Pending' ? '' : '\n${l.status} by ${l.by}: ${l.remark}'}'),
              trailing: Chip(label: Text(l.status)),
            ),
          )),
    ]);
  }
}

class StudentAttendanceMark extends StatelessWidget {
  const StudentAttendanceMark({super.key});
  @override
  Widget build(BuildContext context) {
    // Deactivated students never appear here, so they can't be marked and never get an alert.
    final list = st.myStudents().where((s) => s.status == 'Active').toList();
    return page([
      h('Mark attendance - ${st.teacherMadrasa} - ${nice(kToday)}'),
      const Text('Tap Present or Absent for each student, then Final Submit once. Absent students\' parents get a WhatsApp alert only after Final Submit.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
      const SizedBox(height: 8),
      ...list.map((s) {
        final v = st.todayAtt[s.id] ?? 'P';
        return Card(
          child: ListTile(
            title: Text(s.name),
            subtitle: Text(st.className(s.cls)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(backgroundColor: v == 'P' ? Colors.green : null, foregroundColor: v == 'P' ? Colors.white : Colors.green),
                onPressed: () => st.setAtt(s.id, 'P'),
                child: const Text('Present'),
              ),
              const SizedBox(width: 6),
              OutlinedButton(
                style: OutlinedButton.styleFrom(backgroundColor: v == 'A' ? Colors.red : null, foregroundColor: v == 'A' ? Colors.white : Colors.red),
                onPressed: () => st.setAtt(s.id, 'A'),
                child: const Text('Absent'),
              ),
            ]),
          ),
        );
      }),
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: () {
          final n = st.submitAtt(list);
          toast(context, 'Attendance Final Submitted. $n absence WhatsApp alert(s) sent to parents.');
        },
        child: const Text('Final Submit'),
      ),
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
  String gender = '';
  int cls = 1;
  bool aadhaar = false;
  String? regMadrasa;

  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    final canSeeAadhaar = u.role == 'admin' || u.role == 'super';
    final canDeactivate = u.role == 'admin' || u.role == 'super' || u.role == 'teacher';
    final canPickMadrasa = u.role == 'admin' || u.role == 'super';
    final list = st.myStudents();
    final ready = list.where((s) => st.eligible(s)).toList();
    regMadrasa ??= canPickMadrasa ? st.activeMadrasaNames.first : st.teacherMadrasa;
    return page([
      h('Add new student'),
      field(name, 'Student name *'),
      if (canPickMadrasa) ...[
        DropdownButtonFormField<String>(
          value: regMadrasa,
          decoration: const InputDecoration(labelText: 'Madrasa / Branch *', border: OutlineInputBorder()),
          items: [for (final m in st.activeMadrasaNames) DropdownMenuItem<String>(value: m, child: Text(m))],
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
      field(parent, 'Parent mobile number * (mandatory)', number: true),
      field(stuPhone, 'Student mobile number (optional)', number: true),
      field(address, 'Address (optional)', lines: 2),
      OutlinedButton.icon(
        onPressed: () => setState(() => aadhaar = true),
        icon: Icon(aadhaar ? Icons.check_circle : Icons.upload_file, color: aadhaar ? Colors.green : null),
        label: Text(aadhaar ? 'Aadhaar card attached (demo file)' : 'Upload Aadhaar card * (required)'),
      ),
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: () {
          final e = st.addStudent(name: name.text, gender: gender, cls: cls, parentPhone: digits(parent.text), studentPhone: digits(stuPhone.text), aadhaar: aadhaar, address: address.text, madrasa: u.role == 'teacher' ? st.teacherMadrasa : (regMadrasa ?? 'Hanfi'));
          toast(context, e ?? 'Student added. Parent invited (login with OTP).');
          if (e == null) {
            name.clear();
            parent.clear();
            stuPhone.clear();
            address.clear();
            setState(() {
              gender = '';
              aadhaar = false;
            });
          }
        },
        child: const Text('Save student'),
      ),
      h('Pass and promote'),
      const Text('Classes 1-3: eligible once every page of the book is Completed. Class 4+: eligible once every chapter is Completed.'),
      if (ready.isEmpty) const Text('No student is eligible yet. Mark pages/chapters complete in Syllabus.'),
      ...ready.map((s) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('${st.className(s.cls)} - eligible to pass'),
                const SizedBox(height: 6),
                ElevatedButton(onPressed: () => toast(context, st.promote(s)), child: const Text('Mark Passed and Promote')),
              ]),
            ),
          )),
      h('Students - ${u.role == 'teacher' ? st.teacherMadrasa : 'Hanfi'}'),
      ...list.map((s) => Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text('${s.name} (${s.gender})'),
                subtitle: Text('${s.key} - ${st.className(s.cls)} - ${s.status}\nAadhaar uploaded: ${s.aadhaar ? 'Yes' : 'No'}${canSeeAadhaar ? '' : ' (teachers see only Yes or No)'}'),
                isThreeLine: true,
                trailing: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (canSeeAadhaar) TextButton(onPressed: () => toast(context, 'Demo: Aadhaar card opens here (view is logged)'), child: const Text('View Aadhaar')),
                  if (canDeactivate && s.status == 'Active')
                    TextButton(
                      onPressed: () async {
                        final r = await askText(context, 'Reason for deactivating ${s.name} (optional)');
                        if (r != null) toast(context, st.deactivateStudent(s, r));
                      },
                      child: const Text('Deactivate', style: TextStyle(color: Colors.red)),
                    ),
                  if (canDeactivate && s.status == 'Inactive')
                    TextButton(onPressed: () => toast(context, st.reactivateStudent(s)), child: const Text('Reactivate')),
                ]),
              ),
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
      h('Pending registrations'),
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
    return page([
      h('Teacher attendance - ${nice(kToday)}'),
      ...st.teacherAtt.entries.map((e) => Card(child: ListTile(title: Text(e.key), trailing: Text(e.value)))),
      h('Teacher leave requests'),
      if (st.leaves.isEmpty) const Text('No leave requests yet. Log in as Teacher and apply for leave.'),
      ...st.leaves.map((l) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l.teacher} - ${l.type}: ${nice(l.from)} to ${nice(l.to)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('Reason: ${l.reason}'),
                Text('Status: ${l.status}${l.status == 'Pending' ? '' : ' by ${l.by} (${l.remark})'}'),
                if (l.status == 'Pending')
                  Row(children: [
                    TextButton(
                      onPressed: () async {
                        final r = await askText(context, 'Remark', initial: 'Approved, take rest');
                        if (r != null) st.decideLeave(l, true, r);
                      },
                      child: const Text('Approve'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final r = await askText(context, 'Reason for rejection');
                        if (r != null) st.decideLeave(l, false, r);
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
    return page([
      h('Fees (month-wise)'),
      grid([for (final m in ['Jun', 'Jul', 'Aug', 'Sep']) tile('$m 2026', '${st.completeCount(m)} of ${st.totalFor(m)} complete')]),
      const Text('Tap a due month to record a payment of Rs. 200.'),
      ...st.inBranch('Hanfi').where((s) => s.status == 'Active').map((s) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s.name} - ${st.className(s.cls)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                Wrap(spacing: 6, children: [
                  for (final m in st.feeMonths(s))
                    st.isPaid(s.id, m)
                        ? Chip(label: Text('$m - Complete'), backgroundColor: const Color(0xFFDFF3DA))
                        : ActionChip(label: Text('$m due - Pay'), backgroundColor: const Color(0xFFFFE3E0), onPressed: () => toast(context, st.pay(s, m))),
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
  String? teacherName;
  String? madrasa;
  final Set<int> classIds = {};

  @override
  Widget build(BuildContext context) {
    final teachers = st.users.values.where((u) => u.role == 'teacher').toList();
    return page([
      h('Teacher madrasas and classes'),
      ...teachers.map((t) => Card(
            child: ListTile(
              title: Text(t.name),
              subtitle: Text((st.teacherAssignments[t.name] ?? {}).entries.map((e) => '${e.key}: ${e.value.map((c) => st.className(c)).join(', ')}').join('\n')),
              isThreeLine: true,
            ),
          )),
      h('Assign a teacher to another madrasa'),
      DropdownButtonFormField<String>(
        value: teacherName,
        decoration: const InputDecoration(labelText: 'Teacher', border: OutlineInputBorder()),
        items: [for (final t in teachers) DropdownMenuItem<String>(value: t.name, child: Text(t.name))],
        onChanged: (v) => setState(() => teacherName = v),
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        value: madrasa,
        decoration: const InputDecoration(labelText: 'Madrasa', border: OutlineInputBorder()),
        items: [for (final b in kBranches) DropdownMenuItem<String>(value: b, child: Text(b))],
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
        onPressed: () {
          final err = st.assignTeacherMadrasa(teacherName ?? '', madrasa ?? '', classIds.toList());
          toast(context, err ?? 'Assigned. On next login the teacher sees a madrasa switcher and My Day.');
        },
        child: const Text('Assign to another madrasa'),
      ),
    ]);
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
      h('Classes and syllabus'),
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
          onPressed: () {
            if (title.text.trim().isEmpty) {
              toast(context, 'Enter a title');
              return;
            }
            st.addChapter(cls, title.text.trim(), int.tryParse(days.text) ?? 30);
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
      h('Reports centre'),
      TextField(decoration: const InputDecoration(labelText: 'Search report name', border: OutlineInputBorder()), onChanged: (v) => setState(() => q = v)),
      const SizedBox(height: 8),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [DataColumn(label: Text('Report name')), DataColumn(label: Text('Date / period')), DataColumn(label: Text('Madrasa')), DataColumn(label: Text('Created on')), DataColumn(label: Text('Download'))],
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
  String branch = 'Hanfi';
  static const List<String> screens = ['Students', 'Fees', 'Reports', 'Leave'];

  @override
  Widget build(BuildContext context) {
    final names = st.customRoles.keys.toList();
    return page([
      h('Create role'),
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
        onPressed: () {
          final e = st.createRole(roleName.text, perms);
          toast(context, e ?? 'Role saved');
          if (e == null) {
            roleName.clear();
            setState(perms.clear);
          }
        },
        child: const Text('Save role'),
      ),
      h('Existing custom roles'),
      ...names.map((n) => Card(child: ListTile(title: Text(n), subtitle: Text('Screens: ${(st.customRoles[n] ?? <String>{}).join(', ')}')))),
      h('Give role to a person'),
      field(aPhone, 'Mobile number', number: true),
      field(aName, 'Name'),
      DropdownButtonFormField<String>(
        value: pick,
        decoration: const InputDecoration(labelText: 'Role', border: OutlineInputBorder()),
        items: [for (final n in names) DropdownMenuItem<String>(value: n, child: Text(n))],
        onChanged: (v) => setState(() => pick = v),
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        value: branch,
        decoration: const InputDecoration(labelText: 'Madrasa', border: OutlineInputBorder()),
        items: [for (final b in kBranches) DropdownMenuItem<String>(value: b, child: Text(b))],
        onChanged: (v) => setState(() => branch = v ?? branch),
      ),
      const SizedBox(height: 8),
      ElevatedButton(
        onPressed: () {
          final e = st.assignRole(digits(aPhone.text), aName.text, pick ?? '', branch);
          toast(context, e ?? 'Role given. That person now sees only the ticked screens after login.');
        },
        child: const Text('Assign role'),
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
  @override
  Widget build(BuildContext context) {
    return page([
      h('Add committee member (read-only)'),
      field(phone, 'Mobile number', number: true),
      field(name, 'Name'),
      const Text('Branches this member can see:'),
      ...kBranches.map((b) => CheckboxListTile(
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
        onPressed: () {
          final e = st.addCommittee(digits(phone.text), name.text, br.toList());
          toast(context, e ?? 'Member added. They see only student progress.');
        },
        child: const Text('Add member'),
      ),
      h('Members'),
      ...st.committee().map((m) => Card(
            child: ListTile(
              title: Text(m.name),
              subtitle: Text('${m.phone} - ${m.branches.join(', ')}'),
              trailing: TextButton(onPressed: () => st.removeMember(m.phone), child: const Text('Remove')),
            ),
          )),
      h('View log'),
      if (st.viewLog.isEmpty) const Text('No student views yet. Log in as Working Committee and open a student.'),
      ...st.viewLog.reversed.map((l) => Text(l)),
    ]);
  }
}

// ---------------- working committee (read only) ----------------
class CommitteeDashboard extends StatelessWidget {
  const CommitteeDashboard({super.key});
  @override
  Widget build(BuildContext context) {
    final totalActive = st.students.where((s) => s.status == 'Active').length;
    return page([
      h('Working Committee dashboard'),
      Card(
        child: ListTile(
          leading: const CircleAvatar(backgroundColor: Color(0xFFEEF4E8), child: Icon(Icons.groups, color: kGreen)),
          title: const Text('All Maktab Students', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('$totalActive active student(s) across all Madrasas'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AllStudentsList())),
        ),
      ),
      Card(
        child: ListTile(
          leading: const CircleAvatar(backgroundColor: Color(0xFFEEF4E8), child: Icon(Icons.account_balance, color: kGreen)),
          title: const Text('Madrasa-Wise Student Information', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: const Text('Pick a Madrasa to see its students'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const CommitteeBranches())),
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

class CommitteeBranches extends StatelessWidget {
  const CommitteeBranches({super.key});
  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    return page([
      h('Branches'),
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
            Tab(text: 'Courses'),
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
            Card(child: ListTile(title: Text('Jun 96% - Jul 92% - Aug 90% - Sep ${st.attPct(s)}%'), subtitle: const Text('Attendance by month'))),
          ]),
          page([
            const Card(child: ListTile(title: Text('Monthly Test Sep 2026'), subtitle: Text('60 / 70 - 85.7% - rank 3'))),
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
        const Text('Assign a course to this student:', style: TextStyle(fontWeight: FontWeight.w600)),
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
      if (enrollments.isEmpty) const Text('No courses assigned to this student yet.'),
      ...enrollments.map((e) {
        final c = st.courseById(e.courseId);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(child: Text(c?.name ?? 'Course #${e.courseId}', style: const TextStyle(fontWeight: FontWeight.bold))),
                _badge(e.status),
              ]),
              if (c != null && c.description.isNotEmpty) Text(c.description, style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
              if (e.status == 'completed' && e.completedOn != null) Text('Completed on ${nice(e.completedOn!)}', style: const TextStyle(color: Colors.green)),
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

  @override
  Widget build(BuildContext context) {
    return page([
      h('Madrasa / Branch'),
      ...st.madrasas.map((m) => Card(
            child: SwitchListTile(
              title: Text(m.name),
              subtitle: Text(m.active ? 'Active - shown in registration dropdown' : 'Deactivated - hidden from new registrations'),
              value: m.active,
              onChanged: (v) => st.setMadrasaActive(m, v),
            ),
          )),
      field(madrasaName, 'New Madrasa / Branch name'),
      ElevatedButton(
        onPressed: () {
          final e = st.addMadrasa(madrasaName.text);
          toast(context, e ?? 'Madrasa added. It now appears in the registration dropdown.');
          if (e == null) madrasaName.clear();
        },
        child: const Text('Add Madrasa / Branch'),
      ),
      h('Classes'),
      const Text('Classes and their syllabus (pages / chapters) are managed from the "Classes & Syllabus" screen.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
      ...st.classDefs.values.map((cd) => Card(child: ListTile(title: Text(cd.name), subtitle: Text(cd.pageBased ? 'Book: ${cd.bookName} - ${cd.totalPages} pages' : 'Chapter-based'))),),
      h('Teachers'),
      ...st.teachers().map((t) => Card(
            child: SwitchListTile(
              title: Text(t.name),
              subtitle: Text('${t.phone} - ${t.teachMadrasas.join(', ')}'),
              value: t.active,
              onChanged: (v) => st.setTeacherActive(t, v),
            ),
          )),
      const Padding(padding: EdgeInsets.only(top: 4), child: Text('Add a new teacher from "Teacher Madrasas" (assign) or give them a login via Roles.', style: TextStyle(color: Colors.black54, fontSize: 12.5))),
      h('Users and Roles'),
      ElevatedButton.icon(
        onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const RolesView())),
        icon: const Icon(Icons.admin_panel_settings),
        label: const Text('Open Roles & Permissions'),
      ),
      h('Courses'),
      ...st.courses.map((c) => Card(
            child: SwitchListTile(
              title: Text(c.name),
              subtitle: Text(c.description.isEmpty ? 'No description' : c.description),
              value: c.active,
              onChanged: (v) => st.setCourseActive(c, v),
            ),
          )),
      field(courseName, 'New course name'),
      field(courseDesc, 'Course description (optional)', lines: 2),
      ElevatedButton(
        onPressed: () {
          final e = st.addCourse(courseName.text, courseDesc.text);
          toast(context, e ?? 'Course added. It can now be assigned from any student\'s Courses tab.');
          if (e == null) {
            courseName.clear();
            courseDesc.clear();
          }
        },
        child: const Text('Add course'),
      ),
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
              Text('${s.name} - ${c?.name ?? 'Course'}', style: const TextStyle(fontWeight: FontWeight.bold)),
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
      h('Course completion requests'),
      const Text('Teachers submit a course as complete for a student here; Admin or Super Admin approves or rejects it. Approved courses show a green "Completed" badge in the Courses tab and the Parent Course Progress tab.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
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
      h('Fee payment QR code'),
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
      h('Monthly fee reminder (1st of every month)'),
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
