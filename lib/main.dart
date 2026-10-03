import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'; // <-- Критически важный импорт для RenderRepaintBoundary
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme_manager.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeManager(),
      child: const PaletteApp(),
    ),
  );
}

class PaletteApp extends StatelessWidget {
  const PaletteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeManager>(
      builder: (context, themeManager, child) {
        return MaterialApp(
          title: 'Palette Studio',
          debugShowCheckedModeBanner: false,
          themeMode: themeManager.themeMode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: const PaletteScreen(),
        );
      },
    );
  }
}

class _Role {
  final String name;
  final double hue;
  const _Role(this.name, this.hue);
}

// ---------- МОДЕЛЬ СКРЫТОЙ ЗАПИСИ ----------

class HiddenEntry {
  final DateTime timestamp;
  final int energy;
  final int mood;
  final int comfort;
  final String note;

  HiddenEntry({
    required this.timestamp,
    required this.energy,
    required this.mood,
    required this.comfort,
    required this.note,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'energy': energy,
        'mood': mood,
        'comfort': comfort,
        'note': note,
      };

  factory HiddenEntry.fromJson(Map<String, dynamic> json) => HiddenEntry(
        timestamp: DateTime.parse(json['timestamp']),
        energy: json['energy'],
        mood: json['mood'],
        comfort: json['comfort'],
        note: json['note'] ?? '',
      );
}

class PaletteScreen extends StatefulWidget {
  const PaletteScreen({super.key});

  @override
  State<PaletteScreen> createState() => _PaletteScreenState();
}

class _PaletteScreenState extends State<PaletteScreen> {
  double _h = 210;
  double _s = 0.65;
  double _l = 0.55;
  int _tab = 0;
  int _preset = 2;
  double _angle = 60;
  int _tuneSubTab = 0;
  final PageController _pageController = PageController();
  final GlobalKey _paletteKey = GlobalKey();

  static const _imageSaverChannel = MethodChannel('image_saver');

  // --- ЛОГИКА СКРЫТОГО ТРИГГЕРА (НАВБАР) ---
  List<int> _navTapHistory = [];
  DateTime? _lastNavTapTime;

  static const _presetNames = [
    'моно',
    'контраст',
    'триада',
    'тетрада',
    'аналогия',
    'акцент',
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool get _hasAngle => _preset >= 2;
  double get _angleMin => const <double>[0, 0, 5, -90, 6, 6][_preset];
  double get _angleMax => const <double>[0, 0, 90, 90, 90, 90][_preset];

  void _setPreset(int i) {
    setState(() {
      _preset = i;
      _angle = const <double>[0, 0, 60, 90, 30, 30][i];
    });
  }

  List<_Role> get _roles {
    final h = _h;
    final a = _angle;
    switch (_preset) {
      case 0:
        return [_Role('Основной Цвет:', _norm(h))];
      case 1:
        return [
          _Role('Основной Цвет:', _norm(h)),
          _Role('Дополнительный Цвет:', _norm(h + 180)),
        ];
      case 2:
        return [
          _Role('Основной Цвет:', _norm(h)),
          _Role('Вторичный Цвет А:', _norm(h + 180 - a)),
          _Role('Вторичный Цвет В:', _norm(h + 180 + a)),
        ];
      case 3:
        return [
          _Role('Основной Цвет:', _norm(h)),
          _Role('Вторичный Цвет А:', _norm(h + a)),
          _Role('Дополнительный Цвет:', _norm(h + 180)),
          _Role('Вторичный Цвет В:', _norm(h + 180 + a)),
        ];
      case 4:
        return [
          _Role('Основной Цвет:', _norm(h)),
          _Role('Вторичный Цвет А:', _norm(h + a)),
          _Role('Вторичный Цвет В:', _norm(h - a)),
        ];
      default:
        return [
          _Role('Основной Цвет:', _norm(h)),
          _Role('Вторичный Цвет А:', _norm(h + a)),
          _Role('Вторичный Цвет В:', _norm(h - a)),
          _Role('Акцентный Цвет:', _norm(h + 180)),
        ];
    }
  }

  List<int> _rgbOf(double h, double s, double l) {
    final c = (1 - (2 * l - 1).abs()) * s;
    final x = c * (1 - ((h / 60) % 2 - 1).abs());
    final m = l - c / 2;
    double r = 0, g = 0, b = 0;
    if (h < 60) {
      r = c;
      g = x;
    } else if (h < 120) {
      r = x;
      g = c;
    } else if (h < 180) {
      g = c;
      b = x;
    } else if (h < 240) {
      g = x;
      b = c;
    } else if (h < 300) {
      r = x;
      b = c;
    } else {
      r = c;
      b = x;
    }
    return [
      ((r + m) * 255).round(),
      ((g + m) * 255).round(),
      ((b + m) * 255).round(),
    ];
  }

  String _two(int v) =>
      (v & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();

  Color _colorOf(double h, double s, double l) {
    final rgb = _rgbOf(h, s, l);
    return Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
  }

  String _hexOf(double h, double s, double l) {
    final rgb = _rgbOf(h, s, l);
    return '#${_two(rgb[0])}${_two(rgb[1])}${_two(rgb[2])}';
  }

  double _norm(double h) => (h % 360 + 360) % 360;

  double _clamp01(double v) => v.clamp(0.0, 1.0).toDouble();

  List<List<double>> _shades(double h) {
    final jitter = _preset == 0;
    List<double> at(int i, double s, double l) =>
        [_norm(h + (jitter ? (i - 2) * 4.0 : 0)), s, l];
    return [
      at(0, _s, _l),
      at(1, _clamp01(_s * 0.8), _clamp01(_l * 0.8)),
      at(2, _s, _clamp01(_l * 0.6)),
      at(3, _clamp01(_s * 0.9), _clamp01(_l + (1 - _l) * 0.3)),
      at(4, _clamp01(_s * 0.75), _clamp01(_l + (1 - _l) * 0.55)),
    ];
  }

  void _copy(String hex) {
    Clipboard.setData(ClipboardData(text: hex));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Скопировано: $hex'),
      duration: const Duration(seconds: 1),
    ));
  }

  void _copyAs(String format) {
    String text = '';

    if (format == 'hex') {
      text = _roles.map((r) => _hexOf(r.hue, _s, _l)).join('\n');
    } else if (format == 'css') {
      final buffer = StringBuffer();
      buffer.writeln(':root {');
      for (int i = 0; i < _roles.length; i++) {
        final key = i == 0 ? 'primary' : (i == 1 ? 'secondary' : 'accent-$i');
        buffer.writeln('  --color-$key: ${_hexOf(_roles[i].hue, _s, _l)};');
      }
      buffer.writeln('}');
      text = buffer.toString();
    } else if (format == 'json') {
      final buffer = StringBuffer();
      buffer.writeln('{');
      for (int i = 0; i < _roles.length; i++) {
        final key = i == 0 ? 'primary' : (i == 1 ? 'secondary' : 'accent_$i');
        final isLast = i == _roles.length - 1;
        buffer.writeln(
            '  "$key": "${_hexOf(_roles[i].hue, _s, _l)}"${isLast ? '' : ','}');
      }
      buffer.writeln('}');
      text = buffer.toString();
    }

    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Скопировано как ${format.toUpperCase()}'),
      duration: const Duration(seconds: 1),
    ));
  }

  // --- НАТИВНЫЙ ЭКСПОРТ КАК ИЗОБРАЖЕНИЕ ЧЕРЕЗ METHOD CHANNEL ---
  Future<void> _savePaletteAsImage() async {
    try {
      // Рендерим виджет в изображение
      RenderRepaintBoundary boundary = 
          _paletteKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      // Вызываем нативный метод через MethodChannel
      final success = await _imageSaverChannel.invokeMethod<bool>('saveImage', {
        'bytes': pngBytes,
        'name': 'palette_${DateTime.now().millisecondsSinceEpoch}',
      });

      if (success == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Палитра сохранена в Галерею!')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ошибка сохранения')),
        );
      }
    } catch (e) {
      print("Ошибка сохранения: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: ${e.toString()}')),
      );
    }
  }

  void _random() {
    final rnd = Random();
    setState(() {
      _h = rnd.nextInt(360).toDouble();
      _s = 0.3 + rnd.nextDouble() * 0.7;
      _l = 0.3 + rnd.nextDouble() * 0.5;
    });
  }

  void _onNavTap(int i) {
    final now = DateTime.now();
    if (_lastNavTapTime != null &&
        now.difference(_lastNavTapTime!).inMilliseconds > 1000) {
      _navTapHistory.clear();
    }
    _lastNavTapTime = now;
    _navTapHistory.add(i);

    if (_navTapHistory.length >= 6) {
      final last6 = _navTapHistory.sublist(_navTapHistory.length - 6);
      bool isPattern = true;
      for (int k = 0; k < 5; k++) {
        if (last6[k] == last6[k + 1]) {
          isPattern = false;
          break;
        }
        if (last6[k] != 0 && last6[k] != 2) {
          isPattern = false;
          break;
        }
      }
      if (isPattern && last6.contains(0) && last6.contains(2)) {
        _navTapHistory.clear();
        HapticFeedback.mediumImpact();
        _openHiddenVault();
        return;
      }
    }

    setState(() => _tab = i);
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SettingsSheet(
        onSecretAccess: _openHiddenVault,
      ),
    );
  }

  void _openMockPreview() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => MockPreviewSheet(
        roles: _roles,
        colorOf: _colorOf,
        s: _s,
        l: _l,
      ),
    );
  }

  void _openHiddenVault() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HiddenVaultScreen()),
    );
  }

  Widget _baseColorCard() {
    final rgb = _rgbOf(_h, _s, _l);
    final color = Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
    final hex = '#${_two(rgb[0])}${_two(rgb[1])}${_two(rgb[2])}';
    return Row(
      children: [
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            height: 64,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hex, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(
              'R ${rgb[0]}  G ${rgb[1]}  B ${rgb[2]}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ],
    );
  }

  Widget _palettePreview() {
    return Row(
      children: [
        for (int i = 0; i < _roles.length; i++)
          Expanded(
            child: Padding(
              padding:
                  EdgeInsets.only(right: i < _roles.length - 1 ? 6.0 : 0.0),
              child: InkResponse(
                onTap: () => _copy(_hexOf(_roles[i].hue, _s, _l)),
                borderRadius: BorderRadius.circular(8),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _colorOf(_roles[i].hue, _s, _l),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _presetButton(int i) {
    final selected = _preset == i;
    final tooltipMsg = const <String>[
      'Monochromatic (Single Hue)',
      'Complementary (180°)',
      'Triadic Harmony (120°)',
      'Tetradic / Rectangle (90°)',
      'Analogous (±30°)',
      'Split-Complementary (Accent)',
    ][i];

    return Tooltip(
      message: tooltipMsg,
      waitDuration: const Duration(milliseconds: 500),
      child: InkResponse(
        onTap: () => _setPreset(i),
        borderRadius: BorderRadius.circular(30),
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: _PresetIcon(index: i, size: 40),
            ),
            const SizedBox(height: 2),
            Text(
              _presetNames[i],
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _angleSlider() {
    if (!_hasAngle) return const SizedBox.shrink();
    return Column(
      children: [
        Text('Угол гармонии: ${_angle.round()}°'),
        Slider(
          value: _angle,
          min: _angleMin,
          max: _angleMax,
          divisions: (_angleMax - _angleMin).round(),
          label: '${_angle.round()}°',
          onChanged: (v) => setState(() => _angle = v),
        ),
      ],
    );
  }

  Widget _buildWheelTab() {
    final rgb = _rgbOf(_h, _s, _l);
    final color = Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
    final hex = '#${_two(rgb[0])}${_two(rgb[1])}${_two(rgb[2])}';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SafeArea(
          child: ColorWheel(
            h: _h,
            s: _s,
            roleHues: _roles.map((r) => r.hue).toList(),
            onPicked: (h, s) => setState(() {
              _h = h;
              _s = s;
            }),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (int i = 0; i < _presetNames.length; i++) _presetButton(i),
          ],
        ),
        _angleSlider(),
        const SizedBox(height: 8),
        _palettePreview(),
        const SizedBox(height: 12),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          height: 70,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          hex,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        Text(
          'R: ${(rgb[0] / 255 * 100).round()} %  '
          'G: ${(rgb[1] / 255 * 100).round()} %  '
          'B: ${(rgb[2] / 255 * 100).round()} %',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600]),
        ),
        
        // --- СИСТЕМНЫЕ ОТТЕНКИ НА ГЛАВНОМ ЭКРАНЕ ---
        const SizedBox(height: 16),
        const Text(
          'System Shades',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        Row(
          children: _shades(_h).map((shade) => Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: InkResponse(
                onTap: () => _copy(_hexOf(shade[0], shade[1], shade[2])),
                borderRadius: BorderRadius.circular(6),
                child: Column(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      height: 32,
                      decoration: BoxDecoration(
                        color: _colorOf(shade[0], shade[1], shade[2]),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _hexOf(shade[0], shade[1], shade[2]),
                      style: const TextStyle(fontSize: 9),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          )).toList(),
        ),
      ],
    );
  }

  Widget _buildTuneTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _baseColorCard(),
        const SizedBox(height: 16),
        if (_roles.length > 1) ...[
          Text(
            'Цвета гармонии:',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.grey[700],
            ),
          ),
          const SizedBox(height: 8),
          for (int i = 1; i < _roles.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _colorOf(_roles[i].hue, _s, _l),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _roles[i].name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          _hexOf(_roles[i].hue, _s, _l),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () => _copy(_hexOf(_roles[i].hue, _s, _l)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
        ],
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 0,
              label: Text('2D Палитры'),
              icon: Icon(Icons.grid_on),
            ),
            ButtonSegment(
              value: 1,
              label: Text('Ползунки'),
              icon: Icon(Icons.tune),
            ),
          ],
          selected: {_tuneSubTab},
          onSelectionChanged: (Set<int> newSelection) {
            setState(() => _tuneSubTab = newSelection.first);
          },
        ),
        const SizedBox(height: 24),
        if (_tuneSubTab == 0) ...[
          ColorSquarePicker(
            hue: _h,
            saturation: _s,
            lightness: _l,
            title: 'Насыщенность/Яркость',
            onColorChanged: (s, v) {
              final l = v * (1 - s / 2);
              final sHsl = l == 0 || l == 1
                  ? 0.0
                  : (v * s) / (1 - (2 * l - 1).abs());
              setState(() {
                _s = sHsl.clamp(0.0, 1.0);
                _l = l.clamp(0.0, 1.0);
              });
            },
          ),
        ] else ...[
          _slider('Тон (H)', _h, 360, (v) => _h = v),
          _slider('Насыщенность (S)', _s * 100, 100, (v) => _s = v / 100),
          _slider('Светлота (L)', _l * 100, 100, (v) => _l = v / 100),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _random,
            icon: const Icon(Icons.refresh),
            label: const Text('Случайный цвет'),
          ),
        ],
      ],
    );
  }

  Widget _shadeCell(List<double> hsl) {
    final color = _colorOf(hsl[0], hsl[1], hsl[2]);
    final hex = _hexOf(hsl[0], hsl[1], hsl[2]);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: InkResponse(
          onTap: () => _copy(hex),
          borderRadius: BorderRadius.circular(6),
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 4),
              Text(hex, style: const TextStyle(fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }

  // --- НОВЫЙ МЕТОД ДЛЯ ЭКРАНА СПИСОК С ИНТЕГРАЦИЕЙ ОТТЕНКОВ ---
  Widget _buildListTab() {
    // Получаем оттенки для каждого цвета палитры
    final List<List<Color>> roleShades = _roles.map((role) {
      return _shades(role.hue).map((shade) => _colorOf(shade[0], shade[1], shade[2])).toList();
    }).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Tooltip(
          message: 'Harmony Engine: HSL/HSV Color Space',
          waitDuration: const Duration(milliseconds: 500),
          child: Text(
            'Гармония: ${_presetNames[_preset]}'
            '${_hasAngle ? ' · угол ${_angle.round()}°' : ''}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 12),
        
        // --- УМНЫЙ МОК-АП С ИСПОЛЬЗОВАНИЕМ ОТТЕНКОВ ---
        RepaintBoundary(
          key: _paletteKey,
          child: Container(
            height: 240,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Row(
              children: roleShades.asMap().entries.map((entry) {
                final idx = entry.key;
                final shades = entry.value;
                return Expanded(
                  child: Column(
                    children: shades.asMap().entries.map((shadeEntry) {
                      final shadeIdx = shadeEntry.key;
                      final color = shadeEntry.value;
                      return Expanded(
                        child: Container(
                          color: color,
                          child: Center(
                            child: Text(
                              _hexOf(_roles[idx].hue, _s, _l),
                              style: TextStyle(
                                color: shadeIdx > 2 ? Colors.black54 : Colors.white70,
                                fontSize: 10,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        
        const SizedBox(height: 16),
        
        // Кнопки действий
        OutlinedButton.icon(
          onPressed: _openMockPreview,
          icon: const Icon(Icons.preview, size: 18),
          label: const Text('Предпросмотр в UI'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _savePaletteAsImage,
          icon: const Icon(Icons.save_alt, size: 18),
          label: const Text('Сохранить PNG'),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: Colors.green.shade700),
            foregroundColor: Colors.green.shade700,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _copyAs('hex'),
                child: const Text('HEX'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _copyAs('css'),
                child: const Text('CSS'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _copyAs('json'),
                child: const Text('JSON'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        
        // --- ПОЛНЫЙ СПИСОК ОТТЕНКОВ ДЛЯ КАЖДОГО ЦВЕТА ---
        for (int i = 0; i < _roles.length; i++) ...[
          Tooltip(
            message: 'Luminance steps (HSL)',
            waitDuration: const Duration(milliseconds: 500),
            child: Text(
              _roles[i].name,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: roleShades[i].asMap().entries.map((entry) {
              final idx = entry.key;
              final color = entry.value;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: InkResponse(
                    onTap: () => _copy(_hexOf(_roles[i].hue, _s, _l)),
                    borderRadius: BorderRadius.circular(6),
                    child: Column(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          height: 44,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _hexOf(_roles[i].hue, _s, _l),
                          style: const TextStyle(fontSize: 9),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _slider(String label, double value, double max,
      ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.round()}'),
        Slider(
          value: value,
          min: 0,
          max: max,
          onChanged: (v) => setState(() => onChanged(v)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Palette Studio'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (i) => setState(() => _tab = i),
        children: [
          _buildWheelTab(),
          _buildTuneTab(),
          _buildListTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _onNavTap,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.color_lens), label: 'Круг'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Настройка'),
          NavigationDestination(icon: Icon(Icons.view_list), label: 'Список'),
        ],
      ),
    );
  }
}

// ---------- СКРЫТЫЙ МОДУЛЬ (ДНЕВНИК СОСТОЯНИЯ) ----------

class HiddenVaultScreen extends StatefulWidget {
  const HiddenVaultScreen({super.key});

  @override
  State<HiddenVaultScreen> createState() => _HiddenVaultScreenState();
}

class _HiddenVaultScreenState extends State<HiddenVaultScreen> {
  List<HiddenEntry> _entries = [];
  final TextEditingController _noteController = TextEditingController();
  int _energy = 5;
  int _mood = 5;
  int _comfort = 5;

  // --- ЛОГИКА ЭКСТРЕННОГО ВЫХОДА (ПЕРЕВОРОТ) ---
  StreamSubscription<AccelerometerEvent>? _accelSubscription;
  Timer? _faceDownTimer;
  bool _wasFaceDown = false;

  @override
  void initState() {
    super.initState();
    _loadEntries();
    _initPanicGesture();
  }

  void _initPanicGesture() {
    _accelSubscription = accelerometerEvents.listen((event) {
      if (event.z > 9.5 && !_wasFaceDown) {
        _wasFaceDown = true;
        _faceDownTimer?.cancel();
        _faceDownTimer = Timer(const Duration(milliseconds: 300), () {
          if (_wasFaceDown && mounted) {
            HapticFeedback.mediumImpact();
            Navigator.of(context).pop(); 
          }
        });
      } else if (event.z < 8.0) {
        _wasFaceDown = false;
        _faceDownTimer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _faceDownTimer?.cancel();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString('hidden_vault_data');
    if (data != null) {
      final List<dynamic> decoded = jsonDecode(data);
      setState(() {
        _entries = decoded.map((e) => HiddenEntry.fromJson(e)).toList();
        _entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      });
    }
  }

  Future<void> _saveEntry() async {
    final newEntry = HiddenEntry(
      timestamp: DateTime.now(),
      energy: _energy,
      mood: _mood,
      comfort: _comfort,
      note: _noteController.text,
    );

    _entries.insert(0, newEntry);
    _noteController.clear();
    _energy = 5;
    _mood = 5;
    _comfort = 5;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'hidden_vault_data',
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );

    setState(() {});
    HapticFeedback.mediumImpact();
  }

  Future<void> _deleteEntry(int index) async {
    _entries.removeAt(index);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'hidden_vault_data',
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Render Engine Diagnostics',
          style: TextStyle(fontFamily: 'monospace', fontSize: 16),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.grey),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade800),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'System Metrics Override',
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildMetricSlider('CPU Load (Energy)', _energy,
                      (v) => setState(() => _energy = v.round())),
                  _buildMetricSlider('Color Accuracy (Mood)', _mood,
                      (v) => setState(() => _mood = v.round())),
                  _buildMetricSlider('Thermal Status (Comfort)', _comfort,
                      (v) => setState(() => _comfort = v.round())),
                  const SizedBox(height: 12),
                  CupertinoTextField(
                    controller: _noteController,
                    maxLines: 3,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 14),
                    placeholder: 'Debug Logs',
                    placeholderStyle: const TextStyle(color: Colors.grey),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    padding: const EdgeInsets.all(12),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saveEntry,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.greenAccent.shade700,
                        foregroundColor: Colors.black,
                        textStyle: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      child: const Text('COMMIT DIAGNOSTIC LOG'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Historical Logs',
              style: TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            if (_entries.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Text(
                    'No diagnostic logs found.',
                    style: TextStyle(
                        color: Colors.grey.shade600, fontFamily: 'monospace'),
                  ),
                ),
              )
            else
              ..._entries.asMap().entries.map((entry) {
                final idx = entry.key;
                final e = entry.value;
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade800),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${e.timestamp.day}.${e.timestamp.month}.${e.timestamp.year} ${e.timestamp.hour}:${e.timestamp.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                                color: Colors.blueAccent,
                                fontFamily: 'monospace',
                                fontSize: 12),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                size: 18, color: Colors.redAccent),
                            onPressed: () => _deleteEntry(idx),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                          'CPU: ${e.energy}/10 | ACC: ${e.mood}/10 | TEMP: ${e.comfort}/10',
                          style: const TextStyle(
                              color: Colors.greenAccent,
                              fontFamily: 'monospace',
                              fontSize: 12)),
                      if (e.note.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(e.note,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                      ],
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricSlider(
      String label, int value, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    color: Colors.grey.shade400,
                    fontFamily: 'monospace',
                    fontSize: 12)),
            Text('$value',
                style: const TextStyle(
                    color: Colors.white, fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            activeTrackColor: Colors.greenAccent,
            inactiveTrackColor: Colors.grey.shade800,
            thumbColor: Colors.greenAccent,
          ),
          child: Slider(
            value: value.toDouble(),
            min: 1,
            max: 10,
            divisions: 9,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

// ---------- МОК-АП ПРЕДПРОСМОТРА ----------

class MockPreviewSheet extends StatefulWidget {
  final List<_Role> roles;
  final Color Function(double h, double s, double l) colorOf;
  final double s;
  final double l;

  const MockPreviewSheet({
    super.key,
    required this.roles,
    required this.colorOf,
    required this.s,
    required this.l,
  });

  @override
  State<MockPreviewSheet> createState() => _MockPreviewSheetState();
}

class _MockPreviewSheetState extends State<MockPreviewSheet> {
  int _previewMode = 0;

  @override
  Widget build(BuildContext context) {
    final isDarkMock = _previewMode == 1;
    final bg = isDarkMock ? const Color(0xFF1A1A1A) : const Color(0xFFF5F5F5);
    final textOnBg = isDarkMock ? Colors.white : Colors.black87;
    final subtextOnBg = isDarkMock ? Colors.white70 : Colors.black54;

    final primary = widget.colorOf(widget.roles[0].hue, widget.s, widget.l);
    final secondary = widget.roles.length > 1
        ? widget.colorOf(widget.roles[1].hue, widget.s, widget.l)
        : primary;
    final accent = widget.roles.length > 2
        ? widget.colorOf(widget.roles[2].hue, widget.s, widget.l)
        : secondary;

    return SizedBox(
      height: 520,
      child: Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Предпросмотр в UI',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Светлый')),
                ButtonSegment(value: 1, label: Text('Тёмный')),
              ],
              selected: {_previewMode},
              onSelectionChanged: (Set<int> newSelection) {
                setState(() => _previewMode = newSelection.first);
              },
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade400),
                ),
                child: Column(
                  children: [
                    Container(
                      height: 48,
                      width: double.infinity,
                      color: primary,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Palette Studio',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: secondary,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Заголовок карточки',
                                    style: TextStyle(
                                      color: textOnBg,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Пример текста на вторичном цвете палитры.',
                                    style: TextStyle(
                                      color: subtextOnBg,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              height: 40,
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                'Акцентная кнопка',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Обычный текст на фоне приложения.',
                              style: TextStyle(
                                color: textOnBg,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- ЭКРАН НАСТРОЕК ----------

class SettingsSheet extends StatefulWidget {
  final VoidCallback onSecretAccess;

  const SettingsSheet({super.key, required this.onSecretAccess});

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  bool _cloudSync = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeManager>(
      builder: (context, themeManager, child) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Настройки',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              _fadeSlideIn(
                delay: 100,
                child: const Text(
                  'Тема оформления',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 12),
              _fadeSlideIn(
                delay: 200,
                child: RadioListTile<ThemeMode>(
                  title: const Text('Системная'),
                  subtitle: const Text('Использовать тему устройства'),
                  value: ThemeMode.system,
                  groupValue: themeManager.themeMode,
                  onChanged: (value) {
                    if (value != null) themeManager.setThemeMode(value);
                  },
                ),
              ),
              _fadeSlideIn(
                delay: 300,
                child: RadioListTile<ThemeMode>(
                  title: const Text('Светлая'),
                  value: ThemeMode.light,
                  groupValue: themeManager.themeMode,
                  onChanged: (value) {
                    if (value != null) themeManager.setThemeMode(value);
                  },
                ),
              ),
              _fadeSlideIn(
                delay: 400,
                child: RadioListTile<ThemeMode>(
                  title: const Text('Тёмная'),
                  value: ThemeMode.dark,
                  groupValue: themeManager.themeMode,
                  onChanged: (value) {
                    if (value != null) themeManager.setThemeMode(value);
                  },
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 16),
              const Text(
                'Рабочее пространство',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Синхронизация с облаком'),
                subtitle:
                    const Text('Автосохранение палитр в защищенный контур'),
                value: _cloudSync,
                activeColor: Theme.of(context).colorScheme.primary,
                onChanged: (value) {
                  setState(() => _cloudSync = value);
                  if (value) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            'Инициализация защищенного канала... (Демо-режим)'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('О программе',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  GestureDetector(
                    onLongPress: () {
                      HapticFeedback.mediumImpact();
                      Navigator.of(context).pop();
                      Future.delayed(const Duration(milliseconds: 300), () {
                        widget.onSecretAccess();
                      });
                    },
                    child: Text(
                      'v1.0.4 (build 2026.09.05)',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Движок: HSL/HSV Color Space Engine v2.1',
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.cloud_done,
                      size: 16, color: Colors.green.shade700),
                  const SizedBox(width: 8),
                  Text(
                    'Последняя синхронизация: 05.09.2026, 14:32',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _fadeSlideIn({required int delay, required Widget child}) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

// ---------- 2D-ПАД ДЛЯ ВЫБОРА ЦВЕТА ----------

class ColorSquarePicker extends StatefulWidget {
  final double hue;
  final double saturation;
  final double lightness;
  final Function(double x, double y) onColorChanged;
  final String title;

  const ColorSquarePicker({
    super.key,
    required this.hue,
    required this.saturation,
    required this.lightness,
    required this.onColorChanged,
    required this.title,
  });

  @override
  State<ColorSquarePicker> createState() => _ColorSquarePickerState();
}

class _ColorSquarePickerState extends State<ColorSquarePicker> {
  final GlobalKey _boxKey = GlobalKey();
  Offset _localPosition = Offset.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateMarkerPosition();
    });
  }

  void _updateMarkerPosition() {
    if (_boxKey.currentContext == null) return;
    final RenderBox box =
        _boxKey.currentContext!.findRenderObject() as RenderBox;
    final size = box.size;
    setState(() {
      final v = widget.lightness +
          widget.saturation * (1 - (2 * widget.lightness - 1).abs()) / 2;
      final sHsv = v == 0 ? 0.0 : widget.saturation * widget.lightness / v;
      _localPosition = Offset(
        sHsv * size.width,
        (1.0 - v) * size.height,
      );
    });
  }

  void _onPanDown(DragDownDetails details) {
    final RenderBox box =
        _boxKey.currentContext!.findRenderObject() as RenderBox;
    final Offset localPosition = box.globalToLocal(details.globalPosition);
    setState(() {
      _localPosition = localPosition;
    });
    _updateColor(localPosition);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final RenderBox box =
        _boxKey.currentContext!.findRenderObject() as RenderBox;
    final Offset localPosition = box.globalToLocal(details.globalPosition);
    setState(() {
      _localPosition = localPosition;
    });
    _updateColor(localPosition);
  }

  void _updateColor(Offset position) {
    final RenderBox box =
        _boxKey.currentContext!.findRenderObject() as RenderBox;
    final size = box.size;

    final x = (position.dx / size.width).clamp(0.0, 1.0);
    final y = (position.dy / size.height).clamp(0.0, 1.0);

    widget.onColorChanged(x, 1.0 - y);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: 'HSV Color Space: Saturation (X) vs Value (Y)',
          waitDuration: const Duration(milliseconds: 500),
          child: Text(
            widget.title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onHorizontalDragDown: _onPanDown,
          onHorizontalDragUpdate: _onPanUpdate,
          onVerticalDragDown: _onPanDown,
          onVerticalDragUpdate: _onPanUpdate,
          child: Container(
            key: _boxKey,
            width: double.infinity,
            height: 200,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade400, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: CustomPaint(
                painter: _ColorGridPainter(hue: widget.hue),
                child: Stack(
                  children: [
                    Positioned(
                      left:
                          (_localPosition.dx - 8).clamp(0.0, double.infinity),
                      top:
                          (_localPosition.dy - 8).clamp(0.0, double.infinity),
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ColorGridPainter extends CustomPainter {
  final double hue;

  _ColorGridPainter({required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    const steps = 50;
    final cellWidth = size.width / steps;
    final cellHeight = size.height / steps;

    for (int x = 0; x < steps; x++) {
      for (int y = 0; y < steps; y++) {
        final saturation = x / steps;
        final value = 1.0 - (y / steps);
        final color = HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();

        final rect = Rect.fromLTWH(
          x * cellWidth,
          y * cellHeight,
          cellWidth + 0.5,
          cellHeight + 0.5,
        );
        canvas.drawRect(rect, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ColorGridPainter oldDelegate) {
    return oldDelegate.hue != hue;
  }
}

// ---------- ЦВЕТОВОЙ КРУГ ----------

class ColorWheel extends StatelessWidget {
  final double h;
  final double s;
  final List<double> roleHues;
  final void Function(double h, double s) onPicked;

  const ColorWheel({
    super.key,
    required this.h,
    required this.s,
    required this.roleHues,
    required this.onPicked,
  });

  void _handle(Offset pos, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final dx = pos.dx - center.dx;
    final dy = pos.dy - center.dy;
    final radius = size.width / 2;
    final sat = (sqrt(dx * dx + dy * dy) / radius).clamp(0.0, 1.0);
    double hue = atan2(dy, dx) * 180 / pi;
    if (hue < 0) hue += 360;
    onPicked(hue, sat.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final circleSize = (screenWidth * 0.8).clamp(200.0, 320.0);
    final size = Size(circleSize, circleSize);

    return Center(
      child: GestureDetector(
        onHorizontalDragDown: (d) => _handle(d.localPosition, size),
        onHorizontalDragUpdate: (d) => _handle(d.localPosition, size),
        onVerticalDragDown: (d) => _handle(d.localPosition, size),
        onVerticalDragUpdate: (d) => _handle(d.localPosition, size),
        child: CustomPaint(
          size: size,
          painter: _WheelPainter(h: h, s: s, roleHues: roleHues),
        ),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  final double h;
  final double s;
  final List<double> roleHues;

  _WheelPainter({required this.h, required this.s, required this.roleHues});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final huePaint = Paint()
      ..shader = ui.Gradient.sweep(
        center,
        const [
          Color(0xFFFF0000),
          Color(0xFFFFFF00),
          Color(0xFF00FF00),
          Color(0xFF00FFFF),
          Color(0xFF0000FF),
          Color(0xFFFF00FF),
          Color(0xFFFF0000),
        ],
        const [0, 1 / 6, 2 / 6, 3 / 6, 4 / 6, 5 / 6, 1],
      );
    canvas.drawCircle(center, radius, huePaint);

    final satPaint = Paint()
      ..shader = ui.Gradient.radial(
        center,
        radius,
        const [Color(0xFF808080), Color(0x00808080)],
      );
    canvas.drawCircle(center, radius, satPaint);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0x33000000),
    );

    for (final hue in roleHues.skip(1)) {
      final ang = hue * pi / 180;
      final p = Offset(
        center.dx + cos(ang) * radius * 0.85,
        center.dy + sin(ang) * radius * 0.85,
      );
      canvas.drawCircle(p, 7, Paint()..color = const Color(0xFFFFFFFF));
      canvas.drawCircle(
        p,
        7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF333333),
      );
    }

    final angle = h * pi / 180;
    final thumb = Offset(
      center.dx + cos(angle) * s * radius,
      center.dy + sin(angle) * s * radius,
    );
    canvas.drawCircle(thumb, 10, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawCircle(
      thumb,
      10,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF333333),
    );
  }

  @override
  bool shouldRepaint(covariant _WheelPainter oldDelegate) =>
      oldDelegate.h != h ||
      oldDelegate.s != s ||
      oldDelegate.roleHues.join(',') != roleHues.join(',');
}

// ---------- МИНИ-ИКОНКИ ПРЕСЕТОВ ----------

class _PresetIcon extends StatelessWidget {
  final int index;
  final double size;

  const _PresetIcon({required this.index, this.size = 40});

  static const _darkOffsets = [
    <double>[],
    [180.0],
    [120.0, 240.0],
    [90.0, 180.0, 270.0],
    [30.0, -30.0],
    [30.0, -30.0, 180.0],
  ];

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _IconPainter(darkOffsets: _darkOffsets[index]),
    );
  }
}

class _IconPainter extends CustomPainter {
  final List<double> darkOffsets;

  _IconPainter({required this.darkOffsets});

  void _wedge(
      Canvas canvas, Offset center, double radius, double deg, Color color) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    final start = (deg - 90 - 12) * pi / 180;
    final sweep = 24 * pi / 180;
    final path = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(rect, start, sweep, false)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFF9E9E9E),
    );
    _wedge(canvas, center, radius, 0, const Color(0xFFD32F2F));
    for (final o in darkOffsets) {
      _wedge(canvas, center, radius, o, const Color(0xFF424242));
    }
  }

  @override
  bool shouldRepaint(covariant _IconPainter oldDelegate) => false;
}