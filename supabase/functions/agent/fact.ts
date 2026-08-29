/**
 * Fact 事实核验（轻量版）。
 *
 * MVP 核验范围：坐标存在性、名称/地址完整性、候选间重复（名称归一化 +
 * 距离阈值）。营业时间真实核验需要高德详情接口，属“深度事实核验”，按
 * MVP 裁剪建议延后；本模块只标记不确定，不把不确定说成确定。
 */
import { categoryOverlap, type MemorySignals } from './memory.ts';
import type { PlaceCandidate, VerifiedPlace } from './types.ts';

/** 两候选距离小于该值且名称相似时判定为重复。 */
const DUPLICATE_DISTANCE_METERS = 80;

export function verifyCandidates(
  candidates: PlaceCandidate[],
  signals: MemorySignals,
): VerifiedPlace[] {
  const verified: VerifiedPlace[] = [];

  for (const candidate of candidates) {
    const warnings: string[] = [];
    let confidence = 0.9;

    if (candidate.latitude === null || candidate.longitude === null) {
      warnings.push('缺少坐标，无法参与路线规划');
      confidence -= 0.3;
    }
    if (candidate.address === null || candidate.address.trim().length === 0) {
      warnings.push('缺少地址信息');
      confidence -= 0.15;
    }
    if (candidate.business_status === 'closed') {
      warnings.push('该地点可能已停止营业');
      confidence -= 0.4;
    }
    if (candidate.rating === null) {
      warnings.push('暂无评分数据');
      confidence -= 0.05;
    }
    if (candidate.category === null) {
      warnings.push('类别未知，匹配可能不准');
      confidence -= 0.1;
    }

    if (hasEarlierDuplicate(candidate, verified)) {
      warnings.push('与另一候选疑似同一家店');
      confidence -= 0.5;
    }

    verified.push({
      ...candidate,
      verified: warnings.length === 0,
      confidence: Math.max(0.05, Math.min(1, Number(confidence.toFixed(2)))),
      warnings,
      // 附加字段供 Recommend 打分（不进入持久化契约之外的用途）。
      ...({ memoryOverlap: categoryOverlap(candidate, signals) } as object),
    } as VerifiedPlace);
  }

  return verified;
}

function hasEarlierDuplicate(
  candidate: PlaceCandidate,
  earlier: VerifiedPlace[],
): boolean {
  if (candidate.latitude === null || candidate.longitude === null) return false;
  return earlier.some((other) => {
    if (
      other.latitude === null ||
      other.longitude === null ||
      other.provider_place_id === candidate.provider_place_id
    ) {
      return false;
    }
    const nameSimilar =
      normalizeName(other.name) === normalizeName(candidate.name);
    if (!nameSimilar) return false;
    const distance = haversineMeters(
      candidate.latitude,
      candidate.longitude,
      other.latitude,
      other.longitude,
    );
    return distance <= DUPLICATE_DISTANCE_METERS;
  });
}

function normalizeName(name: string): string {
  return name
    .replace(/\s+/gu, '')
    .replace(/（.*?）|\(.*?\)/gu, '')
    .replace(/(分店|旗舰店|总店|店)$/u, '');
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
