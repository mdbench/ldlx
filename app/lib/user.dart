import 'package:flutter/material.dart';
import 'db_service.dart';

class UserView extends StatefulWidget {
  final UserAccount currentUser;

  const UserView({Key? key, required this.currentUser}) : super(key: key);

  @override
  State<UserView> createState() => _UserViewState();
}

class _UserViewState extends State<UserView> {
  List<ActivityLog> _logs = [];
  List<ActivityLog> _filteredLogs = [];
  List<FailedLogin> _fails = [];
  List<FailedLogin> _filteredFails = [];

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _failsSearchController = TextEditingController();

  bool get isAdmin => widget.currentUser.role.toLowerCase() == 'admin';

  @override
  void initState() {
    super.initState();
    _fetchLogs();
    if (isAdmin) {
      _fetchFailedLogins();
    }
    _searchController.addListener(_applySearch);
    _failsSearchController.addListener(_applyFailsSearch);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _failsSearchController.dispose();
    super.dispose();
  }

  Future<void> _fetchLogs() async {
    final logs = await DbService().getLogs(
      usernameFilter: isAdmin ? null : widget.currentUser.username,
    );
    setState(() {
      _logs = logs;
      _applySearch();
    });
  }

  Future<void> _fetchFailedLogins() async {
    final fails = await DbService().getFailedLogins();
    setState(() {
      _fails = fails;
      _applyFailsSearch();
    });
  }

  void _applySearch() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      _filteredLogs = _logs.where((log) {
        final matchesUser = log.username.toLowerCase().contains(query);
        final matchesAction = log.action.toLowerCase().contains(query);
        final matchesDetails = log.details.toLowerCase().contains(query);
        return matchesUser || matchesAction || matchesDetails;
      }).toList();
    });
  }

  void _applyFailsSearch() {
    final query = _failsSearchController.text.trim().toLowerCase();
    setState(() {
      _filteredFails = _fails.where((fail) {
        final matchesIp = fail.ip.toLowerCase().contains(query);
        final matchesUser = fail.username.toLowerCase().contains(query);
        final matchesPass = fail.password.toLowerCase().contains(query);
        return matchesIp || matchesUser || matchesPass;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('User Profile & Activity Logs', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Active User: ${widget.currentUser.username} | Role: ${widget.currentUser.role}',
                    style: TextStyle(color: colorScheme.secondary),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  _fetchLogs();
                  if (isAdmin) _fetchFailedLogins();
                },
                tooltip: 'Refresh Logs',
              ),
            ],
          ),
          const SizedBox(height: 20),

          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left Panel: Main Activity Logs
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Card(
                        color: colorScheme.surface,
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: isAdmin ? 'Search all logs by user, action, or details...' : 'Search your activity logs...',
                              prefixIcon: const Icon(Icons.search),
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Card(
                          color: colorScheme.surface,
                          child: _filteredLogs.isEmpty
                              ? const Center(child: Text('No activity logs found.'))
                              : ListView.separated(
                                  itemCount: _filteredLogs.length,
                                  separatorBuilder: (context, index) => const Divider(height: 1),
                                  itemBuilder: (context, index) {
                                    final log = _filteredLogs[index];
                                    return ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: colorScheme.primary.withOpacity(0.15),
                                        child: Icon(
                                          _getLogIcon(log.action),
                                          color: colorScheme.secondary,
                                          size: 20,
                                        ),
                                      ),
                                      title: Row(
                                        children: [
                                          Text(log.username, style: const TextStyle(fontWeight: FontWeight.bold)),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: colorScheme.primary.withOpacity(0.2),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              log.action,
                                              style: TextStyle(fontSize: 11, color: colorScheme.secondary),
                                            ),
                                          ),
                                        ],
                                      ),
                                      subtitle: Text(log.details),
                                      trailing: Text(
                                        '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')} - ${log.timestamp.month}/${log.timestamp.day}/${log.timestamp.year}',
                                        style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Right Panel: Admin-Only Failed Login Telemetry
                if (isAdmin) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Container(
                      padding: const EdgeInsets.all(16.0),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colorScheme.error.withOpacity(0.3)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.08),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.gpp_bad, color: colorScheme.error, size: 22),
                              const SizedBox(width: 8),
                              Text(
                                'Failed Login Telemetry (fails.db)',
                                style: TextStyle(
                                  color: colorScheme.onSurface,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),

                          // Search Bar for Failed Logins
                          TextField(
                            controller: _failsSearchController,
                            style: TextStyle(color: colorScheme.onSurface, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Search IP, username, password...',
                              hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                              prefixIcon: Icon(Icons.search, color: colorScheme.error, size: 18),
                              filled: true,
                              fillColor: colorScheme.surfaceContainerHighest,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(color: colorScheme.outlineVariant),
                              ),
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 12),

                          Expanded(
                            child: _filteredFails.isEmpty
                                ? Center(
                                    child: Text(
                                      'No failed authentication attempts.',
                                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                                    ),
                                  )
                                : ListView(
                                    children: _buildGroupedFailuresList(context, _filteredFails),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildGroupedFailuresList(BuildContext context, List<FailedLogin> fails) {
    final now = DateTime.now();
    final sevenDaysAgo = now.subtract(const Duration(days: 7));
    final threeMonthsAgo = DateTime(
      now.month > 3 ? now.year : now.year - 1,
      now.month > 3 ? now.month - 3 : now.month + 9,
      now.day,
    );

    final List<FailedLogin> lastWeekFails = [];
    final List<FailedLogin> lastThreeMonthsFails = [];
    final List<FailedLogin> olderFails = [];

    for (var fail in fails) {
      if (fail.timestamp.isAfter(sevenDaysAgo)) {
        lastWeekFails.add(fail);
      } else if (fail.timestamp.isAfter(threeMonthsAgo)) {
        lastThreeMonthsFails.add(fail);
      } else {
        olderFails.add(fail);
      }
    }

    List<Widget> sections = [];

    // 1. Daily Dropdowns for Last Week
    if (lastWeekFails.isNotEmpty) {
      sections.add(_buildCategoryHeader('Last 7 Days (Daily Logins)'));
      final Map<String, List<FailedLogin>> dailyMap = {};
      for (var f in lastWeekFails) {
        final key = '${f.timestamp.year}-${f.timestamp.month.toString().padLeft(2, '0')}-${f.timestamp.day.toString().padLeft(2, '0')}';
        dailyMap.putIfAbsent(key, () => []).add(f);
      }

      dailyMap.forEach((dateKey, items) {
        sections.add(_buildAccordionTile(
          title: 'Day: $dateKey (${items.length} attempts)',
          icon: Icons.calendar_today_outlined,
          color: Theme.of(context).colorScheme.primary,
          items: items,
        ));
      });
    }

    // 2. Monthly Dropdowns for Previous 3 Months
    if (lastThreeMonthsFails.isNotEmpty) {
      sections.add(_buildCategoryHeader('Previous 3 Months (Monthly Aggregates)'));
      final Map<String, List<FailedLogin>> monthlyMap = {};
      for (var f in lastThreeMonthsFails) {
        final key = '${_getMonthName(f.timestamp.month)} ${f.timestamp.year}';
        monthlyMap.putIfAbsent(key, () => []).add(f);
      }

      monthlyMap.forEach((monthKey, items) {
        sections.add(_buildAccordionTile(
          title: '$monthKey (${items.length} attempts)',
          icon: Icons.date_range_outlined,
          color: Theme.of(context).colorScheme.secondary,
          items: items,
        ));
      });
    }

    // 3. Yearly Dropdowns
    if (olderFails.isNotEmpty) {
      sections.add(_buildCategoryHeader('Historical Archives (Year to Year)'));
      final Map<String, List<FailedLogin>> yearlyMap = {};
      for (var f in olderFails) {
        final key = 'Year ${f.timestamp.year}';
        yearlyMap.putIfAbsent(key, () => []).add(f);
      }

      yearlyMap.forEach((yearKey, items) {
        sections.add(_buildAccordionTile(
          title: '$yearKey (${items.length} attempts)',
          icon: Icons.history_edu_outlined,
          color: Theme.of(context).colorScheme.tertiary,
          items: items,
        ));
      });
    }

    return sections;
  }

  Widget _buildCategoryHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 12.0, bottom: 6.0),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildAccordionTile({
    required String title,
    required IconData icon,
    required Color color,
    required List<FailedLogin> items,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        leading: Icon(icon, color: color, size: 18),
        title: Text(
          title,
          style: TextStyle(
            color: colorScheme.onSurface,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        children: items.map((f) => _buildFailedLoginCard(f)).toList(),
      ),
    );
  }

  Widget _buildFailedLoginCard(FailedLogin fail) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
      padding: const EdgeInsets.all(10.0),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: colorScheme.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'IP: ${fail.ip}',
                      style: TextStyle(
                        color: colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      '${fail.timestamp.hour.toString().padLeft(2, '0')}:${fail.timestamp.minute.toString().padLeft(2, '0')}:${fail.timestamp.second.toString().padLeft(2, '0')}',
                      style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'User Attempted: ${fail.username.isEmpty ? "<blank>" : fail.username}',
                  style: TextStyle(color: colorScheme.onSurface, fontSize: 12),
                ),
                Text(
                  'Pass Attempted: ${fail.password.isEmpty ? "<blank>" : fail.password}',
                  style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getMonthName(int month) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[month - 1];
  }

  IconData _getLogIcon(String action) {
    switch (action.toLowerCase()) {
      case 'authentication':
        return Icons.login;
      case 'navigation':
        return Icons.tab;
      case 'user created':
        return Icons.person_add;
      case 'user modified':
        return Icons.manage_accounts;
      case 'user deleted':
        return Icons.person_remove;
      default:
        return Icons.history;
    }
  }
}