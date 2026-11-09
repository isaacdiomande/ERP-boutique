-- ============================================================================
-- Migration 007 : gestion d'équipe + corrections de sécurité.
--
-- A. Corrections (failles / bugs présents depuis 001) :
--   1. profiles : un utilisateur pouvait modifier sa propre ligne EN ENTIER
--      (policy profiles_update_own), donc s'attribuer le rôle owner ou une
--      autre boutique. Désormais seul display_name est modifiable en direct.
--   2. customers : credit_balance n'est plus modifiable en direct (seulement
--      via ventes à crédit, paiements, retours).
--   3. articles : création / modification réservées au owner et au gérant
--      (les mouvements de stock passent toujours par record_movement).
--   4. shop_id par défaut = boutique de l'utilisateur sur articles,
--      customers, suppliers (l'app n'envoyait pas shop_id pour les articles :
--      création d'article et import Excel refusés par la RLS).
--
-- B. Équipe (le propriétaire gère les utilisateurs, cf. cahier des charges) :
--   - shop_invitations : invitation par email + rôle, code XXXX-XXXX,
--     valable 7 jours, à usage unique, liée à l'email invité
--   - RPC : create / revoke / accept invitation, set_member_role, remove_member
--
-- Pré-requis : migrations 001 à 006 appliquées. Relançable sans casse.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A1. profiles : seul display_name est modifiable par l'utilisateur
-- ----------------------------------------------------------------------------
revoke insert, update, delete on public.profiles from public;
do $$
begin
  execute 'revoke insert, update, delete on public.profiles from anon, authenticated';
  execute 'grant update (display_name) on public.profiles to authenticated';
exception when undefined_object then null;
end $$;

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- ----------------------------------------------------------------------------
-- A2. customers : credit_balance protégé
-- ----------------------------------------------------------------------------
do $$
begin
  execute 'revoke insert, update on public.customers from anon, authenticated';
  execute 'grant insert (shop_id, name, phone, email, address, segment, credit_limit, notes) on public.customers to authenticated';
  execute 'grant update (name, phone, email, address, segment, credit_limit, notes) on public.customers to authenticated';
exception when undefined_object then null;
end $$;

-- ----------------------------------------------------------------------------
-- A3. articles : écriture directe réservée owner / gérant
-- ----------------------------------------------------------------------------
drop policy if exists articles_insert_same_shop on public.articles;
create policy articles_insert_same_shop on public.articles
  for insert with check (shop_id = public.current_shop_id()
                         and public.current_shop_role() in ('owner', 'gerant'));

drop policy if exists articles_update_same_shop on public.articles;
create policy articles_update_same_shop on public.articles
  for update using (shop_id = public.current_shop_id()
                    and public.current_shop_role() in ('owner', 'gerant'))
  with check (shop_id = public.current_shop_id());

-- ----------------------------------------------------------------------------
-- A4. shop_id par défaut
-- ----------------------------------------------------------------------------
alter table public.articles  alter column shop_id set default public.current_shop_id();
alter table public.customers alter column shop_id set default public.current_shop_id();
alter table public.suppliers alter column shop_id set default public.current_shop_id();

-- ----------------------------------------------------------------------------
-- B. Invitations
-- ----------------------------------------------------------------------------
create table if not exists public.shop_invitations (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops(id) on delete cascade,
  email        text not null,
  role         public.shop_role not null check (role <> 'owner'),
  code         text not null unique,
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '7 days',
  accepted_by  uuid references auth.users(id),
  accepted_at  timestamptz,
  revoked_at   timestamptz
);
create index if not exists idx_shop_invitations_shop on public.shop_invitations(shop_id);

alter table public.shop_invitations enable row level security;
drop policy if exists shop_invitations_select_owner on public.shop_invitations;
create policy shop_invitations_select_owner on public.shop_invitations
  for select using (shop_id = public.current_shop_id() and public.current_shop_role() = 'owner');

create or replace function public.create_shop_invitation(p_email text, p_role public.shop_role)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop  uuid;
  v_email text := lower(trim(p_email));
  v_code  text;
  v_hex   text;
begin
  v_shop := public.require_shop_role(array['owner']::public.shop_role[]);
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Adresse email invalide';
  end if;
  if p_role is null or p_role = 'owner' then
    raise exception 'Rôle invalide';
  end if;
  if exists (select 1 from public.profiles where shop_id = v_shop and lower(email) = v_email) then
    raise exception 'Cette personne fait déjà partie de la boutique';
  end if;

  -- Une seule invitation active par email : les précédentes sont annulées
  update public.shop_invitations set revoked_at = now()
  where shop_id = v_shop and lower(email) = v_email and accepted_at is null and revoked_at is null;

  loop
    v_hex  := upper(replace(gen_random_uuid()::text, '-', ''));
    v_code := substr(v_hex, 1, 4) || '-' || substr(v_hex, 5, 4);
    exit when not exists (select 1 from public.shop_invitations where code = v_code);
  end loop;

  insert into public.shop_invitations (shop_id, email, role, code, created_by)
  values (v_shop, v_email, p_role, v_code, auth.uid());
  return v_code;
end;
$$;

create or replace function public.revoke_shop_invitation(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
begin
  v_shop := public.require_shop_role(array['owner']::public.shop_role[]);
  update public.shop_invitations set revoked_at = now()
  where id = p_id and shop_id = v_shop and accepted_at is null and revoked_at is null;
  if not found then
    raise exception 'Invitation introuvable ou déjà utilisée';
  end if;
end;
$$;

-- Appelée par le nouveau membre, connecté, dont le compte n'a pas de boutique.
create or replace function public.accept_shop_invitation(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_inv   public.shop_invitations;
  v_prof  public.profiles;
  v_shop_name text;
begin
  if v_uid is null then
    raise exception 'Authentification requise';
  end if;
  select lower(email) into v_email from auth.users where id = v_uid;

  select * into v_inv from public.shop_invitations
  where code = upper(trim(p_code)) for update;
  if v_inv.id is null or v_inv.revoked_at is not null then
    raise exception 'Code d''invitation invalide';
  end if;
  if v_inv.accepted_at is not null then
    raise exception 'Ce code d''invitation a déjà été utilisé';
  end if;
  if v_inv.expires_at < now() then
    raise exception 'Ce code d''invitation a expiré : demandez-en un nouveau';
  end if;
  -- « is distinct from » : un email introuvable (null) doit aussi être refusé
  if v_email is null or lower(v_inv.email) is distinct from v_email then
    raise exception 'Ce code a été envoyé à une autre adresse email que celle de votre compte';
  end if;

  select * into v_prof from public.profiles where id = v_uid for update;
  if v_prof.id is not null and v_prof.shop_id is not null then
    raise exception 'Ce compte appartient déjà à une boutique';
  end if;

  if v_prof.id is null then
    insert into public.profiles (id, email, display_name, role, shop_id)
    values (v_uid, v_email, split_part(v_email, '@', 1), v_inv.role, v_inv.shop_id);
  else
    update public.profiles set shop_id = v_inv.shop_id, role = v_inv.role where id = v_uid;
  end if;

  update public.shop_invitations set accepted_by = v_uid, accepted_at = now() where id = v_inv.id;

  select name into v_shop_name from public.shops where id = v_inv.shop_id;
  return v_shop_name;
end;
$$;

create or replace function public.set_member_role(p_user_id uuid, p_role public.shop_role)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_prof public.profiles;
begin
  v_shop := public.require_shop_role(array['owner']::public.shop_role[]);
  if p_role is null or p_role = 'owner' then
    raise exception 'Rôle invalide (le transfert de propriété n''est pas géré ici)';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'Vous ne pouvez pas modifier votre propre rôle';
  end if;
  select * into v_prof from public.profiles where id = p_user_id for update;
  if v_prof.id is null or v_prof.shop_id is distinct from v_shop then
    raise exception 'Membre introuvable';
  end if;
  if v_prof.role = 'owner' then
    raise exception 'Le rôle du propriétaire ne peut pas être modifié';
  end if;
  update public.profiles set role = p_role where id = p_user_id;
end;
$$;

-- Retire l'accès : le compte existe toujours mais n'est plus rattaché à la
-- boutique (l'historique — ventes, mouvements — est conservé).
create or replace function public.remove_member(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_prof public.profiles;
begin
  v_shop := public.require_shop_role(array['owner']::public.shop_role[]);
  if p_user_id = auth.uid() then
    raise exception 'Vous ne pouvez pas vous retirer vous-même';
  end if;
  select * into v_prof from public.profiles where id = p_user_id for update;
  if v_prof.id is null or v_prof.shop_id is distinct from v_shop then
    raise exception 'Membre introuvable';
  end if;
  if v_prof.role = 'owner' then
    raise exception 'Le propriétaire ne peut pas être retiré';
  end if;
  update public.profiles set shop_id = null, role = 'vendeur' where id = p_user_id;
end;
$$;

grant execute on function public.create_shop_invitation(text, public.shop_role) to authenticated;
grant execute on function public.revoke_shop_invitation(uuid)                   to authenticated;
grant execute on function public.accept_shop_invitation(text)                   to authenticated;
grant execute on function public.set_member_role(uuid, public.shop_role)        to authenticated;
grant execute on function public.remove_member(uuid)                            to authenticated;

do $$
declare
  v_table text;
begin
  foreach v_table in array array['profiles', 'shop_invitations'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    exception when others then null;
    end;
  end loop;
end $$;
