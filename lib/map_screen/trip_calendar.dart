// Way2GoX TripCalendar v2 — wiederverwendbares Kalender-Widget
// Modi: Zeitraum (Range) | Nur Dauer (Stepper).
// v2: Stop-genaue Belegung mit Namen (Tooltip + dynamische Legende),
// "Naechste freie Luecke"-Chip, weiches Container-Fenster,
// Live-Konfliktstatus, Heute-Marker. TT.MM.JJJJ, Mo-Start.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class TripCalendarOccupancy {
  final DateTime start;
  final DateTime end;
  final Color color;
  final bool fixed;
  final String label;
  const TripCalendarOccupancy({
    required this.start,
    required this.end,
    required this.color,
    this.fixed = false,
    this.label = '',
  });
}

class TripCalendarResult {
  final DateTime? start;
  final DateTime? end;
  final int? days;
  final bool isFixed;
  final bool cleared;
  const TripCalendarResult({
    this.start,
    this.end,
    this.days,
    this.isFixed = false,
    this.cleared = false,
  });
}

// ── Farben (weißes Popup, klare Kontraste) ──────────────────
const _cInk       = Color(0xFF2C2416);
const _cInk2      = Color(0xFF6B7280);
const _cMuted     = Color(0xFF9CA3AF);
const _cDisabled  = Color(0xFFC7CBD1);
const _cBorder    = Color(0xFFE0E0E0);
const _cSoftBg    = Color(0xFFF3F4F6);
const _cTealInk   = Color(0xFF0B5A4E);
const _cToday     = Color(0xFFE8A838);
const _cTeal      = Color(0xFF3A9E8F);
const _cTealMid   = Color(0xFF9FD5CC);
const _cTealPale  = Color(0xFFE3F2EF);
const _cAmber     = Color(0xFFE8A838);
const _cAmberPale = Color(0xFFFAEEDA);
const _cAmberInk  = Color(0xFF8A5A0B);

String _de(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
String _deShort(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.';

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

Future<TripCalendarResult?> showTripCalendar({
  required BuildContext context,
  String title = 'Zeitraum wählen',
  String? subtitle,
  DateTime? minDate,
  DateTime? maxDate,
  DateTime? softMinDate,
  DateTime? softMaxDate,
  DateTime? initialStart,
  DateTime? initialEnd,
  int? initialDays,
  bool initialFixed = false,
  bool showLockToggle = true,
  bool allowDurationOnly = true,
  bool allowClear = true,
  List<TripCalendarOccupancy> occupancy = const [],
}) {
  return showDialog<TripCalendarResult>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _cBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: _TripCalendarBody(
          title: title,
          subtitle: subtitle,
          minDate: minDate != null ? _dateOnly(minDate) : null,
          maxDate: maxDate != null ? _dateOnly(maxDate) : null,
          softMinDate: softMinDate != null ? _dateOnly(softMinDate) : null,
          softMaxDate: softMaxDate != null ? _dateOnly(softMaxDate) : null,
          initialStart: initialStart != null ? _dateOnly(initialStart) : null,
          initialEnd: initialEnd != null ? _dateOnly(initialEnd) : null,
          initialDays: initialDays,
          initialFixed: initialFixed,
          showLockToggle: showLockToggle,
          allowDurationOnly: allowDurationOnly,
          allowClear: allowClear,
          occupancy: occupancy,
        ),
      ),
    ),
  );
}

class _TripCalendarBody extends StatefulWidget {
  final String title;
  final String? subtitle;
  final DateTime? minDate, maxDate, softMinDate, softMaxDate, initialStart, initialEnd;
  final int? initialDays;
  final bool initialFixed, showLockToggle, allowDurationOnly, allowClear;
  final List<TripCalendarOccupancy> occupancy;
  const _TripCalendarBody({
    required this.title,
    this.subtitle,
    this.minDate,
    this.maxDate,
    this.softMinDate,
    this.softMaxDate,
    this.initialStart,
    this.initialEnd,
    this.initialDays,
    required this.initialFixed,
    required this.showLockToggle,
    required this.allowDurationOnly,
    required this.allowClear,
    required this.occupancy,
  });
  @override
  State<_TripCalendarBody> createState() => _TripCalendarBodyState();
}

class _TripCalendarBodyState extends State<_TripCalendarBody> {
  late bool _durationMode;
  late DateTime _visibleMonth;
  DateTime? _selStart, _selEnd, _hover;
  late int _days;
  late bool _isFixed;
  late final DateTime _today;
  DateTime? _gapStart, _gapEnd;

  @override
  void initState() {
    super.initState();
    _today = _dateOnly(DateTime.now());
    _selStart = widget.initialStart;
    _selEnd = widget.initialEnd;
    _isFixed = widget.initialFixed;
    _days = widget.initialDays ??
        ((_selStart != null && _selEnd != null)
            ? _selEnd!.difference(_selStart!).inDays + 1
            : 3);
    if (_days < 1) _days = 1;
    _durationMode =
        widget.allowDurationOnly && _selStart == null && widget.initialDays != null;
    final anchor = _selStart ?? widget.softMinDate ?? widget.minDate ?? _today;
    _visibleMonth = DateTime(anchor.year, anchor.month, 1);
    _computeGap();
  }

  bool _outsideSoftWindow(DateTime d) {
    if (widget.softMinDate == null && widget.softMaxDate == null) return false;
    if (widget.softMinDate != null && d.isBefore(widget.softMinDate!)) return true;
    if (widget.softMaxDate != null && d.isAfter(widget.softMaxDate!)) return true;
    return false;
  }

  /// Erste zusammenhaengende freie Luecke im gueltigen Bereich (max. 30 Tage).
  void _computeGap() {
    _gapStart = null; _gapEnd = null;
    if (widget.occupancy.isEmpty) return;
    final start0 = widget.softMinDate ?? widget.minDate ?? _today;
    final hardEnd = widget.softMaxDate ?? widget.maxDate ??
        start0.add(const Duration(days: 365));
    DateTime d = (start0.isBefore(_today) && !_outOfBounds(_today)) ? _today : start0;
    while (!d.isAfter(hardEnd)) {
      if (_outOfBounds(d)) { d = d.add(const Duration(days: 1)); continue; }
      if (_occFor(d) == null) {
        DateTime e = d;
        while (true) {
          final next = e.add(const Duration(days: 1));
          if (next.isAfter(hardEnd) || _outOfBounds(next) || _occFor(next) != null) break;
          if (next.difference(d).inDays >= 29) break;
          e = next;
        }
        _gapStart = d; _gapEnd = e;
        return;
      }
      d = d.add(const Duration(days: 1));
    }
  }

  /// Ueberschneidungen der aktuellen Auswahl mit Belegungen.
  List<String> _conflicts() {
    if (_selStart == null || _selEnd == null) return [];
    final result = <String>[];
    for (final o in widget.occupancy) {
      final os = _dateOnly(o.start), oe = _dateOnly(o.end);
      final s = _selStart!.isAfter(os) ? _selStart! : os;
      final e = _selEnd!.isBefore(oe) ? _selEnd! : oe;
      final overlap = e.difference(s).inDays + 1;
      if (overlap > 0) {
        final tag = overlap == 1 ? '1 Tag' : '$overlap Tage';
        result.add(o.fixed ? '${o.label} (fixiert, $tag)' : '${o.label} ($tag)');
      }
    }
    return result;
  }

  bool _outOfBounds(DateTime d) {
    if (widget.minDate != null && d.isBefore(widget.minDate!)) return true;
    if (widget.maxDate != null && d.isAfter(widget.maxDate!)) return true;
    return false;
  }

  TripCalendarOccupancy? _occFor(DateTime d) {
    for (final o in widget.occupancy) {
      if (!d.isBefore(_dateOnly(o.start)) && !d.isAfter(_dateOnly(o.end))) return o;
    }
    return null;
  }

  void _tapDay(DateTime d) {
    setState(() {
      if (_selStart == null || (_selStart != null && _selEnd != null)) {
        _selStart = d; _selEnd = null;
      } else if (d.isBefore(_selStart!)) {
        _selStart = d;
      } else {
        _selEnd = d;
      }
      if (_selStart != null && _selEnd != null) {
        _days = _selEnd!.difference(_selStart!).inDays + 1;
      }
    });
  }

  bool _canGoPrev() {
    if (widget.minDate == null) return true;
    final prev = DateTime(_visibleMonth.year, _visibleMonth.month - 1, 1);
    final lastOfPrev = DateTime(prev.year, prev.month + 1, 0);
    return !lastOfPrev.isBefore(widget.minDate!);
  }

  bool _canGoNext() {
    if (widget.maxDate == null) return true;
    final next = DateTime(_visibleMonth.year, _visibleMonth.month + 1, 1);
    return !next.isAfter(widget.maxDate!);
  }

  static const _monthNames = ['Januar','Februar','März','April','Mai','Juni',
    'Juli','August','September','Oktober','November','Dezember'];

  @override
  Widget build(BuildContext context) {
    final conflicts = (!_durationMode && _selEnd != null && widget.occupancy.isNotEmpty)
        ? _conflicts() : null;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // ── Header ─────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title, style: GoogleFonts.nunito(
                fontSize: 15, fontWeight: FontWeight.w700, color: _cInk)),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 2),
              Text(widget.subtitle!, style: GoogleFonts.nunito(fontSize: 12, color: _cMuted)),
            ],
          ])),
          IconButton(
            onPressed: () => Navigator.pop(context, null),
            icon: const Icon(Icons.close, size: 18, color: _cInk2),
            padding: EdgeInsets.zero, constraints: const BoxConstraints(),
          ),
        ]),
      ),

      // ── Tabs: Zeitraum | Nur Dauer ─────────────────────────
      if (widget.allowDurationOnly)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(children: [
              _tab('Zeitraum', !_durationMode, () => setState(() => _durationMode = false)),
              _tab('Nur Dauer', _durationMode, () => setState(() => _durationMode = true)),
            ]),
          ),
        ),

      // ── Freie-Luecke-Chip ──────────────────────────────────
      if (!_durationMode && _gapStart != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _cTealPale,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              const Icon(Icons.auto_awesome, size: 15, color: _cTealInk),
              const SizedBox(width: 8),
              Expanded(child: Text(
                'Nächste freie Lücke: ${_deShort(_gapStart!)} – ${_deShort(_gapEnd!)} · ${_gapEnd!.difference(_gapStart!).inDays + 1} Tage',
                style: GoogleFonts.nunito(fontSize: 12.5, color: _cTealInk))),
              InkWell(
                onTap: () => setState(() {
                  _selStart = _gapStart; _selEnd = _gapEnd;
                  _days = _gapEnd!.difference(_gapStart!).inDays + 1;
                  _visibleMonth = DateTime(_gapStart!.year, _gapStart!.month, 1);
                }),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: _cTeal, borderRadius: BorderRadius.circular(20)),
                  child: Text('Übernehmen', style: GoogleFonts.nunito(
                      fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ]),
          ),
        ),

      // ── Body ───────────────────────────────────────────────
      if (_durationMode) _buildDurationStepper() else _buildCalendar(),

      // ── Dynamische Legende (echte Stop-Namen) ──────────────
      if (!_durationMode &&
          (widget.occupancy.isNotEmpty || widget.softMinDate != null || widget.softMaxDate != null))
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _cBorder, width: 0.5))),
          child: Wrap(spacing: 11, runSpacing: 4, children: _legendItems()),
        ),

      // ── Footer ─────────────────────────────────────────────
      Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: _cBorder, width: 0.5))),
        child: Column(children: [
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_summaryText(), style: GoogleFonts.nunito(
                  fontSize: 13, fontWeight: FontWeight.w700, color: _cInk)),
              if (conflicts != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: conflicts.isEmpty
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.check_circle_outline, size: 12, color: _cTealInk),
                        const SizedBox(width: 4),
                        Text('Keine Überschneidung',
                            style: GoogleFonts.nunito(fontSize: 11.5, color: _cTealInk)),
                      ])
                    : Row(mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Icon(Icons.warning_amber_rounded, size: 12, color: _cAmberInk),
                        const SizedBox(width: 4),
                        Flexible(child: Text(
                            'Überschneidet ${conflicts.take(2).join(', ')}${conflicts.length > 2 ? ' +${conflicts.length - 2} weitere' : ''}',
                            style: GoogleFonts.nunito(fontSize: 11.5, color: _cAmberInk))),
                      ]),
                ),
              if (widget.showLockToggle && !_durationMode && _selStart != null)
                InkWell(
                  onTap: () => setState(() => _isFixed = !_isFixed),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_isFixed ? Icons.lock : Icons.lock_open,
                          size: 12, color: _isFixed ? _cAmberInk : _cMuted),
                      const SizedBox(width: 4),
                      Text(_isFixed ? 'Fixiert — KI verschiebt nicht'
                                    : 'Flexibel — KI darf verschieben',
                          style: GoogleFonts.nunito(fontSize: 11.5,
                              color: _isFixed ? _cAmberInk : _cInk2)),
                      const SizedBox(width: 4),
                      SizedBox(height: 22, child: FittedBox(child: Switch(
                        value: _isFixed, activeColor: _cAmber,
                        onChanged: (v) => setState(() => _isFixed = v),
                      ))),
                    ]),
                  ),
                ),
            ])),
            if (widget.allowClear)
              TextButton(
                onPressed: () => Navigator.pop(context,
                    const TripCalendarResult(cleared: true)),
                child: Text('Löschen',
                    style: GoogleFonts.nunito(fontSize: 12.5, color: _cInk2)),
              ),
            const SizedBox(width: 4),
            ElevatedButton(
              onPressed: _canConfirm() ? _confirm : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _cTeal, foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFD1D5DB),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              ),
              child: Text('Übernehmen', style: GoogleFonts.nunito(
                  fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
          ]),
        ]),
      ),
    ]);
  }

  List<Widget> _legendItems() {
    final items = <Widget>[
      _legend(const Icon(Icons.square_rounded, size: 10, color: _cTeal), 'Auswahl'),
    ];
    final seen = <String>{};
    int shown = 0;
    for (final o in widget.occupancy) {
      final key = o.label.isEmpty ? '${o.color.value}' : o.label;
      if (!seen.add(key)) continue;
      if (shown >= 4) continue;
      shown++;
      if (o.fixed) {
        items.add(_legend(const Icon(Icons.lock, size: 11, color: _cAmberInk),
            '${o.label} (fix)'));
      } else {
        items.add(_legend(Container(width: 9, height: 9,
            decoration: BoxDecoration(color: o.color,
                borderRadius: BorderRadius.circular(3))), o.label));
      }
    }
    final more = seen.length - shown;
    if (more > 0) {
      items.add(Text('+$more weitere',
          style: GoogleFonts.nunito(fontSize: 11, color: _cMuted)));
    }
    if (widget.softMinDate != null || widget.softMaxDate != null) {
      items.add(_legend(Container(width: 9, height: 9,
          decoration: BoxDecoration(color: _cSoftBg,
              border: Border.all(color: _cBorder, width: 0.5),
              borderRadius: BorderRadius.circular(3))), 'Außerhalb Container'));
    }
    return items;
  }

  Widget _tab(String label, bool active, VoidCallback onTap) => Expanded(
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: active ? Border.all(color: _cBorder, width: 0.5) : null,
        ),
        child: Text(label, textAlign: TextAlign.center,
            style: GoogleFonts.nunito(fontSize: 12.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? _cInk : _cInk2)),
      ),
    ),
  );

  Widget _legend(Widget marker, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        marker, const SizedBox(width: 4),
        Text(label, style: GoogleFonts.nunito(fontSize: 11, color: _cInk2)),
      ]);

  String _summaryText() {
    if (_durationMode) return '$_days Tage · ohne Datum';
    if (_selStart != null && _selEnd != null) {
      return '${_de(_selStart!)} – ${_de(_selEnd!)} · $_days Tage';
    }
    if (_selStart != null) return '${_de(_selStart!)} — Enddatum wählen';
    return 'Startdatum wählen';
  }

  bool _canConfirm() {
    if (_durationMode) return _days >= 1;
    return _selStart != null;
  }

  void _confirm() {
    if (_durationMode) {
      Navigator.pop(context, TripCalendarResult(days: _days));
      return;
    }
    final start = _selStart!;
    final end = _selEnd ?? _selStart!;
    Navigator.pop(context, TripCalendarResult(
      start: start, end: end,
      days: end.difference(start).inDays + 1,
      isFixed: widget.showLockToggle ? _isFixed : false,
    ));
  }

  // ── Nur-Dauer-Stepper ───────────────────────────────────────
  Widget _buildDurationStepper() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
    child: Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _stepBtn(Icons.remove, _days > 1 ? () => setState(() => _days--) : null),
        Container(
          width: 90, alignment: Alignment.center,
          child: Column(children: [
            Text('$_days', style: GoogleFonts.nunito(
                fontSize: 32, fontWeight: FontWeight.w800, color: _cInk)),
            Text(_days == 1 ? 'Tag' : 'Tage',
                style: GoogleFonts.nunito(fontSize: 12, color: _cInk2)),
          ]),
        ),
        _stepBtn(Icons.add, _days < 99 ? () => setState(() => _days++) : null),
      ]),
      const SizedBox(height: 10),
      Text('Die KI platziert diese Tage automatisch in der Route.',
          style: GoogleFonts.nunito(fontSize: 12, color: _cMuted),
          textAlign: TextAlign.center),
    ]),
  );

  Widget _stepBtn(IconData icon, VoidCallback? onTap) => InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(20),
    child: Container(
      width: 38, height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: onTap == null ? _cBorder : _cTeal, width: 1.2),
      ),
      child: Icon(icon, size: 18, color: onTap == null ? _cDisabled : _cTeal),
    ),
  );

  // ── Kalender ────────────────────────────────────────────────
  Widget _buildCalendar() {
    final year = _visibleMonth.year, month = _visibleMonth.month;
    final firstDay = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final leading = firstDay.weekday - 1; // Mo = 0
    final cells = <Widget>[];
    for (int i = 0; i < leading; i++) cells.add(const SizedBox());
    for (int d = 1; d <= daysInMonth; d++) {
      cells.add(_dayCell(DateTime(year, month, d)));
    }

    return Column(children: [
      // Monats-Navigation
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _navBtn(Icons.chevron_left, _canGoPrev() ? () => setState(() =>
              _visibleMonth = DateTime(year, month - 1, 1)) : null),
          Text('${_monthNames[month - 1]} $year', style: GoogleFonts.nunito(
              fontSize: 13.5, fontWeight: FontWeight.w700, color: _cInk)),
          _navBtn(Icons.chevron_right, _canGoNext() ? () => setState(() =>
              _visibleMonth = DateTime(year, month + 1, 1)) : null),
        ]),
      ),
      // Wochentage
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: ['Mo','Di','Mi','Do','Fr','Sa','So'].map((w) =>
          Expanded(child: Text(w, textAlign: TextAlign.center,
              style: GoogleFonts.nunito(fontSize: 11, color: _cMuted)))).toList()),
      ),
      const SizedBox(height: 2),
      // Grid
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: GridView.count(
          crossAxisCount: 7, shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 2, crossAxisSpacing: 2, childAspectRatio: 1.15,
          children: cells,
        ),
      ),
    ]);
  }

  Widget _navBtn(IconData icon, VoidCallback? onTap) => InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(6),
    child: Padding(padding: const EdgeInsets.all(4),
      child: Icon(icon, size: 18, color: onTap == null ? _cDisabled : _cInk2)),
  );

  Widget _dayCell(DateTime day) {
    final disabled = _outOfBounds(day);
    final occ = disabled ? null : _occFor(day);
    final softOutside = !disabled && _outsideSoftWindow(day);
    final isToday = day == _today;
    final effEnd = _selEnd ??
        ((_hover != null && _selStart != null && _hover!.isAfter(_selStart!)) ? _hover : null);
    final inSel = !disabled && _selStart != null && effEnd != null &&
        !day.isBefore(_selStart!) && !day.isAfter(effEnd);
    final isCommitted = _selEnd != null;
    final isStart = _selStart != null && day == _selStart;
    final isHoverCursor = _hover != null && day == _hover && _selStart != null && _selEnd == null;

    Color? bg; Color textColor = _cInk;
    Widget? bar; Widget? lockIcon;
    BoxBorder? border; FontWeight weight = FontWeight.w500;

    if (disabled) {
      textColor = _cDisabled;
    } else if (inSel || isStart) {
      if (isCommitted || isStart) {
        bg = _cTeal; textColor = Colors.white; weight = FontWeight.w700;
      } else {
        bg = _cTealMid; textColor = _cInk;
      }
      if (isHoverCursor) {
        bg = Colors.white;
        border = Border.all(color: _cTeal, width: 1.4);
        textColor = _cInk;
      }
    } else if (isHoverCursor) {
      bg = Colors.white;
      border = Border.all(color: _cTeal, width: 1.4);
    } else if (occ != null) {
      if (occ.fixed) {
        bg = _cAmberPale; textColor = _cAmberInk;
        lockIcon = const Icon(Icons.lock, size: 8, color: _cAmberInk);
        bar = _occBar(_cAmber);
      } else {
        bg = occ.color.withOpacity(0.13);
        bar = _occBar(occ.color);
      }
    } else if (softOutside) {
      bg = _cSoftBg; textColor = _cInk2;
    }

    Widget cell = Container(
      decoration: BoxDecoration(
        color: bg, border: border,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Row(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('${day.day}', style: GoogleFonts.nunito(
              fontSize: 12.5, fontWeight: weight, color: textColor,
              decoration: disabled ? TextDecoration.lineThrough : null,
            )),
            if (lockIcon != null) ...[const SizedBox(width: 2), lockIcon],
          ]),
        SizedBox(height: 4, child: bar ?? (isToday && !disabled
            ? Center(child: Container(width: 4, height: 4,
                decoration: const BoxDecoration(
                    color: _cToday, shape: BoxShape.circle)))
            : const SizedBox())),
      ]),
    );

    if (occ != null) {
      cell = Tooltip(
        message: '${occ.label.isEmpty ? 'Belegt' : occ.label} · '
            '${_deShort(_dateOnly(occ.start))} – ${_deShort(_dateOnly(occ.end))}'
            '${occ.fixed ? ' · fixiert' : ' · belegt'}',
        waitDuration: const Duration(milliseconds: 250),
        textStyle: GoogleFonts.nunito(fontSize: 11.5, color: Colors.white),
        decoration: BoxDecoration(
          color: const Color(0xFF1F2937),
          borderRadius: BorderRadius.circular(6),
        ),
        child: cell,
      );
    }

    return MouseRegion(
      onEnter: disabled ? null : (_) => setState(() => _hover = day),
      onExit: (_) { if (_hover == day) setState(() => _hover = null); },
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: disabled ? null : () => _tapDay(day),
        child: cell,
      ),
    );
  }

  Widget _occBar(Color color) => Center(child: Container(
    width: 18, height: 3,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
  ));
}
