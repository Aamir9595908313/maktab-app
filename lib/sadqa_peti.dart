// ============================================================
// Sadqa Peti (donation box) management module.
//
// Donation boxes are placed at shops; roughly every two months the
// collection team opens a box, records the amount, and the shopkeeper gets
// a receipt and a WhatsApp/SMS notification. This file holds the Supabase
// wiring (public.sadqa_petis / sadqa_peti_collectors / sadqa_peti_collections
// / sadqa_peti_notifications - see the migration for the full schema, RLS
// and SECURITY DEFINER functions) plus every screen for it: the Super
// Admin master list, the collector-access assignment UI, the collection
// screen a collector actually uses at a shop, the PDF receipt, and the
// Super Admin dashboard/report.
// ============================================================
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image_picker/image_picker.dart';

import 'state.dart';
import 'main.dart';

// ============================================================
// Loading
// ============================================================

Future<void> loadSadqaPetis() async {
  try {
    final rows = await sb.from('sadqa_petis').select().order('created_at', ascending: false);
    st.setSadqaPetisFromDb([for (final r in (rows as List)) SadqaPeti.fromJson(r as Map<String, dynamic>)]);
  } catch (_) {}
}

Future<void> loadSadqaCollectors() async {
  try {
    final rows = await sb.from('sadqa_peti_collectors').select();
    final list = [for (final r in (rows as List)) SadqaCollector.fromJson(r as Map<String, dynamic>)];
    await _fillNames(list.map((c) => c.userId));
    for (final c in list) {
      c.userName = _nameCache[c.userId] ?? c.userId;
    }
    st.setSadqaCollectorsFromDb(list);
  } catch (_) {}
}

Future<void> loadSadqaCollections() async {
  try {
    final rows = await sb.from('sadqa_peti_collections').select().order('collected_at', ascending: false);
    final list = [for (final r in (rows as List)) SadqaCollection.fromJson(r as Map<String, dynamic>)];
    await _fillNames(list.map((c) => c.collectorId));
    for (final c in list) {
      c.collectorName = _nameCache[c.collectorId] ?? c.collectorId;
    }
    st.setSadqaCollectionsFromDb(list);
  } catch (_) {}
}

// Small in-memory cache so repeated loads don't keep re-querying the same
// user_profiles rows (the accounts involved rarely change between loads).
final Map<String, String> _nameCache = {};

Future<void> _fillNames(Iterable<String> ids) async {
  final missing = ids.where((id) => id.isNotEmpty && !_nameCache.containsKey(id)).toSet();
  if (missing.isEmpty) return;
  try {
    final rows = await sb.from('user_profiles').select('id, full_name').inFilter('id', missing.toList());
    for (final r in (rows as List)) {
      final m = r as Map<String, dynamic>;
      _nameCache[m['id'] as String] = (m['full_name'] as String?) ?? (m['id'] as String);
    }
  } catch (_) {}
}

// Every active account that could plausibly be made a collector (teacher,
// Maktab admin, committee, or another Super Admin) - fetched fresh each
// time the "assign collector" picker opens rather than kept in AppState,
// since it's only needed there.
Future<List<Map<String, String>>> loadAssignableAccounts() async {
  try {
    final rows = await sb
        .from('user_profiles')
        .select('id, full_name, phone, base_role')
        .eq('is_active', true)
        .inFilter('base_role', ['teacher', 'madrasa_admin', 'committee', 'super_admin'])
        .order('full_name');
    return [
      for (final r in (rows as List))
        {
          'id': (r as Map<String, dynamic>)['id'] as String,
          'name': (r['full_name'] as String?) ?? '',
          'phone': (r['phone'] as String?) ?? '',
          'role': (r['base_role'] as String?) ?? '',
        },
    ];
  } catch (_) {
    return [];
  }
}

// ============================================================
// Create / edit Sadqa Peti (Super Admin only - enforced in create_sadqa_peti)
// ============================================================

// Returns null on success, 'DUPLICATE_SHOPKEEPER' if an active box already
// exists for the same shopkeeper (caller should confirm and retry with
// force: true), or a readable error message otherwise.
Future<String?> createSadqaPetiRemote({
  required String name,
  required String phone,
  required String shop,
  String? address,
  String? area,
  required DateTime givenDate,
  String? boxNumber,
  required int freqMonths,
  String? remarks,
  bool force = false,
}) async {
  try {
    final row = await sb.rpc('create_sadqa_peti', params: {
      'p_shopkeeper_name': toTitleCase(name),
      'p_shopkeeper_phone': phone.trim(),
      'p_shop_name': toTitleCase(shop),
      'p_shop_address': address,
      'p_area': area == null ? null : toTitleCase(area),
      'p_box_given_date': _isoDate(givenDate),
      'p_box_number': boxNumber,
      'p_frequency_months': freqMonths,
      'p_remarks': remarks,
      'p_force': force,
    });
    final peti = SadqaPeti.fromJson(Map<String, dynamic>.from(row as Map));
    st.sadqaPetis.insert(0, peti);
    st.setSadqaPetisFromDb(st.sadqaPetis);
    return null;
  } on PostgrestException catch (e) {
    return e.message;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> updateSadqaPetiRemote(SadqaPeti p, {
  required String name,
  required String phone,
  required String shop,
  String? address,
  String? area,
  String? boxNumber,
  required int freqMonths,
  String? remarks,
}) async {
  try {
    final n = toTitleCase(name);
    final sh = toTitleCase(shop);
    final ar = area == null ? null : toTitleCase(area);
    await sb.from('sadqa_petis').update({
      'shopkeeper_name': n,
      'shopkeeper_phone': phone.trim(),
      'shop_name': sh,
      'shop_address': address,
      'area': ar,
      'box_number': boxNumber,
      'collection_frequency_months': freqMonths,
      'remarks': remarks,
      'updated_by': st.user?.dbId,
    }).eq('id', p.id);
    p
      ..shopkeeperName = n
      ..shopkeeperPhone = phone.trim()
      ..shopName = sh
      ..shopAddress = address
      ..area = ar
      ..boxNumber = boxNumber
      ..frequencyMonths = freqMonths
      ..remarks = remarks;
    st.setSadqaPetisFromDb(st.sadqaPetis);
    return null;
  } on PostgrestException catch (e) {
    return 'Only a Super Admin can edit a Sadqa Peti. (${e.message})';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> setSadqaPetiActiveRemote(SadqaPeti p, bool active) async {
  try {
    await sb.from('sadqa_petis').update({'status': active ? 'Active' : 'Inactive', 'updated_by': st.user?.dbId}).eq('id', p.id);
    p.status = active ? 'Active' : 'Inactive';
    st.setSadqaPetisFromDb(st.sadqaPetis);
    return null;
  } on PostgrestException catch (e) {
    return e.message;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// ============================================================
// Collector assignment (Super Admin only - enforced in the RPCs)
// ============================================================

Future<String?> assignSadqaCollectorRemote({required String userId, String? petiId}) async {
  try {
    await sb.rpc('assign_sadqa_collector', params: {'p_peti_id': petiId, 'p_user_id': userId});
    await loadSadqaCollectors();
    return null;
  } on PostgrestException catch (e) {
    return e.message;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> revokeSadqaCollectorRemote(SadqaCollector c) async {
  try {
    await sb.rpc('revoke_sadqa_collector', params: {'p_assignment_id': c.id});
    st.sadqaCollectors.removeWhere((x) => x.id == c.id);
    st.setSadqaCollectorsFromDb(st.sadqaCollectors);
    return null;
  } on PostgrestException catch (e) {
    return e.message;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// ============================================================
// Recording a collection - idempotent, authorized server-side
// ============================================================

String _newIdempotencyKey() => '${st.user?.dbId ?? 'anon'}-${DateTime.now().microsecondsSinceEpoch}';

class RecordCollectionResult {
  final SadqaCollection? collection;
  final String? error;
  const RecordCollectionResult({this.collection, this.error});
}

Future<RecordCollectionResult> recordSadqaCollectionRemote({
  required SadqaPeti peti,
  required double amount,
  String? remarks,
  String? photoFileRef,
  required String idempotencyKey,
}) async {
  try {
    final row = await sb.rpc('record_sadqa_collection', params: {
      'p_peti_id': peti.id,
      'p_amount': amount,
      'p_remarks': remarks,
      'p_photo_file_ref': photoFileRef,
      'p_idempotency_key': idempotencyKey,
    });
    final c = SadqaCollection.fromJson(Map<String, dynamic>.from(row as Map));
    c.collectorName = st.user?.name;
    st.sadqaCollections.insert(0, c);
    st.setSadqaCollectionsFromDb(st.sadqaCollections);
    // Advance the box's own last/next collection date locally too, so the
    // list screen reflects it immediately without a full reload.
    peti.lastCollectionDate = c.collectedAt.split('T').first;
    final next = DateTime.tryParse(peti.lastCollectionDate!);
    if (next != null) {
      peti.nextCollectionDate = _isoDate(DateTime(next.year, next.month + peti.frequencyMonths, next.day));
    }
    st.setSadqaPetisFromDb(st.sadqaPetis);
    // Fire-and-forget: kick the notification edge function. It logs its
    // own Pending/Sent/Failed outcome in sadqa_peti_notifications; nothing
    // here depends on it succeeding, and the receipt is already final.
    unawaited(sb.functions.invoke('send-sadqa-notification', body: {'collection_id': c.id}));
    return RecordCollectionResult(collection: c);
  } on PostgrestException catch (e) {
    return RecordCollectionResult(error: e.message);
  } catch (_) {
    return const RecordCollectionResult(error: 'Could not save. Check your internet connection and try again.');
  }
}

Future<String?> reverseSadqaCollectionRemote(SadqaCollection c, String reason) async {
  try {
    await sb.rpc('reverse_sadqa_collection', params: {'p_collection_id': c.id, 'p_reason': reason});
    await loadSadqaCollections();
    return null;
  } on PostgrestException catch (e) {
    return e.message;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<Map<String, dynamic>?> retrySadqaNotification(String collectionId) async {
  try {
    final res = await sb.functions.invoke('send-sadqa-notification', body: {'collection_id': collectionId});
    return (res.data as Map?)?.cast<String, dynamic>();
  } catch (_) {
    return null;
  }
}

// ============================================================
// Small helpers
// ============================================================

String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String maskPhone(String phone) {
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 4) return phone;
  return 'XXXXXX${digits.substring(digits.length - 4)}';
}

String fmtDateTime(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '${d.day} ${months[d.month - 1]} ${d.year}, ${h.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} $ampm';
}

String fmtDate(String? iso) {
  if (iso == null || iso.isEmpty) return '-';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

// Indian-style number-to-words (lakh/crore grouping), used on the receipt
// so the amount reads the way it would on a handwritten receipt.
String amountInWords(double amount) {
  final rupees = amount.floor();
  final paise = ((amount - rupees) * 100).round();
  final words = _numWordsIndian(rupees);
  final rupeeWords = 'Rupees $words';
  final paiseWords = paise > 0 ? ' and ${_numWordsIndian(paise)} Paise' : '';
  return '$rupeeWords$paiseWords Only';
}

String _numWordsIndian(int n) {
  if (n == 0) return 'Zero';
  const ones = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
  const tens = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];
  String twoDigits(int x) {
    if (x < 20) return ones[x];
    return '${tens[x ~/ 10]}${x % 10 != 0 ? ' ${ones[x % 10]}' : ''}';
  }

  String threeDigits(int x) {
    if (x < 100) return twoDigits(x);
    final rest = x % 100;
    return '${ones[x ~/ 100]} Hundred${rest != 0 ? ' ${twoDigits(rest)}' : ''}';
  }

  final crore = n ~/ 10000000;
  n %= 10000000;
  final lakh = n ~/ 100000;
  n %= 100000;
  final thousand = n ~/ 1000;
  n %= 1000;
  final hundred = n;

  final parts = <String>[];
  if (crore > 0) parts.add('${threeDigits(crore)} Crore');
  if (lakh > 0) parts.add('${threeDigits(lakh)} Lakh');
  if (thousand > 0) parts.add('${threeDigits(thousand)} Thousand');
  if (hundred > 0) parts.add(threeDigits(hundred));
  return parts.join(' ');
}

// ============================================================
// Receipt PDF
// ============================================================

Future<Uint8List> buildSadqaReceiptPdf(SadqaPeti peti, SadqaCollection c, {String? prevDate, double? prevAmount, required double totalToDate}) async {
  final doc = pw.Document();
  Uint8List? logoBytes;
  try {
    final bd = await rootBundle.load('assets/logo.png');
    logoBytes = bd.buffer.asUint8List();
  } catch (_) {}

  pw.Widget kv(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
        child: pw.Row(children: [
          pw.SizedBox(width: 160, child: pw.Text(k, style: const pw.TextStyle(fontSize: 10.5, color: PdfColors.grey700))),
          pw.Expanded(child: pw.Text(v, style: const pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold))),
        ]),
      );

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(30),
      build: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Center(
          child: pw.Column(children: [
            if (logoBytes != null) pw.Image(pw.MemoryImage(logoBytes), height: 54),
            pw.SizedBox(height: 6),
            pw.Text('Faiz-E-Raza Group Mehkar', style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold, color: PdfColor.fromInt(0xFF054D00))),
            pw.Text('Maktab-E-Tajushshriah', style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
            pw.SizedBox(height: 4),
            pw.Text('Sadqa Peti Collection Receipt', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          ]),
        ),
        pw.SizedBox(height: 10),
        pw.Divider(thickness: 1.2, color: PdfColor.fromInt(0xFFD4A72C)),
        pw.SizedBox(height: 8),
        kv('Receipt No', c.receiptNo),
        kv('Transaction ID', c.txnNo),
        kv('Sadqa Peti ID', peti.petiCode),
        kv('Shopkeeper', peti.shopkeeperName),
        kv('Shop Name', peti.shopName),
        if ((peti.shopAddress ?? '').isNotEmpty || (peti.area ?? '').isNotEmpty)
          kv('Shop Address', [peti.shopAddress, peti.area].where((x) => (x ?? '').isNotEmpty).join(', ')),
        kv('Mobile Number', maskPhone(peti.shopkeeperPhone)),
        kv('Collection Date', fmtDateTime(c.collectedAt)),
        kv('Collector', c.collectorName ?? '-'),
        pw.SizedBox(height: 12),
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6))),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Amount Collected: Rs. ${c.amount.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 3),
            pw.Text('In words: ${amountInWords(c.amount)}', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          ]),
        ),
        pw.SizedBox(height: 10),
        if (prevDate != null) kv('Previous Collection', '${fmtDate(prevDate)}${prevAmount != null ? '  -  Rs. ${prevAmount.toStringAsFixed(2)}' : ''}'),
        kv('Total Collected To Date (this box)', 'Rs. ${totalToDate.toStringAsFixed(2)}'),
        pw.SizedBox(height: 26),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Container(width: 150, height: 1, color: PdfColors.grey600),
            pw.SizedBox(height: 3),
            pw.Text('Collector signature / acknowledgement', style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)),
          ]),
        ]),
        pw.SizedBox(height: 22),
        pw.Center(child: pw.Text('JazakAllahu Khairan for your valuable support to Faiz-E-Raza Group Mehkar.', style: pw.TextStyle(fontSize: 11, fontStyle: pw.FontStyle.italic))),
        pw.Center(child: pw.Text('Your contribution is sincerely appreciated.', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700))),
      ]),
    ),
  );
  return doc.save();
}

// Rebuilds a receipt purely from already-saved rows (used from history, not
// just right after recording), so a previously issued receipt stays
// reproducible even if the shopkeeper's details are edited afterwards is
// NOT guaranteed by this helper alone - see the note on SadqaReceiptView.
Future<void> openSadqaReceipt(BuildContext context, SadqaPeti peti, SadqaCollection c) async {
  final history = st.sadqaCollections.where((x) => x.petiId == peti.id && x.status == 'Confirmed').toList()
    ..sort((a, b) => b.collectedAt.compareTo(a.collectedAt));
  final idx = history.indexWhere((x) => x.id == c.id);
  SadqaCollection? prev;
  if (idx >= 0 && idx + 1 < history.length) prev = history[idx + 1];
  final total = history.where((x) => x.collectedAt.compareTo(c.collectedAt) <= 0).fold<double>(0, (t, x) => t + x.amount);
  Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => SadqaReceiptView(peti: peti, collection: c, prevDate: prev?.collectedAt, prevAmount: prev?.amount, totalToDate: total),
    ),
  );
}

class SadqaReceiptView extends StatelessWidget {
  final SadqaPeti peti;
  final SadqaCollection collection;
  final String? prevDate;
  final double? prevAmount;
  final double totalToDate;
  const SadqaReceiptView({super.key, required this.peti, required this.collection, this.prevDate, this.prevAmount, required this.totalToDate});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Collection Receipt'), backgroundColor: kGreen, foregroundColor: Colors.white),
      body: PdfPreview(
        build: (format) => buildSadqaReceiptPdf(peti, collection, prevDate: prevDate, prevAmount: prevAmount, totalToDate: totalToDate),
        canChangeOrientation: false,
        canChangePageFormat: false,
        canDebug: false,
        pdfFileName: '${collection.receiptNo}.pdf',
      ),
    );
  }
}

// ============================================================
// Collection screen - search a box, record a collection, see the receipt
// ============================================================

class SadqaCollectionScreen extends StatefulWidget {
  const SadqaCollectionScreen({super.key});
  @override
  State<SadqaCollectionScreen> createState() => _SadqaCollectionScreenState();
}

class _SadqaCollectionScreenState extends State<SadqaCollectionScreen> {
  final search = TextEditingController();

  List<SadqaPeti> get _visible {
    final mine = st.sadqaPetis.where((p) => p.status == 'Active' && st.isSadqaCollectorFor(p.id));
    final q = search.text.trim().toLowerCase();
    if (q.isEmpty) return mine.toList();
    return mine
        .where((p) =>
            p.shopkeeperName.toLowerCase().contains(q) ||
            p.shopName.toLowerCase().contains(q) ||
            p.shopkeeperPhone.contains(q) ||
            p.petiCode.toLowerCase().contains(q) ||
            (p.area ?? '').toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Sadqa Peti Collection'), backgroundColor: kGreen, foregroundColor: Colors.white),
        body: page([
          TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search by shopkeeper, shop, mobile, area or Sadqa Peti ID',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          if (_visible.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 30),
              child: Center(child: Text('No Sadqa Peti assigned to you matches this search.', style: TextStyle(color: Colors.black54))),
            ),
          ..._visible.map((p) => Card(
                child: ListTile(
                  title: Text('${p.shopName} - ${p.shopkeeperName}'),
                  subtitle: Text('${p.petiCode} - ${p.shopkeeperPhone}\nNext due: ${fmtDate(p.nextCollectionDate)} (${p.scheduleStatus})'),
                  isThreeLine: true,
                  trailing: _statusChip(p.scheduleStatus),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RecordCollectionScreen(peti: p))),
                ),
              )),
        ]),
      ),
    );
  }

  Widget _statusChip(String s) {
    final color = switch (s) {
      'Overdue' => Colors.red,
      'Due' => Colors.orange,
      'Inactive' => Colors.black38,
      _ => kGreen,
    };
    return Chip(label: Text(s, style: const TextStyle(fontSize: 11, color: Colors.white)), backgroundColor: color, visualDensity: VisualDensity.compact);
  }
}

class RecordCollectionScreen extends StatefulWidget {
  final SadqaPeti peti;
  const RecordCollectionScreen({super.key, required this.peti});
  @override
  State<RecordCollectionScreen> createState() => _RecordCollectionScreenState();
}

class _RecordCollectionScreenState extends State<RecordCollectionScreen> {
  final amount = TextEditingController();
  final remarks = TextEditingController();
  bool confirmed = false;
  bool busy = false;
  XFile? photo;
  late final String idempotencyKey = _newIdempotencyKey();

  Future<void> _pickPhoto() async {
    try {
      final f = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1280, imageQuality: 70);
      if (f != null) setState(() => photo = f);
    } catch (_) {
      if (mounted) toast(context, 'Could not open the camera.');
    }
  }

  Future<String?> _uploadPhotoIfAny() async {
    if (photo == null) return null;
    try {
      final bytes = await photo!.readAsBytes();
      final path = 'sadqa_peti/${widget.peti.id}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      await sb.storage.from('documents').uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
      return path;
    } catch (_) {
      return null; // evidence photo is optional - a failed upload shouldn't block the collection itself
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.peti;
    final amt = double.tryParse(amount.text.trim());
    final canSubmit = !busy && confirmed && amt != null && amt >= 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Record Collection'), backgroundColor: kGreen, foregroundColor: Colors.white),
      body: page([
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.shopName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              Text('${p.shopkeeperName} - ${p.shopkeeperPhone}'),
              Text(p.petiCode, style: const TextStyle(color: Colors.black54)),
              if ((p.shopAddress ?? '').isNotEmpty || (p.area ?? '').isNotEmpty) Text([p.shopAddress, p.area].where((x) => (x ?? '').isNotEmpty).join(', ')),
              const SizedBox(height: 4),
              Text('Last collection: ${fmtDate(p.lastCollectionDate)}  -  Next due: ${fmtDate(p.nextCollectionDate)}', style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: amount,
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount collected (Rs.)', border: OutlineInputBorder()),
          ),
        ),
        field(remarks, 'Remarks (optional)', lines: 2),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: _pickPhoto,
          icon: const Icon(Icons.camera_alt),
          label: Text(photo == null ? 'Add a photo of the opened box (optional)' : 'Photo added - tap to retake'),
        ),
        const SizedBox(height: 10),
        CheckboxListTile(
          value: confirmed,
          onChanged: (v) => setState(() => confirmed = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('I confirm the amount entered above has been verified.'),
        ),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: canSubmit
              ? () async {
                  setState(() => busy = true);
                  final photoRef = await _uploadPhotoIfAny();
                  final res = await recordSadqaCollectionRemote(
                    peti: p,
                    amount: amt,
                    remarks: remarks.text.trim().isEmpty ? null : remarks.text.trim(),
                    photoFileRef: photoRef,
                    idempotencyKey: idempotencyKey,
                  );
                  if (!mounted) return;
                  setState(() => busy = false);
                  if (res.error != null) {
                    toast(context, res.error!);
                    return;
                  }
                  toast(context, 'Collection of Rs. ${amt.toStringAsFixed(2)} recorded. Receipt no. ${res.collection!.receiptNo}.');
                  await openSadqaReceipt(context, p, res.collection!);
                  if (mounted) Navigator.pop(context);
                }
              : null,
          icon: busy ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle),
          label: const Text('Submit Collection'),
        ),
      ]),
    );
  }
}

// ============================================================
// Super Admin: master list (create / edit / activate / assign collectors)
// ============================================================

class SadqaPetiMasterView extends StatefulWidget {
  const SadqaPetiMasterView({super.key});
  @override
  State<SadqaPetiMasterView> createState() => _SadqaPetiMasterViewState();
}

class _SadqaPetiMasterViewState extends State<SadqaPetiMasterView> {
  final search = TextEditingController();

  List<SadqaPeti> get _filtered {
    final q = search.text.trim().toLowerCase();
    if (q.isEmpty) return st.sadqaPetis;
    return st.sadqaPetis
        .where((p) =>
            p.shopkeeperName.toLowerCase().contains(q) ||
            p.shopName.toLowerCase().contains(q) ||
            p.shopkeeperPhone.contains(q) ||
            p.petiCode.toLowerCase().contains(q) ||
            (p.area ?? '').toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) => page([
        Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => pushPage(context, 'Sadqa Peti Dashboard', const SadqaPetiDashboardView()),
              icon: const Icon(Icons.dashboard),
              label: const Text('Dashboard & Reports'),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        TextField(
          controller: search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Search boxes', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: () => _openEditor(context, null),
          icon: const Icon(Icons.add),
          label: const Text('Add Sadqa Peti'),
        ),
        const SizedBox(height: 10),
        if (st.sadqaPetis.isEmpty) const Text('No Sadqa Peti boxes yet.', style: TextStyle(color: Colors.black54)),
        ..._filtered.map((p) => Card(
              child: Column(children: [
                SwitchListTile(
                  title: Text('${p.petiCode} - ${p.shopName}'),
                  subtitle: Text('${p.shopkeeperName} - ${p.shopkeeperPhone}\n${p.area ?? ''}\nNext due: ${fmtDate(p.nextCollectionDate)} (${p.scheduleStatus})'),
                  isThreeLine: true,
                  value: p.status == 'Active',
                  onChanged: (v) async {
                    final e = await setSadqaPetiActiveRemote(p, v);
                    if (context.mounted && e != null) toast(context, e);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Wrap(spacing: 6, children: [
                    TextButton.icon(onPressed: () => _openEditor(context, p), icon: const Icon(Icons.edit, size: 16), label: const Text('Edit')),
                    TextButton.icon(onPressed: () => _openCollectors(context, p), icon: const Icon(Icons.groups, size: 16), label: const Text('Collectors')),
                    TextButton.icon(
                      onPressed: () => pushPage(context, 'History - ${p.petiCode}', SadqaBoxHistoryView(peti: p)),
                      icon: const Icon(Icons.history, size: 16),
                      label: const Text('History'),
                    ),
                  ]),
                ),
              ]),
            )),
      ]),
    );
  }

  Future<void> _openEditor(BuildContext context, SadqaPeti? existing) async {
    final name = TextEditingController(text: existing?.shopkeeperName ?? '');
    final phone = TextEditingController(text: existing?.shopkeeperPhone ?? '');
    final shop = TextEditingController(text: existing?.shopName ?? '');
    final address = TextEditingController(text: existing?.shopAddress ?? '');
    final area = TextEditingController(text: existing?.area ?? '');
    final boxNumber = TextEditingController(text: existing?.boxNumber ?? '');
    final freq = TextEditingController(text: '${existing?.frequencyMonths ?? 2}');
    final remarks = TextEditingController(text: existing?.remarks ?? '');
    DateTime givenDate = existing != null ? (DateTime.tryParse(existing.boxGivenDate) ?? DateTime.now()) : DateTime.now();
    bool busy = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(existing == null ? 'Add Sadqa Peti' : 'Edit Sadqa Peti'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Shopkeeper name')),
              const SizedBox(height: 8),
              TextField(controller: phone, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Mobile number (10 digits)')),
              const SizedBox(height: 8),
              TextField(controller: shop, decoration: const InputDecoration(labelText: 'Shop name')),
              const SizedBox(height: 8),
              TextField(controller: address, decoration: const InputDecoration(labelText: 'Shop address')),
              const SizedBox(height: 8),
              TextField(controller: area, decoration: const InputDecoration(labelText: 'Area / locality')),
              const SizedBox(height: 8),
              TextField(controller: boxNumber, decoration: const InputDecoration(labelText: 'Box number / label (optional)')),
              const SizedBox(height: 8),
              TextField(controller: freq, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Collection frequency (months)')),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: Text('Box given on: ${fmtDate(_isoDate(givenDate))}')),
                TextButton(
                  onPressed: () async {
                    final d = await showDatePicker(context: ctx, initialDate: givenDate, firstDate: DateTime(2015), lastDate: DateTime.now());
                    if (d != null) setD(() => givenDate = d);
                  },
                  child: const Text('Change'),
                ),
              ]),
              TextField(controller: remarks, decoration: const InputDecoration(labelText: 'Remarks (optional)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: busy
                  ? null
                  : () async {
                      setD(() => busy = true);
                      Future<void> save({bool force = false}) async {
                        final freqVal = int.tryParse(freq.text.trim()) ?? 2;
                        final e = existing == null
                            ? await createSadqaPetiRemote(
                                name: name.text,
                                phone: phone.text,
                                shop: shop.text,
                                address: address.text.trim().isEmpty ? null : address.text.trim(),
                                area: area.text.trim().isEmpty ? null : area.text.trim(),
                                givenDate: givenDate,
                                boxNumber: boxNumber.text.trim().isEmpty ? null : boxNumber.text.trim(),
                                freqMonths: freqVal,
                                remarks: remarks.text.trim().isEmpty ? null : remarks.text.trim(),
                                force: force,
                              )
                            : await updateSadqaPetiRemote(
                                existing,
                                name: name.text,
                                phone: phone.text,
                                shop: shop.text,
                                address: address.text.trim().isEmpty ? null : address.text.trim(),
                                area: area.text.trim().isEmpty ? null : area.text.trim(),
                                boxNumber: boxNumber.text.trim().isEmpty ? null : boxNumber.text.trim(),
                                freqMonths: freqVal,
                                remarks: remarks.text.trim().isEmpty ? null : remarks.text.trim(),
                              );
                        if (e == 'DUPLICATE_SHOPKEEPER') {
                          if (!ctx.mounted) return;
                          setD(() => busy = false);
                          final proceed = await showDialog<bool>(
                            context: ctx,
                            builder: (c2) => AlertDialog(
                              title: const Text('Possible duplicate'),
                              content: const Text('An active Sadqa Peti already exists for this shopkeeper name and mobile number. Create another box for them anyway?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('Cancel')),
                                ElevatedButton(onPressed: () => Navigator.pop(c2, true), child: const Text('Create anyway')),
                              ],
                            ),
                          );
                          if (proceed == true) {
                            setD(() => busy = true);
                            await save(force: true);
                          }
                          return;
                        }
                        if (!ctx.mounted) return;
                        setD(() => busy = false);
                        if (e != null) {
                          toast(ctx, e);
                        } else {
                          Navigator.pop(ctx);
                        }
                      }

                      await save();
                    },
              child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCollectors(BuildContext context, SadqaPeti p) async {
    final assigned = st.sadqaCollectors.where((c) => c.petiId == p.id).toList();
    final global = st.sadqaCollectors.where((c) => c.petiId == null).toList();
    List<Map<String, String>> accounts = [];
    bool loading = true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          if (loading) {
            loadAssignableAccounts().then((a) {
              accounts = a;
              loading = false;
              if (ctx.mounted) setD(() {});
            });
          }
          return AlertDialog(
            title: Text('Collectors - ${p.petiCode}'),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Assigned to this box:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
                  if (assigned.isEmpty) const Text('None', style: TextStyle(color: Colors.black54)),
                  ...assigned.map((c) => ListTile(
                        dense: true,
                        title: Text(c.userName.isEmpty ? c.userId : c.userName),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () async {
                            final e = await revokeSadqaCollectorRemote(c);
                            if (ctx.mounted && e != null) toast(ctx, e);
                            if (ctx.mounted) setD(() {});
                          },
                        ),
                      )),
                  const SizedBox(height: 8),
                  const Text('Global collectors (access to every box):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
                  ...global.map((c) => ListTile(dense: true, title: Text(c.userName.isEmpty ? c.userId : c.userName))),
                  const Divider(),
                  if (loading)
                    const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
                  else
                    DropdownButtonFormField<String>(
                      decoration: const InputDecoration(labelText: 'Assign a collector to this box'),
                      items: [for (final a in accounts) DropdownMenuItem(value: a['id'], child: Text('${a['name']} (${a['role']})'))],
                      onChanged: (v) async {
                        if (v == null) return;
                        final e = await assignSadqaCollectorRemote(userId: v, petiId: p.id);
                        if (ctx.mounted && e != null) toast(ctx, e);
                        if (ctx.mounted) setD(() {});
                      },
                    ),
                ]),
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
          );
        },
      ),
    );
  }
}

class SadqaBoxHistoryView extends StatelessWidget {
  final SadqaPeti peti;
  const SadqaBoxHistoryView({super.key, required this.peti});
  @override
  Widget build(BuildContext context) {
    final rows = st.sadqaCollections.where((c) => c.petiId == peti.id).toList()..sort((a, b) => b.collectedAt.compareTo(a.collectedAt));
    final total = rows.where((c) => c.status == 'Confirmed').fold<double>(0, (t, c) => t + c.amount);
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) => page([
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Total collected to date: Rs. ${total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        if (rows.isEmpty) const Text('No collections recorded yet.', style: TextStyle(color: Colors.black54)),
        ...rows.map((c) => Card(
              child: ListTile(
                title: Text('Rs. ${c.amount.toStringAsFixed(2)}  -  ${c.receiptNo}'),
                subtitle: Text('${fmtDateTime(c.collectedAt)} - ${c.collectorName ?? c.collectorId}${c.status == 'Reversed' ? '\nReversed: ${c.reversalReason ?? ''}' : ''}'),
                isThreeLine: c.status == 'Reversed',
                trailing: c.status == 'Reversed'
                    ? const Chip(label: Text('Reversed', style: TextStyle(fontSize: 11, color: Colors.white)), backgroundColor: Colors.red)
                    : Wrap(spacing: 4, children: [
                        IconButton(icon: const Icon(Icons.receipt_long), tooltip: 'Receipt', onPressed: () => openSadqaReceipt(context, peti, c)),
                        if (st.user?.role == 'super')
                          IconButton(
                            icon: const Icon(Icons.undo),
                            tooltip: 'Reverse (correction)',
                            onPressed: () async {
                              final reason = await askText(context, 'Reason for reversing this collection');
                              if (reason == null || reason.trim().isEmpty) return;
                              final e = await reverseSadqaCollectionRemote(c, reason.trim());
                              if (context.mounted && e != null) toast(context, e);
                            },
                          ),
                      ]),
              ),
            )),
      ]),
    );
  }
}

// ============================================================
// Super Admin dashboard: summary cards, filters, register, exports
// ============================================================

class SadqaPetiDashboardView extends StatefulWidget {
  const SadqaPetiDashboardView({super.key});
  @override
  State<SadqaPetiDashboardView> createState() => _SadqaPetiDashboardViewState();
}

class _SadqaPetiDashboardViewState extends State<SadqaPetiDashboardView> {
  DateTimeRange? range;
  String q = '';
  String? statusFilter; // schedule status
  bool busy = false;
  int failedNotifCount = 0;
  int pendingNotifCount = 0;

  @override
  void initState() {
    super.initState();
    _loadNotifStats();
  }

  Future<void> _loadNotifStats() async {
    try {
      final failed = await sb.from('sadqa_peti_notifications').select('id').eq('status', 'Failed');
      final pending = await sb.from('sadqa_peti_notifications').select('id').eq('status', 'Pending');
      if (!mounted) return;
      setState(() {
        failedNotifCount = (failed as List).length;
        pendingNotifCount = (pending as List).length;
      });
    } catch (_) {}
  }

  List<SadqaCollection> get _confirmed => st.sadqaCollections.where((c) => c.status == 'Confirmed').toList();

  List<SadqaCollection> get _filtered {
    var rows = _confirmed;
    if (range != null) {
      rows = rows.where((c) {
        final d = DateTime.tryParse(c.collectedAt);
        if (d == null) return false;
        return !d.isBefore(range!.start) && d.isBefore(range!.end.add(const Duration(days: 1)));
      }).toList();
    }
    if (q.trim().isNotEmpty) {
      final needle = q.trim().toLowerCase();
      rows = rows.where((c) {
        final p = st.sadqaPetis.where((p) => p.id == c.petiId).firstOrNull;
        if (p == null) return false;
        return p.shopkeeperName.toLowerCase().contains(needle) ||
            p.shopName.toLowerCase().contains(needle) ||
            p.shopkeeperPhone.contains(needle) ||
            p.petiCode.toLowerCase().contains(needle) ||
            (p.area ?? '').toLowerCase().contains(needle);
      }).toList();
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final petis = st.sadqaPetis;
    final activeBoxes = petis.where((p) => p.status == 'Active').length;
    final due = petis.where((p) => p.scheduleStatus == 'Due').length;
    final overdue = petis.where((p) => p.scheduleStatus == 'Overdue').length;
    final now = DateTime.now();
    final monthRows = _confirmed.where((c) {
      final d = DateTime.tryParse(c.collectedAt);
      return d != null && d.year == now.year && d.month == now.month;
    });
    final monthTotal = monthRows.fold<double>(0, (t, c) => t + c.amount);
    final lifetimeTotal = _confirmed.fold<double>(0, (t, c) => t + c.amount);
    final filteredTotal = _filtered.fold<double>(0, (t, c) => t + c.amount);

    return AnimatedBuilder(
      animation: st,
      builder: (context, _) => page([
        grid([
          tile('Active Boxes', '$activeBoxes', icon: Icons.inventory_2),
          tile('Registered Shops', '${petis.length}', icon: Icons.storefront),
          tile('Collections Due', '$due', icon: Icons.schedule, color: Colors.orange),
          tile('Overdue', '$overdue', icon: Icons.warning_amber, color: Colors.red),
          tile('Completed This Month', '${monthRows.length}', icon: Icons.task_alt),
          tile('Amount This Month', 'Rs. ${monthTotal.toStringAsFixed(0)}', icon: Icons.calendar_month),
          tile('Lifetime Total', 'Rs. ${lifetimeTotal.toStringAsFixed(0)}', icon: Icons.savings),
          tile('Selected Range Total', 'Rs. ${filteredTotal.toStringAsFixed(0)}', icon: Icons.filter_alt),
          tile('Reversed Collections', '${st.sadqaCollections.where((c) => c.status == 'Reversed').length}', icon: Icons.undo),
          tile('Pending Notifications', '$pendingNotifCount', icon: Icons.hourglass_top, color: Colors.orange),
          tile('Failed Notifications', '$failedNotifCount', icon: Icons.error_outline, color: failedNotifCount > 0 ? Colors.red : null),
        ]),
        const SizedBox(height: 10),
        h('Filters', icon: Icons.filter_list),
        TextField(
          onChanged: (v) => setState(() => q = v),
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Shopkeeper, shop, mobile, area or Sadqa Peti ID', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final r = await showDateRangePicker(context: context, firstDate: DateTime(2015), lastDate: DateTime.now(), initialDateRange: range);
                if (r != null) setState(() => range = r);
              },
              icon: const Icon(Icons.date_range),
              label: Text(range == null ? 'Date range' : '${fmtDate(_isoDate(range!.start))} - ${fmtDate(_isoDate(range!.end))}'),
            ),
          ),
          if (range != null) IconButton(onPressed: () => setState(() => range = null), icon: const Icon(Icons.clear)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: busy ? null : () => _exportCsv(context),
              icon: const Icon(Icons.table_view),
              label: const Text('Export CSV'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: busy ? null : () => _exportPdf(context),
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('Export PDF'),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        h('Collection Register (${_filtered.length})', icon: Icons.receipt_long),
        ..._filtered.map((c) {
          final p = st.sadqaPetis.where((p) => p.id == c.petiId).firstOrNull;
          return Card(
            child: ListTile(
              title: Text('${p?.shopName ?? c.petiId} - Rs. ${c.amount.toStringAsFixed(2)}'),
              subtitle: Text('${fmtDateTime(c.collectedAt)} - ${p?.shopkeeperName ?? ''}\nCollector: ${c.collectorName ?? c.collectorId} - Receipt: ${c.receiptNo}'),
              isThreeLine: true,
              trailing: p == null ? null : IconButton(icon: const Icon(Icons.receipt_long), onPressed: () => openSadqaReceipt(context, p, c)),
            ),
          );
        }),
      ]),
    );
  }

  Future<void> _exportCsv(BuildContext context) async {
    setState(() => busy = true);
    try {
      final rows = <List<String>>[
        ['Date', 'Shopkeeper', 'Shop', 'Area', 'Sadqa Peti ID', 'Amount', 'Collector', 'Receipt No', 'Status'],
        for (final c in _filtered)
          [
            fmtDateTime(c.collectedAt),
            st.sadqaPetis.where((p) => p.id == c.petiId).firstOrNull?.shopkeeperName ?? '',
            st.sadqaPetis.where((p) => p.id == c.petiId).firstOrNull?.shopName ?? '',
            st.sadqaPetis.where((p) => p.id == c.petiId).firstOrNull?.area ?? '',
            st.sadqaPetis.where((p) => p.id == c.petiId).firstOrNull?.petiCode ?? '',
            c.amount.toStringAsFixed(2),
            c.collectorName ?? c.collectorId,
            c.receiptNo,
            c.status,
          ],
      ];
      final csv = const ListToCsvConverter().convert(rows);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/sadqa_peti_collections.csv');
      await file.writeAsString(csv);
      await Share.shareXFiles([XFile(file.path)], text: 'Sadqa Peti collection report');
    } catch (_) {
      if (mounted) toast(context, 'Could not export CSV.');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _exportPdf(BuildContext context) async {
    setState(() => busy = true);
    try {
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          build: (ctx) => [
            pw.Text('Sadqa Peti Collection Report', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
            pw.Text('Faiz-E-Raza Group Mehkar - Maktab-E-Tajushshriah', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
            pw.SizedBox(height: 10),
            pw.Table.fromTextArray(
              headers: ['Date', 'Shopkeeper', 'Shop', 'Amount', 'Receipt No'],
              data: [
                for (final c in _filtered)
                  [
                    fmtDate(c.collectedAt),
                    st.sadqaPetis.where((p) => p.id == c.petiId).firstOrNull?.shopkeeperName ?? '',
                    st.sadqaPetis.where((p) => p.id == c.petiId).firstOrNull?.shopName ?? '',
                    c.amount.toStringAsFixed(2),
                    c.receiptNo,
                  ],
              ],
              cellStyle: const pw.TextStyle(fontSize: 9),
              headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 10),
            pw.Text('Total: Rs. ${_filtered.fold<double>(0, (t, c) => t + c.amount).toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          ],
        ),
      );
      await Printing.sharePdf(bytes: await doc.save(), filename: 'sadqa_peti_report.pdf');
    } catch (_) {
      if (mounted) toast(context, 'Could not export PDF.');
    }
    if (mounted) setState(() => busy = false);
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
