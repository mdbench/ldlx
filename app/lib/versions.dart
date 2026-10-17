import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ReleaseAsset {
  final String tagName;
  final String name;
  final String downloadUrl;
  bool isDownloadedLocally;

  ReleaseAsset({
    required this.tagName,
    required this.name,
    required this.downloadUrl,
    this.isDownloadedLocally = false,
  });
}

class VersionManager {
  static const String repoOwner = 'mdbench';
  static const String repoName = 'ldlx';
  static const String backupRoot = '/opt/ldlx.old';
  static const String activeInstallDir = '/opt/ldlx';

  static Map<String, String> get _githubHeaders => {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'LDLx-Client',
      };

  static Future<List<ReleaseAsset>> fetchRemoteReleases() async {
    final url = Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases');
    
    try {
      final response = await http.get(url, headers: _githubHeaders);

      if (response.statusCode != 200) {
        print('[!] GitHub API error: ${response.statusCode}');
        return [];
      }

      final decoded = jsonDecode(response.body);
      final List<dynamic> releasesJson = decoded is List ? decoded : [decoded];
      List<ReleaseAsset> assets = [];

      for (var release in releasesJson) {
        final tagName = release['tag_name'] as String? ?? '';
        final List<dynamic> releaseAssets = release['assets'] ?? [];

        for (var asset in releaseAssets) {
          final assetName = asset['name'] as String? ?? '';
          
          if (assetName.startsWith('ldlx-linux-binary-') && assetName.endsWith('.zip')) {
            final downloadUrl = asset['browser_download_url'] as String? ?? '';
            
            // Check existence directly in local backup directory
            final localPath = Directory('$backupRoot/$tagName');
            final exists = await localPath.exists() && await File('$backupRoot/$tagName/ldlx').exists();

            assets.add(ReleaseAsset(
              tagName: tagName,
              name: assetName,
              downloadUrl: downloadUrl,
              isDownloadedLocally: exists,
            ));
          }
        }
      }
      return assets;
    } catch (e) {
      print('[!] Error fetching GitHub releases: $e');
      return [];
    }
  }

  static Future<void> backupCurrentVersion(String versionTag) async {
    try {
      final backupDir = Directory('$backupRoot/$versionTag');
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      final activeDir = Directory(activeInstallDir);
      if (await activeDir.exists()) {
        await for (var entity in activeDir.list(recursive: false)) {
          final name = entity.uri.pathSegments.last;
          if (entity is File) {
            await entity.copy('$backupRoot/$versionTag/$name');
          } else if (entity is Directory && name != 'ldlx.old') {
            await _copyDirectory(entity, Directory('$backupRoot/$versionTag/$name'));
          }
        }
      }
    } catch (e) {
      print('[!] Failed to store version backup: $e');
    }
  }

  static Future<bool> downloadVersionToBackup(ReleaseAsset release) async {
    try {
      final targetFolder = Directory('$backupRoot/${release.tagName}');
      if (await targetFolder.exists() && await File('${targetFolder.path}/ldlx').exists()) {
        release.isDownloadedLocally = true;
        return true;
      }

      if (!await targetFolder.exists()) {
        await targetFolder.create(recursive: true);
      }

      final response = await http.get(Uri.parse(release.downloadUrl), headers: _githubHeaders);
      if (response.statusCode != 200) return false;

      final tempZipPath = '/tmp/${release.tagName}.zip';
      await File(tempZipPath).writeAsBytes(response.bodyBytes);

      final result = await Process.run('unzip', ['-o', tempZipPath, '-d', targetFolder.path]);
      if (result.exitCode == 0) {
        await Process.run('chmod', ['+x', '${targetFolder.path}/ldlx']);
        release.isDownloadedLocally = true;
        return true;
      }
    } catch (e) {
      print('[!] Error downloading version: $e');
    }
    return false;
  }

  static Future<void> _copyDirectory(Directory source, Directory destination) async {
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }
    await for (var entity in source.list(recursive: false)) {
      final newPath = '${destination.path}/${entity.uri.pathSegments.last}';
      if (entity is File) {
        await entity.copy(newPath);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      }
    }
  }
}

/// Flutter UI View matching the dashboard's polished dark theme
class VersionsView extends StatefulWidget {
  const VersionsView({Key? key}) : super(key: key);

  @override
  State<VersionsView> createState() => _VersionsViewState();
}

class _VersionsViewState extends State<VersionsView> {
  late Future<List<ReleaseAsset>> _releasesFuture;
  List<ReleaseAsset> _allReleases = [];
  List<ReleaseAsset> _filteredReleases = [];
  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadReleases();
    _searchController.addListener(_onSearchChanged);
  }

  void _loadReleases() {
    setState(() {
      _releasesFuture = VersionManager.fetchRemoteReleases();
    });
    _releasesFuture.then((releases) {
      setState(() {
        _allReleases = releases;
        _filteredReleases = releases;
      });
    });
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredReleases = _allReleases.where((release) {
        return release.tagName.toLowerCase().contains(query) ||
               release.name.toLowerCase().contains(query);
      }).toList();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _handleDownloadOrSelect(ReleaseAsset release) async {
    setState(() => _isLoading = true);
    if (!release.isDownloadedLocally) {
      final success = await VersionManager.downloadVersionToBackup(release);
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to download release binary from GitHub.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Successfully downloaded ${release.tagName} to /opt/ldlx.old/')),
        );
      }
    } else {
      // Backup current state under a temporary timestamp or generic tag before switching
      final fallbackTag = 'backup-${DateTime.now().millisecondsSinceEpoch}';
      await VersionManager.backupCurrentVersion(fallbackTag);

      final sourceDir = Directory('${VersionManager.backupRoot}/${release.tagName}');
      await VersionManager._copyDirectory(sourceDir, Directory(VersionManager.activeInstallDir));
      await Process.run('chmod', ['+x', '${VersionManager.activeInstallDir}/ldlx']);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Switched active app to ${release.tagName}. Restart recommended.')),
      );
    }
    setState(() {
      _isLoading = false;
      _loadReleases();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF13161C),
      appBar: AppBar(
        title: const Text('Version Manager', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFF181B22),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Search Bar
            TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search versions (e.g. v1.0.0)...',
                hintStyle: TextStyle(color: Colors.grey[500], fontSize: 14),
                prefixIcon: const Icon(Icons.search, color: Colors.grey, size: 20),
                filled: true,
                fillColor: const Color(0xFF1E222B),
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10.0),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (_isLoading)
              const LinearProgressIndicator(color: Color(0xFF00E5FF), backgroundColor: Color(0xFF1E222B)),
            const SizedBox(height: 10),
            // Versions List Header
            const Text(
              'Available GitHub Releases & Local Cache',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            // Versions List
            Expanded(
              child: FutureBuilder<List<ReleaseAsset>>(
                future: _releasesFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator(color: Color(0xFF00E5FF)));
                  } else if (snapshot.hasError) {
                    return Center(child: Text('Error loading releases: ${snapshot.error}', style: const TextStyle(color: Colors.redAccent)));
                  } else if (_filteredReleases.isEmpty) {
                    return const Center(child: Text('No versions found.', style: TextStyle(color: Colors.grey)));
                  }

                  return ListView.builder(
                    itemCount: _filteredReleases.length,
                    itemBuilder: (context, index) {
                      final release = _filteredReleases[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E222B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withOpacity(0.05)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    release.tagName,
                                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(release.name, style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      Icon(
                                        release.isDownloadedLocally ? Icons.check_circle_outline : Icons.cloud_outlined,
                                        size: 14,
                                        color: release.isDownloadedLocally ? const Color(0xFF00E5FF) : Colors.orangeAccent,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        release.isDownloadedLocally ? 'Cached in /opt/ldlx.old/' : 'Remote release only',
                                        style: TextStyle(
                                          color: release.isDownloadedLocally ? const Color(0xFF00E5FF) : Colors.orangeAccent,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: release.isDownloadedLocally ? const Color(0xFF2A2F3D) : const Color(0xFF00E5FF),
                                foregroundColor: release.isDownloadedLocally ? Colors.white : Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                elevation: 0,
                              ),
                              onPressed: _isLoading ? null : () => _handleDownloadOrSelect(release),
                              child: Text(
                                release.isDownloadedLocally ? 'Switch / Use' : 'Download',
                                style: TextStyle(fontWeight: FontWeight.bold, color: release.isDownloadedLocally ? Colors.white : Colors.black),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
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