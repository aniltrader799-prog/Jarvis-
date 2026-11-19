import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart';

void main() => runApp(const JarvisApp());

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Jarvis',
    theme: ThemeData.dark(useMaterial3: true),
    home: const HomeScreen(),
  );
}

// ============ NATIVE BRIDGE ============
class NativeBridge {
  static const _ch = MethodChannel('jarvis/native');
  static Future<String> getUiTree() async =>
      await _ch.invokeMethod<String>('getUiTree') ?? '[]';
  static Future<Shot> captureScreenshot() async {
    final m = await _ch.invokeMapMethod<String, dynamic>('captureScreenshot');
    if (m == null) throw Exception('Screenshot failed');
    return Shot(
      base64: m['base64'] as String,
      iw: m['imageWidth'] as int, ih: m['imageHeight'] as int,
      sw: m['screenWidth'] as int, sh: m['screenHeight'] as int,
    );
  }
  static Future<bool> tap(double x, double y) async =>
      await _ch.invokeMethod<bool>('tap', {'x': x, 'y': y}) ?? false;
  static Future<bool> swipe(double a, double b, double c, double d) async =>
      await _ch.invokeMethod<bool>('swipe',
        {'x1': a, 'y1': b, 'x2': c, 'y2': d, 'durationMs': 300}) ?? false;
  static Future<bool> back() async =>
      await _ch.invokeMethod<bool>('back') ?? false;
  static Future<bool> home() async =>
      await _ch.invokeMethod<bool>('home') ?? false;
  static Future<bool> type(String t, {int idx = -1}) async =>
      await _ch.invokeMethod<bool>('type', {'text': t, 'nodeIndex': idx}) ?? false;
  static Future<bool> isKilled() async =>
      await _ch.invokeMethod<bool>('isKillSwitchActive') ?? true;
  static Future<void> resetKill() async =>
      _ch.invokeMethod('resetKillSwitch');
  static Future<void> startFGS() async =>
      _ch.invokeMethod('startForegroundService');
  static Future<void> stopFGS() async =>
      _ch.invokeMethod('stopForegroundService');
}

class Shot {
  final String base64;
  final int iw, ih, sw, sh;
  Shot({required this.base64, required this.iw, required this.ih,
       required this.sw, required this.sh});
  double get sx => sw / iw;
  double get sy => sh / ih;
}

// ============ GEMINI ============
class JarvisAction {
  final String summary, action, reason, risk, spoken;
  final int? tIndex;
  final double? x, y, ex, ey;
  final String? text, confirmQ;
  JarvisAction({
    required this.summary, required this.action, required this.reason,
    required this.risk, required this.spoken,
    this.tIndex, this.x, this.y, this.ex, this.ey, this.text, this.confirmQ,
  });
  factory JarvisAction.from(Map<String, dynamic> j) {
    final t = j['target'] as Map?;
    final e = j['end'] as Map?;
    return JarvisAction(
      summary: j['screen_summary'] ?? '',
      action: j['action'] ?? 'done',
      reason: j['action_reason'] ?? '',
      risk: j['risk'] ?? 'none',
      spoken: j['spoken_response'] ?? '',
      tIndex: j['target_index'] as int?,
      x: (t?['x'] as num?)?.toDouble(),
      y: (t?['y'] as num?)?.toDouble(),
      ex: (e?['x'] as num?)?.toDouble(),
      ey: (e?['y'] as num?)?.toDouble(),
      text: j['text'] as String?,
      confirmQ: j['confirm_question'] as String?,
    );
  }
  bool get needsConfirm => action == 'ask_confirmation' || risk == 'high';
}

class Gemini {
  final String apiKey, model, lang;
  Gemini({required this.apiKey, this.model = 'gemini-2.5-flash',
          this.lang = 'hi-IN'});
  Future<JarvisAction> decide({
    required String goal, required Shot? shot,
    required String tree, required List<String> history,
  }) async {
    final langName = {'en-US':'English','hi-IN':'Hindi','or-IN':'Odia'}[lang] ?? 'Hindi';
    final prompt = '''You are Jarvis, an Android UI automation agent.
USER GOAL: "$goal"
RESPOND IN: $langName (screen_summary + spoken_response)

UI TREE: $tree
HISTORY: ${history.isEmpty ? "(none)" : history.join(" | ")}

RULES:
1. Prefer "target_index" over coordinates.
2. Coordinates in IMAGE space (screenshot you see).
3. risk="high" for money/password/delete/send/settings.
4. action="ask_confirmation" if unsure or destructive.
5. action="done" only when goal FULLY achieved.
6. Never repeat same failing action twice.
7. spoken_response REQUIRED on done/ask_confirmation.

Return ONLY valid JSON.''';
    final parts = <Map<String, dynamic>>[{'text': prompt}];
    if (shot != null) parts.add({
      'inline_data': {'mime_type': 'image/jpeg', 'data': shot.base64}
    });
    final body = {
      'contents': [{'role':'user','parts':parts}],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'responseSchema': _schema,
        'temperature': 0.1,
      }
    };
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey');
    final resp = await http.post(url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception('Gemini ${resp.statusCode}: ${resp.body}');
    }
    final text = jsonDecode(resp.body)['candidates'][0]['content']['parts'][0]['text'];
    return JarvisAction.from(jsonDecode(text));
  }

  static const _schema = {
    'type': 'object',
    'properties': {
      'screen_summary': {'type': 'STRING'},
      'action': {'type': 'STRING', 'enum':
        ['tap','type','swipe','back','home','ask_confirmation','done']},
      'action_reason': {'type': 'STRING'},
      'target_index': {'type': 'INTEGER'},
      'target': {'type': 'OBJECT', 'properties':
        {'x': {'type': 'NUMBER'}, 'y': {'type': 'NUMBER'}}},
      'end': {'type': 'OBJECT', 'properties':
        {'x': {'type': 'NUMBER'}, 'y': {'type': 'NUMBER'}}},
      'text': {'type': 'STRING'},
      'risk': {'type': 'STRING', 'enum': ['none','low','high']},
      'confirm_question': {'type': 'STRING'},
      'spoken_response': {'type': 'STRING'},
    },
    'required': ['screen_summary','action','action_reason','risk','spoken_response'],
  };
}

// ============ AGENT LOOP ============
enum TType { observe, action, warn, result }
class TEntry {
  final TType type;
  final String title, detail;
  TEntry(this.type, this.title, this.detail);
}

class AgentLoop {
  final Gemini gemini;
  final void Function(TEntry) onT;
  final Future<void> Function(String) onSpeak;
  final Future<bool> Function(String) onConfirm;
  AgentLoop({required this.gemini, required this.onT,
             required this.onSpeak, required this.onConfirm});

  Future<void> run(String goal, {int maxSteps = 15}) async {
    await NativeBridge.resetKill();
    await NativeBridge.startFGS();
    final history = <String>[];
    String? lastSig;
    int sameCount = 0;

    try {
      for (int step = 1; step <= maxSteps; step++) {
        if (await NativeBridge.isKilled()) {
          onT(TEntry(TType.warn, 'Stopped', 'Kill switch'));
          await onSpeak('Rok diya gaya.');
          return;
        }

        Shot? shot;
        try { shot = await NativeBridge.captureScreenshot(); } catch (_) {}
        final tree = await NativeBridge.getUiTree();

        final sig = '${shot?.base64.hashCode ?? 0}_${tree.hashCode}';
        if (sig == lastSig) {
          sameCount++;
          if (sameCount >= 2) {
            onT(TEntry(TType.warn, 'No change', 'Screen same, ruk raha hoon'));
            await onSpeak('Screen nahi badal rahi.');
            return;
          }
        } else { sameCount = 0; }
        lastSig = sig;

        JarvisAction action;
        try {
          action = await gemini.decide(
            goal: goal,
            screenshot: (step == 1 || sameCount == 0) ? shot : null,
            tree: tree, history: history,
          );
        } catch (e) {
          onT(TEntry(TType.warn, 'Gemini error', e.toString()));
          await onSpeak('Model se jawab nahi mila.');
          return;
        }

        onT(TEntry(TType.observe, 'Step $step', action.summary));
        if (await NativeBridge.isKilled()) {
          await onSpeak('Rok diya gaya.');
          return;
        }

        if (action.needsConfirm) {
          onT(TEntry(TType.warn, '⚠️ Confirm', action.confirmQ ?? '?'));
          final ok = await onConfirm(action.confirmQ ?? 'Aage badhein?');
          if (!ok) { await onSpeak('Cancel kiya.'); return; }
        }

        final done = await _exec(action, shot);
        history.add('$step:${action.action} — ${action.reason}');
        onT(TEntry(TType.action, 'Step $step: ${action.action}', action.reason));

        if (done) {
          onT(TEntry(TType.result, '✅ Done', action.spoken));
          await onSpeak(action.spoken);
          return;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      onT(TEntry(TType.warn, 'Max steps', 'Kaam poora nahi hua'));
      await onSpeak('Maximum steps ho gaye.');
    } finally {
      await NativeBridge.stopFGS();
    }
  }

  Future<bool> _exec(JarvisAction a, Shot? s) async {
    double? sx, sy, ex, ey;
    if (a.x != null && a.y != null) {
      sx = a.x! * (s?.sx ?? 1); sy = a.y! * (s?.sy ?? 1);
    }
    if (a.ex != null && a.ey != null) {
      ex = a.ex! * (s?.sx ?? 1); ey = a.ey! * (s?.sy ?? 1);
    }
    switch (a.action) {
      case 'tap':
        if (sx == null) return false;
        await NativeBridge.tap(sx, sy!);
        return false;
      case 'type':
        if (a.text == null) return false;
        await NativeBridge.type(a.text!, idx: a.tIndex ?? -1);
        return false;
      case 'swipe':
        if (sx == null || ex == null) return false;
        await NativeBridge.swipe(sx, sy!, ex, ey!);
        return false;
      case 'back': await NativeBridge.back(); return false;
      case 'home': await NativeBridge.home(); return false;
      case 'done': return true;
      default: return false;
    }
  }
}

// ============ UI ============
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _storage = const FlutterSecureStorage();
  final _tts = FlutterTts();
  final _stt = SpeechToText();
  final _goal = TextEditingController();
  final _entries = <TEntry>[];

  String _lang = 'hi-IN';
  String? _key;
  bool _running = false, _listening = false;

  @override
  void initState() { super.initState(); _loadKey(); }

  Future<void> _loadKey() async {
    final k = await _storage.read(key: 'gemini_key');
    setState(() => _key = k);
    if (k == null && mounted) _askKey();
  }

  Future<void> _askKey() async {
    final c = TextEditingController(text: _key ?? '');
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Gemini API Key'),
        content: TextField(controller: c,
          decoration: const InputDecoration(hintText: 'AIza…')),
        actions: [TextButton(
          onPressed: () => Navigator.pop(ctx, c.text.trim()),
          child: const Text('Save'))],
      ),
    );
    if (r != null && r.isNotEmpty) {
      await _storage.write(key: 'gemini_key', value: r);
      setState(() => _key = r);
    }
  }

  Future<void> _voice() async {
    final ok = await _stt.initialize();
    if (!ok) return;
    setState(() => _listening = true);
    await _stt.listen(
      localeId: _lang,
      onResult: (r) {
        if (r.finalResult) {
          _goal.text = r.recognizedWords;
          setState(() => _listening = false);
        }
      },
    );
  }

  Future<void> _run() async {
    final g = _goal.text.trim();
    if (g.isEmpty || _key == null) return;
    setState(() { _running = true; _entries.clear(); });
    await _tts.setLanguage(_lang);

    final loop = AgentLoop(
      gemini: Gemini(apiKey: _key!, lang: _lang),
      onT: (e) { if (mounted) setState(() => _entries.add(e)); },
      onSpeak: (s) async => await _tts.speak(s),
      onConfirm: (q) async {
        await _tts.speak(q);
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('⚠️ Confirm'),
            content: Text(q),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Haan')),
            ],
          ),
        ) ?? false;
      },
    );
    await loop.run(g);
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jarvis'),
        actions: [
          DropdownButton<String>(
            value: _lang,
            onChanged: (v) => setState(() => _lang = v!),
            items: const [
              DropdownMenuItem(value: 'en-US', child: Text('EN')),
              DropdownMenuItem(value: 'hi-IN', child: Text('हि')),
              DropdownMenuItem(value: 'or-IN', child: Text('ଓ')),
            ],
          ),
          IconButton(icon: const Icon(Icons.key), onPressed: _askKey),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: TextField(
                controller: _goal,
                decoration: const InputDecoration(
                  hintText: 'Kya karna hai?',
                  border: OutlineInputBorder(),
                ),
              )),
              IconButton.filled(
                onPressed: _listening ? null : _voice,
                icon: Icon(_listening ? Icons.mic : Icons.mic_none)),
              IconButton.filled(
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.play_arrow)),
            ]),
          ),
          if (_running) const LinearProgressIndicator(),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _entries.length,
              itemBuilder: (ctx, i) {
                final e = _entries[i];
                final c = switch (e.type) {
                  TType.observe => Colors.blue.shade100,
                  TType.action => Colors.green.shade100,
                  TType.warn => Colors.orange.shade100,
                  TType.result => Colors.purple.shade100,
                };
                return Card(color: c, child: ListTile(
                  title: Text(e.title, style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.black87)),
                  subtitle: Text(e.detail,
                    style: const TextStyle(color: Colors.black54)),
                ));
              },
            ),
          ),
        ],
      ),
    );
  }
}
