import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

class UserAccount {
  final String username;
  final String password;
  final String role; // 'Admin', 'Analyst', 'User'
  final bool canRead;
  final bool canWrite;
  final bool canExecute;
  final bool isTotpEnabled;
  final String totpSecret;

  UserAccount({
    required this.username,
    required this.password,
    required this.role,
    this.canRead = true,
    this.canWrite = false,
    this.canExecute = false,
    this.isTotpEnabled = false,
    this.totpSecret = '',
  });

  Map<String, dynamic> toMap() => {
        'username': username,
        'password': password,
        'role': role,
        'canRead': canRead,
        'canWrite': canWrite,
        'canExecute': canExecute,
        'isTotpEnabled': isTotpEnabled,
        'totpSecret': totpSecret,
      };

  factory UserAccount.fromMap(Map<String, dynamic> map) => UserAccount(
        username: map['username'] ?? '',
        password: map['password'] ?? '',
        role: map['role'] ?? 'User',
        canRead: map['canRead'] ?? true,
        canWrite: map['canWrite'] ?? false,
        canExecute: map['canExecute'] ?? false,
        isTotpEnabled: map['isTotpEnabled'] ?? false,
        totpSecret: map['totpSecret'] ?? '',
      );
}

class ActivityLog {
  final String id;
  final String username;
  final String action;
  final String details;
  final DateTime timestamp;

  ActivityLog({
    required this.id,
    required this.username,
    required this.action,
    required this.details,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'username': username,
        'action': action,
        'details': details,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ActivityLog.fromMap(Map<String, dynamic> map) => ActivityLog(
        id: map['id'] ?? '',
        username: map['username'] ?? 'unknown',
        action: map['action'] ?? '',
        details: map['details'] ?? '',
        timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      );
}

class FailedLogin {
  final String id;
  final String ip;
  final String username;
  final String password;
  final DateTime timestamp;

  FailedLogin({
    required this.id,
    required this.ip,
    required this.username,
    required this.password,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'ip': ip,
        'username': username,
        'password': password,
        'timestamp': timestamp.toIso8601String(),
      };

  factory FailedLogin.fromMap(Map<String, dynamic> map) => FailedLogin(
        id: map['id'] ?? '',
        ip: map['ip'] ?? '127.0.0.1',
        username: map['username'] ?? '',
        password: map['password'] ?? '',
        timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      );
}

class DbService {
  static final DbService _instance = DbService._internal();
  factory DbService() => _instance;
  DbService._internal();

  Database? _usersDb;
  Database? _logsDb;
  Database? _failsDb;

  final _userStore = stringMapStoreFactory.store('users_store');
  final _logStore = stringMapStoreFactory.store('logs_store');
  final _failsStore = stringMapStoreFactory.store('fails_store');

  Future<void> init() async {
    if (_usersDb != null && _logsDb != null && _failsDb != null) return;

    final Directory dir = await getApplicationDocumentsDirectory();
    final String dataPath = join(dir.path, 'ldlx_data');
    await Directory(dataPath).create(recursive: true);

    _usersDb ??= await databaseFactoryIo.openDatabase(join(dataPath, 'users.db'));
    _logsDb ??= await databaseFactoryIo.openDatabase(join(dataPath, 'logs.db'));
    _failsDb ??= await databaseFactoryIo.openDatabase(join(dataPath, 'fails.db'));

    // Initialize default admin user if database is fresh
    final adminRecord = await _userStore.record('admin').get(_usersDb!);
    if (adminRecord == null) {
      final defaultAdmin = UserAccount(
        username: 'admin',
        password: 'admin',
        role: 'Admin',
        canRead: true,
        canWrite: true,
        canExecute: true,
      );
      await _userStore.record('admin').put(_usersDb!, defaultAdmin.toMap());
    }
  }

  // --- USER OPERATIONS ---

  Future<UserAccount?> authenticate(String username, String password) async {
    await init();
    final record = await _userStore.record(username.toLowerCase()).get(_usersDb!);
    if (record != null) {
      final user = UserAccount.fromMap(record);
      if (user.password == password) {
        return user;
      }
    }
    return null;
  }

  Future<List<UserAccount>> getAllUsers() async {
    await init();
    final snapshots = await _userStore.find(_usersDb!);
    return snapshots.map((s) => UserAccount.fromMap(s.value)).toList();
  }

  Future<void> saveUser(UserAccount user) async {
    await init();
    await _userStore.record(user.username.toLowerCase()).put(_usersDb!, user.toMap());
  }

  Future<bool> deleteUser(String username) async {
    await init();
    if (username.toLowerCase() == 'admin') return false; // Failsafe
    await _userStore.record(username.toLowerCase()).delete(_usersDb!);
    return true;
  }

  // --- TOTP VERIFICATION ---

  Future<bool> verifyTotp(UserAccount user, String code) async {
    if (!user.isTotpEnabled || user.totpSecret.isEmpty) return true;
    try {
      final cleanSecret = user.totpSecret.replaceAll(' ', '').toUpperCase();
      final secretBytes = _base32Decode(cleanSecret);
      if (secretBytes.isEmpty) return false;

      final currentTimestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      const step = 30;
      final currentCounter = currentTimestamp ~/ step;

      // Check current counter and +/- 1 window for clock drift tolerance
      for (int i = -1; i <= 1; i++) {
        final generatedCode = _generateTotpCode(secretBytes, currentCounter + i);
        if (generatedCode == code.trim()) {
          return true;
        }
      }
    } catch (e) {
      // Log or handle TOTP error
    }
    return false;
  }

  Uint8List _base32Decode(String base32) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    int buffer = 0;
    int bitsLeft = 0;
    final output = <int>[];

    for (int i = 0; i < base32.length; i++) {
      final char = base32[i];
      if (char == '=') break;
      final val = alphabet.indexOf(char);
      if (val < 0) continue;
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        output.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    return Uint8List.fromList(output);
  }

  String _generateTotpCode(Uint8List secret, int counter) {
    final counterBytes = Uint8List(8);
    var tmpCounter = counter;
    for (int i = 7; i >= 0; i--) {
      counterBytes[i] = tmpCounter & 0xFF;
      tmpCounter >>= 8;
    }

    final hmac = Hmac(sha1, secret);
    final digest = hmac.convert(counterBytes);
    final hash = digest.bytes;

    final offset = hash[hash.length - 1] & 0x0F;
    final binary = ((hash[offset] & 0x7F) << 24) |
        ((hash[offset + 1] & 0xFF) << 16) |
        ((hash[offset + 2] & 0xFF) << 8) |
        (hash[offset + 3] & 0xFF);

    final otp = binary % 1000000;
    return otp.toString().padLeft(6, '0');
  }

  // --- LOG OPERATIONS ---

  Future<void> logActivity({
    required String username,
    required String action,
    required String details,
  }) async {
    await init();
    final String id = DateTime.now().microsecondsSinceEpoch.toString();
    final log = ActivityLog(
      id: id,
      username: username,
      action: action,
      details: details,
      timestamp: DateTime.now(),
    );
    await _logStore.record(id).put(_logsDb!, log.toMap());
  }

  Future<List<ActivityLog>> getLogs({String? usernameFilter}) async {
    await init();
    final Finder finder = Finder(
      sortOrders: [SortOrder('timestamp', false)], // Newest first
    );

    final snapshots = await _logStore.find(_logsDb!, finder: finder);
    final logs = snapshots.map((s) => ActivityLog.fromMap(s.value)).toList();

    if (usernameFilter != null && usernameFilter.isNotEmpty) {
      return logs.where((l) => l.username.toLowerCase() == usernameFilter.toLowerCase()).toList();
    }

    return logs;
  }

  // --- FAILED LOGIN TELEMETRY OPERATIONS ---

  Future<void> logFailedLogin({
    required String ip,
    required String username,
    required String password,
  }) async {
    await init();
    final String id = DateTime.now().microsecondsSinceEpoch.toString();
    final fail = FailedLogin(
      id: id,
      ip: ip,
      username: username,
      password: password,
      timestamp: DateTime.now(),
    );
    await _failsStore.record(id).put(_failsDb!, fail.toMap());
  }

  Future<List<FailedLogin>> getFailedLogins() async {
    await init();
    final Finder finder = Finder(
      sortOrders: [SortOrder('timestamp', false)], // Newest first
    );
    final snapshots = await _failsStore.find(_failsDb!, finder: finder);
    return snapshots.map((s) => FailedLogin.fromMap(s.value)).toList();
  }
}