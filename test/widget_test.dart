import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timeler/main.dart';

void main() {
  testWidgets('shows the Timeler timer and controls', (tester) async {
    await tester.pumpWidget(const Timeler());
    expect(find.text('TIMELER'), findsOneWidget);
    expect(find.text('30:00'), findsOneWidget);
    expect(find.text('Begin focus'), findsOneWidget);
  });

  testWidgets('opens settings and accesses focus progress dialog', (tester) async {
    await tester.pumpWidget(const Timeler());

    // Tap settings button (tooltip: 'Settings')
    final settingsButton = find.byTooltip('Settings');
    expect(settingsButton, findsOneWidget);
    await tester.tap(settingsButton);
    await tester.pump(const Duration(milliseconds: 300));

    // Check Settings dialog contents
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('ATMOSPHERE'), findsOneWidget);
    expect(find.text('STATISTICS & ACTIVITY'), findsOneWidget);
    expect(find.text('Focus Progress & Analytics'), findsOneWidget);

    // Scroll tile into view if needed and tap Focus Progress & Analytics tile
    final progressTile = find.text('Focus Progress & Analytics');
    await tester.ensureVisible(progressTile);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(progressTile);
    await tester.pump(const Duration(milliseconds: 300));

    // Verify Focus Progress dialog is shown
    expect(find.text('Focus Progress'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('7 Days'), findsOneWidget);
    expect(find.text('This Month'), findsOneWidget);
    expect(find.text('All Time'), findsOneWidget);
    expect(find.text('FOCUS TIME'), findsOneWidget);
    expect(find.text('SESSIONS'), findsOneWidget);

    // Switch to 7 Days tab
    await tester.tap(find.text('7 Days'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('LAST 7 DAYS ACTIVITY'), findsOneWidget);

    // Switch to All Time tab
    await tester.tap(find.text('All Time'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('FOCUS DISTRIBUTION'), findsOneWidget);
  });

  testWidgets('opens custom timer dialog with wheel UI and sets timer', (tester) async {
    await tester.pumpWidget(const Timeler());

    // Tap Custom chip
    final customChip = find.text('Custom');
    expect(customChip, findsOneWidget);
    await tester.ensureVisible(customChip);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(customChip);
    await tester.pump(const Duration(milliseconds: 300));

    // Verify Custom Timer dialog is displayed
    expect(find.text('Custom Timer'), findsOneWidget);
    expect(find.text('How long do you want to focus for?'), findsOneWidget);
    expect(find.text('Set Timer'), findsOneWidget);

    // Tap Set Timer
    await tester.tap(find.text('Set Timer'));
    await tester.pump(const Duration(milliseconds: 300));

    // Verify dialog closed and clock shows 30:00
    expect(find.text('Custom Timer'), findsNothing);
    expect(find.text('30:00'), findsOneWidget);
  });

  testWidgets('switches to Pomodoro mode, displays 3 premium options, and supports step-by-step Continue flow', (tester) async {
    await tester.pumpWidget(const Timeler());

    // Switch to Pomodoro mode
    final pomodoroTab = find.text('Pomodoro');
    expect(pomodoroTab, findsOneWidget);
    await tester.tap(pomodoroTab);
    await tester.pump(const Duration(milliseconds: 300));

    // Verify Pomodoro clock shows initial 25:00
    expect(find.text('25:00'), findsOneWidget);

    // Verify 3 distinct options are rendered in settings panel
    expect(find.text('Pomodoro intervals'), findsOneWidget);
    expect(find.text('Round 1 of 4'), findsOneWidget);
    expect(find.text('FOCUS'), findsOneWidget);
    expect(find.text('SHORT BREAK'), findsOneWidget);
    expect(find.text('LONG BREAK'), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('Rounds per cycle'), findsOneWidget);

    // Verify dial phase pills are shown
    expect(find.text('Focus 25m'), findsOneWidget);
    expect(find.text('Break 5m'), findsOneWidget);
    expect(find.text('Long Break 15m'), findsOneWidget);

    // Tap Break pill on dial to preview break
    await tester.tap(find.text('Break 5m'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('05:00'), findsOneWidget);

    // Tap Focus pill to return to focus
    await tester.tap(find.text('Focus 25m'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('25:00'), findsOneWidget);

    // Tap Begin focus to start
    final beginButton = find.text('Begin focus');
    expect(beginButton, findsOneWidget);
    await tester.tap(beginButton);
    await tester.pump(const Duration(milliseconds: 200));

    // Verify running button is now Pause
    expect(find.text('Pause'), findsOneWidget);

    // Tap Reset to cancel periodic timer cleanly
    await tester.tap(find.text('Reset'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Begin focus'), findsOneWidget);
  });

  testWidgets('renders properly on mobile phone screen dimensions (portrait viewport)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const Timeler());
    expect(find.text('TIMELER'), findsOneWidget);
    expect(find.text('30:00'), findsOneWidget);
    expect(find.text('Begin focus'), findsOneWidget);

    // Verify presets are reachable in scrollable column
    final customChip = find.text('Custom');
    await tester.ensureVisible(customChip);
    await tester.pump(const Duration(milliseconds: 100));
    expect(customChip, findsOneWidget);

    final fifteenMinChip = find.text('15 min');
    await tester.ensureVisible(fifteenMinChip);
    await tester.pump(const Duration(milliseconds: 100));
    expect(fifteenMinChip, findsOneWidget);

    // Verify interaction on mobile
    await tester.tap(fifteenMinChip);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('15:00'), findsOneWidget);
  });

  testWidgets('auto-collapses setup panel on session start, stays collapsed when paused, and restores on reset', (tester) async {
    await tester.pumpWidget(const Timeler());

    // Initially setup panel is fully expanded
    expect(find.text('Set your horizon'), findsOneWidget);
    expect(find.text('Begin focus'), findsOneWidget);
    expect(find.text('LOCKED'), findsNothing);

    // Tap Begin focus
    await tester.tap(find.text('Begin focus'));
    // Pump through the 700ms animation
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 400));

    // Panel is now collapsed to the locked status card
    expect(find.text('Set your horizon'), findsNothing);
    expect(find.text('LOCKED'), findsWidgets);
    expect(find.text('Setup controls auto-collapsed · Tap Reset to adjust'), findsWidgets);
    expect(find.text('Pause'), findsOneWidget);

    // Tap Pause mid-session (e.g. at 29:59 or 00:01)
    await tester.tap(find.text('Pause'));
    await tester.pump(const Duration(milliseconds: 200));

    // Even when paused, panel must stay collapsed and locked to prevent accidental resets
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Set your horizon'), findsNothing);
    expect(find.text('LOCKED'), findsWidgets);

    // Tap Reset to cancel session
    await tester.tap(find.text('Reset'));
    // Pump through reverse animation
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 400));

    // Setup controls are re-enabled and restored
    expect(find.text('Begin focus'), findsOneWidget);
    expect(find.text('Set your horizon'), findsOneWidget);
    expect(find.text('LOCKED'), findsNothing);
  });

  testWidgets('mobile auto-collapses setup panel and disables session name edit during session', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const Timeler());

    expect(find.text('Begin focus'), findsOneWidget);
    expect(find.text('Set your horizon'), findsOneWidget);

    // Tap Begin focus
    await tester.tap(find.text('Begin focus'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // In mobile, locked card is displayed under the dial and controls
    expect(find.text('LOCKED'), findsOneWidget);
    expect(find.text('Setup controls auto-collapsed · Tap Reset to adjust'), findsOneWidget);
    expect(find.text('Set your horizon'), findsNothing);

    // Reset cleanly
    await tester.tap(find.text('Reset'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Begin focus'), findsOneWidget);
    expect(find.text('Set your horizon'), findsOneWidget);
    expect(find.text('LOCKED'), findsNothing);
  });
}

