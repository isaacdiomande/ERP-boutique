-- ============================================================================
-- Migration 013 : codes de licence pour la création d'une boutique.
--
-- Créer une boutique exige désormais un code de licence valide, à usage
-- unique, généré par un administrateur de la plateforme (Isaac). Les membres
-- invités (code d'invitation) ne sont pas concernés ; les boutiques
-- existantes non plus.
--
--   platform_admins          : comptes administrateurs de la plateforme
--   licence_codes            : codes EB-XXXX-XXXX (note = client, état)
--   is_platform_admin()      : l'app affiche l'écran Licences si vrai
--   create_licence_codes(n, note) / list_licence_codes() / revoke_licence_code(code)
--   create_shop_and_owner(nom, code) : remplace l'ancienne version sans code
--
-- APRÈS l'exécution, désigner l'administrateur (une seule fois) :
--   insert into public.platform_admins (user_id)
--   select id from auth.users where email = '<votre email>'
--   on conflict do nothing;
--
-- Pré-requis : migrations 001 à 012. Relançable sans casse.
-- ============================================================================

create table if not exists public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.platform_admins enable row level security;
revoke all on public.platform_admins from anon, authenticated;

create table if not exists public.licence_codes (
  code        text primary key,
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id),
  used_at     timestamptz,
  used_by     uuid references auth.users(id),
  shop_id     uuid references public.shops(id) on delete set null,
  revoked_at  timestamptz
);
alter table public.licence_codes enable row level security;
revoke all on public.licence_codes from anon, authenticated;
-- aucune règle : seules les fonctions ci-dessous y accèdent

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;

create or replace function public.require_platform_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Réservé à l''administrateur de la plateforme';
  end if;
end;
$$;

create or replace function public.create_licence_codes(p_count integer, p_note text default null)
returns setof text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_hex  text;
  i      integer;
begin
  perform public.require_platform_admin();
  if p_count is null or p_count < 1 or p_count > 50 then
    raise exception 'Nombre de codes invalide (1 à 50)';
  end if;
  for i in 1..p_count loop
    loop
      v_hex  := upper(replace(gen_random_uuid()::text, '-', ''));
      v_code := 'EB-' || substr(v_hex, 1, 4) || '-' || substr(v_hex, 5, 4);
      exit when not exists (select 1 from public.licence_codes where code = v_code);
    end loop;
    insert into public.licence_codes (code, note, created_by)
    values (v_code, nullif(trim(p_note), ''), auth.uid());
    return next v_code;
  end loop;
end;
$$;

create or replace function public.list_licence_codes()
returns table (code text, note text, created_at timestamptz, used_at timestamptz,
               used_by_email text, shop_name text, revoked_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_platform_admin();
  return query
    select l.code, l.note, l.created_at, l.used_at, u.email::text, s.name, l.revoked_at
    from public.licence_codes l
    left join auth.users u on u.id = l.used_by
    left join public.shops s on s.id = l.shop_id
    order by l.created_at desc;
end;
$$;

create or replace function public.revoke_licence_code(p_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_platform_admin();
  update public.licence_codes set revoked_at = now()
  where code = upper(trim(p_code)) and used_at is null and revoked_at is null;
  if not found then
    raise exception 'Code introuvable, déjà utilisé ou déjà annulé';
  end if;
end;
$$;

-- L'ancienne version sans code ne doit plus être appelable
drop function if exists public.create_shop_and_owner(text);

create or replace function public.create_shop_and_owner(p_shop_name text, p_licence_code text)
returns public.shops
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_email    text;
  v_existing uuid;
  v_lic      public.licence_codes;
  v_shop     public.shops;
begin
  if v_user_id is null then
    raise exception 'Authentification requise';
  end if;
  if p_shop_name is null or length(trim(p_shop_name)) = 0 then
    raise exception 'Le nom de la boutique est obligatoire';
  end if;

  select * into v_lic from public.licence_codes
  where code = upper(trim(coalesce(p_licence_code, ''))) for update;
  if v_lic.code is null or v_lic.revoked_at is not null then
    raise exception 'Code de licence invalide';
  end if;
  if v_lic.used_at is not null then
    raise exception 'Ce code de licence a déjà été utilisé';
  end if;

  select shop_id into v_existing from public.profiles where id = v_user_id for update;
  if v_existing is not null then
    raise exception 'Ce compte est déjà associé à une boutique';
  end if;

  insert into public.shops (name, owner_id)
  values (trim(p_shop_name), v_user_id)
  returning * into v_shop;

  select email into v_email from auth.users where id = v_user_id;
  insert into public.profiles (id, email, display_name, role, shop_id)
  values (v_user_id, v_email, split_part(coalesce(v_email, 'proprietaire'), '@', 1), 'owner', v_shop.id)
  on conflict (id) do update set shop_id = excluded.shop_id, role = 'owner';

  update public.licence_codes
  set used_at = now(), used_by = v_user_id, shop_id = v_shop.id
  where code = v_lic.code;

  return v_shop;
end;
$$;

revoke execute on function public.is_platform_admin() from public, anon;
revoke execute on function public.require_platform_admin() from public, anon, authenticated;
revoke execute on function public.create_licence_codes(integer, text) from public, anon;
revoke execute on function public.list_licence_codes() from public, anon;
revoke execute on function public.revoke_licence_code(text) from public, anon;
revoke execute on function public.create_shop_and_owner(text, text) from public, anon;
grant execute on function public.is_platform_admin() to authenticated;
grant execute on function public.create_licence_codes(integer, text) to authenticated;
grant execute on function public.list_licence_codes() to authenticated;
grant execute on function public.revoke_licence_code(text) to authenticated;
grant execute on function public.create_shop_and_owner(text, text) to authenticated;

notify pgrst, 'reload schema';
