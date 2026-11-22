import 'package:wsl2distromanager/api/mcp/mcp_server.dart';
import 'package:wsl2distromanager/api/todo_store.dart';

/// Tools that let the assistant read and drive the chat's task queue, so the
/// user can add todos and tell it to "work through these until done".
List<McpTool> buildTodoTools(TodoStore store) {
  return [
    McpTool(
      name: 'todo_list',
      description:
          'List the current task queue with each item\'s id and done state. '
          'Call this to see what is left to do.',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (_) async => store.render(),
    ),
    McpTool(
      name: 'todo_add',
      description: 'Add a task to the queue. Returns its id.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': 'The task.'},
        },
        'required': ['text'],
      },
      handler: (args) async {
        final text = (args['text'] as String?)?.trim() ?? '';
        if (text.isEmpty) return 'Error: text is required.';
        final item = store.add(text);
        return 'Added task #${item.id}.';
      },
    ),
    McpTool(
      name: 'todo_set_done',
      description:
          'Mark a task done (or not). Do this as soon as you finish each '
          'task so the queue reflects progress.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'description': 'Task id from todo_list.'},
          'done': {
            'type': 'boolean',
            'description': 'True to complete (default), false to reopen.',
          },
        },
        'required': ['id'],
      },
      handler: (args) async {
        final id = (args['id'] as num?)?.toInt();
        if (id == null) return 'Error: id is required.';
        final done = args['done'] as bool? ?? true;
        if (!store.setDone(id, done)) return 'Error: no task #$id.';
        return 'Task #$id marked ${done ? "done" : "open"}. '
            '${store.openCount} still open.';
      },
    ),
    McpTool(
      name: 'todo_remove',
      description: 'Remove a task from the queue by id.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'description': 'Task id from todo_list.'},
        },
        'required': ['id'],
      },
      handler: (args) async {
        final id = (args['id'] as num?)?.toInt();
        if (id == null) return 'Error: id is required.';
        return store.remove(id) ? 'Removed task #$id.' : 'Error: no task #$id.';
      },
    ),
  ];
}
