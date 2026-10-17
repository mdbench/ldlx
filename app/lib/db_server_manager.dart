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
import 'db_service.dart';

class LocalDatabaseServerInfo {
  final String dbName;
  final String filePath;
  final int port;
  final String domainUrl;
  final String networkUrl;
  bool isUp;
  int activeSessions;
  int totalQueries;
  String jwtToken;
  String jwtSecretKey;

  LocalDatabaseServerInfo({
    required this.dbName,
    required this.filePath,
    required this.port,
    required this.domainUrl,
    required this.networkUrl,
    this.isUp = true,
    this.activeSessions = 0,
    this.totalQueries = 0,
    this.jwtToken = '',
    this.jwtSecretKey = '',
  });
}

class DbServerManager {
  static final DbServerManager _instance = DbServerManager._internal();
  factory DbServerManager() => _instance;
  DbServerManager._internal();

  HttpServer? _masterServer;
  HttpServer? _adminPanelServer; // Separate internal server instance on port 9001
  final Map<String, LocalDatabaseServerInfo> _serversInfo = {};
  final ValueNotifier<int> totalActiveConnectionsNotifier = ValueNotifier<int>(0);

  Timer? _healthCheckTimer;
  Directory? _dbDirectory;
  int _serverPort = 9000;
  int _adminPanelPort = 9001; // Dedicated isolated admin port
  String _boundIpAddress = '127.0.0.1';

  // Admin Web Panel State & Security (with auto-logout expiration tracking)
  final List<String> _validFingerprints = [];
  final Map<String, List<DateTime>> _ipLoginAttempts = {};
  final Map<String, Map<String, dynamic>> _activeAdminSessions = {}; // Session Token -> {username, expires_at}

  Map<String, LocalDatabaseServerInfo> get serversInfo => Map.unmodifiable(_serversInfo);
  int get serverPort => _serverPort;
  int get adminPanelPort => _adminPanelPort;
  String get domainUrl => 'https://lakelady.ldlx:$_serverPort';
  String get boundIpAddress => _boundIpAddress;

  Future<void> initialize({int port = 9000, int adminPort = 9001}) async {
    _serverPort = port;
    _adminPanelPort = adminPort;
    final appDir = await getApplicationDocumentsDirectory();
    _dbDirectory = Directory(p.join(appDir.path, 'ldlx_dbs'));

    if (!await _dbDirectory!.exists()) {
      await _dbDirectory!.create(recursive: true);
    }

    _boundIpAddress = await _getLocalDeviceIp();

    await scanAndStartServers();
    await _startMasterServer();
    await _startAdminPanelServer(); // Start isolated admin server on port 9001

    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      scanAndStartServers();
      _checkServersHealth();
    });
  }

  Future<Map<String, String>> _loadOrInitJwtForDb(String dbPath) async {
    final jwtFile = File('$dbPath.jwt');
    if (await jwtFile.exists()) {
      try {
        final content = await jwtFile.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        final token = map['token'] as String?;
        final secret = map['secretKey'] as String?;
        if (token != null && secret != null && token.isNotEmpty && secret.isNotEmpty) {
          return {'token': token, 'secretKey': secret};
        }
      } catch (_) {}
    }
    return await _createNewJwtForDb(dbPath);
  }

  Future<Map<String, String>> _createNewJwtForDb(String dbPath) async {
    final randomVals = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final secretKey = base64UrlEncode(randomVals);

    final header = base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
    final payloadMap = {
      'iss': 'ldlx-data-lake-server',
      'iat': DateTime.now().millisecondsSinceEpoch,
      'scope': 'full_admin_access'
    };
    final payload = base64Url.encode(utf8.encode(jsonEncode(payloadMap)));

    final token = '$header.$payload.$secretKey';

    final jwtFile = File('$dbPath.jwt');
    await jwtFile.writeAsString(jsonEncode({
      'token': token,
      'secretKey': secretKey,
      'created_at': DateTime.now().toIso8601String(),
    }));

    return {'token': token, 'secretKey': secretKey};
  }

  Future<String> regenerateAuthToken(String dbName) async {
    final serverInfo = _serversInfo[dbName];
    if (serverInfo == null) throw Exception('Database $dbName not found');

    final newCreds = await _createNewJwtForDb(serverInfo.filePath);
    serverInfo.jwtToken = newCreds['token']!;
    serverInfo.jwtSecretKey = newCreds['secretKey']!;
    return newCreds['token']!;
  }

  bool _validateJwtToken(HttpRequest request, LocalDatabaseServerInfo? targetServer) {
    if (request.connectionInfo?.remoteAddress.isLoopback == true) {
      return true;
    }

    final authHeader = request.headers.value('Authorization') ?? request.headers.value('authorization');
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return false;
    }

    final token = authHeader.substring(7).trim();

    if (targetServer != null) {
      return token == targetServer.jwtToken;
    }

    for (var server in _serversInfo.values) {
      if (token == server.jwtToken) {
        return true;
      }
    }

    return false;
  }

  bool _isRateLimited(String ipAddress) {
    final now = DateTime.now();
    _ipLoginAttempts.putIfAbsent(ipAddress, () => []);
    
    // Prune entries older than 5 minutes
    _ipLoginAttempts[ipAddress]!.removeWhere(
      (timestamp) => now.difference(timestamp).inMinutes >= 5,
    );

    return _ipLoginAttempts[ipAddress]!.length >= 5;
  }

  void _recordLoginAttempt(String ipAddress) {
    _ipLoginAttempts.putIfAbsent(ipAddress, () => []);
    _ipLoginAttempts[ipAddress]!.add(DateTime.now());
  }

  Future<void> _logFailedAttemptToFile(String ip, String username, String reason) async {
    try {
      if (_dbDirectory == null) return;
      final logFile = File(p.join(_dbDirectory!.path, 'failed_login_attempts.log'));
      final entry = '[${DateTime.now().toIso8601String()}] IP: $ip | User: $username | Reason: $reason\n';
      await logFile.writeAsString(entry, mode: FileMode.append);
    } catch (_) {}
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
            filename.endsWith('.pem') ||
            filename.endsWith('.jwt') ||
            filename.endsWith('.log') ||
            filename.endsWith('.txt') ||
            filename.endsWith('.env')) {
          continue;
        }

        final dbName = p.basenameWithoutExtension(filename);
        currentDbFiles.add(dbName);

        final jwtCreds = await _loadOrInitJwtForDb(entity.path);

        if (!_serversInfo.containsKey(dbName)) {
          _serversInfo[dbName] = LocalDatabaseServerInfo(
            dbName: dbName,
            filePath: entity.path,
            port: _serverPort,
            domainUrl: 'https://lakelady.ldlx:$_serverPort',
            networkUrl: 'https://$_boundIpAddress:$_serverPort',
            isUp: true,
            jwtToken: jwtCreds['token']!,
            jwtSecretKey: jwtCreds['secretKey']!,
          );
        } else {
          final existing = _serversInfo[dbName]!;
          existing.isUp = true;
          existing.jwtToken = jwtCreds['token']!;
          existing.jwtSecretKey = jwtCreds['secretKey']!;
        }
      }
    }

    _serversInfo.removeWhere((name, _) => !currentDbFiles.contains(name));
    _updateGlobalConnections();
  }

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

  /// Starts the separate isolated admin panel server on port 9001 (not exposed via public Cloudflare Tunnel)
  Future<void> _startAdminPanelServer() async {
    if (_adminPanelServer != null) return;

    try {
      final certData = await rootBundle.load('assets/cert.pem');
      final keyData = await rootBundle.load('assets/key.pem');

      final securityContext = SecurityContext()
        ..useCertificateChainBytes(certData.buffer.asUint8List())
        ..usePrivateKeyBytes(keyData.buffer.asUint8List());

      //final bindAddress = InternetAddress(_boundIpAddress);
      final bindAddress = InternetAddress.anyIPv4;

      _adminPanelServer = await HttpServer.bindSecure(
        bindAddress,
        _adminPanelPort,
        securityContext,
      );

      _adminPanelServer!.listen((HttpRequest request) async {
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        request.response.headers.add('Access-Control-Allow-Headers', 'Origin, Content-Type, Authorization, X-Browser-Fingerprint');

        if (request.method == 'OPTIONS') {
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
          return;
        }

        final clientIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
        final uri = request.uri;

        try {
          // Serve Fingerprint2.min.js script on isolated admin server
          if (uri.path == '/assets/fingerprint2.min.js') {
            final jsContent = await rootBundle.loadString('assets/fingerprint2.min.js');
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType('application', 'javascript', charset: 'utf-8')
              ..write(jsContent);
            await request.response.close();
            return;
          }

          // Admin Logout Route
          if (uri.path == '/admin/api/logout' && request.method == 'POST') {
            final cookieHeader = request.headers.value('Cookie') ?? '';
            for (var cookie in cookieHeader.split(';')) {
              final parts = cookie.trim().split('=');
              if (parts.length == 2 && parts[0] == 'admin_session') {
                _activeAdminSessions.remove(parts[1]);
              }
            }
            request.response.headers.add('Set-Cookie', 'admin_session=; Path=/admin; Max-Age=0; HttpOnly; Secure; SameSite=Strict');
            _sendJsonResponse(request, HttpStatus.ok, {'status': 'LOGGED_OUT'});
            await request.response.close();
            return;
          }

          // Admin API Route to push strings securely to pushed_strings.txt in the database directory
          if (uri.path == '/admin/api/push-string' && request.method == 'POST') {
            try {
              final bodyText = await utf8.decoder.bind(request).join();
              final body = jsonDecode(bodyText.isEmpty ? '{}' : bodyText);
              final String stringLine = body['line']?.toString() ?? '';
              
              if (_dbDirectory == null) {
                _sendJsonResponse(request, HttpStatus.internalServerError, {
                  'error': 'Database directory not initialized'
                });
                await request.response.close();
                return;
              }

              // Fixed path locked to pushed_strings.txt inside the database directory
              final String targetFilePath = p.join(_dbDirectory!.path, 'pushed_strings.txt');

              if (stringLine.isNotEmpty) {
                final file = File(targetFilePath);
                await file.parent.create(recursive: true);
                await file.writeAsString('$stringLine\n', mode: FileMode.append);
                _sendJsonResponse(request, HttpStatus.ok, {
                  'status': 'SUCCESS',
                  'message': 'String line pushed successfully',
                  'path': targetFilePath
                });
              } else {
                _sendJsonResponse(request, HttpStatus.badRequest, {
                  'error': 'Missing "line" field in request payload'
                });
              }
            } catch (e) {
              _sendJsonResponse(request, HttpStatus.internalServerError, {'error': e.toString()});
            }
            await request.response.close();
            return;
          }

          // Admin Login API Route
          if (uri.path == '/admin/api/login' && request.method == 'POST') {
            if (_isRateLimited(clientIp)) {
              _sendJsonResponse(request, HttpStatus.tooManyRequests, {
                'error': 'Rate limit exceeded. Maximum 5 login attempts per 5 minutes. Please wait before trying again.',
              });
              await request.response.close();
              return;
            }

            _recordLoginAttempt(clientIp);

            final bodyText = await utf8.decoder.bind(request).join();
            final body = jsonDecode(bodyText.isEmpty ? '{}' : bodyText);

            final username = body['username']?.toString().trim() ?? '';
            final password = body['password']?.toString().trim() ?? '';
            final totpCode = body['totp']?.toString().trim() ?? '';
            final fingerprint = body['fingerprint']?.toString().trim() ?? '';

            final user = await DbService().authenticate(username, password);

            if (user == null || user.role.toLowerCase() != 'admin') {
              await _logFailedAttemptToFile(clientIp, username, 'Invalid credentials or non-admin role');
              await DbService().logFailedLogin(ip: clientIp, username: username, password: '[Admin Port Web Failure]');
              _sendJsonResponse(request, HttpStatus.unauthorized, {
                'error': 'Authentication failed. Valid Admin credentials are required.',
              });
              await request.response.close();
              return;
            }

            if (user.isTotpEnabled) {
              final isTotpValid = await DbService().verifyTotp(user, totpCode);
              if (!isTotpValid) {
                await _logFailedAttemptToFile(clientIp, username, 'Invalid TOTP code');
                await DbService().logFailedLogin(ip: clientIp, username: username, password: '[TOTP Admin Port Failure]');
                _sendJsonResponse(request, HttpStatus.unauthorized, {
                  'error': 'Invalid 2FA TOTP authentication code.',
                  'requires_totp': true,
                });
                await request.response.close();
                return;
              }
            }

            if (fingerprint.isNotEmpty) {
              _validFingerprints.add(fingerprint);
            }

            final sessionToken = base64UrlEncode(List<int>.generate(24, (_) => Random.secure().nextInt(256)));
            
            // Set 5-minute auto-logout expiration time
            final expiresAt = DateTime.now().add(const Duration(minutes: 5));
            _activeAdminSessions[sessionToken] = {
              'username': user.username,
              'expires_at': expiresAt,
            };

            await DbService().logActivity(
              username: user.username,
              action: 'Isolated Admin Login',
              details: 'Admin logged into Port 9001 Admin Portal from IP: $clientIp',
            );

            request.response.headers.add('Set-Cookie', 'admin_session=$sessionToken; Path=/admin; HttpOnly; Secure; SameSite=Strict');
            if (fingerprint.isNotEmpty) {
              request.response.headers.add('Set-Cookie', 'ta=$fingerprint; Path=/admin; Secure; SameSite=Strict');
            }

            _sendJsonResponse(request, HttpStatus.ok, {
              'status': 'SUCCESS',
              'session_token': sessionToken,
              'username': user.username,
            });
            await request.response.close();
            return;
          }

          // Admin Panel Main Route (with automatic 5-minute inactivity/expiry check)
          if (uri.path.startsWith('/admin')) {
            final cookieHeader = request.headers.value('Cookie') ?? '';
            String sessionToken = '';
            String requestFingerprint = request.headers.value('X-Browser-Fingerprint') ?? '';

            for (var cookie in cookieHeader.split(';')) {
              final parts = cookie.trim().split('=');
              if (parts.length == 2) {
                if (parts[0] == 'admin_session') sessionToken = parts[1];
                if (parts[0] == 'ta' && requestFingerprint.isEmpty) requestFingerprint = parts[1];
              }
            }

            bool isAuthenticatedSession = false;
            String sessionUsername = '';

            if (sessionToken.isNotEmpty && _activeAdminSessions.containsKey(sessionToken)) {
              final sessionData = _activeAdminSessions[sessionToken]!;
              final DateTime expiresAt = sessionData['expires_at'];
              
              if (DateTime.now().isBefore(expiresAt)) {
                // Refresh session window upon activity (sliding 5-minute expiration)
                sessionData['expires_at'] = DateTime.now().add(const Duration(minutes: 5));
                isAuthenticatedSession = true;
                sessionUsername = sessionData['username'];
              } else {
                // Expired after 5 minutes
                _activeAdminSessions.remove(sessionToken);
              }
            }

            final isValidFingerprint = requestFingerprint.isNotEmpty && _validFingerprints.contains(requestFingerprint);

            if (!isAuthenticatedSession || !isValidFingerprint) {
              _sendHtmlResponse(request, HttpStatus.ok, _buildAdminLoginPageHtml());
            } else {
              _sendHtmlResponse(request, HttpStatus.ok, _buildAdminDashboardPageHtml(sessionUsername));
            }
            await request.response.close();
            return;
          }

          // Default fallback on port 9001
          _sendJsonResponse(request, HttpStatus.ok, {
            'message': 'LDLx Isolated Admin Security Server (Port 9001)',
            'admin_panel': 'https://$_boundIpAddress:$_adminPanelPort/admin',
          });
        } catch (e) {
          _sendJsonResponse(request, HttpStatus.internalServerError, {'error': e.toString()});
        } finally {
          await request.response.close();
        }
      });
    } catch (e) {
      if (kDebugMode) {
        print('Error starting isolated admin panel server on port 9001: $e');
      }
    }
  }

  Future<void> _startMasterServer() async {
    if (_masterServer != null) return;

    try {
      final certData = await rootBundle.load('assets/cert.pem');
      final keyData = await rootBundle.load('assets/key.pem');

      final securityContext = SecurityContext()
        ..useCertificateChainBytes(certData.buffer.asUint8List())
        ..usePrivateKeyBytes(keyData.buffer.asUint8List());

      final bindAddress = InternetAddress(_boundIpAddress);

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
              'server': 'LDLx Unified Data Lake REST Server (Public Tunnel Route)',
              'bound_ip': _boundIpAddress,
              'domain': 'lakelady.ldlx',
              'port': _serverPort,
              'target_database': info?.dbName ?? 'None Specified',
              'available_databases': _serversInfo.keys.toList(),
              'authenticated': _validateJwtToken(request, info),
            });
          } else if (uri.path == '/api/auth/token' && request.method == 'POST') {
            if (info == null) {
              _sendJsonResponse(request, HttpStatus.badRequest, {
                'error': "Missing or invalid 'X-Database-Name' request header for token rotation",
                'available_databases': _serversInfo.keys.toList(),
              });
            } else {
              final newToken = await regenerateAuthToken(info.dbName);
              _sendJsonResponse(request, HttpStatus.ok, {
                'status': 'TOKEN_ROTATED',
                'database': info.dbName,
                'message': 'Previous token for database has been expired successfully.',
                'token': newToken,
              });
            }
          } else if (uri.path.startsWith('/api/data')) {
            if (!_validateJwtToken(request, info)) {
              _sendJsonResponse(request, HttpStatus.unauthorized, {
                'error': 'Unauthorized: Invalid or expired JWT Bearer token for requested database.',
              });
            } else if (info == null) {
              _sendJsonResponse(request, HttpStatus.badRequest, {
                'error': "Missing or invalid 'X-Database-Name' request header",
                'available_databases': _serversInfo.keys.toList(),
              });
            } else {
              final isInternalCall = request.headers.value('X-LDLx-Internal') == 'true' ||
                  request.connectionInfo?.remoteAddress.isLoopback == true;
              await _handleCrudApiRequest(request, info.filePath, isInternalCall, info.dbName);
            }
          } else {
            _sendJsonResponse(request, HttpStatus.ok, {
              'message': 'LDLx Secure Data Lake Server Root (Public Tunnel)',
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
          await _logApiRequest(request, request.response.statusCode, info?.dbName);

          if (info != null) {
            info.activeSessions = (info.activeSessions - 1).clamp(0, 9999);
            _updateGlobalConnections();
          }
        }
      });
    } catch (e) {
      if (kDebugMode) {
        print('Error starting master server on port 9000: $e');
      }
    }
  }

  void _sendHtmlResponse(HttpRequest request, int statusCode, String htmlContent) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.html
      ..write(htmlContent);
  }

  void _sendJsonResponse(HttpRequest request, int statusCode, Map<String, dynamic> jsonMap) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(jsonMap));
  }

  String _buildAdminLoginPageHtml() {
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>LDLx Admin Security Portal</title>
    <script src="/assets/fingerprint2.min.js"></script>
    <style>
        body { background-color: #12181f; color: #e1e6ed; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .login-card { background-color: #1a222d; border: 1px solid #2a3646; border-radius: 12px; padding: 32px; width: 380px; box-shadow: 0 8px 24px rgba(0,0,0,0.4); text-align: center; }
        .title { color: #00e5ff; font-size: 20px; font-weight: bold; margin-bottom: 4px; }
        .subtitle { color: #8a99ad; font-size: 12px; margin-bottom: 24px; }
        .input-field { width: 100%; padding: 12px; margin-bottom: 16px; background-color: #12181f; border: 1px solid #2a3646; border-radius: 6px; color: #fff; box-sizing: border-box; }
        .input-field:focus { border-color: #00e5ff; outline: none; }
        .btn { width: 100%; padding: 12px; background-color: #00838f; color: white; border: none; border-radius: 6px; font-weight: bold; cursor: pointer; transition: background 0.2s; }
        .btn:hover { background-color: #00acc1; }
        .error-box { background: rgba(255, 82, 82, 0.15); border: 1px solid #ff5252; color: #ff8a80; padding: 10px; border-radius: 6px; font-size: 12px; margin-bottom: 16px; display: none; }
    </style>
</head>
<body>
    <div class="login-card">
        <div class="title">LDLx Security</div>
        <div class="subtitle">Lady of the Data Lake Secure Admin Portal (Port 9001)</div>
        <div id="errorBox" class="error-box"></div>
        <input type="text" id="username" class="input-field" placeholder="Admin Username" required>
        <input type="password" id="password" class="input-field" placeholder="Password" required>
        <input type="text" id="totp" class="input-field" placeholder="2FA TOTP Code (If Enabled)" maxlength="6">
        <button class="btn" onclick="performLogin()">Authenticate Portal</button>
    </div>
    <script>
        let clientFingerprint = "";
        if (typeof Fingerprint2 !== "undefined") {
            new Fingerprint2().get(function(result) { clientFingerprint = result; });
        }
        async function performLogin() {
            const errorBox = document.getElementById('errorBox');
            errorBox.style.display = 'none';
            try {
                const res = await fetch('/admin/api/login', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        username: document.getElementById('username').value,
                        password: document.getElementById('password').value,
                        totp: document.getElementById('totp').value,
                        fingerprint: clientFingerprint
                    })
                });
                const data = await res.json();
                if (res.ok) { window.location.reload(); }
                else { errorBox.innerText = data.error || 'Authentication Failed'; errorBox.style.display = 'block'; }
            } catch (e) { errorBox.innerText = 'Network error cleanly connecting to server.'; errorBox.style.display = 'block'; }
        }
    </script>
</body>
</html>
''';
  }

  String _buildAdminDashboardPageHtml(String username) {
    final dbRows = _serversInfo.values.map((server) {
      return '''
      <tr>
        <td style="font-weight: bold; color: #fff;">${server.dbName}</td>
        <td><span class="status-tag ${server.isUp ? 'status-up' : 'status-down'}">${server.isUp ? 'UP' : 'DOWN'}</span></td>
        <td style="font-family: monospace; color: #00e5ff;">${server.networkUrl}</td>
        <td>${server.activeSessions} sessions / ${server.totalQueries} queries</td>
        <td>
          <input type="text" class="jwt-box" value="${server.jwtToken}" readonly id="jwt_${server.dbName}">
          <button class="copy-btn" onclick="copyJwt('jwt_${server.dbName}')">Copy JWT</button>
        </td>
      </tr>
      ''';
    }).join('');

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>LDLx Admin Control Dashboard</title>
    <style>
        body { background-color: #12181f; color: #e1e6ed; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; padding: 32px; margin: 0; }
        .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; border-bottom: 1px solid #2a3646; padding-bottom: 16px; }
        .title { color: #00e5ff; font-size: 24px; font-weight: bold; }
        .user-info { display: flex; align-items: center; gap: 16px; color: #8a99ad; font-size: 14px; }
        .logout-btn { background: #d32f2f; color: white; border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-weight: bold; font-size: 12px; }
        .logout-btn:hover { background: #f44336; }
        table { width: 100%; border-collapse: collapse; background-color: #1a222d; border-radius: 8px; overflow: hidden; border: 1px solid #2a3646; }
        th, td { padding: 14px; text-align: left; border-bottom: 1px solid #2a3646; font-size: 13px; }
        th { background-color: #161d27; color: #8a99ad; font-transform: uppercase; font-size: 11px; letter-spacing: 0.5px; }
        .status-tag { padding: 4px 8px; border-radius: 4px; font-weight: bold; font-size: 11px; }
        .status-up { background: rgba(0, 230, 118, 0.2); color: #00e676; }
        .status-down { background: rgba(255, 82, 82, 0.2); color: #ff5252; }
        .jwt-box { background: #12181f; border: 1px solid #2a3646; color: #69f0ae; font-family: Inconsolata, monospace; font-size: 11px; padding: 6px; width: 280px; border-radius: 4px; }
        .copy-btn { background: #00838f; color: white; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; font-size: 11px; margin-left: 6px; }
        .copy-btn:hover { background: #00acc1; }
    </style>
</head>
<body>
    <div class="header">
        <div>
            <div class="title">System Dashboard (Port 9001 Isolated)</div>
            <div style="color: #8a99ad; font-size: 13px; margin-top: 4px;">Real-time system resource monitor and database server telemetry</div>
        </div>
        <div class="user-info">
            <span>Logged in as Admin: <strong style="color: #00e5ff;">$username</strong></span>
            <button class="logout-btn" onclick="performLogout()">Logout</button>
        </div>
    </div>
    <h3>Database Server Endpoints (${_serversInfo.length})</h3>
    <table>
        <thead>
            <tr>
                <th>Database Target</th>
                <th>Status</th>
                <th>Network Endpoint</th>
                <th>Activity Metrics</th>
                <th>Active JWT Bearer Token</th>
            </tr>
        </thead>
        <tbody>
            $dbRows
        </tbody>
    </table>
    <script>
        function copyJwt(elementId) {
            const input = document.getElementById(elementId);
            input.select();
            document.execCommand('copy');
            alert('JWT Bearer Token copied to clipboard!');
        }

        async function performLogout() {
            try {
                await fetch('/admin/api/logout', { method: 'POST' });
                window.location.reload();
            } catch (e) {
                window.location.reload();
            }
        }

        // Auto reload / redirect after 5 minutes of inactivity or expiration
        setTimeout(function() {
            alert('Your admin session has expired due to 5 minutes of inactivity.');
            window.location.reload();
        }, 300000);
    </script>
</body>
</html>
''';
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
        _sendJsonResponse(request, HttpStatus.ok, {'database': dbName, 'data': dbData});
        break;
      default:
        _sendJsonResponse(request, HttpStatus.methodNotAllowed, {'error': 'Method not allowed'});
    }
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
    _adminPanelServer?.close(force: true);
    _masterServer = null;
    _adminPanelServer = null;
    _serversInfo.clear();
  }
}