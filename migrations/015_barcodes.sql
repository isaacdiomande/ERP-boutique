-- ============================================================================
-- 015 — Codes-barres des articles
-- ----------------------------------------------------------------------------
-- Un code-barres par article (facultatif), unique dans une même boutique :
-- deux boutiques différentes peuvent vendre le même produit avec le même code.
-- Pré-requis : migrations 001 à 014. Relançable sans casse.
-- ============================================================================

alter table public.articles add column if not exists barcode text;

-- Nettoyage : pas d'espaces, chaîne vide = pas de code
update public.articles set barcode = nullif(regexp_replace(barcode, '\s', '', 'g'), '')
where barcode is not null and barcode <> regexp_replace(barcode, '\s', '', 'g') or barcode = '';

alter table public.articles drop constraint if exists articles_barcode_format;
alter table public.articles add constraint articles_barcode_format
  check (barcode is null or (barcode <> '' and barcode !~ '\s' and length(barcode) <= 64));

create unique index if not exists articles_shop_barcode_uidx
  on public.articles (shop_id, barcode) where barcode is not null;

notify pgrst, 'reload schema';
