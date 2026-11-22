import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/mcp/mcp_server.dart';

void main() {
  late McpServer server;
  late List<Map<String, dynamic>> calls;

  setUp(() {
    calls = [];
    server = McpServer(
      serverName: 'test-server',
      serverVersion: '1.2.3',
      tools: [
        McpTool(
          name: 'echo',
          description: 'Echoes the given text back.',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'}
            },
            'required': ['text'],
          },
          handler: (args) async {
            calls.add(args);
            return args['text'] as String;
          },
        ),
        McpTool(
          name: 'boom',
          description: 'Always throws.',
          inputSchema: const {'type': 'object', 'properties': {}},
          handler: (_) async => throw Exception('kaboom'),
        ),
      ],
    );
  });

  test('initialize reports protocol version and server info', () async {
    final response = await server.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
    });

    expect(response, isNotNull);
    expect(response!['id'], 1);
    final result = response['result'] as Map<String, dynamic>;
    expect(result['protocolVersion'], mcpProtocolVersion);
    expect(result['serverInfo'], {'name': 'test-server', 'version': '1.2.3'});
    expect(result['capabilities'], {'tools': {}});
  });

  test('tools/list returns the registered tools with their schemas',
      () async {
    final response = await server.handle({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });

    final tools = response!['result']['tools'] as List;
    expect(tools.map((t) => t['name']), ['echo', 'boom']);
    expect(tools.first['description'], 'Echoes the given text back.');
    expect(tools.first['inputSchema'], isA<Map>());
  });

  test('tools/call invokes the matching tool and wraps the result as text',
      () async {
    final response = await server.handle({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {
        'name': 'echo',
        'arguments': {'text': 'hello'},
      },
    });

    expect(calls, [
      {'text': 'hello'}
    ]);
    final result = response!['result'] as Map<String, dynamic>;
    expect(result['isError'], false);
    expect(result['content'], [
      {'type': 'text', 'text': 'hello'}
    ]);
  });

  test('tools/call reports a thrown exception as an isError result, not a '
      'transport-level failure', () async {
    final response = await server.handle({
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'tools/call',
      'params': {'name': 'boom', 'arguments': {}},
    });

    final result = response!['result'] as Map<String, dynamic>;
    expect(result['isError'], true);
    expect(result['content'][0]['text'], contains('kaboom'));
  });

  test('tools/call with an unknown tool name returns a JSON-RPC error',
      () async {
    final response = await server.handle({
      'jsonrpc': '2.0',
      'id': 5,
      'method': 'tools/call',
      'params': {'name': 'does_not_exist', 'arguments': {}},
    });

    expect(response!['error'], isNotNull);
    expect(response['error']['code'], -32602);
  });

  test('an unknown method returns a JSON-RPC "method not found" error',
      () async {
    final response = await server.handle({
      'jsonrpc': '2.0',
      'id': 6,
      'method': 'not/a/real/method',
    });

    expect(response!['error']['code'], -32601);
  });

  test('a notification (no id) produces no response', () async {
    final response = await server.handle({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });

    expect(response, isNull);
  });
}
