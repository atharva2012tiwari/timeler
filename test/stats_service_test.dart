import 'package:flutter_test/flutter_test.dart';
import 'package:timeler/main.dart';

void main() {
  group('FocusSession JSON Serialization', () {
    test('serializes and deserializes accurately', () {
      final now = DateTime(2026, 9, 18, 14, 30);
      final session = FocusSession(
        id: 'session-123',
        timestamp: now,
        durationMinutes: 25,
        mode: 'pomodoro',
        sessionName: 'Design Work',
      );

      final json = session.toJson();
      expect(json['id'], 'session-123');
      expect(json['timestamp'], now.toIso8601String());
      expect(json['durationMinutes'], 25);
      expect(json['mode'], 'pomodoro');
      expect(json['sessionName'], 'Design Work');

      final reconstructed = FocusSession.fromJson(json);
      expect(reconstructed.id, 'session-123');
      expect(reconstructed.timestamp, now);
      expect(reconstructed.durationMinutes, 25);
      expect(reconstructed.mode, 'pomodoro');
      expect(reconstructed.sessionName, 'Design Work');
    });

    test('handles nullable sessionName', () {
      final session = FocusSession(
        id: 'session-456',
        timestamp: DateTime.now(),
        durationMinutes: 30,
        mode: 'timer',
      );

      final json = session.toJson();
      expect(json.containsKey('sessionName'), isFalse);

      final reconstructed = FocusSession.fromJson(json);
      expect(reconstructed.sessionName, isNull);
    });
  });

  group('StatsService Aggregations and Filters', () {
    setUp(() {
      StatsService.instance.clearForTesting();
    });

    test('formatDuration formats minutes and hours properly', () {
      expect(StatsService.formatDuration(0), '0m');
      expect(StatsService.formatDuration(25), '25m');
      expect(StatsService.formatDuration(60), '1h');
      expect(StatsService.formatDuration(75), '1h 15m');
      expect(StatsService.formatDuration(130), '2h 10m');
    });

    test('filters sessions by today, week, month, and allTime', () {
      final now = DateTime.now();
      final todaySession = FocusSession(
        id: '1',
        timestamp: now,
        durationMinutes: 30,
        mode: 'timer',
      );
      final threeDaysAgoSession = FocusSession(
        id: '2',
        timestamp: now.subtract(const Duration(days: 3)),
        durationMinutes: 45,
        mode: 'pomodoro',
      );
      final tenDaysAgoSession = FocusSession(
        id: '3',
        timestamp: now.subtract(const Duration(days: 10)),
        durationMinutes: 20,
        mode: 'timer',
      );

      StatsService.instance.setSessionsForTesting([
        todaySession,
        threeDaysAgoSession,
        tenDaysAgoSession,
      ]);

      final todayList =
          StatsService.instance.getSessionsForPeriod(ProgressPeriod.today);
      expect(todayList.length, 1);
      expect(todayList.first.id, '1');

      final weekList =
          StatsService.instance.getSessionsForPeriod(ProgressPeriod.week);
      expect(weekList.length, 2);
      expect(weekList.map((s) => s.id), containsAll(['1', '2']));

      final allList =
          StatsService.instance.getSessionsForPeriod(ProgressPeriod.allTime);
      expect(allList.length, 3);

      expect(
        StatsService.instance.getTotalMinutes(todayList),
        30,
      );
      expect(
        StatsService.instance.getTotalMinutes(allList),
        95,
      );
    });

    test('calculates streak correctly', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 10);
      final yesterday = today.subtract(const Duration(days: 1));
      final twoDaysAgo = today.subtract(const Duration(days: 2));

      // 3 consecutive days: today, yesterday, 2 days ago -> streak = 3
      StatsService.instance.setSessionsForTesting([
        FocusSession(
            id: '1', timestamp: today, durationMinutes: 25, mode: 'timer'),
        FocusSession(
            id: '2', timestamp: yesterday, durationMinutes: 25, mode: 'timer'),
        FocusSession(
            id: '3', timestamp: twoDaysAgo, durationMinutes: 25, mode: 'timer'),
      ]);

      expect(StatsService.instance.calculateStreak(), 3);

      // Missed yesterday -> streak = 1 (just today)
      final fourDaysAgo = today.subtract(const Duration(days: 4));
      StatsService.instance.setSessionsForTesting([
        FocusSession(
            id: '1', timestamp: today, durationMinutes: 25, mode: 'timer'),
        FocusSession(
            id: '4',
            timestamp: fourDaysAgo,
            durationMinutes: 25,
            mode: 'timer'),
      ]);

      expect(StatsService.instance.calculateStreak(), 1);
    });
  });
}
