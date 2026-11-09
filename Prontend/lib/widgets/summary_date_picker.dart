import 'package:flutter/cupertino.dart';
import 'package:flutter/physics.dart';

/// Only permitted dates participate in any of the three wheels.
class SummaryDatePicker extends StatefulWidget {
  const SummaryDatePicker({
    super.key,
    required this.dates,
    required this.initialDate,
    required this.onChanged,
  });

  final List<DateTime> dates;
  final DateTime initialDate;
  final ValueChanged<DateTime> onChanged;

  @override
  State<SummaryDatePicker> createState() => _SummaryDatePickerState();
}

class _SummaryDatePickerState extends State<SummaryDatePicker> {
  late DateTime selected = widget.initialDate;

  void choose(Iterable<DateTime> candidates) {
    // Preserve the closest available month/day when another column changes.
    final target = candidates.reduce(
      (a, b) =>
          (a.month - selected.month).abs() * 32 +
                  (a.day - selected.day).abs() <=
              (b.month - selected.month).abs() * 32 +
                  (b.day - selected.day).abs()
          ? a
          : b,
    );
    setState(() => selected = target);
    widget.onChanged(target);
  }

  @override
  Widget build(BuildContext context) {
    final years = widget.dates.map((d) => d.year).toSet().toList()..sort();
    final yearDates = widget.dates
        .where((d) => d.year == selected.year)
        .toList();
    final months = yearDates.map((d) => d.month).toSet().toList()..sort();
    final monthDates = yearDates
        .where((d) => d.month == selected.month)
        .toList();
    final days = monthDates.map((d) => d.day).toSet().toList()..sort();
    return Row(
      children: [
        Expanded(
          child: _DateWheel(
            key: const ValueKey('year'),
            values: years,
            value: selected.year,
            suffix: '년',
            onChanged: (year) =>
                choose(widget.dates.where((d) => d.year == year)),
          ),
        ),
        Expanded(
          child: _DateWheel(
            key: ValueKey('month-${selected.year}'),
            values: months,
            value: selected.month,
            suffix: '월',
            onChanged: (month) =>
                choose(yearDates.where((d) => d.month == month)),
          ),
        ),
        Expanded(
          child: _DateWheel(
            key: ValueKey('day-${selected.year}-${selected.month}'),
            values: days,
            value: selected.day,
            suffix: '일',
            onChanged: (day) => choose(monthDates.where((d) => d.day == day)),
          ),
        ),
      ],
    );
  }
}

class _DateWheel extends StatefulWidget {
  const _DateWheel({
    super.key,
    required this.values,
    required this.value,
    required this.suffix,
    required this.onChanged,
  });
  final List<int> values;
  final int value;
  final String suffix;
  final ValueChanged<int> onChanged;

  @override
  State<_DateWheel> createState() => _DateWheelState();
}

class _DateWheelState extends State<_DateWheel> {
  late final controller = FixedExtentScrollController(
    initialItem: widget.values.indexOf(widget.value),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: ListWheelScrollView.useDelegate(
          controller: controller,
          physics: const _SlowWheelPhysics(parent: ClampingScrollPhysics()),
          itemExtent: 32,
          diameterRatio: 1.07,
          squeeze: 1.45,
          overAndUnderCenterOpacity: .447,
          useMagnifier: true,
          magnification: 1.05,
          onSelectedItemChanged: (index) =>
              widget.onChanged(widget.values[index]),
          childDelegate: ListWheelChildBuilderDelegate(
            childCount: widget.values.length,
            builder: (context, index) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => controller.animateToItem(
                index,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeInOut,
              ),
              child: Center(
                child: Text(
                  '${widget.values[index]}${widget.suffix}',
                  style: CupertinoTheme.of(
                    context,
                  ).textTheme.dateTimePickerTextStyle,
                ),
              ),
            ),
          ),
        ),
      ),
      const Center(
        child: IgnorePointer(
          child: SizedBox(
            height: 32 * 1.05,
            child: CupertinoPickerDefaultSelectionOverlay(),
          ),
        ),
      ),
    ],
  );
}

// Preserve the iOS appearance without CupertinoPicker's automatic tick sound.
class _SlowWheelPhysics extends FixedExtentScrollPhysics {
  const _SlowWheelPhysics({super.parent});

  @override
  _SlowWheelPhysics applyTo(ScrollPhysics? ancestor) =>
      _SlowWheelPhysics(parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      super.applyPhysicsToUserOffset(position, offset * .5);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => super.createBallisticSimulation(position, velocity * .5);
}
