-- =====================================================================
-- Slightly Gigantic — Analytics schema
-- Run this in the Supabase SQL editor AFTER your existing setup.
-- Safe to re-run: every CREATE uses "IF NOT EXISTS" / "OR REPLACE".
-- =====================================================================

-- 1. Events table -----------------------------------------------------
create table if not exists public.analytics_events (
  id          bigserial primary key,
  ts          timestamptz not null default now(),
  event_type  text        not null,      -- 'song_play' | 'platform_click' | 'page_visit' | 'nav_click' | 'booking_open' | 'booking_submit'
  song_id     text,                      -- release id when applicable
  song_title  text,                      -- denormalized for easy reporting
  platform    text,                      -- 'spotify' | 'apple' | 'youtube' | 'pandora' | etc
  page        text,                      -- '/'  '/#bio'  etc
  section     text,                      -- 'bio' | 'music' | 'photos' | 'merch' | 'booking' | 'admin'
  meta        jsonb       not null default '{}'::jsonb,
  session_id  text,                      -- random client-side id (NOT a user id)
  referrer    text,
  user_agent  text
);

create index if not exists idx_analytics_events_ts        on public.analytics_events (ts desc);
create index if not exists idx_analytics_events_type_ts   on public.analytics_events (event_type, ts desc);
create index if not exists idx_analytics_events_song_ts   on public.analytics_events (song_id, ts desc);
create index if not exists idx_analytics_events_plat_ts   on public.analytics_events (platform, ts desc);

-- 2. RLS — public can INSERT through the RPC only, nothing else -------
alter table public.analytics_events enable row level security;

-- No direct SELECT / INSERT / UPDATE / DELETE for anon. All access via RPCs.
drop policy if exists "analytics_no_direct" on public.analytics_events;

-- 3. Public insert RPC ------------------------------------------------
-- Anyone can call this; it sanitizes the input and writes one row.
create or replace function public.track_event(payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type text := coalesce(payload->>'event_type', '');
begin
  -- Whitelist event types
  if v_type not in (
    'song_play', 'platform_click', 'page_visit', 'nav_click',
    'booking_open', 'booking_submit'
  ) then
    raise exception 'invalid event_type: %', v_type;
  end if;

  insert into public.analytics_events (
    event_type, song_id, song_title, platform, page, section, meta,
    session_id, referrer, user_agent
  ) values (
    v_type,
    nullif(payload->>'song_id', ''),
    nullif(payload->>'song_title', ''),
    nullif(payload->>'platform', ''),
    nullif(payload->>'page', ''),
    nullif(payload->>'section', ''),
    coalesce(payload->'meta', '{}'::jsonb),
    nullif(payload->>'session_id', ''),
    nullif(payload->>'referrer', ''),
    nullif(payload->>'user_agent', '')
  );
end;
$$;

grant execute on function public.track_event(jsonb) to anon, authenticated;

-- 4. Admin read RPC — gated by the same admin password as the rest ---
-- Returns aggregated rows for the admin dashboard. Caller passes the
-- shared admin password (same one used by save_site_content).
create or replace function public.get_analytics(
  pass        text,
  start_ts    timestamptz,
  end_ts      timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_pass text;
  result       jsonb;
begin
  -- Re-use the same admin password used elsewhere. Stored on the site_content row.
  select coalesce(current_setting('app.admin_pass', true), 'slightly2026') into v_admin_pass;
  if pass is null or pass <> v_admin_pass then
    raise exception 'unauthorized';
  end if;

  with
    win as (
      select * from public.analytics_events
      where ts >= start_ts and ts < end_ts
    ),
    totals as (
      select event_type, count(*)::bigint as n
      from win group by event_type
    ),
    by_song as (
      select coalesce(song_title, song_id, '(unknown)') as label,
             count(*)::bigint as n
      from win
      where event_type = 'song_play'
      group by 1
      order by n desc
      limit 50
    ),
    by_platform as (
      select coalesce(platform, '(unknown)') as label,
             count(*)::bigint as n
      from win
      where event_type = 'platform_click'
      group by 1
      order by n desc
    ),
    by_platform_song as (
      select coalesce(song_title, song_id, '(unknown)') as song,
             coalesce(platform, '(unknown)')            as platform,
             count(*)::bigint as n
      from win
      where event_type = 'platform_click'
      group by 1, 2
      order by n desc
      limit 200
    ),
    by_section as (
      select coalesce(section, '(unknown)') as label,
             count(*)::bigint as n
      from win
      where event_type in ('page_visit','nav_click')
      group by 1
      order by n desc
    ),
    booking as (
      select
        sum(case when event_type = 'booking_open'   then 1 else 0 end)::bigint as opens,
        sum(case when event_type = 'booking_submit' then 1 else 0 end)::bigint as submits
      from win
    ),
    daily as (
      select date_trunc('day', ts) as day,
             event_type,
             count(*)::bigint as n
      from win
      group by 1, 2
      order by 1
    )
  select jsonb_build_object(
    'range',           jsonb_build_object('start', start_ts, 'end', end_ts),
    'totals',          coalesce((select jsonb_object_agg(event_type, n) from totals), '{}'::jsonb),
    'by_song',         coalesce((select jsonb_agg(jsonb_build_object('label', label, 'n', n)) from by_song), '[]'::jsonb),
    'by_platform',     coalesce((select jsonb_agg(jsonb_build_object('label', label, 'n', n)) from by_platform), '[]'::jsonb),
    'by_platform_song',coalesce((select jsonb_agg(jsonb_build_object('song', song, 'platform', platform, 'n', n)) from by_platform_song), '[]'::jsonb),
    'by_section',      coalesce((select jsonb_agg(jsonb_build_object('label', label, 'n', n)) from by_section), '[]'::jsonb),
    'booking',         coalesce((select to_jsonb(booking) from booking), '{}'::jsonb),
    'daily',           coalesce((select jsonb_agg(jsonb_build_object('day', day, 'event_type', event_type, 'n', n)) from daily), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

grant execute on function public.get_analytics(text, timestamptz, timestamptz) to anon, authenticated;
