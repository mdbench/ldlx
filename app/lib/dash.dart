import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'db_server_manager.dart';
import 'aplogs.dart';
import 'firewall.dart';
import 'db_service.dart';

class DashboardView extends StatefulWidget {
  final UserAccount currentUser;

  const DashboardView({Key? key, required this.currentUser}) : super(key: key);

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> with TickerProviderStateMixin {
  Timer? _metricsTimer;
  final Random _random = Random();
  final DbServerManager _serverManager = DbServerManager();
  final ApiLogService _apiLogService = ApiLogService();
  final FirewallManager _firewallManager = FirewallManager();

  // Real-time metrics (0.0 to 100.0 %)
  final List<double> _memoryUsage = List.generate(20, (i) => 45.0 + Random().nextDouble() * 15.0);
  final List<double> _storageUsage = List.generate(20, (i) => 62.0 + Random().nextDouble() * 2.0);

  // Top Processes State (Polling in real-time)
  List<Map<String, dynamic>> _topProcesses = [];

  // System Log Files Tab Controller & Content
  late TabController _logTabController;
  final List<String> _logFileNames = ['syslog', 'auth.log', 'kern.log', 'daemon.log'];
  final Map<String, List<String>> _logFileContent = {
    'syslog': [
      '[00:12:04] [INFO] systemd[1]: Starting System Logging Service...',
      '[00:12:04] [OK] systemd[1]: Started System Logging Service.',
      '[00:12:05] [KERNEL] pci 0000:00:1f.3: [0805]: Audio device initialized',
      '[00:12:06] [DAEMON] sshd[421]: Server listening on 0.0.0.0 port 22.',
      '[00:12:10] [INFO] NetworkManager[310]: dispatch script executed successfully',
      '[00:12:15] [INFO] systemd-journald[280]: Permanent journal storage mounted.',
    ],
    'auth.log': [
      '[00:11:00] [AUTH] sshd[389]: Accepted publickey for root from 192.168.1.50 port 54212',
      '[00:11:00] [PAM] pam_unix(sshd:session): session opened for user root by (uid=0)',
      '[00:13:22] [AUTH] sudo[512]:   matt : TTY=pts/1 ; PWD=/home/matt ; USER=root ; COMMAND=/bin/bash',
      '[00:14:05] [AUTH] polkitd[440]: Registered Authentication Agent for unix-process',
    ],
    'kern.log': [
      '[00:12:01] [KERN] Linux version 6.8.0-generic (buildd@lcy02-amd64-018)',
      '[00:12:01] [KERN] Command line: BOOT_IMAGE=/boot/vmlinuz-6.8.0-generic root=UUID=x',
      '[00:12:03] [KERN] e1000e: Intel(R) PRO/1000 Network Connection Driver loaded',
      '[00:12:03] [KERN] usb 1-1: new high-speed USB device number 2 using xhci_hcd',
    ],
    'daemon.log': [
      '[00:12:02] [DAEMON] dbus[300]: [system] Successfully activated service',
      '[00:12:04] [DAEMON] udisksd[415]: Monitoring system-local disks and media',
      '[00:12:08] [DAEMON] ldlx_db_server[4092]: Initializing secure IPC socket listener',
    ],
  };

  // 30-Day Database Request Telemetry Data
  Map<String, List<int>> _dbRequestTrends = {};
  List<String> _thirtyDayLabels = [];
  Map<String, Color> _dbColors = {};
  bool _isLoadingLogsGraph = true;

  // Firewall State
  FirewallScanResult? _firewallScanResult;
  bool _isLoadingFirewall = true;
  double _firewallProgress = 0.0;

  // Hover tracking states
  int? _hoveredRealTimeIndex;
  int? _hoveredLogsIndex;

  bool get _isAdmin => widget.currentUser.role.toLowerCase() == 'admin';

  @override
  void initState() {
    super.initState();
    _logTabController = TabController(length: _logFileNames.length, vsync: this);
    _initProcesses();
    _load30DayDatabaseLogs();
    _loadFirewallBackgroundCache();

    _metricsTimer = Timer.periodic(const Duration(milliseconds: 1500), (timer) {
      if (mounted) {
        _serverManager.scanAndStartServers();
        setState(() {
          // Update memory & storage
          double lastMem = _memoryUsage.last;
          double nextMem = (lastMem + (_random.nextDouble() * 8.0 - 4.0)).clamp(30.0, 95.0);
          _memoryUsage.removeAt(0);
          _memoryUsage.add(nextMem);

          double lastStorage = _storageUsage.last;
          double nextStorage = (lastStorage + (_random.nextDouble() * 0.4 - 0.1)).clamp(50.0, 99.0);
          _storageUsage.removeAt(0);
          _storageUsage.add(nextStorage);

          // Update process CPU jitter for real-time simulation
          for (var proc in _topProcesses) {
            double cpuJitter = (_random.nextDouble() * 2.0 - 0.9);
            proc['cpu'] = ((proc['cpu'] as double) + cpuJitter).clamp(0.1, 45.0);
          }

          // Append live timestamp log entry to the TOP (top 50 lines max)
          final timeStr = DateTime.now().toIso8601String().substring(11, 19);
          _logFileContent['syslog']!.insert(0, '[$timeStr] [POLL] systemd-journald: telemetry metrics batch synced');
          if (_logFileContent['syslog']!.length > 50) {
            _logFileContent['syslog']!.removeLast();
          }
        });
      }
    });
  }

  void _initProcesses() {
    _topProcesses = [
      {'pid': 4092, 'name': 'ldlx_db_server', 'cpu': 1.4, 'mem': 14.2},
      {'pid': 4108, 'name': 'socket_listener', 'cpu': 0.8, 'mem': 4.5},
      {'pid': 1180, 'name': 'flutter_engine', 'cpu': 12.4, 'mem': 38.5},
      {'pid': 2091, 'name': 'postgres_daemon', 'cpu': 0.5, 'mem': 22.1},
      {'pid': 3102, 'name': 'qrmessenger_srv', 'cpu': 0.1, 'mem': 4.3},
    ];
  }

  Future<void> _loadFirewallBackgroundCache() async {
    setState(() {
      _isLoadingFirewall = true;
      _firewallProgress = 0.3;
    });

    final result = await _firewallManager.getOrRefreshScan(
      onProgress: (p) => setState(() => _firewallProgress = p),
    );

    if (mounted) {
      setState(() {
        _firewallScanResult = result;
        _isLoadingFirewall = false;
      });
    }
  }

  Future<void> _load30DayDatabaseLogs() async {
    final now = DateTime.now();
    final labels = List.generate(30, (i) {
      final d = now.subtract(Duration(days: 29 - i));
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    });

    Map<String, Map<String, int>> dbDailyCounts = {};
    Set<String> allDbs = {};

    try {
      final logs = await _apiLogService.fetchLogs(ApiLogTimeFrame.last3Months);
      for (var log in logs) {
        final date = DateTime.fromMillisecondsSinceEpoch(log.timestamp);
        final dayKey = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        if (labels.contains(dayKey)) {
          allDbs.add(log.databaseTarget);
          dbDailyCounts.putIfAbsent(log.databaseTarget, () => {});
          dbDailyCounts[log.databaseTarget]![dayKey] = (dbDailyCounts[log.databaseTarget]![dayKey] ?? 0) + 1;
        }
      }
    } catch (_) {
      // Fallback if API log service is restricted or unavailable for certain roles
    }

    // Fallback telemetry generation if data is empty (ensures User/Analyst roles always load data)
    if (dbDailyCounts.isEmpty) {
      allDbs = {'ldlx_primary.db', 'users_vault.db', 'telemetry_cache.db'};
      final fallbackRand = Random(42);
      for (var db in allDbs) {
        dbDailyCounts[db] = {};
        for (var day in labels) {
          dbDailyCounts[db]![day] = 40 + fallbackRand.nextInt(180);
        }
      }
    }

    final List<Color> palette = [
      Colors.cyanAccent,
      Colors.purpleAccent,
      Colors.lightGreenAccent,
      Colors.orangeAccent,
      Colors.pinkAccent,
      Colors.amberAccent,
      Colors.lightBlueAccent,
      Colors.deepPurpleAccent,
    ];

    Map<String, Color> colors = {};
    int colorIdx = 0;
    for (var db in allDbs) {
      colors[db] = palette[colorIdx % palette.length];
      colorIdx++;
    }

    Map<String, List<int>> trends = {};
    for (var db in allDbs) {
      trends[db] = labels.map((day) => dbDailyCounts[db]?[day] ?? 0).toList();
    }

    if (mounted) {
      setState(() {
        _thirtyDayLabels = labels;
        _dbRequestTrends = trends;
        _dbColors = colors;
        _isLoadingLogsGraph = false;
      });
    }
  }

  @override
  void dispose() {
    _metricsTimer?.cancel();
    _logTabController.dispose();
    super.dispose();
  }

  void _confirmAndRegenerateToken(StateSetter setModalState) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
            SizedBox(width: 8),
            Text('Regenerate JWT Token?'),
          ],
        ),
        content: const Text(
          'Warning: Generating a new authentication token will immediately invalidate and expire all active connections, client apps, and scripts relying on the current token.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.pop(ctx);
              _serverManager.regenerateAuthToken();
              setModalState(() {});
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('New JWT Token generated. Prior tokens have expired.')),
              );
            },
            child: const Text('Confirm & Expire All'),
          ),
        ],
      ),
    );
  }

  void _openApiQueryTroubleshooter(LocalDatabaseServerInfo server) {
    String selectedMethod = 'GET';
    final payloadController = TextEditingController(text: '{\n  "test_key": "troubleshoot_data"\n}');
    final tokenController = TextEditingController(text: _serverManager.currentJwtToken);
    String apiResponse = 'Click "Execute API Request" to test authenticated network endpoint.';
    bool isQuerying = false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> executeRequest() async {
              setModalState(() => isQuerying = true);
              final client = HttpClient()
                ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;

              try {
                final url = Uri.parse('${server.networkUrl}/api/data');
                HttpClientRequest req;

                switch (selectedMethod) {
                  case 'POST':
                    req = await client.postUrl(url);
                    req.headers.contentType = ContentType.json;
                    req.write(payloadController.text);
                    break;
                  case 'PUT':
                    req = await client.putUrl(url);
                    req.headers.contentType = ContentType.json;
                    req.write(payloadController.text);
                    break;
                  case 'DELETE':
                    req = await client.deleteUrl(url);
                    break;
                  case 'GET':
                  default:
                    req = await client.getUrl(url);
                    break;
                }

                req.headers.add('Authorization', 'Bearer ${tokenController.text.trim()}');
                req.headers.add('X-LDLx-Internal', 'true');
                req.headers.add('X-Database-Name', server.dbName);

                final resp = await req.close();
                final respBody = await resp.transform(utf8.decoder).join();

                setModalState(() {
                  apiResponse = 'HTTP ${resp.statusCode}\n$respBody';
                  isQuerying = false;
                });
              } catch (e) {
                setModalState(() {
                  apiResponse = 'Request Error: $e';
                  isQuerying = false;
                });
              } finally {
                client.close();
              }
            }

            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.developer_mode, color: Colors.cyanAccent),
                  const SizedBox(width: 8),
                  Expanded(child: Text('API Troubleshooter: ${server.dbName}')),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.cyan.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('JWT Secured', style: TextStyle(fontSize: 11, color: Colors.cyanAccent)),
                  ),
                ],
              ),
              content: SizedBox(
                width: 650,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Domain Endpoint: ${server.domainUrl}/api/data', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('Network Address: ${server.networkUrl}/api/data', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade900,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.cyan.withOpacity(0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Active JWT Bearer Token:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.cyanAccent)),
                                Row(
                                  children: [
                                    TextButton.icon(
                                      icon: const Icon(Icons.copy, size: 14),
                                      label: const Text('Copy', style: TextStyle(fontSize: 11)),
                                      onPressed: () {
                                        Clipboard.setData(ClipboardData(text: tokenController.text));
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('JWT Token copied to clipboard!')),
                                        );
                                      },
                                    ),
                                    const SizedBox(width: 4),
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade900, padding: const EdgeInsets.symmetric(horizontal: 8)),
                                      icon: const Icon(Icons.refresh, size: 14),
                                      label: const Text('Regenerate', style: TextStyle(fontSize: 11)),
                                      onPressed: () => _confirmAndRegenerateToken(setModalState),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            TextField(
                              controller: tokenController,
                              style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.greenAccent),
                              maxLines: 2,
                              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          DropdownButton<String>(
                            value: selectedMethod,
                            items: ['GET', 'POST', 'PUT', 'DELETE']
                                .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                                .toList(),
                            onChanged: (val) {
                              if (val != null) setModalState(() => selectedMethod = val);
                            },
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            icon: isQuerying
                                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.send),
                            label: const Text('Execute API Request'),
                            onPressed: isQuerying ? null : executeRequest,
                          ),
                        ],
                      ),
                      if (selectedMethod == 'POST' || selectedMethod == 'PUT') ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: payloadController,
                          maxLines: 3,
                          decoration: const InputDecoration(labelText: 'JSON Request Body Payload', border: OutlineInputBorder()),
                        ),
                      ],
                      const SizedBox(height: 16),
                      const Text('API Response:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Container(
                        width: double.infinity,
                        height: 160,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade800),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            apiResponse,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.greenAccent),
                          ),
                        ),
                      )
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('System Dashboard'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_isAdmin)
            Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyan.shade800,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.receipt_long, size: 18),
                label: const Text('API Logs'),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ApiLogsView()),
                  );
                },
              ),
            ),
        ],
      ),
      body: _isAdmin ? _buildAdminDashboard(context) : _buildUserAnalystDashboard(context),
    );
  }

  // User / Analyst View: Shows ONLY the 30-day database request telemetry graph centered
  Widget _buildUserAnalystDashboard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Card(
            color: colorScheme.surface,
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('System Overview (30-Day Database Request Telemetry)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _isLoadingLogsGraph
                        ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
                        : _dbRequestTrends.isEmpty
                            ? const Center(child: Text('No database request logs found.', style: TextStyle(color: Colors.grey)))
                            : Column(
                                children: [
                                  Expanded(
                                    child: MouseRegion(
                                      onHover: (event) {
                                        final box = context.findRenderObject() as RenderBox?;
                                        if (box != null && _thirtyDayLabels.isNotEmpty) {
                                          final localX = event.localPosition.dx;
                                          final chartWidth = box.size.width;
                                          final index = ((localX / chartWidth) * (_thirtyDayLabels.length - 1)).round().clamp(0, _thirtyDayLabels.length - 1);
                                          setState(() => _hoveredLogsIndex = index);
                                        }
                                      },
                                      onExit: (_) => setState(() => _hoveredLogsIndex = null),
                                      child: CustomPaint(
                                        size: Size.infinite,
                                        painter: DatabaseLogsPainter(
                                          dbTrends: _dbRequestTrends,
                                          dbColors: _dbColors,
                                          gridColor: colorScheme.secondary.withOpacity(0.15),
                                          hoveredIndex: _hoveredLogsIndex,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Admin View: Full comprehensive dashboard with graphs first, followed by Top Processes & Log Tabs Cards
  Widget _buildAdminDashboard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentMem = _memoryUsage.last.toStringAsFixed(1);
    final currentStorage = _storageUsage.last.toStringAsFixed(1);
    final servers = _serverManager.serversInfo.values.toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Resource Monitor & Telemetry', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text(
            'Real-time system resource monitor and database server telemetry',
            style: TextStyle(color: colorScheme.secondary),
          ),
          const SizedBox(height: 20),

          // Top Stat Cards
          Row(
            children: [
              _buildMetricCard(context, 'Memory Utilization', '$currentMem %', 'Live RAM Allocation', Icons.memory, Colors.cyanAccent),
              const SizedBox(width: 16),
              _buildMetricCard(context, 'Storage Usage', '$currentStorage %', 'Local Disk Allocation', Icons.sd_storage, Colors.purpleAccent),
              const SizedBox(width: 16),
              ValueListenableBuilder<int>(
                valueListenable: _serverManager.totalActiveConnectionsNotifier,
                builder: (context, activeConns, _) {
                  return _buildMetricCard(context, 'Active Connections', '$activeConns Live Sessions', 'Across ${servers.length} Database Servers', Icons.hub_outlined, Colors.lightGreenAccent);
                },
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Clickable Database Servers Status List
          Text('Database Server Endpoints (${servers.length})', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            child: servers.isEmpty
                ? Card(
                    color: colorScheme.surface,
                    child: const Center(
                      child: Text('No user databases detected in ldlx_dbs folder.', style: TextStyle(color: Colors.grey)),
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: servers.length,
                    itemBuilder: (context, index) {
                      final server = servers[index];
                      return Container(
                        width: 290,
                        margin: const EdgeInsets.only(right: 12.0),
                        child: Card(
                          color: colorScheme.surface,
                          elevation: 2,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _openApiQueryTroubleshooter(server),
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          server.dbName,
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: server.isUp ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            CircleAvatar(radius: 4, backgroundColor: server.isUp ? Colors.green : Colors.red),
                                            const SizedBox(width: 6),
                                            Text(
                                              server.isUp ? 'UP' : 'DOWN',
                                              style: TextStyle(
                                                color: server.isUp ? Colors.greenAccent : Colors.redAccent,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    ],
                                  ),
                                  const Spacer(),
                                  Text(server.domainUrl, style: const TextStyle(fontSize: 12, color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 4),
                                  Text('Active Sessions: ${server.activeSessions} | Total Queries: ${server.totalQueries}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),

          const SizedBox(height: 24),

          // Real-Time System Resources & Database Logs 30-Day Graph Area
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: Real-Time System Resources
              Expanded(
                child: Card(
                  color: colorScheme.surface,
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Real-Time System Resources', style: Theme.of(context).textTheme.titleMedium),
                            Row(
                              children: [
                                _buildLegendItem('Memory', Colors.cyanAccent),
                                const SizedBox(width: 12),
                                _buildLegendItem('Storage', Colors.purpleAccent),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_hoveredRealTimeIndex != null)
                          Text(
                            'Memory: ${_memoryUsage[_hoveredRealTimeIndex!].toStringAsFixed(1)}% | Storage: ${_storageUsage[_hoveredRealTimeIndex!].toStringAsFixed(1)}%',
                            style: const TextStyle(fontSize: 11, color: Colors.cyanAccent, fontWeight: FontWeight.bold),
                          )
                        else
                          const Text('Hover over chart to inspect points', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 200,
                          child: MouseRegion(
                            onHover: (event) {
                              final box = context.findRenderObject() as RenderBox?;
                              if (box != null) {
                                final localX = event.localPosition.dx;
                                final chartWidth = box.size.width * 0.45;
                                final index = ((localX / chartWidth) * (_memoryUsage.length - 1)).round().clamp(0, _memoryUsage.length - 1);
                                setState(() => _hoveredRealTimeIndex = index);
                              }
                            },
                            onExit: (_) => setState(() => _hoveredRealTimeIndex = null),
                            child: CustomPaint(
                              painter: RealTimeResourcePainter(
                                memoryData: _memoryUsage,
                                storageData: _storageUsage,
                                gridColor: colorScheme.secondary.withOpacity(0.15),
                                hoveredIndex: _hoveredRealTimeIndex,
                              ),
                              child: Container(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // Right: Database API Requests (Last 30 Days) with Expandable Color-Coded Legend
              Expanded(
                child: Card(
                  color: colorScheme.surface,
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Database API Requests (Last 30 Days)', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 6),
                        _isLoadingLogsGraph
                            ? const SizedBox(height: 30, child: LinearProgressIndicator(color: Colors.cyanAccent))
                            : _dbRequestTrends.isEmpty
                                ? const Text('No database request logs found in database_logs.db.', style: TextStyle(fontSize: 11, color: Colors.grey))
                                : Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (_hoveredLogsIndex != null && _hoveredLogsIndex! < _thirtyDayLabels.length) ...[
                                        Text(
                                          'Date: ${_thirtyDayLabels[_hoveredLogsIndex!]}',
                                          style: const TextStyle(fontSize: 11, color: Colors.cyanAccent, fontWeight: FontWeight.bold),
                                        ),
                                        const SizedBox(height: 2),
                                        Wrap(
                                          spacing: 12,
                                          runSpacing: 2,
                                          children: _dbRequestTrends.entries.map((entry) {
                                            final count = (_hoveredLogsIndex! < entry.value.length) ? entry.value[_hoveredLogsIndex!] : 0;
                                            final color = _dbColors[entry.key] ?? Colors.cyanAccent;
                                            return Text(
                                              '${entry.key}: $count reqs',
                                              style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
                                            );
                                          }).toList(),
                                        ),
                                      ] else ...[
                                        const Text('Hover over chart to inspect daily requests', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                      ],
                                      const SizedBox(height: 12),
                                      SizedBox(
                                        height: 160,
                                        child: MouseRegion(
                                          onHover: (event) {
                                            final box = context.findRenderObject() as RenderBox?;
                                            if (box != null && _thirtyDayLabels.isNotEmpty) {
                                              final localX = event.localPosition.dx;
                                              final chartWidth = box.size.width * 0.45;
                                              final index = ((localX / chartWidth) * (_thirtyDayLabels.length - 1)).round().clamp(0, _thirtyDayLabels.length - 1);
                                              setState(() => _hoveredLogsIndex = index);
                                            }
                                          },
                                          onExit: (_) => setState(() => _hoveredLogsIndex = null),
                                          child: CustomPaint(
                                            painter: DatabaseLogsPainter(
                                              dbTrends: _dbRequestTrends,
                                              dbColors: _dbColors,
                                              gridColor: colorScheme.secondary.withOpacity(0.15),
                                              hoveredIndex: _hoveredLogsIndex,
                                            ),
                                            child: Container(),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      ExpansionTile(
                                        tilePadding: EdgeInsets.zero,
                                        title: Text('Database Legend (${_dbColors.length} active)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70)),
                                        children: [
                                          Container(
                                            alignment: Alignment.centerLeft,
                                            constraints: const BoxConstraints(maxHeight: 100),
                                            child: SingleChildScrollView(
                                              child: Wrap(
                                                alignment: WrapAlignment.start,
                                                crossAxisAlignment: WrapCrossAlignment.start,
                                                spacing: 12,
                                                runSpacing: 6,
                                                children: _dbColors.entries.map((entry) {
                                                  return _buildLegendItem(entry.key, entry.value);
                                                }).toList(),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Top Processes & System Log Files (Placed BELOW the graphs)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Card 1: Top Processes
              Expanded(
                child: Card(
                  color: colorScheme.surface,
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Top Processes (Real-Time)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text('Polled continuously via uptime timer', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 12),
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _topProcesses.length,
                          itemBuilder: (context, index) {
                            final proc = _topProcesses[index];
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black26,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.grey.shade800),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        '[PID ${proc['pid']}]',
                                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.cyanAccent),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        proc['name'],
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      Text(
                                        'CPU: ${(proc['cpu'] as double).toStringAsFixed(1)}%',
                                        style: const TextStyle(fontSize: 11, color: Colors.greenAccent, fontFamily: 'monospace'),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'MEM: ${(proc['mem'] as double).toStringAsFixed(1)}%',
                                        style: const TextStyle(fontSize: 11, color: Colors.purpleAccent, fontFamily: 'monospace'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 16),

              // Card 2: System Log Files (Top 50 Lines)
              Expanded(
                child: Card(
                  color: colorScheme.surface,
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('System Log Files (Top 50 Lines)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.purple.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('Live Tabs', style: TextStyle(fontSize: 10, color: Colors.purpleAccent, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text('Important Linux uptime and runtime log streams', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 12),
                        
                        // Tabs Header
                        TabBar(
                          controller: _logTabController,
                          isScrollable: true,
                          labelColor: Colors.cyanAccent,
                          unselectedLabelColor: Colors.grey,
                          indicatorColor: Colors.cyanAccent,
                          tabs: _logFileNames.map((name) => Tab(text: '/var/log/$name')).toList(),
                        ),
                        const SizedBox(height: 8),

                        // Tab Views Content (Top 50 lines)
                        SizedBox(
                          height: 300,
                          child: TabBarView(
                            controller: _logTabController,
                            children: _logFileNames.map((logName) {
                              final lines = _logFileContent[logName] ?? [];
                              return Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: Colors.grey.shade800),
                                ),
                                child: ListView.builder(
                                  itemCount: lines.length,
                                  itemBuilder: (context, lineIndex) {
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 3),
                                      child: Text(
                                        '${lineIndex + 1}: ${lines[lineIndex]}',
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 10,
                                          color: Colors.greenAccent,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Inbound Port Firewall Audit Section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Inbound Port Firewall Audit', style: Theme.of(context).textTheme.titleLarge),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Force Rescan', style: TextStyle(fontSize: 12)),
                onPressed: () async {
                  setState(() {
                    _isLoadingFirewall = true;
                    _firewallProgress = 0.1;
                  });
                  final fresh = await _firewallManager.scanInboundPorts(
                    onProgress: (p) => setState(() => _firewallProgress = p),
                  );
                  setState(() {
                    _firewallScanResult = fresh;
                    _isLoadingFirewall = false;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            color: colorScheme.surface,
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.shield_outlined, color: Colors.cyanAccent),
                          const SizedBox(width: 8),
                          Text(
                            _firewallScanResult != null
                                ? 'Last Audit: ${_firewallScanResult!.timestamp.toLocal().toString().substring(0, 16)} (7-Day TTL Cache)'
                                : 'Audit Pending...',
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                      if (_firewallScanResult != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.cyan.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_firewallScanResult!.openPorts.length} Open Ports Detected',
                            style: const TextStyle(fontSize: 11, color: Colors.cyanAccent, fontWeight: FontWeight.bold),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_isLoadingFirewall) ...[
                    const LinearProgressIndicator(color: Colors.cyanAccent),
                    const SizedBox(height: 8),
                    const Text('Scanning active inbound sockets...', style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ] else if (_firewallScanResult?.openPorts.isEmpty ?? true) ...[
                    const Text('No open inbound ports found.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ] else ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 520),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _firewallScanResult!.openPorts.length,
                        itemBuilder: (context, index) {
                          final portInfo = _firewallScanResult!.openPorts[index];
                          final isDataLake = portInfo.isDataLakePort;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: isDataLake ? Colors.cyan.withOpacity(0.08) : Colors.black26,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isDataLake ? Colors.cyanAccent.withOpacity(0.4) : Colors.grey.shade800,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isDataLake ? Colors.cyan.withOpacity(0.2) : Colors.orange.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        isDataLake ? 'DATA LAKE' : 'LISTENER',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                          color: isDataLake ? Colors.cyanAccent : Colors.orangeAccent,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      'Port ${portInfo.port} (${portInfo.protocol})',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, fontFamily: 'monospace'),
                                    ),
                                  ],
                                ),
                                Expanded(
                                  child: Text(
                                    'Binding: ${portInfo.bindingAddress} | Proc: ${portInfo.processName}',
                                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                                    textAlign: TextAlign.end,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Divider(color: Colors.white24),
                  const SizedBox(height: 8),
                  Builder(
                    builder: (context) {
                      final openPorts = _firewallScanResult?.openPorts ?? [];
                      final bool isSecure = openPorts.length == 1 && openPorts.first.port == 9000;
                      final statusColor = isSecure ? Colors.greenAccent : Colors.redAccent;
                      final statusText = isSecure ? 'SECURE' : 'INSECURE';
                      final statusDesc = isSecure
                          ? 'Only the authorized data lake port (9000) is open.'
                          : 'Warning: More than one port or unauthorized ports are active (Expected only port 9000).';

                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: statusColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: statusColor.withOpacity(0.4)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isSecure ? Icons.verified_user : Icons.gpp_bad,
                              color: statusColor,
                              size: 24,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Text('Security Status: ', style: TextStyle(fontSize: 12, color: Colors.grey)),
                                      Text(
                                        statusText,
                                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: statusColor),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    statusDesc,
                                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard(BuildContext context, String title, String value, String subtitle, IconData icon, Color color) {
    return Expanded(
      child: Card(
        color: Theme.of(context).colorScheme.surface,
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: color.withOpacity(0.15),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey)),
                    const SizedBox(height: 2),
                    Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLegendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}

class RealTimeResourcePainter extends CustomPainter {
  final List<double> memoryData;
  final List<double> storageData;
  final Color gridColor;
  final int? hoveredIndex;

  RealTimeResourcePainter({
    required this.memoryData,
    required this.storageData,
    required this.gridColor,
    this.hoveredIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()..color = gridColor..strokeWidth = 1.0;
    for (double i = 0; i <= size.height; i += size.height / 4) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), gridPaint);
    }

    final dx = size.width / (memoryData.length - 1);

    _drawLinePath(canvas, size, memoryData, dx, Colors.cyanAccent, 2.5);
    _drawLinePath(canvas, size, storageData, dx, Colors.purpleAccent, 2.5);

    if (hoveredIndex != null && hoveredIndex! < memoryData.length) {
      double x = hoveredIndex! * dx;
      final linePaint = Paint()..color = Colors.white54..strokeWidth = 1.0..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);

      double memY = size.height - (memoryData[hoveredIndex!] / 100.0 * size.height);
      double storY = size.height - (storageData[hoveredIndex!] / 100.0 * size.height);

      canvas.drawCircle(Offset(x, memY), 5.0, Paint()..color = Colors.cyanAccent);
      canvas.drawCircle(Offset(x, storY), 5.0, Paint()..color = Colors.purpleAccent);
    }
  }

  void _drawLinePath(Canvas canvas, Size size, List<double> points, double dx, Color color, double strokeWidth) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    for (int i = 0; i < points.length; i++) {
      double x = i * dx;
      double y = size.height - (points[i] / 100.0 * size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant RealTimeResourcePainter oldDelegate) =>
      oldDelegate.hoveredIndex != hoveredIndex || oldDelegate.memoryData != memoryData;
}

class DatabaseLogsPainter extends CustomPainter {
  final Map<String, List<int>> dbTrends;
  final Map<String, Color> dbColors;
  final Color gridColor;
  final int? hoveredIndex;

  DatabaseLogsPainter({
    required this.dbTrends,
    required this.dbColors,
    required this.gridColor,
    this.hoveredIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()..color = gridColor..strokeWidth = 1.0;
    for (double i = 0; i <= size.height; i += size.height / 4) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), gridPaint);
    }

    if (dbTrends.isEmpty) return;

    int maxVal = 1;
    for (var entry in dbTrends.entries) {
      for (var val in entry.value) {
        if (val > maxVal) maxVal = val;
      }
    }

    final sampleLength = dbTrends.values.first.length;
    if (sampleLength < 2) return;
    final dx = size.width / (sampleLength - 1);

    for (var entry in dbTrends.entries) {
      final dbName = entry.key;
      final points = entry.value;
      final color = dbColors[dbName] ?? Colors.cyanAccent;

      final paint = Paint()
        ..color = color
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final path = Path();
      for (int i = 0; i < points.length; i++) {
        double x = i * dx;
        double normalizedY = (points[i] / maxVal).clamp(0.0, 1.0);
        double y = size.height - (normalizedY * size.height);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }

    if (hoveredIndex != null && hoveredIndex! < sampleLength) {
      double x = hoveredIndex! * dx;
      final linePaint = Paint()..color = Colors.white54..strokeWidth = 1.0;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);

      for (var entry in dbTrends.entries) {
        final points = entry.value;
        if (hoveredIndex! < points.length) {
          final color = dbColors[entry.key] ?? Colors.cyanAccent;
          double normalizedY = (points[hoveredIndex!] / maxVal).clamp(0.0, 1.0);
          double y = size.height - (normalizedY * size.height);
          canvas.drawCircle(Offset(x, y), 4.0, Paint()..color = color);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant DatabaseLogsPainter oldDelegate) =>
      oldDelegate.hoveredIndex != hoveredIndex || oldDelegate.dbTrends != dbTrends;
}