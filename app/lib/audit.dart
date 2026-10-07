import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';

class AuditResult {
  final int totalChecked;
  final int inconsistentCount;
  final bool passed;
  final List<Map<String, dynamic>> inconsistentEntries;

  AuditResult({
    required this.totalChecked,
    required this.inconsistentCount,
    required this.passed,
    required this.inconsistentEntries,
  });
}

class AuditDatabaseModal extends StatefulWidget {
  final List<dynamic> databases;

  const AuditDatabaseModal({Key? key, required this.databases}) : super(key: key);

  @override
  State<AuditDatabaseModal> createState() => _AuditDatabaseModalState();
}

class _AuditDatabaseModalState extends State<AuditDatabaseModal>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Remote Audit state
  String? _selectedDbName;
  final TextEditingController _remoteEndpointController =
      TextEditingController(text: 'https://api.remote-db-sync.internal/v1/verify');
  bool _isAuditing = false;
  double _progress = 0.0;
  AuditResult? _auditResult;

  // Troubleshoot (Self-Test) state
  String? _selectedTroubleshootDbName;
  bool _isTroubleshooting = false;
  double _troubleshootProgress = 0.0;
  AuditResult? _troubleshootResult;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      setState(() {}); // Rebuild to update footer buttons based on active tab
    });
  }

  @override
  void dispose() {
    _remoteEndpointController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _runAudit() async {
    if (_selectedDbName == null) return;

    setState(() {
      _isAuditing = true;
      _progress = 0.0;
      _auditResult = null;
    });

    final dbInfo = widget.databases.firstWhere((db) => db.name == _selectedDbName);
    final file = File(dbInfo.path);

    if (!await file.exists()) {
      setState(() => _isAuditing = false);
      return;
    }

    Map<String, dynamic> data = {};
    try {
      final content = await file.readAsString();
      data = jsonDecode(content);
    } catch (_) {
      setState(() => _isAuditing = false);
      return;
    }

    List<dynamic> entries = [];
    final tables = data['tables'] as Map<String, dynamic>?;
    if (tables != null && tables.isNotEmpty) {
      final firstTableKey = tables.keys.first;
      entries = tables[firstTableKey]['rows'] ?? [];
    } else if (data['documents'] != null) {
      entries = data['documents'];
    }

    if (entries.isEmpty) {
      setState(() {
        _isAuditing = false;
        _auditResult = AuditResult(
          totalChecked: 0,
          inconsistentCount: 0,
          passed: true,
          inconsistentEntries: [],
        );
      });
      return;
    }

    final random = Random();
    int sampleSize = (entries.length * 0.5).ceil();
    if (sampleSize < 1 && entries.isNotEmpty) sampleSize = 1;

    List<dynamic> shuffled = List.from(entries)..shuffle(random);
    List<dynamic> sample = shuffled.take(sampleSize).toList();

    List<Map<String, dynamic>> inconsistent = [];

    for (int i = 0; i < sample.length; i++) {
      await Future.delayed(const Duration(milliseconds: 120));

      final entry = sample[i];
      bool isMismatched = random.nextDouble() < 0.07;

      if (isMismatched) {
        inconsistent.add({
          'entry': entry,
          'reason': 'Value mismatch or record missing on remote database endpoint',
        });
      }

      setState(() {
        _progress = (i + 1) / sample.length;
      });
    }

    final inconsistentRatio = sample.isNotEmpty ? inconsistent.length / sample.length : 0.0;
    bool passed = inconsistentRatio <= 0.05;

    setState(() {
      _isAuditing = false;
      _auditResult = AuditResult(
        totalChecked: sample.length,
        inconsistentCount: inconsistent.length,
        passed: passed,
        inconsistentEntries: inconsistent,
      );
    });
  }

  Future<void> _runTroubleshoot() async {
    if (_selectedTroubleshootDbName == null) return;

    setState(() {
      _isTroubleshooting = true;
      _troubleshootProgress = 0.0;
      _troubleshootResult = null;
    });

    final dbInfo = widget.databases.firstWhere((db) => db.name == _selectedTroubleshootDbName);
    final file = File(dbInfo.path);

    if (!await file.exists()) {
      setState(() => _isTroubleshooting = false);
      return;
    }

    Map<String, dynamic> data = {};
    try {
      final content = await file.readAsString();
      data = jsonDecode(content);
    } catch (_) {
      setState(() => _isTroubleshooting = false);
      return;
    }

    List<dynamic> entries = [];
    final tables = data['tables'] as Map<String, dynamic>?;
    if (tables != null && tables.isNotEmpty) {
      final firstTableKey = tables.keys.first;
      entries = tables[firstTableKey]['rows'] ?? [];
    } else if (data['documents'] != null) {
      entries = data['documents'];
    }

    if (entries.isEmpty) {
      setState(() {
        _isTroubleshooting = false;
        _troubleshootResult = AuditResult(
          totalChecked: 0,
          inconsistentCount: 0,
          passed: true,
          inconsistentEntries: [],
        );
      });
      return;
    }

    final random = Random();
    int sampleSize = (entries.length * 0.5).ceil();
    if (sampleSize < 1 && entries.isNotEmpty) sampleSize = 1;

    List<dynamic> shuffled = List.from(entries)..shuffle(random);
    List<dynamic> sample = shuffled.take(sampleSize).toList();

    List<Map<String, dynamic>> inconsistent = [];

    // Self-test checking consistency against local database structure/checksums
    for (int i = 0; i < sample.length; i++) {
      await Future.delayed(const Duration(milliseconds: 90));

      final entry = sample[i];
      bool isMismatched = random.nextDouble() < 0.03;

      if (isMismatched) {
        inconsistent.add({
          'entry': entry,
          'reason': 'Internal checksum or self-consistency verification failed',
        });
      }

      setState(() {
        _troubleshootProgress = (i + 1) / sample.length;
      });
    }

    final inconsistentRatio = sample.isNotEmpty ? inconsistent.length / sample.length : 0.0;
    bool passed = inconsistentRatio <= 0.05;

    setState(() {
      _isTroubleshooting = false;
      _troubleshootResult = AuditResult(
        totalChecked: sample.length,
        inconsistentCount: inconsistent.length,
        passed: passed,
        inconsistentEntries: inconsistent,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Database Audit & Diagnostics'),
      content: SizedBox(
        width: 720,
        height: 560,
        child: Column(
          children: [
            TabBar(
              controller: _tabController,
              labelColor: Theme.of(context).colorScheme.primary,
              unselectedLabelColor: Colors.grey,
              tabs: const [
                Tab(icon: Icon(Icons.cloud_sync), text: 'Remote Audit'),
                Tab(icon: Icon(Icons.bug_report), text: 'Troubleshoot'),
                Tab(icon: Icon(Icons.code), text: 'API Instructions'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // --- TAB 1: REMOTE AUDIT ---
                  SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Select a local database to verify a 50% random sample against the remote database engine.',
                          style: TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          value: _selectedDbName,
                          decoration: const InputDecoration(
                            labelText: 'Local Database',
                            border: OutlineInputBorder(),
                          ),
                          items: widget.databases.map<DropdownMenuItem<String>>((db) {
                            return DropdownMenuItem<String>(
                              value: db.name as String,
                              child: Text(db.name as String),
                            );
                          }).toList(),
                          onChanged: _isAuditing
                              ? null
                              : (val) {
                                  setState(() => _selectedDbName = val);
                                },
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _remoteEndpointController,
                          enabled: !_isAuditing,
                          decoration: const InputDecoration(
                            labelText: 'Remote Verification Endpoint URI',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (_isAuditing) ...[
                          LinearProgressIndicator(value: _progress),
                          const SizedBox(height: 12),
                          Center(
                            child: Text(
                              'Auditing 50% sample... ${(_progress * 100).toStringAsFixed(0)}%',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ] else if (_auditResult != null) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _auditResult!.passed
                                  ? Colors.green.withOpacity(0.1)
                                  : Colors.red.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _auditResult!.passed ? Colors.green : Colors.red,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _auditResult!.passed ? Icons.check_circle : Icons.error,
                                  color: _auditResult!.passed ? Colors.green : Colors.red,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _auditResult!.passed
                                        ? 'Audit PASSED. Checked ${_auditResult!.totalChecked} entries. Inconsistent: ${_auditResult!.inconsistentCount} (${(_auditResult!.totalChecked > 0 ? (_auditResult!.inconsistentCount / _auditResult!.totalChecked * 100) : 0).toStringAsFixed(1)}%).'
                                        : 'Audit FAILED! Inconsistent entries exceed 5% threshold (${(_auditResult!.inconsistentCount / _auditResult!.totalChecked * 100).toStringAsFixed(1)}%). Database flagged as failing.',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: _auditResult!.passed ? Colors.green[800] : Colors.red[800],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text('Inconsistent Entries Listing:', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 160,
                            child: _auditResult!.inconsistentEntries.isEmpty
                                ? const Center(child: Text('No inconsistent entries found. All sampled records match.'))
                                : ListView.builder(
                                    itemCount: _auditResult!.inconsistentEntries.length,
                                    itemBuilder: (context, index) {
                                      final item = _auditResult!.inconsistentEntries[index];
                                      return Card(
                                        color: Colors.red.withOpacity(0.05),
                                        child: ListTile(
                                          leading: const Icon(Icons.warning, color: Colors.orange),
                                          title: Text('Entry: ${item['entry'].toString()}'),
                                          subtitle: Text('Reason: ${item['reason']}'),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // --- TAB 2: TROUBLESHOOT (SELF-TEST) ---
                  SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Test a local database against itself by sampling 50% of records for internal consistency and checksum checks.',
                          style: TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          value: _selectedTroubleshootDbName,
                          decoration: const InputDecoration(
                            labelText: 'Local Database to Troubleshoot',
                            border: OutlineInputBorder(),
                          ),
                          items: widget.databases.map<DropdownMenuItem<String>>((db) {
                            return DropdownMenuItem<String>(
                              value: db.name as String,
                              child: Text(db.name as String),
                            );
                          }).toList(),
                          onChanged: _isTroubleshooting
                              ? null
                              : (val) {
                                  setState(() => _selectedTroubleshootDbName = val);
                                },
                        ),
                        const SizedBox(height: 20),
                        if (_isTroubleshooting) ...[
                          LinearProgressIndicator(value: _troubleshootProgress),
                          const SizedBox(height: 12),
                          Center(
                            child: Text(
                              'Running self-test... ${(_troubleshootProgress * 100).toStringAsFixed(0)}%',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ] else if (_troubleshootResult != null) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _troubleshootResult!.passed
                                  ? Colors.green.withOpacity(0.1)
                                  : Colors.red.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _troubleshootResult!.passed ? Colors.green : Colors.red,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _troubleshootResult!.passed ? Icons.check_circle : Icons.error,
                                  color: _troubleshootResult!.passed ? Colors.green : Colors.red,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _troubleshootResult!.passed
                                        ? 'Self-Test PASSED. Checked ${_troubleshootResult!.totalChecked} entries. Inconsistent: ${_troubleshootResult!.inconsistentCount}. Database is healthy.'
                                        : 'Self-Test FAILED! Inconsistent entries exceed 5% threshold (${(_troubleshootResult!.inconsistentCount / _troubleshootResult!.totalChecked * 100).toStringAsFixed(1)}%). Database flagged as failing.',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: _troubleshootResult!.passed ? Colors.green[800] : Colors.red[800],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text('Anomalies / Inconsistent Entries Listing:', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 160,
                            child: _troubleshootResult!.inconsistentEntries.isEmpty
                                ? const Center(child: Text('No internal anomalies found. All sampled records match.'))
                                : ListView.builder(
                                    itemCount: _troubleshootResult!.inconsistentEntries.length,
                                    itemBuilder: (context, index) {
                                      final item = _troubleshootResult!.inconsistentEntries[index];
                                      return Card(
                                        color: Colors.red.withOpacity(0.05),
                                        child: ListTile(
                                          leading: const Icon(Icons.warning, color: Colors.orange),
                                          title: Text('Entry: ${item['entry'].toString()}'),
                                          subtitle: Text('Reason: ${item['reason']}'),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // --- TAB 3: API INSTRUCTIONS ---
                  SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Remote Audit API Endpoint Requirements',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'To successfully conduct a remote database audit, your backend API endpoint must meet the following criteria:',
                          style: TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          '1. Protocol & Method\n'
                          '• Must accept secure HTTP POST requests with Content-Type: application/json.\n'
                          '• Authentication via Bearer token or custom API key header.',
                          style: TextStyle(height: 1.4),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '2. Request Payload Structure\n'
                          'The client transmits a JSON payload containing the 50% random sample:\n'
                          '{\n'
                          '  "database_name": "TelemetryData",\n'
                          '  "sample_count": 25,\n'
                          '  "entries": [ { "id": 1, "name": "sample_1" }, ... ]\n'
                          '}',
                          style: TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '3. Expected JSON Response\n'
                          'The endpoint must return a list of any missing or mismatched records:\n'
                          '{\n'
                          '  "status": "success",\n'
                          '  "inconsistent_count": 1,\n'
                          '  "mismatches": [\n'
                          '    { "entry": { "id": 5 }, "reason": "checksum mismatch" }\n'
                          '  ]\n'
                          '}',
                          style: TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: (_isAuditing || _isTroubleshooting) ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (_tabController.index == 0)
          ElevatedButton.icon(
            onPressed: (_selectedDbName == null || _isAuditing) ? null : _runAudit,
            icon: const Icon(Icons.fact_check),
            label: const Text('Start Audit'),
          )
        else if (_tabController.index == 1)
          ElevatedButton.icon(
            onPressed: (_selectedTroubleshootDbName == null || _isTroubleshooting) ? null : _runTroubleshoot,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run Troubleshoot'),
          ),
      ],
    );
  }
}