import 'package:flutter/material.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('System Settings & Build Info', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(
              'Application diagnostic specs, build metadata, and system environment details.',
              style: TextStyle(color: colorScheme.secondary),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: ListView(
                children: [
                  _buildSectionHeader(context, 'Build Information'),
                  Card(
                    color: colorScheme.surface,
                    elevation: 2,
                    child: Column(
                      children: const [
                        ListTile(
                          leading: Icon(Icons.info_outline),
                          title: Text('App Version'),
                          subtitle: Text('LDLx Core Desktop Client'),
                          trailing: Text('v2.4.0-release', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        ),
                        Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.build_circle_outlined),
                          title: Text('Build Number'),
                          subtitle: Text('Compiled with Flutter 3.22.0 (Linux x64 Engine)'),
                          trailing: Text('8942-rel-x11', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        ),
                        Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.developer_board),
                          title: Text('Environment Backend'),
                          subtitle: Text('GDK_BACKEND=x11 (Native Wayland Fallback Enabled)'),
                          trailing: Text('X11 Windowing', style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildSectionHeader(context, 'Storage & Database Engine'),
                  Card(
                    color: colorScheme.surface,
                    elevation: 2,
                    child: Column(
                      children: const [
                        ListTile(
                          leading: Icon(Icons.storage),
                          title: Text('Local Storage Engine'),
                          subtitle: Text('Sembast NoSQL Document Store'),
                          trailing: Text('v3.7.0', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        ),
                        Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.folder_open),
                          title: Text('Data Directory'),
                          subtitle: Text('~/Documents/ldlx_data/ (users.db & logs.db)'),
                          trailing: Icon(Icons.check_circle_outline, color: Colors.green),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildSectionHeader(context, 'Access Control & Security Policy'),
                  Card(
                    color: colorScheme.surface,
                    elevation: 2,
                    child: Column(
                      children: const [
                        ListTile(
                          leading: Icon(Icons.security),
                          title: Text('Access Model'),
                          subtitle: Text('Role-Based Access Control (Admin, Analyst, User)'),
                          trailing: Text('Active RBAC', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        ),
                        Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.admin_panel_settings_outlined),
                          title: Text('Master Admin Protection'),
                          subtitle: Text('Root admin deletion disabled by system failsafe'),
                          trailing: Text('Protected', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
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
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0, left: 4.0),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.secondary,
            ),
      ),
    );
  }
}