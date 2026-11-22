import 'package:flutter/widgets.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/components/helpers.dart';

class Recommendation {
  final String key; // i18n key for the message
  final String? actionRoute; // optional route to navigate on tap
  final VoidCallback? onTap; // optional custom callback
  final int priority; // lower = higher priority, shown first

  Recommendation({
    required this.key,
    this.actionRoute,
    this.onTap,
    this.priority = 0,
  });
}

class RecommenderService {
  static final RecommenderService _instance = RecommenderService._internal();
  factory RecommenderService() => _instance;
  RecommenderService._internal();

  LicenseManager get _license => LicenseManager();

  /// Analyze current state and return relevant recommendations
  List<Recommendation> analyze(List<String> distroNames) {
    final recommendations = <Recommendation>[];

    // Check if user has many Docker-based distros
    final dockerCount = prefs.getInt('DockerImageCount') ?? 0;
    if (dockerCount >= 3) {
      recommendations.add(Recommendation(
        key: 'recommend-docker-template',
        actionRoute: '/templates',
        priority: 1,
      ));
    }

    // Check for large distros that could benefit from cleanup
    for (final name in distroNames) {
      final sizeStr = prefs.getString('DistroSize_$name');
      if (sizeStr != null && _parseSizeGB(sizeStr) > 10) {
        recommendations.add(Recommendation(
          key: 'recommend-cleanup',
          priority: 2,
        ));
        break; // Only show once
      }
    }

    // Check if any distro is missing systemd config (common issue)
    final hasSystemdIssue = _checkSystemdIssues(distroNames);
    if (hasSystemdIssue) {
      recommendations.add(Recommendation(
        key: 'recommend-systemd',
        priority: 3,
      ));
    }

    // Pro-only AI-powered recommendations
    if (_license.isPro) {
      _addAiPoweredRecommendations(recommendations);
    }

    // Sort by priority and limit to 3 visible
    recommendations.sort((a, b) => a.priority.compareTo(b.priority));
    return recommendations.take(3).toList();
  }

  double _parseSizeGB(String sizeStr) {
    final match = RegExp(r'([\d.]+)\s*GB').firstMatch(sizeStr);
    if (match != null) {
      return double.tryParse(match.group(1)!) ?? 0;
    }
    return 0;
  }

  bool _checkSystemdIssues(List<String> distroNames) {
    // Check if user has tried to start services that require systemd
    final hasServiceErrors = prefs.getBool('HasServiceError') ?? false;
    return hasServiceErrors;
  }

  void _addAiPoweredRecommendations(List<Recommendation> recommendations) {
    // AI-powered recommendations would come from the backend
    // For now, this is a placeholder for future implementation
  }

  /// Track that user encountered a service error (for systemd recommendation)
  static void reportServiceError() {
    prefs.setBool('HasServiceError', true);
  }

  /// Track Docker image download count
  static void incrementDockerCount() {
    final current = prefs.getInt('DockerImageCount') ?? 0;
    prefs.setInt('DockerImageCount', current + 1);
  }

  /// Dismiss one recommendation.
  ///
  /// This used to be called `clearDismissed`, a name that promised the exact
  /// opposite of what it did — it *adds* to the dismissed list (audit PS-42).
  void dismiss(String key) {
    final dismissed = prefs.getStringList('DismissedRecommendations') ?? [];
    if (!dismissed.contains(key)) {
      dismissed.add(key);
      prefs.setStringList('DismissedRecommendations', dismissed);
    }
  }

  /// Check if a recommendation was dismissed
  bool isDismissed(String key) {
    final dismissed = prefs.getStringList('DismissedRecommendations') ?? [];
    return dismissed.contains(key);
  }

  /// Reset all dismissal state (e.g., after app update)
  void reset() {
    prefs.remove('DismissedRecommendations');
  }
}
