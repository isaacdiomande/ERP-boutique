-- ============================================================================
-- Migration 002 : inscription self-service d'une nouvelle boutique.
--
-- Problème à éviter : si le client appelait directement
-- `insert into shops (...)` puis `insert into profiles (...)`, un utilisateur
-- malveillant pourrait s'attribuer n'importe quel rôle ou shop_id. On passe
-- donc par une fonction RPC SECURITY DEFINER, appelée UNE SEULE FOIS juste
-- après `supa.auth.signUp()`, qui :
--   1. vérifie que l'utilisateur authentifié n'a pas déjà de profil/shop
--   2. crée la boutique
--   3. crée son profil avec le rôle 'owner', verrouillé côté serveur
--
-- Pré-requis : la migration 001 (shops, shop_role, current_shop_id, etc.)
-- doit déjà être appliquée.
-- ============================================================================

create or replace function public.create_shop_and_owner(p_shop_name text)
returns public.shops
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_existing uuid;
  v_shop     public.shops;
begin
  if v_user_id is null then
    raise exception 'Authentification requise';
  end if;

  if p_shop_name is null or length(trim(p_shop_name)) = 0 then
    raise exception 'Le nom de la boutique est obligatoire';
  end if;

  -- Un compte ne peut créer/posséder sa boutique qu'une seule fois.
  select shop_id into v_existing from public.profiles where id = v_user_id;
  if v_existing is not null then
    raise exception 'Ce compte est déjà associé à une boutique';
  end if;

  insert into public.shops (name, owner_id)
  values (trim(p_shop_name), v_user_id)
  returning * into v_shop;

  -- `profiles` est alimentée par un trigger sur auth.users (voir plus bas) à
  -- la création du compte, avec shop_id NULL et role par défaut 'vendeur'.
  -- On la met ici à jour vers le vrai shop + rôle owner.
  update public.profiles
  set shop_id = v_shop.id, role = 'owner'
  where id = v_user_id;

  return v_shop;
end;
$$;

-- ----------------------------------------------------------------------------
-- Trigger : crée automatiquement une ligne `profiles` dès qu'un compte
-- `auth.users` est créé (signUp), pour que `create_shop_and_owner` ait
-- toujours une ligne à mettre à jour, même sur une inscription normale.
-- ----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)), 'vendeur')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

grant execute on function public.create_shop_and_owner(text) to authenticated;
