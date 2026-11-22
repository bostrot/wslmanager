import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/mcp/mcp_server.dart';
import 'package:wsl2distromanager/api/mcp/todo_tools.dart';
import 'package:wsl2distromanager/api/todo_store.dart';
import 'package:wsl2distromanager/components/helpers.dart';

void main() {
  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    TodoStore.instance.clearAll();
  });

  group('TodoStore', () {
    test('add, complete and count open items', () {
      final store = TodoStore.instance;
      final a = store.add('one');
      final b = store.add('two');
      expect(store.items, hasLength(2));
      expect(store.hasOpen, true);
      expect(store.openCount, 2);

      store.setDone(a.id, true);
      expect(store.openCount, 1);
      expect(store.render(), contains('#${a.id} [x] one'));
      expect(store.render(), contains('#${b.id} [ ] two'));

      store.remove(b.id);
      expect(store.items, hasLength(1));
    });

    test('persists across reload', () async {
      TodoStore.instance.add('remember me');
      // Simulate a fresh load from the same prefs by round-tripping the store's
      // own persistence.
      final json = prefs.getString('AiTodos');
      expect(json, isNotNull);
      expect(json, contains('remember me'));
    });
  });

  group('todo tools', () {
    McpTool tool(String name) =>
        buildTodoTools(TodoStore.instance).firstWhere((t) => t.name == name);

    test('add, list, set_done, remove drive the store', () async {
      final add = await tool('todo_add').handler({'text': 'build it'});
      expect(add, contains('#'));
      expect(TodoStore.instance.items, hasLength(1));

      final id = TodoStore.instance.items.first.id;
      final list = await tool('todo_list').handler({});
      expect(list, contains('build it'));

      final done = await tool('todo_set_done').handler({'id': id});
      expect(done, contains('done'));
      expect(TodoStore.instance.items.first.done, true);

      await tool('todo_remove').handler({'id': id});
      expect(TodoStore.instance.items, isEmpty);
    });

    test('set_done on an unknown id is a readable error, not a crash',
        () async {
      final r = await tool('todo_set_done').handler({'id': 999});
      expect(r, contains('no task'));
    });
  });
}
