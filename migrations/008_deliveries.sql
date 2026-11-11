-- ============================================================================
-- Migration 008 : module Livraisons (phase 3, module 4).
--
-- Une livraison :
--   - est créée depuis une facture émise (client, contenu, montant à encaisser
--     préremplis) ou librement ; numéro LIV-AAAA-00001 ;
--   - est assignée à un membre de l'équipe (en général un livreur) ;
--   - suit les statuts : a_livrer -> en_cours -> livree | echec (motif) ;
--     un échec peut être reprogrammé (retour à a_livrer) ; annulee par un
--     responsable ;
--   - peut porter un montant à encaisser à la livraison : à la validation
--     « livrée », le montant reçu est enregistré et, si la livraison vient
--     d'une facture, il est ajouté aux paiements de cette facture.
--
-- Visibilité : un livreur ne voit que les livraisons qui lui sont assignées.
--
-- Pré-requis : migrations 001 à 007 appliquées. Relançable sans casse.
-- ============================================================================

create table if not exists public.deliveries (
  id                  uuid primary key default gen_random_uuid(),
  shop_id             uuid not null references public.shops(id) on delete cascade,
  number              text not null,
  status              text not null default 'a_livrer'
                      check (status in ('a_livrer', 'en_cours', 'livree', 'echec', 'annulee')),
  source_document_id  uuid references public.sales_documents(id) on delete set null,
  customer_id         uuid references public.customers(id) on delete set null,
  customer_name       text not null,
  customer_phone      text,
  address             text not null,
  commune             text,
  scheduled_date      date,
  time_slot           text,                -- ex. « matin », « 14h-16h »
  assigned_to         uuid references public.profiles(id) on delete set null,
  content             text,                -- contenu du colis
  delivery_fee        numeric not null default 0 check (delivery_fee >= 0),
  amount_to_collect   numeric not null default 0 check (amount_to_collect >= 0),
  collected_amount    numeric not null default 0 check (collected_amount >= 0),
  collected_method    text check (collected_method is null or collected_method in ('especes', 'orange_money', 'mtn_money', 'moov_money', 'wave', 'banque', 'cheque', 'autre')),
  collected_reference text,
  notes               text,
  failure_reason      text,
  attempts            int not null default 0,
  started_at          timestamptz,
  delivered_at        timestamptz,
  created_by          uuid references auth.users(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint deliveries_number_unique unique (shop_id, number)
);
create index if not exists idx_deliveries_shop     on public.deliveries(shop_id);
create index if not exists idx_deliveries_assigned on public.deliveries(assigned_to);
create index if not exists idx_deliveries_source   on public.deliveries(source_document_id);

alter table public.deliveries enable row level security;

-- Lecture : toute l'équipe, sauf le livreur qui ne voit que ses livraisons.
-- Écriture : uniquement via les fonctions ci-dessous.
drop policy if exists deliveries_select on public.deliveries;
create policy deliveries_select on public.deliveries
  for select using (
    shop_id = public.current_shop_id()
    and (public.current_shop_role() <> 'livreur' or assigned_to = auth.uid())
  );

-- ----------------------------------------------------------------------------
-- Numérotation : préfixe LIV
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
    when 'livraison' then 'LIV'
    else upper(p_type) end;
  return v_prefix || '-' || v_year || '-' || lpad(v_n::text, 5, '0');
end;
$$;

-- ----------------------------------------------------------------------------
-- Création / modification (tant que la livraison n'est pas partie)
-- p_data : {source_document_id?, customer_id?, customer_name, customer_phone,
--           address, commune, scheduled_date, time_slot, assigned_to,
--           content, delivery_fee, amount_to_collect, notes}
-- ----------------------------------------------------------------------------
create or replace function public.save_delivery(p_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop     uuid;
  v_del      public.deliveries;
  v_doc      public.sales_documents;
  v_cust     public.customers;
  v_assignee public.profiles;
  v_id       uuid;
  v_name     text := nullif(trim(p_data->>'customer_name'), '');
  v_phone    text := nullif(trim(p_data->>'customer_phone'), '');
  v_address  text := nullif(trim(p_data->>'address'), '');
  v_fee      numeric := coalesce(nullif(p_data->>'delivery_fee', '')::numeric, 0);
  v_collect  numeric := coalesce(nullif(p_data->>'amount_to_collect', '')::numeric, 0);
  v_src      uuid := nullif(p_data->>'source_document_id', '')::uuid;
  v_cust_id  uuid := nullif(p_data->>'customer_id', '')::uuid;
  v_assigned uuid := nullif(p_data->>'assigned_to', '')::uuid;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable', 'vendeur']::public.shop_role[]);

  if p_id is not null then
    select * into v_del from public.deliveries where id = p_id for update;
    if v_del.id is null or v_del.shop_id <> v_shop then
      raise exception 'Livraison introuvable';
    end if;
    if v_del.status not in ('a_livrer', 'echec') then
      raise exception 'Une livraison en cours, livrée ou annulée ne peut plus être modifiée';
    end if;
    v_src := v_del.source_document_id;  -- la facture d'origine ne change pas
  end if;

  if v_src is not null then
    select * into v_doc from public.sales_documents where id = v_src;
    if v_doc.id is null or v_doc.shop_id <> v_shop or v_doc.doc_type <> 'facture' or v_doc.status <> 'emise' then
      raise exception 'La livraison doit porter sur une facture émise de votre boutique';
    end if;
    v_cust_id := coalesce(v_cust_id, v_doc.customer_id);
  end if;

  if v_cust_id is not null then
    select * into v_cust from public.customers where id = v_cust_id;
    if v_cust.id is null or v_cust.shop_id <> v_shop then
      raise exception 'Ce client n''appartient pas à votre boutique';
    end if;
  end if;

  v_name  := coalesce(v_name, v_cust.name, v_doc.customer_name);
  v_phone := coalesce(v_phone, v_cust.phone, v_doc.customer_phone);
  if v_name is null then
    raise exception 'Le nom du destinataire est obligatoire';
  end if;
  if v_address is null then
    raise exception 'L''adresse de livraison est obligatoire';
  end if;
  if v_fee < 0 or v_collect < 0 then
    raise exception 'Montants invalides';
  end if;
  if v_doc.id is not null and v_collect > v_doc.total_ttc - v_doc.amount_paid - v_doc.credited_amount + v_fee then
    raise exception 'Le montant à encaisser dépasse le reste à payer de la facture (% + frais %)',
      v_doc.total_ttc - v_doc.amount_paid - v_doc.credited_amount, v_fee;
  end if;

  if v_assigned is not null then
    select * into v_assignee from public.profiles where id = v_assigned;
    if v_assignee.id is null or v_assignee.shop_id is distinct from v_shop then
      raise exception 'Le livreur choisi ne fait pas partie de la boutique';
    end if;
  end if;

  if p_id is null then
    insert into public.deliveries (
      shop_id, number, source_document_id, customer_id, customer_name, customer_phone, address, commune,
      scheduled_date, time_slot, assigned_to, content, delivery_fee, amount_to_collect, notes, created_by
    ) values (
      v_shop, public.next_document_number(v_shop, 'livraison'), v_src, v_cust.id, v_name, v_phone, v_address,
      nullif(trim(p_data->>'commune'), ''), nullif(p_data->>'scheduled_date', '')::date,
      nullif(trim(p_data->>'time_slot'), ''), v_assigned, nullif(trim(p_data->>'content'), ''),
      v_fee, v_collect, nullif(trim(p_data->>'notes'), ''), auth.uid()
    )
    returning id into v_id;
  else
    update public.deliveries set
      customer_id = v_cust.id, customer_name = v_name, customer_phone = v_phone, address = v_address,
      commune = nullif(trim(p_data->>'commune'), ''), scheduled_date = nullif(p_data->>'scheduled_date', '')::date,
      time_slot = nullif(trim(p_data->>'time_slot'), ''), assigned_to = v_assigned,
      content = nullif(trim(p_data->>'content'), ''), delivery_fee = v_fee, amount_to_collect = v_collect,
      notes = nullif(trim(p_data->>'notes'), ''), updated_at = now()
    where id = p_id;
    v_id := p_id;
  end if;
  return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- Changement de statut
--   en_cours  : livreur assigné ou responsable, depuis a_livrer
--   livree    : livreur assigné ou responsable, depuis en_cours ou a_livrer ;
--               p_amount = montant encaissé (≤ montant à encaisser) ; si la
--               livraison vient d'une facture, le paiement y est enregistré
--               (hors frais de livraison)
--   echec     : livreur assigné ou responsable, depuis en_cours/a_livrer ; motif
--   a_livrer  : reprogrammation après échec (responsable ou livreur assigné)
--   annulee   : owner / gérant, si non livrée
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
-- Droits et temps réel
-- ----------------------------------------------------------------------------
revoke execute on function public.next_document_number(uuid, text) from public;
do $$
begin
  execute 'revoke execute on function public.next_document_number(uuid, text) from anon, authenticated';
exception when undefined_object then null;
end $$;

grant execute on function public.save_delivery(uuid, jsonb) to authenticated;
grant execute on function public.set_delivery_status(uuid, text, text, numeric, text, text, date) to authenticated;

do $$
begin
  execute 'alter publication supabase_realtime add table public.deliveries';
exception when others then null;
end $$;
