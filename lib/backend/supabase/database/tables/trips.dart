import '../database.dart';

class TripsTable extends SupabaseTable<TripsRow> {
  @override
  String get tableName => 'trips';

  @override
  TripsRow createRow(Map<String, dynamic> data) => TripsRow(data);
}

class TripsRow extends SupabaseDataRow {
  TripsRow(Map<String, dynamic> data) : super(data);

  @override
  SupabaseTable get table => TripsTable();

  String? get id => getField<String>('id');
  set id(String? value) => setField<String>('id', value);

  String get ownerId => getField<String>('owner_id')!;
  set ownerId(String value) => setField<String>('owner_id', value);

  String get name => getField<String>('name')!;
  set name(String value) => setField<String>('name', value);

  DateTime? get startDate => getField<DateTime>('start_date');
  set startDate(DateTime? value) => setField<DateTime>('start_date', value);

  DateTime? get endDate => getField<DateTime>('end_date');
  set endDate(DateTime? value) => setField<DateTime>('end_date', value);

  int? get totalDays => getField<int>('total_days');
  set totalDays(int? value) => setField<int>('total_days', value);

  String? get topScopeLevel => getField<String>('top_scope_level');
  set topScopeLevel(String? value) =>
      setField<String>('top_scope_level', value);

  String? get topScopeName => getField<String>('top_scope_name');
  set topScopeName(String? value) => setField<String>('top_scope_name', value);

  String? get topScopePlaceId => getField<String>('top_scope_place_id');
  set topScopePlaceId(String? value) =>
      setField<String>('top_scope_place_id', value);

  String? get paramGroupType => getField<String>('param_group_type');
  set paramGroupType(String? value) =>
      setField<String>('param_group_type', value);

  String? get paramDiet => getField<String>('param_diet');
  set paramDiet(String? value) => setField<String>('param_diet', value);

  String? get paramBudget => getField<String>('param_budget');
  set paramBudget(String? value) => setField<String>('param_budget', value);

  String? get paramTripStyle => getField<String>('param_trip_style');
  set paramTripStyle(String? value) =>
      setField<String>('param_trip_style', value);

  String? get paramActivityLevel => getField<String>('param_activity_level');
  set paramActivityLevel(String? value) =>
      setField<String>('param_activity_level', value);

  List<String> get paramTags => getListField<String>('param_tags');
  set paramTags(List<String>? value) =>
      setListField<String>('param_tags', value);

  String? get searchTier => getField<String>('search_tier');
  set searchTier(String? value) => setField<String>('search_tier', value);

  DateTime? get createdAt => getField<DateTime>('created_at');
  set createdAt(DateTime? value) => setField<DateTime>('created_at', value);
}
