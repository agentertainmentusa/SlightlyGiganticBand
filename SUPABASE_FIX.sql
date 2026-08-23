-- =====================================================================
-- Slightly Gigantic — Supabase FIX (run after the initial setup)
-- This fixes the "crypt() does not exist" error by making sure
-- pgcrypto is in the extensions schema and our functions reference it.
-- =====================================================================

begin;

-- Make sure pgcrypto exists in the standard "extensions" schema
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Re-seed the admin password using the qualified function path
update public.admin_secret
  set pass_hash  = extensions.crypt('slightly2026', extensions.gen_salt('bf')),
      updated_at = now()
  where id = 1;

-- Recreate is_admin_request() with qualified crypt() call
create or replace function public.is_admin_request()
returns boolean
  language plpgsql
  security definer
  set search_path = public, extensions
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
  return stored_hash is not null and stored_hash = extensions.crypt(client_pass, stored_hash);
end;
$$;

grant execute on function public.is_admin_request() to anon;

-- Recreate save_site_content() with qualified crypt() call
create or replace function public.save_site_content(
  pass text,
  payload jsonb
) returns void
  language plpgsql
  security definer
  set search_path = public, extensions
as $$
declare
  stored_hash text;
begin
  select pass_hash into stored_hash from public.admin_secret where id = 1;
  if stored_hash is null or stored_hash <> extensions.crypt(pass, stored_hash) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  update public.site_content
    set data = payload, updated_at = now()
    where id = 1;
end;
$$;

revoke all on function public.save_site_content(text, jsonb) from public;
grant execute on function public.save_site_content(text, jsonb) to anon;

commit;
