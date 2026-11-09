-- ============================================================================
-- Migration 005 : module Retours & remboursements (phase 2, module 5).
--
-- Un retour :
--   - part d'une facture émise (lignes reprises, quantités plafonnées par ce
--     qui a été facturé moins les retours précédents), ou est libre (vente
--     au comptoir sans facture) ;
--   - remet en stock, ligne par ligne, les articles revendables ;
--   - a une suite financière : remboursement (espèces, mobile money...),
--     déduction du reste à payer de la facture, déduction du crédit
--     comptoir du client, ou aucune (échange) ;
--   - porte un motif catégorisé et un numéro séquentiel RET-AAAA-00001,
--     avec un champ pour rattacher l'avoir FNE émis sur la plateforme DGI.
--
-- Les remboursements (refund_amount / refund_method) seront une des sources
-- de la future Trésorerie (module 8).
--
-- Pré-requis : migrations 001 à 004 appliquées. Relançable sans casse.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Montant déduit d'une facture par des avoirs
--    Reste à payer = total_ttc - amount_paid - credited_amount
-- ----------------------------------------------------------------------------
alter table public.sales_documents
  add column if not exists credited_amount numeric not null default 0;

-- ----------------------------------------------------------------------------
-- 2. Tables
-- ----------------------------------------------------------------------------
create table if not exists public.returns (
  id                  uuid primary key default gen_random_uuid(),
  shop_id             uuid not null references public.shops(id) on delete cascade,
  number              text not null,
  return_date         date not null default current_date,
  source_document_id  uuid references public.sales_documents(id) on delete set null,
  customer_id         uuid references public.customers(id) on delete set null,
  customer_name       text,
  reason_category     text not null check (reason_category in ('defaut', 'erreur_commande', 'insatisfaction', 'autre')),
  reason_note         text,
  total_ttc           numeric not null default 0,
  refund_type         text not null check (refund_type in ('aucun', 'remboursement', 'deduction_facture', 'credit_client')),
  refund_amount       numeric not null default 0 check (refund_amount >= 0),
  refund_method       text check (refund_method is null or refund_method in ('especes', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'banque', 'cheque', 'autre')),
  refund_reference    text,
  fne_number          text,
  fne_recorded_at     timestamptz,
  created_by          uuid references auth.users(id),
  created_at          timestamptz not null default now(),
  constraint returns_number_unique unique (shop_id, number)
);
create index if not exists idx_returns_shop   on public.returns(shop_id);
create index if not exists idx_returns_source on public.returns(source_document_id);

create table if not exists public.return_lines (
  id              uuid primary key default gen_random_uuid(),
  return_id       uuid not null references public.returns(id) on delete cascade,
  shop_id         uuid not null references public.shops(id) on delete cascade,
  position        int  not null default 0,
  article_id      uuid references public.articles(id) on delete set null,
  description     text not null,
  qty             integer not null check (qty > 0),
  unit_price_ttc  numeric not null check (unit_price_ttc >= 0),
  line_total_ttc  numeric not null,
  restock         boolean not null default true
);
create index if not exists idx_return_lines_return on public.return_lines(return_id);

alter table public.movements
  add column if not exists return_id uuid references public.returns(id) on delete set null;

-- RLS : lecture par boutique, écriture uniquement via les fonctions
alter table public.returns      enable row level security;
alter table public.return_lines enable row level security;

drop policy if exists returns_select_same_shop on public.returns;
create policy returns_select_same_shop on public.returns
  for select using (shop_id = public.current_shop_id());

drop policy if exists return_lines_select_same_shop on public.return_lines;
create policy return_lines_select_same_shop on public.return_lines
  for select using (shop_id = public.current_shop_id());

-- ----------------------------------------------------------------------------
-- 3. Numérotation : préfixe RET pour les retours
-- ----------------------------------------------------------------------------
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
  insert into public.document_counters (shop_id, doc_type, year, last_number)
  values (p_shop, p_type, v_year, 1)
  on conflict (shop_id, doc_type, year)
  do update set last_number = public.document_counters.last_number + 1
  returning last_number into v_n;

  v_prefix := case p_type
    when 'devis' then 'DEV'
    when 'facture' then 'FAC'
    when 'retour' then 'RET'
    else upper(p_type) end;
  return v_prefix || '-' || v_year || '-' || lpad(v_n::text, 5, '0');
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Création d'un retour (tout en une transaction)
--    p_lines : [{article_id?, description?, qty, unit_price_ttc, restock}, ...]
-- ----------------------------------------------------------------------------
create or replace function public.create_return(
  p_source_document_id uuid,
  p_customer_id        uuid,
  p_customer_name      text,
  p_lines              jsonb,
  p_reason_category    text,
  p_reason_note        text,
  p_refund_type        text,
  p_refund_amount      numeric,
  p_refund_method      text default null,
  p_refund_reference   text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop        uuid;
  v_doc         public.sales_documents;
  v_cust        public.customers;
  v_id          uuid;
  v_number      text;
  v_line        jsonb;
  v_pos         int := 0;
  v_art         uuid;
  v_art_shop    uuid;
  v_art_name    text;
  v_qty         int;
  v_price       numeric;
  v_desc        text;
  v_restock     boolean;
  v_total       numeric := 0;
  v_amount      numeric := coalesce(p_refund_amount, 0);
  v_by          text;
  v_check       record;
  v_prev_value  numeric;
  v_refunded    numeric;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable', 'vendeur']::public.shop_role[]);

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Le retour doit contenir au moins une ligne';
  end if;
  if p_reason_category is null or p_reason_category not in ('defaut', 'erreur_commande', 'insatisfaction', 'autre') then
    raise exception 'Motif de retour invalide';
  end if;
  if p_refund_type is null or p_refund_type not in ('aucun', 'remboursement', 'deduction_facture', 'credit_client') then
    raise exception 'Type de remboursement invalide';
  end if;

  -- Facture d'origine (facultative)
  if p_source_document_id is not null then
    select * into v_doc from public.sales_documents where id = p_source_document_id for update;
    if v_doc.id is null or v_doc.shop_id <> v_shop or v_doc.doc_type <> 'facture' then
      raise exception 'Facture d''origine introuvable';
    end if;
    if v_doc.status <> 'emise' then
      raise exception 'Un retour ne peut porter que sur une facture émise';
    end if;
  end if;

  -- Client : celui de la facture s'il y en a une, sinon celui choisi
  if v_doc.id is not null then
    if v_doc.customer_id is not null then
      select * into v_cust from public.customers where id = v_doc.customer_id for update;
    end if;
  elsif p_customer_id is not null then
    select * into v_cust from public.customers where id = p_customer_id for update;
    if v_cust.id is null or v_cust.shop_id <> v_shop then
      raise exception 'Ce client n''appartient pas à votre boutique';
    end if;
  end if;

  v_number := public.next_document_number(v_shop, 'retour');

  insert into public.returns (
    shop_id, number, source_document_id, customer_id, customer_name,
    reason_category, reason_note, refund_type, refund_amount, refund_method, refund_reference, created_by
  ) values (
    v_shop, v_number, v_doc.id, v_cust.id,
    coalesce(v_cust.name, v_doc.customer_name, nullif(trim(p_customer_name), '')),
    p_reason_category, nullif(trim(p_reason_note), ''), p_refund_type, 0, null, null, auth.uid()
  )
  returning id into v_id;

  select coalesce(display_name, email) into v_by from public.profiles where id = auth.uid();

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_art     := nullif(v_line->>'article_id', '')::uuid;
    v_qty     := (v_line->>'qty')::int;
    v_price   := (v_line->>'unit_price_ttc')::numeric;
    v_desc    := nullif(trim(v_line->>'description'), '');
    v_restock := coalesce((v_line->>'restock')::boolean, true);

    if v_qty is null or v_qty <= 0 then
      raise exception 'Quantité invalide sur une ligne';
    end if;
    if v_price is null or v_price < 0 then
      raise exception 'Prix invalide sur une ligne';
    end if;
    if v_art is not null then
      select shop_id, name into v_art_shop, v_art_name from public.articles where id = v_art for update;
      if v_art_shop is null or v_art_shop <> v_shop then
        raise exception 'Article invalide sur une ligne';
      end if;
      v_desc := coalesce(v_desc, v_art_name);
    end if;
    if v_desc is null then
      raise exception 'Chaque ligne doit avoir une désignation';
    end if;
    if v_art is null then
      v_restock := false;  -- rien à remettre en stock pour une ligne libre
    end if;

    insert into public.return_lines
      (return_id, shop_id, position, article_id, description, qty, unit_price_ttc, line_total_ttc, restock)
    values
      (v_id, v_shop, v_pos, v_art, v_desc, v_qty, v_price, round(v_qty * v_price), v_restock);

    if v_restock then
      update public.articles set qty = qty + v_qty where id = v_art;
      insert into public.movements (article_id, type, qty, by_name, at, shop_id, customer_id, return_id)
      values (v_art, 'retour', v_qty, v_by, now(), v_shop, v_cust.id, v_id);
    end if;

    v_total := v_total + round(v_qty * v_price);
    v_pos := v_pos + 1;
  end loop;

  -- Plafonds liés à la facture d'origine (retours précédents inclus)
  if v_doc.id is not null then
    for v_check in
      select rl.article_id,
             sum(rl.qty) as returned,
             coalesce((select sum(l.qty) from public.sales_document_lines l
                       where l.document_id = v_doc.id and l.article_id = rl.article_id), 0) as invoiced,
             max(rl.description) as name
      from public.return_lines rl
      join public.returns r on r.id = rl.return_id
      where r.source_document_id = v_doc.id and rl.article_id is not null
      group by rl.article_id
    loop
      if v_check.returned > v_check.invoiced then
        raise exception 'Quantité retournée supérieure à la quantité facturée pour « % » (facturé : %, retours cumulés : %)',
          v_check.name, v_check.invoiced, v_check.returned;
      end if;
    end loop;

    select coalesce(sum(r.total_ttc), 0) into v_prev_value
    from public.returns r where r.source_document_id = v_doc.id and r.id <> v_id;
    if v_prev_value + v_total > v_doc.total_ttc then
      raise exception 'Valeur des retours supérieure au montant de la facture (% déjà retournés sur %)', v_prev_value, v_doc.total_ttc;
    end if;
  end if;

  -- Suite financière
  if p_refund_type = 'aucun' then
    v_amount := 0;
  else
    if v_amount <= 0 then
      raise exception 'Le montant doit être positif';
    end if;
    if v_amount > v_total then
      raise exception 'Le montant (%) dépasse la valeur des articles retournés (%)', v_amount, v_total;
    end if;
  end if;

  if p_refund_type = 'deduction_facture' then
    if v_doc.id is null then
      raise exception 'La déduction sur facture nécessite une facture d''origine';
    end if;
    if v_amount > v_doc.total_ttc - v_doc.amount_paid - v_doc.credited_amount then
      raise exception 'Le montant dépasse le reste à payer de la facture (%)', v_doc.total_ttc - v_doc.amount_paid - v_doc.credited_amount;
    end if;
    update public.sales_documents
    set credited_amount = credited_amount + v_amount, updated_at = now()
    where id = v_doc.id;

  elsif p_refund_type = 'remboursement' then
    if p_refund_method is null or p_refund_method not in ('especes', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'banque', 'cheque', 'autre') then
      raise exception 'Moyen de remboursement invalide';
    end if;
    if v_doc.id is not null then
      select coalesce(sum(refund_amount), 0) into v_refunded
      from public.returns
      where source_document_id = v_doc.id and refund_type = 'remboursement' and id <> v_id;
      if v_amount > v_doc.amount_paid - v_refunded then
        raise exception 'Le remboursement dépasse ce que le client a payé sur cette facture (%)', v_doc.amount_paid - v_refunded;
      end if;
    end if;

  elsif p_refund_type = 'credit_client' then
    if v_cust.id is null then
      raise exception 'La déduction sur crédit nécessite un client enregistré';
    end if;
    if v_amount > v_cust.credit_balance then
      raise exception 'Le montant dépasse le crédit comptoir dû par ce client (%)', v_cust.credit_balance;
    end if;
    update public.customers set credit_balance = credit_balance - v_amount where id = v_cust.id;
  end if;

  update public.returns
  set total_ttc        = v_total,
      refund_amount    = v_amount,
      refund_method    = case when p_refund_type = 'remboursement' then p_refund_method end,
      refund_reference = case when p_refund_type = 'remboursement' then nullif(trim(p_refund_reference), '') end
  where id = v_id;

  return v_id;
end;
$$;

-- Rattache le numéro de l'avoir FNE émis sur la plateforme DGI.
create or replace function public.set_return_fne(p_id uuid, p_fne_number text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_ret  public.returns;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);
  select * into v_ret from public.returns where id = p_id for update;
  if v_ret.id is null or v_ret.shop_id <> v_shop then
    raise exception 'Retour introuvable';
  end if;
  update public.returns
  set fne_number = nullif(trim(p_fne_number), ''),
      fne_recorded_at = case when nullif(trim(p_fne_number), '') is null then null else now() end
  where id = p_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Factures : le reste à payer tient compte des avoirs
-- ----------------------------------------------------------------------------
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
  v_shop      uuid;
  v_doc       public.sales_documents;
  v_remaining numeric;
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
  v_remaining := v_doc.total_ttc - v_doc.amount_paid - v_doc.credited_amount;
  if p_amount > v_remaining then
    raise exception 'Montant supérieur au reste à payer (%)', v_remaining;
  end if;

  insert into public.invoice_payments (shop_id, document_id, amount, method, reference, created_by)
  values (v_shop, p_id, p_amount, p_method, nullif(trim(p_reference), ''), auth.uid());

  update public.sales_documents
  set amount_paid = amount_paid + p_amount, updated_at = now()
  where id = p_id;
end;
$$;

-- Annulation impossible dès qu'un retour existe sur la facture (le retour
-- a déjà ajusté stock et argent : annuler en plus compterait deux fois).
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
  if exists (select 1 from public.returns where source_document_id = p_id) then
    raise exception 'Cette facture a déjà fait l''objet d''un retour : elle ne peut plus être annulée';
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

-- ----------------------------------------------------------------------------
-- 6. Droits et temps réel
-- ----------------------------------------------------------------------------
revoke execute on function public.next_document_number(uuid, text) from public;
do $$
begin
  execute 'revoke execute on function public.next_document_number(uuid, text) from anon, authenticated';
exception when undefined_object then null;
end $$;

grant execute on function public.create_return(uuid, uuid, text, jsonb, text, text, text, numeric, text, text) to authenticated;
grant execute on function public.set_return_fne(uuid, text) to authenticated;

do $$
begin
  execute 'alter publication supabase_realtime add table public.returns';
exception when others then null;
end $$;
