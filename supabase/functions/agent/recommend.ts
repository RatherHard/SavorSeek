/**
 * Recommend 推荐决策（规则版）。
 *
 * 打分全部来自结构化数据字段（评分、距离、收藏类别重叠、预算匹配），
 * LLM 后续只负责生成 matchSummary 的可读表达，不产生分数——保证
 * “硬约束优先，软偏好次之；每个推荐都能解释为什么”。
 */
import type { MemorySignals } from './memory.ts';
import type { ParsedIntent, RecommendationItem, VerifiedPlace } from './types.ts';

export interface RankOptions {
  /** 用户地图视野中心，距离按此计算；无坐标时为 null。 */
  centerLatitude: number | null;
  centerLongitude: number | null;
  resultLimit: number;
}

export function rankPlaces(
  places: VerifiedPlace[],
  intent: ParsedIntent,
  signals: MemorySignals,
  options: RankOptions,
): RecommendationItem[] {
  const scored = places.map((place) => {
    const reasonCodes: string[] = [];
    const riskFlags: string[] = [...place.warnings];
    let score = 0;

    if (place.rating !== null) {
      score += place.rating; // 0-5
      if (place.rating >= 4.5) reasonCodes.push('高评分');
      else if (place.rating >= 4.0) reasonCodes.push('评分良好');
    }

    if (options.centerLatitude !== null && options.centerLongitude !== null && place.latitude !== null) {
      const distance = haversineMeters(
        options.centerLatitude,
        options.centerLongitude,
        place.latitude,
        place.longitude,
      );
      // 5km 内线性加分，越近越高，最多 +3。
      score += Math.max(0, 3 - distance / 5000 * 3);
      if (distance <= 1000) reasonCodes.push('距离很近');
    }

    const overlap = (place as unknown as { memoryOverlap?: number }).memoryOverlap ?? 0;
    if (overlap > 0) {
      score += 2;
      reasonCodes.push(
        `匹配你的收藏偏好（${signals.favoriteCategories.map((entry) => entry.category).slice(0, 2).join('、')}）`,
      );
    }

    if (intent.budgetPerPersonMinor !== null && place.price_level !== null) {
      // 高德 price_level: 0-4 档。以 2 档≈100 元/人 估单价，超过预算则降权。
      const estimatedMinor = place.price_level * 5000;
      if (estimatedMinor <= intent.budgetPerPersonMinor) {
        score += 1.5;
        reasonCodes.push('预计在预算内');
      } else {
        score -= 2;
        riskFlags.push('价格可能超出预算');
      }
    }

    if (intent.mealPeriod === 'dinner' && /烧烤|火锅|烤肉|家常菜|川菜|湘菜/u.test(place.name)) {
      score += 0.5;
    }
    if (intent.mealPeriod === 'breakfast' && /早点|早餐|包子|豆浆|粥|面馆/u.test(place.name)) {
      score += 0.5;
    }

    if (intent.avoid.length > 0) {
      const conflict = intent.avoid.find((item) =>
        place.name.includes(item) || (place.cuisine_tags ?? []).some((tag) => tag.includes(item)),
      );
      if (conflict) {
        score -= 5;
        riskFlags.push(`与忌口「${conflict}」可能冲突`);
      }
    }

    // 停业候选不应出现在推荐首位：直接排除。
    if (place.business_status === 'closed') {
      score -= 100;
    }

    const matchSummary = reasonCodes.length > 0
      ? reasonCodes.join('；')
      : '综合评分与距离的常规匹配';

    return {
      placeId: null,
      name: place.name,
      rank: 0,
      score: Number(score.toFixed(2)),
      matchSummary,
      reasonCodes,
      confidence: place.confidence,
      riskFlags,
    } satisfies RecommendationItem & { placeId: string | null };
  });

  return scored
    .sort((a, b) => b.score - a.score)
    .slice(0, Math.max(1, options.resultLimit))
    .map((item, index) => ({ ...item, rank: index + 1 }));
}

function haversineMeters(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const R = 6_371_000;
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}
