import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api/games_api.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/map/map_pack_uploader.dart';
import '../../core/map/tile_downloader.dart';
import '../../core/session/game_session.dart';

/// Создание игры организатором.
///
/// Шаги:
///   1. _Step.form         — название + стороны (+ опц. оффлайн-карта).
///   2. _Step.downloading  — прогресс: скачивание тайлов → upload → PATCH.
///   3. _Step.created      — QR-коды join_code'ов сторон.
class GameCreateScreen extends ConsumerStatefulWidget {
  const GameCreateScreen({super.key});

  @override
  ConsumerState<GameCreateScreen> createState() => _GameCreateScreenState();
}

enum _Step { form, downloading, created }

class _SideDraft {
  final TextEditingController name;
  Color color;
  _SideDraft({required String initialName, required this.color})
      : name = TextEditingController(text: initialName);
  void dispose() => name.dispose();
}

class _GameCreateScreenState extends ConsumerState<GameCreateScreen> {
  static const _palette = <Color>[
    Color(0xFFE53935), Color(0xFF1E88E5), Color(0xFF43A047),
    Color(0xFFFB8C00), Color(0xFF8E24AA), Color(0xFFFDD835),
    Color(0xFF00ACC1), Color(0xFFEC407A),
  ];

  // Zoom-окно для топо-карты полигона. Меньше — крупный план, больше — обзор.
  static const _minZoom = 12;
  static const _maxZoom = 17;
  // Если оценочный размер пачки превысит — блокируем submit и просим уменьшить.
  static const _maxSizeBytes = 70 * 1024 * 1024; // 70 MB

  final _nameCtrl = TextEditingController(text: 'Игра');
  final _formKey = GlobalKey<FormState>();
  late final List<_SideDraft> _sides;

  _Step _step = _Step.form;
  bool _submitting = false;
  CreatedGame? _created;

  // Bbox-сostояние.
  bool _offlineMap = true;
  ({double lat, double lng})? _center;
  double _sizeKm = 2.0;
  String? _locationError;

  // Время респауна (сек). Шаг 15с, 30..300.
  double _respawnSeconds = 60;

  // Прогресс шага downloading.
  String _progressLabel = '';
  double? _progressValue; // null → indeterminate

  @override
  void initState() {
    super.initState();
    _sides = [
      _SideDraft(initialName: 'Красные', color: _palette[0]),
      _SideDraft(initialName: 'Синие', color: _palette[1]),
    ];
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final s in _sides) {
      s.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (_step) {
          _Step.form => 'Создание игры',
          _Step.downloading => 'Подготовка карты',
          _Step.created => 'Игра создана',
        }),
        leading: BackButton(onPressed: () => context.go('/lobby')),
      ),
      body: switch (_step) {
        _Step.form => _buildForm(),
        _Step.downloading => _buildDownloading(),
        _Step.created => _buildCreated(),
      },
    );
  }

  // ─── Form ─────────────────────────────────────────────────────────────────

  Widget _buildForm() {
    final tiles = _estimateTiles();
    final bytes = TileDownloader.estimateBytes(tiles);
    final tooBig = bytes > _maxSizeBytes;
    final canSubmit = !_submitting &&
        (!_offlineMap || (_center != null && !tooBig));

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Название игры',
              border: OutlineInputBorder(),
            ),
            maxLength: 80,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Укажите название' : null,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Стороны',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_sides.length < 8)
                TextButton.icon(
                  onPressed: _addSide,
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ..._sides.asMap().entries.map((e) => _buildSideRow(e.key, e.value)),
          const SizedBox(height: 16),
          _buildOfflineMapBlock(tiles, bytes, tooBig),
          const SizedBox(height: 16),
          _buildRespawnBlock(),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: canSubmit ? _submit : null,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: _submitting
                ? const SizedBox(
                    height: 22, width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white,
                    ),
                  )
                : const Text('Создать игру', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }

  Widget _buildSideRow(int index, _SideDraft side) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _pickColor(index),
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: side.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 2),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: side.name,
              decoration: const InputDecoration(
                labelText: 'Название стороны',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLength: 40,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Имя стороны' : null,
            ),
          ),
          if (_sides.length > 1)
            IconButton(
              tooltip: 'Удалить сторону',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _removeSide(index),
            ),
        ],
      ),
    );
  }

  Widget _buildRespawnBlock() {
    final secs = _respawnSeconds.round();
    final label = secs >= 60
        ? '${secs ~/ 60} мин${secs % 60 != 0 ? " ${secs % 60} с" : ""}'
        : '$secs с';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Время респауна',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            const Text(
              'Сколько боец ждёт после «Убит», прежде чем сможет возродиться',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _respawnSeconds,
                    min: 30,
                    max: 300,
                    divisions: 18, // шаг 15с
                    label: label,
                    onChanged: (v) => setState(() => _respawnSeconds = v),
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: Text(label, textAlign: TextAlign.right),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOfflineMapBlock(int tiles, int bytes, bool tooBig) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _offlineMap,
              onChanged: (v) => setState(() => _offlineMap = v),
              title: const Text('Оффлайн-карта полигона'),
              subtitle: const Text(
                'Скачать топо-тайлы заранее, чтобы карта работала без связи',
              ),
            ),
            if (_offlineMap) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _center == null
                        ? Text(
                            _locationError ?? 'Центр не задан',
                            style: TextStyle(
                              color: _locationError != null
                                  ? Colors.orange
                                  : Colors.white70,
                            ),
                          )
                        : Text(
                            'Центр: ${_center!.lat.toStringAsFixed(5)}, '
                            '${_center!.lng.toStringAsFixed(5)}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                  ),
                  TextButton.icon(
                    onPressed: _useCurrentLocation,
                    icon: const Icon(Icons.my_location),
                    label: const Text('Текущее'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Размер'),
                  Expanded(
                    child: Slider(
                      value: _sizeKm,
                      min: 0.5,
                      max: 5.0,
                      divisions: 9,
                      label: '${_sizeKm.toStringAsFixed(1)} км',
                      onChanged: (v) => setState(() => _sizeKm = v),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_sizeKm.toStringAsFixed(1)} км',
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Оценка: $tiles тайлов · ~${_formatBytes(bytes)}'
                '${tooBig ? "  ⚠ слишком много, уменьшите размер" : ""}',
                style: TextStyle(
                  color: tooBig ? Colors.red : Colors.white70,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _addSide() {
    final usedColors = _sides.map((s) => s.color).toSet();
    final nextColor = _palette.firstWhere(
      (c) => !usedColors.contains(c),
      orElse: () => _palette[_sides.length % _palette.length],
    );
    setState(() {
      _sides.add(_SideDraft(
        initialName: 'Сторона ${_sides.length + 1}',
        color: nextColor,
      ));
    });
  }

  void _removeSide(int index) {
    _sides.removeAt(index).dispose();
    setState(() {});
  }

  Future<void> _pickColor(int index) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Цвет стороны'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _palette
              .map((c) => GestureDetector(
                    onTap: () => Navigator.pop(ctx, c),
                    child: Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ))
              .toList(),
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() => _sides[index].color = picked);
    }
  }

  Future<void> _useCurrentLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm != LocationPermission.always &&
          perm != LocationPermission.whileInUse) {
        setState(() => _locationError = 'Нет разрешения на геолокацию');
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      setState(() {
        _center = (lat: pos.latitude, lng: pos.longitude);
        _locationError = null;
      });
    } catch (e) {
      setState(() => _locationError = 'GPS ошибка: $e');
    }
  }

  int _estimateTiles() {
    if (!_offlineMap || _center == null) return 0;
    final bbox = _bboxAroundCenter(_center!.lat, _center!.lng, _sizeKm);
    return TileDownloader.tilesForBbox(
      minLng: bbox.minLng,
      minLat: bbox.minLat,
      maxLng: bbox.maxLng,
      maxLat: bbox.maxLat,
      minZoom: _minZoom,
      maxZoom: _maxZoom,
    ).length;
  }

  // ─── Submit ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    final messenger = ScaffoldMessenger.of(context);
    final hasBbox = _offlineMap && _center != null;
    final bbox = hasBbox
        ? _bboxAroundCenter(_center!.lat, _center!.lng, _sizeKm)
        : null;

    try {
      await ref.read(authServiceProvider).ensureSignedIn();

      // 1. POST /games — игра создаётся всегда, даже если последующая
      // загрузка пачки упадёт. Организатор сможет повторить загрузку через
      // POST /games/:id/map-pack позже.
      final game = await ref.read(gamesApiProvider).create(
            name: _nameCtrl.text.trim(),
            sides: _sides
                .map((s) =>
                    SideInput(name: s.name.text.trim(), color: _hex(s.color)))
                .toList(),
            bboxMinLng: bbox?.minLng,
            bboxMinLat: bbox?.minLat,
            bboxMaxLng: bbox?.maxLng,
            bboxMaxLat: bbox?.maxLat,
            respawnSeconds: _respawnSeconds.round(),
          );

      ref.read(gameSessionProvider.notifier).setForOrganizer(game);

      if (bbox != null) {
        if (!mounted) return;
        setState(() {
          _step = _Step.downloading;
          _submitting = false; // дальше живёт _progressLabel
        });
        await _downloadAndUpload(game, bbox);
      }

      if (!mounted) return;
      setState(() {
        _created = game;
        _step = _Step.created;
      });
    } on DioException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Ошибка сети: ${e.response?.statusCode ?? e.message}'),
      ));
      if (mounted) setState(() => _step = _Step.form);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      if (mounted) setState(() => _step = _Step.form);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _downloadAndUpload(
    CreatedGame game,
    ({double minLng, double minLat, double maxLng, double maxLat}) bbox,
  ) async {
    // 1. Подготовка файла.
    final docs = await getApplicationDocumentsDirectory();
    final mapsDir = Directory(p.join(docs.path, 'maps'));
    if (!mapsDir.existsSync()) mapsDir.createSync(recursive: true);
    final filePath = p.join(mapsDir.path, '${game.id}.mbtiles');
    final file = File(filePath);
    if (file.existsSync()) file.deleteSync(); // переотрисовка с нуля

    // 2. Скачивание тайлов.
    final tiles = TileDownloader.tilesForBbox(
      minLng: bbox.minLng, minLat: bbox.minLat,
      maxLng: bbox.maxLng, maxLat: bbox.maxLat,
      minZoom: _minZoom, maxZoom: _maxZoom,
    );
    if (mounted) {
      setState(() {
        _progressLabel = 'Скачиваю тайлы 0/${tiles.length}';
        _progressValue = 0;
      });
    }

    final downloader = TileDownloader();
    final result = await downloader.downloadToMbtiles(
      tiles: tiles,
      outputPath: filePath,
      bboxMinLng: bbox.minLng, bboxMinLat: bbox.minLat,
      bboxMaxLng: bbox.maxLng, bboxMaxLat: bbox.maxLat,
      minZoom: _minZoom, maxZoom: _maxZoom,
      name: game.name,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _progressLabel = 'Скачиваю тайлы $done/$total';
          _progressValue = total == 0 ? null : done / total;
        });
      },
    );

    if (result.downloaded == 0) {
      throw Exception('Не удалось скачать ни одного тайла');
    }

    // 3. Upload в Supabase Storage.
    if (mounted) {
      setState(() {
        _progressLabel =
            'Заливаю карту (${_formatBytes(result.sizeBytes)})...';
        _progressValue = null;
      });
    }
    final publicUrl =
        await ref.read(mapPackUploaderProvider).upload(game.id, file);

    // 4. PATCH /games/:id/map-pack — фиксируем URL в БД.
    if (mounted) {
      setState(() {
        _progressLabel = 'Сохраняю ссылку...';
        _progressValue = null;
      });
    }
    await ref.read(gamesApiProvider).setMapPack(
          gameId: game.id,
          mapPackUrl: publicUrl,
          bboxMinLng: bbox.minLng,
          bboxMinLat: bbox.minLat,
          bboxMaxLng: bbox.maxLng,
          bboxMaxLat: bbox.maxLat,
        );

    // 5. Обновляем сессию — battle_map увидит mapPackUrl и переключится на MBTiles.
    //    Файл уже лежит локально по тому же пути, что и ожидает battle_map,
    //    повторного скачивания не будет.
    ref.read(gameSessionProvider.notifier).setMapPack(publicUrl);
  }

  // ─── Downloading step ─────────────────────────────────────────────────────

  Widget _buildDownloading() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_download_outlined, size: 64),
          const SizedBox(height: 24),
          Text(
            _progressLabel.isEmpty ? 'Готовлю...' : _progressLabel,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _progressValue),
          const SizedBox(height: 8),
          const Text(
            'Не закрывай приложение, пока идёт загрузка',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ─── Created step ─────────────────────────────────────────────────────────

  Widget _buildCreated() {
    final created = _created!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          created.name,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'Код игры: ${created.joinCode}',
          style: const TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 16),
        const Text(
          'Покажи QR-коды бойцам:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        ...created.sides.map(_sideQrCard),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => context.go('/battle'),
          icon: const Icon(Icons.map_outlined),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('На карту', style: TextStyle(fontSize: 18)),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => context.go('/command'),
          icon: const Icon(Icons.people_alt_outlined),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text('Распределение'),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => context.go('/lobby'),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('В лобби'),
          ),
        ),
      ],
    );
  }

  Widget _sideQrCard(CreatedSide side) {
    final color = _parseHex(side.color) ?? Colors.green;
    final code = side.joinCode ?? '—';
    final qrData = 'airsoftmap://join/$code';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 18, height: 18,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    side.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Скопировать код',
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () => _copy(code),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Colors.white,
                child: QrImageView(
                  data: qrData,
                  size: 220,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Код скопирован')),
    );
  }

  // ─── helpers ──────────────────────────────────────────────────────────────

  String _hex(Color c) =>
      '#${c.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

Color? _parseHex(String hex) {
  final s = hex.replaceAll('#', '').trim();
  if (s.length == 6) return Color(int.parse('FF$s', radix: 16));
  if (s.length == 8) return Color(int.parse(s, radix: 16));
  return null;
}

/// Квадратный bbox со стороной `sizeKm`, центрированный на (lat, lng).
({double minLng, double minLat, double maxLng, double maxLat})
    _bboxAroundCenter(double lat, double lng, double sizeKm) {
  // 1 градус широты ≈ 111 км; долгота сжимается по широте через cos.
  final dLat = (sizeKm / 2) / 111.0;
  final dLng = (sizeKm / 2) / (111.0 * math.cos(lat * math.pi / 180));
  return (
    minLng: lng - dLng,
    minLat: lat - dLat,
    maxLng: lng + dLng,
    maxLat: lat + dLat,
  );
}
