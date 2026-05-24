import '../database.dart';

class PlaceLevelConfigTable extends SupabaseTable<PlaceLevelConfigRow> {
  @override
  String get tableName => 'place_level_config';

  @override
  PlaceLevelConfigRow createRow(Map<String, dynamic> data) =>
      PlaceLevelConfigRow(data);
}

class PlaceLevelConfigRow extends SupabaseDataRow {
  PlaceLevelConfigRow(Map<String, dynamic> data) : super(data);

  @override
  SupabaseTable get table => PlaceLevelConfigTable();

  String get placeLevel => getField<String>('place_level')!;
  set placeLevel(String value) => setField<String>('place_level', value);

  bool? get isAutoContainer => getField<bool>('is_auto_container');
  set isAutoContainer(bool? value) =>
      setField<bool>('is_auto_container', value);

  String? get naturalEarthLayer => getField<String>('natural_earth_layer');
  set naturalEarthLayer(String? value) =>
      setField<String>('natural_earth_layer', value);

  double? get zoomMin => getField<double>('zoom_min');
  set zoomMin(double? value) => setField<double>('zoom_min', value);

  double? get zoomMax => getField<double>('zoom_max');
  set zoomMax(double? value) => setField<double>('zoom_max', value);
}
