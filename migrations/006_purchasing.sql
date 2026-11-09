-- ============================================================================
-- Migration 006 : module Achats & fournisseurs (phase 3, module 7).
--
-- Ajoute :
--   1. suppliers : fiches fournisseurs (délai de paiement habituel)
--   2. purchase_orders + lignes : bons de commande (brouillon -> commandé ->
--      partiellement reçu -> reçu, ou annulé), numéro BC-AAAA-00001
--   3. Réception totale ou partielle : entrée en stock (mouvement
--      'reassort' rattaché au bon), mise à jour optionnelle du prix d'achat
--   4. supplier_payments : paiements fournisseurs (acomptes possibles)
--      Dette = valeur reçue - payé ; échéance par bon de commande
--
-- Droits (cahier des charges) : le vendeur n'a pas accès aux achats ; le
-- comptable voit les achats et paie les fournisseurs mais ne réceptionne
-- pas (pas de gestion du stock physique) ; owner / gérant : tout.
--
-- Pré-requis : migrations 001 à 005 appliquées. Relançable sans casse.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Fournisseurs
-- ----------------------------------------------------------------------------
create table if not exists public.suppliers (
  id                  uuid primary key default gen_random_uuid(),
  shop_id             uuid not null references public.shops(id) on delete cascade,
  name                text not null,
  contact_name        text,
  phone               text,
  email               text,
  address             text,
  payment_terms_days  int not null default 0 check (payment_terms_days >= 0),
  notes               text,
  created_at          timestamptz not null default now()
);
create index if not exists idx_suppliers_shop on public.suppliers(shop_id);

alter table public.suppliers enable row level security;

drop policy if exists suppliers_select on public.suppliers;
create policy suppliers_select on public.suppliers
  for select using (shop_id = public.current_shop_id()
                    and public.current_shop_role() in ('owner', 'gerant', 'comptable'));

drop policy if exists suppliers_insert on public.suppliers;
create policy suppliers_insert on public.suppliers
  for insert with check (shop_id = public.current_shop_id()
                         and public.current_shop_role() in ('owner', 'gerant', 'comptable'));

drop policy if exists suppliers_update on public.suppliers;
create policy suppliers_update on public.suppliers
  for update using (shop_id = public.current_shop_id()
                    and public.current_shop_role() in ('owner', 'gerant', 'comptable'))
  with check (shop_id = public.current_shop_id());

drop policy if exists suppliers_delete on public.suppliers;
create policy suppliers_delete on public.suppliers
  for delete using (shop_id = public.current_shop_id()
                    and public.current_shop_role() in ('owner', 'gerant'));

-- ----------------------------------------------------------------------------
-- 2. Bons de commande
-- ----------------------------------------------------------------------------
create table if not exists public.purchase_orders (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops(id) on delete cascade,
  number            text,
  status            text not null default 'brouillon'
                    check (status in ('brouillon', 'commande', 'partiel', 'recu', 'annule')),
  supplier_id       uuid references public.suppliers(id) on delete set null,
  supplier_name     text,   -- copie figée
  order_date        date,
  expected_date     date,   -- livraison prévue
  due_date          date,   -- échéance de paiement
  supplier_ref      text,   -- n° de facture / proforma du fournisseur
  total             numeric not null default 0,
  received_value    numeric not null default 0,
  amount_paid       numeric not null default 0,
  notes             text,
  cancel_reason     text,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint purchase_orders_number_unique unique (shop_id, number)
);
create index if not exists idx_purchase_orders_shop     on public.purchase_orders(shop_id);
create index if not exists idx_purchase_orders_supplier on public.purchase_orders(supplier_id);

create table if not exists public.purchase_order_lines (
  id            uuid primary key default gen_random_uuid(),
  po_id         uuid not null references public.purchase_orders(id) on delete cascade,
  shop_id       uuid not null references public.shops(id) on delete cascade,
  position      int  not null default 0,
  article_id    uuid references public.articles(id) on delete set null,
  description   text not null,
  qty_ordered   integer not null check (qty_ordered > 0),
  qty_received  integer not null default 0 check (qty_received >= 0),
  unit_cost     numeric not null check (unit_cost >= 0),
  line_total    numeric not null,
  constraint purchase_order_lines_received_le_ordered check (qty_received <= qty_ordered)
);
create index if not exists idx_purchase_order_lines_po on public.purchase_order_lines(po_id);

create table if not exists public.supplier_payments (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops(id) on delete cascade,
  po_id        uuid not null references public.purchase_orders(id) on delete restrict,
  supplier_id  uuid references public.suppliers(id) on delete set null,
  amount       numeric not null check (amount > 0),
  method       text not null check (method in ('especes', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'banque', 'cheque', 'autre')),
  reference    text,
  paid_at      timestamptz not null default now(),
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now()
);
create index if not exists idx_supplier_payments_po on public.supplier_payments(po_id);

alter table public.movements
  add column if not exists purchase_order_id uuid references public.purchase_orders(id) on delete set null;

-- Lecture réservée owner / gérant / comptable ; écriture via fonctions uniquement
alter table public.purchase_orders      enable row level security;
alter table public.purchase_order_lines enable row level security;
alter table public.supplier_payments    enable row level security;

drop policy if exists purchase_orders_select on public.purchase_orders;
create policy purchase_orders_select on public.purchase_orders
  for select using (shop_id = public.current_shop_id()
                    and public.current_shop_role() in ('owner', 'gerant', 'comptable'));

drop policy if exists purchase_order_lines_select on public.purchase_order_lines;
create policy purchase_order_lines_select on public.purchase_order_lines
  for select using (shop_id = public.current_shop_id()
                    and public.current_shop_role() in ('owner', 'gerant', 'comptable'));

drop policy if exists supplier_payments_select on public.supplier_payments;
create policy supplier_payments_select on public.supplier_payments
  for select using (shop_id = public.current_shop_id()
                    and public.current_shop_role() in ('owner', 'gerant', 'comptable'));

-- ----------------------------------------------------------------------------
-- 3. Numérotation : préfixe BC pour les bons de commande
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
    when 'bon_commande' then 'BC'
    else upper(p_type) end;
  return v_prefix || '-' || v_year || '-' || lpad(v_n::text, 5, '0');
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. RPC
-- ----------------------------------------------------------------------------

-- Crée (p_id null) ou modifie un bon de commande en brouillon.
-- p_lines : [{article_id?, description?, qty, unit_cost}, ...]
create or replace function public.save_purchase_order(
  p_id            uuid,
  p_supplier_id   uuid,
  p_lines         jsonb,
  p_expected_date date default null,
  p_due_date      date default null,
  p_supplier_ref  text default null,
  p_notes         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop     uuid;
  v_sup      public.suppliers;
  v_po       public.purchase_orders;
  v_id       uuid;
  v_line     jsonb;
  v_pos      int := 0;
  v_art      uuid;
  v_art_shop uuid;
  v_art_name text;
  v_qty      int;
  v_cost     numeric;
  v_desc     text;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);

  if p_supplier_id is null then
    raise exception 'Choisissez un fournisseur';
  end if;
  select * into v_sup from public.suppliers where id = p_supplier_id;
  if v_sup.id is null or v_sup.shop_id <> v_shop then
    raise exception 'Fournisseur introuvable';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Le bon de commande doit contenir au moins une ligne';
  end if;

  if p_id is null then
    insert into public.purchase_orders (shop_id, status, supplier_id, supplier_name, expected_date, due_date, supplier_ref, notes, created_by)
    values (v_shop, 'brouillon', v_sup.id, v_sup.name, p_expected_date, p_due_date,
            nullif(trim(p_supplier_ref), ''), nullif(trim(p_notes), ''), auth.uid())
    returning id into v_id;
  else
    select * into v_po from public.purchase_orders where id = p_id for update;
    if v_po.id is null or v_po.shop_id <> v_shop then
      raise exception 'Bon de commande introuvable';
    end if;
    if v_po.status <> 'brouillon' then
      raise exception 'Seul un bon de commande en brouillon peut être modifié';
    end if;
    update public.purchase_orders set
      supplier_id = v_sup.id, supplier_name = v_sup.name, expected_date = p_expected_date,
      due_date = p_due_date, supplier_ref = nullif(trim(p_supplier_ref), ''),
      notes = nullif(trim(p_notes), ''), updated_at = now()
    where id = p_id;
    delete from public.purchase_order_lines where po_id = p_id;
    v_id := p_id;
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_art  := nullif(v_line->>'article_id', '')::uuid;
    v_qty  := (v_line->>'qty')::int;
    v_cost := (v_line->>'unit_cost')::numeric;
    v_desc := nullif(trim(v_line->>'description'), '');
    if v_qty is null or v_qty <= 0 then
      raise exception 'Quantité invalide sur une ligne';
    end if;
    if v_cost is null or v_cost < 0 then
      raise exception 'Coût invalide sur une ligne';
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
    insert into public.purchase_order_lines (po_id, shop_id, position, article_id, description, qty_ordered, unit_cost, line_total)
    values (v_id, v_shop, v_pos, v_art, v_desc, v_qty, v_cost, round(v_qty * v_cost));
    v_pos := v_pos + 1;
  end loop;

  update public.purchase_orders
  set total = (select coalesce(sum(line_total), 0) from public.purchase_order_lines where po_id = v_id)
  where id = v_id;

  return v_id;
end;
$$;

-- Passe la commande : numéro définitif, date de commande, échéance par défaut
create or replace function public.place_purchase_order(p_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop   uuid;
  v_po     public.purchase_orders;
  v_terms  int;
  v_number text;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);
  select * into v_po from public.purchase_orders where id = p_id for update;
  if v_po.id is null or v_po.shop_id <> v_shop then
    raise exception 'Bon de commande introuvable';
  end if;
  if v_po.status <> 'brouillon' then
    raise exception 'Ce bon de commande a déjà été passé';
  end if;
  if not exists (select 1 from public.purchase_order_lines where po_id = p_id) then
    raise exception 'Le bon de commande ne contient aucune ligne';
  end if;
  select payment_terms_days into v_terms from public.suppliers where id = v_po.supplier_id;
  v_number := public.next_document_number(v_shop, 'bon_commande');
  update public.purchase_orders
  set number = v_number, status = 'commande', order_date = current_date,
      due_date = coalesce(due_date, current_date + coalesce(v_terms, 0)),
      updated_at = now()
  where id = p_id;
  return v_number;
end;
$$;

-- Réception (totale ou partielle). p_lines : [{line_id, qty}, ...]
create or replace function public.receive_purchase_order(
  p_id                uuid,
  p_lines             jsonb,
  p_update_buy_price  boolean default true
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop    uuid;
  v_po      public.purchase_orders;
  v_item    jsonb;
  v_line    public.purchase_order_lines;
  v_qty     int;
  v_by      text;
  v_any     boolean := false;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant']::public.shop_role[]);
  select * into v_po from public.purchase_orders where id = p_id for update;
  if v_po.id is null or v_po.shop_id <> v_shop then
    raise exception 'Bon de commande introuvable';
  end if;
  if v_po.status not in ('commande', 'partiel') then
    raise exception 'Seul un bon de commande passé et non soldé peut être réceptionné';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Lignes de réception invalides';
  end if;

  select coalesce(display_name, email) into v_by from public.profiles where id = auth.uid();

  for v_item in select * from jsonb_array_elements(p_lines) loop
    v_qty := coalesce((v_item->>'qty')::int, 0);
    continue when v_qty = 0;
    if v_qty < 0 then
      raise exception 'Quantité reçue invalide';
    end if;
    select * into v_line from public.purchase_order_lines
    where id = (v_item->>'line_id')::uuid and po_id = p_id for update;
    if v_line.id is null then
      raise exception 'Ligne de commande introuvable';
    end if;
    if v_line.qty_received + v_qty > v_line.qty_ordered then
      raise exception 'Quantité reçue supérieure à la quantité commandée pour « % » (commandé : %, déjà reçu : %)',
        v_line.description, v_line.qty_ordered, v_line.qty_received;
    end if;

    update public.purchase_order_lines set qty_received = qty_received + v_qty where id = v_line.id;

    if v_line.article_id is not null then
      update public.articles
      set qty = qty + v_qty,
          buy_price = case when p_update_buy_price then v_line.unit_cost else buy_price end
      where id = v_line.article_id;
      insert into public.movements (article_id, type, qty, by_name, at, shop_id, purchase_order_id)
      values (v_line.article_id, 'reassort', v_qty, v_by, now(), v_shop, p_id);
    end if;
    v_any := true;
  end loop;

  if not v_any then
    raise exception 'Indiquez au moins une quantité reçue';
  end if;

  update public.purchase_orders po set
    received_value = (select coalesce(sum(round(qty_received * unit_cost)), 0) from public.purchase_order_lines where po_id = p_id),
    status = case when exists (select 1 from public.purchase_order_lines where po_id = p_id and qty_received < qty_ordered)
                  then 'partiel' else 'recu' end,
    updated_at = now()
  where po.id = p_id;
end;
$$;

-- Paiement fournisseur (acompte possible avant réception, jamais plus que le total commandé)
create or replace function public.record_supplier_payment(
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
  v_po   public.purchase_orders;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);
  select * into v_po from public.purchase_orders where id = p_id for update;
  if v_po.id is null or v_po.shop_id <> v_shop then
    raise exception 'Bon de commande introuvable';
  end if;
  if v_po.status in ('brouillon', 'annule') then
    raise exception 'Un paiement ne peut être enregistré que sur un bon de commande passé';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Le montant doit être positif';
  end if;
  if p_amount > v_po.total - v_po.amount_paid then
    raise exception 'Montant supérieur au reste à payer sur cette commande (%)', v_po.total - v_po.amount_paid;
  end if;
  insert into public.supplier_payments (shop_id, po_id, supplier_id, amount, method, reference, created_by)
  values (v_shop, p_id, v_po.supplier_id, p_amount, p_method, nullif(trim(p_reference), ''), auth.uid());
  update public.purchase_orders set amount_paid = amount_paid + p_amount, updated_at = now() where id = p_id;
end;
$$;

-- Annulation : seulement si rien reçu et rien payé
create or replace function public.cancel_purchase_order(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_po   public.purchase_orders;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant']::public.shop_role[]);
  select * into v_po from public.purchase_orders where id = p_id for update;
  if v_po.id is null or v_po.shop_id <> v_shop then
    raise exception 'Bon de commande introuvable';
  end if;
  if v_po.status <> 'commande' then
    raise exception 'Seule une commande passée et non encore reçue peut être annulée';
  end if;
  if v_po.amount_paid > 0 then
    raise exception 'Un paiement a déjà été versé sur cette commande : elle ne peut pas être annulée';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Le motif d''annulation est obligatoire';
  end if;
  update public.purchase_orders set status = 'annule', cancel_reason = trim(p_reason), updated_at = now() where id = p_id;
end;
$$;

create or replace function public.delete_purchase_order(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop uuid;
  v_po   public.purchase_orders;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);
  select * into v_po from public.purchase_orders where id = p_id for update;
  if v_po.id is null or v_po.shop_id <> v_shop then
    raise exception 'Bon de commande introuvable';
  end if;
  if v_po.status <> 'brouillon' then
    raise exception 'Seul un brouillon peut être supprimé (une commande passée s''annule)';
  end if;
  delete from public.purchase_orders where id = p_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Droits et temps réel
-- ----------------------------------------------------------------------------
revoke execute on function public.next_document_number(uuid, text) from public;
do $$
begin
  execute 'revoke execute on function public.next_document_number(uuid, text) from anon, authenticated';
exception when undefined_object then null;
end $$;

grant execute on function public.save_purchase_order(uuid, uuid, jsonb, date, date, text, text) to authenticated;
grant execute on function public.place_purchase_order(uuid)                        to authenticated;
grant execute on function public.receive_purchase_order(uuid, jsonb, boolean)      to authenticated;
grant execute on function public.record_supplier_payment(uuid, numeric, text, text) to authenticated;
grant execute on function public.cancel_purchase_order(uuid, text)                 to authenticated;
grant execute on function public.delete_purchase_order(uuid)                       to authenticated;

do $$
declare
  v_table text;
begin
  foreach v_table in array array['suppliers', 'purchase_orders', 'supplier_payments'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    exception when others then null;
    end;
  end loop;
end $$;
