-- ============================================================================
-- Migration 012 : correctif inscription avec confirmation d'email.
--
-- 1. Un utilisateur peut toujours lire SA propre fiche (profiles), même quand
--    il n'est rattaché à aucune boutique (inscription en attente, compte
--    invité, membre retiré). La seule règle de lecture était « même boutique »,
--    or un compte sans boutique n'en a pas : l'app affichait « Votre compte
--    n'a pas de profil associé ». Une ancienne règle de l'app web masquait le
--    problème ; la 011 l'a supprimée.
-- 2. create_shop_and_owner crée la fiche si elle n'existe pas (compte créé
--    avant le trigger, ou trigger absent) au lieu d'échouer silencieusement.
--
-- Pré-requis : migrations 001 à 011. Relançable sans casse.
-- ============================================================================

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select using (id = auth.uid());

create or replace function public.create_shop_and_owner(p_shop_name text)
returns public.shops
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_email    text;
  v_existing uuid;
  v_shop     public.shops;
begin
  if v_user_id is null then
    raise exception 'Authentification requise';
  end if;
  if p_shop_name is null or length(trim(p_shop_name)) = 0 then
    raise exception 'Le nom de la boutique est obligatoire';
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

  return v_shop;
end;
$$;
revoke execute on function public.create_shop_and_owner(text) from public, anon;
grant execute on function public.create_shop_and_owner(text) to authenticated;

notify pgrst, 'reload schema';
