-- ============================================================================
-- Migration 001 : passage de "Boutique Stock" (une boutique) à une base
-- multi-tenant (plusieurs boutiques, isolées par shop_id + RLS).
--
-- Hypothèse de départ : les tables existantes `articles`, `movements`,
-- `profiles` n'ont PAS encore de colonne shop_id (version actuelle = une
-- seule boutique, celle d'Isaac). Ce script :
--   1. Crée `shops` et `roles`
--   2. Ajoute `shop_id` aux tables existantes
--   3. Rattache les données déjà présentes à une boutique "legacy" (celle
--      d'Isaac), pour ne rien perdre
--   4. Ajoute le rôle sur `profiles`
--   5. Réécrit les policies RLS pour filtrer par shop_id
--   6. Réécrit `record_movement` pour vérifier le shop_id en plus du rôle
--
-- À exécuter dans l'éditeur SQL Supabase, sur une copie/branche de la base
-- avant de l'appliquer en production. Idempotent autant que possible
-- (IF NOT EXISTS / DROP POLICY IF EXISTS) pour pouvoir le relancer sans tout
-- casser si une étape échoue à mi-chemin.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Table des boutiques
-- ----------------------------------------------------------------------------
create table if not exists public.shops (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  owner_id    uuid not null references auth.users(id) on delete restrict,
  created_at  timestamptz not null default now()
);

comment on table public.shops is 'Une boutique cliente du produit. Chaque boutique est un tenant isolé.';

-- ----------------------------------------------------------------------------
-- 2. Rôles : énumération fermée, cohérente avec le cahier des charges
--    (owner > gérant > comptable > vendeur > livreur)
-- ----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'shop_role') then
    create type public.shop_role as enum ('owner', 'gerant', 'comptable', 'vendeur', 'livreur');
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 3. Ajout de shop_id + role aux tables existantes
-- ----------------------------------------------------------------------------
alter table public.profiles  add column if not exists shop_id uuid references public.shops(id) on delete cascade;
alter table public.profiles  add column if not exists role    public.shop_role not null default 'vendeur';

alter table public.articles  add column if not exists shop_id uuid references public.shops(id) on delete cascade;
alter table public.movements add column if not exists shop_id uuid references public.shops(id) on delete cascade;

-- ----------------------------------------------------------------------------
-- 4. Rattachement des données existantes à une boutique "legacy"
--    (la boutique d'Isaac, pour ne rien perdre lors de la migration)
--
--    Remplacer '<EMAIL_ISAAC>' par l'email réel du compte owner actuel avant
--    d'exécuter cette section.
-- ----------------------------------------------------------------------------
do $$
declare
  v_owner_id uuid;
  v_shop_id  uuid;
begin
  select id into v_owner_id from auth.users where email = '<EMAIL_ISAAC>' limit 1;

  if v_owner_id is null then
    raise notice 'Aucun utilisateur trouvé pour l''email fourni — section 4 ignorée. À traiter manuellement.';
  else
    select id into v_shop_id from public.shops where owner_id = v_owner_id limit 1;

    if v_shop_id is null then
      insert into public.shops (name, owner_id) values ('Boutique Isaac', v_owner_id)
      returning id into v_shop_id;
    end if;

    update public.profiles set shop_id = v_shop_id, role = 'owner' where id = v_owner_id and shop_id is null;
    update public.profiles set shop_id = v_shop_id where shop_id is null; -- autres comptes existants (vendeurs, etc.)
    update public.articles  set shop_id = v_shop_id where shop_id is null;
    update public.movements set shop_id = v_shop_id where shop_id is null;
  end if;
end $$;

-- Une fois toutes les lignes rattachées (vérifier qu'il n'y a plus de NULL),
-- rendre shop_id obligatoire pour les nouvelles lignes :
-- alter table public.articles  alter column shop_id set not null;
-- alter table public.movements alter column shop_id set not null;
-- alter table public.profiles  alter column shop_id set not null;
-- (laissé en commentaire : à activer après vérification manuelle)

-- ----------------------------------------------------------------------------
-- 5. Fonction utilitaire : shop_id de l'utilisateur courant
--    SECURITY DEFINER + search_path figé pour éviter tout contournement RLS
-- ----------------------------------------------------------------------------
create or replace function public.current_shop_id()
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select shop_id from public.profiles where id = auth.uid();
$$;

create or replace function public.current_role()
returns public.shop_role
language sql
security definer
set search_path = public
stable
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ----------------------------------------------------------------------------
-- 6. RLS : activer + policies par shop_id
-- ----------------------------------------------------------------------------
alter table public.shops     enable row level security;
alter table public.profiles  enable row level security;
alter table public.articles  enable row level security;
alter table public.movements enable row level security;

-- shops : un utilisateur ne voit que sa propre boutique
drop policy if exists shops_select_own on public.shops;
create policy shops_select_own on public.shops
  for select using (id = public.current_shop_id());

-- profiles : chacun voit les profils de sa boutique (utile pour lister l'équipe)
drop policy if exists profiles_select_same_shop on public.profiles;
create policy profiles_select_same_shop on public.profiles
  for select using (shop_id = public.current_shop_id());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update using (id = auth.uid());

-- articles : lecture/écriture limitées à la boutique courante
drop policy if exists articles_select_same_shop on public.articles;
create policy articles_select_same_shop on public.articles
  for select using (shop_id = public.current_shop_id());

drop policy if exists articles_insert_same_shop on public.articles;
create policy articles_insert_same_shop on public.articles
  for insert with check (shop_id = public.current_shop_id());

drop policy if exists articles_update_same_shop on public.articles;
create policy articles_update_same_shop on public.articles
  for update using (shop_id = public.current_shop_id())
  with check (shop_id = public.current_shop_id());

drop policy if exists articles_delete_same_shop on public.articles;
create policy articles_delete_same_shop on public.articles
  for delete using (
    shop_id = public.current_shop_id()
    and public.current_role() in ('owner', 'gerant')
  );

-- movements : lecture limitée à la boutique ; écriture directe interdite
-- (tout mouvement passe par record_movement, SECURITY DEFINER, ci-dessous)
drop policy if exists movements_select_same_shop on public.movements;
create policy movements_select_same_shop on public.movements
  for select using (shop_id = public.current_shop_id());

-- ----------------------------------------------------------------------------
-- 7. record_movement : réécrite pour vérifier le shop_id en plus du rôle,
--    afin qu'un vendeur ne puisse jamais faire bouger le stock d'une autre
--    boutique même en falsifiant p_article_id depuis le client.
-- ----------------------------------------------------------------------------
create or replace function public.record_movement(
  p_article_id uuid,
  p_type       text,
  p_qty        numeric
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop_id        uuid := public.current_shop_id();
  v_role           public.shop_role := public.current_role();
  v_article_shop   uuid;
begin
  if v_shop_id is null then
    raise exception 'Aucune boutique associée à cet utilisateur';
  end if;

  select shop_id into v_article_shop from public.articles where id = p_article_id;

  if v_article_shop is null or v_article_shop <> v_shop_id then
    raise exception 'Cet article n''appartient pas à votre boutique';
  end if;

  if p_type = 'reassort' and v_role not in ('owner', 'gerant') then
    raise exception 'Seul un gérant ou le owner peut enregistrer un réassort';
  end if;

  if p_type = 'vente' then
    update public.articles set quantity = quantity - p_qty where id = p_article_id;
  elsif p_type = 'perte' then
    update public.articles set quantity = quantity - p_qty where id = p_article_id;
  elsif p_type = 'reassort' then
    update public.articles set quantity = quantity + p_qty where id = p_article_id;
  else
    raise exception 'Type de mouvement inconnu : %', p_type;
  end if;

  insert into public.movements (article_id, type, qty, shop_id, at)
  values (p_article_id, p_type, p_qty, v_shop_id, now());
end;
$$;

-- ----------------------------------------------------------------------------
-- 8. Index utiles (les requêtes filtrent quasi systématiquement par shop_id)
-- ----------------------------------------------------------------------------
create index if not exists idx_articles_shop_id  on public.articles(shop_id);
create index if not exists idx_movements_shop_id on public.movements(shop_id);
create index if not exists idx_profiles_shop_id  on public.profiles(shop_id);
