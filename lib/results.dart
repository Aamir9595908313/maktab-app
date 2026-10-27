// ============================================================
// Student Results Management.
//
// Reuses existing data rather than inventing new master records: the
// examinable "Subject" list for a class is built from that class's own
// Books (public.class_books - Book Management, already real data), the
// Academic Year picker reads public.academic_years (a table that already
// existed in the database with 0 rows and no screen anywhere - this is
// the first thing that actually uses it), and student/branch/class data
// all come straight from AppState (st.students / st.madrasas / st.classDefs)
// exactly like every other screen in this app.
//
// All writes go through SECURITY DEFINER functions (create_examination,
// add_exam_subject, save_exam_mark, submit_exam_for_review, publish_exam,
// delete_exam_result / restore_exam_result, delete_examination /
// restore_examination - see migration student_results_management_* for
// the full schema, RLS and function bodies) so permission checks, status
// transitions, duplicate prevention, audit logging and notification
// creation are enforced in one place, not just hoped for from the UI.
// Reads go through RLS directly, same as every other module.
// ============================================================
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';

import 'state.dart';
import 'main.dart';

// ============================================================
// Loading
// ============================================================

Future<void> loadAcademicYears() async {
  try {
    final rows = await sb.from('academic_years').select().order('starts_on', ascending: false);
    st.setAcademicYearsFromDb([for (final r in (rows as List)) AcademicYear.fromJson(r as Map<String, dynamic>)]);
  } catch (_) {}
}

Future<String?> createAcademicYearRemote(String label, String startsOn, String endsOn) async {
  if (label.trim().isEmpty) return "Give this academic year a label (e.g. '2026-27').";
  try {
    await sb.from('academic_years').insert({'label': label.trim(), 'starts_on': startsOn, 'ends_on': endsOn, 'created_by': sb.auth.currentUser?.id});
    await loadAcademicYears();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only a Super Admin can add an academic year.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Examinations this account can see at all (RLS: Super Admin - everything;
// a Result Manager - their own branch(es); nothing for anyone else - a
// student/parent uses loadMyResultsFor() below instead, which reads
// exam_results directly and never touches this list).
Future<void> loadExaminations() async {
  try {
    final rows = await sb
        .from('examinations')
        .select('*, madrasas(name), classes(class_no, name), academic_years(label)')
        .eq('is_deleted', false)
        .order('created_at', ascending: false);
    st.setExaminationsFromDb([for (final r in (rows as List)) Examination.fromJson(r as Map<String, dynamic>)]);
  } catch (_) {}
}

Future<void> loadExamSubjects(String examId, void Function(List<ExamSubject>) onLoaded) async {
  try {
    final rows = await sb.from('exam_subjects').select().eq('exam_id', examId).order('sort_order');
    onLoaded([for (final r in (rows as List)) ExamSubject.fromJson(r as Map<String, dynamic>)]);
  } catch (_) {
    onLoaded([]);
  }
}

Future<void> loadExamResults(String examSubjectId, void Function(List<ExamResultRow>) onLoaded) async {
  try {
    final rows = await sb.from('exam_results').select().eq('exam_subject_id', examSubjectId).eq('is_deleted', false);
    onLoaded([for (final r in (rows as List)) ExamResultRow.fromJson(r as Map<String, dynamic>)]);
  } catch (_) {
    onLoaded([]);
  }
}

Future<List<ResultAuditRow>> loadExamAudit(String examId) async {
  try {
    final rows = await sb.from('exam_result_audit').select().eq('exam_id', examId).order('created_at', ascending: false);
    return [for (final r in (rows as List)) ResultAuditRow.fromJson(r as Map<String, dynamic>)];
  } catch (_) {
    return [];
  }
}

// "Published"/"corrected" notifications for the signed-in student, or for
// every child linked to a signed-in parent.
Future<void> loadMyResultNotifs() async {
  final u = st.user;
  if (u == null || (u.role != 'student' && u.role != 'parent')) return;
  try {
    final rows = await sb.from('result_notifications').select('*, examinations(name)').order('created_at', ascending: false).limit(100);
    st.setResultNotifsFromDb([for (final r in (rows as List)) ResultNotif.fromJson(r as Map<String, dynamic>)]);
  } catch (_) {}
}

Future<void> markResultNotifReadRemote(ResultNotif n) async {
  if (n.isRead) return;
  n.isRead = true;
  st.setResultNotifsFromDb(st.resultNotifs);
  try {
    await sb.from('result_notifications').update({'is_read': true}).eq('id', n.id);
  } catch (_) {}
}

// Every published result for one student - used by both the Student "My
// Results" screen (their own dbId) and the Parent "My Child's Results"
// screen (the selected child's dbId). RLS (exam_results_student_read /
// exam_results_parent_read) is the real boundary here - this only ever
// asks for one student's own rows, but even a tampered request for
// someone else's id would come back empty.
Future<List<Map<String, dynamic>>> loadMyResultsFor(String studentId) async {
  try {
    final rows = await sb
        .from('exam_results')
        .select('*, exam_subjects(subject_name, max_marks, passing_marks, examinations(id, name, starts_on, status, published_at, classes(name), academic_years(label)))')
        .eq('student_id', studentId)
        .eq('is_deleted', false);
    return [for (final r in (rows as List)) r as Map<String, dynamic>];
  } catch (_) {
    return [];
  }
}

// ============================================================
// Mutations (SECURITY DEFINER RPCs)
// ============================================================

String _friendly(Object e) {
  if (e is PostgrestException) return e.message;
  return 'Could not save. Check your internet connection and try again.';
}

Future<String?> createExaminationRemote({
  required String madrasaId,
  required String classId,
  required String academicYearId,
  required String name,
  required String startsOn,
  String? endsOn,
  String? remarks,
}) async {
  if (name.trim().isEmpty) return 'Give the examination a name.';
  try {
    final row = await sb.rpc('create_examination', params: {
      'p_madrasa_id': madrasaId,
      'p_class_id': classId,
      'p_academic_year_id': academicYearId,
      'p_name': name.trim(),
      'p_starts_on': startsOn,
      'p_ends_on': endsOn,
      'p_remarks': (remarks?.trim().isEmpty ?? true) ? null : remarks!.trim(),
    });
    await loadExaminations();
    // So the caller can immediately navigate to the newly created exam -
    // it's always first, since loadExaminations() sorts newest-first.
    final created = Map<String, dynamic>.from(row as Map)['id'] as String?;
    if (created == null || !st.examinations.any((e) => e.id == created)) return 'Saved, but could not reload it - pull to refresh.';
    return null;
  } catch (e) {
    return _friendly(e);
  }
}

Future<String?> addExamSubjectRemote({
  required String examId,
  required String subjectName,
  String? sourceBookId,
  required num maxMarks,
  num? passingMarks,
}) async {
  if (subjectName.trim().isEmpty) return 'Pick or name a subject.';
  if (maxMarks <= 0) return 'Maximum Marks must be greater than zero.';
  if (passingMarks != null && passingMarks > maxMarks) return 'Passing Marks cannot exceed Maximum Marks.';
  try {
    await sb.rpc('add_exam_subject', params: {
      'p_exam_id': examId,
      'p_subject_name': subjectName.trim(),
      'p_source_book_id': sourceBookId,
      'p_source_course_id': null,
      'p_max_marks': maxMarks,
      'p_passing_marks': passingMarks,
    });
    return null;
  } catch (e) {
    return _friendly(e);
  }
}

Future<String?> removeExamSubjectRemote(String examSubjectId) async {
  try {
    await sb.rpc('remove_exam_subject', params: {'p_exam_subject_id': examSubjectId});
    return null;
  } catch (e) {
    return _friendly(e);
  }
}

// `reason` is only required (and only used) when correcting a mark on an
// already-Published examination - save_exam_mark() enforces that itself.
Future<String?> saveExamMarkRemote({
  required String examSubjectId,
  required String studentId,
  num? marks,
  bool isAbsent = false,
  String? remarks,
  String? reason,
}) async {
  try {
    await sb.rpc('save_exam_mark', params: {
      'p_exam_subject_id': examSubjectId,
      'p_student_id': studentId,
      'p_marks': marks,
      'p_is_absent': isAbsent,
      'p_remarks': (remarks?.trim().isEmpty ?? true) ? null : remarks!.trim(),
      'p_reason': (reason?.trim().isEmpty ?? true) ? null : reason!.trim(),
    });
    return null;
  } catch (e) {
    return _friendly(e);
  }
}

Future<String?> submitExamForReviewRemote(String examId) async {
  try {
    await sb.rpc('submit_exam_for_review', params: {'p_exam_id': examId});
    await loadExaminations();
    return null;
  } catch (e) {
    return _friendly(e);
  }
}

Future<String?> publishExamRemote(String examId) async {
  try {
    await sb.rpc('publish_exam', params: {'p_exam_id': examId});
    await loadExaminations();
    return null;
  } catch (e) {
    return _friendly(e);
  }
}

Future<String?> deleteExamResultRemote(String examResultId, String reason) async {
  if (reason.trim().isEmpty) return 'A reason is required.';
  try {
    await sb.rpc('delete_exam_result', params: {'p_exam_result_id': examResultId, 'p_reason': reason.trim()});
    return null;
  } catch (e) {
    return _friendly(e);
  }
}

Future<String?> restoreExamResultRemote(String examResultId, String reason) async {
  if (reason.trim().isEmpty) return 'A reason is required.';
  try {
    await sb.rpc('restore_exam_result', params: {'p_exam_result_id': examResultId, 'p_reason': reason.trim()});
    return null;
  } catch (e) {
    return _friendly(e);
  }
}

Future<String?> deleteExaminationRemote(String examId, String reason) async {
  if (reason.trim().isEmpty) return 'A reason is required.';
  try {
    await sb.rpc('delete_examination', params: {'p_exam_id': examId, 'p_reason': reason.trim()});
    await loadExaminations();
    return null;
  } catch (e) {
    return _friendly(e);
  }
}

Future<String?> restoreExaminationRemote(String examId, String reason) async {
  if (reason.trim().isEmpty) return 'A reason is required.';
  try {
    await sb.rpc('restore_examination', params: {'p_exam_id': examId, 'p_reason': reason.trim()});
    await loadExaminations();
    return null;
  } catch (e) {
    return _friendly(e);
  }
}

// ============================================================
// Small shared helpers
// ============================================================

Color _statusColor(String status) => switch (status) {
      'Draft' => Colors.black54,
      'Ready for Review' => const Color(0xFFB8860B),
      'Published' => kGreen,
      _ => Colors.black54,
    };

Widget _statusChip(String status) => Chip(
      label: Text(status, style: const TextStyle(color: Colors.white, fontSize: 12)),
      backgroundColor: _statusColor(status),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

Future<String?> _askReason(BuildContext c, String title) async {
  final ctl = TextEditingController();
  final ok = await showDialog<bool>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, autofocus: true, maxLines: 2, decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
      ],
    ),
  );
  if (ok != true) return null;
  final r = ctl.text.trim();
  return r.isEmpty ? null : r;
}

// ============================================================
// Academic Years (Super Admin only) - the missing prerequisite
// ============================================================

class AcademicYearsAdmin extends StatefulWidget {
  const AcademicYearsAdmin({super.key});
  @override
  State<AcademicYearsAdmin> createState() => _AcademicYearsAdminState();
}

class _AcademicYearsAdminState extends State<AcademicYearsAdmin> {
  final label = TextEditingController();
  DateTime? starts;
  DateTime? ends;
  bool busy = false;

  Future<void> _pick(bool isStart) async {
    final picked = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2015), lastDate: DateTime(2050));
    if (picked == null) return;
    setState(() => isStart ? starts = picked : ends = picked);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: st,
        builder: (context, _) => page([
          h('Add an academic year', icon: Icons.calendar_today),
          const Text(
            'Examinations are tied to an academic year. Add at least one before creating an examination (e.g. "2026-27").',
            style: TextStyle(color: Colors.black54, fontSize: 12.5),
          ),
          field(label, 'Label (e.g. 2026-27)'),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => _pick(true), child: Text(starts == null ? 'Starts on' : fd(starts!)))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: () => _pick(false), child: Text(ends == null ? 'Ends on' : fd(ends!)))),
          ]),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: busy || starts == null || ends == null
                ? null
                : () async {
                    setState(() => busy = true);
                    final e = await createAcademicYearRemote(label.text, fd(starts!), fd(ends!));
                    if (!mounted) return;
                    setState(() => busy = false);
                    toast(context, e ?? 'Academic year added');
                    if (e == null) {
                      label.clear();
                      setState(() {
                        starts = null;
                        ends = null;
                      });
                    }
                  },
            child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
          ),
          h('Existing academic years', icon: Icons.calendar_today),
          if (st.academicYears.isEmpty) const Text('None yet.', style: TextStyle(color: Colors.black54)),
          ...st.academicYears.map((y) => Card(child: ListTile(title: Text(y.label), subtitle: Text('${y.startsOn} to ${y.endsOn}')))),
        ]),
      );
}

// ============================================================
// Results Hub - the entry point for Super Admin / a Result Manager
// ============================================================

class ResultsHub extends StatefulWidget {
  const ResultsHub({super.key});
  @override
  State<ResultsHub> createState() => _ResultsHubState();
}

class _ResultsHubState extends State<ResultsHub> {
  @override
  void initState() {
    super.initState();
    loadExaminations();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: st, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final u = st.user!;
    final canCreate = u.role == 'super' || userHasPerm(u, 'Results Create');
    return page([
      h('Student Results', icon: Icons.grading),
      if (u.role == 'super')
        OutlinedButton.icon(
          onPressed: () => pushPage(context, 'Academic Years', const AcademicYearsAdmin()),
          icon: const Icon(Icons.calendar_today, size: 16),
          label: const Text('Manage Academic Years'),
        ),
      const SizedBox(height: 8),
      if (canCreate)
        ElevatedButton.icon(
          onPressed: st.academicYears.isEmpty
              ? () => toast(context, u.role == 'super' ? 'Add an academic year first (button above).' : 'Ask your Super Admin to add an academic year first.')
              : () => pushPage(context, 'Create Examination', const CreateExaminationScreen()),
          icon: const Icon(Icons.add),
          label: const Text('Create Examination'),
        ),
      const SizedBox(height: 10),
      if (st.examinations.isEmpty) const Text('No examinations yet.', style: TextStyle(color: Colors.black54)),
      ...st.examinations.map((e) => Card(
            child: ListTile(
              title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${e.className} - ${e.madrasaName} - ${e.academicYearLabel}\n${e.startsOn}${e.endsOn != null && e.endsOn != e.startsOn ? ' to ${e.endsOn}' : ''}'),
              isThreeLine: true,
              trailing: _statusChip(e.status),
              onTap: () => pushPage(context, e.name, ExamDetailScreen(exam: e)),
            ),
          )),
    ]);
  }
}

// ============================================================
// Create Examination
// ============================================================

class CreateExaminationScreen extends StatefulWidget {
  const CreateExaminationScreen({super.key});
  @override
  State<CreateExaminationScreen> createState() => _CreateExaminationScreenState();
}

class _CreateExaminationScreenState extends State<CreateExaminationScreen> {
  final name = TextEditingController();
  final remarks = TextEditingController();
  String? madrasaName;
  int? classNo;
  String? yearId;
  DateTime starts = DateTime.now();
  DateTime? ends;
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    final pickableMadrasas = u.role == 'super' ? st.activeMadrasaNames : st.activeMadrasaNames.where(u.branches.contains).toList();
    final classes = st.classDefs.values.where((c) => c.active).toList()..sort((a, b) => a.id.compareTo(b.id));
    return page([
      h('New examination', icon: Icons.add_chart),
      field(name, 'Examination Name (e.g. Half-Yearly Examination)'),
      DropdownButtonFormField<String>(
        value: madrasaName,
        decoration: const InputDecoration(labelText: 'Maktab / Branch', border: OutlineInputBorder()),
        items: [for (final m in pickableMadrasas) DropdownMenuItem(value: m, child: Text(m))],
        onChanged: (v) => setState(() => madrasaName = v),
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<int>(
        value: classNo,
        decoration: const InputDecoration(labelText: 'Class', border: OutlineInputBorder()),
        items: [for (final c in classes) DropdownMenuItem(value: c.id, child: Text(c.name))],
        onChanged: (v) => setState(() => classNo = v),
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        value: yearId,
        decoration: const InputDecoration(labelText: 'Academic Year', border: OutlineInputBorder()),
        items: [for (final y in st.academicYears) DropdownMenuItem(value: y.id, child: Text(y.label))],
        onChanged: (v) => setState(() => yearId = v),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () async {
              final p = await showDatePicker(context: context, initialDate: starts, firstDate: DateTime(2015), lastDate: DateTime(2050));
              if (p != null) setState(() => starts = p);
            },
            child: Text('Starts: ${fd(starts)}'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: () async {
              final p = await showDatePicker(context: context, initialDate: ends ?? starts, firstDate: DateTime(2015), lastDate: DateTime(2050));
              if (p != null) setState(() => ends = p);
            },
            child: Text(ends == null ? 'Ends (optional)' : 'Ends: ${fd(ends!)}'),
          ),
        ),
      ]),
      field(remarks, 'Remarks / Instructions (optional)', lines: 2),
      const SizedBox(height: 10),
      ElevatedButton(
        onPressed: busy || madrasaName == null || classNo == null || yearId == null
            ? null
            : () async {
                setState(() => busy = true);
                final mid = st.madrasas.firstWhere((m) => m.name == madrasaName).dbId;
                final cid = st.classDefs[classNo]?.dbId;
                if (mid == null || cid == null) {
                  setState(() => busy = false);
                  toast(context, 'That Maktab or Class has not finished syncing yet - try again in a moment.');
                  return;
                }
                final e = await createExaminationRemote(
                  madrasaId: mid,
                  classId: cid,
                  academicYearId: yearId!,
                  name: name.text,
                  startsOn: fd(starts),
                  endsOn: ends == null ? null : fd(ends!),
                  remarks: remarks.text,
                );
                if (!mounted) return;
                setState(() => busy = false);
                if (e != null) {
                  toast(context, e);
                  return;
                }
                final created = st.examinations.first;
                Navigator.pop(context);
                pushPage(context, created.name, ExamDetailScreen(exam: created));
              },
        child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Create - add subjects next'),
      ),
    ]);
  }
}

// ============================================================
// Examination detail: subjects, workflow actions, audit, delete
// ============================================================

class ExamDetailScreen extends StatefulWidget {
  final Examination exam;
  const ExamDetailScreen({super.key, required this.exam});
  @override
  State<ExamDetailScreen> createState() => _ExamDetailScreenState();
}

class _ExamDetailScreenState extends State<ExamDetailScreen> {
  List<ExamSubject>? subjects;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await loadExamSubjects(widget.exam.id, (s) {
      if (mounted) setState(() => subjects = s);
    });
  }

  Future<void> _addSubject() async {
    final cd = st.classDefs.values.where((c) => c.dbId == widget.exam.classId).firstOrNull;
    final books = cd?.books.where((b) => b.active).toList() ?? [];
    ClassBook? pickedBook;
    final nameCtl = TextEditingController();
    final maxCtl = TextEditingController(text: '100');
    final passCtl = TextEditingController(text: '40');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Add subject'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (books.isNotEmpty) ...[
                DropdownButtonFormField<ClassBook>(
                  value: pickedBook,
                  decoration: const InputDecoration(labelText: 'From this class\'s Books', border: OutlineInputBorder()),
                  items: [for (final b in books) DropdownMenuItem(value: b, child: Text(b.name))],
                  onChanged: (v) => setD(() {
                    pickedBook = v;
                    if (v != null) nameCtl.text = v.name;
                  }),
                ),
                const SizedBox(height: 8),
                const Text('or name it yourself:', style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 4),
              ],
              TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Subject Name', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: maxCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Maximum Marks', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: passCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Passing Marks (optional)', border: OutlineInputBorder())),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final e = await addExamSubjectRemote(
      examId: widget.exam.id,
      subjectName: nameCtl.text,
      sourceBookId: pickedBook?.dbId,
      maxMarks: num.tryParse(maxCtl.text) ?? 0,
      passingMarks: passCtl.text.trim().isEmpty ? null : num.tryParse(passCtl.text),
    );
    if (!mounted) return;
    if (e != null) {
      toast(context, e);
    } else {
      await _load();
    }
  }

  Future<void> _removeSubject(ExamSubject s) async {
    final e = await removeExamSubjectRemote(s.id);
    if (!mounted) return;
    if (e != null) {
      toast(context, e);
    } else {
      await _load();
    }
  }

  Future<void> _submit() async {
    setState(() => busy = true);
    final e = await submitExamForReviewRemote(widget.exam.id);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (e == null) widget.exam.status = 'Ready for Review';
    });
    toast(context, e ?? 'Submitted for review.');
  }

  Future<void> _publish() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Publish results?'),
        content: const Text('This makes results visible to the affected students and their parents right away. Make sure every entry has been checked.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Publish')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => busy = true);
    final e = await publishExamRemote(widget.exam.id);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (e == null) widget.exam.status = 'Published';
    });
    toast(context, e ?? 'Published.');
  }

  Future<void> _deleteExam() async {
    final reason = await _askReason(context, 'Delete this entire examination?');
    if (reason == null) return;
    final e = await deleteExaminationRemote(widget.exam.id, reason);
    if (!mounted) return;
    toast(context, e ?? 'Examination deleted.');
    if (e == null) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    final isSuper = u.role == 'super';
    final canCreate = isSuper || userHasPerm(u, 'Results Create');
    final canSubmit = isSuper || userHasPerm(u, 'Results Submit');
    final canPublish = isSuper || userHasPerm(u, 'Results Publish');
    final canDelete = isSuper || userHasPerm(u, 'Results Delete');
    final canViewReports = isSuper || userHasPerm(u, 'Results View Reports');
    final e = widget.exam;
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) => page([
        Row(children: [Expanded(child: h(e.name, icon: Icons.grading)), _statusChip(e.status)]),
        Text('${e.className} - ${e.madrasaName} - ${e.academicYearLabel}', style: const TextStyle(color: Colors.black54)),
        Text('${e.startsOn}${e.endsOn != null && e.endsOn != e.startsOn ? ' to ${e.endsOn}' : ''}', style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
        if (e.remarks != null && e.remarks!.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(e.remarks!)),
        const SizedBox(height: 10),
        h('Subjects', icon: Icons.menu_book),
        if (subjects == null) const Center(child: CircularProgressIndicator()),
        if (subjects != null && subjects!.isEmpty) const Text('No subjects added yet.', style: TextStyle(color: Colors.black54)),
        ...?subjects?.map((s) => Card(
              child: ListTile(
                title: Text(s.subjectName),
                subtitle: Text('Max ${s.maxMarks}${s.passingMarks != null ? ' - Pass ${s.passingMarks}' : ''}'),
                onTap: () => pushPage(context, s.subjectName, SubjectMarksScreen(exam: e, subject: s)),
                trailing: e.status == 'Draft' && canCreate
                    ? IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _removeSubject(s))
                    : const Icon(Icons.chevron_right),
              ),
            )),
        if (e.status == 'Draft' && canCreate)
          OutlinedButton.icon(onPressed: _addSubject, icon: const Icon(Icons.add), label: const Text('Add subject')),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (e.status == 'Draft' && canSubmit)
            ElevatedButton.icon(onPressed: busy || (subjects?.isEmpty ?? true) ? null : _submit, icon: const Icon(Icons.send), label: const Text('Submit for Review')),
          if (e.status == 'Ready for Review' && canPublish)
            ElevatedButton.icon(onPressed: busy ? null : _publish, icon: const Icon(Icons.publish), label: const Text('Publish')),
          if (canViewReports)
            OutlinedButton.icon(
              onPressed: () => pushPage(context, 'Audit history', ExamAuditScreen(exam: e)),
              icon: const Icon(Icons.history),
              label: const Text('Audit history'),
            ),
          if (userHasPerm(u, 'Results Export') || isSuper)
            OutlinedButton.icon(onPressed: subjects == null || subjects!.isEmpty ? null : () => _exportCsv(context, e, subjects!), icon: const Icon(Icons.ios_share), label: const Text('Export CSV')),
          if (canDelete) OutlinedButton.icon(onPressed: busy ? null : _deleteExam, icon: const Icon(Icons.delete_forever, color: Colors.red), label: const Text('Delete examination', style: TextStyle(color: Colors.red))),
        ]),
      ]),
    );
  }

  Future<void> _exportCsv(BuildContext context, Examination e, List<ExamSubject> subs) async {
    final rows = <List<String>>[
      ['Subject', 'Student', 'Admission No', 'Marks', 'Max Marks', 'Percentage', 'Status'],
    ];
    for (final s in subs) {
      final results = <ExamResultRow>[];
      await loadExamResults(s.id, results.addAll);
      final roster = st.students.where((st2) => st2.madrasa == e.madrasaName && st2.cls == e.classNo).toList();
      for (final stu in roster) {
        final r = results.where((x) => x.studentId == stu.dbId).firstOrNull;
        final marks = r?.marksObtained;
        final pct = marks == null ? '' : (marks / s.maxMarks * 100).toStringAsFixed(1);
        final status = r == null ? 'Not entered' : (r.isAbsent ? 'Absent' : (s.passingMarks == null ? '' : ((marks ?? 0) >= s.passingMarks! ? 'Pass' : 'Fail')));
        rows.add([s.subjectName, stu.name, stu.key, marks?.toString() ?? '', '${s.maxMarks}', pct, status]);
      }
    }
    final csv = const ListToCsvConverter().convert(rows);
    try {
      final dir = await getTemporaryDirectory();
      final safe = e.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
      final file = File('${dir.path}/results_$safe.csv');
      await file.writeAsString(csv);
      await Share.shareXFiles([XFile(file.path)], text: '${e.name} - results');
    } catch (_) {
      if (mounted) toast(context, 'Could not export. Check storage/share permissions.');
    }
  }
}

// ============================================================
// One subject's class-wise marks entry
// ============================================================

class SubjectMarksScreen extends StatefulWidget {
  final Examination exam;
  final ExamSubject subject;
  const SubjectMarksScreen({super.key, required this.exam, required this.subject});
  @override
  State<SubjectMarksScreen> createState() => _SubjectMarksScreenState();
}

class _SubjectMarksScreenState extends State<SubjectMarksScreen> {
  List<ExamResultRow>? results;
  final Map<String, TextEditingController> _marks = {};
  final Map<String, bool> _absent = {};
  bool busy = false;

  List<Student> get _roster => st.students.where((s) => s.madrasa == widget.exam.madrasaName && s.cls == widget.exam.classNo && s.dbId != null).toList()..sort((a, b) => a.name.compareTo(b.name));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await loadExamResults(widget.subject.id, (r) {
      if (!mounted) return;
      setState(() {
        results = r;
        for (final stu in _roster) {
          final existing = r.where((x) => x.studentId == stu.dbId).firstOrNull;
          _marks[stu.dbId!] = TextEditingController(text: existing?.marksObtained?.toString() ?? '');
          _absent[stu.dbId!] = existing?.isAbsent ?? false;
        }
      });
    });
  }

  ExamResultRow? _existingFor(String studentId) => results?.where((r) => r.studentId == studentId).firstOrNull;

  Future<void> _save(Student stu) async {
    final existing = _existingFor(stu.dbId!);
    final isAbsent = _absent[stu.dbId!] ?? false;
    final marksText = _marks[stu.dbId!]?.text.trim() ?? '';
    final marks = isAbsent ? null : (marksText.isEmpty ? null : num.tryParse(marksText));
    if (!isAbsent && marksText.isNotEmpty && marks == null) {
      toast(context, 'Marks must be a number.');
      return;
    }
    String? reason;
    if (widget.exam.status == 'Published') {
      reason = await _askReason(context, 'Why is this correction needed?');
      if (reason == null) return;
    }
    setState(() => busy = true);
    final e = await saveExamMarkRemote(examSubjectId: widget.subject.id, studentId: stu.dbId!, marks: marks, isAbsent: isAbsent, reason: reason);
    if (!mounted) return;
    setState(() => busy = false);
    if (e != null) {
      toast(context, e);
    } else {
      await _load();
      if (mounted) toast(context, existing == null ? 'Saved.' : 'Updated.');
    }
  }

  Future<void> _delete(Student stu) async {
    final existing = _existingFor(stu.dbId!);
    if (existing?.id == null) return;
    final reason = await _askReason(context, 'Delete ${stu.name}\'s result for this subject?');
    if (reason == null) return;
    final e = await deleteExamResultRemote(existing!.id!, reason);
    if (!mounted) return;
    toast(context, e ?? 'Deleted.');
    if (e == null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final u = st.user!;
    final isSuper = u.role == 'super';
    final canDelete = isSuper || userHasPerm(u, 'Results Delete');
    final roster = _roster;
    final entered = results?.where((r) => !r.isDeleted).length ?? 0;
    return page([
      h(widget.subject.subjectName, icon: Icons.menu_book),
      Text('Max Marks ${widget.subject.maxMarks}${widget.subject.passingMarks != null ? ' - Passing ${widget.subject.passingMarks}' : ''}', style: const TextStyle(color: Colors.black54)),
      const SizedBox(height: 6),
      if (results == null) const Center(child: CircularProgressIndicator()),
      if (results != null) Text('$entered of ${roster.length} students have marks entered.', style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
      const SizedBox(height: 8),
      if (results != null && roster.isEmpty) const Text('No active students found in this class/branch.', style: TextStyle(color: Colors.black54)),
      ...roster.map((stu) {
        final existing = _existingFor(stu.dbId!);
        final isAbsent = _absent[stu.dbId!] ?? false;
        final marksNum = num.tryParse(_marks[stu.dbId!]?.text ?? '');
        final pct = marksNum == null ? null : (marksNum / widget.subject.maxMarks * 100);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('${stu.name}  (${stu.key})', style: const TextStyle(fontWeight: FontWeight.bold))),
                if (existing != null && !existing.isDeleted)
                  Icon(widget.subject.passingMarks != null && !isAbsent && marksNum != null ? (marksNum >= widget.subject.passingMarks! ? Icons.check_circle : Icons.cancel) : Icons.circle_outlined,
                      size: 18, color: widget.subject.passingMarks != null && !isAbsent && marksNum != null ? (marksNum >= widget.subject.passingMarks! ? kGreen : Colors.red) : Colors.black26),
              ]),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _marks[stu.dbId!],
                    enabled: !isAbsent,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Marks obtained', isDense: true, border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Column(children: [
                  const Text('Absent', style: TextStyle(fontSize: 11)),
                  Switch(value: isAbsent, onChanged: (v) => setState(() => _absent[stu.dbId!] = v)),
                ]),
              ]),
              if (pct != null && !isAbsent) Text('${pct.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 12, color: Colors.black54)),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (existing != null && !existing.isDeleted && canDelete)
                  TextButton.icon(onPressed: busy ? null : () => _delete(stu), icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red), label: const Text('Delete', style: TextStyle(color: Colors.red))),
                ElevatedButton(onPressed: busy ? null : () => _save(stu), child: Text(existing == null ? 'Save' : 'Update')),
              ]),
            ]),
          ),
        );
      }),
    ]);
  }
}

// ============================================================
// Audit history (correction / delete / restore trail)
// ============================================================

class ExamAuditScreen extends StatefulWidget {
  final Examination exam;
  const ExamAuditScreen({super.key, required this.exam});
  @override
  State<ExamAuditScreen> createState() => _ExamAuditScreenState();
}

class _ExamAuditScreenState extends State<ExamAuditScreen> {
  List<ResultAuditRow>? rows;

  @override
  void initState() {
    super.initState();
    loadExamAudit(widget.exam.id).then((r) {
      if (mounted) setState(() => rows = r);
    });
  }

  String _studentName(String? id) {
    if (id == null) return 'Whole examination';
    final s = st.students.where((s) => s.dbId == id).firstOrNull;
    return s?.name ?? '(student not found)';
  }

  @override
  Widget build(BuildContext context) => page([
        h('Audit history - ${widget.exam.name}', icon: Icons.history),
        if (rows == null) const Center(child: CircularProgressIndicator()),
        if (rows != null && rows!.isEmpty) const Text('No corrections or deletions recorded.', style: TextStyle(color: Colors.black54)),
        ...?rows?.map((r) => Card(
              child: ListTile(
                title: Text('${r.action[0].toUpperCase()}${r.action.substring(1)} - ${_studentName(r.studentId)}'),
                subtitle: Text(
                  '${r.oldMarks != null || r.newMarks != null ? '${r.oldMarks ?? '-'} -> ${r.newMarks ?? '-'}\n' : ''}'
                  'Reason: ${r.reason}\nBy ${r.actorRole ?? 'unknown'} on ${r.createdAt.toString().split('.').first}',
                ),
                isThreeLine: true,
              ),
            )),
      ]);
}

// ============================================================
// Student "My Results"
// ============================================================

class StudentMyResultsScreen extends StatefulWidget {
  const StudentMyResultsScreen({super.key});
  @override
  State<StudentMyResultsScreen> createState() => _StudentMyResultsScreenState();
}

class _StudentMyResultsScreenState extends State<StudentMyResultsScreen> {
  List<Map<String, dynamic>>? rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final kid = st.currentKid();
    if (kid?.dbId == null) {
      setState(() => rows = []);
      return;
    }
    final r = await loadMyResultsFor(kid!.dbId!);
    if (mounted) setState(() => rows = r);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: st,
        builder: (context, _) => page([
          ..._notifBanners(st.resultNotifs.where((n) => !n.isRead)),
          ...resultsBodyWidgets(rows, title: 'My Results'),
        ]),
      );
}

// ============================================================
// Parent "My Child's Results"
// ============================================================

class ParentChildResultsScreen extends StatefulWidget {
  const ParentChildResultsScreen({super.key});
  @override
  State<ParentChildResultsScreen> createState() => _ParentChildResultsScreenState();
}

class _ParentChildResultsScreenState extends State<ParentChildResultsScreen> {
  List<Map<String, dynamic>>? rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final kid = st.currentKid();
    if (kid?.dbId == null) {
      setState(() => rows = []);
      return;
    }
    final r = await loadMyResultsFor(kid!.dbId!);
    if (mounted) setState(() => rows = r);
  }

  @override
  Widget build(BuildContext context) {
    final kids = st.kids();
    final kidDbId = st.currentKid()?.dbId;
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) => page([
        if (kids.length > 1) ...[
          const Text('Child:'),
          Wrap(spacing: 6, children: [
            for (final k in kids)
              ChoiceChip(
                label: Text(k.name),
                selected: st.currentKid()?.id == k.id,
                onSelected: (_) {
                  st.selectKid(k.id);
                  _load();
                },
              ),
          ]),
          const SizedBox(height: 8),
        ],
        ..._notifBanners(st.resultNotifs.where((n) => !n.isRead && n.studentId == kidDbId)),
        ...resultsBodyWidgets(rows, title: "My Child's Results"),
      ]),
    );
  }
}

// A short, dismissible "<Examination> results published/corrected" card -
// never shows marks (section 11: "Avoid exposing detailed marks in
// notification previews"). Tapping it marks that one notification read;
// it stays visible until then, so opening this screen always surfaces it
// at least once, and it is never re-created just by reopening or
// refreshing (result_notifications only gets a new row from publish_exam
// / a real correction in save_exam_mark, never from a read).
List<Widget> _notifBanners(Iterable<ResultNotif> unread) => [
      for (final n in unread)
        Card(
          color: const Color(0xFFFFF6E0),
          child: ListTile(
            leading: const Icon(Icons.notifications_active, color: Color(0xFFB8860B)),
            title: Text(n.kind == 'corrected' ? '${n.examName} - result corrected' : '${n.examName} - result published'),
            subtitle: const Text('Tap to view and dismiss', style: TextStyle(fontSize: 11.5)),
            trailing: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => markResultNotifReadRemote(n)),
            onTap: () => markResultNotifReadRemote(n),
          ),
        ),
    ];

// Shared rendering for both the Student and Parent results screens -
// grouped by examination, published-only (loadMyResultsFor() only ever
// returns rows RLS allows, which already excludes draft/unpublished and
// deleted results).
List<Widget> resultsBodyWidgets(List<Map<String, dynamic>>? rows, {required String title}) {
  if (rows == null) return [h(title, icon: Icons.grading), const Center(child: CircularProgressIndicator())];
  if (rows.isEmpty) {
    return [h(title, icon: Icons.grading), const Text('No results have been published yet.', style: TextStyle(color: Colors.black54))];
  }
  final byExam = <String, List<Map<String, dynamic>>>{};
  for (final r in rows) {
    final es = r['exam_subjects'] as Map?;
    final exam = es?['examinations'] as Map?;
    final examId = exam?['id'] as String? ?? '';
    byExam.putIfAbsent(examId, () => []).add(r);
  }
  final out = <Widget>[h(title, icon: Icons.grading)];
  for (final entry in byExam.entries) {
    final first = entry.value.first;
    final exam = ((first['exam_subjects'] as Map?)?['examinations'] as Map?) ?? {};
    final examName = (exam['name'] as String?) ?? '';
    final className = ((exam['classes'] as Map?)?['name'] as String?) ?? '';
    final yearLabel = ((exam['academic_years'] as Map?)?['label'] as String?) ?? '';
    final startsOn = (exam['starts_on'] as String?) ?? '';
    out.add(Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(examName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          Text('$className - $yearLabel - $startsOn', style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
          const Divider(),
          for (final r in entry.value)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Builder(builder: (_) {
                final es = r['exam_subjects'] as Map? ?? {};
                final subject = (es['subject_name'] as String?) ?? '';
                final maxMarks = (es['max_marks'] as num?) ?? 0;
                final passing = es['passing_marks'] as num?;
                final isAbsent = (r['is_absent'] as bool?) ?? false;
                final marks = r['marks_obtained'] as num?;
                final pct = (!isAbsent && marks != null && maxMarks > 0) ? (marks / maxMarks * 100) : null;
                final passed = (!isAbsent && marks != null && passing != null) ? marks >= passing : null;
                return Row(children: [
                  Expanded(child: Text(subject)),
                  Text(isAbsent ? 'Absent' : (marks == null ? 'Not entered' : '$marks / $maxMarks')),
                  if (pct != null) Padding(padding: const EdgeInsets.only(left: 8), child: Text('${pct.toStringAsFixed(1)}%', style: const TextStyle(color: Colors.black54))),
                  if (passed != null) Padding(padding: const EdgeInsets.only(left: 8), child: Icon(passed ? Icons.check_circle : Icons.cancel, size: 16, color: passed ? kGreen : Colors.red)),
                ]);
              }),
            ),
        ]),
      ),
    ));
  }
  return out;
}

// Reusable "Results" tab for StudentDetail (main.dart) - the screen a
// Teacher/Admin/Super Admin/Committee member lands on from Search, "All
// Students", "Students by Maktab", or Committee's branch list. Shows the
// same published-only results a student/parent would see on their own
// "My Results" screen. The caller (StudentDetail) is responsible for only
// building this widget for an account that's actually allowed to see
// marks (Super Admin, or has_screen_permission('Results View')) - this
// widget itself does no permission check, since by the time it's on
// screen that decision has already been made.
class StudentResultsTab extends StatefulWidget {
  final Student s;
  const StudentResultsTab({super.key, required this.s});
  @override
  State<StudentResultsTab> createState() => _StudentResultsTabState();
}

class _StudentResultsTabState extends State<StudentResultsTab> {
  List<Map<String, dynamic>>? rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.s.dbId == null) {
      if (mounted) setState(() => rows = []);
      return;
    }
    final r = await loadMyResultsFor(widget.s.dbId!);
    final published = r.where((row) {
      final exam = ((row['exam_subjects'] as Map?)?['examinations'] as Map?) ?? {};
      return exam['status'] == 'Published';
    }).toList();
    if (mounted) setState(() => rows = published);
  }

  @override
  Widget build(BuildContext context) => page(resultsBodyWidgets(rows, title: 'Examination Results'));
}
