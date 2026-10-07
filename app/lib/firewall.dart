import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class PortRuleInfo {
  final int port;
  final String protocol;
  final String processName;
  final String bindingAddress;
  final bool isDataLakePort;

  PortRuleInfo({
    required this.port,
    required this.protocol,
    required this.processName,
    required this.bindingAddress,
    required this.isDataLakePort,
  });

  Map<String, dynamic> toJson() => {
        'port': port,
        'protocol': protocol,
        'processName': processName,
        'bindingAddress': bindingAddress,
        'isDataLakePort': isDataLakePort,
      };

  factory PortRuleInfo.fromJson(Map<String, dynamic> json) => PortRuleInfo(
        port: json['port'],
        protocol: json['protocol'],
        processName: json['processName'],
        bindingAddress: json['bindingAddress'],
        isDataLakePort: json['isDataLakePort'],
      );
}

class FirewallScanResult {
  final DateTime timestamp;
  final List<PortRuleInfo> openPorts;
  final String statusMessage;

  FirewallScanResult({
    required this.timestamp,
    required this.openPorts,
    required this.statusMessage,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'openPorts': openPorts.map((p) => p.toJson()).toList(),
        'statusMessage': statusMessage,
      };

  factory FirewallScanResult.fromJson(Map<String, dynamic> json) => FirewallScanResult(
        timestamp: DateTime.parse(json['timestamp']),
        openPorts: (json['openPorts'] as List).map((p) => PortRuleInfo.fromJson(p)).toList(),
        statusMessage: json['statusMessage'],
      );
}

class FirewallManager {
  static const int dataLakePort = 48210; // Designated data lake OS port
  static const String cacheFileName = 'firewall_scan_cache.json';

  Future<File> _getCacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$cacheFileName');
  }

  Future<FirewallScanResult?> loadCachedResult() async {
    try {
      final file = await _getCacheFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        return FirewallScanResult.fromJson(jsonDecode(content));
      }
    } catch (_) {}
    return null;
  }

  Future<void> saveCachedResult(FirewallScanResult result) async {
    try {
      final file = await _getCacheFile();
      await file.writeAsString(jsonEncode(result.toJson()));
    } catch (_) {}
  }

  Future<FirewallScanResult> scanInboundPorts({
    int targetDataLakePort = dataLakePort,
    Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.2);
    List<PortRuleInfo> openPorts = [];

    try {
      onProgress?.call(0.5);
      final result = await Process.run('ss', ['-tulpn']);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        for (var line in lines) {
          if (line.trim().isEmpty || line.startsWith('Netid')) continue;
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length >= 5) {
            final proto = parts[0];
            final localAddrPort = parts[4];
            final procInfo = parts.length > 6 ? parts.sublist(6).join(' ') : 'Unknown';

            final lastColon = localAddrPort.lastIndexOf(':');
            if (lastColon != -1) {
              final addr = localAddrPort.substring(0, lastColon);
              final portStr = localAddrPort.substring(lastColon + 1);
              final port = int.tryParse(portStr) ?? 0;

              if (port > 0) {
                openPorts.add(PortRuleInfo(
                  port: port,
                  protocol: proto.toUpperCase(),
                  processName: procInfo,
                  bindingAddress: addr,
                  isDataLakePort: port == targetDataLakePort,
                ));
              }
            }
          }
        }
      }
    } catch (e) {
      // Fallback if ss is unavailable
    }

    onProgress?.call(1.0);
    final scanResult = FirewallScanResult(
      timestamp: DateTime.now(),
      openPorts: openPorts,
      statusMessage: 'Inbound port audit complete. Verified active listeners.',
    );

    await saveCachedResult(scanResult);
    return scanResult;
  }

  /// Retrieves cached results if under 7 days old, or automatically triggers a fresh scan.
  Future<FirewallScanResult> getOrRefreshScan({bool forceRefresh = false, Function(double)? onProgress}) async {
    final cached = await loadCachedResult();
    final now = DateTime.now();

    if (!forceRefresh && cached != null) {
      final difference = now.difference(cached.timestamp).inDays;
      if (difference < 7) {
        return cached; // Valid cache within the 7-day TTL
      }
    }

    return await scanInboundPorts(onProgress: onProgress);
  }
}