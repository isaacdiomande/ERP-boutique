-- ============================================================================
-- Migration 010 : module Rapports & statistiques (phase 4, module 9).
--
-- 1. Coût d'achat figé au moment de la vente (unit_cost) sur les mouvements,
--    les lignes de facture et les lignes de retour, rempli automatiquement
--    par trigger depuis articles.buy_price. Sans cela, la marge d'une vente
--    passée changerait à chaque modification du prix d'achat.
--    Pour l'historique antérieur, les rapports retombent sur le prix d'achat
--    actuel (et le prix de vente actuel pour les anciennes ventes comptoir).
--
-- 2. report_sales(p_from, p_to) : renvoie en un seul JSON (pas de limite de
--    1000 lignes de l'API) toutes les lignes de vente de la période :
--      - ventes comptoir (mouvements « vente » hors facture)
--      - lignes des factures émises (date d'émission ; annulées exclues)
--      - lignes des retours (en négatif ; coût repris seulement si remis en stock)
--    + les pertes de la période. Le regroupement (article, catégorie,
--    vendeur, client, moyen, jour, mois) est fait dans l'app.
--
-- Accès : owner / gérant / comptable.
-- Pré-requis : migrations 001 à 009 appliquées. Relançable sans casse.
-- ============================================================================

alter table public.movements            add column if not exists unit_cost numeric;
alter table public.sales_document_lines add column if not exists unit_cost numeric;
alter table public.return_lines         add column if not exists unit_cost numeric;

create or replace function public.fill_unit_cost()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.unit_cost is null and new.article_id is not null then
    select buy_price into new.unit_cost from public.articles where id = new.article_id;
  end if;
  return new;
end;
$$;
revoke execute on function public.fill_unit_cost() from public, anon, authenticated;

drop trigger if exists trg_movements_unit_cost on public.movements;
create trigger trg_movements_unit_cost before insert on public.movements
  for each row execute function public.fill_unit_cost();

drop trigger if exists trg_sales_lines_unit_cost on public.sales_document_lines;
create trigger trg_sales_lines_unit_cost before insert on public.sales_document_lines
  for each row execute function public.fill_unit_cost();

drop trigger if exists trg_return_lines_unit_cost on public.return_lines;
create trigger trg_return_lines_unit_cost before insert on public.return_lines
  for each row execute function public.fill_unit_cost();

-- Index utiles aux rapports
create index if not exists idx_movements_shop_at on public.movements(shop_id, at);
create index if not exists idx_sales_documents_shop_issue on public.sales_documents(shop_id, issue_date);
create index if not exists idx_returns_shop_date on public.returns(shop_id, return_date);

-- ----------------------------------------------------------------------------
-- report_sales
-- Chaque ligne : d (date), src (comptoir|facture|retour), ref, art (id),
-- name, cat, qty, ca, cost, seller, cust, method, est (coût estimé = prix
-- d'achat actuel faute de coût figé).
-- ----------------------------------------------------------------------------
create or replace function public.report_sales(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_shop  uuid;
  v_lines jsonb;
  v_loss  jsonb;
begin
  v_shop := public.require_shop_role(array['owner', 'gerant', 'comptable']::public.shop_role[]);
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Période invalide';
  end if;
  if p_to - p_from > 1100 then
    raise exception 'Période trop longue (3 ans maximum)';
  end if;

  with lines as (
    -- Ventes au comptoir
    select (m.at at time zone 'Africa/Abidjan')::date as d,
           'comptoir'::text as src,
           null::text as ref,
           m.article_id as art,
           coalesce(a.name, 'Article supprimé') as name,
           a.category as cat,
           m.qty::numeric as qty,
           m.qty * coalesce(m.unit_price, a.sell_price, 0) as ca,
           m.qty * coalesce(m.unit_cost, a.buy_price, 0) as cost,
           coalesce(nullif(m.by_name, ''), 'Inconnu') as seller,
           c.name as cust,
           case when m.on_credit then 'credit' else coalesce(m.payment_method, 'inconnu') end as method,
           (m.unit_cost is null) as est
    from public.movements m
    left join public.articles a on a.id = m.article_id
    left join public.customers c on c.id = m.customer_id
    where m.shop_id = v_shop
      and m.type = 'vente'
      and m.document_id is null
      and (m.at at time zone 'Africa/Abidjan')::date between p_from and p_to

    union all
    -- Lignes de factures émises
    select d.issue_date, 'facture', d.number,
           l.article_id,
           coalesce(a.name, l.description),
           case when l.article_id is null then 'Hors stock' else a.category end,
           l.qty::numeric,
           l.line_total_ttc,
           case when l.article_id is null then 0 else l.qty * coalesce(l.unit_cost, a.buy_price, 0) end,
           coalesce(p.display_name, 'Inconnu'),
           coalesce(d.customer_name, c.name),
           'facture',
           (l.article_id is not null and l.unit_cost is null)
    from public.sales_documents d
    join public.sales_document_lines l on l.document_id = d.id
    left join public.articles a on a.id = l.article_id
    left join public.customers c on c.id = d.customer_id
    left join public.profiles p on p.id = d.created_by
    where d.shop_id = v_shop
      and d.doc_type = 'facture'
      and d.status = 'emise'
      and d.issue_date between p_from and p_to

    union all
    -- Retours (en négatif). Le coût n'est déduit que si l'article revient
    -- en stock : un article défectueux non remis en stock reste une perte.
    select r.return_date, 'retour', r.number,
           l.article_id,
           coalesce(a.name, l.description),
           case when l.article_id is null then 'Hors stock' else a.category end,
           -l.qty::numeric,
           -l.line_total_ttc,
           case when l.restock and l.article_id is not null
                then -(l.qty * coalesce(l.unit_cost, a.buy_price, 0)) else 0 end,
           coalesce(p.display_name, 'Inconnu'),
           coalesce(r.customer_name, c.name),
           case r.refund_type when 'remboursement' then coalesce(r.refund_method, 'inconnu')
                              when 'deduction_facture' then 'facture'
                              when 'credit_client' then 'credit'
                              else 'echange' end,
           (l.restock and l.article_id is not null and l.unit_cost is null)
    from public.returns r
    join public.return_lines l on l.return_id = r.id
    left join public.articles a on a.id = l.article_id
    left join public.customers c on c.id = r.customer_id
    left join public.profiles p on p.id = r.created_by
    where r.shop_id = v_shop
      and r.return_date between p_from and p_to
  )
  select coalesce(jsonb_agg(to_jsonb(lines) order by d, src), '[]'::jsonb) into v_lines from lines;

  select coalesce(jsonb_agg(jsonb_build_object(
           'd', (m.at at time zone 'Africa/Abidjan')::date,
           'art', m.article_id,
           'name', coalesce(a.name, 'Article supprimé'),
           'cat', a.category,
           'qty', m.qty,
           'cost', m.qty * coalesce(m.unit_cost, a.buy_price, 0),
           'by', m.by_name
         ) order by m.at), '[]'::jsonb)
  into v_loss
  from public.movements m
  left join public.articles a on a.id = m.article_id
  where m.shop_id = v_shop
    and m.type = 'perte'
    and (m.at at time zone 'Africa/Abidjan')::date between p_from and p_to;

  return jsonb_build_object('from', p_from, 'to', p_to, 'lines', v_lines, 'losses', v_loss);
end;
$$;

revoke execute on function public.report_sales(date, date) from public, anon;
grant execute on function public.report_sales(date, date) to authenticated;

notify pgrst, 'reload schema';
