-- ============================================================================
-- 014 — Console plateforme : vue d'ensemble de toutes les boutiques
-- ----------------------------------------------------------------------------
-- Réservée aux administrateurs de la plateforme (table platform_admins, 013).
-- Ne renvoie que des chiffres de synthèse par boutique : aucune donnée de
-- détail (ventes, clients, factures) d'une boutique n'est exposée.
-- Pré-requis : migrations 001 à 013. Relançable sans casse.
-- ============================================================================

drop function if exists public.platform_shops_overview(integer);

create or replace function public.platform_shops_overview(p_days integer default 30)
returns table (
  shop_id            uuid,
  shop_name          text,
  owner_name         text,
  owner_email        text,
  licence_code       text,
  activated_at       timestamptz,
  users_count        integer,
  articles_count     integer,
  sales_count        integer,     -- ventes comptoir sur la période
  sales_amount       numeric,     -- montant des ventes comptoir sur la période
  invoices_count     integer,     -- factures émises sur la période
  invoices_amount    numeric,
  last_activity_at   timestamptz, -- dernière vente, facture ou action journalisée
  last_login_at      timestamptz,
  last_backup_at     timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
begin
  perform public.require_platform_admin();
  if p_days is null or p_days < 1 or p_days > 366 then
    raise exception 'Période invalide (1 à 366 jours)';
  end if;
  v_from := now() - make_interval(days => p_days);

  return query
  with
  own as (
    select distinct on (p.shop_id) p.shop_id, p.display_name, u.email::text as email
    from public.profiles p
    left join auth.users u on u.id = p.id
    where p.role = 'owner' and p.shop_id is not null
    order by p.shop_id, p.display_name
  ),
  usr as (
    select p.shop_id, count(*)::int as n from public.profiles p
    where p.shop_id is not null group by p.shop_id
  ),
  art as (
    select a.shop_id, count(*)::int as n from public.articles a group by a.shop_id
  ),
  mv_last as (
    select m.shop_id, max(m.at) as last_at from public.movements m group by m.shop_id
  ),
  sales as (
    -- prix de vente figé sur le mouvement s'il existe, sinon prix actuel de l'article
    select m.shop_id, count(*)::int as n,
           coalesce(sum(m.qty * coalesce((to_jsonb(m)->>'unit_price')::numeric, a.sell_price, 0)), 0) as amount
    from public.movements m
    left join public.articles a on a.id = m.article_id
    where m.type = 'vente' and m.at >= v_from
    group by m.shop_id
  ),
  inv as (
    select d.shop_id, count(*)::int as n, coalesce(sum(d.total_ttc), 0) as amount
    from public.sales_documents d
    where d.doc_type = 'facture'
      and d.status not in ('brouillon', 'annulee', 'annule')
      and coalesce(d.issue_date::timestamptz, d.created_at) >= v_from
    group by d.shop_id
  ),
  doc_last as (
    select d.shop_id, max(d.created_at) as last_at from public.sales_documents d group by d.shop_id
  ),
  aud as (
    select l.shop_id,
           max(l.at) as last_at,
           max(l.at) filter (where l.action = 'login') as last_login
    from public.audit_log l group by l.shop_id
  ),
  lic as (
    select distinct on (c.shop_id) c.shop_id, c.code, c.used_at
    from public.licence_codes c where c.shop_id is not null
    order by c.shop_id, c.used_at
  )
  select s.id,
         s.name::text,
         own.display_name::text,
         own.email,
         lic.code,
         lic.used_at,
         coalesce(usr.n, 0),
         coalesce(art.n, 0),
         coalesce(sales.n, 0),
         coalesce(sales.amount, 0),
         coalesce(inv.n, 0),
         coalesce(inv.amount, 0),
         nullif(greatest(coalesce(mv_last.last_at, '-infinity'), coalesce(doc_last.last_at, '-infinity'),
                         coalesce(aud.last_at, '-infinity')), '-infinity'::timestamptz),
         aud.last_login,
         s.last_backup_at
  from public.shops s
  left join own      on own.shop_id = s.id
  left join usr      on usr.shop_id = s.id
  left join art      on art.shop_id = s.id
  left join mv_last  on mv_last.shop_id = s.id
  left join sales    on sales.shop_id = s.id
  left join inv      on inv.shop_id = s.id
  left join doc_last on doc_last.shop_id = s.id
  left join aud      on aud.shop_id = s.id
  left join lic      on lic.shop_id = s.id
  order by 13 desc nulls last, 2;
end;
$$;

revoke all on function public.platform_shops_overview(integer) from public, anon;
grant execute on function public.platform_shops_overview(integer) to authenticated;

notify pgrst, 'reload schema';
