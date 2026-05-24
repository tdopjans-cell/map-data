import '../database.dart';

class RuleSetsTable extends SupabaseTable<RuleSetsRow> {
  @override
  String get tableName => 'rule_sets';

  @override
  RuleSetsRow createRow(Map<String, dynamic> data) => RuleSetsRow(data);
}

class RuleSetsRow extends SupabaseDataRow {
  RuleSetsRow(Map<String, dynamic> data) : super(data);

  @override
  SupabaseTable get table => RuleSetsTable();

  String? get id => getField<String>('id');
  set id(String? value) => setField<String>('id', value);

  String get tripId => getField<String>('trip_id')!;
  set tripId(String value) => setField<String>('trip_id', value);

  String? get routeVersionId => getField<String>('route_version_id');
  set routeVersionId(String? value) =>
      setField<String>('route_version_id', value);

  String get ownerId => getField<String>('owner_id')!;
  set ownerId(String value) => setField<String>('owner_id', value);

  String? get scopeType => getField<String>('scope_type');
  set scopeType(String? value) => setField<String>('scope_type', value);

  String? get parentStopId => getField<String>('parent_stop_id');
  set parentStopId(String? value) => setField<String>('parent_stop_id', value);

  String? get status => getField<String>('status');
  set status(String? value) => setField<String>('status', value);

  DateTime? get createdAt => getField<DateTime>('created_at');
  set createdAt(DateTime? value) => setField<DateTime>('created_at', value);
}
