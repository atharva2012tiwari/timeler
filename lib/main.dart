import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum AtmosphereType { stormToSky, nightToDawn, deepOceanToSurface }

void main() => runApp(const Timeler());

// ---------------------------------------------------------------------------
// Sound helper — uses Linux freedesktop sounds
// ---------------------------------------------------------------------------

class SoundPlayer {
  static Process? _activeProcess;

  static Future<void> playCompletion() async {
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
    _activeProcess?.kill();
    _activeProcess = null;
  }

  static Future<void> playPhaseEnd() async {
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
        backgroundColor: surface.withValues(alpha: 0.4),
        selectedColor: primary.withValues(alpha: 0.5),
        side: BorderSide(color: border),
        labelStyle: const TextStyle(
          color: Colors.white,
          fontFamily: 'SF Pro',
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

  // --- Tasks ---
  List<TaskItem> tasks = [];
  final _taskController = TextEditingController();

  // --- Animation ---
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat(reverse: true);

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
      return (1 -
              left.inMilliseconds / Duration(minutes: minutes).inMilliseconds)
          .clamp(0.0, 1.0);
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

  String get clock =>
      '${left.inMinutes.toString().padLeft(2, '0')}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';

  String get statusText {
    if (showCompletion) return 'SESSION COMPLETE';
    if (mode == TimerMode.timer) {
      return running ? 'WEATHERING THE MOMENT' : 'READY WHEN YOU ARE';
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
      if (currentRound >= totalRounds) {
        SoundPlayer.playPhaseEnd();
        setState(() {
          pomodoroPhase = PomodoroPhase.longBreak;
          left = Duration(minutes: longBreakMinutes);
        });
      } else {
        SoundPlayer.playPhaseEnd();
        setState(() {
          pomodoroPhase = PomodoroPhase.shortBreak;
          left = Duration(minutes: breakMinutes);
        });
      }
      _startTicker();
    } else if (pomodoroPhase == PomodoroPhase.longBreak) {
      SoundPlayer.playCompletion();
      setState(() {
        running = false;
        showCompletion = true;
      });
    } else {
      SoundPlayer.playPhaseEnd();
      setState(() {
        currentRound++;
        pomodoroPhase = PomodoroPhase.work;
        left = Duration(minutes: workMinutes);
      });
      _startTicker();
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
    if (left == Duration.zero) {
      if (mode == TimerMode.timer) {
        left = Duration(minutes: minutes);
      } else {
        left = Duration(minutes: _currentPhaseMinutes);
      }
    }
    stamp = DateTime.now();
    ticker = Timer.periodic(
      const Duration(milliseconds: 180),
      (_) => advance(),
    );
    setState(() => running = true);
  }

  void reset() {
    ticker?.cancel();
    SoundPlayer.stop();
    setState(() {
      running = false;
      showCompletion = false;
      if (mode == TimerMode.timer) {
        left = Duration(minutes: minutes);
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
      left = Duration(minutes: value);
      running = false;
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
      if (newMode == TimerMode.pomodoro) {
        currentRound = 1;
        pomodoroPhase = PomodoroPhase.work;
        left = Duration(minutes: workMinutes);
        _pomodoroAccumulatedMs = 0;
      } else {
        left = Duration(minutes: minutes);
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
      currentRound = 1;
      pomodoroPhase = PomodoroPhase.work;
      left = Duration(minutes: workMinutes);
      _pomodoroAccumulatedMs = 0;
    });
  }

  void dismissCompletion() {
    SoundPlayer.stop();
    setState(() {
      showCompletion = false;
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
            );
          },
        );
      },
    );
  }

  Future<void> customDuration() async {
    final controller = TextEditingController(text: minutes.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Custom duration'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Minutes',
            suffixText: 'min',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, int.tryParse(controller.text)),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result >= 1 && result <= 720) select(result);
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
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 40,
                        vertical: 24,
                      ),
                      child: LayoutBuilder(
                        builder: (_, box) {
                          final compact = box.maxWidth < 950;
                          final dial = _TimerDial(
                            clock: clock,
                            clear: clear,
                            running: running,
                            breathe: _breathe.value,
                            statusText: statusText,
                            sessionNameController: _sessionNameController,
                          );
                          final controls = _Controls(
                            running: running,
                            onToggle: toggle,
                            onReset: reset,
                          );
                          final taskPanel = _TaskListPanel(
                            tasks: tasks,
                            onToggle: toggleTask,
                            onRemove: removeTask,
                            onAdd: addTask,
                            controller: _taskController,
                          );
                          return Column(
                            children: [
                              // Quote
                              _QuoteBanner(atmosphere: currentAtmosphere),
                              const SizedBox(height: 8),
                              // Header
                              _Header(clear: clear, atmosphere: currentAtmosphere),
                              const SizedBox(height: 12),
                              // Main content
                              Expanded(
                                child: compact
                                    ? SingleChildScrollView(
                                        child: Column(
                                          children: [
                                            dial,
                                            const SizedBox(height: 16),
                                            controls,
                                            const SizedBox(height: 24),
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
                                              onPomodoroUpdate: updatePomodoro,
                                              currentAtmosphere:
                                                  currentAtmosphere,
                                              onAtmosphereChanged: (v) =>
                                                  setState(
                                                    () => currentAtmosphere = v,
                                                  ),
                                            ),
                                            const SizedBox(height: 16),
                                            SizedBox(
                                              height: 350,
                                              child: taskPanel,
                                            ),
                                          ],
                                        ),
                                      )
                                    : Row(
                                        children: [
                                          Expanded(flex: 3, child: dial),
                                          const SizedBox(width: 24),
                                          Expanded(
                                            flex: 2,
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
                                                            currentAtmosphere =
                                                                v,
                                                      ),
                                                ),
                                                const SizedBox(height: 16),
                                                Expanded(child: taskPanel),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              );
            },
          ),

          // Settings Icon (Bottom Left)
          Positioned(
            left: 24,
            bottom: 24,
            child: Tooltip(
              message: 'Settings',
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: IconButton(
                  onPressed: _showSettingsDialog,
                  icon: Icon(
                    Icons.settings_outlined,
                    color: Colors.white.withValues(alpha: 0.75),
                    size: 24,
                  ),
                  splashRadius: 24,
                  hoverColor: Colors.white.withValues(alpha: 0.12),
                ),
              ),
            ),
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
  const _Header({required this.clear, required this.atmosphere});
  final double clear;
  final AtmosphereType atmosphere;

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
        const SizedBox(width: 10),
        Text(
          'TIMELER',
          style: TextStyle(
            letterSpacing: 6,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        const Spacer(),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          child: Text(
            label,
            key: ValueKey(key),
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 4,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ),
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
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.08),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
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
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.white.withValues(alpha: 0.14),
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
                                : Colors.white54,
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
                                : Colors.white54,
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
  });

  final String clock;
  final double clear;
  final bool running;
  final double breathe;
  final String statusText;
  final TextEditingController sessionNameController;

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
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 310),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(36),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 60,
                offset: const Offset(0, 20),
              ),
              BoxShadow(
                color: glowColor.withValues(alpha: 0.12 + breathe * 0.06),
                blurRadius: 80,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(36),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 28,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(36),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                    width: 1,
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.12),
                      Colors.white.withValues(alpha: 0.04),
                    ],
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Clock
                    Text(
                      clock,
                      style: TextStyle(
                        fontFamily: 'SF Pro',
                        color: Colors.white,
                        fontSize: 80,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 8,
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

                    // Session name
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: sessionNameController,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Name this session\u2026',
                          hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: 0.25),
                            fontSize: 12,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 6,
                            horizontal: 12,
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

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 50,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                  width: 1,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.1),
                    Colors.white.withValues(alpha: 0.02),
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
                    const Text(
                      'Pomodoro settings',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _StepperRow(
                      label: 'Focus',
                      value: workMinutes,
                      suffix: 'min',
                      enabled: !running,
                      onDec: () => onPomodoroUpdate(work: workMinutes - 5),
                      onInc: () => onPomodoroUpdate(work: workMinutes + 5),
                    ),
                    _StepperRow(
                      label: 'Break',
                      value: breakMinutes,
                      suffix: 'min',
                      enabled: !running,
                      onDec: () => onPomodoroUpdate(brk: breakMinutes - 1),
                      onInc: () => onPomodoroUpdate(brk: breakMinutes + 1),
                    ),
                    _StepperRow(
                      label: 'Long break',
                      value: longBreakMinutes,
                      suffix: 'min',
                      enabled: !running,
                      onDec: () =>
                          onPomodoroUpdate(longBrk: longBreakMinutes - 5),
                      onInc: () =>
                          onPomodoroUpdate(longBrk: longBreakMinutes + 5),
                    ),
                    _StepperRow(
                      label: 'Rounds',
                      value: totalRounds,
                      suffix: '',
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
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stepper Row (for Pomodoro settings)
// ---------------------------------------------------------------------------

class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.label,
    required this.value,
    required this.suffix,
    required this.enabled,
    required this.onDec,
    required this.onInc,
  });

  final String label;
  final int value;
  final String suffix;
  final bool enabled;
  final VoidCallback onDec, onInc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
          ),
          _miniButton(Icons.remove_rounded, enabled ? onDec : null),
          const SizedBox(width: 6),
          SizedBox(
            width: 50,
            child: Text(
              suffix.isNotEmpty ? '$value $suffix' : '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 6),
          _miniButton(Icons.add_rounded, enabled ? onInc : null),
        ],
      ),
    );
  }

  Widget _miniButton(IconData icon, VoidCallback? onPressed) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 14),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.08),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
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
  });

  final bool running;
  final VoidCallback onToggle, onReset;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      TextButton.icon(
        onPressed: onReset,
        icon: const Icon(Icons.replay_rounded, size: 18),
        label: const Text('Reset'),
      ),
      const SizedBox(width: 20),
      FilledButton.icon(
        onPressed: onToggle,
        icon: Icon(
          running ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 20,
        ),
        label: Text(
          running ? 'Pause' : 'Begin focus',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
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
  });

  final List<TaskItem> tasks;
  final ValueChanged<int> onToggle;
  final ValueChanged<int> onRemove;
  final ValueChanged<String> onAdd;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 50,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                  width: 1,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.1),
                    Colors.white.withValues(alpha: 0.02),
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
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
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
                            color: Colors.white.withValues(alpha: 0.4),
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
      ),
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
  });

  final AtmosphereType currentAtmosphere;
  final ValueChanged<AtmosphereType> onAtmosphereChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
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
