export interface SearchBounds {
  south: number;
  west: number;
  north: number;
  east: number;
}

export interface SearchPartition {
  key: string;
  bounds: SearchBounds;
  latitude: number;
  longitude: number;
  radius: number;
}

const MAX_PARTITIONS = 4;
const SAFE_RADIUS_METERS = 45_000;
const EARTH_METERS_PER_DEGREE = 111_320;
const MAX_SPLIT_DEPTH = 2;

/**
 * Splits a bounds query into a deterministic, bounded set of around queries.
 * A west value greater than east represents an antimeridian crossing and is
 * split into two ordinary ranges before the size calculation.
 */
export function planSearchPartitions(bounds: SearchBounds): SearchPartition[] {
  const ranges = bounds.west > bounds.east
    ? [
      { ...bounds, east: 180 },
      { ...bounds, west: -180 },
    ]
    : [bounds];
  const partitions = ranges.flatMap((range) => splitRange(range));
  return partitions.slice(0, MAX_PARTITIONS).map((partition, index) => ({
    ...partition,
    key: `${index}:${partition.bounds.south.toFixed(5)}:${partition.bounds.west.toFixed(5)}:${partition.bounds.north.toFixed(5)}:${partition.bounds.east.toFixed(5)}`,
  }));
}

function splitRange(bounds: SearchBounds, depth = 0): SearchPartition[] {
  const latitudeSpan = (bounds.north - bounds.south) * EARTH_METERS_PER_DEGREE;
  const meanLatitude = (bounds.south + bounds.north) / 2;
  const longitudeSpan =
    (bounds.east - bounds.west) * EARTH_METERS_PER_DEGREE *
    Math.cos((meanLatitude * Math.PI) / 180);
  const diagonal = Math.hypot(latitudeSpan, longitudeSpan) / 2;
  if (diagonal <= SAFE_RADIUS_METERS || depth >= MAX_SPLIT_DEPTH) {
    return [toPartition(bounds)];
  }

  const splitLongitude = Math.abs(longitudeSpan) >= Math.abs(latitudeSpan);
  if (splitLongitude) {
    const middle = (bounds.west + bounds.east) / 2;
    return [
      ...splitRange({ ...bounds, east: middle }),
      ...splitRange({ ...bounds, west: middle }),
    ];
  }
  const middle = (bounds.south + bounds.north) / 2;
  return [
    ...splitRange({ ...bounds, north: middle }),
    ...splitRange({ ...bounds, south: middle }),
  ];
}

function toPartition(bounds: SearchBounds): SearchPartition {
  const latitude = (bounds.south + bounds.north) / 2;
  const longitude = (bounds.west + bounds.east) / 2;
  const latitudeSpan = (bounds.north - bounds.south) * EARTH_METERS_PER_DEGREE;
  const longitudeSpan =
    (bounds.east - bounds.west) * EARTH_METERS_PER_DEGREE *
    Math.cos((latitude * Math.PI) / 180);
  return {
    key: '',
    bounds,
    latitude,
    longitude,
    radius: Math.min(SAFE_RADIUS_METERS, Math.ceil(Math.hypot(latitudeSpan, longitudeSpan) / 2)),
  };
}
