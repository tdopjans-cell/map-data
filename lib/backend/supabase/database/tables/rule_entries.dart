import '../database.dart';

class RuleEntriesTable extends SupabaseTable<RuleEntriesRow> {
  @override
  String get tableName => 'rule_entries';

  @override
  RuleEntriesRow createRow(Map<String, dynamic> data) => RuleEntriesRow(data);
}

class RuleEntriesRow extends SupabaseDataRow {
  RuleEntriesRow(Map<String, dynamic> data) : super(data);

  @override
  SupabaseTable get table => RuleEntriesTable();

  String? get id => getField<String>('id');
  set id(String? value) => setField<String>('id', value);

  String get ruleSetId => getField<String>('rule_set_id')!;
  set ruleSetId(String value) => setField<String>('rule_set_id', value);

  String get tripId => getField<String>('trip_id')!;
  set tripId(String value) => setField<String>('trip_id', value);

  String get ownerId => getField<String>('owner_id')!;
  set ownerId(String value) => setField<String>('owner_id', value);

  String? get placeName => getField<String>('place_name');
  set placeName(String? value) => setField<String>('place_name', value);

  String? get placeLevel => getField<String>('place_level');
  set placeLevel(String? value) => setField<String>('place_level', value);

  String? get placeIdGoogle => getField<String>('place_id_google');
  set placeIdGoogle(String? value) =>
      setField<String>('place_id_google', value);

  String? get placeIdNe => getField<String>('place_id_ne');
  set placeIdNe(String? value) => setField<String>('place_id_ne', value);

  String? get placeIdOsm => getField<String>('place_id_osm');
  set placeIdOsm(String? value) => setField<String>('place_id_osm', value);

  String? get placeSource => getField<String>('place_source');
  set placeSource(String? value) => setField<String>('place_source', value);

  String get state => getField<String>('state')!;
  set state(String value) => setField<String>('state', value);

  bool? get appliesToDescendants => getField<bool>('applies_to_descendants');
  set appliesToDescendants(bool? value) =>
      setField<bool>('applies_to_descendants', value);

  String? get source => getField<String>('source');
  set source(String? value) => setField<String>('source', value);

  DateTime? get createdAt => getField<DateTime>('created_at');
  set createdAt(DateTime? value) => setField<DateTime>('created_at', value);
}
