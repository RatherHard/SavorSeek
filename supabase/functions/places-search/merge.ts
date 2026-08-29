import type { NormalizedPlace } from './amap.ts';
import type { SearchBounds, SearchPartition } from './partition.ts';

export interface BoundsFilters {
  cuisine_tags: string[];
  min_price_level?: number;
  max_price_level?: number;
  max_distance_meters?: number;
  open_now?: boolean;
  min_rating?: number;
}

export interface PartitionBatch {
  partition: SearchPartition;
  page: number;
  places: NormalizedPlace[];
}

export interface MergeOptions {
  bounds: SearchBounds;
  filters: BoundsFilters;
  limit: number;
  origin?: { latitude: number; longitude: number };
}

/**
 * Merges bounded provider batches without depending on Promise completion order.
 * Provider ids are the cross-request identity; database ids are assigned later.
 */
export function mergePartitionBatches(
  batches: PartitionBatch[],
  options: MergeOptions,
): NormalizedPlace[] {
  const byProviderId = new Map<string, NormalizedPlace>();
  const sourceByProviderId = new Map<string, [number, number, number]>();

  for (const batch of batches) {
    for (const [providerIndex, place] of batch.places.entries()) {
      if (!isInsideBounds(place, options.bounds)) continue;
      if (!matchesFilters(place, options)) continue;
      const previous = byProviderId.get(place.provider_place_id);
      const source: [number, number, number] = [
        0,
        batch.page,
        providerIndex,
      ];
      if (!previous) {
        byProviderId.set(place.provider_place_id, place);
        sourceByProviderId.set(place.provider_place_id, source);
        continue;
      }
      const previousSource = sourceByProviderId.get(place.provider_place_id)!;
      if (isBetterPlace(place, previous, source, previousSource)) {
        byProviderId.set(place.provider_place_id, place);
        sourceByProviderId.set(place.provider_place_id, source);
      }
    }
  }

  return [...byProviderId.values()]
    .sort((a, b) => comparePlaces(a, b, options.origin))
    .slice(0, options.limit);
}

function isInsideBounds(place: NormalizedPlace, bounds: SearchBounds): boolean {
  if (place.latitude === null || place.longitude === null) return false;
  const inLongitude = bounds.west > bounds.east
    ? place.longitude >= bounds.west || place.longitude <= bounds.east
    : place.longitude >= bounds.west && place.longitude <= bounds.east;
  return place.latitude >= bounds.south && place.latitude <= bounds.north && inLongitude;
}

function matchesFilters(place: NormalizedPlace, options: MergeOptions): boolean {
  const filters = options.filters;
  if (filters.cuisine_tags.length > 0) {
    const cuisines = new Set((place.cuisine_tags ?? []).map((tag) => tag.toLowerCase()));
    if (!filters.cuisine_tags.some((tag) => cuisines.has(tag.toLowerCase()))) return false;
  }
  if (filters.min_rating !== undefined &&
      (place.rating === null || place.rating < filters.min_rating)) return false;
  if (filters.min_price_level !== undefined &&
      (place.price_level === null || place.price_level < filters.min_price_level)) return false;
  if (filters.max_price_level !== undefined &&
      (place.price_level === null || place.price_level > filters.max_price_level)) return false;
  if (filters.open_now !== undefined) {
    const isOpen = place.business_status === 'open';
    if (isOpen !== filters.open_now) return false;
  }
  if (filters.max_distance_meters !== undefined) {
    if (!options.origin || place.latitude === null || place.longitude === null) return false;
    if (distanceMeters(options.origin, place.latitude, place.longitude) > filters.max_distance_meters) return false;
  }
  return true;
}

function isBetterPlace(
  candidate: NormalizedPlace,
  previous: NormalizedPlace,
  source: [number, number, number],
  previousSource: [number, number, number],
): boolean {
  const candidateCompleteness = completeness(candidate);
  const previousCompleteness = completeness(previous);
  if (candidateCompleteness !== previousCompleteness) return candidateCompleteness > previousCompleteness;
  const candidateRating = candidate.rating ?? -1;
  const previousRating = previous.rating ?? -1;
  if (candidateRating !== previousRating) return candidateRating > previousRating;
  return source[1] < previousSource[1] ||
    (source[1] === previousSource[1] && source[2] < previousSource[2]);
}

function completeness(place: NormalizedPlace): number {
  return Number(place.latitude !== null && place.longitude !== null) +
    Number(place.rating !== null) +
    Number(place.price_level !== null) +
    Number(place.business_status !== null) +
    Number((place.cuisine_tags ?? []).length > 0);
}

function comparePlaces(
  a: NormalizedPlace,
  b: NormalizedPlace,
  origin?: { latitude: number; longitude: number },
): number {
  if (origin && a.latitude !== null && a.longitude !== null && b.latitude !== null && b.longitude !== null) {
    const distance = distanceMeters(origin, a.latitude, a.longitude) -
      distanceMeters(origin, b.latitude, b.longitude);
    if (distance !== 0) return distance;
  }
  const rating = (b.rating ?? -1) - (a.rating ?? -1);
  if (rating !== 0) return rating;
  return a.provider_place_id.localeCompare(b.provider_place_id);
}

function distanceMeters(
  origin: { latitude: number; longitude: number },
  latitude: number,
  longitude: number,
): number {
  const radians = Math.PI / 180;
  const dLat = (latitude - origin.latitude) * radians;
  const dLng = (longitude - origin.longitude) * radians;
  const lat1 = origin.latitude * radians;
  const lat2 = latitude * radians;
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 6_371_000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
