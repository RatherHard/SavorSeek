import 'package:flutter/foundation.dart';

/// 一个可在地图上呈现的地点。
///
/// 字段与 `public.places` 的列一一对应，坐标固定为 gcj02（与高德底图一致，见
/// `20260823000005_places_schema.sql`）。这里不引入高德 SDK 的类型：地图插件的
/// 类型不应泄漏到领域层（设计文档 §1013），否则更换地图供应商会波及全部调用方。
@immutable
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.fetchedAt,
    this.category,
    this.address,
    this.latitude,
    this.longitude,
  }) : assert(
         (latitude == null) == (longitude == null),
         '经纬度必须同时提供或同时省略',
       );

  final String id;
  final String name;

  /// 供应商原始类别串，形如 `餐饮服务;中餐厅;海鲜酒楼`。
  final String? category;
  final String? address;
  final double? latitude;
  final double? longitude;

  /// 该地点信息的抓取时间，用于向用户说明「信息更新于 X」。
  ///
  /// 可解释性要求：推荐与地点信息必须给出时效提示（PRD 可解释性一节），
  /// 让用户知道看到的营业信息可能已经过时。
  final DateTime fetchedAt;

  bool get hasCoordinates => latitude != null && longitude != null;

  /// 类别的展示形式。高德用 `;` 分层，最末一级最具体，取它最贴近用户认知。
  String? get primaryCategory {
    final raw = category?.trim();
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split(';').where((part) => part.trim().isNotEmpty);
    return parts.isEmpty ? null : parts.last.trim();
  }

  factory Place.fromJson(Map<String, dynamic> json) {
    return Place(
      id: json['id'] as String,
      name: json['name'] as String,
      category: json['category'] as String?,
      address: json['address'] as String?,
      // numeric 列经 JSON 传输后可能是 num 或 String，两种都要接住。
      latitude: _readDouble(json['latitude']),
      longitude: _readDouble(json['longitude']),
      fetchedAt: DateTime.parse(json['fetched_at'] as String).toLocal(),
    );
  }

  static double? _readDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}

/// 一次检索的结果。
@immutable
class PlaceSearchResult {
  const PlaceSearchResult({
    required this.places,
    required this.fromCache,
    this.fetchedAt,
  });

  final List<Place> places;

  /// 结果是否来自服务端缓存。用于在 UI 上说明数据时效来源。
  final bool fromCache;
  final DateTime? fetchedAt;

  bool get isEmpty => places.isEmpty;
}
