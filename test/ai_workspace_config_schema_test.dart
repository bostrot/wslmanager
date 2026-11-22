import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/ai_workspace/config_schema.dart';

/// The two dialects the tools actually publish, in miniature: OpenCode's
/// 2020-12 document (`$defs` + `$ref`, unions of `const`s) and OpenClaw's
/// draft-07 one (`definitions`, deeply nested objects).
const String _openCodeStyle = '''
{
  "\$schema": "https://json-schema.org/draft/2020-12/schema",
  "\$ref": "#/\$defs/Config",
  "\$defs": {
    "LogLevel": {
      "type": "string",
      "enum": ["DEBUG", "INFO", "WARN", "ERROR"],
      "description": "Log level"
    },
    "ServerConfig": {
      "type": "object",
      "properties": {
        "port": {"type": "integer", "default": 4096},
        "hostname": {"type": "string", "default": "127.0.0.1"}
      }
    },
    "Config": {
      "type": "object",
      "properties": {
        "\$schema": {"type": "string"},
        "shell": {"type": "string", "description": "Default shell"},
        "logLevel": {"\$ref": "#/\$defs/LogLevel"},
        "server": {"\$ref": "#/\$defs/ServerConfig", "description": "Server"},
        "snapshot": {"type": "boolean"},
        "instructions": {"type": "array", "items": {"type": "string"}},
        "autoupdate": {
          "anyOf": [{"type": "boolean"}, {"type": "object"}],
          "description": "Automatically update"
        },
        "agent": {"\$ref": "#/\$defs/Config"}
      }
    }
  }
}
''';

void main() {
  group('ConfigSchema.fromJsonSchema', () {
    late ConfigSchema schema;

    setUp(() {
      schema = ConfigSchema.fromJsonSchema(
          jsonDecode(_openCodeStyle) as Map<String, dynamic>);
    });

    test('follows the root \$ref into \$defs', () {
      expect(schema.fieldAt('shell')?.kind, ConfigFieldKind.text);
      expect(schema.fieldAt('shell')?.description, 'Default shell');
    });

    test('resolves a \$ref to an enum into a choice field', () {
      final field = schema.fieldAt('logLevel');
      expect(field?.kind, ConfigFieldKind.choice);
      expect(field?.choices, ['DEBUG', 'INFO', 'WARN', 'ERROR']);
    });

    test('turns a referenced object into its own section with defaults', () {
      final field = schema.fieldAt('server.port');
      expect(field?.kind, ConfigFieldKind.integer);
      expect(field?.defaultValue, 4096);
      expect(schema.fieldAt('server.hostname')?.defaultValue, '127.0.0.1');
    });

    test('keeps the scalar branch of a scalar-or-object union', () {
      // `boolean | object` stays a switch rather than dropping to raw JSON.
      expect(schema.fieldAt('autoupdate')?.kind, ConfigFieldKind.boolean);
    });

    test('edits an array as raw JSON', () {
      expect(schema.fieldAt('instructions')?.kind, ConfigFieldKind.json);
    });

    test('drops the \$schema pointer', () {
      expect(schema.fieldAt(r'$schema'), isNull);
    });

    test('a recursive \$ref terminates instead of hanging', () {
      // `agent` points back at `Config`. Without the cycle guard this is an
      // infinite tree; with it the branch simply ends.
      expect(schema.fields, isNotEmpty);
      expect(schema.fieldAt('agent.agent.agent.shell'), isNull);
    });

    test('a boolean field is a switch and an integer a number', () {
      expect(schema.fieldAt('snapshot')?.kind, ConfigFieldKind.boolean);
      expect(schema.fieldAt('server.port')?.kind, ConfigFieldKind.integer);
    });

    test('anyOf of consts becomes a choice, as OpenClaw spells its unions',
        () {
      final openClawStyle = ConfigSchema.fromJsonSchema({
        'type': 'object',
        'properties': {
          'gateway': {
            'type': 'object',
            'title': 'Gateway',
            'properties': {
              'mode': {
                'anyOf': [
                  {'type': 'string', 'const': 'local'},
                  {'type': 'string', 'const': 'remote'},
                ],
                'title': 'Gateway Mode',
              },
              'port': {'type': 'integer'},
            },
          },
        },
      });
      final mode = openClawStyle.fieldAt('gateway.mode');
      expect(mode?.kind, ConfigFieldKind.choice);
      expect(mode?.choices, ['local', 'remote']);
      expect(mode?.label, 'Gateway Mode');
    });

    test('objects deeper than maxDepth become one raw-JSON field', () {
      final deep = ConfigSchema.fromJsonSchema({
        'type': 'object',
        'properties': {
          'a': {
            'type': 'object',
            'properties': {
              'b': {
                'type': 'object',
                'properties': {
                  'c': {
                    'type': 'object',
                    'properties': {
                      'd': {
                        'type': 'object',
                        'properties': {'e': {'type': 'string'}},
                      },
                    },
                  },
                },
              },
            },
          },
        },
      });
      expect(deep.truncated, isTrue);
      expect(deep.fieldAt('a.b.c.d')?.kind, ConfigFieldKind.json);
      expect(deep.fieldAt('a.b.c.d.e'), isNull);
    });

    test('allOf members are folded into one set of properties', () {
      final merged = ConfigSchema.fromJsonSchema({
        'definitions': {
          'Base': {
            'type': 'object',
            'properties': {'name': {'type': 'string'}},
          },
        },
        'type': 'object',
        'properties': {
          'thing': {
            'allOf': [
              {r'$ref': '#/definitions/Base'},
              {
                'type': 'object',
                'properties': {'count': {'type': 'integer'}},
              },
            ],
          },
        },
      });
      expect(merged.fieldAt('thing.name')?.kind, ConfigFieldKind.text);
      expect(merged.fieldAt('thing.count')?.kind, ConfigFieldKind.integer);
    });

    test('a credential key is marked secret wherever it appears', () {
      final withToken = ConfigSchema.fromJsonSchema({
        'type': 'object',
        'properties': {
          'gateway': {
            'type': 'object',
            'properties': {
              'auth': {
                'type': 'object',
                'properties': {
                  'token': {'type': 'string'},
                  'mode': {'type': 'string'},
                },
              },
            },
          },
        },
      });
      expect(withToken.fieldAt('gateway.auth.token')?.secret, isTrue);
      expect(withToken.fieldAt('gateway.auth.mode')?.secret, isFalse);
    });

    test('a \$ref pointing outside the document leaves the node alone', () {
      final external = ConfigSchema.fromJsonSchema({
        'type': 'object',
        'properties': {
          'thing': {r'$ref': 'https://example.invalid/other.json'},
        },
      });
      // No network call, no crash: it is simply not a form control.
      expect(external.fieldAt('thing')?.kind, ConfigFieldKind.json);
    });
  });

  group('ConfigSchema.inferred', () {
    test('derives kinds from the values a config file holds', () {
      final schema = ConfigSchema.inferred({
        'model': 'anthropic/claude',
        'port': 9119,
        'ratio': 1.5,
        'quiet': true,
        'plugins': ['a', 'b'],
        'gateway': {'mode': 'local', 'token': 'tok'},
      });
      expect(schema.fieldAt('model')?.kind, ConfigFieldKind.text);
      expect(schema.fieldAt('port')?.kind, ConfigFieldKind.integer);
      expect(schema.fieldAt('ratio')?.kind, ConfigFieldKind.number);
      expect(schema.fieldAt('quiet')?.kind, ConfigFieldKind.boolean);
      expect(schema.fieldAt('plugins')?.kind, ConfigFieldKind.json);
      expect(schema.fieldAt('gateway.mode')?.label, 'Mode');
      expect(schema.fieldAt('gateway.token')?.secret, isTrue);
    });

    test('an empty config yields an empty schema', () {
      expect(ConfigSchema.inferred(const {}).isEmpty, isTrue);
    });

    test('read-only marks every inferred field', () {
      final schema =
          ConfigSchema.inferred({'WEBUI_NAME': 'x'}, readOnly: true);
      expect(schema.fieldAt('WEBUI_NAME')?.readOnly, isTrue);
    });
  });

  group('value helpers', () {
    test('valueAtPath walks nested maps and stops at a missing step', () {
      final data = {
        'gateway': {
          'auth': {'mode': 'token'}
        }
      };
      expect(valueAtPath(data, ['gateway', 'auth', 'mode']), 'token');
      expect(valueAtPath(data, ['gateway', 'missing', 'mode']), isNull);
      expect(valueAtPath(data, ['gateway', 'auth', 'mode', 'deeper']), isNull);
    });

    test('nestedPatch rebuilds the tree from dotted keys', () {
      final patch = nestedPatch({
        'gateway.port': 19001,
        'gateway.auth.mode': 'token',
        'worktreeRoot': '/srv',
      });
      expect(patch, {
        'gateway': {
          'port': 19001,
          'auth': {'mode': 'token'},
        },
        'worktreeRoot': '/srv',
      });
    });

    test('applyPatch removes a key whose new value is null', () {
      final document = <String, dynamic>{
        'model': 'anthropic/claude',
        'gateway': {'port': 18789, 'mode': 'local'},
      };
      applyPatch(document, {
        'model': null,
        'gateway': {'mode': null},
      });
      // Cleared, not written back as an explicit null the tool would reject.
      expect(document, {
        'gateway': {'port': 18789}
      });
    });

    test('applyPatch merges objects and replaces scalars', () {
      final document = <String, dynamic>{
        'gateway': {'port': 18789, 'mode': 'local'},
        'keep': true,
      };
      applyPatch(document, {
        'gateway': {'port': 19001},
      });
      expect(document, {
        'gateway': {'port': 19001, 'mode': 'local'},
        'keep': true,
      });
    });

    test('humanizeKey splits camelCase and separators', () {
      expect(humanizeKey('worktreeRoot'), 'Worktree Root');
      expect(humanizeKey('small_model'), 'Small Model');
      expect(humanizeKey('disabled-providers'), 'Disabled Providers');
    });
  });

  group('decodeRelaxedJson', () {
    test('reads the .jsonc file OpenCode installs', () {
      final decoded = decodeRelaxedJson('''
{
  // written by the installer
  "\$schema": "https://opencode.ai/config.json",
  /* block */
  "model": "anthropic/claude",
}
''');
      expect(decoded['model'], 'anthropic/claude');
      expect(decoded[r'$schema'], 'https://opencode.ai/config.json');
    });

    test('leaves a trailing-comma-shaped string alone', () {
      // The comma inside the value is part of the text, not syntax.
      final decoded = decodeRelaxedJson('{"note": "a, }", "n": 1,}');
      expect(decoded['note'], 'a, }');
      expect(decoded['n'], 1);
    });

    test('leaves a // inside a string alone', () {
      final decoded =
          decodeRelaxedJson('{"url": "https://example.com/x", "n": 1}');
      expect(decoded['url'], 'https://example.com/x');
      expect(decoded['n'], 1);
    });

    test('rejects a document that is not an object', () {
      expect(() => decodeRelaxedJson('[1, 2]'), throwsFormatException);
      expect(() => decodeRelaxedJson('{ not json'), throwsFormatException);
    });
  });
}
