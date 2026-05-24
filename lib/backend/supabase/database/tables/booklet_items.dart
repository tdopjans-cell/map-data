import '../database.dart';

class BookletItemsTable extends SupabaseTable<BookletItemsRow> {
  @override
  String get tableName => 'booklet_items';

  @override
  BookletItemsRow createRow(Map<String, dynamic> data) => BookletItemsRow(data);
}

class BookletItemsRow extends SupabaseDataRow {
  BookletItemsRow(Map<String, dynamic> data) : super(data);

  @override
  SupabaseTable get table => BookletItemsTable();

  String? get id => getField<String>('id');
  set id(String? value) => setField<String>('id', value);

  String get tripId => getField<String>('trip_id')!;
  set tripId(String value) => setField<String>('trip_id', value);

  String get ownerId => getField<String>('owner_id')!;
  set ownerId(String value) => setField<String>('owner_id', value);

  String? get stopId => getField<String>('stop_id');
  set stopId(String? value) => setField<String>('stop_id', value);

  String get category => getField<String>('category')!;
  set category(String value) => setField<String>('category', value);

  String get name => getField<String>('name')!;
  set name(String value) => setField<String>('name', value);

  String? get description => getField<String>('description');
  set description(String? value) => setField<String>('description', value);

  String? get address => getField<String>('address');
  set address(String? value) => setField<String>('address', value);

  double? get lat => getField<double>('lat');
  set lat(double? value) => setField<double>('lat', value);

  double? get lng => getField<double>('lng');
  set lng(double? value) => setField<double>('lng', value);

  String? get placeIdGoogle => getField<String>('place_id_google');
  set placeIdGoogle(String? value) =>
      setField<String>('place_id_google', value);

  String? get placeIdOsm => getField<String>('place_id_osm');
  set placeIdOsm(String? value) => setField<String>('place_id_osm', value);

  String? get placeSource => getField<String>('place_source');
  set placeSource(String? value) => setField<String>('place_source', value);

  String? get affiliateUrl => getField<String>('affiliate_url');
  set affiliateUrl(String? value) => setField<String>('affiliate_url', value);

  String? get imageUrl => getField<String>('image_url');
  set imageUrl(String? value) => setField<String>('image_url', value);

  bool? get isChecked => getField<bool>('is_checked');
  set isChecked(bool? value) => setField<bool>('is_checked', value);

  String? get source => getField<String>('source');
  set source(String? value) => setField<String>('source', value);

  DateTime? get createdAt => getField<DateTime>('created_at');
  set createdAt(DateTime? value) => setField<DateTime>('created_at', value);
}
