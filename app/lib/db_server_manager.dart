import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'; // Required for rootBundle
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

class LocalDatabaseServerInfo {
  final String dbName;
  final String filePath;
  final int port;
  final String domainUrl;
  final String networkUrl;
  bool isUp;
  int activeSessions;
  int totalQueries;

  LocalDatabaseServerInfo({
    required this.dbName,
    required this.filePath,
    required this.port,
    required this.domainUrl,
    required this.networkUrl,
    this.isUp = true,
    this.activeSessions = 0,
    this.totalQueries = 0,
  });
}

class DbServerManager {
  static final DbServerManager _instance = DbServerManager._internal();
  factory DbServerManager() => _instance;
  DbServerManager._internal();

  HttpServer? _masterServer;
  final Map<String, LocalDatabaseServerInfo> _serversInfo = {};
  final ValueNotifier<int> totalActiveConnectionsNotifier = ValueNotifier<int>(0);

  Timer? _healthCheckTimer;
  Directory? _dbDirectory;
  int _serverPort = 9000;
  String _boundIpAddress = '127.0.0.1';

  // JWT Security State
  String _currentJwtToken = '';
  String _jwtSecretKey = '';

  Map<String, LocalDatabaseServerInfo> get serversInfo => Map.unmodifiable(_serversInfo);
  int get serverPort => _serverPort;
  String get domainUrl => 'https://lakelady.ldlx:$_serverPort';
  String get boundIpAddress => _boundIpAddress;
  String get currentJwtToken => _currentJwtToken;

  Future<void> initialize({int port = 9000}) async {
    _serverPort = port;
    final appDir = await getApplicationDocumentsDirectory();
    _dbDirectory = Directory(p.join(appDir.path, 'ldlx_dbs'));

    if (!await _dbDirectory!.exists()) {
      await _dbDirectory!.create(recursive: true);
    }

    // Resolve the actual local device IP address or fallback safely
    _boundIpAddress = await _getLocalDeviceIp();

    // Generate initial JWT secret and token
    _rotateJwtToken();

    await scanAndStartServers();
    await _startMasterServer();

    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      scanAndStartServers();
      _checkServersHealth();
    });
  }

  /// Generates a fresh cryptographic JWT token and invalidates prior tokens
  String _rotateJwtToken() {
    final randomVals = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    _jwtSecretKey = base64UrlEncode(randomVals);
    
    final header = base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
    final payloadMap = {
      'iss': 'ldlx-data-lake-server',
      'iat': DateTime.now().millisecondsSinceEpoch,
      'scope': 'full_admin_access'
    };
    final payload = base64Url.encode(utf8.encode(jsonEncode(payloadMap)));
    
    _currentJwtToken = '$header.$payload.$_jwtSecretKey';
    return _currentJwtToken;
  }

  String regenerateAuthToken() {
    return _rotateJwtToken();
  }

  bool _validateJwtToken(HttpRequest request) {
    if (request.connectionInfo?.remoteAddress.isLoopback == true) {
      return true;
    }

    final authHeader = request.headers.value('Authorization') ?? request.headers.value('authorization');
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return false;
    }

    final token = authHeader.substring(7).trim();
    return token == _currentJwtToken;
  }

  Future<String> _getLocalDeviceIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            if (addr.address.startsWith('192.') ||
                addr.address.startsWith('10.') ||
                addr.address.startsWith('172.')) {
              return addr.address;
            }
          }
        }
      }

      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    
    return InternetAddress.loopbackIPv4.address;
  }

  Future<void> scanAndStartServers() async {
    if (_dbDirectory == null) return;

    final List<FileSystemEntity> entities = await _dbDirectory!.list().toList();
    Set<String> currentDbFiles = {};

    for (var entity in entities) {
      if (entity is File) {
        final filename = p.basename(entity.path);

        if (filename.toLowerCase() == 'approve.db' ||
            filename.toLowerCase() == 'database_logs.db' ||
            filename.toLowerCase() == 'comments.db' ||
            filename.endsWith('.lock') ||
            filename.endsWith('.tmp') ||
            filename.endsWith('.pem')) {
          continue;
        }

        final dbName = p.basenameWithoutExtension(filename);
        currentDbFiles.add(dbName);

        if (!_serversInfo.containsKey(dbName)) {
          _serversInfo[dbName] = LocalDatabaseServerInfo(
            dbName: dbName,
            filePath: entity.path,
            port: _serverPort,
            domainUrl: 'https://lakelady.ldlx:$_serverPort',
            networkUrl: 'https://$_boundIpAddress:$_serverPort',
            isUp: true,
          );
        } else {
          final existing = _serversInfo[dbName]!;
          _serversInfo[dbName] = LocalDatabaseServerInfo(
            dbName: existing.dbName,
            filePath: entity.path,
            port: _serverPort,
            domainUrl: existing.domainUrl,
            networkUrl: 'https://$_boundIpAddress:$_serverPort',
            isUp: existing.isUp,
            activeSessions: existing.activeSessions,
            totalQueries: existing.totalQueries,
          );
        }
      }
    }

    _serversInfo.removeWhere((name, _) => !currentDbFiles.contains(name));
    _updateGlobalConnections();
  }

  /// Helper method to record API request logs into Sembast database_logs.db
  Future<void> _logApiRequest(HttpRequest request, int statusCode, String? dbName) async {
    try {
      if (_dbDirectory == null) return;
      final dbPath = p.join(_dbDirectory!.path, 'database_logs.db');
      final db = await databaseFactoryIo.openDatabase(dbPath);
      final store = intMapStoreFactory.store('api_logs');

      await store.add(db, {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'iso_time': DateTime.now().toIso8601String(),
        'method': request.method,
        'path': request.uri.path,
        'query_parameters': request.uri.queryParameters,
        'status_code': statusCode,
        'remote_address': request.connectionInfo?.remoteAddress.address ?? 'unknown',
        'database_target': dbName ?? 'none',
      });
      await db.close();
    } catch (e) {
      if (kDebugMode) {
        print('Error recording API request log: $e');
      }
    }
  }

  Future<void> _startMasterServer() async {
    if (_masterServer != null) return;

    try {
      // Load SSL Certificate and Private Key from updated Flutter Assets paths
      final certData = await rootBundle.load('assets/cert.pem');
      final keyData = await rootBundle.load('assets/key.pem');

      final securityContext = SecurityContext()
        ..useCertificateChainBytes(certData.buffer.asUint8List())
        ..usePrivateKeyBytes(keyData.buffer.asUint8List());

      final bindAddress = InternetAddress(_boundIpAddress);
      
      // Bind securely using HttpServer.bindSecure
      _masterServer = await HttpServer.bindSecure(
        bindAddress, 
        _serverPort,
        securityContext,
      );

      _masterServer!.listen((HttpRequest request) async {
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
        request.response.headers.add('Access-Control-Allow-Headers', 'Origin, Content-Type, Authorization, X-LDLx-Internal, X-Database-Name');

        if (request.method == 'OPTIONS') {
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
          return;
        }

        final isInternalCall = request.headers.value('X-LDLx-Internal') == 'true' ||
            request.connectionInfo?.remoteAddress.isLoopback == true;

        final targetDbName = request.headers.value('X-Database-Name') ?? request.headers.value('x-database-name');
        LocalDatabaseServerInfo? info;

        if (targetDbName != null && targetDbName.trim().isNotEmpty) {
          info = _serversInfo[targetDbName.trim()];
        }

        if (info != null) {
          info.activeSessions++;
          info.totalQueries++;
          _updateGlobalConnections();
        }

        try {
          final uri = request.uri;

          if (uri.path == '/health') {
            _sendJsonResponse(request, HttpStatus.ok, {
              'status': 'UP',
              'protocol': 'HTTPS',
              'server': 'LDLx Unified Data Lake REST Server',
              'bound_ip': _boundIpAddress,
              'domain': 'lakelady.ldlx',
              'port': _serverPort,
              'target_database': info?.dbName ?? 'None Specified',
              'available_databases': _serversInfo.keys.toList(),
              'authenticated': _validateJwtToken(request),
            });
          } else if (uri.path == '/api/auth/token' && request.method == 'POST') {
            final newToken = _rotateJwtToken();
            _sendJsonResponse(request, HttpStatus.ok, {
              'status': 'TOKEN_ROTATED',
              'message': 'All previous tokens have been expired successfully.',
              'token': newToken,
            });
          } else if (uri.path.startsWith('/api/data')) {
            if (!_validateJwtToken(request)) {
              _sendJsonResponse(request, HttpStatus.unauthorized, {
                'error': 'Unauthorized: Invalid or expired JWT Bearer token.',
              });
            } else if (info == null) {
              _sendJsonResponse(request, HttpStatus.badRequest, {
                'error': "Missing or invalid 'X-Database-Name' request header",
                'available_databases': _serversInfo.keys.toList(),
              });
            } else {
              await _handleCrudApiRequest(request, info.filePath, isInternalCall, info.dbName);
            }
          } else {
            _sendJsonResponse(request, HttpStatus.ok, {
              'message': 'LDLx Secure Data Lake Server Root',
              'bound_ip': _boundIpAddress,
              'domain': 'https://lakelady.ldlx:$_serverPort',
              'endpoints': ['/health', '/api/auth/token', '/api/data'],
              'usage': "Include header 'Authorization: Bearer <jwt_token>' and 'X-Database-Name: <database_name>'",
              'available_databases': _serversInfo.keys.toList(),
            });
          }
        } catch (e) {
          _sendJsonResponse(request, HttpStatus.internalServerError, {'error': e.toString()});
        } finally {
          await request.response.close();
          // Record API request in sembast database_logs.db
          await _logApiRequest(request, request.response.statusCode, info?.dbName);

          if (info != null) {
            info.activeSessions = (info.activeSessions - 1).clamp(0, 9999);
            _updateGlobalConnections();
          }
        }
      });
    } catch (e) {
      if (kDebugMode) {
        print('Error starting secure data lake master server: $e');
      }
    }
  }

  Future<void> _handleCrudApiRequest(
      HttpRequest request, String filePath, bool isInternalCall, String dbName) async {
    final file = File(filePath);
    Map<String, dynamic> dbData = {};

    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        dbData = jsonDecode(content.isEmpty ? '{}' : content);
      } catch (_) {
        dbData = {'raw': 'Non-JSON file content'};
      }
    }

    switch (request.method) {
      case 'GET':
        final queryParams = request.uri.queryParameters;
        final targetTable = queryParams['table'];
        final searchField = queryParams['field'] ?? queryParams['column'] ?? queryParams['key'];
        final searchValue = queryParams['value'];

        if (searchField == null || searchValue == null) {
          _sendJsonResponse(request, HttpStatus.ok, {
            'database': dbName,
            'internalAccess': isInternalCall,
            'data': dbData,
          });
          break;
        }

        dynamic foundMatch;

        if (dbData.containsKey('tables')) {
          final tables = dbData['tables'] as Map<String, dynamic>;
          final tableName = targetTable ?? tables.keys.first;
          if (tables.containsKey(tableName)) {
            final rows = tables[tableName]['rows'] as List;
            try {
              foundMatch = rows.firstWhere(
                (row) => row is Map && row[searchField]?.toString() == searchValue,
              );
            } catch (_) {}
          }
        } else if (dbData.containsKey('documents')) {
          final docs = dbData['documents'] as List;
          try {
            foundMatch = docs.firstWhere(
              (doc) => doc is Map && doc[searchField]?.toString() == searchValue,
            );
          } catch (_) {}
        } else {
          if (dbData.containsKey(searchField) && dbData[searchField].toString() == searchValue) {
            foundMatch = dbData;
          } else if (dbData.containsKey('custom_entries')) {
            final entries = dbData['custom_entries'] as List;
            try {
              foundMatch = entries.firstWhere(
                (entry) => entry is Map && entry[searchField]?.toString() == searchValue,
              );
            } catch (_) {}
          }
        }

        if (foundMatch != null) {
          _sendJsonResponse(request, HttpStatus.ok, {
            'database': dbName,
            'query': {searchField: searchValue},
            'match': foundMatch,
          });
        } else {
          _sendJsonResponse(request, HttpStatus.notFound, {
            'error': 'Entry not found',
            'database': dbName,
            'query': {searchField: searchValue},
          });
        }
        break;

      case 'POST':
        final bodyText = await utf8.decoder.bind(request).join();
        final bodyJson = jsonDecode(bodyText.isEmpty ? '{}' : bodyText);

        if (dbData.containsKey('tables')) {
          final tables = dbData['tables'] as Map<String, dynamic>;
          final firstTable = tables.keys.first;
          (tables[firstTable]['rows'] as List).add(bodyJson);
        } else if (dbData.containsKey('documents')) {
          (dbData['documents'] as List).add(bodyJson);
        } else {
          dbData['custom_entries'] ??= [];
          (dbData['custom_entries'] as List).add(bodyJson);
        }

        await file.writeAsString(const JsonEncoder.withIndent('  ').convert(dbData));
        _sendJsonResponse(request, HttpStatus.created, {
          'status': 'CREATED',
          'database': dbName,
          'inserted': bodyJson,
        });
        break;

      case 'PUT':
        final bodyText = await utf8.decoder.bind(request).join();
        final bodyJson = jsonDecode(bodyText.isEmpty ? '{}' : bodyText);

        dbData['last_updated_by'] = isInternalCall ? 'IT_Dev_Troubleshooter' : 'Network_API_User';
        dbData['last_updated_time'] = DateTime.now().toIso8601String();
        dbData['override_data'] = bodyJson;

        await file.writeAsString(const JsonEncoder.withIndent('  ').convert(dbData));
        _sendJsonResponse(request, HttpStatus.ok, {
          'status': 'UPDATED',
          'database': dbName,
          'data': dbData,
        });
        break;

      case 'DELETE':
        if (dbData.containsKey('tables')) {
          final tables = dbData['tables'] as Map<String, dynamic>;
          final firstTable = tables.keys.first;
          if ((tables[firstTable]['rows'] as List).isNotEmpty) {
            (tables[firstTable]['rows'] as List).removeLast();
          }
        } else if (dbData.containsKey('documents') && (dbData['documents'] as List).isNotEmpty) {
          (dbData['documents'] as List).removeLast();
        }

        await file.writeAsString(const JsonEncoder.withIndent('  ').convert(dbData));
        _sendJsonResponse(request, HttpStatus.ok, {
          'status': 'DELETED_LAST_RECORD',
          'database': dbName,
        });
        break;

      default:
        _sendJsonResponse(request, HttpStatus.methodNotAllowed, {'error': 'Method not allowed'});
    }
  }

  Future<void> _sendJsonResponse(HttpRequest request, int statusCode, Map<String, dynamic> jsonMap) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(jsonMap));
    return Future.value();
  }

  Future<void> _checkServersHealth() async {
    for (var info in _serversInfo.values) {
      final file = File(info.filePath);
      info.isUp = _masterServer != null && await file.exists();
    }
    _updateGlobalConnections();
  }

  void _updateGlobalConnections() {
    int total = _serversInfo.values.fold(0, (sum, server) => sum + server.activeSessions);
    totalActiveConnectionsNotifier.value = total;
  }

  void dispose() {
    _healthCheckTimer?.cancel();
    _masterServer?.close(force: true);
    _masterServer = null;
    _serversInfo.clear();
  }
}