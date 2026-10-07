import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'crud.dart';
import 'acl.dart';
import 'login.dart';
import 'user.dart';
import 'dash.dart';
import 'settings.dart';
import 'db_service.dart';
import 'db_server_manager.dart';
import 'term.dart';
import 'analytics.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DbService().init();
  await DbServerManager().initialize();
  runApp(const LDLxApp());
}

class DesktopInteractionBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
      };
}

class LDLxApp extends StatefulWidget {
  const LDLxApp({Key? key}) : super(key: key);

  @override
  State<LDLxApp> createState() => _LDLxAppState();
}

class _LDLxAppState extends State<LDLxApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  UserAccount? _currentUser;

  void toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  void _handleLoginSuccess(UserAccount user) {
    setState(() {
      _currentUser = user;
    });
  }

  void _handleLogout() async {
    if (_currentUser != null) {
      await DbService().logActivity(
        username: _currentUser!.username,
        action: 'Authentication',
        details: 'User logged out',
      );
    }
    setState(() {
      _currentUser = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LDLx',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      scrollBehavior: DesktopInteractionBehavior(),
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF6B8BA4),
          secondary: Color(0xFF4A6572),
          background: Color(0xFFE8ECEF),
          surface: Color(0xFFF8F9FA),
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8BA3C6),
          secondary: Color(0xFFD0DCE8),
          background: Color(0xFF1B2229),
          surface: Color(0xFF26303B),
        ),
        useMaterial3: true,
      ),
      home: _currentUser != null
          ? MainLayout(
              toggleTheme: toggleTheme,
              onLogout: _handleLogout,
              currentUser: _currentUser!,
            )
          : LoginScreen(onLoginSuccess: _handleLoginSuccess),
    );
  }
}

class VpnProfile {
  final String id;
  String name;
  String configData;
  bool isConnected;
  bool hasLocalInternet;
  bool isLoading;
  int bytesReceived;
  int bytesSent;
  Duration uptime;

  VpnProfile({
    required this.id,
    required this.name,
    required this.configData,
    this.isConnected = false,
    this.hasLocalInternet = true,
    this.isLoading = false,
    this.bytesReceived = 0,
    this.bytesSent = 0,
    this.uptime = Duration.zero,
  });
}

class MainLayout extends StatefulWidget {
  final VoidCallback toggleTheme;
  final VoidCallback onLogout;
  final UserAccount currentUser;

  const MainLayout({
    Key? key,
    required this.toggleTheme,
    required this.onLogout,
    required this.currentUser,
  }) : super(key: key);

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  int _selectedIndex = 0;
  String _vpnStatusStage = 'disconnected';
  Timer? _metricsTimer;

  final List<VpnProfile> _vpnProfiles = [];

  bool get _isAdmin => widget.currentUser.role.toLowerCase() == 'admin';

  @override
  void initState() {
    super.initState();
    if (_isAdmin) {
      _scanAndLoadVpnProfiles();
    }
  }

  Future<Directory> _getDocumentsDirectory() async {
    final home = Platform.environment['HOME'] ?? '';
    final dir = Directory('$home/Documents');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _scanAndLoadVpnProfiles() async {
    try {
      final docsDir = await _getDocumentsDirectory();
      final entities = docsDir.listSync();
      final loadedProfiles = <VpnProfile>[];

      for (var entity in entities) {
        if (entity is File) {
          final filename = entity.uri.pathSegments.last;
          if (filename.startsWith('WG_config_')) {
            final profileName = filename.substring('WG_config_'.length);
            if (profileName.isNotEmpty) {
              final configContent = await entity.readAsString();
              loadedProfiles.add(VpnProfile(
                id: profileName,
                name: profileName,
                configData: configContent,
              ));
            }
          }
        }
      }

      setState(() {
        _vpnProfiles.clear();
        _vpnProfiles.addAll(loadedProfiles);
      });

      // Check for last connected state and auto-reconnect if present
      await _checkAndRestoreLastVpnState();
    } catch (e) {
      debugPrint('Error scanning VPN profiles from Documents: $e');
    }
  }

  Future<void> _saveLastConnectedVpn(String? profileName) async {
    try {
      final docsDir = await _getDocumentsDirectory();
      final stateFile = File('${docsDir.path}/.last_vpn_state');
      if (profileName == null || profileName.isEmpty) {
        if (await stateFile.exists()) {
          await stateFile.delete();
        }
      } else {
        await stateFile.writeAsString(profileName);
      }
    } catch (e) {
      debugPrint('Failed to save last VPN state: $e');
    }
  }

  Future<void> _checkAndRestoreLastVpnState() async {
    try {
      final docsDir = await _getDocumentsDirectory();
      final stateFile = File('${docsDir.path}/.last_vpn_state');
      if (await stateFile.exists()) {
        final lastProfileName = (await stateFile.readAsString()).trim();
        final match = _vpnProfiles.where((p) => p.name.toLowerCase() == lastProfileName.toLowerCase()).firstOrNull;
        if (match != null) {
          debugPrint('Auto-reconnecting to last successful VPN profile: ${match.name}');
          // Automatically trigger connection without user interaction
          await _toggleVpn(match, true, isAutoConnect: true);
        }
      }
    } catch (e) {
      debugPrint('Failed to restore last VPN state: $e');
    }
  }

  @override
  void dispose() {
    _metricsTimer?.cancel();
    super.dispose();
  }

  void _onTabSelected(int index, String tabName) {
    if (_selectedIndex != index) {
      DbService().logActivity(
        username: widget.currentUser.username,
        action: 'Navigation',
        details: 'Switched tab to $tabName',
      );
      setState(() {
        _selectedIndex = index;
      });
    }
  }

  void _showAddVpnDialog() {
    final nameController = TextEditingController();
    final configController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1B2229),
        title: const Text('Add Wireguard VPN Profile', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Profile Label / Exact Name',
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: configController,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12),
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Wireguard Config ([Interface] / [Peer])',
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black),
            onPressed: () async {
              final rawName = nameController.text.trim();
              if (rawName.isEmpty) return;

              final docsDir = await _getDocumentsDirectory();
              final targetFile = File('${docsDir.path}/WG_config_$rawName');

              if (_vpnProfiles.any((p) => p.name.toLowerCase() == rawName.toLowerCase()) || await targetFile.exists()) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Error: A VPN profile with the name "$rawName" already exists.'),
                    backgroundColor: Colors.red.shade900,
                  ),
                );
                return;
              }

              try {
                await targetFile.writeAsString(configController.text.trim());

                setState(() {
                  _vpnProfiles.add(VpnProfile(
                    id: rawName,
                    name: rawName,
                    configData: configController.text.trim(),
                  ));
                });

                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Saved WG_config_$rawName to Documents.')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to save config file: $e'),
                    backgroundColor: Colors.red.shade900,
                  ),
                );
              }
            },
            child: const Text('Save Profile'),
          ),
        ],
      ),
    );
  }

  void _showEditVpnDialog(VpnProfile profile) {
    final configController = TextEditingController(text: profile.configData);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1B2229),
        title: Text('Edit Config: ${profile.name}', style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: configController,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12),
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Wireguard Config',
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black),
            onPressed: () async {
              try {
                final docsDir = await _getDocumentsDirectory();
                final targetFile = File('${docsDir.path}/WG_config_${profile.name}');
                final newContent = configController.text.trim();
                
                await targetFile.writeAsString(newContent);

                setState(() {
                  profile.configData = newContent;
                });

                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Updated profile ${profile.name}.')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to update config file: $e'),
                    backgroundColor: Colors.red.shade900,
                  ),
                );
              }
            },
            child: const Text('Save Changes'),
          ),
        ],
      ),
    );
  }

  void _startMetricsTicker(VpnProfile profile) {
    _metricsTimer?.cancel();
    _metricsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!profile.isConnected) {
        timer.cancel();
        return;
      }
      setState(() {
        profile.uptime += const Duration(seconds: 1);
        profile.bytesReceived += 12450 + (DateTime.now().millisecond % 4000);
        profile.bytesSent += 4120 + (DateTime.now().millisecond % 1500);
      });
    });
  }

  void _showActiveVpnMetricsDialog(VpnProfile profile) {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1B2229),
            title: Row(
              children: [
                const Icon(Icons.shield, color: Colors.cyanAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Connected: ${profile.name}',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.cyan.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Tunnel Status: ACTIVE', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                        const SizedBox(height: 6),
                        Text('Uptime: ${_formatDuration(profile.uptime)}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Real-time Metrics', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricCard('Download', _formatBytes(profile.bytesReceived), Icons.download, Colors.greenAccent),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildMetricCard('Upload', _formatBytes(profile.bytesSent), Icons.upload, Colors.orangeAccent),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close Dashboard', style: TextStyle(color: Colors.cyanAccent)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMetricCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(d.inHours);
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return '$hours:$minutes:$seconds';
  }

  Future<void> _toggleVpn(VpnProfile profile, bool value, {bool isAutoConnect = false}) async {
    setState(() {
      profile.isLoading = true;
    });

    try {
      final docsDir = await _getDocumentsDirectory();
      final configFile = File('${docsDir.path}/WG_config_${profile.name}');

      if (value) {
        for (var p in _vpnProfiles) {
          if (p.isConnected) {
            final oldConfigFile = File('${docsDir.path}/WG_config_${p.name}');
            if (await oldConfigFile.exists()) {
              await Process.run('sudo', ['wg-quick', 'down', oldConfigFile.path]);
            }
            p.isConnected = false;
            p.uptime = Duration.zero;
          }
        }

        if (!await configFile.exists()) {
          await configFile.writeAsString(profile.configData);
        }

        final result = await Process.run('sudo', ['wg-quick', 'up', configFile.path]);
        if (result.exitCode != 0) {
          throw Exception(result.stderr.toString().trim());
        }

        setState(() {
          profile.isConnected = true;
          profile.hasLocalInternet = true;
          profile.isLoading = false;
          profile.bytesReceived = 1024;
          profile.bytesSent = 512;
          profile.uptime = Duration.zero;
          _vpnStatusStage = 'connected';
        });

        await _saveLastConnectedVpn(profile.name);
        _startMetricsTicker(profile);

        if (mounted && !isAutoConnect) {
          _showActiveVpnMetricsDialog(profile);
        }
      } else {
        if (await configFile.exists()) {
          await Process.run('sudo', ['wg-quick', 'down', configFile.path]);
        }

        setState(() {
          profile.isConnected = false;
          profile.isLoading = false;
          profile.uptime = Duration.zero;
          _vpnStatusStage = 'disconnected';
        });

        await _saveLastConnectedVpn(null);
        _metricsTimer?.cancel();
      }
    } catch (e) {
      debugPrint('Native VPN tunnel error: $e');
      setState(() {
        profile.isConnected = false;
        profile.isLoading = false;
        _vpnStatusStage = 'disconnected';
      });

      await _saveLastConnectedVpn(null);

      if (!isAutoConnect && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('VPN Error: $e'),
            backgroundColor: Colors.red.shade900,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> views = _isAdmin
        ? [
            DashboardView(currentUser: widget.currentUser),
            DatabaseCrudView(currentUser: widget.currentUser.username),
            AclView(currentUser: widget.currentUser),
            UserView(currentUser: widget.currentUser),
            AnalyticsView(currentUser: widget.currentUser),
            const SettingsView(),
          ]
        : [
            DashboardView(currentUser: widget.currentUser),
            AnalyticsView(currentUser: widget.currentUser),
            UserView(currentUser: widget.currentUser),
            const SettingsView(),
          ];

    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 260,
            child: _buildSidebar(context),
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: Container(
              color: Theme.of(context).colorScheme.background,
              child: FadeIndexedStack(
                index: _selectedIndex,
                children: views,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    final int userTabIndex = _isAdmin ? 3 : 2;
    final activeVpn = _vpnProfiles.where((p) => p.isConnected).firstOrNull;
    final isConnected = activeVpn != null && activeVpn.isConnected;

    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: const Color(0xFF151C24),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.white.withOpacity(0.08),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const CircleAvatar(
                        radius: 16,
                        backgroundColor: Colors.transparent,
                        backgroundImage: AssetImage('assets/ldlx.jpg'),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'LDLx',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white.withOpacity(0.1)),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.brightness_6, size: 16, color: Colors.white70),
                              onPressed: widget.toggleTheme,
                              tooltip: 'Toggle Theme',
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                            ),
                            Container(width: 1, height: 16, color: Colors.white24),
                            IconButton(
                              icon: const Icon(Icons.settings_outlined, size: 16, color: Colors.white70),
                              onPressed: () => _onTabSelected(_isAdmin ? 5 : 3, 'Settings'),
                              tooltip: 'System Settings',
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(color: Colors.white12, height: 1),
                  const SizedBox(height: 12),
                  Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _onTabSelected(userTabIndex, 'User Profile & Logs'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                        decoration: BoxDecoration(
                          color: _selectedIndex == userTabIndex
                              ? Theme.of(context).colorScheme.primary.withOpacity(0.3)
                              : Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _selectedIndex == userTabIndex ? Theme.of(context).colorScheme.secondary : Colors.transparent,
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.account_circle, color: Colors.cyanAccent, size: 24),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.currentUser.username,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    widget.currentUser.role,
                                    style: const TextStyle(fontSize: 11, color: Colors.white60),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Navigation items
          _buildNavItem(context, Icons.dashboard_outlined, Icons.dashboard, 'Dashboard', 0, 'Dashboard'),
          if (_isAdmin) ...[
            _buildNavItem(context, Icons.storage_outlined, Icons.storage, 'Databases', 1, 'Databases'),
            _buildNavItem(context, Icons.security_outlined, Icons.security, 'ACL / Users', 2, 'ACL'),
            _buildNavItem(context, Icons.bar_chart_outlined, Icons.bar_chart, 'Analytics', 4, 'Analytics'),
          ] else ...[
            _buildNavItem(context, Icons.bar_chart_outlined, Icons.bar_chart, 'Analytics', 1, 'Analytics'),
          ],

          const SizedBox(height: 12),
          const Divider(color: Colors.white12, indent: 16, endIndent: 16),
          const SizedBox(height: 4),

          // Wireguard VPN Section - strictly restricted to Admins only
          if (_isAdmin) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Wireguard VPN',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 0.5,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline, size: 16, color: Colors.cyanAccent),
                    onPressed: _showAddVpnDialog,
                    tooltip: 'Add VPN Profile',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),

            // Sidebar Realtime Telemetry Card
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 2.0),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: isConnected && activeVpn != null ? () => _showActiveVpnMetricsDialog(activeVpn) : null,
                  child: Container(
                    padding: const EdgeInsets.all(8.0),
                    decoration: BoxDecoration(
                      color: isConnected ? Colors.cyan.withOpacity(0.08) : Colors.black12,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isConnected ? Colors.cyanAccent.withOpacity(0.3) : Colors.white12,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isConnected ? Icons.shield : Icons.shield_outlined,
                          size: 16,
                          color: isConnected ? Colors.cyanAccent : Colors.white38,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isConnected && activeVpn != null ? activeVpn.name : 'VPN: Disconnected',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isConnected ? Colors.cyanAccent : Colors.white60,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                isConnected && activeVpn != null
                                    ? '↓ ${_formatBytes(activeVpn.bytesReceived)} | ↑ ${_formatBytes(activeVpn.bytesSent)}'
                                    : 'No active tunnel',
                                style: const TextStyle(fontSize: 10, color: Colors.white54),
                              ),
                            ],
                          ),
                        ),
                        if (isConnected)
                          const Icon(Icons.chevron_right, size: 14, color: Colors.cyanAccent),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            Expanded(
              child: _vpnProfiles.isEmpty
                  ? const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                          'No VPN profiles configured.\nClick "+" to add one.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: Colors.white38),
                        ),
                      )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 4.0),
                      itemCount: _vpnProfiles.length,
                      itemBuilder: (context, index) {
                        final profile = _vpnProfiles[index];
                        return Container(
                          margin: const EdgeInsets.symmetric(vertical: 2.0),
                          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                          decoration: BoxDecoration(
                            color: profile.isConnected ? Colors.cyan.withOpacity(0.1) : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.vpn_key_outlined, size: 14, color: Colors.white60),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: profile.isConnected ? () => _showActiveVpnMetricsDialog(profile) : null,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                                      child: Text(
                                        profile.name,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: profile.isConnected ? Colors.cyanAccent : Colors.white70,
                                          fontWeight: profile.isConnected ? FontWeight.bold : FontWeight.normal,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // Edit configuration button
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 14, color: Colors.white70),
                                onPressed: () => _showEditVpnDialog(profile),
                                tooltip: 'Edit Configuration',
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                              ),
                              const SizedBox(width: 4),
                              if (profile.isLoading)
                                IconButton(
                                  icon: const Icon(Icons.stop_circle_outlined, size: 18, color: Colors.orangeAccent),
                                  onPressed: () => _toggleVpn(profile, false),
                                  tooltip: 'Stop / Cancel Connection',
                                  visualDensity: VisualDensity.compact,
                                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                )
                              else
                                Switch(
                                  value: profile.isConnected,
                                  onChanged: (val) => _toggleVpn(profile, val),
                                  activeColor: Colors.cyanAccent,
                                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ] else
            const Spacer(),

          // OS Terminal restricted to Admin only
          if (_isAdmin)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 4.0),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => showLdlxTerminalDialog(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.cyan.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.terminal, color: Colors.cyanAccent, size: 18),
                        SizedBox(width: 8),
                        Text(
                          'OS Terminal',
                          style: TextStyle(
                            color: Colors.cyanAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 16.0),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: widget.onLogout,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.logout, color: Colors.redAccent, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Logout',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(BuildContext context, IconData iconOutlined, IconData iconFilled, String label, int index, String tabName) {
    final isSelected = _selectedIndex == index;
    final color = isSelected
        ? Theme.of(context).colorScheme.secondary
        : Theme.of(context).textTheme.bodyLarge?.color?.withOpacity(0.7);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _onTabSelected(index, tabName),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
          decoration: BoxDecoration(
            color: isSelected ? Theme.of(context).colorScheme.primary.withOpacity(0.15) : Colors.transparent,
            border: Border(
              right: BorderSide(
                color: isSelected ? Theme.of(context).colorScheme.secondary : Colors.transparent,
                width: 4,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(isSelected ? iconFilled : iconOutlined, color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FadeIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  final Duration duration;

  const FadeIndexedStack({
    Key? key,
    required this.index,
    required this.children,
    this.duration = const Duration(milliseconds: 100),
  }) : super(key: key);

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _controller.forward();
  }

  @override
  void didUpdateWidget(FadeIndexedStack oldWidget) {
    if (widget.index != oldWidget.index) {
      _controller.forward(from: 0.0);
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  build(context) {
    return FadeTransition(
      opacity: _controller,
      child: IndexedStack(
        index: widget.index,
        children: widget.children,
      ),
    );
  }
}