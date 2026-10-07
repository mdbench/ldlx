import 'dart:math';
import 'package:flutter/material.dart';
import 'db_service.dart';

class AclView extends StatefulWidget {
  final UserAccount currentUser;

  const AclView({
    Key? key,
    required this.currentUser,
  }) : super(key: key);

  @override
  State<AclView> createState() => _AclViewState();
}

class _AclViewState extends State<AclView> {
  List<UserAccount> _allUsers = [];
  List<UserAccount> _filteredUsers = [];

  // Search & Filters
  final TextEditingController _searchController = TextEditingController();
  String _selectedRoleFilter = 'All';
  bool _filterRead = false;
  bool _filterWrite = false;
  bool _filterExecute = false;

  bool get isAdmin => widget.currentUser.role.toLowerCase() == 'admin';

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _searchController.addListener(_applyFilters);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    final users = await DbService().getAllUsers();
    setState(() {
      _allUsers = users;
      _applyFilters();
    });
  }

  void _applyFilters() {
    final query = _searchController.text.trim().toLowerCase();

    setState(() {
      _filteredUsers = _allUsers.where((user) {
        final matchesQuery = user.username.toLowerCase().contains(query);
        final matchesRole = _selectedRoleFilter == 'All' || user.role.toLowerCase() == _selectedRoleFilter.toLowerCase();
        final matchesRead = !_filterRead || user.canRead;
        final matchesWrite = !_filterWrite || user.canWrite;
        final matchesExec = !_filterExecute || user.canExecute;

        return matchesQuery && matchesRole && matchesRead && matchesWrite && matchesExec;
      }).toList();
    });
  }

  String _generateRandomBase32Secret() {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final random = Random.secure();
    return List.generate(16, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }

  void _openUserDialog({UserAccount? userToEdit}) {
    if (!isAdmin) return;

    final isEditing = userToEdit != null;
    final isRootAdmin = isEditing && userToEdit.username.toLowerCase() == 'admin';

    final usernameController = TextEditingController(text: userToEdit?.username ?? '');
    final passwordController = TextEditingController(text: userToEdit?.password ?? '');
    final totpSecretController = TextEditingController(text: userToEdit?.totpSecret ?? '');
    
    String selectedRole = userToEdit?.role ?? 'User';
    bool canRead = userToEdit?.canRead ?? true;
    bool canWrite = userToEdit?.canWrite ?? false;
    bool canExecute = userToEdit?.canExecute ?? false;
    bool isTotpEnabled = userToEdit?.isTotpEnabled ?? false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final colorScheme = Theme.of(context).colorScheme;
            final targetUsername = usernameController.text.trim().isEmpty ? 'User' : usernameController.text.trim();
            final qrData = 'otpauth://totp/LDLx:$targetUsername?secret=${totpSecretController.text.trim()}&issuer=LDLxSecurity';

            return AlertDialog(
              title: Text(isEditing ? 'Modify User: ${userToEdit.username}' : 'Create New User'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: usernameController,
                        enabled: !isRootAdmin, // Admin username cannot be altered
                        onChanged: (_) => setModalState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: selectedRole,
                        decoration: const InputDecoration(
                          labelText: 'Role',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'Admin', child: Text('Admin')),
                          DropdownMenuItem(value: 'Analyst', child: Text('Analyst')),
                          DropdownMenuItem(value: 'User', child: Text('User')),
                        ],
                        onChanged: isRootAdmin
                            ? null
                            : (val) {
                                if (val != null) {
                                  setModalState(() {
                                    selectedRole = val;
                                    if (selectedRole == 'Admin') {
                                      canRead = true;
                                      canWrite = true;
                                      canExecute = true;
                                    } else if (selectedRole == 'Analyst') {
                                      canRead = true;
                                      canWrite = true;
                                      canExecute = false;
                                    } else {
                                      canRead = true;
                                      canWrite = false;
                                      canExecute = false;
                                    }
                                  });
                                }
                              },
                      ),
                      const SizedBox(height: 20),
                      Text('Two-Factor Authentication (TOTP)', style: Theme.of(context).textTheme.titleSmall),
                      SwitchListTile(
                        title: const Text('Enable TOTP 2FA'),
                        subtitle: const Text('Require 6-digit authenticator code on login'),
                        value: isTotpEnabled,
                        onChanged: (val) {
                          setModalState(() {
                            isTotpEnabled = val;
                            if (val) {
                              // Automatically generate a new random secret key when toggled on
                              totpSecretController.text = _generateRandomBase32Secret();
                            } else {
                              totpSecretController.clear();
                            }
                          });
                        },
                      ),
                      if (isTotpEnabled && totpSecretController.text.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Center(
                          child: Column(
                            children: [
                              SizedBox(
                                width: 160,
                                height: 160,
                                child: Image.network(
                                  'https://api.qrserver.com/v1/create-qr-code/?size=160x160&data=${Uri.encodeComponent(qrData)}',
                                  errorBuilder: (context, error, stackTrace) => const Padding(
                                    padding: EdgeInsets.all(24.0),
                                    child: Text('Unable to load QR Code', textAlign: TextAlign.center),
                                  ),
                                  loadingBuilder: (context, child, loadingProgress) {
                                    if (loadingProgress == null) return child;
                                    return const Center(child: CircularProgressIndicator());
                                  },
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text('Scan with Authenticator App', style: TextStyle(fontSize: 12, color: colorScheme.secondary)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: totpSecretController,
                          onChanged: (_) => setModalState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'TOTP Secret Key (Base32)',
                            helperText: 'Auto-generated or custom Base32 key',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text('Permissions Matrix', style: Theme.of(context).textTheme.titleSmall),
                      CheckboxListTile(
                        title: const Text('Read Permission'),
                        value: canRead,
                        onChanged: isRootAdmin ? null : (val) => setModalState(() => canRead = val ?? false),
                      ),
                      CheckboxListTile(
                        title: const Text('Write Permission'),
                        value: canWrite,
                        onChanged: isRootAdmin ? null : (val) => setModalState(() => canWrite = val ?? false),
                      ),
                      CheckboxListTile(
                        title: const Text('Execute Permission'),
                        value: canExecute,
                        onChanged: isRootAdmin ? null : (val) => setModalState(() => canExecute = val ?? false),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final username = usernameController.text.trim();
                    final password = passwordController.text.trim();
                    final totpSecret = totpSecretController.text.trim();

                    if (username.isEmpty || password.isEmpty) return;
                    if (isTotpEnabled && totpSecret.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please provide a TOTP secret key if 2FA is enabled.')),
                      );
                      return;
                    }

                    final updatedUser = UserAccount(
                      username: isRootAdmin ? 'admin' : username,
                      password: password,
                      role: isRootAdmin ? 'Admin' : selectedRole,
                      canRead: isRootAdmin ? true : canRead,
                      canWrite: isRootAdmin ? true : canWrite,
                      canExecute: isRootAdmin ? true : canExecute,
                      isTotpEnabled: isRootAdmin ? (userToEdit?.isTotpEnabled ?? false) : isTotpEnabled,
                      totpSecret: isRootAdmin ? (userToEdit?.totpSecret ?? '') : totpSecret,
                    );

                    await DbService().saveUser(updatedUser);
                    await DbService().logActivity(
                      username: widget.currentUser.username,
                      action: isEditing ? 'User Modified' : 'User Created',
                      details: 'Modified details for target user "${updatedUser.username}"',
                    );

                    if (mounted) {
                      Navigator.pop(context);
                      _loadUsers();
                    }
                  },
                  child: Text(isEditing ? 'Save Changes' : 'Create User'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _deleteUser(UserAccount user) {
    if (!isAdmin || user.username.toLowerCase() == 'admin') return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Deletion'),
        content: Text('Are you sure you want to delete user "${user.username}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () async {
              await DbService().deleteUser(user.username);
              await DbService().logActivity(
                username: widget.currentUser.username,
                action: 'User Deleted',
                details: 'Deleted user account "${user.username}"',
              );

              if (mounted) {
                Navigator.pop(context);
                _loadUsers();
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Access Control List (ACL)', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Logged in as: ${widget.currentUser.username} (${widget.currentUser.role})',
                    style: TextStyle(color: colorScheme.secondary),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: isAdmin ? () => _openUserDialog() : null,
                icon: const Icon(Icons.person_add),
                label: const Text('Create User'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Search and Filter Bar
          Card(
            color: colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          decoration: const InputDecoration(
                            hintText: 'Search users by username...',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 160,
                        child: DropdownButtonFormField<String>(
                          value: _selectedRoleFilter,
                          decoration: const InputDecoration(
                            labelText: 'Role Filter',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(value: 'All', child: Text('All Roles')),
                            DropdownMenuItem(value: 'Admin', child: Text('Admin')),
                            DropdownMenuItem(value: 'Analyst', child: Text('Analyst')),
                            DropdownMenuItem(value: 'User', child: Text('User')),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              _selectedRoleFilter = val;
                              _applyFilters();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Filter by Permission: ', style: TextStyle(fontWeight: FontWeight.bold)),
                      FilterChip(
                        label: const Text('Read'),
                        selected: _filterRead,
                        onSelected: (val) {
                          setState(() => _filterRead = val);
                          _applyFilters();
                        },
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Write'),
                        selected: _filterWrite,
                        onSelected: (val) {
                          setState(() => _filterWrite = val);
                          _applyFilters();
                        },
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Execute'),
                        selected: _filterExecute,
                        onSelected: (val) {
                          setState(() => _filterExecute = val);
                          _applyFilters();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Expanded(
            child: Card(
              color: colorScheme.surface,
              child: ListView.separated(
                itemCount: _filteredUsers.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final user = _filteredUsers[index];
                  final isRootAdmin = user.username.toLowerCase() == 'admin';

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    leading: CircleAvatar(
                      backgroundColor: colorScheme.primary.withOpacity(0.2),
                      child: Icon(
                        user.role == 'Admin'
                            ? Icons.admin_panel_settings
                            : user.role == 'Analyst'
                                ? Icons.analytics
                                : Icons.person,
                        color: colorScheme.secondary,
                      ),
                    ),
                    title: Row(
                      children: [
                        Text(
                          user.username,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            user.role,
                            style: TextStyle(fontSize: 12, color: colorScheme.secondary),
                          ),
                        ),
                        if (user.isTotpEnabled) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'TOTP 2FA',
                              style: TextStyle(fontSize: 10, color: Colors.greenAccent),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          _buildPermissionChip('Read', user.canRead, Colors.blue),
                          _buildPermissionChip('Write', user.canWrite, Colors.orange),
                          _buildPermissionChip('Execute', user.canExecute, Colors.purple),
                        ],
                      ),
                    ),
                    trailing: isAdmin
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: isRootAdmin ? 'Modify Admin Password / TOTP' : 'Modify User',
                                onPressed: () => _openUserDialog(userToEdit: user),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.delete_outline,
                                  color: isRootAdmin ? Colors.grey : Colors.redAccent,
                                ),
                                tooltip: isRootAdmin ? 'Admin Account Cannot Be Deleted' : 'Delete User',
                                onPressed: isRootAdmin ? null : () => _deleteUser(user),
                              ),
                            ],
                          )
                        : null,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionChip(String label, bool enabled, Color color) {
    return Chip(
      avatar: Icon(
        enabled ? Icons.check_circle : Icons.cancel,
        size: 14,
        color: enabled ? color : Colors.grey,
      ),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: enabled ? color : Colors.grey,
        ),
      ),
      backgroundColor: enabled ? color.withOpacity(0.1) : Colors.transparent,
      side: BorderSide(color: enabled ? color.withOpacity(0.4) : Colors.grey.withOpacity(0.3)),
      visualDensity: VisualDensity.compact,
    );
  }
}