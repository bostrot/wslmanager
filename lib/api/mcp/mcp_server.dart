// Minimal MCP server core: the synchronous JSON-RPC subset (initialize,
// tools/list, tools/call). No SSE streaming or resumable sessions.
//
// Transport-agnostic — operates on decoded JSON maps so the protocol logic
// is unit testable without a server.

const String mcpProtocolVersion = '2025-06-18';

/// How a call of one tool goes into the record of an AI chat run — the
/// snippet the run is saved as when it created or changed an instance
/// (lib/api/ai_run_recorder.dart, ai-tasks#77).
///
/// Declared on the tool, next to the arguments it names, rather than kept
/// as a list of tool names somewhere else that has to be remembered when a
/// tool is added. A tool with no [McpTool.recording] is read-only as far as
/// the record is concerned.
class ToolRecording {
  const ToolRecording({this.target, this.shell, this.supporting = false});

  /// The argument naming the instance the call acts on (`distro`, `name`,
  /// `container`), or null when the call has none (`.wslconfig`, a disk
  /// mount).
  final String? target;

  /// The argument holding a shell command that ran inside the instance —
  /// the snippet carries it verbatim, so Run replays it.
  final String? shell;

  /// True for a call worth recording only next to others: starting a VM
  /// belongs in the record of a create-and-set-up run, but a run that only
  /// started one has changed nothing worth a snippet.
  final bool supporting;
}

/// A single tool exposed to MCP clients.
class McpTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Future<String> Function(Map<String, dynamic> arguments) handler;

  /// Set when the tool creates, changes or removes an instance; see
  /// [ToolRecording]. Null for read-only tools.
  final ToolRecording? recording;

  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
    this.recording,
  });
}

class McpServer {
  final String serverName;
  final String serverVersion;
  final List<McpTool> tools;

  McpServer({
    required this.serverName,
    required this.serverVersion,
    required this.tools,
  });

  /// Handle one decoded JSON-RPC message. Returns the JSON-RPC response map,
  /// or null if [message] was a notification (no `id`) that expects no reply.
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> message) async {
    final id = message['id'];
    final method = message['method'] as String?;

    if (method == null) {
      return id == null ? null : _error(id, -32600, 'Invalid Request');
    }

    // Notifications never get a response, even on error.
    if (id == null) {
      return null;
    }

    switch (method) {
      case 'initialize':
        return _result(id, {
          'protocolVersion': mcpProtocolVersion,
          'capabilities': {'tools': {}},
          'serverInfo': {'name': serverName, 'version': serverVersion},
        });

      case 'tools/list':
        return _result(id, {
          'tools': tools
              .map((t) => {
                    'name': t.name,
                    'description': t.description,
                    'inputSchema': t.inputSchema,
                  })
              .toList(),
        });

      case 'tools/call':
        // Normalize rather than cast: a Map literal from a direct caller has
        // different generic parameters than json.decode's output, and a rigid
        // cast throws on it.
        final rawParams = message['params'];
        final params =
            rawParams is Map ? Map<String, dynamic>.from(rawParams) : null;
        final toolName = params?['name'] as String?;
        final rawArguments = params?['arguments'];
        final arguments = rawArguments is Map
            ? Map<String, dynamic>.from(rawArguments)
            : <String, dynamic>{};

        final tool = tools.where((t) => t.name == toolName).firstOrNull;
        if (tool == null) {
          return _error(id, -32602, 'Unknown tool: $toolName');
        }

        try {
          final text = await tool.handler(arguments);
          return _result(id, {
            'content': [
              {'type': 'text', 'text': text}
            ],
            'isError': false,
          });
        } catch (e) {
          return _result(id, {
            'content': [
              {'type': 'text', 'text': e.toString()}
            ],
            'isError': true,
          });
        }

      default:
        return _error(id, -32601, 'Method not found: $method');
    }
  }

  Map<String, dynamic> _result(dynamic id, Map<String, dynamic> result) => {
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      };

  Map<String, dynamic> _error(dynamic id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
