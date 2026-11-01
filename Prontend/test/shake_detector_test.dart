import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/services/shake_detector.dart';

Duration _ms(int ms) => Duration(milliseconds: ms);

void main() {
  test('방향이 바뀌는 큰 흔들림 3번이면 인정', () {
    final d = ShakeDetector();
    expect(d.add(20, 0, 0, _ms(0)), isFalse);
    expect(d.add(-20, 0, 0, _ms(200)), isFalse);
    expect(d.add(20, 0, 0, _ms(400)), isTrue);
  });

  test('한 번 크게 튀는 건 무시(같은 휘두름의 연속 표본 포함)', () {
    final d = ShakeDetector();
    for (var t = 0; t < 100; t += 20) {
      expect(d.add(25, 0, 0, _ms(t)), isFalse);
    }
  });

  test('기준보다 약한 움직임은 무시', () {
    final d = ShakeDetector();
    for (var i = 0; i < 10; i++) {
      expect(d.add(i.isEven ? 8 : -8, 0, 0, _ms(i * 150)), isFalse);
    }
  });

  test('세게 흔들어 한 방향 표본이 길게 이어져도 놓치지 않음', () {
    final d = ShakeDetector();
    var fired = false;
    // 휘두를 때마다 같은 방향 표본이 200ms 동안 20ms 간격으로 이어짐
    for (var swing = 0; swing < 3 && !fired; swing++) {
      for (var t = 0; t < 200; t += 20) {
        fired |= d.add(swing.isEven ? 40 : -40, 0, 0, _ms(swing * 250 + t));
      }
    }
    expect(fired, isTrue);
  });

  test('책상에 세게 놓아 0.1초 안에 위아래로 튀는 건 무시', () {
    final d = ShakeDetector();
    // 11/2 노트9 실측 - 놓는 순간 z축이 +57/-12/+46/-12/+26으로 튐
    expect(d.add(0, 0, 55, _ms(0)), isFalse);
    expect(d.add(0, 0, -12, _ms(1)), isFalse);
    expect(d.add(0, 0, 45, _ms(17)), isFalse);
    expect(d.add(0, 0, 32, _ms(117)), isFalse);
    expect(d.add(0, 0, -12, _ms(136)), isFalse);
    expect(d.add(0, 0, 26, _ms(208)), isFalse);
  });

  test('같은 방향으로만 툭툭 치면 무시', () {
    final d = ShakeDetector();
    expect(d.add(20, 0, 0, _ms(0)), isFalse);
    expect(d.add(20, 0, 0, _ms(200)), isFalse);
    expect(d.add(20, 0, 0, _ms(400)), isFalse);
  });

  test('0.8초 안에 다 모여야 인정', () {
    final d = ShakeDetector();
    expect(d.add(20, 0, 0, _ms(0)), isFalse);
    expect(d.add(-20, 0, 0, _ms(500)), isFalse);
    expect(d.add(20, 0, 0, _ms(1000)), isFalse);
  });

  test('인정 뒤 2초는 다시 인정 안 함', () {
    final d = ShakeDetector();
    d.add(20, 0, 0, _ms(0));
    d.add(-20, 0, 0, _ms(200));
    expect(d.add(20, 0, 0, _ms(400)), isTrue);
    expect(d.add(-20, 0, 0, _ms(600)), isFalse);
    expect(d.add(20, 0, 0, _ms(800)), isFalse);
    expect(d.add(-20, 0, 0, _ms(1000)), isFalse);
    d.add(20, 0, 0, _ms(2500));
    d.add(-20, 0, 0, _ms(2700));
    expect(d.add(20, 0, 0, _ms(2900)), isTrue);
  });
}
