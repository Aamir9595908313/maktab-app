// ============================================================
// User Management - ONE screen for Super Admin to find, create, edit,
// activate/deactivate people. Replaces the separate Maktab Admins,
// Committee Members and Users and Roles tiles.
//
// It adds no new backend rules: every write goes through the same calls
// and tables as before (setUserRoleRemote, user_profiles.is_active,
// grant/revokeExtraPermissionRemote, createRoleRemote) and is still
// guarded by the database's row-level security (Super Admin only).
// ============================================================
import 'package:flutter/material.dart';
import 'state.dart';
import 'main.dart';

class UmUser {
  final String? id; // null = invited, has not logged in yet
  final String phone10;
  String name;
  String dbRole;
  String customRole;
  bool active;
  List<String> branches;
  final bool pending;
  UmUser({this.id, required this.phone10, required this.name, required this.dbRole, this.customRole = '', this.active = true, this.branches = const [], this.pending = false});

  String get roleLabel {
    switch (dbRole) {
      case 'super_admin':
        return 'Super Admin';
      case 'madrasa_admin':
        return 'Maktab Admin';
      case 'teacher':
        return 'Teacher';
      case 'committee':
        return 'Committee Member';
      case 'parent':
        return 'Parent';
      case 'student':
        return 'Student';
      case 'custom':
        return customRole.isEmpty ? 'Custom role' : customRole;
      default:
        return dbRole;
    }
  }

  String get branchLabel => dbRole == 'super_admin' ? 'All Makatib' : (branches.isEmpty ? '-' : branches.join(', '));
}

const List<String> _kBuiltIn = ['Super Admin', 'Maktab Admin', 'Teacher', 'Committee Member'];
const List<String> _kScreens = ['Students', 'Fees', 'Reports', 'Leave', 'Sadqa Peti', 'Monthly Members'];

String _dbRoleFor(String label) {
  switch (label) {
    case 'Super Admin':
      return 'super_admin';
    case 'Maktab Admin':
      return 'madrasa_admin';
    case 'Teacher':
      return 'teacher';
    case 'Committee Member':
      return 'committee';
    default:
      return 'custom';
  }
}

Future<List<UmUser>> loadAllUsers() async {
  final roleRows = await sb.from('roles').select('id, name');
  final roleName = {for (final r in (roleRows as List)) r['id'] as String: (r['name'] as String?) ?? ''};
  final scopeRows = await sb.from('user_madrasa_scope').select('user_id, madrasas(name)');
  final scope = <String, List<String>>{};
  for (final r in (scopeRows as List)) {
    final n = (r['madrasas'] as Map?)?['name'] as String?;
    if (n != null && n.isNotEmpty) scope.putIfAbsent(r['user_id'] as String, () => []).add(n);
  }
  final out = <UmUser>[];
  final profs = await sb.from('user_profiles').select('id, phone, full_name, base_role, custom_role_id, is_active');
  for (final r in (profs as List)) {
    out.add(UmUser(
      id: r['id'] as String,
      phone10: digits((r['phone'] as String?) ?? ''),
      name: (r['full_name'] as String?) ?? '',
      dbRole: (r['base_role'] as String?) ?? '',
      customRole: roleName[r['custom_role_id']] ?? '',
      active: (r['is_active'] as bool?) ?? true,
      branches: scope[r['id'] as String] ?? [],
    ));
  }
  final inv = await sb.from('pending_role_invites').select();
  final have = {for (final u in out) u.phone10};
  for (final r in (inv as List)) {
    final p = digits((r['phone'] as String?) ?? '');
    if (have.contains(p)) continue;
    out.add(UmUser(
      phone10: p,
      name: (r['full_name'] as String?) ?? '',
      dbRole: (r['base_role'] as String?) ?? '',
      customRole: roleName[r['custom_role_id']] ?? '',
      branches: List<String>.from((r['madrasa_names'] as List?) ?? []),
      pending: true,
    ));
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});
  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  List<UmUser> users = [];
  bool loading = true;
  String? error;
  final search = TextEditingController();
  String roleFilter = 'All staff';
  String branchFilter = 'All Makatib';
  String statusFilter = 'All';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final l = await loadAllUsers();
      if (!mounted) return;
      setState(() {
        users = l;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Could not load users. Check your internet connection and try again.';
      });
    }
  }

  List<String> get _roleOptions => ['All staff', ..._kBuiltIn, ...st.customRoles.keys, 'Parent', 'Student'];

  List<UmUser> get _filtered {
    final q = search.text.trim().toLowerCase();
    final qd = digits(search.text);
    return users.where((u) {
      if (roleFilter == 'All staff') {
        if (u.dbRole == 'parent' || u.dbRole == 'student') return false;
      } else if (u.roleLabel != roleFilter) {
        return false;
      }
      if (branchFilter != 'All Makatib' && u.dbRole != 'super_admin' && !u.branches.contains(branchFilter)) return false;
      if (statusFilter == 'Active' && (u.pending || !u.active)) return false;
      if (statusFilter == 'Inactive' && (u.pending || u.active)) return false;
      if (statusFilter == 'Invited' && !u.pending) return false;
      if (q.isEmpty) return true;
      return u.name.toLowerCase().contains(q) || (qd.isNotEmpty && u.phone10.contains(qd));
    }).toList();
  }

  bool _isMe(UmUser u) => u.id != null && u.id == sb.auth.currentUser?.id;

  Future<void> _toggleActive(UmUser u, bool v) async {
    if (u.id == null || _isMe(u)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(v ? 'Activate ${u.name}?' : 'Deactivate ${u.name}?'),
        content: Text(v ? 'They will be able to log in again.' : 'They will not be able to use the app until you activate them again.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes'))],
      ),
    );
    if (ok != true) return;
    setState(() => busy = true);
    String? e;
    try {
      await sb.from('user_profiles').update({'is_active': v}).eq('id', u.id!);
      u.active = v;
    } catch (_) {
      e = 'Could not save. Check your internet connection and try again.';
    }
    if (!mounted) return;
    setState(() => busy = false);
    toast(context, e ?? (v ? 'Activated' : 'Deactivated'));
  }

  Future<void> _edit(UmUser? u) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _UserForm(user: u, isMe: u != null && _isMe(u)),
      ),
    );
    if (changed == true) await _load();
  }

  Future<void> _cancelInvite(UmUser u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel invite?'),
        content: Text('${u.name} has not logged in yet. Remove the invite for +91 ${u.phone10}?'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')), TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, remove'))],
      ),
    );
    if (ok != true) return;
    try {
      await sb.from('pending_role_invites').delete().eq('phone', '91${u.phone10}');
      if (!mounted) return;
      toast(context, 'Invite removed');
      await _load();
    } catch (_) {
      if (mounted) toast(context, 'Could not remove. Check your internet connection and try again.');
    }
  }

  Future<void> _manageRoles() async {
    await showDialog<void>(context: context, builder: (ctx) => const _RoleDialog());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      appBar: AppBar(title: const Text('User Management'), actions: [
        IconButton(tooltip: 'Custom roles', icon: const Icon(Icons.badge_outlined), onPressed: _manageRoles),
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: loading ? null : _load),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(null), icon: const Icon(Icons.person_add), label: const Text('Create User')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search by name or mobile number',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: search.text.isEmpty ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(search.clear)),
              isDense: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(spacing: 8, runSpacing: 0, children: [
            _dd('Role', roleFilter, _roleOptions, (v) => setState(() => roleFilter = v)),
            _dd('Maktab', branchFilter, ['All Makatib', ...st.activeMadrasaNames], (v) => setState(() => branchFilter = v)),
            _dd('Status', statusFilter, const ['All', 'Active', 'Inactive', 'Invited'], (v) => setState(() => statusFilter = v)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
          child: Align(alignment: Alignment.centerLeft, child: Text('${list.length} user${list.length == 1 ? '' : 's'}', style: const TextStyle(color: Colors.black54, fontSize: 12))),
        ),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(error!, style: const TextStyle(color: Colors.red)), TextButton(onPressed: _load, child: const Text('Retry'))]))
                  : list.isEmpty
                      ? const Center(child: Text('No users match.', style: TextStyle(color: Colors.black54)))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 90),
                            itemCount: list.length,
                            itemBuilder: (c, i) => _card(list[i]),
                          ),
                        ),
        ),
      ]),
    );
  }

  Widget _dd(String label, String value, List<String> opts, ValueChanged<String> on) => SizedBox(
        width: 150,
        child: DropdownButtonFormField<String>(
          value: opts.contains(value) ? value : opts.first,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
          items: [for (final o in opts) DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))],
          onChanged: (v) => v == null ? null : on(v),
        ),
      );

  Widget _card(UmUser u) {
    final status = u.pending ? 'Invited' : (u.active ? 'Active' : 'Inactive');
    final color = u.pending ? Colors.orange[800] : (u.active ? Colors.green[800] : Colors.red);
    return Card(
      child: InkWell(
        onTap: () => _edit(u),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(u.name.isEmpty ? '(no name)' : u.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('+91 ${u.phone10}', style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
                const SizedBox(height: 2),
                Text('${u.roleLabel}  -  ${u.branchLabel}', style: const TextStyle(fontSize: 12.5)),
                Text(status, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
              ]),
            ),
            if (u.pending)
              IconButton(tooltip: 'Cancel invite', icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => _cancelInvite(u))
            else
              Switch(value: u.active, onChanged: busy || _isMe(u) ? null : (v) => _toggleActive(u, v)),
          ]),
        ),
      ),
    );
  }
}

// ---------------- Create / edit form ----------------
class _UserForm extends StatefulWidget {
  const _UserForm({this.user, required this.isMe});
  final UmUser? user;
  final bool isMe;
  @override
  State<_UserForm> createState() => _UserFormState();
}

class _UserFormState extends State<_UserForm> {
  late final TextEditingController name = TextEditingController(text: widget.user?.name ?? '');
  late final TextEditingController phone = TextEditingController(text: widget.user?.phone10 ?? '');
  String? role;
  final Set<String> branches = {};
  bool active = true;
  bool busy = false;
  String? err;
  Set<String> extra = {};
  bool extraLoaded = false;

  bool get isEdit => widget.user != null;
  bool get hasAccount => widget.user?.id != null;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    if (u != null) {
      role = u.dbRole == 'custom' ? u.customRole : (u.dbRole == 'parent' || u.dbRole == 'student' ? null : u.roleLabel);
      branches.addAll(u.branches);
      active = u.active;
      if (u.id != null) _loadExtra(u.id!);
    }
  }

  Future<void> _loadExtra(String uid) async {
    try {
      final rows = await sb.from('user_extra_permissions').select('screen_key').eq('user_id', uid);
      if (!mounted) return;
      setState(() {
        extra = {for (final r in (rows as List)) (r['screen_key'] as String?) ?? ''}..removeWhere((x) => x.isEmpty);
        extraLoaded = true;
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    if (role == null) {
      setState(() => err = 'Choose a role');
      return;
    }
    setState(() {
      busy = true;
      err = null;
    });
    final dbRole = _dbRoleFor(role!);
    final e = await setUserRoleRemote(
      phone: phone.text,
      name: name.text,
      dbRole: dbRole,
      customRoleName: dbRole == 'custom' ? role : null,
      branches: dbRole == 'super_admin' ? const [] : branches.toList(),
    );
    if (e == null && hasAccount && !widget.isMe && active != widget.user!.active) {
      try {
        await sb.from('user_profiles').update({'is_active': active}).eq('id', widget.user!.id!);
      } catch (_) {
        if (!mounted) return;
        setState(() {
          busy = false;
          err = 'Role saved, but the status could not be changed. Try again.';
        });
        return;
      }
    }
    if (!mounted) return;
    if (e != null) {
      setState(() {
        busy = false;
        err = e;
      });
      return;
    }
    toast(context, isEdit ? 'User updated' : 'User created - they are active from their first OTP login.');
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final roles = [..._kBuiltIn, ...st.customRoles.keys];
    final showBranches = role != null && role != 'Super Admin';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(isEdit ? 'Edit user' : 'Create user', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: kGreen)),
        const SizedBox(height: 10),
        TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Full name')),
        const SizedBox(height: 10),
        TextField(
          controller: phone,
          enabled: !isEdit,
          keyboardType: TextInputType.number,
          maxLength: 10,
          decoration: const InputDecoration(labelText: 'Mobile number (10 digits)', prefixText: '+91 ', counterText: ''),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: roles.contains(role) ? role : null,
          decoration: InputDecoration(labelText: 'Role', helperText: widget.isMe ? 'You cannot change your own role.' : null),
          items: [for (final r in roles) DropdownMenuItem(value: r, child: Text(r))],
          onChanged: widget.isMe ? null : (v) => setState(() => role = v),
        ),
        if (showBranches) ...[
          const SizedBox(height: 10),
          const Text('Maktab / Branch', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
          Wrap(spacing: 4, children: [
            FilterChip(
              label: const Text('All Makatib'),
              selected: st.activeMadrasaNames.isNotEmpty && branches.length >= st.activeMadrasaNames.length,
              onSelected: (v) => setState(() {
                branches.clear();
                if (v) branches.addAll(st.activeMadrasaNames);
              }),
            ),
            for (final m in st.activeMadrasaNames)
              FilterChip(label: Text(m), selected: branches.contains(m), onSelected: (v) => setState(() => v ? branches.add(m) : branches.remove(m))),
          ]),
        ],
        if (role == 'Teacher')
          const Padding(padding: EdgeInsets.only(top: 6), child: Text('Class assignments for a teacher are set in Master Data > Teachers.', style: TextStyle(fontSize: 12, color: Colors.black54))),
        const SizedBox(height: 8),
        if (hasAccount)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(active ? 'Active' : 'Inactive'),
            subtitle: widget.isMe ? const Text('You cannot deactivate your own account.') : null,
            value: active,
            onChanged: widget.isMe ? null : (v) => setState(() => active = v),
          )
        else
          const Text('Status: becomes Active when this person first logs in with their mobile number and OTP.', style: TextStyle(fontSize: 12, color: Colors.black54)),
        if (hasAccount && extraLoaded) ...[
          const Divider(),
          const Text('Extra screen access (on top of the role - saves immediately)', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
          Wrap(spacing: 4, children: [
            for (final s in [..._kScreens, ...kResultPerms])
              FilterChip(
                label: Text(s),
                selected: extra.contains(s),
                onSelected: busy
                    ? null
                    : (v) async {
                        final uid = widget.user!.id!;
                        setState(() => busy = true);
                        final e = v ? await grantExtraPermissionRemote(uid, s) : await revokeExtraPermissionRemote(uid, s);
                        if (!mounted) return;
                        setState(() {
                          busy = false;
                          if (e == null) {
                            v ? extra.add(s) : extra.remove(s);
                          } else {
                            err = e;
                          }
                        });
                      },
              ),
          ]),
        ],
        if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.red))),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel'))),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton(
              onPressed: busy ? null : _save,
              child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(isEdit ? 'Save changes' : 'Create user'),
            ),
          ),
        ]),
      ]),
    );
  }
}

// ---------------- Custom roles (what a custom role may open) ----------------
class _RoleDialog extends StatefulWidget {
  const _RoleDialog();
  @override
  State<_RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends State<_RoleDialog> {
  final name = TextEditingController();
  final Set<String> perms = {};
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Custom roles'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (st.customRoles.isEmpty) const Text('No custom roles yet.', style: TextStyle(color: Colors.black54)),
          for (final e in st.customRoles.entries) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('${e.key}: ${e.value.join(', ')}', style: const TextStyle(fontSize: 12.5))),
          const Divider(),
          const Text('New role', style: TextStyle(fontWeight: FontWeight.bold)),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Role name (e.g. Accountant)')),
          const SizedBox(height: 6),
          Wrap(spacing: 4, children: [
            for (final s in [..._kScreens, ...kResultPerms]) FilterChip(label: Text(s), selected: perms.contains(s), onSelected: (v) => setState(() => v ? perms.add(s) : perms.remove(s))),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        TextButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  final e = await createRoleRemote(name.text, perms);
                  if (!mounted) return;
                  setState(() => busy = false);
                  toast(context, e ?? 'Role saved');
                  if (e == null) {
                    name.clear();
                    setState(perms.clear);
                  }
                },
          child: const Text('Save role'),
        ),
      ],
    );
  }
}
