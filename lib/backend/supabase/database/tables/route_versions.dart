import '../database.dart';

class RouteVersionsTable extends SupabaseTable<RouteVersionsRow> {
  @override
  String get tableName => 'route_versions';

  @override
  RouteVersionsRow createRow(Map<String, dynamic> data) =>
      RouteVersionsRow(data);
}

class RouteVersionsRow extends SupabaseDataRow {
  RouteVersionsRow(Map<String, dynamic> data) : super(data);

  @override
  SupabaseTable get table => RouteVersionsTable();

  String? get id => getField<String>('id');
  set id(String? value) => setField<String>('id', value);

  String get tripId => getField<String>('trip_id')!;
  set tripId(String value) => setField<String>('trip_id', value);

  int? get versionNo => getField<int>('version_no');
  set versionNo(int? value) => setField<int>('version_no', value);

  bool? get isActive => getField<bool>('is_active');
  set isActive(bool? value) => setField<bool>('is_active', value);

  String? get generatedBy => getField<String>('generated_by');
  set generatedBy(String? value) => setField<String>('generated_by', value);

  String? get generationMode => getField<String>('generation_mode');
  set generationMode(String? value) =>
      setField<String>('generation_mode', value);

  DateTime? get createdAt => getField<DateTime>('created_at');
  set createdAt(DateTime? value) => setField<DateTime>('created_at', value);
}
