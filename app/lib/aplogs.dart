import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

enum ApiLogTimeFrame {
  currentMonth,
  last3Months,
  lastYear,
  fiveYears,
}

class ApiLogEntry {
  final int id;
  final int timestamp;
  final String isoTime;
  final String method;
  final String path;
  final Map<String, dynamic> queryParameters;
  final int statusCode;
  final String remoteAddress;
  final String databaseTarget;

  ApiLogEntry({
    required this.id,
    required this.timestamp,
    required this.isoTime,
    required this.method,
    required this.path,
    required this.queryParameters,
    required this.statusCode,
    required this.remoteAddress,
    required this.databaseTarget,
  });

  factory ApiLogEntry.fromMap(int id, Map<String, dynamic> map) {
    return ApiLogEntry(
      id: id,
      timestamp: map['timestamp'] ?? 0,
      isoTime: map['iso_time'] ?? '',
      method: map['method'] ?? 'GET',
      path: map['path'] ?? '',
      queryParameters: Map<String, dynamic>.from(map['query_parameters'] ?? {}),
      statusCode: map['status_code'] ?? 200,
      remoteAddress: map['remote_address'] ?? '',
      databaseTarget: map['database_target'] ?? 'none',
    );
  }
}

class ApiLogService {
  static final ApiLogService _instance = ApiLogService._internal();
  factory ApiLogService() => _instance;
  ApiLogService._internal();

  Database? _db;
  final _store = intMapStoreFactory.store('api_logs');

  Future<Database> _getDatabase() async {
    if (_db != null) return _db!;
    final appDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(appDir.path, 'ldlx_dbs', 'database_logs.db');
    
    // Ensure parent directory exists
    final dir = Directory(p.dirname(dbPath));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    _db = await databaseFactoryIo.openDatabase(dbPath);
    return _db!;
  }

  /// Efficiently query logs filtered by timeframe using Sembast Indexing/Finders
  Future<List<ApiLogEntry>> fetchLogs(ApiLogTimeFrame timeFrame) async {
    try {
      final db = await _getDatabase();
      final now = DateTime.now();
      DateTime cutoff;

      switch (timeFrame) {
        case ApiLogTimeFrame.currentMonth:
          cutoff = DateTime(now.year, now.month, 1);
          break;
        case ApiLogTimeFrame.last3Months:
          cutoff = now.subtract(const Duration(days: 90));
          break;
        case ApiLogTimeFrame.lastYear:
          cutoff = now.subtract(const Duration(days: 365));
          break;
        case ApiLogTimeFrame.fiveYears:
          cutoff = now.subtract(const Duration(days: 365 * 5));
          break;
      }

      final finder = Finder(
        filter: Filter.greaterThanOrEquals('timestamp', cutoff.millisecondsSinceEpoch),
        sortOrders: [SortOrder('timestamp', false)], // Newest logs first
      );

      final snapshots = await _store.find(db, finder: finder);
      return snapshots.map((snap) => ApiLogEntry.fromMap(snap.key, snap.value)).toList();
    } catch (e) {
      return [];
    }
  }

  /// Efficiently fetch and bucket logs organized by each calendar day (YYYY-MM-DD)
  Future<Map<String, List<ApiLogEntry>>> fetchLogsGroupedByDay(ApiLogTimeFrame timeFrame) async {
    final logs = await fetchLogs(timeFrame);
    final Map<String, List<ApiLogEntry>> groupedLogs = {};

    for (var log in logs) {
      final date = DateTime.fromMillisecondsSinceEpoch(log.timestamp);
      final dayKey = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

      groupedLogs.putIfAbsent(dayKey, () => []);
      groupedLogs[dayKey]!.add(log);
    }

    return groupedLogs;
  }
}

/// Fully integrated UI View for inspecting database API request logs
class ApiLogsView extends StatefulWidget {
  const ApiLogsView({Key? key}) : super(key: key);

  @override
  State<ApiLogsView> createState() => _ApiLogsViewState();
}

class _ApiLogsViewState extends State<ApiLogsView> {
  ApiLogTimeFrame _selectedTimeFrame = ApiLogTimeFrame.currentMonth;
  String _searchQuery = '';
  bool _isLoading = true;
  List<ApiLogEntry> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _isLoading = true);
    final logs = await ApiLogService().fetchLogs(_selectedTimeFrame);
    setState(() {
      _logs = logs;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final filteredLogs = _logs.where((log) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return log.databaseTarget.toLowerCase().contains(q) ||
          log.path.toLowerCase().contains(q) ||
          log.method.toLowerCase().contains(q) ||
          log.remoteAddress.toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0F1219),
      appBar: AppBar(
        title: const Text('Database API Logs Viewer'),
        backgroundColor: const Color(0xFF161B22),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Logs',
            onPressed: _loadLogs,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search by database, path, method...',
                      prefixIcon: const Icon(Icons.search, color: Colors.cyanAccent),
                      filled: true,
                      fillColor: const Color(0xFF161B22),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      isDense: true,
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                ),
                const SizedBox(width: 16),
                DropdownButton<ApiLogTimeFrame>(
                  value: _selectedTimeFrame,
                  dropdownColor: const Color(0xFF161B22),
                  style: const TextStyle(color: Colors.white),
                  items: const [
                    DropdownMenuItem(value: ApiLogTimeFrame.currentMonth, child: Text('Current Month')),
                    DropdownMenuItem(value: ApiLogTimeFrame.last3Months, child: Text('Last 3 Months')),
                    DropdownMenuItem(value: ApiLogTimeFrame.lastYear, child: Text('Last Year')),
                    DropdownMenuItem(value: ApiLogTimeFrame.fiveYears, child: Text('Last 5 Years')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedTimeFrame = val);
                      _loadLogs();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
                  : filteredLogs.isEmpty
                      ? const Center(
                          child: Text('No API log entries found for this period.', style: TextStyle(color: Colors.grey)),
                        )
                      : ListView.builder(
                          itemCount: filteredLogs.length,
                          itemBuilder: (context, index) {
                            final log = filteredLogs[index];
                            final isSuccess = log.statusCode >= 200 && log.statusCode < 300;
                            return Card(
                              color: const Color(0xFF161B22),
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isSuccess ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${log.statusCode}',
                                    style: TextStyle(color: isSuccess ? Colors.greenAccent : Colors.redAccent, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Text(log.method, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                                    const SizedBox(width: 8),
                                    Expanded(child: Text(log.path, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white))),
                                  ],
                                ),
                                subtitle: Text(
                                  'Database: ${log.databaseTarget} | IP: ${log.remoteAddress} | ${log.isoTime}',
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}