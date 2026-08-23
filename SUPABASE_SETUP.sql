-- =====================================================================
-- Slightly Gigantic — Supabase Setup (single transaction)
-- Run this in: supabase.com/dashboard → (your project) → SQL Editor → New query
-- Paste the ENTIRE file, click RUN.
-- =====================================================================

begin;

-- ---------- Extensions ----------
create extension if not exists pgcrypto;

-- ---------- 1. site_content table ----------
create table if not exists public.site_content (
  id          int          primary key default 1,
  data        jsonb        not null default '{}'::jsonb,
  updated_at  timestamptz  not null default now(),
  constraint single_row check (id = 1)
);

-- ---------- 2. admin_secret table ----------
create table if not exists public.admin_secret (
  id         int          primary key default 1,
  pass_hash  text         not null,
  updated_at timestamptz  not null default now(),
  constraint admin_single_row check (id = 1)
);

commit;

-- =====================================================================
-- Pass 2: seed rows, set RLS, create storage bucket, define RPCs
-- =====================================================================
begin;

-- ---------- 3. Seed the single content row ----------
insert into public.site_content (id, data)
values (1, '{}'::jsonb)
on conflict (id) do nothing;

-- ---------- 4. Seed the admin passphrase (default: slightly2026) ----------
insert into public.admin_secret (id, pass_hash)
values (1, crypt('slightly2026', gen_salt('bf')))
on conflict (id) do nothing;

-- ---------- 5. Row Level Security ----------
alter table public.site_content enable row level security;
alter table public.admin_secret enable row level security;

drop policy if exists "public read site_content" on public.site_content;
create policy "public read site_content"
  on public.site_content for select
  to anon
  using (true);

-- admin_secret: NO policies. Anon cannot read or write directly.

-- ---------- 6. Storage bucket for band photos ----------
insert into storage.buckets (id, name, public)
values ('band-photos', 'band-photos', true)
on conflict (id) do nothing;

drop policy if exists "public read band-photos" on storage.objects;
create policy "public read band-photos"
  on storage.objects for select
  to anon
  using (bucket_id = 'band-photos');

-- ---------- 7. Helper: check if request has the correct admin pass header ----------
create or replace function public.is_admin_request()
returns boolean
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  hdrs jsonb;
  client_pass text;
  stored_hash text;
begin
  begin
    hdrs := current_setting('request.headers', true)::jsonb;
  exception when others then
    return false;
  end;
  client_pass := hdrs ->> 'x-admin-pass';
  if client_pass is null then return false; end if;
  select pass_hash into stored_hash from public.admin_secret where id = 1;
  return stored_hash is not null and stored_hash = crypt(client_pass, stored_hash);
end;
$$;

grant execute on function public.is_admin_request() to anon;

-- ---------- 8. RPC: save_site_content(pass, payload) ----------
create or replace function public.save_site_content(
  pass text,
  payload jsonb
) returns void
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  stored_hash text;
begin
  select pass_hash into stored_hash from public.admin_secret where id = 1;
  if stored_hash is null or stored_hash <> crypt(pass, stored_hash) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  update public.site_content
    set data = payload, updated_at = now()
    where id = 1;
end;
$$;

revoke all on function public.save_site_content(text, jsonb) from public;
grant execute on function public.save_site_content(text, jsonb) to anon;

-- ---------- 9. Storage write policies (admin only, via x-admin-pass header) ----------
drop policy if exists "admin can upload band-photos" on storage.objects;
create policy "admin can upload band-photos"
  on storage.objects for insert
  to anon
  with check (bucket_id = 'band-photos' and public.is_admin_request());

drop policy if exists "admin can delete band-photos" on storage.objects;
create policy "admin can delete band-photos"
  on storage.objects for delete
  to anon
  using (bucket_id = 'band-photos' and public.is_admin_request());

commit;

-- =====================================================================
-- DONE.
-- Default admin password: slightly2026
--
-- To change later, run:
--   update public.admin_secret
--   set pass_hash = crypt('your-new-pass', gen_salt('bf')),
--       updated_at = now()
--   where id = 1;
-- =====================================================================
