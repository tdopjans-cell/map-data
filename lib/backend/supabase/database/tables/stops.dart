import '../database.dart';

class StopsTable extends SupabaseTable<StopsRow> {
  @override
  String get tableName => 'stops';

  @override
  StopsRow createRow(Map<String, dynamic> data) => StopsRow(data);
}

class StopsRow extends SupabaseDataRow {
  StopsRow(Map<String, dynamic> data) : super(data);

  @override
  SupabaseTable get table => StopsTable();

  String? get id => getField<String>('id');
  set id(String? value) => setField<String>('id', value);

  String get tripId => getField<String>('trip_id')!;
  set tripId(String value) => setField<String>('trip_id', value);

  String get routeVersionId => getField<String>('route_version_id')!;
  set routeVersionId(String value) =>
      setField<String>('route_version_id', value);

  String get ownerId => getField<String>('owner_id')!;
  set ownerId(String value) => setField<String>('owner_id', value);

  int get sequenceIndex => getField<int>('sequence_index')!;
  set sequenceIndex(int value) => setField<int>('sequence_index', value);

  String? get stopType => getField<String>('stop_type');
  set stopType(String? value) => setField<String>('stop_type', value);

  String? get stopRole => getField<String>('stop_role');
  set stopRole(String? value) => setField<String>('stop_role', value);

  String? get placeLevel => getField<String>('place_level');
  set placeLevel(String? value) => setField<String>('place_level', value);

  String? get placeName => getField<String>('place_name');
  set placeName(String? value) => setField<String>('place_name', value);

  String? get placeIdGoogle => getField<String>('place_id_google');
  set placeIdGoogle(String? value) =>
      setField<String>('place_id_google', value);

  String? get placeIdNe => getField<String>('place_id_ne');
  set placeIdNe(String? value) => setField<String>('place_id_ne', value);

  String? get placeIdOsm => getField<String>('place_id_osm');
  set placeIdOsm(String? value) => setField<String>('place_id_osm', value);

  String? get placeSource => getField<String>('place_source');
  set placeSource(String? value) => setField<String>('place_source', value);

  double? get lat => getField<double>('lat');
  set lat(double? value) => setField<double>('lat', value);

  double? get lng => getField<double>('lng');
  set lng(double? value) => setField<double>('lng', value);

  int? get plannedDays => getField<int>('planned_days');
  set plannedDays(int? value) => setField<int>('planned_days', value);

  DateTime? get startDate => getField<DateTime>('start_date');
  set startDate(DateTime? value) => setField<DateTime>('start_date', value);

  DateTime? get endDate => getField<DateTime>('end_date');
  set endDate(DateTime? value) => setField<DateTime>('end_date', value);

  String? get timeMode => getField<String>('time_mode');
  set timeMode(String? value) => setField<String>('time_mode', value);

  bool? get isTimeFixed => getField<bool>('is_time_fixed');
  set isTimeFixed(bool? value) => setField<bool>('is_time_fixed', value);

  String? get parentStopId => getField<String>('parent_stop_id');
  set parentStopId(String? value) => setField<String>('parent_stop_id', value);

  String? get rootContainerStopId => getField<String>('root_container_stop_id');
  set rootContainerStopId(String? value) =>
      setField<String>('root_container_stop_id', value);

  bool? get isContainer => getField<bool>('is_container');
  set isContainer(bool? value) => setField<bool>('is_container', value);

  String? get source => getField<String>('source');
  set source(String? value) => setField<String>('source', value);

  bool? get isAiGenerated => getField<bool>('is_ai_generated');
  set isAiGenerated(bool? value) => setField<bool>('is_ai_generated', value);

  String? get overrideParamGroupType =>
      getField<String>('override_param_group_type');
  set overrideParamGroupType(String? value) =>
      setField<String>('override_param_group_type', value);

  String? get overrideParamDiet => getField<String>('override_param_diet');
  set overrideParamDiet(String? value) =>
      setField<String>('override_param_diet', value);

  String? get overrideParamBudget => getField<String>('override_param_budget');
  set overrideParamBudget(String? value) =>
      setField<String>('override_param_budget', value);

  String? get overrideParamTripStyle =>
      getField<String>('override_param_trip_style');
  set overrideParamTripStyle(String? value) =>
      setField<String>('override_param_trip_style', value);

  String? get overrideParamActivityLevel =>
      getField<String>('override_param_activity_level');
  set overrideParamActivityLevel(String? value) =>
      setField<String>('override_param_activity_level', value);

  List<String> get overrideParamTags =>
      getListField<String>('override_param_tags');
  set overrideParamTags(List<String>? value) =>
      setListField<String>('override_param_tags', value);

  DateTime? get createdAt => getField<DateTime>('created_at');
  set createdAt(DateTime? value) => setField<DateTime>('created_at', value);
}
