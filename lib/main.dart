import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: 'assets/env/.env');

  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];

  if (supabaseUrl == null || supabaseUrl.isEmpty) {
    throw StateError(
      'SUPABASE_URL is missing or empty in assets/env/.env',
    );
  }
  if (supabaseAnonKey == null || supabaseAnonKey.isEmpty) {
    throw StateError(
      'SUPABASE_ANON_KEY is missing or empty in assets/env/.env',
    );
  }

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Biblioteca Inteligente',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const SessionRouter(),
    );
  }
}

class SessionRouter extends StatelessWidget {
  const SessionRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final client = Supabase.instance.client;
    return StreamBuilder<AuthState>(
      stream: client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = snapshot.data?.session ?? client.auth.currentSession;
        if (session == null) {
          return const AuthScreen();
        }
        return const LibraryScreen();
      },
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLogin = true;
  bool _submitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);

    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final auth = Supabase.instance.client.auth;

    try {
      if (_isLogin) {
        await auth.signInWithPassword(email: email, password: password);
      } else {
        await auth.signUp(email: email, password: password);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cuenta creada, inicia sesión.')),
        );
        setState(() => _isLogin = true);
      }
    } on AuthException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _isLogin ? 'Iniciar sesión' : 'Crear cuenta',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: 'Correo electrónico',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Ingresa un correo válido';
                        }
                        if (!value.contains('@')) {
                          return 'El correo debe contener @';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Contraseña',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.length < 6) {
                          return 'La contraseña debe tener al menos 6 caracteres';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(_isLogin ? 'Entrar' : 'Registrarme'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () => setState(() => _isLogin = !_isLogin),
                      child: Text(
                        _isLogin
                            ? '¿No tienes cuenta? Regístrate'
                            : '¿Ya tienes cuenta? Inicia sesión',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _bucket = dotenv.env['SUPABASE_BUCKET'] ?? 'login_b';
  final Set<String> _textExtensions = {'.txt', '.md', '.csv', '.json'};

  List<StoredFile> _files = [];
  bool _loadingFiles = true;
  bool _summaryLoading = false;
  bool _uploading = false;
  List<ConversationEntry> _conversationHistory = [];
  bool _loadingHistory = false;
  String? _summary;

  @override
  void initState() {
    super.initState();
    _loadFiles();
    _loadConversationHistory();
  }

  String? _normalizeModelId(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('models/')) {
      return trimmed.substring('models/'.length);
    }
    return trimmed;
  }

  String _trimForPrompt(String value, {int max = 400}) {
    if (value.length <= max) return value;
    return '${value.substring(0, max)}...';
  }

  Future<void> _loadFiles() async {
    setState(() => _loadingFiles = true);
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;

    if (userId == null) {
      setState(() {
        _files = [];
        _loadingFiles = false;
      });
      return;
    }

    try {
      final objects = await client.storage.from(_bucket).list(path: userId);
      final files = objects
          .map(
            (item) => StoredFile(
              name: item.name,
              fullPath: '$userId/${item.name}',
              createdAt: _parseDate(item.createdAt),
            ),
          )
          .toList()
        ..sort(
          (a, b) => (b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
        );

      setState(() => _files = files);
    } catch (error) {
      _showSnack('No se pudieron cargar los archivos: $error');
    } finally {
      if (mounted) {
        setState(() => _loadingFiles = false);
      }
    }
  }

  String _conversationPath(String userId) =>
      '$userId/__history/summary_history.json';

  Future<void> _loadConversationHistory() async {
    setState(() => _loadingHistory = true);
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;

    if (userId == null) {
      setState(() {
        _conversationHistory = [];
        _loadingHistory = false;
      });
      return;
    }

    try {
      final bytes =
          await client.storage.from(_bucket).download(_conversationPath(userId));
      final decoded = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
      final history = decoded
          .whereType<Map<String, dynamic>>()
          .map(ConversationEntry.fromJson)
          .toList();
      if (mounted) {
        setState(() => _conversationHistory = history);
      }
    } on StorageException catch (error) {
      if (error.statusCode == 404) {
        // No history stored yet. Ignore.
      } else if (mounted) {
        _showSnack('No se pudo cargar el historial: ${error.message}');
      }
    } catch (error) {
      if (mounted) {
        _showSnack('No se pudo cargar el historial: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _loadingHistory = false);
      }
    }
  }

  Future<void> _storeConversationHistory() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || _conversationHistory.isEmpty) return;

    final payload = jsonEncode(
      _conversationHistory.map((entry) => entry.toJson()).toList(),
    );
    final bytes = Uint8List.fromList(utf8.encode(payload));

    try {
      await client.storage.from(_bucket).uploadBinary(
            _conversationPath(userId),
            bytes,
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'application/json',
            ),
          );
    } catch (error) {
      if (mounted) {
        _showSnack('No se pudo guardar el historial: $error');
      }
    }
  }

  List<ConversationEntry> _recentHistory(int limit) {
    if (_conversationHistory.length <= limit) {
      return List<ConversationEntry>.from(_conversationHistory);
    }
    return _conversationHistory
        .sublist(_conversationHistory.length - limit)
        .toList();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  DateTime? _parseDate(dynamic value) {
    if (value is DateTime) {
      return value;
    }
    if (value is String) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  Future<void> _uploadDocument() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;

    if (userId == null) {
      _showSnack('Primero inicia sesión nuevamente.');
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: true,
    );

    if (result == null) return;

    final file = result.files.single;
    Uint8List? fileBytes = file.bytes;

    if (fileBytes == null) {
      _showSnack('No se pudo leer el archivo seleccionado.');
      return;
    }

    final sanitizedName = _sanitizeFileName(file.name);
    final objectPath =
        '$userId/${DateTime.now().millisecondsSinceEpoch}_$sanitizedName';

    setState(() => _uploading = true);

    try {
      await client.storage.from(_bucket).uploadBinary(
            objectPath,
            fileBytes,
            fileOptions: const FileOptions(upsert: false),
          );
      await _loadFiles();

      _showSnack('Archivo "${file.name}" guardado.');
    } on StorageException catch (error) {
      _showSnack('Error de almacenamiento: ${error.message}');
    } catch (error) {
      _showSnack('No se pudo subir el archivo: $error');
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  String _sanitizeFileName(String original) {
    final collapsedWhitespace = original.replaceAll(RegExp(r'\s+'), '_');
    final safeCharacters =
        collapsedWhitespace.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safeCharacters;
  }

  Future<void> _deleteFile(StoredFile file) async {
    final client = Supabase.instance.client;

    try {
      await client.storage.from(_bucket).remove([file.fullPath]);
      await _loadFiles();
      _showSnack('Archivo "${file.name}" eliminado.');
    } on StorageException catch (error) {
      _showSnack('No se pudo eliminar: ${error.message}');
    } catch (error) {
      _showSnack('Error al eliminar archivo: $error');
    }
  }

  Future<void> _generateSummary() async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    final modelIdRaw = dotenv.env['GEMINI_MODEL'] ?? 'gemini-pro';
    final modelId = _normalizeModelId(modelIdRaw);
    if (apiKey == null || apiKey.isEmpty) {
      _showSnack('Configura GEMINI_API_KEY en assets/env/.env');
      return;
    }

    if (modelId == null || modelId.isEmpty) {
      _showSnack('Configura GEMINI_MODEL en assets/env/.env');
      return;
    }

    if (_files.isEmpty) {
      _showSnack('Aún no hay documentos que resumir.');
      return;
    }

    setState(() => _summaryLoading = true);

    try {
      final client = Supabase.instance.client;
      final textContents = await _collectTextDocuments(client);

      final prompt = StringBuffer()
        ..writeln(
            'Genera un resumen ejecutivo en español de los archivos listados.')
        ..writeln(
            'Incluye los puntos principales y recomendaciones accionables.')
        ..writeln('Archivos disponibles:');

      for (final file in _files) {
        prompt.writeln('- ${file.name}');
      }

      final previous = _recentHistory(3);
      if (previous.isNotEmpty) {
        prompt.writeln('Contexto de resúmenes previos:');
        for (final entry in previous) {
          prompt
            ..writeln(
                '- ${entry.timestamp.toIso8601String()}: ${_trimForPrompt(entry.summary)}');
        }
      }

      if (textContents.isEmpty) {
        prompt.writeln(
            'No hay contenido textual disponible; crea un resumen a partir de los nombres y extensiones.');
      } else {
        prompt.writeln('Fragmentos de contenido de soporte:');
        textContents.forEach((name, snippet) {
          prompt
            ..writeln('Documento: $name')
            ..writeln(snippet)
            ..writeln('---');
        });
      }

      final model = GenerativeModel(
        model: modelId,
        apiKey: apiKey,
      );

      final response = await model.generateContent([
        Content.text(prompt.toString()),
      ]);

      final summaryText = response.text?.trim() ??
          'No se recibió respuesta del modelo. Intenta nuevamente.';

      final historyEntry = ConversationEntry(
        timestamp: DateTime.now(),
        files: _files.map((file) => file.name).toList(),
        prompt: _trimForPrompt(prompt.toString(), max: 2000),
        summary: summaryText,
      );

      setState(() {
        _summary = summaryText;
        _conversationHistory = [..._conversationHistory, historyEntry];
      });
      await _storeConversationHistory();
    } catch (error) {
      _showSnack('No se pudo generar el resumen: $error');
    } finally {
      if (mounted) {
        setState(() => _summaryLoading = false);
      }
    }
  }

  Future<Map<String, String>> _collectTextDocuments(
    SupabaseClient client,
  ) async {
    final Map<String, String> snippets = {};
    for (final file in _files) {
      final extension = p.extension(file.name).toLowerCase();
      if (!_textExtensions.contains(extension)) continue;
      final content = await _readFileAsText(client, file);
      if (content == null) continue;
      final snippet =
          content.length > 4000 ? content.substring(0, 4000) : content;
      snippets[file.name] = snippet;
    }
    return snippets;
  }

  Future<String?> _readFileAsText(
    SupabaseClient client,
    StoredFile file,
  ) async {
    final extension = p.extension(file.name).toLowerCase();
    if (!_textExtensions.contains(extension)) return null;
    try {
      final bytes =
          await client.storage.from(_bucket).download(file.fullPath);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openDocument(StoredFile file) async {
    final client = Supabase.instance.client;
    final extension = p.extension(file.name).toLowerCase();

    try {
      if (_textExtensions.contains(extension)) {
        final content = await _readFileAsText(client, file);
        if (content == null) {
          _showSnack('No se pudo leer el archivo ${file.name}.');
          return;
        }
        if (!mounted) return;
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (context) {
            final height = MediaQuery.of(context).size.height * 0.8;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  height: height,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          child: SelectableText(content),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
        return;
      }

      final url = await client.storage
          .from(_bucket)
          .createSignedUrl(file.fullPath, 60 * 5);
      final uri = Uri.parse(url);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        _showSnack('No se pudo abrir el archivo. Usa este enlace: $url');
      }
    } catch (error) {
      _showSnack('No se pudo abrir el archivo: $error');
    }
  }

  Map<String, int> _buildStats() {
    final stats = <String, int>{};
    for (final file in _files) {
      final extension = file.extensionLabel;
      stats[extension] = (stats[extension] ?? 0) + 1;
    }
    return stats;
  }

  @override
  Widget build(BuildContext context) {
    final userEmail = Supabase.instance.client.auth.currentUser?.email ?? '';
    final stats = _buildStats();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Biblioteca del caso'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(
                userEmail,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () async {
              await Supabase.instance.client.auth.signOut();
            },
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            _loadFiles(),
            _loadConversationHistory(),
          ]);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SummarySection(
              summary: _summary,
              loading: _summaryLoading,
              onRefresh: _generateSummary,
            ),
            const SizedBox(height: 16),
            _HistorySection(
              entries: _conversationHistory,
              loading: _loadingHistory,
            ),
            const SizedBox(height: 16),
            _DocumentsSection(
              loadingFiles: _loadingFiles,
              uploading: _uploading,
              files: _files,
              onUpload: _uploadDocument,
              onView: _openDocument,
              onDelete: _deleteFile,
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.analytics_outlined,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Estadísticas de la biblioteca',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (stats.isEmpty)
                      const Text(
                        'Cuando cargues archivos, verás aquí el desglose por tipo.',
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: stats.entries
                            .map(
                              (entry) => Chip(
                                avatar: const Icon(Icons.insert_drive_file),
                                label: Text(
                                  '${entry.key}: ${entry.value}',
                                ),
                              ),
                            )
                            .toList(),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _InstructionsSection(),
          ],
        ),
      ),
    );
  }
}

class _SummarySection extends StatelessWidget {
  const _SummarySection({
    required this.summary,
    required this.loading,
    required this.onRefresh,
  });

  final String? summary;
  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 360;
                final header = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_stories_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Resumen con Gemini',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                );
                final action = FilledButton.icon(
                  onPressed: loading ? null : onRefresh,
                  icon: const Icon(Icons.bolt_outlined),
                  label: const Text('Generar'),
                );
                if (isNarrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header,
                      const SizedBox(height: 12),
                      action,
                    ],
                  );
                }
                return Row(
                  children: [
                    header,
                    const Spacer(),
                    action,
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            if (loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (summary == null)
              const Text(
                'Solicita un resumen para que Gemini analice los documentos cargados.',
              )
            else
              Text(summary!),
            const SizedBox(height: 12),
            const Text(
              'Nota: Se analiza directamente el contenido de archivos de texto (txt, md, csv, json). Para otros formatos, usa el boton "Abrir" y agrega contexto adicional si es necesario.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistorySection extends StatelessWidget {
  const _HistorySection({
    required this.entries,
    required this.loading,
  });

  final List<ConversationEntry> entries;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.history,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Historial de resumenes',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (entries.isEmpty)
              const Text(
                'Aqui apareceran los resumenes generados previamente para dar contexto a Gemini.',
              )
            else
              Builder(
                builder: (context) {
                  final visibleEntries = entries.length > 10
                      ? entries.sublist(entries.length - 10)
                      : entries;
                  final displayEntries = visibleEntries.reversed.toList();
                  return ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: displayEntries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = displayEntries[index];
                      return ListTile(
                        title: Text(entry.formattedTimestamp),
                        subtitle: Text(entry.previewSummary),
                        trailing: Icon(
                          Icons.auto_awesome,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      );
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _DocumentsSection extends StatelessWidget {
  const _DocumentsSection({
    required this.loadingFiles,
    required this.uploading,
    required this.files,
    required this.onUpload,
    required this.onView,
    required this.onDelete,
  });

  final bool loadingFiles;
  final bool uploading;
  final List<StoredFile> files;
  final VoidCallback onUpload;
  final void Function(StoredFile file) onView;
  final void Function(StoredFile file) onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 360;
                final header = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.folder_copy_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Documentos del caso',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                );
                final action = FilledButton.icon(
                  onPressed: uploading ? null : onUpload,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: uploading
                      ? const Text('Subiendo...')
                      : const Text('Subir archivo'),
                );
                if (isNarrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header,
                      const SizedBox(height: 12),
                      action,
                    ],
                  );
                }
                return Row(
                  children: [
                    header,
                    const Spacer(),
                    action,
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            if (loadingFiles)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (files.isEmpty)
              const Text(
                'Aún no hay documentos. Sube tus PDFs, TXT, hojas de cálculo u otros archivos relevantes.',
              )
            else
              ListView.separated(
                itemCount: files.length,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final file = files[index];
                  return ListTile(
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(file.name),
                    subtitle: Text(
                      'Tipo: ${file.extensionLabel} · '
                      '${file.createdAtLabel}',
                    ),
                    onTap: () => onView(file),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        IconButton(
                          tooltip: 'Abrir',
                          onPressed: () => onView(file),
                          icon: const Icon(Icons.open_in_new),
                        ),
                        IconButton(
                          tooltip: 'Eliminar',
                          onPressed: () => onDelete(file),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _InstructionsSection extends StatelessWidget {
  const _InstructionsSection();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Row(
              children: [
                Icon(Icons.info_outline),
                SizedBox(width: 8),
                Text(
                  'Instrucciones rapidas',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            SizedBox(height: 12),
            _InstructionItem(
              text:
                  'Carga documentos desde "Subir archivo". Cada usuario guarda sus archivos en una carpeta propia dentro del bucket.',
            ),
            _InstructionItem(
              text:
                  'Usa el boton "Abrir" para revisar un documento. Los archivos de texto se muestran en pantalla; el resto se abre con un visor externo.',
            ),
            _InstructionItem(
              text:
                  'Pulsa "Generar" para obtener un resumen. Gemini utiliza el historial para mantener el contexto de lo que ya analizaste.',
            ),
            _InstructionItem(
              text:
                  'Si cambias llaves o el modelo de Gemini, edita login/assets/env/.env y reinicia con un hot restart.',
            ),
          ],
        ),
      ),
    );
  }
}

class _InstructionItem extends StatelessWidget {
  const _InstructionItem({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: Icon(
              Icons.check_circle_outline,
              size: 16,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text),
          ),
        ],
      ),
    );
  }
}

class StoredFile {
  StoredFile({
    required this.name,
    required this.fullPath,
    this.createdAt,
  });

  final String name;
  final String fullPath;
  final DateTime? createdAt;

  String get extensionLabel {
    final ext = p.extension(name).replaceFirst('.', '').toUpperCase();
    return ext.isEmpty ? 'SIN EXTENSION' : ext;
  }

  String get createdAtLabel {
    if (createdAt == null) return 'fecha desconocida';
    final local = createdAt!.toLocal();
    final date = '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    final time = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }
}

class ConversationEntry {
  ConversationEntry({
    required this.timestamp,
    required this.files,
    required this.prompt,
    required this.summary,
  });

  final DateTime timestamp;
  final List<String> files;
  final String prompt;
  final String summary;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'timestamp': timestamp.toUtc().toIso8601String(),
        'files': files,
        'prompt': prompt,
        'summary': summary,
      };

  static ConversationEntry fromJson(Map<String, dynamic> json) {
    final rawTimestamp = json['timestamp'];
    DateTime timestamp;
    if (rawTimestamp is String) {
      timestamp = DateTime.tryParse(rawTimestamp) ?? DateTime.now();
    } else {
      timestamp = DateTime.now();
    }

    final files = (json['files'] as List<dynamic>? ?? [])
        .whereType<String>()
        .toList();
    return ConversationEntry(
      timestamp: timestamp.toLocal(),
      files: files,
      prompt: json['prompt'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
    );
  }

  String get formattedTimestamp {
    final local = timestamp.toLocal();
    final date = '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    final time = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  String get previewSummary =>
      summary.length <= 160 ? summary : '${summary.substring(0, 160)}...';
}




