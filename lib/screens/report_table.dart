import 'package:flutter/material.dart';

/// Category | new | already there | failed
class ReportTable extends StatelessWidget {
  final List<(String, int, int, int)> rows;
  const ReportTable({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final head = Theme.of(context).textTheme.labelMedium;
    Widget cell(String s, {TextStyle? style, bool end = true}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(s, style: style, textAlign: end ? TextAlign.end : TextAlign.start),
        );
    return Table(
      columnWidths: const {0: FlexColumnWidth(2.2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1.3), 3: FlexColumnWidth(1)},
      children: [
        TableRow(children: [
          cell('', end: false),
          cell('Copied', style: head),
          cell('Already there', style: head),
          cell('Failed', style: head),
        ]),
        for (final r in rows)
          TableRow(children: [
            cell(r.$1, end: false),
            cell('${r.$2}'),
            cell('${r.$3}'),
            cell('${r.$4}', style: r.$4 > 0 ? const TextStyle(color: Colors.red) : null),
          ]),
      ],
    );
  }
}
