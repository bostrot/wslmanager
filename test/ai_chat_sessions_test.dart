/// "New chat" files the running conversation instead of throwing it away,
/// and "Previous chats" puts one back on screen (ai-tasks#104). The store
/// behind both is what these cover: what gets filed, what it is called, and
/// that switching back and forth never leaves two copies of one thread.
// ignore_for_file: dangling_library_doc_comments

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_chat_sessions.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';

AiMessage _user(String text) =>
    AiMessage(role: 'user', content: text, timestamp: DateTime(2026, 9, 20));

AiMessage _assistant(String text) => AiMessage(
    role: 'assistant', content: text, timestamp: DateTime(2026, 9, 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sessions = AiChatSessions.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('archiving', () {
    test('files the running conversation and marks nothing current', () {
      sessions.archive([_user('why is my distro offline'), _assistant('…')]);

      final all = sessions.list();
      expect(all, hasLength(1));
      expect(all.single.messages, hasLength(2));
      expect(all.single.title, 'why is my distro offline');
      // Nothing is on screen from the history now, so the next file-away
      // starts its own entry rather than overwriting this one.
      expect(sessions.currentId, isNull);
    });

    test('an empty transcript is not worth keeping', () {
      sessions.archive(const []);
      expect(sessions.list(), isEmpty);
    });

    test('the newest chat is first', () {
      sessions.archive([_user('first')]);
      sessions.archive([_user('second')]);

      expect(sessions.list().map((s) => s.title), ['second', 'first']);
    });

    test('drops the oldest past the cap', () {
      for (var i = 0; i < AiChatSessions.maxSessions + 3; i++) {
        sessions.archive([_user('chat $i')]);
      }

      final all = sessions.list();
      expect(all, hasLength(AiChatSessions.maxSessions));
      expect(all.first.title, 'chat ${AiChatSessions.maxSessions + 2}');
      expect(all.last.title, 'chat 3');
    });

    test('a frozen clock still files each chat separately', () {
      // Windows resolves DateTime.now() to about 15ms, so a run of archives
      // can share a microsecondsSinceEpoch. Holding the clock still is the
      // worst case of that: every id would collide, and each chat would
      // replace the one before it.
      AiChatSessions.now = () => DateTime.utc(2026, 9, 20, 12);
      addTearDown(() => AiChatSessions.now = DateTime.now);

      sessions.archive([_user('one')]);
      sessions.archive([_user('two')]);
      sessions.archive([_user('three')]);

      expect(sessions.list().map((s) => s.title), ['three', 'two', 'one']);
      expect(sessions.list().map((s) => s.id).toSet(), hasLength(3));
    });

    test('notifies so the panel repaints', () {
      var notifications = 0;
      void listener() => notifications++;
      sessions.addListener(listener);
      addTearDown(() => sessions.removeListener(listener));

      sessions.archive([_user('hello')]);
      expect(notifications, 1);
    });
  });

  group('titles', () {
    test('come from the first question, not from a tool note', () {
      sessions.archive([
        AiMessage(
            role: 'tool',
            content: 'wsl_list',
            timestamp: DateTime(2026, 9, 20)),
        _user('  list   my\n distros  '),
        _user('and the second one'),
      ]);

      expect(sessions.list().single.title, 'list my distros');
    });

    test('are cut short rather than filling the flyout', () {
      final long = 'a' * (AiChatSession.maxTitleLength + 20);
      sessions.archive([_user(long)]);

      final title = sessions.list().single.title;
      expect(title.length, AiChatSession.maxTitleLength + 1);
      expect(title.endsWith('…'), isTrue);
    });

    test('a chat with no question at all has none', () {
      sessions.archive([_assistant('I had a look around.')]);
      expect(sessions.list().single.title, isEmpty);
    });
  });

  group('reopening', () {
    test('returns the stored chat and files the running one', () {
      sessions.archive([_user('older thread')]);
      final stored = sessions.list().single;

      final reopened = sessions.switchTo(stored.id, [_user('live thread')]);

      expect(reopened, isNotNull);
      expect(reopened!.single.content, 'older thread');
      // The reopened chat is the one on screen, so it leaves the list; the
      // conversation it replaced takes its place there.
      expect(sessions.list().map((s) => s.title), ['live thread']);
      expect(sessions.currentId, stored.id);
    });

    test('switching back and forth keeps one entry per thread', () {
      sessions.archive([_user('alpha')]);
      final alpha = sessions.list().single.id;

      // Open alpha with beta on screen, then go back to beta.
      sessions.switchTo(alpha, [_user('beta')]);
      final beta = sessions.list().single.id;
      sessions.switchTo(beta, [_user('alpha'), _assistant('more')]);

      final all = sessions.list();
      expect(all, hasLength(1));
      expect(all.single.id, alpha);
      // The turn added while alpha was on screen came back with it.
      expect(all.single.messages, hasLength(2));
    });

    test('an id that is gone changes nothing', () {
      sessions.archive([_user('kept')]);

      expect(sessions.switchTo('no-such-chat', [_user('live')]), isNull);
      expect(sessions.list().map((s) => s.title), ['kept']);
    });

    test('reopening with an empty transcript files nothing in its place', () {
      sessions.archive([_user('only chat')]);
      final id = sessions.list().single.id;

      expect(sessions.switchTo(id, const []), isNotNull);
      expect(sessions.list(), isEmpty);
    });
  });

  group('the stored blob', () {
    test('survives a restart', () {
      sessions.archive([_user('remembered'), _assistant('sure')]);
      final before = sessions.list().single;

      // A fresh read of prefs is what the next launch does.
      final after = AiChatSessions.instance.list().single;
      expect(after.id, before.id);
      expect(after.updatedAt, before.updatedAt);
      expect(after.messages.map((m) => m.content),
          ['remembered', 'sure']);
    });

    test('unreadable history is treated as none, not as a crash', () async {
      SharedPreferences.setMockInitialValues(
          {AiChatSessions.prefsKey: 'not json at all'});
      prefs = await SharedPreferences.getInstance();

      expect(sessions.list(), isEmpty);
    });

    test('clear forgets everything', () {
      sessions.archive([_user('one')]);
      sessions.archive([_user('two')]);

      sessions.clear();

      expect(sessions.list(), isEmpty);
      expect(sessions.currentId, isNull);
      expect(prefs.getString(AiChatSessions.prefsKey), isNull);
    });

    test('remove drops a single chat', () {
      sessions.archive([_user('keep me')]);
      sessions.archive([_user('drop me')]);
      final doomed = sessions.list().first.id;

      sessions.remove(doomed);

      expect(sessions.list().map((s) => s.title), ['keep me']);
    });
  });
}
