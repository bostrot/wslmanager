import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/templates.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// Template Screen
class TemplatePage extends StatefulWidget {
  const TemplatePage({super.key});

  @override
  State<TemplatePage> createState() => _TemplatePageState();
}

/// Template Screen State
class _TemplatePageState extends State<TemplatePage> {
  List<String> _templates = [];

  @override
  void initState() {
    super.initState();

    _templates = Templates().getTemplates();
  }

  void editTemplateDialog(String name) {
    final context = GlobalVariable.infobox.currentContext!;
    final nameController = TextEditingController(text: name);
    final descriptionController =
        TextEditingController(text: Templates().getTemplateDescription(name));

    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: Text('edittemplate-text'.i18n()),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InfoLabel(
                label: 'name-text'.i18n(),
                child: TextBox(
                  controller: nameController,
                ),
              ),
              const SizedBox(height: 10),
              InfoLabel(
                label: 'description-text'.i18n(),
                child: TextBox(
                  controller: descriptionController,
                  placeholder: 'descriptionhint-text'.i18n(),
                  maxLines: 3,
                ),
              ),
            ],
          ),
          actions: [
            Button(
              child: Text('save-text'.i18n()),
              onPressed: () async {
                Navigator.pop(context);
                String newName = nameController.text;
                String description = descriptionController.text;

                if (newName.isNotEmpty) {
                  await Templates().renameTemplate(name, newName);
                  await Templates()
                      .setTemplateDescription(newName, description);
                  setState(() {
                    _templates = Templates().getTemplates();
                  });
                }
              },
            ),
            Button(
              child: Text('cancel-text'.i18n()),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_templates.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color:
                    FluentTheme.of(context).accentColor.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                FluentIcons.page,
                size: 26,
                color: FluentTheme.of(context).accentColor,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'notemplates-text'.i18n(),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: secondaryTextColor(context), fontSize: 14),
            ),
            const SizedBox(height: 8),
            // What a template is and where one comes from — the screen used
            // to open on a bare list with neither (audit ST-41).
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                (vmBackend().features.templatesDeprecated
                    ? 'templatesinfo-text'
                    : 'templatesinfo-vm-text')
                .i18n(),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: secondaryTextColor(context), fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }
    // Scrollable list with template items, under a title and one sentence
    // saying what a template is (audit ST-41).
    return Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4.0, bottom: 4.0),
              child: Text('templates-text'.i18n(),
                  style: FluentTheme.of(context).typography.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
              child: Text((vmBackend().features.templatesDeprecated
                    ? 'templatesinfo-text'
                    : 'templatesinfo-vm-text')
                .i18n(),
                  style: TextStyle(
                      color: secondaryTextColor(context), fontSize: 12)),
            ),
            // Distro packages cover the same ground in the official WSL
            // format; templates are on their way out there and say so up
            // front. On backends without packaging (Apple virtualization)
            // templates stay a first-class feature, so no banner.
            if (vmBackend().features.templatesDeprecated)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: InfoBar(
                key: const ValueKey('test-templates-deprecated'),
                severity: InfoBarSeverity.warning,
                isLong: true,
                title: Text('templatesdeprecated-text'.i18n()),
                content: Text('templatesdeprecatedinfo-text'.i18n()),
                action: Button(
                  onPressed: () =>
                      navigateGuarded('package', path: '/package'),
                  child: Text('opendistropackages-text'.i18n()),
                ),
              ),
            ),
            Expanded(
                child: ListView.builder(
          itemCount: _templates.length,
          itemBuilder: (context, index) {
            var name = _templates[index];
            var size = Templates().getTemplateSize(name);
            var description = Templates().getTemplateDescription(name);

            // Every template renders. A small one used to format to '0 GB'
            // and its row became a zero-height box — present on disk,
            // unusable and undeletable from the UI (audit ST-37).
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Expander(
                header: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(size.isEmpty ? name : '$name ($size)'),
                    if (description.isNotEmpty)
                      Text(
                        description,
                        style: FluentTheme.of(context).typography.caption,
                      ),
                  ],
                ),
                // Delete used to be pushed 900px to the far right by a
                // `spaceBetween`, an unlabelled icon nowhere near the two
                // labelled buttons it belongs with (audit ST-40).
                content: Row(
                  children: [
                    Row(
                      children: [
                        Button(
                            child: Row(
                              children: [
                                const Icon(FluentIcons.add),
                                const SizedBox(
                                  width: 10.0,
                                ),
                                Text('createnewinstance-text'.i18n()),
                              ],
                            ),
                            // The button said Create, the dialog said
                            // "Copy 'test-4' ... the WSL instance" — three
                            // verbs for one action, about an object that is
                            // not a WSL instance (audit ST-39).
                            onPressed: () => dialog(
                                item: name,
                                title: 'createnewinstance-text'.i18n(),
                                body: 'createfromtemplate-text'.i18n([name]),
                                submitText: 'create-text'.i18n(),
                                submitStyle: const ButtonStyle(),
                                validateInput: (inputText) => inputText.isEmpty
                                    ? 'errorentername-text'.i18n()
                                    : null,
                                onSubmit: (inputText) async {
                                  await Templates()
                                      .useTemplate(name, inputText);
                                })),
                        const SizedBox(width: 10),
                        Button(
                          child: Row(
                            children: [
                              const Icon(FluentIcons.edit),
                              const SizedBox(width: 10.0),
                              Text('edittemplate-text'.i18n()),
                            ],
                          ),
                          onPressed: () => editTemplateDialog(name),
                        ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Button(
                      key: ValueKey('test-template-delete-$name'),
                      style: ButtonStyle(
                        foregroundColor:
                            ButtonState.all(destructiveColor(context)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(FluentIcons.delete,
                              color: destructiveColor(context)),
                          const SizedBox(width: 10.0),
                          Text('deletetemplate-text'.i18n()),
                        ],
                      ),
                      onPressed: () {
                        // A template is an archive file, not a WSL instance.
                        // This asked "Delete instance … permanently? / If you
                        // delete this Distro …" — the distro string, reused
                        // for a third kind of object (audit ST-38).
                        dialog(
                            item: name,
                            title: 'deletetemplatequestion-text'.i18n([name]),
                            body: 'deletetemplatebody-text'.i18n(),
                            submitText: 'delete-text'.i18n(),
                            submitInput: false,
                            submitStyle: ButtonStyle(
                              backgroundColor: ButtonState.all(Colors.red),
                              foregroundColor: ButtonState.all(Colors.white),
                            ),
                            onSubmit: (inputText) async {
                              await Templates().deleteTemplate(name);
                              _templates.remove(name);
                              setState(() {});
                            });
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        )),
          ],
        ));
  }
}
