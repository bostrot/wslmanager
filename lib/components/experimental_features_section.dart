import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// The "Experimental features" section of Settings: one switch per
/// [ExperimentalFeature] the active backend can carry, each off until the
/// user decides otherwise (bostrot/ai-tasks#87). A flip is written to the
/// pref straight away and announced through
/// [ExperimentalFeatures.generation], which this section and the shell
/// both rebuild on, so the pane follows without a restart.
class ExperimentalFeaturesSection extends StatelessWidget {
  const ExperimentalFeaturesSection({super.key});

  /// The switch's widget key for [feature], for tests.
  static Key switchKey(ExperimentalFeature feature) =>
      ValueKey('test-experimental-${feature.name}');

  @override
  Widget build(BuildContext context) {
    final hintStyle =
        TextStyle(color: secondaryTextColor(context), fontSize: 12);
    return ListenableBuilder(
      listenable: ExperimentalFeatures.generation,
      builder: (context, _) {
        final backend = vmBackend();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text('experimentalfeatures-info-text'.i18n()),
            ),
            // A feature the backend cannot carry gets no switch — unless it
            // is on, so a choice made on another backend (Cloud on local
            // WSL, then a remote target) can still be taken back here.
            for (final feature in ExperimentalFeature.values)
              if (feature.offeredBy(backend) ||
                  ExperimentalFeatures.isEnabled(feature))
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: InfoLabel(
                    label: feature.labelKey.i18n(),
                    labelStyle: const TextStyle(fontWeight: FontWeight.w500),
                    child: Row(children: [
                      ToggleSwitch(
                        key: ExperimentalFeaturesSection.switchKey(feature),
                        checked: ExperimentalFeatures.isEnabled(feature),
                        onChanged: (value) =>
                            ExperimentalFeatures.setEnabled(feature, value),
                      ),
                      const SizedBox(width: 10.0),
                      Expanded(
                          child:
                              Text(feature.infoKey.i18n(), style: hintStyle)),
                    ]),
                  ),
                ),
          ],
        );
      },
    );
  }
}
