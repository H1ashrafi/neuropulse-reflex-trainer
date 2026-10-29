final class DataFormatException implements Exception {
  const DataFormatException(this.message);

  final String message;

  @override
  String toString() => 'DataFormatException: $message';
}

final class JsonGuard {
  JsonGuard._(this._fields, this.path);

  factory JsonGuard.from(Object? value, String path) {
    if (value is Map<String, Object?>) {
      return JsonGuard._(value, path);
    }
    throw DataFormatException('$path must be an object');
  }

  final Map<String, Object?> _fields;
  final String path;

  Object? _raw(String key) {
    if (!_fields.containsKey(key)) {
      throw DataFormatException('$path.$key is missing');
    }
    return _fields[key];
  }

  DataFormatException _rejected(String key) =>
      DataFormatException('$path.$key is not an allowed value');

  String text(String key, {required RegExp pattern}) {
    final value = _raw(key);
    if (value is String && pattern.hasMatch(value)) {
      return value;
    }
    throw _rejected(key);
  }

  int integer(String key, {required int min, required int max}) {
    final value = _raw(key);
    if (value is int && value >= min && value <= max) {
      return value;
    }
    throw _rejected(key);
  }

  double number(String key, {required double min, required double max}) {
    final value = _raw(key);
    if (value is num) {
      final asDouble = value.toDouble();
      if (asDouble.isFinite && asDouble >= min && asDouble <= max) {
        return asDouble;
      }
    }
    throw _rejected(key);
  }

  double? optionalNumber(String key, {required double min, required double max}) {
    if (_raw(key) == null) {
      return null;
    }
    return number(key, min: min, max: max);
  }

  JsonGuard child(String key) => JsonGuard.from(_raw(key), '$path.$key');

  List<JsonGuard> children(String key, {required int maxCount}) {
    final value = _raw(key);
    if (value is! List<Object?>) {
      throw DataFormatException('$path.$key must be a list');
    }
    if (value.length > maxCount) {
      throw DataFormatException('$path.$key has more than $maxCount entries');
    }
    return [
      for (final (index, item) in value.indexed)
        JsonGuard.from(item, '$path.$key[$index]'),
    ];
  }
}
