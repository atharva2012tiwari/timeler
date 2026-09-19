import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum AtmosphereType { stormToSky, nightToDawn, deepOceanToSurface }

void main() => runApp(const Timeler());

// ---------------------------------------------------------------------------
// Sound helper — uses Linux freedesktop sounds or Android native MethodChannel
// ---------------------------------------------------------------------------

class SoundPlayer {
  static Process? _activeProcess;
  static const MethodChannel _androidAudio =
      MethodChannel('io.github.atharva2012tiwari.timeler/audio');

  static Future<void> playCompletion() async {
    if (Platform.isAndroid) {
      try {
        await _androidAudio.invokeMethod('playCompletion');
        return;
      } catch (_) {}
    }
    _activeProcess?.kill();
    for (final cmd in [
      [
        'ffplay',
        '-nodisp',
        '-loop',
        '0',
        '-loglevel',
        'quiet',
        '/usr/share/sounds/freedesktop/stereo/complete.oga',
      ],
      ['canberra-gtk-play', '-i', 'complete', '--loop=0'],
      ['aplay', '/usr/share/sounds/alsa/Front_Center.wav'],
    ]) {
      try {
        _activeProcess = await Process.start(cmd.first, cmd.sublist(1));
        return;
      } catch (_) {}
    }
  }

  static void stop() {
    if (Platform.isAndroid) {
      try {
        _androidAudio.invokeMethod('stop');
      } catch (_) {}
    }
    _activeProcess?.kill();
    _activeProcess = null;
  }

  static Future<void> playPhaseEnd() async {
    if (Platform.isAndroid) {
      try {
        await _androidAudio.invokeMethod('playBell');
        return;
      } catch (_) {}
    }
    for (final cmd in [
      [
        'ffplay',
        '-nodisp',
        '-autoexit',
        '-loglevel',
        'quiet',
        '/usr/share/sounds/freedesktop/stereo/bell.oga',
      ],
      ['canberra-gtk-play', '-i', 'bell'],
      ['aplay', '/usr/share/sounds/alsa/Front_Center.wav'],
    ]) {
      try {
        final r = await Process.run(cmd.first, cmd.sublist(1));
        if (r.exitCode == 0) return;
      } catch (_) {}
    }
  }
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum TimerMode { timer, pomodoro }

enum PomodoroPhase { work, shortBreak, longBreak }

class TaskItem {
  String title;
  bool isCompleted;
  TaskItem(this.title, {this.isCompleted = false});
}

// ---------------------------------------------------------------------------
// Progress & Analytics Service (Experimental)
// ---------------------------------------------------------------------------

enum ProgressPeriod { today, week, month, allTime }

class FocusSession {
  final String id;
  final DateTime timestamp;
  final int durationMinutes;
  final String mode; // 'timer' or 'pomodoro'
  final String? sessionName;

  FocusSession({
    required this.id,
    required this.timestamp,
    required this.durationMinutes,
    required this.mode,
    this.sessionName,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'durationMinutes': durationMinutes,
    'mode': mode,
    if (sessionName != null) 'sessionName': sessionName,
  };

  factory FocusSession.fromJson(Map<String, dynamic> json) {
    return FocusSession(
      id: json['id'] as String? ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp:
          DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
      durationMinutes: (json['durationMinutes'] as num?)?.toInt() ?? 0,
      mode: json['mode'] as String? ?? 'timer',
      sessionName: json['sessionName'] as String?,
    );
  }
}

class StatsService {
  StatsService._();
  static final StatsService instance = StatsService._();

  final List<FocusSession> _sessions = [];
  List<FocusSession> get sessions => List.unmodifiable(_sessions);
  bool _initialized = false;

  @visibleForTesting
  void setSessionsForTesting(List<FocusSession> testSessions) {
    _sessions.clear();
    _sessions.addAll(testSessions);
    _initialized = true;
  }

  @visibleForTesting
  void clearForTesting() {
    _sessions.clear();
    _initialized = false;
  }

  Future<File> _resolveFile() async {
    String? basePath = Platform.environment['SNAP_USER_DATA'];
    if (basePath == null || basePath.isEmpty) {
      if (Platform.isLinux) {
        final xdg = Platform.environment['XDG_DATA_HOME'];
        if (xdg != null && xdg.isNotEmpty) {
          basePath = '$xdg/timeler';
        } else {
          final home = Platform.environment['HOME'] ?? '.';
          basePath = '$home/.local/share/timeler';
        }
      } else {
        try {
          final dir = await getApplicationDocumentsDirectory();
          basePath = dir.path;
        } catch (_) {
          basePath = '.';
        }
      }
    }
    final dir = Directory(basePath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/stats.json');
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final file = await _resolveFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is List) {
            _sessions.clear();
            for (final item in decoded) {
              if (item is Map<String, dynamic>) {
                _sessions.add(FocusSession.fromJson(item));
              }
            }
          }
        }
      }
    } catch (_) {}
    _initialized = true;
  }

  Future<void> recordSession({
    required int durationMinutes,
    required String mode,
    String? sessionName,
  }) async {
    final session = FocusSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      durationMinutes: durationMinutes,
      mode: mode,
      sessionName: sessionName,
    );
    _sessions.insert(0, session);
    await _save();
  }

  Future<void> _save() async {
    try {
      final file = await _resolveFile();
      final data = jsonEncode(_sessions.map((s) => s.toJson()).toList());
      await file.writeAsString(data, flush: true);
    } catch (_) {}
  }

  List<FocusSession> getSessionsForPeriod(ProgressPeriod period) {
    final now = DateTime.now();
    return switch (period) {
      ProgressPeriod.today => _sessions.where((s) {
          return s.timestamp.year == now.year &&
              s.timestamp.month == now.month &&
              s.timestamp.day == now.day;
        }).toList(),
      ProgressPeriod.week => _sessions.where((s) {
          final sevenDaysAgo = DateTime(now.year, now.month, now.day)
              .subtract(const Duration(days: 6));
          final sessionDate = DateTime(
              s.timestamp.year, s.timestamp.month, s.timestamp.day);
          return sessionDate.isAtSameMomentAs(sevenDaysAgo) ||
              sessionDate.isAfter(sevenDaysAgo);
        }).toList(),
      ProgressPeriod.month => _sessions.where((s) {
          return s.timestamp.year == now.year &&
              s.timestamp.month == now.month;
        }).toList(),
      ProgressPeriod.allTime => List.of(_sessions),
    };
  }

  int getTotalMinutes(List<FocusSession> list) {
    return list.fold(0, (sum, s) => sum + s.durationMinutes);
  }

  int getActiveDaysCount(List<FocusSession> list) {
    final days = <String>{};
    for (final s in list) {
      days.add('${s.timestamp.year}-${s.timestamp.month}-${s.timestamp.day}');
    }
    return days.length;
  }

  int calculateStreak() {
    if (_sessions.isEmpty) return 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final Set<String> sessionDates = {};
    for (final s in _sessions) {
      sessionDates.add('${s.timestamp.year}-${s.timestamp.month}-${s.timestamp.day}');
    }

    String toKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

    DateTime checkDate;
    if (sessionDates.contains(toKey(today))) {
      checkDate = today;
    } else if (sessionDates.contains(toKey(yesterday))) {
      checkDate = yesterday;
    } else {
      return 0;
    }

    int streak = 0;
    while (sessionDates.contains(toKey(checkDate))) {
      streak++;
      checkDate = checkDate.subtract(const Duration(days: 1));
    }
    return streak;
  }

  static String formatDuration(int totalMinutes) {
    if (totalMinutes <= 0) return '0m';
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

class AtmosphereTheme {
  static ThemeData lerp(double clear, AtmosphereType type) {
    final primary = switch (type) {
      AtmosphereType.nightToDawn =>
        Color.lerp(const Color(0xffa8b8e0), const Color(0xfff2a65a), clear)!,
      AtmosphereType.deepOceanToSurface =>
        Color.lerp(const Color(0xff4a9ec4), const Color(0xff40e0d0), clear)!,
      _ =>
        Color.lerp(const Color(0xff8ba4bd), const Color(0xfff0c060), clear)!,
    };

    final surface = switch (type) {
      AtmosphereType.nightToDawn =>
        Color.lerp(const Color(0xd9050b1a), const Color(0xd91f132e), clear)!,
      AtmosphereType.deepOceanToSurface =>
        Color.lerp(const Color(0xd9021020), const Color(0xd9083848), clear)!,
      _ =>
        Color.lerp(const Color(0xd90a1520), const Color(0xd9143050), clear)!,
    };

    final border = Color.lerp(
      const Color(0x33ffffff),
      const Color(0x55ffffff),
      clear,
    )!;

    return ThemeData(
      fontFamily: 'SF Pro',
      brightness: Brightness.dark,
      useMaterial3: true,
    ).copyWith(
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'SF Pro'),
      colorScheme: ColorScheme.dark(
        primary: primary,
        surface: surface,
        onSurface: Colors.white,
        outline: border,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xff162e45),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary.withValues(alpha: 0.85),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: Colors.white70),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white.withValues(alpha: 0.14),
        selectedColor: primary.withValues(alpha: 0.45),
        side: const BorderSide(color: Color(0x44ffffff)),
        labelStyle: const TextStyle(
          color: Colors.white,
          fontFamily: 'SF Pro',
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

class Timeler extends StatelessWidget {
  const Timeler({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'SF Pro',
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const WeatherTimer(),
  );
}

// ---------------------------------------------------------------------------
// Main State
// ---------------------------------------------------------------------------

class WeatherTimer extends StatefulWidget {
  const WeatherTimer({super.key});

  @override
  State<WeatherTimer> createState() => _WeatherTimerState();
}

class _WeatherTimerState extends State<WeatherTimer>
    with TickerProviderStateMixin {
  AtmosphereType currentAtmosphere = AtmosphereType.stormToSky;
  // --- Common state ---
  int minutes = 30;
  Duration timerDuration = const Duration(minutes: 30);
  Duration left = const Duration(minutes: 30);
  DateTime? stamp;
  Timer? ticker;
  bool running = false;
  TimerMode mode = TimerMode.timer;
  bool showCompletion = false;

  // --- Session name ---
  final _sessionNameController = TextEditingController();

  // --- Pomodoro state ---
  int workMinutes = 25;
  int breakMinutes = 5;
  int longBreakMinutes = 15;
  int totalRounds = 4;
  int currentRound = 1;
  PomodoroPhase pomodoroPhase = PomodoroPhase.work;
  int _pomodoroAccumulatedMs = 0;
  bool pomodoroWaitingForNextPhase = false;

  // --- Tasks ---
  List<TaskItem> tasks = [];
  final _taskController = TextEditingController();
  int _mobileTabIndex = 0;

  // --- Animation ---
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    StatsService.instance.init();
  }

  @override
  void dispose() {
    ticker?.cancel();
    _breathe.dispose();
    _sessionNameController.dispose();
    _taskController.dispose();
    SoundPlayer.stop();
    super.dispose();
  }

  // --- Computed ---

  int get _currentPhaseMinutes => switch (pomodoroPhase) {
    PomodoroPhase.work => workMinutes,
    PomodoroPhase.shortBreak => breakMinutes,
    PomodoroPhase.longBreak => longBreakMinutes,
  };

  double get clear {
    if (showCompletion) return 1.0;
    if (mode == TimerMode.timer) {
      final totalMs = timerDuration.inMilliseconds;
      if (totalMs <= 0) return 1.0;
      return (1 - left.inMilliseconds / totalMs).clamp(0.0, 1.0);
    }
    // Pomodoro — overall progress
    final totalMs =
        (totalRounds * workMinutes +
            (totalRounds - 1) * breakMinutes +
            longBreakMinutes) *
        60000;
    if (totalMs == 0) return 0;
    final phaseMs = _currentPhaseMinutes * 60000;
    final phaseElapsed = (phaseMs - left.inMilliseconds).clamp(0, phaseMs);
    return ((_pomodoroAccumulatedMs + phaseElapsed) / totalMs).clamp(0.0, 1.0);
  }

  String get clock {
    final hours = left.inHours;
    final mins = left.inMinutes % 60;
    final secs = left.inSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${left.inMinutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String get statusText {
    if (showCompletion) return 'SESSION COMPLETE';
    if (mode == TimerMode.timer) {
      return running ? 'WEATHERING THE MOMENT' : 'READY WHEN YOU ARE';
    }
    if (pomodoroWaitingForNextPhase) {
      return switch (pomodoroPhase) {
        PomodoroPhase.shortBreak =>
          'FOCUS ROUND $currentRound COMPLETE · READY FOR BREAK',
        PomodoroPhase.longBreak =>
          'ALL $totalRounds FOCUS ROUNDS DONE · READY FOR LONG BREAK',
        PomodoroPhase.work =>
          'BREAK OVER · READY FOR ROUND $currentRound/$totalRounds',
      };
    }
    if (!running &&
        currentRound == 1 &&
        pomodoroPhase == PomodoroPhase.work &&
        left == Duration(minutes: workMinutes)) {
      return 'READY WHEN YOU ARE';
    }
    final phaseLabel = switch (pomodoroPhase) {
      PomodoroPhase.work => 'FOCUS',
      PomodoroPhase.shortBreak => 'SHORT BREAK',
      PomodoroPhase.longBreak => 'LONG BREAK',
    };
    return 'ROUND $currentRound/$totalRounds · $phaseLabel';
  }

  String get mainActionLabel {
    if (running) return 'Pause';
    if (mode == TimerMode.pomodoro && pomodoroWaitingForNextPhase) {
      return switch (pomodoroPhase) {
        PomodoroPhase.shortBreak => 'Continue to Break',
        PomodoroPhase.longBreak => 'Continue to Long Break',
        PomodoroPhase.work => 'Continue to Focus',
      };
    }
    if (mode == TimerMode.pomodoro) {
      final totalPhaseDuration = Duration(minutes: _currentPhaseMinutes);
      if (left < totalPhaseDuration && left > Duration.zero) {
        return 'Resume';
      }
    } else {
      if (left < timerDuration && left > Duration.zero) {
        return 'Resume';
      }
    }
    return 'Begin focus';
  }

  // --- Actions ---

  void advance() {
    final next = left - DateTime.now().difference(stamp!);
    stamp = DateTime.now();
    if (next <= Duration.zero) {
      ticker?.cancel();
      if (mode == TimerMode.timer) {
        SoundPlayer.playCompletion();
        setState(() {
          left = Duration.zero;
          running = false;
          showCompletion = true;
        });
        final sName = _sessionNameController.text.trim();
        final durationMins = timerDuration.inMinutes > 0
            ? timerDuration.inMinutes
            : (timerDuration.inSeconds > 0 ? 1 : 0);
        StatsService.instance.recordSession(
          durationMinutes: durationMins,
          mode: 'timer',
          sessionName: sName.isNotEmpty ? sName : null,
        );
      } else {
        _advancePomodoro();
      }
    } else {
      setState(() => left = next);
    }
  }

  void _advancePomodoro() {
    _pomodoroAccumulatedMs += _currentPhaseMinutes * 60000;

    if (pomodoroPhase == PomodoroPhase.work) {
      final sName = _sessionNameController.text.trim();
      StatsService.instance.recordSession(
        durationMinutes: workMinutes,
        mode: 'pomodoro',
        sessionName: sName.isNotEmpty ? sName : null,
      );
      SoundPlayer.playPhaseEnd();
      if (currentRound >= totalRounds) {
        setState(() {
          pomodoroPhase = PomodoroPhase.longBreak;
          left = Duration(minutes: longBreakMinutes);
          running = false;
          pomodoroWaitingForNextPhase = true;
        });
      } else {
        setState(() {
          pomodoroPhase = PomodoroPhase.shortBreak;
          left = Duration(minutes: breakMinutes);
          running = false;
          pomodoroWaitingForNextPhase = true;
        });
      }
    } else if (pomodoroPhase == PomodoroPhase.longBreak) {
      SoundPlayer.playCompletion();
      setState(() {
        running = false;
        showCompletion = true;
        pomodoroWaitingForNextPhase = false;
      });
    } else {
      SoundPlayer.playPhaseEnd();
      setState(() {
        currentRound++;
        pomodoroPhase = PomodoroPhase.work;
        left = Duration(minutes: workMinutes);
        running = false;
        pomodoroWaitingForNextPhase = true;
      });
    }
  }

  void _startTicker() {
    stamp = DateTime.now();
    ticker = Timer.periodic(
      const Duration(milliseconds: 180),
      (_) => advance(),
    );
  }

  void toggle() {
    if (running) {
      advance();
      ticker?.cancel();
      setState(() => running = false);
      return;
    }
    if (pomodoroWaitingForNextPhase) {
      pomodoroWaitingForNextPhase = false;
    }
    if (left == Duration.zero) {
      if (mode == TimerMode.timer) {
        left = timerDuration;
      } else {
        left = Duration(minutes: _currentPhaseMinutes);
      }
    }
    _startTicker();
    setState(() => running = true);
  }

  void reset() {
    ticker?.cancel();
    SoundPlayer.stop();
    setState(() {
      running = false;
      showCompletion = false;
      pomodoroWaitingForNextPhase = false;
      if (mode == TimerMode.timer) {
        left = timerDuration;
      } else {
        currentRound = 1;
        pomodoroPhase = PomodoroPhase.work;
        left = Duration(minutes: workMinutes);
        _pomodoroAccumulatedMs = 0;
      }
    });
  }

  void select(int value) {
    ticker?.cancel();
    setState(() {
      minutes = value;
      timerDuration = Duration(minutes: value);
      left = timerDuration;
      running = false;
      showCompletion = false;
    });
  }

  void selectDuration(Duration duration) {
    if (duration <= Duration.zero) return;
    ticker?.cancel();
    setState(() {
      minutes = duration.inMinutes;
      timerDuration = duration;
      left = duration;
      running = false;
      showCompletion = false;
    });
  }

  void setMode(TimerMode newMode) {
    if (newMode == mode) return;
    ticker?.cancel();
    SoundPlayer.stop();
    setState(() {
      mode = newMode;
      running = false;
      showCompletion = false;
      pomodoroWaitingForNextPhase = false;
      if (newMode == TimerMode.pomodoro) {
        currentRound = 1;
        pomodoroPhase = PomodoroPhase.work;
        left = Duration(minutes: workMinutes);
        _pomodoroAccumulatedMs = 0;
      } else {
        left = timerDuration;
      }
    });
  }

  void updatePomodoro({int? work, int? brk, int? longBrk, int? rounds}) {
    if (running) return;
    setState(() {
      if (work != null) workMinutes = work.clamp(1, 120);
      if (brk != null) breakMinutes = brk.clamp(1, 30);
      if (longBrk != null) longBreakMinutes = longBrk.clamp(1, 60);
      if (rounds != null) totalRounds = rounds.clamp(1, 12);
      if (pomodoroWaitingForNextPhase) {
        left = Duration(minutes: _currentPhaseMinutes);
      } else {
        currentRound = 1;
        pomodoroPhase = PomodoroPhase.work;
        left = Duration(minutes: workMinutes);
        _pomodoroAccumulatedMs = 0;
      }
    });
  }

  void selectPomodoroPhase(PomodoroPhase phase) {
    if (running) return;
    setState(() {
      pomodoroPhase = phase;
      pomodoroWaitingForNextPhase = false;
      switch (phase) {
        case PomodoroPhase.work:
          left = Duration(minutes: workMinutes);
          break;
        case PomodoroPhase.shortBreak:
          left = Duration(minutes: breakMinutes);
          break;
        case PomodoroPhase.longBreak:
          left = Duration(minutes: longBreakMinutes);
          break;
      }
    });
  }

  Future<void> customPomodoroPhaseDuration(PomodoroPhase phase) async {
    if (running) return;
    final initial = switch (phase) {
      PomodoroPhase.work => Duration(minutes: workMinutes),
      PomodoroPhase.shortBreak => Duration(minutes: breakMinutes),
      PomodoroPhase.longBreak => Duration(minutes: longBreakMinutes),
    };
    final title = switch (phase) {
      PomodoroPhase.work => 'Focus Duration',
      PomodoroPhase.shortBreak => 'Short Break Duration',
      PomodoroPhase.longBreak => 'Long Break Duration',
    };
    final subtitle = switch (phase) {
      PomodoroPhase.work => 'Set your focus sprint duration',
      PomodoroPhase.shortBreak => 'Set your quick recharge duration',
      PomodoroPhase.longBreak => 'Set your deep restorative break duration',
    };
    final color = switch (phase) {
      PomodoroPhase.work => const Color(0xfff59e0b),
      PomodoroPhase.shortBreak => const Color(0xff10b981),
      PomodoroPhase.longBreak => const Color(0xff8b5cf6),
    };

    final result = await showDialog<Duration>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (dialogContext) => _CustomDurationDialog(
        initialDuration: initial,
        primaryColor: color,
        title: title,
        subtitle: subtitle,
        buttonLabel: 'Set Duration',
      ),
    );
    if (result != null && mounted) {
      final totalMins = result.inMinutes > 0
          ? result.inMinutes
          : (result.inSeconds > 0 ? 1 : 1);
      switch (phase) {
        case PomodoroPhase.work:
          updatePomodoro(work: totalMins);
          break;
        case PomodoroPhase.shortBreak:
          updatePomodoro(brk: totalMins);
          break;
        case PomodoroPhase.longBreak:
          updatePomodoro(longBrk: totalMins);
          break;
      }
    }
  }

  void dismissCompletion() {
    SoundPlayer.stop();
    setState(() {
      showCompletion = false;
      pomodoroWaitingForNextPhase = false;
      if (mode == TimerMode.pomodoro) {
        currentRound = 1;
        pomodoroPhase = PomodoroPhase.work;
        left = Duration(minutes: workMinutes);
        _pomodoroAccumulatedMs = 0;
      } else {
        left = Duration(minutes: minutes);
      }
    });
  }

  void addTask(String title) {
    if (title.trim().isEmpty) return;
    setState(() => tasks.add(TaskItem(title.trim())));
    _taskController.clear();
  }

  void toggleTask(int index) {
    setState(() => tasks[index].isCompleted = !tasks[index].isCompleted);
  }

  void removeTask(int index) {
    setState(() => tasks.removeAt(index));
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return _SettingsDialog(
              currentAtmosphere: currentAtmosphere,
              onAtmosphereChanged: (type) {
                setState(() => currentAtmosphere = type);
                setDialogState(() {});
              },
              onOpenProgress: () {
                Navigator.of(dialogContext).pop();
                _showProgressDialog();
              },
            );
          },
        );
      },
    );
  }

  void _showProgressDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (dialogContext) {
        return _ProgressDialog(
          primaryColor: Theme.of(context).colorScheme.primary,
        );
      },
    );
  }

  Future<void> customDuration() async {
    final result = await showDialog<Duration>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (dialogContext) => _CustomDurationDialog(
        initialDuration: timerDuration,
        primaryColor: Theme.of(context).colorScheme.primary,
      ),
    );
    if (result != null && result > Duration.zero) {
      selectDuration(result);
    }
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Main UI
          AnimatedBuilder(
            animation: _breathe,
            builder: (context, _) {
              return Theme(
                data: AtmosphereTheme.lerp(clear, currentAtmosphere),
                child: _ImmersiveBackdrop(
                  atmosphere: currentAtmosphere,
                  clear: clear,
                  breathe: _breathe.value,
                  child: SafeArea(
                    child: LayoutBuilder(
                      builder: (_, box) {
                        final isMobile = box.maxWidth < 600;
                        final compact = box.maxWidth < 950;
                        final horizontalPadding =
                            isMobile ? 16.0 : (compact ? 24.0 : 40.0);
                        final verticalPadding = isMobile ? 12.0 : 24.0;
                        final dial = _TimerDial(
                            clock: clock,
                            clear: clear,
                            running: running,
                            breathe: _breathe.value,
                            statusText: statusText,
                            sessionNameController: _sessionNameController,
                            isPomodoro: mode == TimerMode.pomodoro,
                            pomodoroPhase: pomodoroPhase,
                            workMinutes: workMinutes,
                            breakMinutes: breakMinutes,
                            longBreakMinutes: longBreakMinutes,
                            onSelectPhase: running ? null : selectPomodoroPhase,
                            isMobile: isMobile,
                          );
                          final controls = _Controls(
                            running: running,
                            onToggle: toggle,
                            onReset: reset,
                            actionLabel: mainActionLabel,
                            isWaiting: mode == TimerMode.pomodoro &&
                                pomodoroWaitingForNextPhase,
                          );
                          final taskPanel = _TaskListPanel(
                            tasks: tasks,
                            onToggle: toggleTask,
                            onRemove: removeTask,
                            onAdd: addTask,
                            controller: _taskController,
                            isMobile: isMobile,
                          );
                          return Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: horizontalPadding,
                              vertical: verticalPadding,
                            ),
                            child: Column(
                            children: [
                              // Quote
                              _QuoteBanner(atmosphere: currentAtmosphere),
                              const SizedBox(height: 6),
                              // Header
                              _Header(
                                clear: clear,
                                atmosphere: currentAtmosphere,
                                onSettingsPressed: _showSettingsDialog,
                              ),
                              const SizedBox(height: 12),
                              // Main content
                              Expanded(
                                child: compact
                                    ? SingleChildScrollView(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            dial,
                                            const SizedBox(height: 18),
                                            Center(child: controls),
                                            const SizedBox(height: 20),
                                            if (isMobile) ...[
                                              // Mobile Tab Selector (Focus Setup | Tasks)
                                              Center(
                                                child: Container(
                                                  height: 38,
                                                  constraints:
                                                      const BoxConstraints(
                                                    maxWidth: 320,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(20),
                                                    color: Colors.white
                                                        .withValues(alpha: 0.12),
                                                    border: Border.all(
                                                      color: Colors.white
                                                          .withValues(alpha: 0.22),
                                                      width: 1,
                                                    ),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        child: GestureDetector(
                                                          onTap: () => setState(
                                                            () =>
                                                                _mobileTabIndex = 0,
                                                          ),
                                                          behavior:
                                                              HitTestBehavior
                                                                  .opaque,
                                                          child:
                                                              AnimatedContainer(
                                                            duration:
                                                                const Duration(
                                                              milliseconds: 200,
                                                            ),
                                                            decoration:
                                                                BoxDecoration(
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                18,
                                                              ),
                                                              color: _mobileTabIndex ==
                                                                      0
                                                                  ? Colors.white
                                                                      .withValues(
                                                                        alpha:
                                                                            0.25,
                                                                      )
                                                                  : Colors
                                                                      .transparent,
                                                            ),
                                                            alignment:
                                                                Alignment.center,
                                                            child: Text(
                                                              'Focus Setup',
                                                              style: TextStyle(
                                                                fontSize: 12,
                                                                fontWeight:
                                                                    _mobileTabIndex ==
                                                                            0
                                                                        ? FontWeight
                                                                            .w600
                                                                        : FontWeight
                                                                            .w400,
                                                                color:
                                                                    _mobileTabIndex ==
                                                                            0
                                                                        ? Colors
                                                                            .white
                                                                        : Colors
                                                                            .white70,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      Expanded(
                                                        child: GestureDetector(
                                                          onTap: () => setState(
                                                            () =>
                                                                _mobileTabIndex = 1,
                                                          ),
                                                          behavior:
                                                              HitTestBehavior
                                                                  .opaque,
                                                          child:
                                                              AnimatedContainer(
                                                            duration:
                                                                const Duration(
                                                              milliseconds: 200,
                                                            ),
                                                            decoration:
                                                                BoxDecoration(
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                18,
                                                              ),
                                                              color: _mobileTabIndex ==
                                                                      1
                                                                  ? Colors.white
                                                                      .withValues(
                                                                        alpha:
                                                                            0.25,
                                                                      )
                                                                  : Colors
                                                                      .transparent,
                                                            ),
                                                            alignment:
                                                                Alignment.center,
                                                            child: Text(
                                                              tasks.isEmpty
                                                                  ? 'Tasks'
                                                                  : 'Tasks (${tasks.where((t) => !t.isCompleted).length})',
                                                              style: TextStyle(
                                                                fontSize: 12,
                                                                fontWeight:
                                                                    _mobileTabIndex ==
                                                                            1
                                                                        ? FontWeight
                                                                            .w600
                                                                        : FontWeight
                                                                            .w400,
                                                                color:
                                                                    _mobileTabIndex ==
                                                                            1
                                                                        ? Colors
                                                                            .white
                                                                        : Colors
                                                                            .white70,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              _mobileTabIndex == 0
                                                  ? _SettingsPanel(
                                                      mode: mode,
                                                      onModeChanged: setMode,
                                                      minutes: minutes,
                                                      onSelect: select,
                                                      onCustom: customDuration,
                                                      controls: const SizedBox
                                                          .shrink(),
                                                      running: running,
                                                      workMinutes: workMinutes,
                                                      breakMinutes: breakMinutes,
                                                      longBreakMinutes:
                                                          longBreakMinutes,
                                                      totalRounds: totalRounds,
                                                      onPomodoroUpdate:
                                                          updatePomodoro,
                                                      currentAtmosphere:
                                                          currentAtmosphere,
                                                      onAtmosphereChanged: (v) =>
                                                          setState(
                                                        () =>
                                                            currentAtmosphere = v,
                                                      ),
                                                      pomodoroPhase:
                                                          pomodoroPhase,
                                                      currentRound: currentRound,
                                                      onSelectPhase:
                                                          selectPomodoroPhase,
                                                      onCustomPhaseDuration:
                                                          customPomodoroPhaseDuration,
                                                      isMobile: isMobile,
                                                    )
                                                  : SizedBox(
                                                      height: 380,
                                                      child: taskPanel,
                                                    ),
                                            ] else ...[
                                              _SettingsPanel(
                                                mode: mode,
                                                onModeChanged: setMode,
                                                minutes: minutes,
                                                onSelect: select,
                                                onCustom: customDuration,
                                                controls: const SizedBox.shrink(),
                                                running: running,
                                                workMinutes: workMinutes,
                                                breakMinutes: breakMinutes,
                                                longBreakMinutes:
                                                    longBreakMinutes,
                                                totalRounds: totalRounds,
                                                onPomodoroUpdate:
                                                    updatePomodoro,
                                                currentAtmosphere:
                                                    currentAtmosphere,
                                                onAtmosphereChanged: (v) =>
                                                    setState(
                                                  () => currentAtmosphere = v,
                                                ),
                                                pomodoroPhase: pomodoroPhase,
                                                currentRound: currentRound,
                                                onSelectPhase:
                                                    selectPomodoroPhase,
                                                onCustomPhaseDuration:
                                                    customPomodoroPhaseDuration,
                                                isMobile: false,
                                              ),
                                              const SizedBox(height: 16),
                                              SizedBox(
                                                height: 350,
                                                child: taskPanel,
                                              ),
                                            ],
                                            const SizedBox(height: 24),
                                          ],
                                        ),
                                      )
                                    : Row(
                                        children: [
                                          Expanded(flex: 3, child: dial),
                                          const SizedBox(width: 24),
                                          Expanded(
                                            flex: 2,
                                            child: SingleChildScrollView(
                                              child: Column(
                                                children: [
                                                  _SettingsPanel(
                                                    mode: mode,
                                                    onModeChanged: setMode,
                                                    minutes: minutes,
                                                    onSelect: select,
                                                    onCustom: customDuration,
                                                    controls: controls,
                                                    running: running,
                                                    workMinutes: workMinutes,
                                                    breakMinutes: breakMinutes,
                                                    longBreakMinutes:
                                                        longBreakMinutes,
                                                    totalRounds: totalRounds,
                                                    onPomodoroUpdate:
                                                        updatePomodoro,
                                                    currentAtmosphere:
                                                        currentAtmosphere,
                                                    onAtmosphereChanged: (v) =>
                                                        setState(
                                                      () =>
                                                          currentAtmosphere = v,
                                                    ),
                                                    pomodoroPhase: pomodoroPhase,
                                                    currentRound: currentRound,
                                                    onSelectPhase:
                                                        selectPomodoroPhase,
                                                    onCustomPhaseDuration:
                                                        customPomodoroPhaseDuration,
                                                  ),
                                                  const SizedBox(height: 16),
                                                  SizedBox(
                                                    height: 350,
                                                    child: taskPanel,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),

          // Completion overlay
          IgnorePointer(
            ignoring: !showCompletion,
            child: AnimatedOpacity(
              opacity: showCompletion ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOut,
              child: _CompletionOverlay(
                sessionName: _sessionNameController.text,
                isPomodoro: mode == TimerMode.pomodoro,
                onDismiss: dismissCompletion,
                atmosphere: currentAtmosphere,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quote Banner
// ---------------------------------------------------------------------------

class _QuoteBanner extends StatelessWidget {
  const _QuoteBanner({required this.atmosphere});
  final AtmosphereType atmosphere;

  @override
  Widget build(BuildContext context) {
    final quote = switch (atmosphere) {
      AtmosphereType.deepOceanToSurface =>
        '\u201CFrom the deepest dark, rise toward the light\u201D',
      AtmosphereType.nightToDawn =>
        '\u201CThe darkest hour is just before the dawn\u201D',
      _ => '\u201CTransform your inner storm into a clear day\u201D',
    };
    return Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 600),
        child: Text(
          quote,
          key: ValueKey(atmosphere),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 12,
            fontWeight: FontWeight.w400,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.clear,
    required this.atmosphere,
    this.onSettingsPressed,
  });
  final double clear;
  final AtmosphereType atmosphere;
  final VoidCallback? onSettingsPressed;

  @override
  Widget build(BuildContext context) {
    final color = Color.lerp(
      Colors.white.withValues(alpha: 0.7),
      Colors.white,
      clear,
    );

    final headerIcon = atmosphere == AtmosphereType.deepOceanToSurface
        ? Icons.water_outlined
        : Icons.cloud_outlined;

    final (label, key) = switch (atmosphere) {
      AtmosphereType.deepOceanToSurface => clear > .72
          ? ('SUNLIT SHALLOWS', 'surface')
          : clear > .35
              ? ('ASCENDING', 'mid')
              : ('DEEP ABYSS', 'deep'),
      AtmosphereType.nightToDawn => clear > .72
          ? ('GOLDEN DAWN', 'dawn')
          : clear > .35
              ? ('FIRST LIGHT', 'mid')
              : ('MIDNIGHT', 'night'),
      _ => clear > .72
          ? ('CLEARING SKY', 'clear')
          : clear > .35
              ? ('BREAKING THROUGH', 'mid')
              : ('STORM FRONT', 'storm'),
    };

    return Row(
      children: [
        Icon(headerIcon, size: 18, color: color),
        const SizedBox(width: 6),
        Text(
          'TIMELER',
          style: TextStyle(
            letterSpacing: 3,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        const Spacer(),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.white.withValues(alpha: 0.12),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.22),
                width: 1,
              ),
            ),
            child: Text(
              label,
              key: ValueKey(key),
              style: TextStyle(
                fontSize: 9.5,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ),
        if (onSettingsPressed != null) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: 'Settings',
            child: SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                onPressed: onSettingsPressed,
                icon: const Icon(Icons.settings_outlined, size: 18),
                color: color,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                splashRadius: 16,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Immersive Backdrop
// ---------------------------------------------------------------------------

class _ImmersiveBackdrop extends StatelessWidget {
  const _ImmersiveBackdrop({
    required this.clear,
    required this.breathe,
    required this.atmosphere,
    required this.child,
  });

  final double clear;
  final double breathe;
  final AtmosphereType atmosphere;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = 1.0 + breathe * 0.03;
    final bgImage1 = switch (atmosphere) {
      AtmosphereType.nightToDawn => 'assets/images/night.jpg',
      AtmosphereType.deepOceanToSurface => 'assets/images/deep_ocean.jpg',
      _ => 'assets/images/storm.jpg',
    };
    final bgImage2 = switch (atmosphere) {
      AtmosphereType.nightToDawn => 'assets/images/dawn.jpg',
      AtmosphereType.deepOceanToSurface => 'assets/images/surface.jpg',
      _ => 'assets/images/clear.jpg',
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: Transform.scale(
            scale: scale,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 1000),
              layoutBuilder:
                  (Widget? currentChild, List<Widget> previousChildren) {
                    return Stack(
                      fit: StackFit.expand,
                      alignment: Alignment.center,
                      children: <Widget>[
                        ...previousChildren,
                        ?currentChild,
                      ],
                    );
                  },
              child: SizedBox.expand(
                key: ValueKey(bgImage1),
                child: Image.asset(
                  bgImage1,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: clear,
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeInOut,
            child: Transform.scale(
              scale: scale,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 1000),
                layoutBuilder:
                    (Widget? currentChild, List<Widget> previousChildren) {
                      return Stack(
                        fit: StackFit.expand,
                        alignment: Alignment.center,
                        children: <Widget>[
                          ...previousChildren,
                          ?currentChild,
                        ],
                      );
                    },
                child: SizedBox.expand(
                  key: ValueKey(bgImage2),
                  child: Image.asset(
                    bgImage2,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
          ),
        ),
        // Ocean-specific: animated tinted overlay that shifts with depth
        if (atmosphere == AtmosphereType.deepOceanToSurface) ...[
          Positioned.fill(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 1200),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.lerp(
                      const Color(0x60001830),
                      const Color(0x1000c8ff),
                      clear,
                    )!,
                    Color.lerp(
                      const Color(0x80000818),
                      const Color(0x2000e8ff),
                      clear,
                    )!,
                  ],
                ),
              ),
            ),
          ),
          // Caustic light rays from above
          Positioned.fill(
            child: Opacity(
              opacity: (0.08 + clear * 0.18 + breathe * 0.04).clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0.0, -0.9 + breathe * 0.15),
                    radius: 0.8 + clear * 0.6,
                    colors: [
                      Color.lerp(
                        const Color(0x2040c8ff),
                        const Color(0x50fffde0),
                        clear,
                      )!,
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.2,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(
                    alpha: atmosphere == AtmosphereType.deepOceanToSurface
                        ? 0.5 - clear * 0.15
                        : 0.4,
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black.withValues(
                    alpha: atmosphere == AtmosphereType.deepOceanToSurface
                        ? 0.55 - clear * 0.15
                        : 0.45,
                  ),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ),
        // Ocean-specific: animated bubble particles
        if (atmosphere == AtmosphereType.deepOceanToSurface)
          Positioned.fill(
            child: _OceanBubbles(clear: clear, breathe: breathe),
          ),
        child,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Ocean Bubbles — animated rising bubble particles
// ---------------------------------------------------------------------------

class _Bubble {
  double x;
  double y;
  double radius;
  double speed;
  double wobbleOffset;
  double opacity;

  _Bubble({
    required this.x,
    required this.y,
    required this.radius,
    required this.speed,
    required this.wobbleOffset,
    required this.opacity,
  });
}

class _OceanBubbles extends StatefulWidget {
  const _OceanBubbles({required this.clear, required this.breathe});
  final double clear;
  final double breathe;

  @override
  State<_OceanBubbles> createState() => _OceanBubblesState();
}

class _OceanBubblesState extends State<_OceanBubbles>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Bubble> _bubbles;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();

    // Generate a set of bubbles with varied properties
    _bubbles = List.generate(28, (i) {
      final hash = (i * 7919 + 13) % 1000;
      return _Bubble(
        x: (hash % 100) / 100.0,
        y: ((hash * 3 + 17) % 100) / 100.0,
        radius: 1.5 + (hash % 40) / 10.0,
        speed: 0.015 + (hash % 30) / 1000.0,
        wobbleOffset: (hash % 628) / 100.0,
        opacity: 0.15 + (hash % 50) / 100.0,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return CustomPaint(
          painter: _BubblePainter(
            bubbles: _bubbles,
            time: _controller.value,
            clear: widget.clear,
            breathe: widget.breathe,
          ),
        );
      },
    );
  }
}

class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.bubbles,
    required this.time,
    required this.clear,
    required this.breathe,
  });

  final List<_Bubble> bubbles;
  final double time;
  final double clear;
  final double breathe;

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in bubbles) {
      // Bubbles rise upward continuously
      final progress = (b.y - time * b.speed * 30) % 1.2 - 0.1;
      if (progress < -0.05 || progress > 1.05) continue;

      // Wobble side to side with a sinusoidal motion
      final wobble = 0.02 *
          (progress * 10 + b.wobbleOffset + time * 12)
              .remainder(6.28)
              .abs();
      final sinWobble =
          wobble > 3.14 ? -(wobble - 3.14) / 3.14 : wobble / 3.14;
      final xPos = (b.x + sinWobble * 0.03) * size.width;
      final yPos = progress * size.height;

      // Bubbles get slightly larger and brighter as they rise near the surface
      final surfaceBoost = (1 - progress).clamp(0.0, 1.0);
      final radius =
          b.radius * (1.0 + surfaceBoost * 0.4 + breathe * 0.15);
      final alpha =
          (b.opacity * (0.5 + clear * 0.5) * (0.6 + surfaceBoost * 0.4))
              .clamp(0.0, 0.7);

      // Color shifts from deep blue glow to white-cyan near surface
      final color = Color.lerp(
        Color.fromRGBO(100, 200, 255, alpha),
        Color.fromRGBO(220, 255, 255, alpha),
        clear * surfaceBoost,
      )!;

      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(xPos, yPos), radius, paint);

      // Highlight shimmer on each bubble
      final highlightPaint = Paint()
        ..color = Colors.white.withValues(alpha: alpha * 0.4)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(xPos - radius * 0.3, yPos - radius * 0.3),
        radius * 0.3,
        highlightPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Mode Toggle — glassmorphic segmented control
// ---------------------------------------------------------------------------

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged});
  final TimerMode mode;
  final ValueChanged<TimerMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white.withValues(alpha: 0.12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.22),
          width: 1,
        ),
      ),
      child: LayoutBuilder(
        builder: (_, constraints) {
          final half = constraints.maxWidth / 2;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                left: mode == TimerMode.timer ? 2 : half,
                top: 2,
                bottom: 2,
                width: half - 2,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white.withValues(alpha: 0.24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => onChanged(TimerMode.timer),
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: Text(
                          'Timer',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: mode == TimerMode.timer
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: mode == TimerMode.timer
                                ? Colors.white
                                : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => onChanged(TimerMode.pomodoro),
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: Text(
                          'Pomodoro',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: mode == TimerMode.pomodoro
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: mode == TimerMode.pomodoro
                                ? Colors.white
                                : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Timer Dial
// ---------------------------------------------------------------------------

class _TimerDial extends StatelessWidget {
  const _TimerDial({
    required this.clock,
    required this.clear,
    required this.running,
    required this.breathe,
    required this.statusText,
    required this.sessionNameController,
    this.isPomodoro = false,
    this.pomodoroPhase = PomodoroPhase.work,
    this.workMinutes = 25,
    this.breakMinutes = 5,
    this.longBreakMinutes = 15,
    this.onSelectPhase,
    this.isMobile = false,
  });

  final String clock;
  final double clear;
  final bool running;
  final double breathe;
  final String statusText;
  final TextEditingController sessionNameController;
  final bool isPomodoro;
  final PomodoroPhase pomodoroPhase;
  final int workMinutes;
  final int breakMinutes;
  final int longBreakMinutes;
  final ValueChanged<PomodoroPhase>? onSelectPhase;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glowColor = Color.lerp(
      const Color(0xff5080b0),
      const Color(0xfff0c060),
      clear,
    )!;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isMobile ? 500 : 440,
          maxHeight: isMobile ? double.infinity : 330,
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(36),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 40,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: glowColor.withValues(alpha: 0.18 + breathe * 0.08),
                blurRadius: 70,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(36),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 35, sigmaY: 35),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeInOut,
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 24 : 40,
                  vertical: isMobile ? 28 : 24,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(36),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.28),
                    width: 1.2,
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.24),
                      Colors.white.withValues(alpha: 0.12),
                    ],
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isPomodoro) ...[
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _DialPhasePill(
                              label: 'Focus',
                              durationMinutes: workMinutes,
                              isActive: pomodoroPhase == PomodoroPhase.work,
                              accentColor: const Color(0xfff59e0b),
                              onTap: onSelectPhase != null
                                  ? () => onSelectPhase!(PomodoroPhase.work)
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            _DialPhasePill(
                              label: 'Break',
                              durationMinutes: breakMinutes,
                              isActive: pomodoroPhase == PomodoroPhase.shortBreak,
                              accentColor: const Color(0xff10b981),
                              onTap: onSelectPhase != null
                                  ? () => onSelectPhase!(PomodoroPhase.shortBreak)
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            _DialPhasePill(
                              label: 'Long Break',
                              durationMinutes: longBreakMinutes,
                              isActive: pomodoroPhase == PomodoroPhase.longBreak,
                              accentColor: const Color(0xff8b5cf6),
                              onTap: onSelectPhase != null
                                  ? () => onSelectPhase!(PomodoroPhase.longBreak)
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    // Clock
                    Text(
                      clock,
                      style: TextStyle(
                        fontFamily: 'SF Pro',
                        color: Colors.white,
                        fontSize: clock.length > 5
                            ? (isMobile ? 48 : 56)
                            : (isMobile ? 72 : 80),
                        fontWeight: FontWeight.w300,
                        letterSpacing: clock.length > 5
                            ? 2
                            : (isMobile ? 5 : 8),
                        height: 1.0,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Status
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      child: Text(
                        statusText,
                        key: ValueKey(statusText),
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 3,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Session name (intentional frosted capsule)
                    Container(
                      width: 230,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: Colors.white.withValues(alpha: 0.12),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.edit_note_rounded,
                            size: 16,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: sessionNameController,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Name this session\u2026',
                                hintStyle: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.35),
                                  fontSize: 12,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ],
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

class _DialPhasePill extends StatelessWidget {
  const _DialPhasePill({
    required this.label,
    required this.durationMinutes,
    required this.isActive,
    required this.accentColor,
    this.onTap,
  });

  final String label;
  final int durationMinutes;
  final bool isActive;
  final Color accentColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isActive
                ? accentColor.withValues(alpha: 0.28)
                : Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive
                  ? accentColor.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.20),
              width: 1,
            ),
          ),
          child: Text(
            '$label ${durationMinutes}m',
            style: TextStyle(
              color: isActive
                  ? accentColor
                  : Colors.white.withValues(alpha: 0.8),
              fontSize: 11,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings Panel
// ---------------------------------------------------------------------------

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.mode,
    required this.onModeChanged,
    required this.minutes,
    required this.onSelect,
    required this.onCustom,
    required this.controls,
    required this.running,
    required this.workMinutes,
    required this.breakMinutes,
    required this.longBreakMinutes,
    required this.totalRounds,
    required this.onPomodoroUpdate,
    required this.currentAtmosphere,
    required this.onAtmosphereChanged,
    this.pomodoroPhase = PomodoroPhase.work,
    this.currentRound = 1,
    this.onSelectPhase,
    this.onCustomPhaseDuration,
    this.isMobile = false,
  });

  final TimerMode mode;
  final ValueChanged<TimerMode> onModeChanged;
  final int minutes;
  final ValueChanged<int> onSelect;
  final VoidCallback onCustom;
  final Widget controls;
  final bool running;
  final int workMinutes, breakMinutes, longBreakMinutes, totalRounds;
  final void Function({int? work, int? brk, int? longBrk, int? rounds})
  onPomodoroUpdate;
  final AtmosphereType currentAtmosphere;
  final ValueChanged<AtmosphereType> onAtmosphereChanged;
  final PomodoroPhase pomodoroPhase;
  final int currentRound;
  final ValueChanged<PomodoroPhase>? onSelectPhase;
  final ValueChanged<PomodoroPhase>? onCustomPhaseDuration;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    final panel = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 40,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.05),
            blurRadius: 10,
            spreadRadius: -2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 35, sigmaY: 35),
          child: Container(
            padding: EdgeInsets.all(isMobile ? 20 : 24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.28),
                width: 1.2,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.22),
                  Colors.white.withValues(alpha: 0.10),
                ],
              ),
            ),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Mode toggle
                  _ModeToggle(mode: mode, onChanged: onModeChanged),
                  const SizedBox(height: 20),

                  // Mode-specific content
                  if (mode == TimerMode.timer) ...[
                    const Text(
                      'Set your horizon',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children:
                          [5, 15, 30, 45, 60]
                              .map<Widget>(
                                (value) => ChoiceChip(
                                  label: Text('$value min'),
                                  selected: value == minutes,
                                  onSelected: (_) => onSelect(value),
                                ),
                              )
                              .toList()
                            ..add(
                              ActionChip(
                                label: const Text('Custom'),
                                onPressed: onCustom,
                              ),
                            ),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Pomodoro intervals',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.1),
                              width: 1,
                            ),
                          ),
                          child: Text(
                            'Round $currentRound of $totalRounds',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Option 1: Focus
                    _PomodoroPhaseOptionCard(
                      title: 'FOCUS',
                      minutes: workMinutes,
                      accentColor: const Color(0xfff59e0b),
                      icon: Icons.bolt_rounded,
                      isCurrent: pomodoroPhase == PomodoroPhase.work,
                      enabled: !running,
                      onTap: () => onSelectPhase?.call(PomodoroPhase.work),
                      onDec: () => onPomodoroUpdate(work: workMinutes - 5),
                      onInc: () => onPomodoroUpdate(work: workMinutes + 5),
                      onCustomDuration: () =>
                          onCustomPhaseDuration?.call(PomodoroPhase.work),
                    ),
                    const SizedBox(height: 8),

                    // Option 2: Break
                    _PomodoroPhaseOptionCard(
                      title: 'SHORT BREAK',
                      minutes: breakMinutes,
                      accentColor: const Color(0xff10b981),
                      icon: Icons.coffee_rounded,
                      isCurrent: pomodoroPhase == PomodoroPhase.shortBreak,
                      enabled: !running,
                      onTap: () =>
                          onSelectPhase?.call(PomodoroPhase.shortBreak),
                      onDec: () => onPomodoroUpdate(brk: breakMinutes - 1),
                      onInc: () => onPomodoroUpdate(brk: breakMinutes + 1),
                      onCustomDuration: () =>
                          onCustomPhaseDuration?.call(PomodoroPhase.shortBreak),
                    ),
                    const SizedBox(height: 8),

                    // Option 3: Long Break
                    _PomodoroPhaseOptionCard(
                      title: 'LONG BREAK',
                      minutes: longBreakMinutes,
                      accentColor: const Color(0xff8b5cf6),
                      icon: Icons.spa_rounded,
                      isCurrent: pomodoroPhase == PomodoroPhase.longBreak,
                      enabled: !running,
                      onTap: () =>
                          onSelectPhase?.call(PomodoroPhase.longBreak),
                      onDec: () =>
                          onPomodoroUpdate(longBrk: longBreakMinutes - 5),
                      onInc: () =>
                          onPomodoroUpdate(longBrk: longBreakMinutes + 5),
                      onCustomDuration: () =>
                          onCustomPhaseDuration?.call(PomodoroPhase.longBreak),
                    ),
                    const SizedBox(height: 10),

                    // Rounds per cycle bar
                    _PomodoroRoundsBar(
                      totalRounds: totalRounds,
                      currentRound: currentRound,
                      enabled: !running,
                      onDec: () => onPomodoroUpdate(rounds: totalRounds - 1),
                      onInc: () => onPomodoroUpdate(rounds: totalRounds + 1),
                    ),
                  ],

                  const SizedBox(height: 18),
                  Text(
                    mode == TimerMode.timer
                        ? switch (currentAtmosphere) {
                            AtmosphereType.deepOceanToSurface =>
                              'Rise from the depths.\nYour focus becomes sunlight.',
                            AtmosphereType.nightToDawn =>
                              'The night lifts gently.\nYour focus becomes the dawn.',
                            _ =>
                              'The storm fades gradually.\nYour focus becomes daylight.',
                          }
                        : switch (currentAtmosphere) {
                            AtmosphereType.deepOceanToSurface =>
                              'Work in rounds, rest between.\nYou surface with each cycle.',
                            _ =>
                              'Work in rounds, rest between.\nThe sky clears with each cycle.',
                          },
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.7,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 20),
                  controls,
                ],
              ),
            ),
          ),
        ),
      );

    if (isMobile) {
      return panel;
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: panel,
    );
  }
}

// ---------------------------------------------------------------------------
// Pomodoro Option Card (Clear, Big, Distinct & Premium)
// ---------------------------------------------------------------------------

class _PomodoroPhaseOptionCard extends StatelessWidget {
  const _PomodoroPhaseOptionCard({
    required this.title,
    required this.minutes,
    required this.accentColor,
    required this.icon,
    required this.isCurrent,
    required this.enabled,
    required this.onTap,
    required this.onDec,
    required this.onInc,
    required this.onCustomDuration,
  });

  final String title;
  final int minutes;
  final Color accentColor;
  final IconData icon;
  final bool isCurrent;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDec;
  final VoidCallback onInc;
  final VoidCallback onCustomDuration;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isCurrent
                  ? [
                      accentColor.withValues(alpha: 0.22),
                      accentColor.withValues(alpha: 0.08),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.06),
                      Colors.white.withValues(alpha: 0.02),
                    ],
            ),
            border: Border.all(
              color: isCurrent
                  ? accentColor.withValues(alpha: 0.75)
                  : Colors.white.withValues(alpha: 0.1),
              width: isCurrent ? 1.6 : 1.0,
            ),
            boxShadow: isCurrent
                ? [
                    BoxShadow(
                      color: accentColor.withValues(alpha: 0.25),
                      blurRadius: 18,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : [],
          ),
          child: Row(
            children: [
              // Icon container
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: isCurrent ? 0.28 : 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: accentColor.withValues(alpha: isCurrent ? 0.6 : 0.3),
                    width: 1,
                  ),
                ),
                child: Icon(icon, size: 16, color: accentColor),
              ),
              const SizedBox(width: 10),

              // Title and duration
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: isCurrent
                                  ? accentColor
                                  : Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                        if (isCurrent) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: accentColor.withValues(alpha: 0.6),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              'ACTIVE',
                              style: TextStyle(
                                color: accentColor,
                                fontSize: 8,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: InkWell(
                        onTap: enabled ? onCustomDuration : null,
                        borderRadius: BorderRadius.circular(6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '$minutes',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            Text(
                              ' min',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: Colors.white.withValues(alpha: 0.65),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.edit_rounded,
                              size: 11,
                              color: Colors.white.withValues(alpha: 0.35),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Stepper buttons
              _stepBtn(Icons.remove_rounded, enabled ? onDec : null),
              const SizedBox(width: 5),
              _stepBtn(Icons.add_rounded, enabled ? onInc : null),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback? onPressed) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 14),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.1),
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.white.withValues(alpha: 0.03),
          disabledForegroundColor: Colors.white24,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pomodoro Rounds Bar
// ---------------------------------------------------------------------------

class _PomodoroRoundsBar extends StatelessWidget {
  const _PomodoroRoundsBar({
    required this.totalRounds,
    required this.currentRound,
    required this.enabled,
    required this.onDec,
    required this.onInc,
  });

  final int totalRounds;
  final int currentRound;
  final bool enabled;
  final VoidCallback onDec;
  final VoidCallback onInc;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withValues(alpha: 0.05),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.repeat_rounded,
              size: 15,
              color: Colors.white70,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Rounds per cycle',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 4),
                // Indicator dots
                Row(
                  children: List.generate(
                    totalRounds.clamp(1, 8),
                    (i) => Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: (i + 1) <= currentRound
                            ? const Color(0xfff0c060)
                            : Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              onPressed: enabled ? onDec : null,
              icon: const Icon(Icons.remove_rounded, size: 14),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.white.withValues(alpha: 0.03),
                disabledForegroundColor: Colors.white24,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$totalRounds',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              onPressed: enabled ? onInc : null,
              icon: const Icon(Icons.add_rounded, size: 14),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.white.withValues(alpha: 0.03),
                disabledForegroundColor: Colors.white24,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

class _Controls extends StatelessWidget {
  const _Controls({
    required this.running,
    required this.onToggle,
    required this.onReset,
    this.actionLabel,
    this.isWaiting = false,
  });

  final bool running;
  final VoidCallback onToggle, onReset;
  final String? actionLabel;
  final bool isWaiting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = actionLabel ?? (running ? 'Pause' : 'Begin focus');
    final icon = running
        ? Icons.pause_rounded
        : (isWaiting
            ? Icons.arrow_forward_rounded
            : Icons.play_arrow_rounded);

    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 10,
      children: [
        OutlinedButton.icon(
          onPressed: onReset,
          icon: const Icon(Icons.replay_rounded, size: 18),
          label: const Text('Reset'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white.withValues(alpha: 0.9),
            side: BorderSide(
              color: Colors.white.withValues(alpha: 0.25),
              width: 1,
            ),
            backgroundColor: Colors.white.withValues(alpha: 0.10),
            padding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 14,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        FilledButton.icon(
          onPressed: onToggle,
          icon: Icon(icon, size: 20),
          label: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: isWaiting
                ? const Color(0xfff0c060)
                : (running
                    ? Colors.white.withValues(alpha: 0.22)
                    : theme.colorScheme.primary.withValues(alpha: 0.90)),
            foregroundColor: isWaiting ? Colors.black87 : Colors.white,
            padding: const EdgeInsets.symmetric(
              horizontal: 26,
              vertical: 14,
            ),
            elevation: 8,
            shadowColor: (isWaiting
                    ? const Color(0xfff0c060)
                    : theme.colorScheme.primary)
                .withValues(alpha: 0.45),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Completion Overlay
// ---------------------------------------------------------------------------

class _CompletionOverlay extends StatelessWidget {
  const _CompletionOverlay({
    required this.sessionName,
    required this.isPomodoro,
    required this.onDismiss,
    required this.atmosphere,
  });

  final String sessionName;
  final bool isPomodoro;
  final VoidCallback onDismiss;
  final AtmosphereType atmosphere;

  @override
  Widget build(BuildContext context) {
    final isOcean = atmosphere == AtmosphereType.deepOceanToSurface;
    final accentColor = isOcean ? const Color(0xff40e0d0) : const Color(0xfff0c060);
    final accentLight = isOcean ? const Color(0xffb0fff8) : const Color(0xfffff4be);
    final icon = isOcean ? Icons.water_drop_rounded : Icons.wb_sunny_rounded;

    final completionText = isOcean
        ? (isPomodoro
            ? 'All rounds complete. You\u2019ve reached the surface.'
            : 'You\u2019ve surfaced. Breathe the light.')
        : (isPomodoro
            ? 'All rounds cleared. The sky is yours.'
            : 'The storm has passed. Well done.');

    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(36),
              boxShadow: [
                BoxShadow(
                  color: accentColor.withValues(alpha: 0.15),
                  blurRadius: 80,
                  spreadRadius: 8,
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 60,
                  offset: const Offset(0, 20),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(36),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 48,
                    vertical: 44,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(36),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.2),
                      width: 1,
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: 0.15),
                        Colors.white.withValues(alpha: 0.05),
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icon
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [accentLight, accentColor],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: accentColor.withValues(alpha: 0.4),
                              blurRadius: 30,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: Icon(
                          icon,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                      const SizedBox(height: 28),

                      const Text(
                        'SESSION COMPLETE',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 4,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),

                      if (sessionName.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            sessionName.trim(),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),

                      Text(
                        completionText,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.5),
                          height: 1.6,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),

                      FilledButton(
                        onPressed: onDismiss,
                        style: FilledButton.styleFrom(
                          backgroundColor: accentColor.withValues(alpha: 0.8),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 36,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: const Text(
                          'Start New Session',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Task List Panel
// ---------------------------------------------------------------------------

class _TaskListPanel extends StatelessWidget {
  const _TaskListPanel({
    required this.tasks,
    required this.onToggle,
    required this.onRemove,
    required this.onAdd,
    required this.controller,
    this.isMobile = false,
  });

  final List<TaskItem> tasks;
  final ValueChanged<int> onToggle;
  final ValueChanged<int> onRemove;
  final ValueChanged<String> onAdd;
  final TextEditingController controller;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    final panel = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 40,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.05),
            blurRadius: 10,
            spreadRadius: -2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 35, sigmaY: 35),
          child: Container(
            padding: EdgeInsets.all(isMobile ? 20 : 24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.28),
                width: 1.2,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.22),
                  Colors.white.withValues(alpha: 0.10),
                ],
              ),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Focus Tasks',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView.builder(
                      itemCount: tasks.length,
                      itemBuilder: (context, index) {
                        final task = tasks[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              GestureDetector(
                                onTap: () => onToggle(index),
                                behavior: HitTestBehavior.opaque,
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: task.isCompleted
                                          ? const Color(0xfff0c060)
                                          : Colors.white.withValues(alpha: 0.4),
                                      width: 1.5,
                                    ),
                                    color: task.isCompleted
                                        ? const Color(0xfff0c060)
                                              .withValues(alpha: 0.2)
                                        : Colors.transparent,
                                  ),
                                  child: task.isCompleted
                                      ? const Icon(
                                          Icons.check,
                                          size: 12,
                                          color: Color(0xfff0c060),
                                        )
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  task.title,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: task.isCompleted
                                        ? Colors.white.withValues(alpha: 0.4)
                                        : Colors.white.withValues(alpha: 0.9),
                                    decoration: task.isCompleted
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 24,
                                height: 24,
                                child: IconButton(
                                  icon: Icon(
                                    Icons.close,
                                    size: 14,
                                    color: Colors.white.withValues(alpha: 0.4),
                                  ),
                                  onPressed: () => onRemove(index),
                                  padding: EdgeInsets.zero,
                                  style: IconButton.styleFrom(
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                        width: 1,
                      ),
                    ),
                    child: Center(
                      child: TextField(
                        controller: controller,
                        onSubmitted: onAdd,
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Add a new task... (Press Enter)',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

    if (isMobile) {
      return panel;
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: panel,
    );
  }
}

// ---------------------------------------------------------------------------
// Settings Dialog
// ---------------------------------------------------------------------------

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog({
    required this.currentAtmosphere,
    required this.onAtmosphereChanged,
    required this.onOpenProgress,
  });

  final AtmosphereType currentAtmosphere;
  final ValueChanged<AtmosphereType> onAtmosphereChanged;
  final VoidCallback onOpenProgress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 680),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 35, sigmaY: 35),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                color: const Color(0xee0e1824),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 40,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: primary.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.settings_rounded,
                            color: primary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Text(
                          'Settings',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded, size: 20),
                          color: Colors.white54,
                          hoverColor: Colors.white10,
                          splashRadius: 20,
                          tooltip: 'Close',
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Atmosphere Section Title
                    Row(
                      children: [
                        Icon(
                          Icons.palette_outlined,
                          size: 16,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'ATMOSPHERE',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.5,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Option 1: Storm to Clear Sky
                    _AtmosphereOptionTile(
                      title: 'Storm to Clear Sky',
                      description: 'Rain & storm clouds clear into bright blue sky as your session progresses',
                      icon: Icons.thunderstorm_outlined,
                      isSelected: currentAtmosphere == AtmosphereType.stormToSky,
                      primaryColor: primary,
                      onTap: () => onAtmosphereChanged(AtmosphereType.stormToSky),
                    ),
                    const SizedBox(height: 12),

                    // Option 2: Night to Dawn
                    _AtmosphereOptionTile(
                      title: 'Night to Dawn',
                      description: 'Deep starry night slowly transforms into a glowing golden sunrise',
                      icon: Icons.nightlight_outlined,
                      isSelected: currentAtmosphere == AtmosphereType.nightToDawn,
                      primaryColor: primary,
                      onTap: () =>
                          onAtmosphereChanged(AtmosphereType.nightToDawn),
                    ),
                    const SizedBox(height: 12),

                    // Option 3: Deep Ocean to Surface
                    _AtmosphereOptionTile(
                      title: 'Deep Ocean to Surface',
                      description: 'Rise from the dark abyss through bioluminescent depths to sun-drenched shallows',
                      icon: Icons.water_outlined,
                      isSelected: currentAtmosphere == AtmosphereType.deepOceanToSurface,
                      primaryColor: primary,
                      onTap: () =>
                          onAtmosphereChanged(AtmosphereType.deepOceanToSurface),
                    ),

                    const SizedBox(height: 24),

                    // Statistics & Activity Section Title
                    Row(
                      children: [
                        Icon(
                          Icons.insights_rounded,
                          size: 16,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'STATISTICS & ACTIVITY',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.5,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Focus Progress & Analytics Tile
                    _SettingsActionTile(
                      title: 'Focus Progress & Analytics',
                      description: 'View daily, weekly, monthly, and all-time focus statistics',
                      icon: Icons.insights_rounded,
                      primaryColor: primary,
                      onTap: onOpenProgress,
                    ),

                    const SizedBox(height: 28),

                    // Done Button
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: FilledButton.styleFrom(
                        backgroundColor: primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Done',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
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

class _AtmosphereOptionTile extends StatelessWidget {
  const _AtmosphereOptionTile({
    required this.title,
    required this.description,
    required this.icon,
    required this.isSelected,
    required this.primaryColor,
    required this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final bool isSelected;
  final Color primaryColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: isSelected
              ? primaryColor.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.04),
          border: Border.all(
            color: isSelected
                ? primaryColor.withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: 0.08),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected
                    ? primaryColor.withValues(alpha: 0.3)
                    : Colors.white.withValues(alpha: 0.06),
              ),
              child: Icon(
                icon,
                color: isSelected ? Colors.white : Colors.white70,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: Colors.white.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected) ...[
              const SizedBox(width: 10),
              Icon(Icons.check_circle_rounded, color: primaryColor, size: 20),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsActionTile extends StatelessWidget {
  const _SettingsActionTile({
    required this.title,
    required this.description,
    required this.icon,
    required this.primaryColor,
    required this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final Color primaryColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Colors.white.withValues(alpha: 0.04),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
            width: 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primaryColor.withValues(alpha: 0.15),
              ),
              child: Icon(
                icon,
                color: primaryColor,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.95),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: Colors.white.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.4),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Progress & Analytics Dialog
// ---------------------------------------------------------------------------

class _ProgressDialog extends StatefulWidget {
  const _ProgressDialog({required this.primaryColor});

  final Color primaryColor;

  @override
  State<_ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<_ProgressDialog> {
  ProgressPeriod _selectedPeriod = ProgressPeriod.today;

  @override
  Widget build(BuildContext context) {
    final sessions =
        StatsService.instance.getSessionsForPeriod(_selectedPeriod);
    final totalMinutes = StatsService.instance.getTotalMinutes(sessions);
    final streak = StatsService.instance.calculateStreak();
    final pomodoroCount = sessions.where((s) => s.mode == 'pomodoro').length;
    final timerCount = sessions.where((s) => s.mode == 'timer').length;
    final activeDays = StatsService.instance.getActiveDaysCount(sessions);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 680),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 35, sigmaY: 35),
            child: Container(
              padding: const EdgeInsets.all(26),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                color: const Color(0xee0e1824),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 40,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: widget.primaryColor.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.insights_rounded,
                          color: widget.primaryColor,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Text(
                        'Focus Progress',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded, size: 20),
                        color: Colors.white54,
                        hoverColor: Colors.white10,
                        splashRadius: 20,
                        tooltip: 'Close',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Period Selector Bar
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        _buildPeriodTab('Today', ProgressPeriod.today),
                        _buildPeriodTab('7 Days', ProgressPeriod.week),
                        _buildPeriodTab('This Month', ProgressPeriod.month),
                        _buildPeriodTab('All Time', ProgressPeriod.allTime),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Scrollable Body
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 3 Metric Cards Row
                          Row(
                            children: [
                              Expanded(
                                child: _MetricCard(
                                  title: 'FOCUS TIME',
                                  value: StatsService.formatDuration(totalMinutes),
                                  icon: Icons.timer_outlined,
                                  primaryColor: widget.primaryColor,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _MetricCard(
                                  title: 'SESSIONS',
                                  value: '${sessions.length}',
                                  icon: Icons.check_circle_outline_rounded,
                                  primaryColor: widget.primaryColor,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _MetricCard(
                                  title: _selectedPeriod == ProgressPeriod.week
                                      ? 'DAILY AVG'
                                      : (_selectedPeriod == ProgressPeriod.month
                                          ? 'ACTIVE DAYS'
                                          : 'STREAK'),
                                  value: _selectedPeriod == ProgressPeriod.week
                                      ? StatsService.formatDuration(totalMinutes ~/ 7)
                                      : (_selectedPeriod == ProgressPeriod.month
                                          ? '$activeDays days'
                                          : '$streak ${streak == 1 ? 'day' : 'days'}'),
                                  icon: Icons.local_fire_department_rounded,
                                  primaryColor: widget.primaryColor,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),

                          // Visual Breakdown Chart
                          _buildVisualChart(
                              sessions, totalMinutes, pomodoroCount, timerCount),
                          const SizedBox(height: 20),

                          // Recent Sessions List Section
                          Row(
                            children: [
                              Icon(
                                Icons.history_rounded,
                                size: 15,
                                color: Colors.white.withValues(alpha: 0.6),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'SESSION HISTORY (${sessions.length})',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.5,
                                  color: Colors.white.withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),

                          if (sessions.isEmpty)
                            _buildEmptyState()
                          else
                            ...sessions.take(15).map(
                                  (s) => _SessionHistoryItem(
                                    session: s,
                                    primaryColor: widget.primaryColor,
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
        ),
      ),
    );
  }

  Widget _buildPeriodTab(String title, ProgressPeriod period) {
    final isSelected = _selectedPeriod == period;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selectedPeriod = period),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected
                ? widget.primaryColor.withValues(alpha: 0.25)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? widget.primaryColor.withValues(alpha: 0.6)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected ? Colors.white : Colors.white60,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVisualChart(
    List<FocusSession> sessions,
    int totalMinutes,
    int pomodoroCount,
    int timerCount,
  ) {
    if (_selectedPeriod == ProgressPeriod.week) {
      return _build7DayChart(sessions);
    }
    return _buildModeDistributionBar(pomodoroCount, timerCount, totalMinutes);
  }

  Widget _build7DayChart(List<FocusSession> sessions) {
    final now = DateTime.now();
    final days = List.generate(7, (i) {
      final d = now.subtract(Duration(days: 6 - i));
      return DateTime(d.year, d.month, d.day);
    });

    final dayMinutes = days.map((d) {
      final matching = sessions.where((s) {
        return s.timestamp.year == d.year &&
            s.timestamp.month == d.month &&
            s.timestamp.day == d.day;
      });
      return matching.fold(0, (sum, s) => sum + s.durationMinutes);
    }).toList();

    int maxM = dayMinutes.reduce(math.max);
    if (maxM < 60) maxM = 60;

    const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LAST 7 DAYS ACTIVITY',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: Colors.white.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 110,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(7, (i) {
                final date = days[i];
                final isToday = i == 6;
                final m = dayMinutes[i];
                final heightFactor = (m / maxM).clamp(0.06, 1.0);

                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          m > 0 ? '${m}m' : '—',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                            color: isToday
                                ? widget.primaryColor
                                : (m > 0 ? Colors.white70 : Colors.white24),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: heightFactor,
                              widthFactor: 0.65,
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  color: isToday
                                      ? widget.primaryColor
                                      : (m > 0
                                          ? widget.primaryColor.withValues(alpha: 0.5)
                                          : Colors.white.withValues(alpha: 0.08)),
                                  border: isToday
                                      ? Border.all(
                                          color: Colors.white.withValues(alpha: 0.8),
                                          width: 1,
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isToday ? 'Today' : weekdayNames[date.weekday - 1],
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                            color: isToday ? widget.primaryColor : Colors.white60,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeDistributionBar(
    int pomodoroCount,
    int timerCount,
    int totalMinutes,
  ) {
    final totalSessions = pomodoroCount + timerCount;
    final pomoRatio = totalSessions > 0 ? pomodoroCount / totalSessions : 0.5;
    final timerRatio = totalSessions > 0 ? timerCount / totalSessions : 0.5;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'FOCUS DISTRIBUTION',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
              Text(
                '$totalSessions total sessions',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 10,
              child: totalSessions == 0
                  ? Container(color: Colors.white.withValues(alpha: 0.08))
                  : Row(
                      children: [
                        if (pomodoroCount > 0)
                          Expanded(
                            flex: (pomoRatio * 100).round(),
                            child: Container(color: Colors.deepOrangeAccent),
                          ),
                        if (timerCount > 0)
                          Expanded(
                            flex: (timerRatio * 100).round(),
                            child: Container(color: widget.primaryColor),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildLegendDot(Colors.deepOrangeAccent, 'Pomodoro ($pomodoroCount)'),
              const SizedBox(width: 16),
              _buildLegendDot(widget.primaryColor, 'Standard Timer ($timerCount)'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        children: [
          Icon(
            Icons.history_toggle_off_rounded,
            size: 34,
            color: Colors.white.withValues(alpha: 0.25),
          ),
          const SizedBox(height: 10),
          Text(
            'No focus sessions recorded for this period',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Complete a focus session to track your progress here',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.primaryColor,
  });

  final String title;
  final String value;
  final IconData icon;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: primaryColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.0,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: -0.3,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _SessionHistoryItem extends StatelessWidget {
  const _SessionHistoryItem({
    required this.session,
    required this.primaryColor,
  });

  final FocusSession session;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    final isPomodoro = session.mode == 'pomodoro';
    final name = (session.sessionName != null && session.sessionName!.isNotEmpty)
        ? session.sessionName!
        : (isPomodoro ? 'Pomodoro Focus' : 'Focus Session');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isPomodoro
                  ? Colors.deepOrangeAccent.withValues(alpha: 0.15)
                  : primaryColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isPomodoro ? Icons.alarm_rounded : Icons.timer_outlined,
              size: 16,
              color: isPomodoro ? Colors.deepOrangeAccent : primaryColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _formatSessionDate(session.timestamp),
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: primaryColor.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Text(
              '${session.durationMinutes}m',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: primaryColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatSessionDate(DateTime dt) {
    final now = DateTime.now();
    final isToday =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final timeStr = _formatTime(dt);
    if (isToday) return 'Today at $timeStr';
    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday = dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day;
    if (isYesterday) return 'Yesterday at $timeStr';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day} at $timeStr';
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }
}

// ---------------------------------------------------------------------------
// Custom Duration Dialog (Inspired by wheel timer UI, desktop optimized)
// ---------------------------------------------------------------------------

class _CustomDurationDialog extends StatefulWidget {
  const _CustomDurationDialog({
    required this.initialDuration,
    required this.primaryColor,
    this.title = 'Custom Timer',
    this.subtitle = 'How long do you want to focus for?',
    this.buttonLabel = 'Set Timer',
  });

  final Duration initialDuration;
  final Color primaryColor;
  final String title;
  final String subtitle;
  final String buttonLabel;

  @override
  State<_CustomDurationDialog> createState() => _CustomDurationDialogState();
}

class _CustomDurationDialogState extends State<_CustomDurationDialog> {
  late int _hours;
  late int _minutes;
  late int _seconds;

  late final FixedExtentScrollController _hoursController;
  late final FixedExtentScrollController _minutesController;
  late final FixedExtentScrollController _secondsController;

  @override
  void initState() {
    super.initState();
    _hours = widget.initialDuration.inHours.clamp(0, 23);
    _minutes = (widget.initialDuration.inMinutes % 60).clamp(0, 59);
    _seconds = (widget.initialDuration.inSeconds % 60).clamp(0, 59);

    _hoursController = FixedExtentScrollController(initialItem: _hours);
    _minutesController = FixedExtentScrollController(initialItem: _minutes);
    _secondsController = FixedExtentScrollController(initialItem: _seconds);
  }

  @override
  void dispose() {
    _hoursController.dispose();
    _minutesController.dispose();
    _secondsController.dispose();
    super.dispose();
  }

  Duration get _totalDuration =>
      Duration(hours: _hours, minutes: _minutes, seconds: _seconds);

  void _step(
    FixedExtentScrollController controller,
    int current,
    int delta,
    int max,
  ) {
    final target = (current + delta).clamp(0, max);
    controller.animateToItem(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isZero = _totalDuration == Duration.zero;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 35, sigmaY: 35),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(32),
                color: const Color(0xee0e1824),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 40,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top navigation bar
                  Row(
                    children: [
                      InkWell(
                        onTap: () => Navigator.of(context).pop(),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.1),
                              width: 1,
                            ),
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          widget.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 34),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 3-Wheel Drum Picker (Hours, Minutes, Seconds)
                  SizedBox(
                    height: 210,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Center selection lens
                        Container(
                          height: 46,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.15),
                              width: 1,
                            ),
                          ),
                        ),
                        // Columns
                        Row(
                          children: [
                            // Hours column
                            Expanded(
                              child: _buildDrumColumn(
                                label: 'hours',
                                controller: _hoursController,
                                count: 24,
                                selectedValue: _hours,
                                onSelected: (v) => setState(() => _hours = v),
                                unitSingular: 'hour',
                                unitPlural: 'hours',
                              ),
                            ),
                            // Minutes column
                            Expanded(
                              child: _buildDrumColumn(
                                label: 'min',
                                controller: _minutesController,
                                count: 60,
                                selectedValue: _minutes,
                                onSelected: (v) => setState(() => _minutes = v),
                                unitSingular: 'min',
                                unitPlural: 'min',
                              ),
                            ),
                            // Seconds column
                            Expanded(
                              child: _buildDrumColumn(
                                label: 'sec',
                                controller: _secondsController,
                                count: 60,
                                selectedValue: _seconds,
                                onSelected: (v) => setState(() => _seconds = v),
                                unitSingular: 'sec',
                                unitPlural: 'sec',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Total duration preview
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: isZero ? 0.4 : 1.0,
                    child: Text(
                      isZero
                          ? 'Select at least 1 second'
                          : _formatSelectedSummary(),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isZero
                            ? Colors.white38
                            : widget.primaryColor.withValues(alpha: 0.9),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Pill "Set Timer" Button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: isZero
                          ? null
                          : () => Navigator.of(context).pop(_totalDuration),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xff0e1824),
                        disabledBackgroundColor:
                            Colors.white.withValues(alpha: 0.12),
                        disabledForegroundColor: Colors.white38,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                      child: Text(
                        widget.buttonLabel,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatSelectedSummary() {
    final parts = <String>[];
    if (_hours > 0) parts.add('$_hours ${_hours == 1 ? 'hour' : 'hours'}');
    if (_minutes > 0) parts.add('$_minutes min');
    if (_seconds > 0) parts.add('$_seconds sec');
    return 'Total: ${parts.join(' ')}';
  }

  Widget _buildDrumColumn({
    required String label,
    required FixedExtentScrollController controller,
    required int count,
    required int selectedValue,
    required ValueChanged<int> onSelected,
    required String unitSingular,
    required String unitPlural,
  }) {
    return Column(
      children: [
        // Desktop quick increment up
        InkWell(
          onTap: () => _step(controller, selectedValue, -1, count - 1),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
            child: Icon(
              Icons.keyboard_arrow_up_rounded,
              size: 18,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
        ),
        // Drum wheel
        Expanded(
          child: ListWheelScrollView.useDelegate(
            controller: controller,
            itemExtent: 44,
            perspective: 0.003,
            diameterRatio: 1.25,
            physics: const FixedExtentScrollPhysics(),
            onSelectedItemChanged: onSelected,
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: count,
              builder: (context, index) {
                final isSelected = index == selectedValue;
                final unit = index == 1 ? unitSingular : unitPlural;

                return Center(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 150),
                    style: TextStyle(
                      fontFamily: 'SF Pro',
                      fontSize: isSelected ? 22 : 17,
                      fontWeight:
                          isSelected ? FontWeight.w700 : FontWeight.w400,
                      color: isSelected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.28),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text('$index'),
                        if (isSelected) ...[
                          const SizedBox(width: 4),
                          Text(
                            unit,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        // Desktop quick increment down
        InkWell(
          onTap: () => _step(controller, selectedValue, 1, count - 1),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
        ),
      ],
    );
  }
}
