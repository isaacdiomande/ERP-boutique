-- ============================================================================
-- Migration 009 : module Trésorerie (phase 3, module 8).
--
-- Principe : la trésorerie n'est pas ressaisie, elle REGROUPE par compte les
-- flux d'argent déjà enregistrés par l'app :
--   + ventes au comptoir (prix et moyen de paiement désormais mémorisés)
--   + paiements de factures (y compris ceux faits à la livraison)
--   + encaissements de livraison hors facture (et frais de livraison)
--   + paiements sur crédit comptoir (désormais historisés)
--   − remboursements de retours
--   − paiements fournisseurs
--   ± écritures manuelles (dépenses, recettes, transferts entre comptes)
--
-- Comptes : caisse, banque, Orange Money, MTN, Moov, Wave (+ comptes libres).
-- Un moyen de paiement est rattaché au compte par défaut de son type
-- (espèces -> caisse, chèque -> banque, autre -> caisse).
--
-- Démarrage : l'historique ancien ne contient ni le prix exact ni le moyen
-- de paiement des ventes comptoir. La boutique choisit une DATE DE DÉPART et
-- saisit le solde réel de chaque compte à cette date ; seuls les flux
-- postérieurs sont comptés.
--
-- Accès : owner / gérant / comptable (cahier des charges : pas le vendeur).
-- Pré-requis : migrations 001 à 008 appliquées. Relançable sans casse.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Données complémentaires sur les flux existants
-- ----------------------------------------------------------------------------
alter table public.shops add column if not exists treasury_start_date date;

-- Ventes comptoir : prix unitaire, vente à crédit, moyen de paiement
alter table public.movements add column if not exists unit_price numeric;
alter table public.movements add column if not exists on_credit boolean not null default false;
alter table public.movements add column if not exists payment_method text;
alter table public.movements drop constraint if exists movements_payment_method_check;
alter table public.movements add constraint movements_payment_method_check
  check (payment_method is null or payment_method in ('especes', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'banque', 'cheque', 'autre'));

-- Livraisons : part de l'encaissement reportée sur la facture (évite le
-- double comptage facture + livraison dans la trésorerie)
alter table public.deliveries add column if not exists invoice_paid_amount numeric not null default 0;
update public.deliveries d
set invoice_paid_amount = coalesce((
  select sum(p.amount) from public.invoice_payments p
  where p.document_id = d.source_document_id and p.reference like 'Livraison ' || d.number || '%'
), 0)
where d.status = 'livree' and d.source_document_id is not null and d.invoice_paid_amount = 0;

-- Paiements sur crédit comptoir (historique, jusqu'ici seul le solde existait)
create table if not exists public.customer_payments (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops(id) on delete cascade,
  customer_id  uuid references public.customers(id) on delete set null,
  amount       numeric not null check (amount > 0),
  method       text not null default 'especes' check (method in ('especes', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'banque', 'cheque', 'autre')),
  reference    text,
  paid_at      timestamptz not null default now(),
  created_by   uuid references auth.users(id)
);
create index if not exists idx_customer_payments_shop on public.customer_payments(shop_id);
alter table public.customer_payments enable row level security;
drop policy if exists customer_payments_select on public.customer_payments;
create policy customer_payments_select on public.customer_payments
  for select using (shop_id = public.current_shop_id());

-- ----------------------------------------------------------------------------
-- 2. Comptes et écritures manuelles
-- ----------------------------------------------------------------------------
create table if not exists public.treasury_accounts (
  id               uuid primary key default gen_random_uuid(),
  shop_id          uuid not null references public.shops(id) on delete cascade,
  name             text not null,
  kind             text not null check (kind in ('caisse', 'banque', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'autre')),
  opening_balance  numeric not null default 0,
  is_default       boolean not null default false,  -- compte qui reçoit les paiements de ce type
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);
create unique index if not exists uq_treasury_default_kind on public.treasury_accounts(shop_id, kind) where is_default;
create index if not exists idx_treasury_accounts_shop on public.treasury_accounts(shop_id);

create table if not exists public.treasury_entries (
  id              uuid primary key default gen_random_uuid(),
  shop_id         uuid not null references public.shops(id) on delete cascade,
  account_id      uuid not null references public.treasury_accounts(id) on delete restrict,
  amount          numeric not null check (amount <> 0),   -- positif = entrée, négatif = sortie
  category        text not null,
  label           text,
  reference       text,
  transfer_group  uuid,                                   -- les 2 lignes d'un transfert
  occurred_at     timestamptz not null default now(),
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now()
);
create index if not exists idx_treasury_entries_shop on public.treasury_entries(shop_id);

alter table public.treasury_accounts enable row level security;
alter table public.treasury_entries  enable row level security;

drop policy if exists treasury_accounts_select on public.treasury_accounts;
create policy treasury_accounts_select on public.treasury_accounts
  for select using (shop_id = public.current_shop_id() and public.current_shop_role() in ('owner', 'gerant', 'comptable'));

drop policy if exists treasury_entries_select on public.treasury_entries;
create policy treasury_entries_select on public.treasury_entries
  for select using (shop_id = public.current_shop_id() and public.current_shop_role() in ('owner', 'gerant', 'comptable'));

-- ----------------------------------------------------------------------------
-- 3. Journal unifié (vue, droits de l'utilisateur appliqués)
-- ----------------------------------------------------------------------------
create or replace function public.method_account_kind(p_method text)
returns text
language sql
immutable
as $$
  select case coalesce(p_method, 'especes')
    when 'especes' then 'caisse'
    when 'cheque' then 'banque'
    when 'autre' then 'caisse'
    else p_method end;
$$;

drop view if exists public.treasury_ledger;
create view public.treasury_ledger with (security_invoker = true) as
with flows as (
  -- Ventes au comptoir (hors crédit, hors ventes issues d'une facture)
  select m.shop_id, m.at as occurred_at, 'vente_comptoir'::text as source, m.id as source_id,
         'Vente comptoir — ' || coalesce(a.name, 'article') || ' × ' || m.qty as label,
         coalesce(m.payment_method, 'especes') as method, (m.qty * m.unit_price) as amount,
         null::uuid as account_id, null::text as category
  from public.movements m
  left join public.articles a on a.id = m.article_id
  where m.type = 'vente' and m.document_id is null and not m.on_credit and m.unit_price is not null
  union all
  select p.shop_id, p.paid_at, 'facture', p.id,
         'Paiement facture ' || coalesce(d.number, '') || coalesce(' — ' || d.customer_name, ''),
         p.method, p.amount, null, null
  from public.invoice_payments p
  left join public.sales_documents d on d.id = p.document_id
  union all
  select dl.shop_id, dl.delivered_at, 'livraison', dl.id,
         'Encaissement livraison ' || dl.number || ' — ' || dl.customer_name,
         dl.collected_method, dl.collected_amount - dl.invoice_paid_amount, null, null
  from public.deliveries dl
  where dl.status = 'livree' and dl.collected_amount - dl.invoice_paid_amount > 0
  union all
  select cp.shop_id, cp.paid_at, 'credit_client', cp.id,
         'Paiement crédit comptoir' || coalesce(' — ' || c.name, ''),
         cp.method, cp.amount, null, null
  from public.customer_payments cp
  left join public.customers c on c.id = cp.customer_id
  union all
  select r.shop_id, r.created_at, 'remboursement', r.id,
         'Remboursement ' || r.number || coalesce(' — ' || r.customer_name, ''),
         r.refund_method, -r.refund_amount, null, null
  from public.returns r
  where r.refund_type = 'remboursement' and r.refund_amount > 0
  union all
  select sp.shop_id, sp.paid_at, 'fournisseur', sp.id,
         'Paiement fournisseur ' || coalesce(po.number, '') || coalesce(' — ' || po.supplier_name, ''),
         sp.method, -sp.amount, null, null
  from public.supplier_payments sp
  left join public.purchase_orders po on po.id = sp.po_id
  union all
  select e.shop_id, e.occurred_at, case when e.transfer_group is null then 'manuel' else 'transfert' end, e.id,
         coalesce(e.label, e.category), null, e.amount, e.account_id, e.category
  from public.treasury_entries e
)
select f.shop_id, f.occurred_at, f.source, f.source_id, f.label, f.method, f.amount, f.category,
       coalesce(f.account_id, acc.id) as account_id
from flows f
join public.shops s on s.id = f.shop_id
left join public.treasury_accounts acc
  on acc.shop_id = f.shop_id and acc.is_default and acc.kind = public.method_account_kind(f.method) and f.account_id is null
where f.shop_id = public.current_shop_id()
  and public.current_shop_role() in ('owner', 'gerant', 'comptable')
  and s.treasury_start_date is not null
  and f.occurred_at >= s.treasury_start_date::timestamp at time zone 'UTC';

-- Soldes par compte
create or replace function public.treasury_balances()
returns table (account_id uuid, name text, kind text, opening_balance numeric, flows numeric, balance numeric, is_default boolean, active boolean)
language sql
stable
security invoker
set search_path = public
as $$
  select a.id, a.name, a.kind, a.opening_balance,
         coalesce(sum(l.amount), 0),
         a.opening_balance + coalesce(sum(l.amount), 0),
         a.is_default, a.active
  from public.treasury_accounts a
  left join public.treasury_ledger l on l.account_id = a.id
  where a.shop_id = public.current_shop_id()
  group by a.id
  order by case a.kind when 'caisse' then 0 when 'orange_money' then 1 when 'wave' then 2 when 'mtn_money' then 3 when 'moov_money' then 4 when 'banque' then 5 else 6 end, a.name;
$$;

-- ----------------------------------------------------------------------------
-- 4. RPC trésorerie
-- ----------------------------------------------------------------------------

-- Configuration initiale (ou modification de la date de départ / des soldes)
-- p_accounts : [{kind, name, opening_balance}, ...]
create or replace function public.setup_treasury(p_start_date date, p_accounts jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_acc  jsonb;
  v_kind text;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);
  if p_start_date is null then
    raise exception 'La date de départ est obligatoire';
  end if;
  if p_start_date > current_date then
    raise exception 'La date de départ ne peut pas être dans le futur';
  end if;
  update public.shops set treasury_start_date = p_start_date where id = v_shop;

  for v_acc in select * from jsonb_array_elements(coalesce(p_accounts, '[]'::jsonb)) loop
    v_kind := v_acc->>'kind';
    if v_kind not in ('caisse', 'banque', 'orange_money', 'mtn_money', 'moov_money', 'wave') then
      raise exception 'Type de compte invalide : %', v_kind;
    end if;
    if exists (select 1 from public.treasury_accounts where shop_id = v_shop and kind = v_kind and is_default) then
      update public.treasury_accounts
      set opening_balance = coalesce((v_acc->>'opening_balance')::numeric, 0),
          name = coalesce(nullif(trim(v_acc->>'name'), ''), name)
      where shop_id = v_shop and kind = v_kind and is_default;
    else
      insert into public.treasury_accounts (shop_id, name, kind, opening_balance, is_default)
      values (v_shop, coalesce(nullif(trim(v_acc->>'name'), ''), v_kind), v_kind,
              coalesce((v_acc->>'opening_balance')::numeric, 0), true);
    end if;
  end loop;
end;
$$;

-- Dépense (montant négatif) ou recette (positif) manuelle
create or replace function public.add_treasury_entry(
  p_account_id uuid,
  p_amount     numeric,
  p_category   text,
  p_label      text default null,
  p_reference  text default null,
  p_date       date default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_acc  public.treasury_accounts;
  v_id   uuid;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);
  select * into v_acc from public.treasury_accounts where id = p_account_id;
  if v_acc.id is null or v_acc.shop_id <> v_shop then
    raise exception 'Compte introuvable';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception 'Le montant doit être différent de zéro';
  end if;
  if p_category is null or length(trim(p_category)) = 0 then
    raise exception 'La catégorie est obligatoire';
  end if;
  if p_date is not null and p_date > current_date then
    raise exception 'La date ne peut pas être dans le futur';
  end if;
  insert into public.treasury_entries (shop_id, account_id, amount, category, label, reference, occurred_at, created_by)
  values (v_shop, p_account_id, p_amount, trim(p_category), nullif(trim(p_label), ''), nullif(trim(p_reference), ''),
          case when p_date is null or p_date = current_date then now() else p_date::timestamp + interval '12 hours' end,
          auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- Transfert entre deux comptes (ex. dépôt d'espèces en banque)
create or replace function public.add_treasury_transfer(
  p_from   uuid,
  p_to     uuid,
  p_amount numeric,
  p_label  text default null,
  p_date   date default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop  uuid;
  v_from  public.treasury_accounts;
  v_to    public.treasury_accounts;
  v_group uuid := gen_random_uuid();
  v_at    timestamptz;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);
  select * into v_from from public.treasury_accounts where id = p_from;
  select * into v_to   from public.treasury_accounts where id = p_to;
  if v_from.id is null or v_to.id is null or v_from.shop_id <> v_shop or v_to.shop_id <> v_shop then
    raise exception 'Compte introuvable';
  end if;
  if p_from = p_to then
    raise exception 'Choisissez deux comptes différents';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Le montant doit être positif';
  end if;
  if p_date is not null and p_date > current_date then
    raise exception 'La date ne peut pas être dans le futur';
  end if;
  v_at := case when p_date is null or p_date = current_date then now() else p_date::timestamp + interval '12 hours' end;
  insert into public.treasury_entries (shop_id, account_id, amount, category, label, transfer_group, occurred_at, created_by) values
    (v_shop, p_from, -p_amount, 'Transfert', coalesce(nullif(trim(p_label), ''), 'Transfert vers ' || v_to.name), v_group, v_at, auth.uid()),
    (v_shop, p_to,    p_amount, 'Transfert', coalesce(nullif(trim(p_label), ''), 'Transfert depuis ' || v_from.name), v_group, v_at, auth.uid());
  return v_group;
end;
$$;

-- Suppression d'une écriture manuelle (et de sa jumelle si transfert)
create or replace function public.delete_treasury_entry(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_e    public.treasury_entries;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant']::public.shop_role[]);
  select * into v_e from public.treasury_entries where id = p_id;
  if v_e.id is null or v_e.shop_id <> v_shop then
    raise exception 'Écriture introuvable';
  end if;
  if v_e.transfer_group is not null then
    delete from public.treasury_entries where transfer_group = v_e.transfer_group and shop_id = v_shop;
  else
    delete from public.treasury_entries where id = p_id;
  end if;
end;
$$;

-- Compte supplémentaire / renommage / solde de départ / désactivation
create or replace function public.save_treasury_account(
  p_id              uuid,
  p_name            text,
  p_kind            text,
  p_opening_balance numeric,
  p_active          boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_acc  public.treasury_accounts;
  v_id   uuid;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Le nom du compte est obligatoire';
  end if;
  if p_id is null then
    if p_kind not in ('caisse', 'banque', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'autre') then
      raise exception 'Type de compte invalide';
    end if;
    insert into public.treasury_accounts (shop_id, name, kind, opening_balance, is_default, active)
    values (v_shop, trim(p_name), p_kind, coalesce(p_opening_balance, 0), false, coalesce(p_active, true))
    returning id into v_id;
  else
    select * into v_acc from public.treasury_accounts where id = p_id for update;
    if v_acc.id is null or v_acc.shop_id <> v_shop then
      raise exception 'Compte introuvable';
    end if;
    if v_acc.is_default and p_active = false then
      raise exception 'Le compte principal d''un moyen de paiement ne peut pas être désactivé';
    end if;
    update public.treasury_accounts
    set name = trim(p_name), opening_balance = coalesce(p_opening_balance, 0), active = coalesce(p_active, true)
    where id = p_id;
    v_id := p_id;
  end if;
  return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. record_movement : mémorise prix unitaire, vente à crédit et moyen de
--    paiement (pour la trésorerie). Ancienne signature remplacée.
-- ----------------------------------------------------------------------------
drop function if exists public.record_movement(uuid, text, numeric, uuid, boolean);
create or replace function public.record_movement(
  p_article_id  uuid,
  p_type        text,
  p_qty         numeric,
  p_customer_id uuid default null,
  p_on_credit   boolean default false,
  p_method      text default null
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
  v_by             text;
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

  if p_type = 'vente' and p_on_credit then
    update public.customers
    set credit_balance = credit_balance + (p_qty * coalesce(v_sell_price, 0))
    where id = p_customer_id;
  end if;

  select coalesce(display_name, email) into v_by from public.profiles where id = auth.uid();

  if p_type = 'vente' and not coalesce(p_on_credit, false)
     and p_method is not null and p_method not in ('especes', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'banque', 'cheque', 'autre') then
    raise exception 'Moyen de paiement invalide';
  end if;

  insert into public.movements (article_id, type, qty, by_name, shop_id, at, customer_id, unit_price, on_credit, payment_method)
  values (p_article_id, p_type, p_qty, v_by, v_shop_id, now(), p_customer_id,
          case when p_type = 'vente' then v_sell_price end,
          p_type = 'vente' and coalesce(p_on_credit, false),
          case when p_type = 'vente' and not coalesce(p_on_credit, false) then coalesce(p_method, 'especes') end);
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. Paiement sur crédit comptoir : moyen + référence, et historique
-- ----------------------------------------------------------------------------
drop function if exists public.record_customer_payment(uuid, numeric);
create or replace function public.record_customer_payment(
  p_customer_id uuid,
  p_amount      numeric,
  p_method      text default 'especes',
  p_reference   text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_cust public.customers;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable', 'vendeur']::public.shop_role[]);
  if p_amount is null or p_amount <= 0 then
    raise exception 'Le montant du paiement doit être positif';
  end if;
  if coalesce(p_method, 'especes') not in ('especes', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'banque', 'cheque', 'autre') then
    raise exception 'Moyen de paiement invalide';
  end if;
  select * into v_cust from public.customers where id = p_customer_id for update;
  if v_cust.id is null or v_cust.shop_id <> v_shop then
    raise exception 'Ce client n''appartient pas à votre boutique';
  end if;
  if p_amount > v_cust.credit_balance then
    raise exception 'Le montant dépasse le crédit dû par ce client (%)', v_cust.credit_balance;
  end if;
  update public.customers set credit_balance = credit_balance - p_amount where id = p_customer_id;
  insert into public.customer_payments (shop_id, customer_id, amount, method, reference, created_by)
  values (v_shop, p_customer_id, p_amount, coalesce(p_method, 'especes'), nullif(trim(p_reference), ''), auth.uid());
end;
$$;

-- ----------------------------------------------------------------------------
-- 7. set_delivery_status : reprise de 008 + mémorise la part reportée sur la
--    facture (invoice_paid_amount)
-- ----------------------------------------------------------------------------
create or replace function public.set_delivery_status(
  p_id        uuid,
  p_status    text,
  p_reason    text default null,
  p_amount    numeric default 0,
  p_method    text default null,
  p_reference text default null,
  p_new_date  date default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop     uuid := public.current_shop_id();
  v_role     public.shop_role := public.current_shop_role();
  v_del      public.deliveries;
  v_doc      public.sales_documents;
  v_is_mine  boolean;
  v_is_mgr   boolean;
  v_amount   numeric := coalesce(p_amount, 0);
  v_to_invoice numeric;
begin
  if v_shop is null then
    raise exception 'Aucune boutique associée à cet utilisateur';
  end if;
  select * into v_del from public.deliveries where id = p_id for update;
  if v_del.id is null or v_del.shop_id <> v_shop then
    raise exception 'Livraison introuvable';
  end if;

  v_is_mine := v_del.assigned_to = auth.uid();
  v_is_mgr  := v_role in ('owner', 'gerant', 'comptable', 'vendeur');
  if not v_is_mine and not v_is_mgr then
    raise exception 'Cette livraison ne vous est pas assignée';
  end if;

  if p_status = 'en_cours' then
    if v_del.status <> 'a_livrer' then
      raise exception 'Seule une livraison « à livrer » peut partir';
    end if;
    update public.deliveries
    set status = 'en_cours', started_at = now(), attempts = attempts + 1, updated_at = now()
    where id = p_id;

  elsif p_status = 'livree' then
    if v_del.status not in ('a_livrer', 'en_cours') then
      raise exception 'Cette livraison ne peut pas être marquée livrée';
    end if;
    if v_amount < 0 or v_amount > v_del.amount_to_collect then
      raise exception 'Le montant encaissé doit être compris entre 0 et % (montant à encaisser)', v_del.amount_to_collect;
    end if;
    if v_amount > 0 and (p_method is null or p_method not in ('especes', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'banque', 'cheque', 'autre')) then
      raise exception 'Indiquez le moyen de paiement utilisé par le client';
    end if;

    -- Paiement sur la facture d'origine (les frais de livraison n'en font pas partie)
    if v_amount > 0 and v_del.source_document_id is not null then
      select * into v_doc from public.sales_documents where id = v_del.source_document_id for update;
      if v_doc.id is not null and v_doc.status = 'emise' then
        v_to_invoice := least(greatest(v_amount - v_del.delivery_fee, 0),
                              v_doc.total_ttc - v_doc.amount_paid - v_doc.credited_amount);
        if v_to_invoice > 0 then
          insert into public.invoice_payments (shop_id, document_id, amount, method, reference, created_by)
          values (v_shop, v_doc.id, v_to_invoice, p_method,
                  trim(concat_ws(' · ', 'Livraison ' || v_del.number, nullif(trim(p_reference), ''))), auth.uid());
          update public.sales_documents set amount_paid = amount_paid + v_to_invoice, updated_at = now()
          where id = v_doc.id;
        end if;
      end if;
    end if;

    update public.deliveries
    set status = 'livree', delivered_at = now(),
        attempts = case when status = 'a_livrer' then attempts + 1 else attempts end,
        collected_amount = v_amount,
        collected_method = case when v_amount > 0 then p_method end,
        collected_reference = case when v_amount > 0 then nullif(trim(p_reference), '') end,
        invoice_paid_amount = coalesce(v_to_invoice, 0),
        failure_reason = null, updated_at = now()
    where id = p_id;

  elsif p_status = 'echec' then
    if v_del.status not in ('a_livrer', 'en_cours') then
      raise exception 'Cette livraison ne peut pas être marquée en échec';
    end if;
    if p_reason is null or length(trim(p_reason)) = 0 then
      raise exception 'Le motif de l''échec est obligatoire';
    end if;
    update public.deliveries
    set status = 'echec', failure_reason = trim(p_reason),
        attempts = case when status = 'a_livrer' then attempts + 1 else attempts end,
        updated_at = now()
    where id = p_id;

  elsif p_status = 'a_livrer' then
    if v_del.status <> 'echec' then
      raise exception 'Seule une livraison en échec peut être reprogrammée';
    end if;
    update public.deliveries
    set status = 'a_livrer', scheduled_date = coalesce(p_new_date, scheduled_date), updated_at = now()
    where id = p_id;

  elsif p_status = 'annulee' then
    if v_role not in ('owner', 'gerant') then
      raise exception 'Seul le propriétaire ou le gérant peut annuler une livraison';
    end if;
    if v_del.status in ('livree', 'annulee') then
      raise exception 'Une livraison livrée ou déjà annulée ne peut pas être annulée';
    end if;
    if p_reason is null or length(trim(p_reason)) = 0 then
      raise exception 'Le motif d''annulation est obligatoire';
    end if;
    update public.deliveries
    set status = 'annulee', failure_reason = trim(p_reason), updated_at = now()
    where id = p_id;

  else
    raise exception 'Statut inconnu : %', p_status;
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 8. Droits et temps réel
-- ----------------------------------------------------------------------------
grant execute on function public.record_movement(uuid, text, numeric, uuid, boolean, text) to authenticated;
grant execute on function public.record_customer_payment(uuid, numeric, text, text) to authenticated;
grant execute on function public.set_delivery_status(uuid, text, text, numeric, text, text, date) to authenticated;
grant execute on function public.setup_treasury(date, jsonb) to authenticated;
grant execute on function public.add_treasury_entry(uuid, numeric, text, text, text, date) to authenticated;
grant execute on function public.add_treasury_transfer(uuid, uuid, numeric, text, date) to authenticated;
grant execute on function public.delete_treasury_entry(uuid) to authenticated;
grant execute on function public.save_treasury_account(uuid, text, text, numeric, boolean) to authenticated;
grant execute on function public.treasury_balances() to authenticated;
grant select on public.treasury_ledger to authenticated;

do $$
declare
  v_table text;
begin
  foreach v_table in array array['treasury_accounts', 'treasury_entries', 'customer_payments'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    exception when others then null;
    end;
  end loop;
end $$;
