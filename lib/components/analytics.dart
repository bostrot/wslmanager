library wsl2distromanager.analytics;

import 'package:plausible_analytics/plausible_analytics.dart';

String analyticsUrl = "https://analytics.bostrot.com";
const String analyticsName = "wslmanager.bostrot.com";

Plausible plausible = Plausible(analyticsUrl, analyticsName);

/// Where an "Upgrade to Pro" button was pressed — the AI Workspace paywall,
/// the chat panel, one of the Settings cards or the pane itself — so the
/// licence screen's views can be set against the paywall that sent them.
/// Every button lands on the same screen, and a pageview of it says
/// nothing about which feature the user wanted.
void trackUpgradeClick(String source) {
  plausible.event(name: 'upgrade_clicked', props: {'source': source});
}
