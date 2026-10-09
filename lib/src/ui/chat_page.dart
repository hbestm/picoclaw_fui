import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:picoclaw_flutter_ui/src/core/core_api_client.dart';
import 'widgets/bilingual_text.dart';
import 'widgets/core_auth_gate.dart';

/// 聊天页面 - 通过 Web 后台的 /pico/ws 代理与网关的 Pico Protocol 通信。
/// 代理需要 dashboard 登录态（cookie），由 [CoreAuthGate] 保证；
/// 服务端会在转发时自动注入网关 token。
class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    return CoreAuthGate(
      builder: (context, client) => _ChatView(client: client),
    );
  }
}

class _ChatView extends StatefulWidget {
  final CoreApiClient client;
  const _ChatView({required this.client});

  @override
  State<_ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<_ChatView> {
  static const _keySessionId = 'session_id';
  static const _keyHistory = 'chat_history_v1';
  static const _maxHistory = 100;

  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <_ChatMessage>[];
  final _uuid = const Uuid();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _isConnected = false;
  bool _isSending = false;
  late String _sessionId;
  _ChatMessage? _streamingMessage;

  @override
  void initState() {
    super.initState();
    _initChat();
  }

  Future<void> _initChat() async {
    _sessionId = await _getOrCreateSessionId();
    final restored = await _loadHistory();
    if (!mounted) return;
    if (restored) {
      // 有历史记录：直接重连，不刷欢迎语
      _connectToGateway();
    } else {
      _addMessage(
          _ChatMessage(
              tr(context, '正在连接 AI 助手...', 'Connecting to AI assistant...'),
              _Role.assistant),
          transient: true);
      _connectToGateway();
    }
  }

  /// 从本地恢复历史消息，返回是否有历史。
  Future<bool> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_keyHistory);
      if (raw == null || raw.isEmpty) return false;
      final list = jsonDecode(raw) as List;
      final msgs = <_ChatMessage>[];
      for (final e in list) {
        if (e is Map) {
          final content = (e['c'] ?? '').toString();
          if (content.isEmpty) continue;
          msgs.add(_ChatMessage(
            content,
            e['r'] == 'u' ? _Role.user : _Role.assistant,
          ));
        }
      }
      if (msgs.isEmpty) return false;
      setState(() => _messages.addAll(msgs));
      _scrollToBottom();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 持久化历史消息（不含"思考中"等临时消息）。
  Future<void> _persistMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _messages
          .where((m) => !m.isThinking && m.content.isNotEmpty)
          .toList();
      final trimmed =
          list.length > _maxHistory ? list.sublist(list.length - _maxHistory) : list;
      await prefs.setString(
        _keyHistory,
        jsonEncode([
          for (final m in trimmed)
            {'c': m.content, 'r': m.role == _Role.user ? 'u' : 'a'}
        ]),
      );
    } catch (_) {}
  }

  Future<String> _getOrCreateSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_keySessionId);
    if (id == null) {
      id = _uuid.v4();
      await prefs.setString(_keySessionId, id);
    }
    return id;
  }

  void _connectToGateway() {
    try {
      // 走 Web 后台的 WebSocket 代理（18800），它会校验 dashboard cookie
      // 并在转发给网关时自动带上 pico token。
      final uri = Uri.parse(
        '${widget.client.wsBaseUrl}/pico/ws?session_id=$_sessionId',
      );
      final cookie = widget.client.sessionCookie;
      _channel = IOWebSocketChannel.connect(
        uri,
        headers: {
          if (cookie != null)
            'Cookie': '${CoreApiClient.cookieName}=$cookie',
        },
      );

      _subscription = _channel!.stream.listen(
        (data) => _handleGatewayMessage(data.toString()),
        onDone: () {
          if (mounted) {
            setState(() {
              _isConnected = false;
              _isSending = false;
            });
            _addMessage(_ChatMessage(tr(context, '⚠️ 连接已断开', '⚠️ Connection lost'), _Role.assistant));
          }
        },
        onError: (error) {
          if (mounted) {
            setState(() {
              _isConnected = false;
              _isSending = false;
            });
            _addMessage(
              _ChatMessage(
                tr(context, '❌ 连接失败: $error\n请确保 PicoClaw 服务正在运行。',
                    '❌ Connection failed: $error\nMake sure the PicoClaw service is running.'),
                _Role.assistant,
              ),
            );
          }
        },
      );

      // WebSocketChannel.connect 成功后不会触发 onOpen 回调，
      // 通过监听 ready future 来确认连接成功
      _channel!.ready
          .then((_) {
            if (mounted) {
              setState(() {
                _isConnected = true;
                _messages.clear();
              });
              _addMessage(
                _ChatMessage(tr(context, '你好！我是 AI 助手，有什么可以帮你的？', 'Hi! I\'m your AI assistant. How can I help?'), _Role.assistant),
              );
            }
          })
          .catchError((e) {
            if (mounted) {
              setState(() {
                _isConnected = false;
              });
              _addMessage(_ChatMessage(tr(context, '❌ 连接失败: $e', '❌ Connection failed: $e'), _Role.assistant));
            }
          });
    } catch (e) {
      _addMessage(_ChatMessage('❌ 连接错误: $e', _Role.assistant));
    }
  }

  void _handleGatewayMessage(String text) {
    try {
      final msg = jsonDecode(text) as Map<String, dynamic>;
      final type = msg['type'] as String? ?? '';
      final payload = msg['payload'] as Map<String, dynamic>?;

      switch (type) {
        case 'message.create':
          final content = payload?['content'] as String? ?? '';
          if (content.isNotEmpty) {
            setState(() {
              _removeThinkingMessage();
              _isSending = false;
              if (_streamingMessage != null) {
                // 流式输出的最终消息：直接定稿
                _streamingMessage!.content = content;
                _streamingMessage!.isStreaming = false;
                _streamingMessage = null;
              } else {
                _messages.add(_ChatMessage(content, _Role.assistant));
              }
            });
            _scrollToBottom();
            _persistMessages();
          }
          break;
        case 'message.update':
          // 流式增量：更新同一条消息，而不是追加多条
          final content = payload?['content'] as String? ?? '';
          if (content.isNotEmpty) {
            setState(() {
              _removeThinkingMessage();
              if (_streamingMessage == null) {
                _streamingMessage = _ChatMessage(
                  content,
                  _Role.assistant,
                  isStreaming: true,
                );
                _messages.add(_streamingMessage!);
              } else {
                _streamingMessage!.content = content;
              }
            });
            _scrollToBottom();
          }
          break;
        case 'typing.start':
          if (!_messages.any((m) => m.isThinking)) {
            _addMessage(
              _ChatMessage(tr(context, '正在思考...', 'Thinking...'), _Role.assistant, isThinking: true),
            );
          }
          break;
        case 'typing.stop':
          // typing stop 由 message.create 隐式处理
          break;
        case 'error':
          final errorMsg = payload?['message'] as String? ?? '未知错误';
          setState(() {
            _removeThinkingMessage();
            _isSending = false;
          });
          _addMessage(_ChatMessage(tr(context, '❌ 错误: $errorMsg', '❌ Error: $errorMsg'), _Role.assistant));
          break;
        case 'pong':
          break; // 忽略心跳
      }
    } catch (e) {
      _addMessage(_ChatMessage(tr(context, '❌ 解析消息失败: $e', '❌ Failed to parse message: $e'), _Role.assistant));
    }
  }

  void _removeThinkingMessage() {
    _messages.removeWhere((m) => m.isThinking);
  }

  void _addMessage(_ChatMessage message, {bool transient = false}) {
    if (!mounted) return;
    setState(() {
      _messages.add(message);
    });
    _scrollToBottom();
    if (!transient && !message.isThinking) _persistMessages();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    if (!_isConnected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr(context, '未连接到 AI 服务，正在重连...', 'Not connected to AI service, reconnecting...'))));
      _connectToGateway();
      return;
    }

    _messageController.clear();
    _addMessage(_ChatMessage(text, _Role.user));
    _addMessage(_ChatMessage(tr(context, '正在思考...', 'Thinking...'), _Role.assistant, isThinking: true));
    setState(() => _isSending = true);

    // 通过 WebSocket 发送 Pico Protocol 消息
    final picoMsg = jsonEncode({
      'type': 'message.send',
      'id': _uuid.v4(),
      'session_id': _sessionId,
      'payload': {'content': text},
    });

    try {
      _channel?.sink.add(picoMsg);
    } catch (e) {
      setState(() {
        _removeThinkingMessage();
        _isSending = false;
      });
      _addMessage(_ChatMessage(tr(context, '❌ 发送失败，请重试', '❌ Send failed, please retry'), _Role.assistant));
    }
  }

  void _clearChat() async {
    final prefs = await SharedPreferences.getInstance();
    _sessionId = _uuid.v4();
    await prefs.setString(_keySessionId, _sessionId);
    await prefs.remove(_keyHistory);

    setState(() {
      _messages.clear();
      _streamingMessage = null;
      _isSending = false;
    });

    _subscription?.cancel();
    _channel?.sink.close();
    _addMessage(
        _ChatMessage(
            tr(context, '正在开始新对话...', 'Starting a new conversation...'),
            _Role.assistant),
        transient: true);
    _connectToGateway();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _channel?.sink.close();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: colorScheme.secondary.withAlpha(25),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.smart_toy_outlined,
                size: 48,
                color: colorScheme.secondary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              tr(context, '开始对话', 'Start chatting'),
              style: GoogleFonts.inter(
                  fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              _isConnected
                  ? tr(context, '在下方输入框中向 AI 提问',
                      'Ask the AI anything below')
                  : tr(context, '正在连接网关…请确保服务已启动',
                      'Connecting to gateway… make sure the service is running'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface.withAlpha(140),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          tr(context, '对话', 'Chat'),
          style: GoogleFonts.inter(fontWeight: FontWeight.w700),
        ),
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        actions: [
          // 连接状态指示
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: (_isConnected ? Colors.green : Colors.red).withAlpha(30),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _isConnected ? Colors.green : Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  _isConnected
                      ? tr(context, '已连接', 'Connected')
                      : tr(context, '未连接', 'Offline'),
                  style: TextStyle(
                    fontSize: 11,
                    color: _isConnected ? Colors.green : Colors.red,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: tr(context, '清空对话', 'Clear chat'),
            onPressed: _clearChat,
          ),
        ],
      ),
      body: Column(
        children: [
          // 消息列表
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState(colorScheme)
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        return _MessageBubble(message: message);
                      },
                    ),
                  ),
          ),
          // 输入区域
          Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: colorScheme.outlineVariant.withAlpha(50),
                ),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: tr(context, '输入消息...', 'Type a message...'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHigh,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      maxLines: null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: _isSending
                        ? colorScheme.outline
                        : colorScheme.secondary,
                    borderRadius: BorderRadius.circular(24),
                    child: InkWell(
                      onTap: _isSending ? null : _sendMessage,
                      borderRadius: BorderRadius.circular(24),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          Icons.send_rounded,
                          color: colorScheme.onSecondary,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- 数据模型 ---

enum _Role { user, assistant }

class _ChatMessage {
  String content;
  final _Role role;
  final bool isThinking;
  bool isStreaming;

  _ChatMessage(this.content, this.role,
      {this.isThinking = false, this.isStreaming = false});
}

// --- 消息气泡组件 ---

class _MessageBubble extends StatelessWidget {
  final _ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isUser = message.role == _Role.user;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: colorScheme.secondary.withAlpha(30),
              child: Icon(
                Icons.smart_toy_outlined,
                size: 18,
                color: colorScheme.secondary,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? colorScheme.secondary.withAlpha(40)
                    : colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
              ),
              child: message.isThinking
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.secondary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          message.content,
                          style: TextStyle(
                            color: colorScheme.onSurface.withAlpha(150),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    )
                  : isUser
                      ? Text(
                          message.content,
                          style: TextStyle(
                            color: colorScheme.onSurface,
                            height: 1.4,
                          ),
                        )
                      : MarkdownBody(
                          data: message.content,
                          selectable: false,
                          styleSheet: MarkdownStyleSheet.fromTheme(
                            Theme.of(context),
                          ).copyWith(
                            p: TextStyle(
                              color: colorScheme.onSurface,
                              height: 1.45,
                              fontSize: 14.5,
                            ),
                            code: TextStyle(
                              color: colorScheme.secondary,
                              backgroundColor:
                                  colorScheme.secondary.withAlpha(25),
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                            codeblockDecoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest
                                  .withAlpha(140),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor: colorScheme.primary.withAlpha(30),
              child: Icon(
                Icons.person_outline,
                size: 18,
                color: colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
