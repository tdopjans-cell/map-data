import '../database.dart';

class ProfilesTable extends SupabaseTable<ProfilesRow> {
  @override
  String get tableName => 'profiles';

  @override
  ProfilesRow createRow(Map<String, dynamic> data) => ProfilesRow(data);
}

class ProfilesRow extends SupabaseDataRow {
  ProfilesRow(Map<String, dynamic> data) : super(data);

  @override
  SupabaseTable get table => ProfilesTable();

  String get id => getField<String>('id')!;
  set id(String value) => setField<String>('id', value);

  String? get displayName => getField<String>('display_name');
  set displayName(String? value) => setField<String>('display_name', value);

  String? get avatarUrl => getField<String>('avatar_url');
  set avatarUrl(String? value) => setField<String>('avatar_url', value);

  String? get subscriptionTier => getField<String>('subscription_tier');
  set subscriptionTier(String? value) =>
      setField<String>('subscription_tier', value);

  DateTime? get subscriptionValidUntil =>
      getField<DateTime>('subscription_valid_until');
  set subscriptionValidUntil(DateTime? value) =>
      setField<DateTime>('subscription_valid_until', value);

  int? get rerunCreditsRemaining => getField<int>('rerun_credits_remaining');
  set rerunCreditsRemaining(int? value) =>
      setField<int>('rerun_credits_remaining', value);

  DateTime? get guestExpiresAt => getField<DateTime>('guest_expires_at');
  set guestExpiresAt(DateTime? value) =>
      setField<DateTime>('guest_expires_at', value);

  String? get preferredLanguage => getField<String>('preferred_language');
  set preferredLanguage(String? value) =>
      setField<String>('preferred_language', value);

  DateTime? get createdAt => getField<DateTime>('created_at');
  set createdAt(DateTime? value) => setField<DateTime>('created_at', value);
}
