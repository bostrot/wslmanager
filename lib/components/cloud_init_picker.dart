import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/cloud_init.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// The "Cloud-init configuration" field both create pages carry: the saved
/// configurations by name, "None" first, a line under it saying when the
/// choice applies, and a link that opens the editor for a new one — pushed,
/// so the half-filled form is still there when it pops back, and the box
/// lists the new entry the moment it is saved (the store notifies).
class CloudInitPicker extends StatelessWidget {
  const CloudInitPicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.hint,
    this.enabled = true,
  });

  /// The chosen configuration's name; empty for none.
  final String value;
  final ValueChanged<String> onChanged;
  final String hint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // The field goes with the destination: while cloud-init is not switched
    // on in Settings, or not carried by the backend, a create page must not
    // offer a picker that links to a screen the pane does not show
    // (bostrot/ai-tasks#87).
    if (!ExperimentalFeatures.isVisible(ExperimentalFeature.cloudInit)) {
      return const SizedBox.shrink();
    }
    final store = CloudInitStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final items = store.items;
        // A configuration deleted since it was picked must not leave the box
        // pointing at a value it has no item for. The page still holds the
        // name and refuses the create, naming it, rather than seed nothing.
        final current = items.any((e) => e.name == value) ? value : '';
        return InfoLabel(
          label: 'cloudinitselect-text'.i18n(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ComboBox<String>(
                key: const ValueKey('test-create-cloudinit'),
                value: current,
                isExpanded: true,
                items: [
                  ComboBoxItem(
                      value: '', child: Text('cloudinitnone-text'.i18n())),
                  for (final item in items)
                    ComboBoxItem(
                      value: item.name,
                      child: Text(
                          item.description.isEmpty
                              ? item.name
                              : '${item.name} — ${item.description}',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: enabled ? (value) => onChanged(value ?? '') : null,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(hint,
                        style: TextStyle(
                            fontSize: 12, color: secondaryTextColor(context))),
                    HyperlinkButton(
                      key: const ValueKey('test-create-cloudinit-new'),
                      onPressed: enabled
                          ? () => router.pushNamed('cloudinit-editor')
                          : null,
                      child: Text('newcloudinit-text'.i18n(),
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
