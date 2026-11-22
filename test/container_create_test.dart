/// The create path: what a filled-in form is allowed to say, and the argv it
/// becomes. Pure — no engine is launched here, which is the point of keeping
/// [ContainerCreateRequest] out of the service.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/containers/container_create_request.dart';

void main() {
  group('argv', () {
    test('a bare image runs detached and nothing else', () {
      final request = ContainerCreateRequest.parse(image: 'alpine');
      expect(request.toArguments(), ['run', '--detach', 'alpine']);
    });

    test('every field lands on its own flag, image last before the command',
        () {
      final request = ContainerCreateRequest.parse(
        image: 'nginx:1.27',
        name: 'web',
        ports: '8080:80\n127.0.0.1:8443:443/tcp',
        volumes: 'mydata:/data\n/srv/html:/usr/share/nginx/html:ro',
        env: 'TZ=Europe/Berlin\nDEBUG=1',
        command: 'nginx -g "daemon off;"',
        removeOnExit: true,
      );
      expect(request.toArguments(), [
        'run',
        '--detach',
        '--rm',
        '--name', 'web',
        '--publish', '8080:80',
        '--publish', '127.0.0.1:8443:443/tcp',
        '--volume', 'mydata:/data',
        '--volume', '/srv/html:/usr/share/nginx/html:ro',
        '--env', 'TZ=Europe/Berlin',
        '--env', 'DEBUG=1',
        'nginx:1.27',
        'nginx', '-g', 'daemon off;',
      ]);
    });

    test('blank lines in a list box are not empty flags', () {
      final request = ContainerCreateRequest.parse(
        image: 'alpine',
        ports: '\n8080:80\n\n  \n',
      );
      expect(request.toArguments(), [
        'run', '--detach', '--publish', '8080:80', 'alpine',
      ]);
    });

    test('--detach is never dropped, so the dialog cannot wait on a TTY', () {
      // -it would leave the engine reading a stdin a GUI does not have.
      final request = ContainerCreateRequest.parse(image: 'alpine');
      expect(request.toArguments().contains('--detach'), isTrue);
      expect(request.toArguments(), isNot(contains('-it')));
      expect(request.toArguments(), isNot(contains('--interactive')));
    });
  });

  group('command splitting', () {
    test('quotes group, and are not passed on', () {
      expect(ContainerCreateRequest.parseCommand('sh -c "echo a  b"'),
          ['sh', '-c', 'echo a  b']);
      expect(ContainerCreateRequest.parseCommand("sh -c 'echo \$HOME'"),
          ['sh', '-c', 'echo \$HOME']);
    });

    test('runs of whitespace collapse, and tabs count', () {
      expect(ContainerCreateRequest.parseCommand('  sleep\t\t3600  '),
          ['sleep', '3600']);
    });

    test('an empty command is no command at all', () {
      expect(ContainerCreateRequest.parseCommand('   '), isEmpty);
    });

    test('an empty quoted token survives as an empty argument', () {
      expect(ContainerCreateRequest.parseCommand('sh -c ""'), ['sh', '-c', '']);
    });

    test('an unclosed quote is a field error, not a silent truncation', () {
      expect(
        () => ContainerCreateRequest.parseCommand('sh -c "echo a'),
        throwsA(isA<ContainerFieldError>().having(
            (e) => e.field, 'field', ContainerCreateRequest.fieldCommand)),
      );
    });
  });

  group('flag injection', () {
    // The whole reason the validators refuse a leading dash: argv entries are
    // never re-split by a shell, but the *engine* still reads them as options.
    test('an image that looks like a flag is refused', () {
      expect(ContainerCreateRequest.validateImage('--privileged'),
          ContainerCreateRequest.keyFlagLike);
    });

    test('a name that looks like a flag is refused', () {
      expect(ContainerCreateRequest.validateName('--network=host'),
          ContainerCreateRequest.keyFlagLike);
    });

    test('a port, volume and variable that look like flags are refused', () {
      expect(ContainerCreateRequest.validatePort('--publish-all'),
          ContainerCreateRequest.keyFlagLike);
      expect(ContainerCreateRequest.validateVolume('--mount=x'),
          ContainerCreateRequest.keyFlagLike);
      expect(ContainerCreateRequest.validateEnv('--env-file=/etc/shadow'),
          ContainerCreateRequest.keyEnv);
    });

    test('parse reports the field, so the dialog can point at the box', () {
      expect(
        () => ContainerCreateRequest.parse(image: '-v'),
        throwsA(isA<ContainerFieldError>().having(
            (e) => e.field, 'field', ContainerCreateRequest.fieldImage)),
      );
      expect(
        () => ContainerCreateRequest.parse(image: 'alpine', ports: '--rm'),
        throwsA(isA<ContainerFieldError>().having(
            (e) => e.field, 'field', ContainerCreateRequest.fieldPorts)),
      );
    });
  });

  group('image', () {
    test('references the engines accept pass', () {
      for (final image in [
        'alpine',
        'nginx:1.27',
        'ghcr.io/owner/app:v2',
        'registry.example.com:5000/team/app@sha256:abc123',
        'mcr.microsoft.com/windows/servercore',
      ]) {
        expect(ContainerCreateRequest.validateImage(image), isNull,
            reason: image);
      }
    });

    test('empty and malformed are refused', () {
      expect(ContainerCreateRequest.validateImage(''),
          ContainerCreateRequest.keyImage);
      expect(ContainerCreateRequest.validateImage('two words'),
          ContainerCreateRequest.keyImage);
      expect(ContainerCreateRequest.validateImage('alpine;rm -rf /'),
          ContainerCreateRequest.keyImage);
    });
  });

  group('name', () {
    test('empty is allowed — the engine invents one', () {
      expect(ContainerCreateRequest.validateName(''), isNull);
    });

    test('the engines\' own character set passes', () {
      expect(ContainerCreateRequest.validateName('web_1.2-a'), isNull);
    });

    test('a leading dot and a space are refused', () {
      expect(ContainerCreateRequest.validateName('.hidden'),
          ContainerCreateRequest.keyName);
      expect(ContainerCreateRequest.validateName('my container'),
          ContainerCreateRequest.keyName);
    });
  });

  group('ports', () {
    test('the three accepted shapes, with and without a protocol', () {
      for (final port in [
        '80',
        '8080:80',
        '127.0.0.1:8080:80',
        '8080:80/udp',
        '0.0.0.0:8080:80/tcp',
        '65535:1',
      ]) {
        expect(ContainerCreateRequest.validatePort(port), isNull, reason: port);
      }
    });

    test('out-of-range and non-numeric ports are refused', () {
      expect(ContainerCreateRequest.validatePort('0:80'),
          ContainerCreateRequest.keyPort);
      expect(ContainerCreateRequest.validatePort('65536:80'),
          ContainerCreateRequest.keyPort);
      expect(ContainerCreateRequest.validatePort('http:80'),
          ContainerCreateRequest.keyPort);
      expect(ContainerCreateRequest.validatePort('8080:'),
          ContainerCreateRequest.keyPort);
    });

    test('a bad protocol and a bad host address are refused', () {
      expect(ContainerCreateRequest.validatePort('8080:80/sctp'),
          ContainerCreateRequest.keyPort);
      expect(ContainerCreateRequest.validatePort('999.1.1.1:8080:80'),
          ContainerCreateRequest.keyPort);
      expect(ContainerCreateRequest.validatePort('localhost:8080:80'),
          ContainerCreateRequest.keyPort);
    });
  });

  group('volumes', () {
    test('named volumes, absolute paths and :ro pass', () {
      for (final volume in [
        'mydata:/data',
        '/srv/www:/usr/share/nginx/html',
        '/srv/www:/usr/share/nginx/html:ro',
        'mydata:/data:rw',
      ]) {
        expect(ContainerCreateRequest.validateVolume(volume), isNull,
            reason: volume);
      }
    });

    test('a Windows source keeps its drive colon', () {
      // The reason the split hunts for the colon that starts "/dst" rather
      // than taking the first one: C:\src:/dst has two.
      expect(ContainerCreateRequest.validateVolume(r'C:\src:/src'), isNull);
      expect(ContainerCreateRequest.validateVolume(r'D:/data:/data:ro'), isNull);
    });

    test('a relative container path is refused', () {
      expect(ContainerCreateRequest.validateVolume('mydata:data'),
          ContainerCreateRequest.keyVolume);
    });

    test('no colon at all is refused', () {
      expect(ContainerCreateRequest.validateVolume('/srv/www'),
          ContainerCreateRequest.keyVolume);
    });

    test('an empty source is refused', () {
      expect(ContainerCreateRequest.validateVolume(':/data'),
          ContainerCreateRequest.keyVolume);
    });
  });

  group('environment', () {
    test('a value may hold spaces, equals signs and quotes', () {
      // One argv entry, so none of this needs escaping — and a password with
      // a space in it is an ordinary thing to pass an image.
      expect(ContainerCreateRequest.validateEnv('MSG=hello world'), isNull);
      expect(ContainerCreateRequest.validateEnv('DSN=k=v;x=y'), isNull);
      expect(ContainerCreateRequest.validateEnv('EMPTY='), isNull);
    });

    test('a missing or malformed key is refused', () {
      expect(ContainerCreateRequest.validateEnv('JUSTAWORD'),
          ContainerCreateRequest.keyEnv);
      expect(ContainerCreateRequest.validateEnv('=value'),
          ContainerCreateRequest.keyEnv);
      expect(ContainerCreateRequest.validateEnv('2FA=x'),
          ContainerCreateRequest.keyEnv);
      expect(ContainerCreateRequest.validateEnv('my key=x'),
          ContainerCreateRequest.keyEnv);
    });
  });

  group('summary', () {
    test('names what will run, for the status bar', () {
      final request = ContainerCreateRequest.parse(
          image: 'alpine', name: 'demo', ports: '8080:80', removeOnExit: true);
      expect(request.summary, 'demo · alpine · ports=8080:80 · --rm');
    });
  });

  test('every key the validators return exists in en.json', () {
    // A validator that returns a key nothing translates would show the raw
    // key in the dialog.
    final en = json.decode(File('lib/i18n/en.json').readAsStringSync())
        as Map<String, dynamic>;
    for (final key in [
      ContainerCreateRequest.keyImage,
      ContainerCreateRequest.keyName,
      ContainerCreateRequest.keyPort,
      ContainerCreateRequest.keyVolume,
      ContainerCreateRequest.keyEnv,
      ContainerCreateRequest.keyCommand,
      ContainerCreateRequest.keyFlagLike,
    ]) {
      expect(en.containsKey(key), isTrue, reason: 'missing $key');
    }
  });
}
