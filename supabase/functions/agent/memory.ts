/**
 * Memory 偏好记忆（只读版）。
 *
 * MVP 从 favorites 反推稳定偏好信号（收藏即明确表达），写入路径不在此实现：
 * 记忆写入必须走 memory_proposals + 队长确认（对接设计 2.5 / 5.7 节）。
 *
 * 推测性结论（例如“似乎喜欢辣”）不由本模块产出——只输出有数据支撑的事实。
 */
import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2';

import type { PlaceCandidate } from './types.ts';

export interface MemorySignals {
  /** 收藏地点的类别分布，按次数降序。 */
  favoriteCategories: Array<{ category: string; count: number }>;
  /** 收藏地点名称，供 Present 层解释“因为你收藏过 X”。 */
  favoriteNames: string[];
  /** 收藏总数。 */
  favoriteCount: number;
}

/** 读取用户收藏，聚合为偏好信号。失败时返回空信号（降级，不阻塞编排）。 */
export async function readMemorySignals(
  serviceClient: SupabaseClient,
  userId: string,
): Promise<MemorySignals> {
  const signals: MemorySignals = {
    favoriteCategories: [],
    favoriteNames: [],
    favoriteCount: 0,
  };

  try {
    const { data, error } = await serviceClient
      .from('favorites')
      .select('place_id, places(name, category)')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(50);
    if (error) return signals;

    const categoryCount = new Map<string, number>();
    for (const row of data ?? []) {
      signals.favoriteCount += 1;
      const place = row['places'] as { name?: unknown; category?: unknown } | null;
      if (place && typeof place['name'] === 'string') {
        signals.favoriteNames.push(place['name']);
      }
      if (place && typeof place['category'] === 'string' && place['category'].length > 0) {
        const category = place['category'];
        categoryCount.set(category, (categoryCount.get(category) ?? 0) + 1);
      }
    }
    signals.favoriteCategories = [...categoryCount.entries()]
      .map(([category, count]) => ({ category, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 5);
    return signals;
  } catch (_error) {
    // 记忆不可用：使用显式输入继续，不假设无偏好（降级矩阵第 14 行）。
    return signals;
  }
}

/** 候选与用户收藏的类别重叠计数，用于推荐打分。 */
export function categoryOverlap(
  candidate: PlaceCandidate,
  signals: MemorySignals,
): number {
  if (candidate.category === null) return 0;
  return signals.favoriteCategories.some((entry) => entry.category === candidate.category)
    ? 1
    : 0;
}
