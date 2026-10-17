import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class TerminalWidget extends StatefulWidget {
  const TerminalWidget({Key? key}) : super(key: key);

  @override
  State<TerminalWidget> createState() => _TerminalWidgetState();
}

class _TerminalWidgetState extends State<TerminalWidget> {
  final TextEditingController _commandController = TextEditingController();
  final List<String> _outputLogs = [
    'LDLx Secure Terminal v1.3.0 (Linux x86_64)',
    'Type "help" for available commands or "ldlxstrings" to view pushed strings.',
    '------------------------------------------------------------',
  ];
  final ScrollController _scrollController = ScrollController();
  bool _isExecuting = false;

  // Active state for interactive network file editing mode
  bool _isEditingNetworkFile = false;
  String _targetNetworkFilePath = '/etc/network/interfaces';
  List<String> _editableConfigLines = [];

  // Active state for line-by-line pushed strings viewer sidebar (Locked to database directory)
  bool _isViewingStringFile = false;
  String _targetStringFilePath = '';
  List<String> _stringFileLines = [];

  // Strict whitelist of allowed command prefixes and utilities
  final List<String> _allowedCommandPrefixes = [
    'cloudflared',
    'sys-test',
    'sys-info',
    'ldlxconfignet',
    'ldlxeditnet',
    'ldlxstrings',
    'save',
    'cancel',
    'help',
    'clear',
    'echo',
    'curl',
    'top',
    'ping',
    'dig',
    'ip',
    'netstat',
    'journalctl',
  ];

  void _executeCommand() async {
    String rawInput = _commandController.text.trim();
    if (rawInput.isEmpty) return;

    // Requirement: Auto-remove string file viewer mode the moment ANY new command is sent
    if (_isViewingStringFile) {
      setState(() {
        _isViewingStringFile = false;
        _outputLogs.add('\$ [Exited string file viewer mode]');
      });
    }

    // If we are actively in the network file editing state, input lines are appended
    if (_isEditingNetworkFile) {
      if (rawInput == 'cancel') {
        _cancelEditing();
        return;
      } else if (rawInput == 'save') {
        _saveConfigChanges();
        return;
      } else {
        setState(() {
          _outputLogs.add('\$ [Appending line: "$rawInput"]');
          _editableConfigLines.add(rawInput);
          _commandController.clear();
        });
        _scrollToBottom();
        return;
      }
    }

    bool isAllowed = _allowedCommandPrefixes.any((prefix) => rawInput.startsWith(prefix));

    setState(() {
      _outputLogs.add('\$ $rawInput');
      _commandController.clear();
    });

    if (!isAllowed) {
      setState(() {
        _outputLogs.add('ACCESS DENIED: Command not authorized by LDLx security policy.');
        _outputLogs.add('Allowed prefixes: ${_allowedCommandPrefixes.join(", ")}');
      });
      _scrollToBottom();
      return;
    }

    if (rawInput == 'clear') {
      setState(() {
        _outputLogs.clear();
        _outputLogs.add('LDLx Secure Terminal cleared.');
      });
      return;
    }

    if (rawInput == 'help') {
      setState(() {
        _outputLogs.add('Available Commands:');
        _outputLogs.add('  ldlxstrings              - View line-by-line pushed strings file in sidebar with copy support');
        _outputLogs.add('  ldlxeditnet [path]       - Open interactive network file editor & sidebar');
        _outputLogs.add('  ldlxconfignet            - Interactive tool to view and configure network parameters');
        _outputLogs.add('  sys-test                 - Inspect system memory (free) and disk storage (df)');
        _outputLogs.add('  sys-info                 - Display complete device, kernel, and hardware info');
        _outputLogs.add('  curl [URL]               - Transfer data from or to a server');
        _outputLogs.add('  ping [host] -c 4         - Send ICMP echo requests');
        _outputLogs.add('  dig [domain]             - Perform DNS lookup queries');
        _outputLogs.add('  ip addr                  - Inspect network interfaces and IP configurations');
        _outputLogs.add('  journalctl -n 50         - Query recent system and service logs');
        _outputLogs.add('  cloudflared tunnel ...   - Execute Cloudflare tunnel operations');
        _outputLogs.add('  clear                    - Clear terminal console logs');
      });
      _scrollToBottom();
      return;
    }

    // Handle ldlxstrings initialization (Locked to application documents database directory)
    if (rawInput == 'ldlxstrings') {
      setState(() => _isExecuting = true);
      try {
        final appDir = await getApplicationDocumentsDirectory();
        _targetStringFilePath = p.join(appDir.path, 'ldlx_dbs', 'pushed_strings.txt');

        final file = File(_targetStringFilePath);
        if (await file.exists()) {
          final content = await file.readAsString();
          _stringFileLines = content.split('\n').where((l) => l.trim().isNotEmpty).toList();
        } else {
          _stringFileLines = ['(File is empty or does not exist yet: $_targetStringFilePath)'];
        }

        setState(() {
          _outputLogs.add('=== OPENED STRING VIEWER: $_targetStringFilePath ===');
          _outputLogs.add('Sidebar active. Click copy next to any line to copy it. Sending any command will auto-close viewer.');
          _isViewingStringFile = true;
        });
      } catch (e) {
        setState(() {
          _outputLogs.add('Error reading string file: $e');
        });
      } finally {
        setState(() => _isExecuting = false);
        _scrollToBottom();
      }
      return;
    }

    // Handle ldlxeditnet initialization
    if (rawInput.startsWith('ldlxeditnet')) {
      final parts = rawInput.split(' ');
      if (parts.length > 1) {
        _targetNetworkFilePath = parts[1];
      } else {
        _targetNetworkFilePath = '/etc/network/interfaces';
      }

      setState(() => _isExecuting = true);
      try {
        final file = File(_targetNetworkFilePath);
        if (await file.exists()) {
          final content = await file.readAsString();
          _editableConfigLines = content.split('\n');
        } else {
          _editableConfigLines = [
            '# Network Interface Configuration',
            'auto eth0',
            'iface eth0 inet dhcp',
          ];
        }

        setState(() {
          _outputLogs.add('=== OPENED EDITOR: $_targetNetworkFilePath ===');
          _outputLogs.add('Sidebar active. Type text below to append lines, or use sidebar controls to comment/save.');
          _isEditingNetworkFile = true;
        });
      } catch (e) {
        setState(() {
          _outputLogs.add('Error opening network file: $e');
        });
      } finally {
        setState(() => _isExecuting = false);
        _scrollToBottom();
      }
      return;
    }

    setState(() => _isExecuting = true);

    try {
      ProcessResult result;

      if (rawInput == 'sys-test') {
        result = await Process.run('sh', ['-c', 'echo "=== MEMORY ===" && free -h && echo "" && echo "=== STORAGE ===" && df -h /']);
      } else if (rawInput == 'sys-info') {
        result = await Process.run('sh', ['-c', 'uname -a && echo "" && lscpu | grep "Model name\\|Architecture\\|CPU(s):" && echo "" && cat /etc/os-release']);
      } else if (rawInput == 'ldlxconfignet') {
        result = await Process.run('sh', ['-c', 'echo "=== ACTIVE INTERFACES ===" && ip -brief addr && echo "" && echo "=== DEFAULT GATEWAY ===" && ip route show default']);
      } else if (rawInput.startsWith('ping') && !rawInput.contains('-c')) {
        final safePing = '$rawInput -c 4';
        result = await Process.run('sh', ['-c', safePing]);
      } else {
        result = await Process.run('sh', ['-c', rawInput]);
      }

      setState(() {
        final stdoutStr = result.stdout.toString().trim();
        final stderrStr = result.stderr.toString().trim();

        if (stdoutStr.isNotEmpty) {
          _outputLogs.add(stdoutStr);
        }
        if (stderrStr.isNotEmpty) {
          _outputLogs.add('Error/Stderr: $stderrStr');
        }
        if (stdoutStr.isEmpty && stderrStr.isEmpty) {
          _outputLogs.add('Command executed successfully with no output.');
        }
        if (result.exitCode != 0 && stderrStr.isEmpty) {
          _outputLogs.add('Process exited with code ${result.exitCode}');
        }
      });
    } catch (e) {
      setState(() {
        _outputLogs.add('Execution Exception: $e');
      });
    } finally {
      setState(() => _isExecuting = false);
      _scrollToBottom();
    }
  }

  void _toggleCommentLine(int index) {
    setState(() {
      String line = _editableConfigLines[index];
      if (line.trim().startsWith('#')) {
        _editableConfigLines[index] = line.replaceFirst(RegExp(r'#\s*'), '');
      } else {
        _editableConfigLines[index] = '# $line';
      }
    });
  }

  void _saveConfigChanges() async {
    setState(() {
      _outputLogs.add('\$ [Saving changes to $_targetNetworkFilePath...]');
    });

    try {
      final file = File(_targetNetworkFilePath);
      await file.writeAsString(_editableConfigLines.join('\n'));
      setState(() {
        _outputLogs.add('SUCCESS: Network configuration file saved successfully.');
        _isEditingNetworkFile = false;
      });
    } catch (e) {
      setState(() {
        _outputLogs.add('ERROR: Failed to save network config file: $e');
      });
    }
    _commandController.clear();
    _scrollToBottom();
  }

  void _cancelEditing() {
    setState(() {
      _isEditingNetworkFile = false;
      _outputLogs.add('\$ cancel');
      _outputLogs.add('Network configuration edit cancelled.');
      _commandController.clear();
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const Color icyBackground = Color(0xFF0F172A);
    const Color panelSurface = Color(0xFF1E293B);
    const Color silverBorder = Color(0xFF64748B);
    const Color paleBlueAccent = Color(0xFFE0F7FA);
    const Color iceBlueText = Color(0xFFB2EBF2);

    final bool showSidebar = _isEditingNetworkFile || _isViewingStringFile;

    return SizedBox(
      width: 960,
      height: 700,
      child: Container(
        decoration: BoxDecoration(
          color: icyBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: silverBorder.withOpacity(0.6), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: paleBlueAccent.withOpacity(0.1),
              blurRadius: 20,
              spreadRadius: 2,
            )
          ],
        ),
        child: Row(
          children: [
            // Main Terminal Window Section
            Expanded(
              flex: showSidebar ? 3 : 5,
              child: Column(
                children: [
                  // Terminal Title Bar
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: panelSurface,
                      borderRadius: const BorderRadius.only(topLeft: Radius.circular(16)),
                      border: Border(bottom: BorderSide(color: silverBorder.withOpacity(0.4))),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.terminal, color: paleBlueAccent, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          _isViewingStringFile
                              ? 'LDLx Terminal - Pushed Strings: $_targetStringFilePath'
                              : (_isEditingNetworkFile
                                  ? 'LDLx Terminal - Editing: $_targetNetworkFilePath'
                                  : 'LDLx Secure Terminal (Cloudflare & Diagnostics)'),
                          style: const TextStyle(
                            color: paleBlueAccent,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18, color: silverBorder),
                          onPressed: () => Navigator.pop(context),
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),

                  // Output Logs Area
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(14.0),
                      child: ListView.builder(
                        controller: _scrollController,
                        itemCount: _outputLogs.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.5),
                            child: Text(
                              _outputLogs[index],
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5,
                                color: _outputLogs[index].startsWith('\$')
                                    ? paleBlueAccent
                                    : iceBlueText,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  if (_isExecuting)
                    const LinearProgressIndicator(minHeight: 2, color: paleBlueAccent),

                  // Command Input Bar
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: panelSurface,
                      borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(16)),
                      border: Border(top: BorderSide(color: silverBorder.withOpacity(0.4))),
                    ),
                    child: Row(
                      children: [
                        Text(
                          _isEditingNetworkFile ? 'APPEND> ' : '\$ ',
                          style: const TextStyle(
                            color: paleBlueAccent,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _commandController,
                            style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12.5),
                            decoration: InputDecoration(
                              hintText: _isEditingNetworkFile
                                  ? 'Type line to append to config (or click Save/Cancel)...'
                                  : 'Enter command (e.g. ldlxstrings, ldlxeditnet, ping, ip addr ...)',
                              hintStyle: TextStyle(color: silverBorder.withOpacity(0.6), fontSize: 11.5),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                            onSubmitted: (_) => _executeCommand(),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.send, color: paleBlueAccent, size: 18),
                          onPressed: _executeCommand,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Sidebar: Pushed Strings Viewer (ldlxstrings) or Network Editor (ldlxeditnet)
            if (showSidebar) ...[
              Container(
                width: 320,
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  border: Border(left: BorderSide(color: silverBorder.withOpacity(0.5))),
                ),
                child: _isViewingStringFile
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Strings Viewer Sidebar Header
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: panelSurface,
                              borderRadius: const BorderRadius.only(topRight: Radius.circular(16)),
                              border: Border(bottom: BorderSide(color: silverBorder.withOpacity(0.4))),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Pushed Strings Viewer',
                                      style: TextStyle(
                                        color: paleBlueAccent,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      'Click copy icon next to any line.',
                                      style: TextStyle(color: silverBorder, fontSize: 10),
                                    ),
                                  ],
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close, size: 16, color: silverBorder),
                                  onPressed: () => setState(() => _isViewingStringFile = false),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                              ],
                            ),
                          ),
                          // Strings Line List with Copy Support
                          Expanded(
                            child: ListView.builder(
                              padding: const EdgeInsets.all(8),
                              itemCount: _stringFileLines.length,
                              itemBuilder: (context, index) {
                                final line = _stringFileLines[index];
                                return Container(
                                  margin: const EdgeInsets.symmetric(vertical: 3),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E293B),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: silverBorder.withOpacity(0.3)),
                                  ),
                                  child: Row(
                                    children: [
                                      Text(
                                        '${index + 1}:',
                                        style: TextStyle(color: silverBorder, fontSize: 10, fontFamily: 'monospace'),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          line,
                                          style: const TextStyle(
                                            color: iceBlueText,
                                            fontSize: 11,
                                            fontFamily: 'monospace',
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.copy, size: 14, color: paleBlueAccent),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        tooltip: 'Copy line',
                                        onPressed: () {
                                          Clipboard.setData(ClipboardData(text: line));
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text('Copied line to clipboard!'),
                                              duration: Duration(milliseconds: 1200),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Network Editor Sidebar Header
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: panelSurface,
                              borderRadius: const BorderRadius.only(topRight: Radius.circular(16)),
                              border: Border(bottom: BorderSide(color: silverBorder.withOpacity(0.4))),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Config Line Manager',
                                  style: TextStyle(
                                    color: paleBlueAccent,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Toggle comments or type below to append.',
                                  style: TextStyle(color: silverBorder, fontSize: 10.5),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.cyan.shade700,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(vertical: 8),
                                          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                        ),
                                        icon: const Icon(Icons.save, size: 14),
                                        label: const Text('SAVE'),
                                        onPressed: _saveConfigChanges,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: silverBorder,
                                          side: const BorderSide(color: silverBorder),
                                          padding: const EdgeInsets.symmetric(vertical: 8),
                                          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                        ),
                                        icon: const Icon(Icons.close, size: 14),
                                        label: const Text('CANCEL'),
                                        onPressed: _cancelEditing,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Config Lines List
                          Expanded(
                            child: ListView.builder(
                              padding: const EdgeInsets.all(8),
                              itemCount: _editableConfigLines.length,
                              itemBuilder: (context, index) {
                                final line = _editableConfigLines[index];
                                final isCommented = line.trim().startsWith('#');
                                return Container(
                                  margin: const EdgeInsets.symmetric(vertical: 3),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isCommented ? Colors.black26 : const Color(0xFF1E293B),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: silverBorder.withOpacity(0.3)),
                                  ),
                                  child: Row(
                                    children: [
                                      Text(
                                        '${index + 1}:',
                                        style: TextStyle(color: silverBorder, fontSize: 10, fontFamily: 'monospace'),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          line,
                                          style: TextStyle(
                                            color: isCommented ? silverBorder : iceBlueText,
                                            fontSize: 11,
                                            fontFamily: 'monospace',
                                            decoration: isCommented ? TextDecoration.lineThrough : null,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      InkWell(
                                        onTap: () => _toggleCommentLine(index),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: isCommented ? Colors.green.shade900 : Colors.orange.shade900,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            isCommented ? 'Uncomment' : '#',
                                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Helper function to open the terminal dialog from the sidebar with guaranteed large dimensions
void showLdlxTerminalDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => const AlertDialog(
      backgroundColor: Colors.transparent,
      contentPadding: EdgeInsets.zero,
      insetPadding: EdgeInsets.all(16),
      content: TerminalWidget(),
    ),
  );
}