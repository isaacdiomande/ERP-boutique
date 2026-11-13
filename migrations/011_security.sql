-- ============================================================================
-- Migration 011 : module Sécurité & sauvegardes (phase 4, module 11).
--
-- A. Durcissement des droits
--    1. Livreur : n'accède plus en lecture aux articles, mouvements, clients,
--       devis/factures, paiements et retours (jusqu'ici masqués seulement
--       dans l'interface). Il garde ses livraisons et la liste de l'équipe.
--    2. Privilèges par défaut de Supabase trop larges :
--       - le rôle « anon » (visiteur non connecté) n'a plus aucun droit sur
--         les tables ni sur les fonctions de l'app ;
--       - TRUNCATE / TRIGGER / REFERENCES retirés à tous les rôles de l'API ;
--       - les futurs objets suivent la même règle.
--
-- B. Journal d'activité (audit_log) : qui a fait quoi, quand.
--    Rempli automatiquement par trigger sur les tables métier (création,
--    modification avec ancien → nouveau, suppression) + connexions.
--    Lecture : owner / gérant. Personne ne peut le modifier ni l'effacer
--    via l'app (aucun droit d'écriture, seules les fonctions internes y
--    écrivent).
--
-- C. Sauvegarde : export_shop_backup() renvoie TOUTES les données de la
--    boutique en un seul JSON (owner uniquement) et mémorise la date de la
--    dernière sauvegarde (shops.last_backup_at) pour le rappel dans l'app.
--
-- Pré-requis : migrations 001 à 010 appliquées. Relançable sans casse.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A0. Règles héritées de l'ancienne app web (setup.sql, setup-roles*.sql) :
--     « lecture articles », « public access … », etc. Elles autorisaient tout
--     utilisateur connecté (voire anonyme) à lire les articles et mouvements
--     de TOUTES les boutiques, et les règles Postgres s'additionnent.
--     On supprime toute règle qui ne fait pas partie du modèle actuel.
-- ----------------------------------------------------------------------------
do $$
declare
  r record;
  v_keep text[] := array[
    'articles_select_same_shop', 'articles_insert_same_shop', 'articles_update_same_shop', 'articles_delete_same_shop',
    'customer_payments_select',
    'customers_select_same_shop', 'customers_insert_same_shop', 'customers_update_same_shop', 'customers_delete_same_shop',
    'deliveries_select', 'invoice_payments_select_same_shop', 'movements_select_same_shop',
    'profiles_select_same_shop', 'profiles_select_own', 'profiles_update_own',
    'purchase_order_lines_select', 'purchase_orders_select', 'return_lines_select_same_shop', 'returns_select_same_shop',
    'sales_document_lines_select_same_shop', 'sales_documents_select_same_shop', 'shop_invitations_select_owner',
    'shops_select_own', 'supplier_payments_select',
    'suppliers_select', 'suppliers_insert', 'suppliers_update', 'suppliers_delete',
    'treasury_accounts_select', 'treasury_entries_select', 'audit_log_select'];
begin
  for r in
    select tablename, policyname from pg_policies
    where schemaname = 'public'
      and tablename in ('articles', 'movements', 'profiles', 'shops', 'customers', 'customer_payments',
        'deliveries', 'invoice_payments', 'purchase_order_lines', 'purchase_orders', 'return_lines', 'returns',
        'sales_document_lines', 'sales_documents', 'shop_invitations', 'supplier_payments', 'suppliers',
        'treasury_accounts', 'treasury_entries', 'document_counters', 'audit_log')
      and not (policyname = any (v_keep))
      and policyname not like '%\_not\_livreur'
  loop
    raise notice 'Règle supprimée : % sur %', r.policyname, r.tablename;
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- A1. Livreur : lecture restreinte (policies RESTRICTIVE, qui s'ajoutent aux
--     policies existantes sans les remplacer)
-- ----------------------------------------------------------------------------
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'articles', 'movements', 'customers', 'customer_payments',
    'sales_documents', 'sales_document_lines', 'invoice_payments',
    'returns', 'return_lines'
  ] loop
    execute format('drop policy if exists %I on public.%I', v_table || '_not_livreur', v_table);
    execute format(
      'create policy %I on public.%I as restrictive for all
         using (coalesce(public.current_shop_role()::text, '''') <> ''livreur'')
         with check (coalesce(public.current_shop_role()::text, '''') <> ''livreur'')',
      v_table || '_not_livreur', v_table);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- A2. Privilèges de l'API
-- ----------------------------------------------------------------------------
do $$
declare
  r record;
begin
  -- Tables et vues : anon n'a rien ; TRUNCATE/TRIGGER/REFERENCES retirés
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p')
  loop
    begin
      execute format('revoke all on public.%I from anon', r.relname);
      execute format('revoke truncate, trigger, references on public.%I from authenticated', r.relname);
    exception when undefined_object then null;
    end;
  end loop;

  -- Fonctions de l'app (hors extensions comme pgcrypto) : plus d'accès anon
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    begin
      execute format('revoke execute on function %s from public, anon', r.sig);
    exception when undefined_object then null;
    end;
  end loop;

  -- Objets créés plus tard par le même propriétaire
  begin
    execute 'alter default privileges in schema public revoke all on tables from anon';
    execute 'alter default privileges in schema public revoke execute on functions from public, anon';
    execute 'alter default privileges in schema public revoke truncate, trigger, references on tables from authenticated';
  exception when others then null;
  end;
end $$;

-- Les fonctions appelées par l'app restent accessibles aux utilisateurs
-- connectés (chacune vérifie elle-même boutique et rôle).
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'accept_shop_invitation', 'add_treasury_entry', 'add_treasury_transfer', 'cancel_invoice',
        'cancel_purchase_order', 'convert_quote_to_invoice', 'create_return', 'create_shop_and_owner',
        'create_shop_invitation', 'current_shop_id', 'current_shop_role', 'delete_purchase_order',
        'delete_sales_document', 'delete_treasury_entry', 'issue_invoice', 'method_account_kind',
        'place_purchase_order', 'receive_purchase_order', 'record_customer_payment', 'record_invoice_payment',
        'record_movement', 'record_supplier_payment', 'remove_member', 'report_sales', 'revoke_shop_invitation',
        'save_delivery', 'save_purchase_order', 'save_sales_document', 'save_treasury_account',
        'set_delivery_status', 'set_invoice_fne', 'set_member_role', 'set_quote_status', 'set_return_fne',
        'setup_treasury', 'treasury_balances', 'update_shop_settings')
  loop
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- B. Journal d'activité
-- ----------------------------------------------------------------------------
create table if not exists public.audit_log (
  id         bigint generated always as identity primary key,
  shop_id    uuid not null references public.shops(id) on delete cascade,
  at         timestamptz not null default now(),
  user_id    uuid,
  user_name  text,
  entity     text not null,      -- table concernée (ou 'session')
  action     text not null check (action in ('insert', 'update', 'delete', 'login')),
  record_id  uuid,
  label      text,               -- n° de document, nom… (lisible)
  changes    jsonb               -- update : {colonne: [ancien, nouveau]} ; insert/delete : ligne
);
create index if not exists idx_audit_log_shop_at on public.audit_log(shop_id, at desc);

alter table public.audit_log enable row level security;
drop policy if exists audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log
  for select using (shop_id = public.current_shop_id()
                    and public.current_shop_role() in ('owner', 'gerant'));
revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;

-- Trigger générique. Arguments (TG_ARGV) : colonnes à ignorer dans les
-- modifications (ex. qty des articles, déjà tracée par les mouvements).
create or replace function public.audit_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old     jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new     jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_shop    uuid;
  v_changes jsonb := '{}'::jsonb;
  v_key     text;
  v_ignore  text[] := array['updated_at', 'created_at', 'shop_id', 'id'] || coalesce(tg_argv::text[], '{}');
  v_uid     uuid := auth.uid();
  v_name    text;
begin
  v_shop := case when tg_table_name = 'shops' then (v_row->>'id')::uuid
                 else coalesce((v_new->>'shop_id')::uuid, (v_old->>'shop_id')::uuid) end;
  -- boutique absente (ou en cours de suppression) : rien à journaliser
  if v_shop is null or not exists (select 1 from public.shops where id = v_shop) then
    return null;
  end if;

  if tg_op = 'UPDATE' then
    for v_key in select jsonb_object_keys(v_new) loop
      if not (v_key = any (v_ignore)) and (v_new->v_key) is distinct from (v_old->v_key) then
        v_changes := v_changes || jsonb_build_object(v_key, jsonb_build_array(v_old->v_key, v_new->v_key));
      end if;
    end loop;
    if v_changes = '{}'::jsonb then
      return null;   -- rien d'intéressant (ex. seul le stock a bougé)
    end if;
  else
    v_changes := v_row - 'shop_id' - 'created_at' - 'updated_at';
  end if;

  select display_name into v_name from public.profiles where id = v_uid;

  insert into public.audit_log (shop_id, user_id, user_name, entity, action, record_id, label, changes)
  values (v_shop, v_uid, coalesce(v_name, case when v_uid is null then 'Système' end),
          tg_table_name, lower(tg_op), (v_row->>'id')::uuid,
          coalesce(v_row->>'number', v_row->>'name', v_row->>'display_name', v_row->>'label', v_row->>'email', v_row->>'category'),
          v_changes);
  return null;
end;
$$;
revoke execute on function public.audit_row() from public, anon, authenticated;

do $$
declare
  t record;
begin
  for t in
    select * from (values
      ('articles',          array['qty']),
      ('customers',         array['credit_balance']),
      ('suppliers',         array[]::text[]),
      ('sales_documents',   array['amount_paid', 'credited_amount', 'total_ht', 'total_vat']),
      ('invoice_payments',  array[]::text[]),
      ('customer_payments', array[]::text[]),
      ('returns',           array[]::text[]),
      ('purchase_orders',   array['received_value', 'amount_paid']),
      ('supplier_payments', array[]::text[]),
      ('deliveries',        array['attempts', 'started_at']),
      ('treasury_accounts', array[]::text[]),
      ('treasury_entries',  array[]::text[]),
      ('profiles',          array[]::text[]),
      ('shop_invitations',  array[]::text[]),
      ('shops',             array['last_backup_at'])
    ) as x(tbl, ign)
  loop
    execute format('drop trigger if exists trg_audit on public.%I', t.tbl);
    execute format('create trigger trg_audit after insert or update or delete on public.%I
                    for each row execute function public.audit_row(%s)',
                   t.tbl, coalesce((select string_agg(quote_literal(c), ', ') from unnest(t.ign) c), ''));
  end loop;
end $$;

-- Connexion : appelée par l'app à l'ouverture d'une session (au plus une
-- ligne toutes les 30 minutes par utilisateur).
create or replace function public.log_session_start()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_prof public.profiles;
begin
  if v_uid is null then return; end if;
  select * into v_prof from public.profiles where id = v_uid;
  if v_prof.shop_id is null then return; end if;
  if exists (select 1 from public.audit_log
             where shop_id = v_prof.shop_id and user_id = v_uid and action = 'login'
               and at > now() - interval '30 minutes') then
    return;
  end if;
  insert into public.audit_log (shop_id, user_id, user_name, entity, action, record_id, label)
  values (v_prof.shop_id, v_uid, v_prof.display_name, 'session', 'login', v_uid, v_prof.role::text);
end;
$$;
revoke execute on function public.log_session_start() from public, anon;
grant execute on function public.log_session_start() to authenticated;

-- ----------------------------------------------------------------------------
-- C. Sauvegarde complète de la boutique
-- ----------------------------------------------------------------------------
alter table public.shops add column if not exists last_backup_at timestamptz;

create or replace function public.export_shop_backup()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop   uuid;
  v_tables jsonb := '{}'::jsonb;
  v_t      text;
  v_rows   jsonb;
begin
  v_shop := public.require_shop_role(array['owner']::public.shop_role[]);

  foreach v_t in array array[
    'articles', 'movements', 'customers', 'customer_payments', 'suppliers',
    'sales_documents', 'sales_document_lines', 'invoice_payments',
    'returns', 'return_lines', 'purchase_orders', 'purchase_order_lines', 'supplier_payments',
    'deliveries', 'treasury_accounts', 'treasury_entries', 'document_counters', 'shop_invitations'
  ] loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t where t.shop_id = $1', v_t)
      into v_rows using v_shop;
    v_tables := v_tables || jsonb_build_object(v_t, v_rows);
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'email', email, 'display_name', display_name, 'role', role)), '[]'::jsonb)
    into v_rows from public.profiles where shop_id = v_shop;
  v_tables := v_tables || jsonb_build_object('profiles', v_rows);

  update public.shops set last_backup_at = now() where id = v_shop;

  return jsonb_build_object(
    'format', 'erp-boutique-backup',
    'version', 11,
    'exported_at', now(),
    'shop', (select to_jsonb(s) from public.shops s where s.id = v_shop),
    'tables', v_tables
  );
end;
$$;
revoke execute on function public.export_shop_backup() from public, anon;
grant execute on function public.export_shop_backup() to authenticated;

do $$
begin
  execute 'alter publication supabase_realtime add table public.audit_log';
exception when others then null;
end $$;

notify pgrst, 'reload schema';
