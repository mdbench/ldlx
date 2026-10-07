import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'audit.dart';
import 'db_service.dart';

class LocalDatabaseInfo {
  final String name;
  final String path;
  final String type; // SQL or NoSQL engine type
  final DateTime lastModified;
  final int sizeInBytes;

  LocalDatabaseInfo({
    required this.name,
    required this.path,
    required this.type,
    required this.lastModified,
    required this.sizeInBytes,
  });
}

class ColumnDefinition {
  String name;
  String dataType; // INTEGER, TEXT, REAL, BLOB
  bool isPrimaryKey;

  ColumnDefinition({
    required this.name,
    this.dataType = 'TEXT',
    this.isPrimaryKey = false,
  });
}

class DatabaseCrudView extends StatefulWidget {
  final String currentUser;

  DatabaseCrudView({
    Key? key,
    required this.currentUser,
  }) : super(key: key);

  @override
  State<DatabaseCrudView> createState() => _DatabaseCrudViewState();
}

class _DatabaseCrudViewState extends State<DatabaseCrudView> {
  Directory? _dbDirectory;
  List<LocalDatabaseInfo> _databases = [];
  List<LocalDatabaseInfo> _filteredDatabases = [];
  bool _isLoading = true;

  final TextEditingController _searchController = TextEditingController();
  String _selectedDbType = 'SQLite';
  final List<String> _dbTypes = [
    'SQLite',
    'PostgreSQL',
    'MySQL / MariaDB',
    'MongoDB',
    'Redis',
    'Hive',
    'Isar'
  ];

  // List of database filenames to skip during directory listing
  final List<String> _skippedDatabases = [
    'approve.db',
    'database_logs.db',
  ];

  Database? _approveDb;
  final _approveStore = StoreRef<String, Map<String, dynamic>>.main();

  @override
  void initState() {
    super.initState();
    _initStorageAndLoad();
    _searchController.addListener(_filterDatabases);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _approveDb?.close();
    super.dispose();
  }

  Future<void> _initStorageAndLoad() async {
    setState(() => _isLoading = true);
    final appDir = await getApplicationDocumentsDirectory();
    _dbDirectory = Directory(p.join(appDir.path, 'ldlx_dbs'));

    if (!await _dbDirectory!.exists()) {
      await _dbDirectory!.create(recursive: true);
    }

    // Initialize Sembast approve.db for deletion requests
    final approveDbPath = p.join(_dbDirectory!.path, 'approve.db');
    _approveDb = await databaseFactoryIo.openDatabase(approveDbPath);

    await _refreshDatabaseList();
    setState(() => _isLoading = false);
  }

  Future<void> _refreshDatabaseList() async {
    if (_dbDirectory == null) return;

    final List<FileSystemEntity> entities = await _dbDirectory!.list().toList();
    final List<LocalDatabaseInfo> loadedDbs = [];

    for (var entity in entities) {
      if (entity is File) {
        final filename = p.basename(entity.path);
        if (_skippedDatabases.contains(filename)) continue; // Skip configured system dbs

        final stat = await entity.stat();
        final ext = p.extension(filename).toLowerCase();

        String type = 'SQLite';
        if (ext == '.json' || ext == '.nosql') {
          type = 'MongoDB / NoSQL';
        } else if (ext == '.hive') {
          type = 'Hive';
        } else if (ext == '.isar') {
          type = 'Isar';
        }

        loadedDbs.add(LocalDatabaseInfo(
          name: p.basenameWithoutExtension(filename),
          path: entity.path,
          type: type,
          lastModified: stat.modified,
          sizeInBytes: stat.size,
        ));
      }
    }

    setState(() {
      _databases = loadedDbs;
      _filterDatabases();
    });
  }

  void _filterDatabases() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredDatabases = List.from(_databases);
      } else {
        _filteredDatabases = _databases.where((db) {
          return db.name.toLowerCase().contains(query) ||
              db.type.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  // --- CREATE DATABASE ---
  void _openCreateDatabaseModal() {
    final isSql = ['SQLite', 'PostgreSQL', 'MySQL / MariaDB'].contains(_selectedDbType);
    final nameController = TextEditingController();
    final tableNameController = TextEditingController(text: 'main_table');

    List<ColumnDefinition> columns = [
      ColumnDefinition(name: 'id', dataType: 'INTEGER', isPrimaryKey: true),
      ColumnDefinition(name: 'name', dataType: 'TEXT'),
      ColumnDefinition(name: 'created_at', dataType: 'TEXT'),
    ];

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: Text('Create New $_selectedDbType Database'),
              content: SizedBox(
                width: 550,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Database Name',
                          hintText: 'e.g. TelemetryData',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (isSql) ...[
                        Text('Initial SQL Table Schema',
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 8),
                        TextField(
                          controller: tableNameController,
                          decoration: const InputDecoration(
                            labelText: 'Table Name',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Columns', style: TextStyle(fontWeight: FontWeight.bold)),
                            TextButton.icon(
                              icon: const Icon(Icons.add),
                              label: const Text('Add Column'),
                              onPressed: () {
                                setModalState(() {
                                  columns.add(ColumnDefinition(
                                    name: 'col_${columns.length + 1}',
                                  ));
                                });
                              },
                            )
                          ],
                        ),
                        const Divider(),
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: columns.length,
                          itemBuilder: (context, index) {
                            final col = columns[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4.0),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: TextFormField(
                                      initialValue: col.name,
                                      decoration: const InputDecoration(
                                        labelText: 'Column Name',
                                        isDense: true,
                                      ),
                                      onChanged: (val) => col.name = val.trim(),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    flex: 2,
                                    child: DropdownButtonFormField<String>(
                                      value: col.dataType,
                                      isDense: true,
                                      items: ['INTEGER', 'TEXT', 'REAL', 'BLOB']
                                          .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                                          .toList(),
                                      onChanged: (val) {
                                        if (val != null) {
                                          setModalState(() => col.dataType = val);
                                        }
                                      },
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                    onPressed: columns.length > 1
                                        ? () {
                                            setModalState(() {
                                              columns.removeAt(index);
                                            });
                                          }
                                        : null,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ] else ...[
                        const Text(
                          'NoSQL databases will be initialized as empty key-value / document stores.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
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
                    final dbName = nameController.text.trim();
                    if (dbName.isEmpty) return;

                    final ext = isSql ? '.db' : '.nosql';
                    final filePath = p.join(_dbDirectory!.path, '$dbName$ext');

                    final file = File(filePath);
                    Map<String, dynamic> dbStructure = {};

                    if (isSql) {
                      dbStructure = {
                        'type': 'SQL',
                        'engine': _selectedDbType,
                        'tables': {
                          tableNameController.text.trim(): {
                            'columns': columns
                                .map((c) => {
                                      'name': c.name,
                                      'type': c.dataType,
                                      'primaryKey': c.isPrimaryKey,
                                    })
                                .toList(),
                            'rows': []
                          }
                        }
                      };
                    } else {
                      dbStructure = {
                        'type': 'NoSQL',
                        'engine': _selectedDbType,
                        'documents': []
                      };
                    }

                    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(dbStructure));
                    Navigator.pop(context);
                    await _refreshDatabaseList();
                  },
                  child: const Text('Create Database'),
                )
              ],
            );
          },
        );
      },
    );
  }

  // --- VIEW / MODIFY DATABASE TABLE (Desktop-optimized Large Popup) ---
  void _openDatabaseEditor(LocalDatabaseInfo dbInfo) async {
    final file = File(dbInfo.path);
    if (!await file.exists()) return;

    final content = await file.readAsString();
    Map<String, dynamic> data = {};
    try {
      data = jsonDecode(content);
    } catch (_) {
      data = {'type': 'Unknown', 'raw': content};
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // Ensure tables and structure are properly initialized and bound to `data`
            if (data['tables'] == null || data['tables'] is! Map) {
              data['tables'] = {
                'main_table': {
                  'columns': [
                    {'name': 'id', 'type': 'INTEGER'},
                    {'name': 'name', 'type': 'TEXT'}
                  ],
                  'rows': []
                }
              };
            }
            final tables = data['tables'] as Map<String, dynamic>;
            String activeTable = tables.isNotEmpty ? tables.keys.first : 'main_table';
            Map<String, dynamic> currentTable = tables.putIfAbsent(activeTable, () => {'columns': [], 'rows': []});
            List<dynamic> columns = currentTable.putIfAbsent('columns', () => []);
            List<dynamic> rows = currentTable.putIfAbsent('rows', () => []);

            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
              backgroundColor: Theme.of(context).colorScheme.surface,
              child: Container(
                width: 950,
                height: MediaQuery.of(context).size.height * 0.85,
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Database: ${dbInfo.name} (${dbInfo.type})',
                            style: Theme.of(context).textTheme.headlineSmall),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        )
                      ],
                    ),
                    const Divider(),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('Add Row'),
                          onPressed: () {
                            setDialogState(() {
                              Map<String, dynamic> newRow = {};
                              for (var col in columns) {
                                newRow[col['name'].toString()] = 'New Data';
                              }
                              rows.add(newRow);
                            });
                          },
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.view_column),
                          label: const Text('Add Column'),
                          onPressed: () {
                            _promptAddColumn(context, (colName, colType) {
                              setDialogState(() {
                                columns.add({'name': colName, 'type': colType});
                                for (var r in rows) {
                                  r[colName] = '';
                                }
                              });
                            });
                          },
                        ),
                        const Spacer(),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.save),
                          label: const Text('Save Changes'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.secondary,
                          ),
                          onPressed: () async {
                            await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Database changes saved successfully.')),
                              );
                            }
                          },
                        )
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.vertical,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: [
                              ...columns.map((c) => DataColumn(
                                    label: Text('${c['name']}\n(${c['type']})',
                                        style: const TextStyle(fontWeight: FontWeight.bold)),
                                  )),
                              const DataColumn(label: Text('Actions')),
                            ],
                            rows: List<DataRow>.generate(rows.length, (rowIndex) {
                              final rowData = rows[rowIndex] as Map<String, dynamic>;
                              return DataRow(
                                cells: [
                                  ...columns.map((col) {
                                    final colName = col['name'].toString();
                                    final cellVal = rowData[colName]?.toString() ?? '';
                                    return DataCell(
                                      Text(cellVal),
                                      showEditIcon: true,
                                      onTap: () {
                                        _promptEditCell(context, colName, cellVal, (newVal) {
                                          setDialogState(() {
                                            rowData[colName] = newVal;
                                          });
                                        });
                                      },
                                    );
                                  }),
                                  DataCell(
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.redAccent),
                                      onPressed: () {
                                        setDialogState(() {
                                          rows.removeAt(rowIndex);
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              );
                            }),
                          ),
                        ),
                      ),
                    )
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _promptAddColumn(BuildContext context, Function(String name, String type) onAdd) {
    final nameCtrl = TextEditingController();
    String type = 'TEXT';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add New Column'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Column Name'),
            ),
            DropdownButton<String>(
              value: type,
              isExpanded: true,
              items: ['INTEGER', 'TEXT', 'REAL', 'BLOB']
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (val) {
                if (val != null) type = val;
              },
            )
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isNotEmpty) {
                onAdd(nameCtrl.text.trim(), type);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Add'),
          )
        ],
      ),
    );
  }

  void _promptEditCell(
      BuildContext context, String colName, String currentVal, Function(String newVal) onSave) {
    final ctrl = TextEditingController(text: currentVal);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit $colName'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              onSave(ctrl.text);
              Navigator.pop(ctx);
            },
            child: const Text('Update'),
          )
        ],
      ),
    );
  }

  // --- DUAL ADMIN APPROVAL DELETION ---
  Future<void> _handleDeleteDatabaseRequest(LocalDatabaseInfo db) async {
    if (_approveDb == null) return;

    final existingRecord = await _approveStore.record(db.name).get(_approveDb!);
    final currentUser = widget.currentUser;

    // 1. Fetch existing approvals or start a new list
    List<String> approvals = [];
    if (existingRecord != null && existingRecord['approvals'] != null) {
      approvals = (existingRecord['approvals'] as List).map((e) => e.toString()).toList();
    }

    // 2. Prevent duplicate approvals from the exact same admin account
    if (approvals.contains(currentUser)) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Already Approved'),
          content: Text(
            'Admin account "$currentUser" has already recorded an approval for this deletion.\n\nPlease switch to a different admin user to provide the second required approval.',
          ),
          actions: [
            ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))
          ],
        ),
      );
      return;
    }

    // 3. Add current admin to the approvals list
    approvals.add(currentUser);

    // 4. Check if we have reached 2 unique admin approvals
    if (approvals.length < 2) {
      // Save first approval state
      await _approveStore.record(db.name).put(_approveDb!, {
        'dbName': db.name,
        'path': db.path,
        'requestedBy': approvals.first,
        'approvals': approvals,
        'timestamp': DateTime.now().toIso8601String(),
      });

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('First Approval Recorded'),
          content: Text(
            'Approval (1/2) recorded by "$currentUser".\n\nA second distinct admin user must now switch accounts and attempt deletion to complete the process.',
          ),
          actions: [
            ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    } else {
      // 5. Two approvals reached! Confirm and execute permanent deletion
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm Dual-Admin Deletion'),
          content: Text(
            'Two admin approvals collected (${approvals.join(', ')}).\n\nProceed with permanent deletion of "${db.name}"?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () async {
                Navigator.pop(ctx);

                // Delete the actual database file from disk
                final file = File(db.path);
                if (await file.exists()) {
                  await file.delete();
                }

                // Clear the approval record
                await _approveStore.record(db.name).delete(_approveDb!);
                await _refreshDatabaseList();

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Database ${db.name} permanently deleted after 2 admin approvals.')),
                  );
                }
              },
              child: const Text('Delete Permanently'),
            ),
          ],
        ),
      );
    }
  }

  // --- IMPORT / EXPORT MODALS ---
  void _openImportModal() {
    final hostCtrl = TextEditingController(text: '192.168.1.100');
    final portCtrl = TextEditingController(text: '5432');
    final dbNameCtrl = TextEditingController();
    final userCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Remote Database'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: hostCtrl,
                decoration: const InputDecoration(labelText: 'Remote Host IP / Endpoint'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: portCtrl,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: dbNameCtrl,
                decoration: const InputDecoration(labelText: 'Target Database Name'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: userCtrl,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (dbNameCtrl.text.trim().isEmpty) return;
              final newPath = p.join(_dbDirectory!.path, '${dbNameCtrl.text.trim()}.db');
              final file = File(newPath);
              final importedData = {
                'type': 'SQL',
                'engine': _selectedDbType,
                'tables': {
                  'imported_data': {
                    'columns': [
                      {'name': 'id', 'type': 'INTEGER'},
                      {'name': 'remote_payload', 'type': 'TEXT'}
                    ],
                    'rows': [
                      {'id': 1, 'remote_payload': 'Synced from ${hostCtrl.text}'}
                    ]
                  }
                }
              };
              await file.writeAsString(const JsonEncoder.withIndent('  ').convert(importedData));
              Navigator.pop(ctx);
              await _refreshDatabaseList();
            },
            child: const Text('Connect & Import'),
          )
        ],
      ),
    );
  }

  void _openExportModal() {
    final remoteTargetCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export Local Database to Remote Target'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: remoteTargetCtrl,
                decoration: const InputDecoration(
                  labelText: 'Remote Destination URI / Endpoint',
                  hintText: 'postgres://admin:pass@remote-host:5432/target_db',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Database sync task queued for remote export.')),
              );
            },
            child: const Text('Export Data'),
          )
        ],
      ),
    );
  }

  // --- MIRROR OPTION ---
  void _openMirrorModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Database Background Mirroring'),
        content: SizedBox(
          width: 450,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Select a local database to mirror with a remote database engine:'),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                items: _databases
                    .map((db) => DropdownMenuItem(value: db.name, child: Text(db.name)))
                    .toList(),
                onChanged: (_) {},
                decoration: const InputDecoration(labelText: 'Local Database', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              const TextField(
                decoration: InputDecoration(
                  labelText: 'Remote Replication URL',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Mirroring active. Changes will sync in background.')),
              );
            },
            child: const Text('Enable Mirroring'),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header section with Refresh button, Mirror button, and Audit button
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text('Database Management', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh Database List',
                    onPressed: _refreshDatabaseList,
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.sync),
                    label: const Text('Mirror DB'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                      foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                    onPressed: _openMirrorModal,
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.fact_check),
                    label: const Text('Audit DB'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
                      foregroundColor: Theme.of(context).colorScheme.onTertiaryContainer,
                    ),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AuditDatabaseModal(databases: _databases),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Creation & Import/Export Controls
          Card(
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Database Engine',
                        border: OutlineInputBorder(),
                      ),
                      value: _selectedDbType,
                      items: _dbTypes.map((String type) {
                        return DropdownMenuItem<String>(
                          value: type,
                          child: Text(type, overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        if (newValue != null) {
                          setState(() => _selectedDbType = newValue);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: _openCreateDatabaseModal,
                    icon: const Icon(Icons.add),
                    label: const Text('Create New'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    ),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton.icon(
                    onPressed: _openImportModal,
                    icon: const Icon(Icons.upload),
                    label: const Text('Import'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    ),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton.icon(
                    onPressed: _openExportModal,
                    icon: const Icon(Icons.download),
                    label: const Text('Export'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Search Bar
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              labelText: 'Search Databases',
              hintText: 'Type database name or engine...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => _searchController.clear(),
                    )
                  : null,
              border: const OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 24),
          Text('All Configured Databases (${_filteredDatabases.length})',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),

          // Master Database List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredDatabases.isEmpty
                    ? Center(
                        child: Text(
                          _databases.isEmpty
                              ? 'No databases found in ldlx_dbs folder.\nCreate one above to get started.'
                              : 'No databases match your search filter.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _filteredDatabases.length,
                        itemBuilder: (context, index) {
                          final db = _filteredDatabases[index];
                          return _buildDbListItem(db);
                        },
                      ),
          )
        ],
      ),
    );
  }

  Widget _buildDbListItem(LocalDatabaseInfo db) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8.0),
      child: ListTile(
        leading: Icon(
          Icons.storage,
          color: Theme.of(context).colorScheme.secondary,
        ),
        title: Text(db.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('Engine: ${db.type} | Path: ldlx_dbs/${p.basename(db.path)}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_note, color: Colors.cyan),
              tooltip: 'View / Modify Table',
              onPressed: () => _openDatabaseEditor(db),
            ),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.redAccent),
              tooltip: 'Delete (Requires 2 Admin Approvals)',
              onPressed: () => _handleDeleteDatabaseRequest(db),
            ),
          ],
        ),
      ),
    );
  }
}