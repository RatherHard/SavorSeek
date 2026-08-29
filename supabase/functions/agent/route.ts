/**
 * Route 路线规划（Phase E）。
 *
 * MVP 不调用外部路线 API 做精确到达时间承诺（降级矩阵：路线服务不可用时
 * 保留地点顺序），先用最近邻排序 + 固定停留时长生成可执行草案。生成的
 * TripDraft 需要 is_time_locked 之外的字段由队长确认后经 apply_trip_draft
 * 写入正式行程。
 */
import type { RecommendationItem, VerifiedPlace } from './types.ts';

export interface RouteStop {
  name: string;
  placeId: string | null;
  localDate: string;
  plannedStartAt: string;
  plannedEndAt: string;
  timeSlot: string;
  position: number;
  itemType: 'place_visit';
  placeSnapshot: Record<string, unknown> | null;
}

export interface RouteResult {
  stops: RouteStop[];
  warnings: string[];
}

/** 每站默认停留 90 分钟。 */
const STAY_MINUTES = 90;

function mealSlotFor(hour: number): string {
  if (hour < 10) return 'breakfast';
  if (hour < 14) return 'lunch';
  if (hour < 17) return 'afternoon_tea';
  if (hour < 22) return 'dinner';
  return 'late_night';
}

export function planRoute(
  places: VerifiedPlace[],
  recommendations: RecommendationItem[],
  options: {
    startDate: string;
    startHour: number;
    startMinute?: number;
    maxStops?: number;
  },
): RouteResult {
  const warnings: string[] = [];
  const maxStops = options.maxStops ?? 5;

  // 只选有坐标且通过核验的候选，按推荐 rank 排序后做最近邻串线。
  const withCoords = places
    .filter((place) => place.latitude !== null && place.longitude !== null)
    .slice(0, maxStops);
  if (withCoords.length === 0) {
    return { stops: [], warnings: ['所有候选缺少坐标，无法规划路线'] };
  }

  const ordered: VerifiedPlace[] = [];
  const remaining = [...withCoords];
  let currentLat = withCoords[0].latitude!;
  let currentLng = withCoords[0].longitude!;
  while (remaining.length > 0) {
    let bestIndex = 0;
    let bestDistance = Number.POSITIVE_INFINITY;
    for (let index = 0; index < remaining.length; index++) {
      const candidate = remaining[index];
      const distance = haversine(currentLat, currentLng, candidate.latitude!, candidate.longitude!);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = index;
      }
    }
    const next = remaining.splice(bestIndex, 1)[0];
    ordered.push(next);
    currentLat = next.latitude!;
    currentLng = next.longitude!;
  }

  // 时间表：跨站预留 30 分钟交通（MVP 用直线距离估算 15km/h 步行/骑行均值）。
  const stops: RouteStop[] = [];
  const startMinutes = options.startHour * 60 + (options.startMinute ?? 0);
  let cursor = 0;
  for (let index = 0; index < ordered.length; index++) {
    if (index > 0) {
      const prev = ordered[index - 1];
      const distance = haversine(prev.latitude!, prev.longitude!, ordered[index].latitude!, ordered[index].longitude!);
      cursor += Math.min(60, Math.max(10, Math.round(distance / 250)));
    }
    const beginMinutes = startMinutes + cursor;
    const endMinutes = beginMinutes + STAY_MINUTES;
    const dayOffset = Math.floor(beginMinutes / 1440);
    const dayOffsetEnd = Math.floor(endMinutes / 1440);
    const localStart = minutesToIso(options.startDate, beginMinutes % 1440, dayOffset);
    const localEnd = minutesToIso(options.startDate, endMinutes % 1440, dayOffsetEnd);
    if (dayOffset > 0) warnings.push(`${ordered[index].name} 排到了次日，请确认`);
    const rankItem = recommendations.find((item) => item.name === ordered[index].name);
    stops.push({
      name: ordered[index].name,
      placeId: null,
      localDate: offsetDate(options.startDate, dayOffset),
      plannedStartAt: localStart,
      plannedEndAt: localEnd,
      timeSlot: mealSlotFor(Math.floor((beginMinutes % 1440) / 60)),
      position: index,
      itemType: 'place_visit',
      placeSnapshot: {
        schema_version: 1,
        name: ordered[index].name,
        address: ordered[index].address,
        latitude: ordered[index].latitude,
        longitude: ordered[index].longitude,
        coordinate_system: 'gcj02',
        verified_at: null,
        ...(rankItem ? { match_summary: rankItem.matchSummary } : {}),
      },
    });
    cursor = endMinutes - startMinutes;
  }

  return { stops, warnings };
}

/** 把 stops 映射为 trip_drafts.items 的 JSONB 形状。 */
export function toTripDraftItems(
  stops: RouteStop[],
  recommendations: RecommendationItem[],
  placeIds: Map<string, string> = new Map(),
): Array<Record<string, unknown>> {
  return stops.map((stop) => {
    const rankItem = recommendations.find((item) => item.name === stop.name);
    return {
      itemType: stop.itemType,
      placeId: placeIds.get(stop.name) ?? stop.placeId,
      title: stop.name,
      localDate: stop.localDate,
      plannedStartAt: stop.plannedStartAt,
      plannedEndAt: stop.plannedEndAt,
      timeSlot: stop.timeSlot,
      position: stop.position,
      estimatedCostMinMinor: null,
      estimatedCostMaxMinor: null,
      placeSnapshot: stop.placeSnapshot,
      matchSummary: rankItem?.matchSummary ?? null,
      confidence: rankItem?.confidence ?? null,
    };
  });
}

function offsetDate(startDate: string, dayOffset: number): string {
  const date = new Date(`${startDate}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + dayOffset);
  return date.toISOString().slice(0, 10);
}

function minutesToIso(startDate: string, minutes: number, dayOffset: number): string {
  const date = new Date(`${offsetDate(startDate, dayOffset)}T00:00:00Z`);
  date.setUTCMinutes(minutes);
  return date.toISOString().replace(/\.\d{3}Z$/, '+00:00');
}

function haversine(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6_371_000;
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}
