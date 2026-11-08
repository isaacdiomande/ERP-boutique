-- ============================================================================
-- Migration 003 : module Clients (phase 2, module 3 du cahier des charges).
--
-- Ajoute :
--   1. Table `customers` (fiche client, compte crédit, segmentation)
--   2. Colonne `customer_id` sur `movements` (pour rattacher une vente à un
--      client existant — optionnel, une vente au comptoir sans client reste
--      possible)
--   3. `record_movement` réécrite pour accepter ce client optionnel et, pour
--      une vente à crédit, incrémenter le solde dû du client
--   4. RLS sur `customers`, cohérente avec le reste (isolation par shop_id)
--
-- Pré-requis : migrations 001 et 002 déjà appliquées.
-- Idempotent autant que possible (IF NOT EXISTS / DROP ... IF EXISTS) pour
-- pouvoir le relancer sans tout casser si une étape échoue à mi-chemin.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Table clients
-- ----------------------------------------------------------------------------
create table if not exists public.customers (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops(id) on delete cascade,
  name         text not null,
  phone        text,
  email        text,
  address      text,
  segment      text,                         -- libre : "fidèle", "grossiste", etc.
  credit_limit numeric not null default 0,    -- plafond de crédit autorisé (0 = pas de crédit)
  credit_balance numeric not null default 0,  -- solde dû actuel (mis à jour par record_movement)
  notes        text,
  created_at   timestamptz not null default now()
);

comment on table public.customers is 'Clients d''une boutique : fiche, historique (via movements.customer_id), compte crédit.';
comment on column public.customers.credit_balance is 'Montant dû par le client, mis à jour automatiquement par record_movement lors d''une vente à crédit ou d''un paiement.';

create index if not exists idx_customers_shop_id on public.customers(shop_id);

alter table public.customers enable row level security;

drop policy if exists customers_select_same_shop on public.customers;
create policy customers_select_same_shop on public.customers
  for select using (shop_id = public.current_shop_id());

drop policy if exists customers_insert_same_shop on public.customers;
create policy customers_insert_same_shop on public.customers
  for insert with check (shop_id = public.current_shop_id());

drop policy if exists customers_update_same_shop on public.customers;
create policy customers_update_same_shop on public.customers
  for update using (shop_id = public.current_shop_id())
  with check (shop_id = public.current_shop_id());

drop policy if exists customers_delete_same_shop on public.customers;
create policy customers_delete_same_shop on public.customers
  for delete using (
    shop_id = public.current_shop_id()
    and public.current_shop_role() in ('owner', 'gerant')
  );

-- ----------------------------------------------------------------------------
-- 2. Rattachement optionnel d'un mouvement à un client
-- ----------------------------------------------------------------------------
alter table public.movements
  add column if not exists customer_id uuid references public.customers(id) on delete set null;

create index if not exists idx_movements_customer_id on public.movements(customer_id);

-- Politique de lecture pour que l'historique d'un client reste filtré par
-- boutique (déjà couvert par movements_select_same_shop existante — rien à
-- ajouter ici, la jointure customer_id ne contourne pas le shop_id).

-- ----------------------------------------------------------------------------
-- 3. Nettoyage d'une dette technique issue de 001 : deux fonctions
--    `record_movement` coexistent actuellement en base avec des signatures
--    différentes —
--      record_movement(uuid, text, integer) : l'originale (avant 001),
--        utilise bien la colonne `qty` qui existe réellement.
--      record_movement(uuid, text, numeric) : créée par 001, référence par
--        erreur une colonne `quantity` qui n'a jamais existé sur `articles`.
--    PostgREST choisit la signature `integer` pour les appels actuels de
--    l'app (c'est pour ça que les ventes fonctionnent normalement malgré le
--    bug), donc la version cassée n'a jamais été exécutée — mais elle reste
--    un piège pour plus tard. On supprime les deux et on recrée une seule
--    fonction propre ci-dessous, avec la bonne colonne `qty`.
-- ----------------------------------------------------------------------------
drop function if exists public.record_movement(uuid, text, integer);
drop function if exists public.record_movement(uuid, text, numeric);

-- ----------------------------------------------------------------------------
-- 4. record_movement (version unique, propre) : ajoute un paramètre
--    p_customer_id optionnel et, pour une vente à crédit (p_on_credit =
--    true), incrémente le solde dû du client au lieu d'exiger un paiement
--    immédiat.
--
--    Les appels existants (sans ces deux nouveaux paramètres) continuent de
--    fonctionner grâce aux valeurs par défaut.
-- ----------------------------------------------------------------------------
create or replace function public.record_movement(
  p_article_id  uuid,
  p_type        text,
  p_qty         numeric,
  p_customer_id uuid default null,
  p_on_credit   boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop_id        uuid := public.current_shop_id();
  v_role           public.shop_role := public.current_shop_role();
  v_article_shop   uuid;
  v_customer_shop  uuid;
  v_sell_price     numeric;
begin
  if v_shop_id is null then
    raise exception 'Aucune boutique associée à cet utilisateur';
  end if;

  select shop_id, sell_price into v_article_shop, v_sell_price
  from public.articles where id = p_article_id;

  if v_article_shop is null or v_article_shop <> v_shop_id then
    raise exception 'Cet article n''appartient pas à votre boutique';
  end if;

  if p_type = 'reassort' and v_role not in ('owner', 'gerant') then
    raise exception 'Seul un gérant ou le owner peut enregistrer un réassort';
  end if;

  if p_customer_id is not null then
    select shop_id into v_customer_shop from public.customers where id = p_customer_id;
    if v_customer_shop is null or v_customer_shop <> v_shop_id then
      raise exception 'Ce client n''appartient pas à votre boutique';
    end if;
  end if;

  if p_type = 'vente' and p_on_credit and p_customer_id is null then
    raise exception 'Une vente à crédit doit être rattachée à un client';
  end if;

  if p_type = 'vente' then
    update public.articles set qty = qty - p_qty where id = p_article_id;
  elsif p_type = 'perte' then
    update public.articles set qty = qty - p_qty where id = p_article_id;
  elsif p_type = 'reassort' then
    update public.articles set qty = qty + p_qty where id = p_article_id;
  else
    raise exception 'Type de mouvement inconnu : %', p_type;
  end if;

  -- Vente à crédit : le client doit maintenant ce montant à la boutique.
  if p_type = 'vente' and p_on_credit then
    update public.customers
    set credit_balance = credit_balance + (p_qty * coalesce(v_sell_price, 0))
    where id = p_customer_id;
  end if;

  insert into public.movements (article_id, type, qty, shop_id, at, customer_id)
  values (p_article_id, p_type, p_qty, v_shop_id, now(), p_customer_id);
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Enregistrer un paiement d'un client sur son solde dû (utilisé quand le
--    client rembourse tout ou partie de son crédit, en dehors d'une vente).
-- ----------------------------------------------------------------------------
create or replace function public.record_customer_payment(
  p_customer_id uuid,
  p_amount      numeric
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop_id       uuid := public.current_shop_id();
  v_customer_shop uuid;
begin
  if v_shop_id is null then
    raise exception 'Aucune boutique associée à cet utilisateur';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Le montant du paiement doit être positif';
  end if;

  select shop_id into v_customer_shop from public.customers where id = p_customer_id;
  if v_customer_shop is null or v_customer_shop <> v_shop_id then
    raise exception 'Ce client n''appartient pas à votre boutique';
  end if;

  update public.customers
  set credit_balance = greatest(0, credit_balance - p_amount)
  where id = p_customer_id;
end;
$$;

grant execute on function public.record_customer_payment(uuid, numeric) to authenticated;
