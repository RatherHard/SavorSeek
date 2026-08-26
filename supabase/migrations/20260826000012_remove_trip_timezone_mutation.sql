-- 行程时区修改能力移除的前向迁移。
-- 不修改历史迁移；应用前请先核对线上对象与数据。

DROP FUNCTION IF EXISTS public.change_trip_timezone(uuid, bigint, uuid, text);

CREATE OR REPLACE FUNCTION public.validate_trip_row()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  money_exists boolean;
BEGIN
  new.title := btrim(new.title);
  IF char_length(new.title) < 1 THEN
    RAISE EXCEPTION USING errcode = '22023',
      message = 'trip title must not be blank';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_timezone_names WHERE name = new.timezone
  ) THEN
    RAISE EXCEPTION USING errcode = '22023',
      message = 'timezone must be a valid IANA timezone';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF new.id IS DISTINCT FROM old.id
      OR new.user_id IS DISTINCT FROM old.user_id THEN
      RAISE EXCEPTION USING errcode = '42501',
        message = 'trip identity cannot be changed';
    END IF;
    IF new.revision NOT IN (old.revision, old.revision + 1) THEN
      RAISE EXCEPTION USING errcode = '22023',
        message = 'revision may only stay unchanged or increase by one';
    END IF;
    IF new.status IS DISTINCT FROM old.status AND NOT (
      (old.status = 'draft' AND new.status IN ('confirmed', 'completed', 'cancelled'))
      OR (old.status = 'confirmed' AND new.status IN ('in_progress', 'completed', 'cancelled'))
      OR (old.status = 'in_progress' AND new.status IN ('completed', 'cancelled'))
    ) THEN
      RAISE EXCEPTION USING errcode = '22023',
        message = 'invalid trip status transition';
    END IF;
    IF new.timezone IS DISTINCT FROM old.timezone THEN
      RAISE EXCEPTION USING errcode = '23514',
        message = 'timezone cannot be changed after trip creation';
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM public.trip_days
      WHERE trip_id = old.id AND budget_limit_minor IS NOT NULL
      UNION ALL
      SELECT 1 FROM public.trip_items
      WHERE trip_id = old.id
        AND (estimated_cost_min_minor IS NOT NULL
          OR estimated_cost_max_minor IS NOT NULL)
    ) INTO money_exists;
    IF money_exists AND new.currency_code IS DISTINCT FROM old.currency_code THEN
      RAISE EXCEPTION USING errcode = '23514',
        message = 'currency cannot change while aggregate amounts exist';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.trip_days
      WHERE trip_id = old.id
        AND (local_date < new.start_date OR local_date > new.end_date)
    ) THEN
      RAISE EXCEPTION USING errcode = '23514',
        message = 'trip date range excludes an existing trip day';
    END IF;
  END IF;
  RETURN new;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_trip_row() FROM public, anon, authenticated;
