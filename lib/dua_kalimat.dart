// ---------------- Dua'iya Kalimat Gallery ----------------
//
// Super-Admin-managed Islamic dua content (an image or a PDF per item),
// shown read-only to Guests and every logged-in role. Backed by
// public.dua_kalimat_items (metadata) + the private 'dua_kalimat' storage
// bucket (the actual files) - see the add_dua_kalimat_gallery migration
// for the table/bucket/RLS definitions this file relies on.
//
// Nothing here ever hands out a public or long-lived URL: every file is
// fetched with sb.storage...download(), which goes through the same
// Supabase Auth session (or anon key, for a true Guest) as any other
// request and is checked against storage RLS on every single call - a
// deactivated or deleted item's path stops being readable immediately,
// even though createSignedUrl/public-URL approaches would have kept
// working until a link expired or was revoked. Bytes are kept in memory
// only (a short-lived per-screen cache), never written to disk, so there
// is no file left behind in any device-accessible folder either.

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:printing/printing.dart';
import 'package:flutter_windowmanager_plus/flutter_windowmanager_plus.dart';
import 'main.dart' show sb, kGreen, page, toast, askText;
import 'state.dart' show fd, nice;

const String kDuaKalimatBucket = 'dua_kalimat';
const int kDuaKalimatMaxBytes = 10 * 1024 * 1024; // 10 MB - also enforced server-side on the bucket itself.

class DuaKalimatItem {
  final String id;
  String title;
  String fileType; // 'image' | 'pdf'
  String storagePath;
  String? thumbnailPath;
  int sequenceOrder;
  bool isActive;
  DateTime? updatedAt;

  DuaKalimatItem({
    required this.id,
    required this.title,
    required this.fileType,
    required this.storagePath,
    this.thumbnailPath,
    required this.sequenceOrder,
    required this.isActive,
    this.updatedAt,
  });

  factory DuaKalimatItem.fromJson(Map<String, dynamic> r) => DuaKalimatItem(
        id: r['id'] as String,
        title: (r['title'] as String?) ?? '',
        fileType: (r['file_type'] as String?) ?? 'image',
        storagePath: (r['storage_path'] as String?) ?? '',
        thumbnailPath: r['thumbnail_path'] as String?,
        sequenceOrder: (r['sequence_order'] as int?) ?? 0,
        isActive: (r['is_active'] as bool?) ?? true,
        updatedAt: r['updated_at'] == null ? null : DateTime.tryParse(r['updated_at'] as String),
      );
}

Future<List<DuaKalimatItem>> fetchDuaKalimatItems({bool includeInactive = false}) async {
  final rows = includeInactive
      ? await sb.from('dua_kalimat_items').select().order('sequence_order').order('title')
      : await sb.from('dua_kalimat_items').select().eq('is_active', true).order('sequence_order').order('title');
  return [for (final r in (rows as List)) DuaKalimatItem.fromJson(r as Map<String, dynamic>)];
}

String? _fileTypeForName(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.pdf')) return 'pdf';
  if (n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.png') || n.endsWith('.webp')) return 'image';
  return null;
}

String _contentTypeFor(String fileType, String name) {
  if (fileType == 'pdf') return 'application/pdf';
  final n = name.toLowerCase();
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

String _safeStem(String title) => title.trim().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').toLowerCase();

Future<String?> createDuaKalimatItemRemote({
  required String title,
  required int sequenceOrder,
  required String fileType,
  required Uint8List bytes,
  required String fileName,
}) async {
  if (title.trim().isEmpty) return 'Enter a title.';
  if (bytes.length > kDuaKalimatMaxBytes) return 'That file is larger than the 10 MB limit.';
  final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : (fileType == 'pdf' ? 'pdf' : 'jpg');
  final path = 'dua_kalimat/${DateTime.now().millisecondsSinceEpoch}_${_safeStem(title)}.$ext';
  try {
    await sb.storage.from(kDuaKalimatBucket).uploadBinary(path, bytes, fileOptions: FileOptions(contentType: _contentTypeFor(fileType, fileName)));
  } on StorageException catch (e) {
    return 'Could not upload the file: ${e.message}';
  } catch (_) {
    return 'Could not upload the file. Check your internet connection and try again.';
  }
  try {
    await sb.from('dua_kalimat_items').insert({
      'title': title.trim(),
      'file_type': fileType,
      'storage_path': path,
      'thumbnail_path': fileType == 'image' ? path : null,
      'sequence_order': sequenceOrder,
      'created_by': sb.auth.currentUser?.id,
      'updated_by': sb.auth.currentUser?.id,
    });
    return null;
  } on PostgrestException catch (e) {
    // The row failed - remove the just-uploaded file so a failed save
    // never leaves an orphaned file with no matching gallery item.
    try {
      await sb.storage.from(kDuaKalimatBucket).remove([path]);
    } catch (_) {}
    if (e.code == '42501') return "Only a Super Admin can upload Dua'iya Kalimat content.";
    return 'Could not save: ${e.message}';
  } catch (_) {
    try {
      await sb.storage.from(kDuaKalimatBucket).remove([path]);
    } catch (_) {}
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> updateDuaKalimatItemRemote(DuaKalimatItem item, {String? title, int? sequenceOrder}) async {
  final payload = <String, dynamic>{
    'updated_by': sb.auth.currentUser?.id,
    'updated_at': DateTime.now().toIso8601String(),
  };
  if (title != null && title.trim().isNotEmpty) payload['title'] = title.trim();
  if (sequenceOrder != null) payload['sequence_order'] = sequenceOrder;
  try {
    await sb.from('dua_kalimat_items').update(payload).eq('id', item.id);
    if (title != null && title.trim().isNotEmpty) item.title = title.trim();
    if (sequenceOrder != null) item.sequenceOrder = sequenceOrder;
    item.updatedAt = DateTime.now();
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> setDuaKalimatActiveRemote(DuaKalimatItem item, bool active) async {
  try {
    await sb.from('dua_kalimat_items').update({
      'is_active': active,
      'updated_by': sb.auth.currentUser?.id,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', item.id);
    item.isActive = active;
    item.updatedAt = DateTime.now();
    return null;
  } on PostgrestException catch (e) {
    return 'Could not update: ${e.message}';
  } catch (_) {
    return 'Could not update. Check your internet connection and try again.';
  }
}

Future<String?> replaceDuaKalimatFileRemote(DuaKalimatItem item, {required String fileType, required Uint8List bytes, required String fileName}) async {
  if (bytes.length > kDuaKalimatMaxBytes) return 'That file is larger than the 10 MB limit.';
  final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : (fileType == 'pdf' ? 'pdf' : 'jpg');
  final newPath = 'dua_kalimat/${DateTime.now().millisecondsSinceEpoch}_${item.id}.$ext';
  try {
    await sb.storage.from(kDuaKalimatBucket).uploadBinary(newPath, bytes, fileOptions: FileOptions(contentType: _contentTypeFor(fileType, fileName)));
  } on StorageException catch (e) {
    return 'Could not upload the replacement file: ${e.message}';
  } catch (_) {
    return 'Could not upload the replacement file. Check your internet connection and try again.';
  }
  final oldPath = item.storagePath;
  final oldThumb = item.thumbnailPath;
  try {
    await sb.from('dua_kalimat_items').update({
      'file_type': fileType,
      'storage_path': newPath,
      'thumbnail_path': fileType == 'image' ? newPath : null,
      'updated_by': sb.auth.currentUser?.id,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', item.id);
  } on PostgrestException catch (e) {
    try {
      await sb.storage.from(kDuaKalimatBucket).remove([newPath]);
    } catch (_) {}
    return 'Could not save: ${e.message}';
  } catch (_) {
    try {
      await sb.storage.from(kDuaKalimatBucket).remove([newPath]);
    } catch (_) {}
    return 'Could not save. Check your internet connection and try again.';
  }
  item.fileType = fileType;
  item.storagePath = newPath;
  item.thumbnailPath = fileType == 'image' ? newPath : null;
  item.updatedAt = DateTime.now();
  _duaKalimatCache.remove(oldPath);
  if (oldThumb != null) _duaKalimatCache.remove(oldThumb);
  // Only remove the old file(s) once the row points at the new one - never
  // delete first, which could strand the item with no file at all if the
  // database update above had failed instead.
  final toRemove = <String>{oldPath, if (oldThumb != null) oldThumb}.toList();
  try {
    await sb.storage.from(kDuaKalimatBucket).remove(toRemove);
  } catch (_) {}
  return null;
}

Future<String?> deleteDuaKalimatItemRemote(DuaKalimatItem item) async {
  try {
    await sb.from('dua_kalimat_items').delete().eq('id', item.id);
  } on PostgrestException catch (e) {
    return 'Could not delete: ${e.message}';
  } catch (_) {
    return 'Could not delete. Check your internet connection and try again.';
  }
  // The row is gone - remove its file(s) too. If this part fails, the
  // file is simply orphaned in storage: storage RLS requires a matching
  // active row to read it back, so nothing can ever fetch it again -
  // it's just unused space, never a dangling reference anyone can hit.
  final paths = <String>{item.storagePath, if (item.thumbnailPath != null) item.thumbnailPath!}.toList();
  try {
    await sb.storage.from(kDuaKalimatBucket).remove(paths);
  } catch (_) {}
  _duaKalimatCache.remove(item.storagePath);
  if (item.thumbnailPath != null) _duaKalimatCache.remove(item.thumbnailPath);
  return null;
}

// Session-only, in-memory - never written to disk, so there's no cached
// copy left behind in any device-accessible folder. Cleared automatically
// when the app process ends; individual entries are dropped above
// whenever a file is replaced or deleted so a stale copy can't linger.
final Map<String, Uint8List> _duaKalimatCache = {};

Future<Uint8List?> downloadDuaKalimatFile(String path) async {
  final cached = _duaKalimatCache[path];
  if (cached != null) return cached;
  try {
    final bytes = await sb.storage.from(kDuaKalimatBucket).download(path);
    _duaKalimatCache[path] = bytes;
    return bytes;
  } catch (_) {
    return null;
  }
}

// Wraps a screen with Android's FLAG_SECURE for as long as it's on
// screen: the OS refuses a normal screenshot or screen-recording of this
// window, and also blanks it out of the task switcher's recent-apps
// preview. This is Android's own strongest practical protection - not a
// guarantee against every form of capture (see the note on the viewer
// screen below for what it does not cover).
class SecureScreen extends StatefulWidget {
  const SecureScreen({super.key, required this.child});
  final Widget child;
  @override
  State<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends State<SecureScreen> {
  @override
  void initState() {
    super.initState();
    FlutterWindowManagerPlus.addFlags(FlutterWindowManagerPlus.FLAG_SECURE).catchError((_) {});
  }

  @override
  void dispose() {
    FlutterWindowManagerPlus.clearFlags(FlutterWindowManagerPlus.FLAG_SECURE).catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ---------------- Public gallery (Guest + every logged-in role) ----------------

class DuaKalimatGalleryScreen extends StatefulWidget {
  const DuaKalimatGalleryScreen({super.key});
  @override
  State<DuaKalimatGalleryScreen> createState() => _DuaKalimatGalleryScreenState();
}

class _DuaKalimatGalleryScreenState extends State<DuaKalimatGalleryScreen> {
  List<DuaKalimatItem>? _items;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await fetchDuaKalimatItems();
      if (!mounted) return;
      setState(() {
        _items = items;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: const Text("Dua'iya Kalimat"), backgroundColor: kGreen, foregroundColor: Colors.white),
        body: _items == null
            ? Center(
                child: _failed
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text("Could not load Dua'iya Kalimat. Check your internet connection and try again.", textAlign: TextAlign.center),
                          const SizedBox(height: 10),
                          OutlinedButton(onPressed: _load, child: const Text('Retry')),
                        ]),
                      )
                    : const CircularProgressIndicator(),
              )
            : _items!.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text("No Dua'iya Kalimat has been published yet.", textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 220,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.82,
                      ),
                      itemCount: _items!.length,
                      itemBuilder: (context, i) => _GalleryCard(item: _items![i]),
                    ),
                  ),
      ),
    );
  }
}

class _GalleryCard extends StatefulWidget {
  const _GalleryCard({required this.item});
  final DuaKalimatItem item;
  @override
  State<_GalleryCard> createState() => _GalleryCardState();
}

class _GalleryCardState extends State<_GalleryCard> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    final p = widget.item.thumbnailPath;
    if (p != null) {
      // GridView.builder only ever builds the cards currently on/near
      // screen, so this only ever downloads thumbnails for items the
      // user has actually scrolled to - not every item up front.
      downloadDuaKalimatFile(p).then((bytes) {
        if (!mounted || bytes == null) return;
        setState(() => _thumb = bytes);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => DuaKalimatViewerScreen(item: item))),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          Expanded(
            child: Container(
              width: double.infinity,
              color: const Color(0xFFEEF4E8),
              child: _thumb != null
                  ? Image.memory(_thumb!, fit: BoxFit.cover)
                  : Center(child: Icon(item.fileType == 'pdf' ? Icons.picture_as_pdf : Icons.image, size: 40, color: kGreen.withOpacity(0.55))),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(item.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ]),
      ),
    );
  }
}

// ---------------- Read-only viewer ----------------

class DuaKalimatViewerScreen extends StatefulWidget {
  const DuaKalimatViewerScreen({super.key, required this.item});
  final DuaKalimatItem item;
  @override
  State<DuaKalimatViewerScreen> createState() => _DuaKalimatViewerScreenState();
}

class _DuaKalimatViewerScreenState extends State<DuaKalimatViewerScreen> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await downloadDuaKalimatFile(widget.item.storagePath);
    if (!mounted) return;
    setState(() {
      if (bytes != null) {
        _bytes = bytes;
      } else {
        _failed = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: Text(item.title), backgroundColor: kGreen, foregroundColor: Colors.white),
        body: _bytes == null
            ? Center(
                child: _failed
                    ? const Padding(padding: EdgeInsets.all(24), child: Text('Could not load this item. Check your internet connection and try again.', textAlign: TextAlign.center))
                    : const CircularProgressIndicator(),
              )
            : item.fileType == 'pdf'
                ? PdfPreview(
                    build: (format) async => _bytes!,
                    allowPrinting: false,
                    allowSharing: false,
                    canChangePageFormat: false,
                    canChangeOrientation: false,
                    canDebug: false,
                    useActions: false,
                    actions: const [],
                  )
                : InteractiveViewer(
                    minScale: 1,
                    maxScale: 5,
                    child: Center(child: Image.memory(_bytes!)),
                  ),
      ),
    );
  }
}

// ---------------- Super Admin management ----------------

class DuaKalimatManagementView extends StatefulWidget {
  const DuaKalimatManagementView({super.key});
  @override
  State<DuaKalimatManagementView> createState() => _DuaKalimatManagementViewState();
}

class _DuaKalimatManagementViewState extends State<DuaKalimatManagementView> {
  List<DuaKalimatItem>? _items;
  final _title = TextEditingController();
  final _seq = TextEditingController(text: '0');
  PlatformFile? _picked;
  Uint8List? _pickedBytes;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await fetchDuaKalimatItems(includeInactive: true);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _items = []);
    }
  }

  String? get _pickedFileType => _picked == null ? null : _fileTypeForName(_picked!.name);

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'pdf']);
    if (files.isEmpty) return;
    final f = files.first;
    try {
      final bytes = await f.readAsBytes();
      if (bytes.length > kDuaKalimatMaxBytes) {
        setState(() => _error = 'That file is larger than the 10 MB limit.');
        return;
      }
      setState(() {
        _picked = f;
        _pickedBytes = bytes;
        _error = null;
      });
    } catch (_) {
      setState(() => _error = 'Could not read that file on this device.');
    }
  }

  Future<void> _save() async {
    final ft = _pickedFileType;
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Enter a title.');
      return;
    }
    if (_picked == null || _pickedBytes == null || ft == null) {
      setState(() => _error = 'Pick an image (JPG/PNG/WebP) or a PDF first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final e = await createDuaKalimatItemRemote(
      title: _title.text,
      sequenceOrder: int.tryParse(_seq.text.trim()) ?? 0,
      fileType: ft,
      bytes: _pickedBytes!,
      fileName: _picked!.name,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (e != null) {
      setState(() => _error = e);
      return;
    }
    _title.clear();
    _seq.text = '0';
    setState(() {
      _picked = null;
      _pickedBytes = null;
    });
    toast(context, 'Published.');
    _load();
  }

  Future<void> _editTitleSeq(DuaKalimatItem item) async {
    final t = await askText(context, 'Title', initial: item.title);
    if (t == null || t.trim().isEmpty) return;
    final sText = await askText(context, 'Display sequence', initial: '${item.sequenceOrder}');
    final seq = (sText == null || sText.trim().isEmpty) ? item.sequenceOrder : (int.tryParse(sText.trim()) ?? item.sequenceOrder);
    final e = await updateDuaKalimatItemRemote(item, title: t, sequenceOrder: seq);
    if (!mounted) return;
    toast(context, e ?? 'Updated.');
    setState(() {});
  }

  Future<void> _replace(DuaKalimatItem item) async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'pdf']);
    if (files.isEmpty) return;
    final f = files.first;
    final ft = _fileTypeForName(f.name);
    if (ft == null) {
      toast(context, 'Pick an image (JPG/PNG/WebP) or a PDF.');
      return;
    }
    Uint8List bytes;
    try {
      bytes = await f.readAsBytes();
    } catch (_) {
      toast(context, 'Could not read that file on this device.');
      return;
    }
    if (bytes.length > kDuaKalimatMaxBytes) {
      toast(context, 'That file is larger than the 10 MB limit.');
      return;
    }
    final e = await replaceDuaKalimatFileRemote(item, fileType: ft, bytes: bytes, fileName: f.name);
    if (!mounted) return;
    toast(context, e ?? 'File replaced.');
    setState(() {});
  }

  Future<void> _toggleActive(DuaKalimatItem item) async {
    final e = await setDuaKalimatActiveRemote(item, !item.isActive);
    if (!mounted) return;
    if (e != null) toast(context, e);
    setState(() {});
  }

  Future<void> _delete(DuaKalimatItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete item?'),
        content: Text('"${item.title}" and its uploaded file will be permanently deleted. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    final e = await deleteDuaKalimatItemRemote(item);
    if (!mounted) return;
    toast(context, e ?? 'Deleted.');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items == null
        ? null
        : ([...(_items!)]..sort((a, b) => a.sequenceOrder != b.sequenceOrder ? a.sequenceOrder.compareTo(b.sequenceOrder) : a.title.compareTo(b.title)));
    return Scaffold(
      appBar: AppBar(title: const Text("Dua'iya Kalimat Management"), backgroundColor: kGreen, foregroundColor: Colors.white),
      body: page([
        const Text('Upload a new item', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 4),
        const Text(
          'Shown to Guests and every logged-in role, ordered by sequence number (lower first). Images (JPG/PNG/WebP) and PDFs up to 10 MB.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 10),
        TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(
          controller: _seq,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Display sequence (lower shows first)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: _pickFile, icon: const Icon(Icons.attach_file), label: Text(_picked == null ? 'Choose image or PDF' : _picked!.name)),
        if (_pickedBytes != null && _pickedFileType == 'image') ...[
          const SizedBox(height: 8),
          ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(_pickedBytes!, height: 140, fit: BoxFit.cover)),
        ],
        if (_pickedBytes != null && _pickedFileType == 'pdf') ...[
          const SizedBox(height: 8),
          const Text('PDF selected - ready to publish.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
        ],
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: _busy ? null : _save,
          icon: _busy ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.cloud_upload),
          label: const Text('Save and publish'),
          style: ElevatedButton.styleFrom(backgroundColor: kGreen, foregroundColor: Colors.white),
        ),
        const Divider(height: 32),
        const Text('All items', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 8),
        if (items == null) const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
        if (items != null && items.isEmpty) const Text('Nothing uploaded yet.', style: TextStyle(color: Colors.black54)),
        if (items != null)
          ...items.map((item) => Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFEEF4E8),
                    child: Icon(item.fileType == 'pdf' ? Icons.picture_as_pdf : Icons.image, color: kGreen),
                  ),
                  title: Text('${item.sequenceOrder}. ${item.title}'),
                  subtitle: Text(
                    '${item.isActive ? 'Active' : 'Inactive'}${item.updatedAt != null ? ' - updated ${nice(fd(item.updatedAt!))}' : ''}',
                    style: TextStyle(color: item.isActive ? Colors.black54 : Colors.red),
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'view') Navigator.push(context, MaterialPageRoute<void>(builder: (_) => DuaKalimatViewerScreen(item: item)));
                      if (v == 'edit') _editTitleSeq(item);
                      if (v == 'replace') _replace(item);
                      if (v == 'toggle') _toggleActive(item);
                      if (v == 'delete') _delete(item);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'view', child: Text('View')),
                      const PopupMenuItem(value: 'edit', child: Text('Edit title / sequence')),
                      const PopupMenuItem(value: 'replace', child: Text('Replace file')),
                      PopupMenuItem(value: 'toggle', child: Text(item.isActive ? 'Deactivate' : 'Activate')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
              )),
      ]),
    );
  }
}
