-- ============================================================================
-- Migration 004 : module Devis & facturation (phase 2, module 2).
--
-- Contexte réglementaire (Côte d'Ivoire, 2025-2026) : la facture fiscalement
-- opposable est la Facture Normalisée Électronique (FNE), validée par la DGI
-- qui y appose QR code, sceau et numéro fiscal. Cette app ne peut pas générer
-- ces marqueurs elle-même. Les factures gérées ici sont donc des documents de
-- gestion (numérotation interne, TVA, paiements, stock), avec un champ
-- `fne_number` pour rattacher la FNE émise sur la plateforme DGI. Une future
-- intégration API DGI pourra s'appuyer sur cette même structure.
--
-- Ajoute :
--   1. Infos fiscales de la boutique (en-tête des documents, TVA)
--   2. Compteurs de numérotation séquentielle (par boutique, type, année)
--   3. sales_documents (devis + factures), lignes, paiements
--   4. RPC : save / issue / convert / payment / cancel / FNE / réglages
--   5. Correction : record_movement renseigne à nouveau `by_name`
--
-- Toute écriture passe par des fonctions SECURITY DEFINER (aucune policy
-- insert/update/delete côté client) : une facture émise ne peut pas être
-- modifiée en douce, et la numérotation ne peut pas être falsifiée.
--
-- Pré-requis : migrations 001, 002 et 003 appliquées.
-- Relançable sans casse (IF NOT EXISTS / OR REPLACE / DROP ... IF EXISTS).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Infos fiscales de la boutique
-- ----------------------------------------------------------------------------
alter table public.shops add column if not exists legal_name     text;
alter table public.shops add column if not exists address        text;
alter table public.shops add column if not exists phone          text;
alter table public.shops add column if not exists email          text;
alter table public.shops add column if not exists ncc            text;  -- Numéro de Compte Contribuable
alter table public.shops add column if not exists rccm           text;
alter table public.shops add column if not exists tax_regime     text;  -- RNI / RSI / RME / TEE...
alter table public.shops add column if not exists vat_applicable boolean not null default true;
alter table public.shops add column if not exists vat_rate       numeric not null default 18;
alter table public.shops add column if not exists invoice_footer text;

-- ----------------------------------------------------------------------------
-- 2. Compteurs de numérotation (accès uniquement via fonctions)
-- ----------------------------------------------------------------------------
create table if not exists public.document_counters (
  shop_id     uuid not null references public.shops(id) on delete cascade,
  doc_type    text not null,
  year        int  not null,
  last_number int  not null default 0,
  primary key (shop_id, doc_type, year)
);
alter table public.document_counters enable row level security;

-- ----------------------------------------------------------------------------
-- 3. Documents de vente
-- ----------------------------------------------------------------------------
create table if not exists public.sales_documents (
  id               uuid primary key default gen_random_uuid(),
  shop_id          uuid not null references public.shops(id) on delete cascade,
  doc_type         text not null check (doc_type in ('devis', 'facture')),
  number           text,
  status           text not null,
  customer_id      uuid references public.customers(id) on delete set null,
  customer_name    text,   -- copie figée au moment du document
  customer_phone   text,
  issue_date       date,
  valid_until      date,   -- devis
  due_date         date,   -- facture
  vat_applicable   boolean not null default true,
  vat_rate         numeric not null default 18,
  total_ht         numeric not null default 0,
  total_vat        numeric not null default 0,
  total_ttc        numeric not null default 0,
  amount_paid      numeric not null default 0,
  source_quote_id  uuid references public.sales_documents(id) on delete set null,
  stock_applied    boolean not null default false,
  notes            text,
  fne_number       text,
  fne_recorded_at  timestamptz,
  cancel_reason    text,
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint sales_documents_status_check check (
    (doc_type = 'devis'   and status in ('en_attente', 'accepte', 'refuse', 'converti'))
    or
    (doc_type = 'facture' and status in ('brouillon', 'emise', 'annulee'))
  ),
  constraint sales_documents_number_unique unique (shop_id, number)
);
create index if not exists idx_sales_documents_shop     on public.sales_documents(shop_id);
create index if not exists idx_sales_documents_customer on public.sales_documents(customer_id);

create table if not exists public.sales_document_lines (
  id              uuid primary key default gen_random_uuid(),
  document_id     uuid not null references public.sales_documents(id) on delete cascade,
  shop_id         uuid not null references public.shops(id) on delete cascade,
  position        int  not null default 0,
  article_id      uuid references public.articles(id) on delete set null,
  description     text not null,
  qty             integer not null check (qty > 0),
  unit_price_ttc  numeric not null check (unit_price_ttc >= 0),
  line_total_ttc  numeric not null
);
create index if not exists idx_sales_document_lines_doc on public.sales_document_lines(document_id);

create table if not exists public.invoice_payments (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops(id) on delete cascade,
  document_id  uuid not null references public.sales_documents(id) on delete restrict,
  amount       numeric not null check (amount > 0),
  method       text not null check (method in ('especes', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'banque', 'cheque', 'autre')),
  reference    text,
  paid_at      timestamptz not null default now(),
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now()
);
create index if not exists idx_invoice_payments_doc on public.invoice_payments(document_id);

-- Traçabilité : un mouvement de stock peut provenir d'une facture
alter table public.movements
  add column if not exists document_id uuid references public.sales_documents(id) on delete set null;

-- Le type 'retour' est utilisé par l'annulation de facture (et le futur
-- module Retours). Si une contrainte CHECK limite movements.type, on
-- l'élargit ; sinon rien à faire.
do $$
declare
  v_con record;
begin
  for v_con in
    select conname from pg_constraint
    where conrelid = 'public.movements'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%type%'
  loop
    execute format('alter table public.movements drop constraint %I', v_con.conname);
  end loop;
end $$;
alter table public.movements drop constraint if exists movements_type_check;
alter table public.movements
  add constraint movements_type_check check (type in ('vente', 'reassort', 'perte', 'retour'));

-- ----------------------------------------------------------------------------
-- RLS : lecture limitée à la boutique ; aucune écriture directe
-- ----------------------------------------------------------------------------
alter table public.sales_documents      enable row level security;
alter table public.sales_document_lines enable row level security;
alter table public.invoice_payments     enable row level security;

drop policy if exists sales_documents_select_same_shop on public.sales_documents;
create policy sales_documents_select_same_shop on public.sales_documents
  for select using (shop_id = public.current_shop_id());

drop policy if exists sales_document_lines_select_same_shop on public.sales_document_lines;
create policy sales_document_lines_select_same_shop on public.sales_document_lines
  for select using (shop_id = public.current_shop_id());

drop policy if exists invoice_payments_select_same_shop on public.invoice_payments;
create policy invoice_payments_select_same_shop on public.invoice_payments
  for select using (shop_id = public.current_shop_id());

-- ----------------------------------------------------------------------------
-- 4. Fonctions internes
-- ----------------------------------------------------------------------------
create or replace function public.require_shop_role(p_roles public.shop_role[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid := public.current_shop_id();
  v_role public.shop_role := public.current_shop_role();
begin
  if v_shop is null then
    raise exception 'Aucune boutique associée à cet utilisateur';
  end if;
  if v_role is null or not (v_role = any (p_roles)) then
    raise exception 'Action non autorisée pour votre rôle';
  end if;
  return v_shop;
end;
$$;

create or replace function public.next_document_number(p_shop uuid, p_type text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year   int := extract(year from now())::int;
  v_n      int;
  v_prefix text;
begin
  -- Atomique : deux émissions simultanées ne peuvent pas obtenir le même numéro.
  insert into public.document_counters (shop_id, doc_type, year, last_number)
  values (p_shop, p_type, v_year, 1)
  on conflict (shop_id, doc_type, year)
  do update set last_number = public.document_counters.last_number + 1
  returning last_number into v_n;

  v_prefix := case p_type when 'devis' then 'DEV' when 'facture' then 'FAC' else upper(p_type) end;
  return v_prefix || '-' || v_year || '-' || lpad(v_n::text, 5, '0');
end;
$$;

create or replace function public.recompute_document_totals(p_doc uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ttc  numeric;
  v_ht   numeric;
  v_rate numeric;
  v_app  boolean;
begin
  select coalesce(sum(line_total_ttc), 0) into v_ttc
  from public.sales_document_lines where document_id = p_doc;

  select vat_rate, vat_applicable into v_rate, v_app
  from public.sales_documents where id = p_doc;

  -- Les prix saisis sont TTC (prix affichés en boutique) ; on en déduit le HT
  -- sur le total du document, pour éviter les écarts d'arrondi ligne à ligne.
  if v_app and v_rate > 0 then
    v_ht := round(v_ttc / (1 + v_rate / 100));
  else
    v_ht := v_ttc;
  end if;

  update public.sales_documents
  set total_ttc = v_ttc, total_ht = v_ht, total_vat = v_ttc - v_ht, updated_at = now()
  where id = p_doc;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. RPC publiques
-- ----------------------------------------------------------------------------

-- Crée (p_id null) ou modifie un devis en attente / une facture brouillon.
-- p_lines : [{article_id?, description?, qty, unit_price_ttc}, ...]
create or replace function public.save_sales_document(
  p_id            uuid,
  p_doc_type      text,
  p_customer_id   uuid,
  p_customer_name text,
  p_lines         jsonb,
  p_notes         text default null,
  p_valid_until   date default null,
  p_due_date      date default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop     uuid;
  v_shopinfo public.shops;
  v_cust     public.customers;
  v_doc      public.sales_documents;
  v_id       uuid;
  v_line     jsonb;
  v_pos      int := 0;
  v_art      uuid;
  v_art_shop uuid;
  v_art_name text;
  v_qty      int;
  v_price    numeric;
  v_desc     text;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable', 'vendeur']::public.shop_role[]);

  if p_doc_type not in ('devis', 'facture') then
    raise exception 'Type de document inconnu : %', p_doc_type;
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Le document doit contenir au moins une ligne';
  end if;

  if p_customer_id is not null then
    select * into v_cust from public.customers where id = p_customer_id;
    if v_cust.id is null or v_cust.shop_id <> v_shop then
      raise exception 'Ce client n''appartient pas à votre boutique';
    end if;
  end if;

  select * into v_shopinfo from public.shops where id = v_shop;

  if p_id is null then
    insert into public.sales_documents (
      shop_id, doc_type, number, status, customer_id, customer_name, customer_phone,
      issue_date, valid_until, due_date, vat_applicable, vat_rate, notes, created_by
    ) values (
      v_shop, p_doc_type,
      case when p_doc_type = 'devis' then public.next_document_number(v_shop, 'devis') end,
      case when p_doc_type = 'devis' then 'en_attente' else 'brouillon' end,
      p_customer_id,
      coalesce(v_cust.name, nullif(trim(p_customer_name), '')),
      v_cust.phone,
      current_date,
      case when p_doc_type = 'devis' then coalesce(p_valid_until, current_date + 30) end,
      case when p_doc_type = 'facture' then p_due_date end,
      v_shopinfo.vat_applicable, v_shopinfo.vat_rate, nullif(trim(p_notes), ''), auth.uid()
    )
    returning id into v_id;
  else
    select * into v_doc from public.sales_documents where id = p_id for update;
    if v_doc.id is null or v_doc.shop_id <> v_shop then
      raise exception 'Document introuvable';
    end if;
    if not ((v_doc.doc_type = 'facture' and v_doc.status = 'brouillon')
         or (v_doc.doc_type = 'devis' and v_doc.status = 'en_attente')) then
      raise exception 'Ce document ne peut plus être modifié';
    end if;

    update public.sales_documents set
      customer_id    = p_customer_id,
      customer_name  = coalesce(v_cust.name, nullif(trim(p_customer_name), '')),
      customer_phone = v_cust.phone,
      notes          = nullif(trim(p_notes), ''),
      valid_until    = case when doc_type = 'devis' then coalesce(p_valid_until, valid_until) end,
      due_date       = case when doc_type = 'facture' then p_due_date end,
      vat_applicable = v_shopinfo.vat_applicable,
      vat_rate       = v_shopinfo.vat_rate,
      updated_at     = now()
    where id = p_id;

    delete from public.sales_document_lines where document_id = p_id;
    v_id := p_id;
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_art   := nullif(v_line->>'article_id', '')::uuid;
    v_qty   := (v_line->>'qty')::int;
    v_price := (v_line->>'unit_price_ttc')::numeric;
    v_desc  := nullif(trim(v_line->>'description'), '');

    if v_qty is null or v_qty <= 0 then
      raise exception 'Quantité invalide sur une ligne';
    end if;
    if v_price is null or v_price < 0 then
      raise exception 'Prix invalide sur une ligne';
    end if;
    if v_art is not null then
      select shop_id, name into v_art_shop, v_art_name from public.articles where id = v_art;
      if v_art_shop is null or v_art_shop <> v_shop then
        raise exception 'Article invalide sur une ligne';
      end if;
      v_desc := coalesce(v_desc, v_art_name);
    end if;
    if v_desc is null then
      raise exception 'Chaque ligne doit avoir une désignation';
    end if;

    insert into public.sales_document_lines
      (document_id, shop_id, position, article_id, description, qty, unit_price_ttc, line_total_ttc)
    values
      (v_id, v_shop, v_pos, v_art, v_desc, v_qty, v_price, round(v_qty * v_price));
    v_pos := v_pos + 1;
  end loop;

  perform public.recompute_document_totals(v_id);
  return v_id;
end;
$$;

-- Émet une facture brouillon : numéro définitif, puis (option) sortie de stock.
create or replace function public.issue_invoice(p_id uuid, p_apply_stock boolean default true)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop   uuid;
  v_doc    public.sales_documents;
  v_line   record;
  v_stock  int;
  v_name   text;
  v_by     text;
  v_number text;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable', 'vendeur']::public.shop_role[]);

  select * into v_doc from public.sales_documents where id = p_id for update;
  if v_doc.id is null or v_doc.shop_id <> v_shop then
    raise exception 'Document introuvable';
  end if;
  if v_doc.doc_type <> 'facture' or v_doc.status <> 'brouillon' then
    raise exception 'Seule une facture en brouillon peut être émise';
  end if;
  if not exists (select 1 from public.sales_document_lines where document_id = p_id) then
    raise exception 'La facture ne contient aucune ligne';
  end if;

  if p_apply_stock then
    -- Vérifie d'abord tout le stock (rien n'est modifié si une ligne manque)
    for v_line in
      select article_id, sum(qty)::int as qty
      from public.sales_document_lines
      where document_id = p_id and article_id is not null
      group by article_id
    loop
      select qty, name into v_stock, v_name from public.articles where id = v_line.article_id for update;
      if v_stock is null then
        raise exception 'Un article de la facture n''existe plus';
      end if;
      if v_stock < v_line.qty then
        raise exception 'Stock insuffisant pour « % » (disponible : %, demandé : %)', v_name, v_stock, v_line.qty;
      end if;
    end loop;

    select coalesce(display_name, email) into v_by from public.profiles where id = auth.uid();

    for v_line in
      select article_id, qty from public.sales_document_lines
      where document_id = p_id and article_id is not null
      order by position
    loop
      update public.articles set qty = qty - v_line.qty where id = v_line.article_id;
      insert into public.movements (article_id, type, qty, by_name, at, shop_id, customer_id, document_id)
      values (v_line.article_id, 'vente', v_line.qty, v_by, now(), v_shop, v_doc.customer_id, p_id);
    end loop;
  end if;

  v_number := public.next_document_number(v_shop, 'facture');

  update public.sales_documents
  set number = v_number, status = 'emise', issue_date = current_date,
      stock_applied = p_apply_stock, updated_at = now()
  where id = p_id;

  return v_number;
end;
$$;

create or replace function public.set_quote_status(p_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_doc  public.sales_documents;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable', 'vendeur']::public.shop_role[]);
  if p_status not in ('en_attente', 'accepte', 'refuse') then
    raise exception 'Statut de devis invalide';
  end if;
  select * into v_doc from public.sales_documents where id = p_id for update;
  if v_doc.id is null or v_doc.shop_id <> v_shop or v_doc.doc_type <> 'devis' then
    raise exception 'Devis introuvable';
  end if;
  if v_doc.status = 'converti' then
    raise exception 'Ce devis a déjà été converti en facture';
  end if;
  update public.sales_documents set status = p_status, updated_at = now() where id = p_id;
end;
$$;

-- Copie un devis en facture brouillon (prix figés du devis).
create or replace function public.convert_quote_to_invoice(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop     uuid;
  v_doc      public.sales_documents;
  v_shopinfo public.shops;
  v_new      uuid;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable', 'vendeur']::public.shop_role[]);

  select * into v_doc from public.sales_documents where id = p_id for update;
  if v_doc.id is null or v_doc.shop_id <> v_shop or v_doc.doc_type <> 'devis' then
    raise exception 'Devis introuvable';
  end if;
  if v_doc.status not in ('en_attente', 'accepte') then
    raise exception 'Seul un devis en attente ou accepté peut être converti';
  end if;

  select * into v_shopinfo from public.shops where id = v_shop;

  insert into public.sales_documents (
    shop_id, doc_type, status, customer_id, customer_name, customer_phone, issue_date,
    vat_applicable, vat_rate, source_quote_id, notes, created_by
  ) values (
    v_shop, 'facture', 'brouillon', v_doc.customer_id, v_doc.customer_name, v_doc.customer_phone,
    current_date, v_shopinfo.vat_applicable, v_shopinfo.vat_rate, v_doc.id, v_doc.notes, auth.uid()
  )
  returning id into v_new;

  insert into public.sales_document_lines
    (document_id, shop_id, position, article_id, description, qty, unit_price_ttc, line_total_ttc)
  select v_new, shop_id, position, article_id, description, qty, unit_price_ttc, line_total_ttc
  from public.sales_document_lines where document_id = p_id;

  perform public.recompute_document_totals(v_new);

  update public.sales_documents set status = 'converti', updated_at = now() where id = p_id;
  return v_new;
end;
$$;

create or replace function public.delete_sales_document(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_doc  public.sales_documents;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable', 'vendeur']::public.shop_role[]);
  select * into v_doc from public.sales_documents where id = p_id for update;
  if v_doc.id is null or v_doc.shop_id <> v_shop then
    raise exception 'Document introuvable';
  end if;
  -- Une facture émise ne se supprime jamais (numérotation continue) : on l'annule.
  if not ((v_doc.doc_type = 'facture' and v_doc.status = 'brouillon')
       or (v_doc.doc_type = 'devis' and v_doc.status <> 'converti')) then
    raise exception 'Ce document ne peut pas être supprimé (une facture émise s''annule)';
  end if;
  delete from public.sales_documents where id = p_id;
end;
$$;

create or replace function public.record_invoice_payment(
  p_id        uuid,
  p_amount    numeric,
  p_method    text,
  p_reference text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_doc  public.sales_documents;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable', 'vendeur']::public.shop_role[]);

  select * into v_doc from public.sales_documents where id = p_id for update;
  if v_doc.id is null or v_doc.shop_id <> v_shop or v_doc.doc_type <> 'facture' then
    raise exception 'Facture introuvable';
  end if;
  if v_doc.status <> 'emise' then
    raise exception 'Un paiement ne peut être enregistré que sur une facture émise';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Le montant du paiement doit être positif';
  end if;
  if p_amount > v_doc.total_ttc - v_doc.amount_paid then
    raise exception 'Montant supérieur au reste à payer (%)', v_doc.total_ttc - v_doc.amount_paid;
  end if;

  insert into public.invoice_payments (shop_id, document_id, amount, method, reference, created_by)
  values (v_shop, p_id, p_amount, p_method, nullif(trim(p_reference), ''), auth.uid());

  update public.sales_documents
  set amount_paid = amount_paid + p_amount, updated_at = now()
  where id = p_id;
end;
$$;

-- Annulation d'une facture émise sans paiement (avec remise en stock si
-- l'émission l'avait sortie). Les cas avec paiement relèvent du futur
-- module Retours & remboursements (avoir).
create or replace function public.cancel_invoice(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_doc  public.sales_documents;
  v_line record;
  v_by   text;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);

  select * into v_doc from public.sales_documents where id = p_id for update;
  if v_doc.id is null or v_doc.shop_id <> v_shop or v_doc.doc_type <> 'facture' then
    raise exception 'Facture introuvable';
  end if;
  if v_doc.status <> 'emise' then
    raise exception 'Seule une facture émise peut être annulée';
  end if;
  if v_doc.amount_paid > 0 then
    raise exception 'Cette facture a déjà reçu un paiement : elle ne peut pas être annulée (passer par un retour/avoir)';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Le motif d''annulation est obligatoire';
  end if;

  if v_doc.stock_applied then
    select coalesce(display_name, email) into v_by from public.profiles where id = auth.uid();
    for v_line in
      select l.article_id, l.qty
      from public.sales_document_lines l
      join public.articles a on a.id = l.article_id
      where l.document_id = p_id
    loop
      update public.articles set qty = qty + v_line.qty where id = v_line.article_id;
      insert into public.movements (article_id, type, qty, by_name, at, shop_id, customer_id, document_id)
      values (v_line.article_id, 'retour', v_line.qty, v_by, now(), v_shop, v_doc.customer_id, p_id);
    end loop;
  end if;

  update public.sales_documents
  set status = 'annulee', cancel_reason = trim(p_reason), updated_at = now()
  where id = p_id;
end;
$$;

-- Rattache le numéro de la FNE émise sur la plateforme DGI.
create or replace function public.set_invoice_fne(p_id uuid, p_fne_number text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_doc  public.sales_documents;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);
  select * into v_doc from public.sales_documents where id = p_id for update;
  if v_doc.id is null or v_doc.shop_id <> v_shop or v_doc.doc_type <> 'facture' or v_doc.status <> 'emise' then
    raise exception 'Facture émise introuvable';
  end if;
  update public.sales_documents
  set fne_number = nullif(trim(p_fne_number), ''),
      fne_recorded_at = case when nullif(trim(p_fne_number), '') is null then null else now() end,
      updated_at = now()
  where id = p_id;
end;
$$;

create or replace function public.update_shop_settings(p_settings jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_rate numeric;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant']::public.shop_role[]);
  v_rate := coalesce((p_settings->>'vat_rate')::numeric, 18);
  if v_rate < 0 or v_rate > 100 then
    raise exception 'Taux de TVA invalide';
  end if;
  update public.shops set
    name           = coalesce(nullif(trim(p_settings->>'name'), ''), name),
    legal_name     = nullif(trim(p_settings->>'legal_name'), ''),
    address        = nullif(trim(p_settings->>'address'), ''),
    phone          = nullif(trim(p_settings->>'phone'), ''),
    email          = nullif(trim(p_settings->>'email'), ''),
    ncc            = nullif(trim(p_settings->>'ncc'), ''),
    rccm           = nullif(trim(p_settings->>'rccm'), ''),
    tax_regime     = nullif(trim(p_settings->>'tax_regime'), ''),
    vat_applicable = coalesce((p_settings->>'vat_applicable')::boolean, true),
    vat_rate       = v_rate,
    invoice_footer = nullif(trim(p_settings->>'invoice_footer'), '')
  where id = v_shop;
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. record_movement : identique à 003, mais renseigne à nouveau `by_name`
--    (la version 003 ne le faisait plus : l'historique affichait "inconnu").
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

  insert into public.movements (article_id, type, qty, by_name, shop_id, at, customer_id)
  values (p_article_id, p_type, p_qty, v_by, v_shop_id, now(), p_customer_id);
end;
$$;

-- ----------------------------------------------------------------------------
-- 7. Droits d'exécution
-- ----------------------------------------------------------------------------
revoke execute on function public.next_document_number(uuid, text)  from public;
revoke execute on function public.recompute_document_totals(uuid)   from public;
revoke execute on function public.require_shop_role(public.shop_role[]) from public;
do $$
begin
  -- Rôles propres à Supabase : absents d'une base Postgres de test locale.
  execute 'revoke execute on function public.next_document_number(uuid, text) from anon, authenticated';
  execute 'revoke execute on function public.recompute_document_totals(uuid) from anon, authenticated';
  execute 'revoke execute on function public.require_shop_role(public.shop_role[]) from anon, authenticated';
exception when undefined_object then null;
end $$;

grant execute on function public.save_sales_document(uuid, text, uuid, text, jsonb, text, date, date) to authenticated;
grant execute on function public.issue_invoice(uuid, boolean)                     to authenticated;
grant execute on function public.set_quote_status(uuid, text)                     to authenticated;
grant execute on function public.convert_quote_to_invoice(uuid)                   to authenticated;
grant execute on function public.delete_sales_document(uuid)                      to authenticated;
grant execute on function public.record_invoice_payment(uuid, numeric, text, text) to authenticated;
grant execute on function public.cancel_invoice(uuid, text)                       to authenticated;
grant execute on function public.set_invoice_fne(uuid, text)                      to authenticated;
grant execute on function public.update_shop_settings(jsonb)                      to authenticated;

-- ----------------------------------------------------------------------------
-- 8. Temps réel (mise à jour automatique des écrans ouverts)
-- ----------------------------------------------------------------------------
do $$
declare
  v_table text;
begin
  foreach v_table in array array['customers', 'sales_documents', 'invoice_payments'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    exception when others then null;  -- déjà présente, ou publication absente (base locale)
    end;
  end loop;
end $$;
