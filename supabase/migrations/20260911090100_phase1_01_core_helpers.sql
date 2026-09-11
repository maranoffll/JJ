-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 01 : core helper functions (money, GST, numbering, identity, words)
-- ----------------------------------------------------------------------------
-- All money helpers are IMMUTABLE and use NUMERIC arithmetic exclusively so
-- that rupee values are deterministic (no floating point anywhere).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Generic updated_at maintenance
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end $$;

comment on function public.set_updated_at() is
  'BEFORE UPDATE trigger: stamps updated_at with the transaction timestamp.';

-- ---------------------------------------------------------------------------
-- Money rounding — half-up to 2 decimals, never floating point.
-- ---------------------------------------------------------------------------
create or replace function public.round_money(p_amount numeric, p_scale int default 2)
returns numeric
language sql
immutable
as $$
  select round(coalesce(p_amount, 0)::numeric, greatest(coalesce(p_scale, 2), 0));
$$;

comment on function public.round_money(numeric, int) is
  'Deterministic half-up rounding of a monetary value (default 2 decimals).';

-- ---------------------------------------------------------------------------
-- GST split. Indian GST: intra-state = CGST + SGST (half each), inter-state =
-- IGST (full). CGST is rounded and SGST is the remainder so that
-- cgst + sgst always equals the total tax exactly.
-- ---------------------------------------------------------------------------
create or replace function public.split_gst(p_taxable numeric, p_rate numeric, p_tax_type public.tax_type)
returns table (total_tax numeric, cgst numeric, sgst numeric, igst numeric)
language sql
immutable
as $$
  with computed as (
    select public.round_money(coalesce(p_taxable, 0) * coalesce(p_rate, 0) / 100.0) as tax
  )
  select
    c.tax,
    case when p_tax_type = 'INTRA_STATE' then public.round_money(c.tax / 2.0) else 0::numeric end,
    case when p_tax_type = 'INTRA_STATE' then c.tax - public.round_money(c.tax / 2.0) else 0::numeric end,
    case when p_tax_type = 'INTER_STATE' then c.tax else 0::numeric end
  from computed c;
$$;

comment on function public.split_gst(numeric, numeric, public.tax_type) is
  'Deterministic GST split: INTRA_STATE -> CGST+SGST (sum equals total), INTER_STATE -> IGST.';

-- ---------------------------------------------------------------------------
-- Indian financial year label for a date: 2026-04-01 .. 2027-03-31 => "2026-27"
-- ---------------------------------------------------------------------------
create or replace function public.financial_year(p_date date default current_date)
returns text
language sql
immutable
as $$
  select case
    when extract(month from coalesce(p_date, current_date)) >= 4
      then to_char(coalesce(p_date, current_date), 'YYYY') || '-' ||
           to_char((extract(year from coalesce(p_date, current_date))::int + 1) % 100, 'FM00')
    else to_char(extract(year from coalesce(p_date, current_date))::int - 1, 'FM0000') || '-' ||
         to_char(extract(year from coalesce(p_date, current_date))::int % 100, 'FM00')
  end;
$$;

comment on function public.financial_year(date) is
  'Indian financial year (April–March) label, e.g. 2026-27.';

-- Device-independent validation of Indian GSTIN / PAN formats.
create or replace function public.is_valid_gstin(p_value text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_value, '') ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$';
$$;

create or replace function public.is_valid_pan(p_value text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_value, '') ~ '^[A-Z]{5}[0-9]{4}[A-Z]$';
$$;

-- ---------------------------------------------------------------------------
-- Amount in words (Indian numbering system: crore / lakh / thousand / hundred).
-- Used by printable documents (Phase 13). IMMUTABLE and read-only.
-- ---------------------------------------------------------------------------
create or replace function public._two_digit_words(p_value int)
returns text
language sql
immutable
as $$
  select case
    when p_value is null or p_value <= 0 then ''
    when p_value < 20 then
      (array['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
             'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
             'Seventeen', 'Eighteen', 'Nineteen']::text[])[p_value + 1]
    else
      trim(
        (array['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety']::text[])[(p_value / 10) + 1]
        || case when p_value % 10 <> 0
                then ' ' || (array['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight',
                                   'Nine', 'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen',
                                   'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen']::text[])[(p_value % 10) + 1]
                else '' end
      )
  end;
$$;

comment on function public._two_digit_words(int) is 'Words for 1..99 (empty string for 0).';

-- Whole-number words, e.g. 1234567 -> "Twelve Lakh Thirty Four Thousand Five Hundred Sixty Seven"
create or replace function public._integer_words(p_value bigint)
returns text
language plpgsql
immutable
as $$
declare
  v_parts    text[] := array[]::text[];
  v_crore    bigint;
  v_lakh     bigint;
  v_thousand bigint;
  v_rest     int;
begin
  if p_value is null or p_value = 0 then
    return 'Zero';
  end if;

  if p_value < 0 then
    return 'Minus ' || public._integer_words(-p_value);
  end if;

  v_crore    := p_value / 10000000;
  v_lakh     := (p_value % 10000000) / 100000;
  v_thousand := (p_value % 100000) / 1000;
  v_rest     := (p_value % 1000)::int;

  if v_crore > 0 then
    v_parts := v_parts || (public._integer_words(v_crore) || ' Crore');
  end if;
  if v_lakh > 0 then
    v_parts := v_parts || (public._two_digit_words(v_lakh::int) || ' Lakh');
  end if;
  if v_thousand > 0 then
    v_parts := v_parts || (public._two_digit_words(v_thousand::int) || ' Thousand');
  end if;
  if v_rest >= 100 then
    v_parts := v_parts || (public._two_digit_words(v_rest / 100) || ' Hundred');
    v_rest := v_rest % 100;
  end if;
  if v_rest > 0 then
    v_parts := v_parts || public._two_digit_words(v_rest);
  end if;

  return array_to_string(v_parts, ' ');
end $$;

comment on function public._integer_words(bigint) is
  'Indian-system words for a whole number (crore/lakh/thousand/hundred).';

create or replace function public.amount_in_words(
  p_amount   numeric,
  p_currency text default 'Rupees',
  p_subunit  text default 'Paise'
)
returns text
language plpgsql
immutable
as $$
declare
  v_total  numeric := public.round_money(abs(coalesce(p_amount, 0)));
  v_rupees bigint  := floor(v_total)::bigint;
  v_paise  int     := floor((v_total - floor(v_total)) * 100 + 0.5)::int;
  v_words  text;
begin
  if v_paise = 100 then
    v_rupees := v_rupees + 1;
    v_paise := 0;
  end if;

  v_words := trim(coalesce(nullif(btrim(coalesce(p_currency, '')), ''), '') || ' ' ||
                  public._integer_words(v_rupees));

  if v_paise > 0 then
    v_words := v_words || ' and ' || public._two_digit_words(v_paise) || ' ' ||
               coalesce(nullif(btrim(coalesce(p_subunit, '')), ''), '');
  end if;

  return trim(v_words) || ' Only';
end $$;

comment on function public.amount_in_words(numeric, text, text) is
  'Amount in words using the Indian numbering system, e.g. "Rupees Twelve Lakh Thirty Four Thousand Five Hundred Sixty Seven and Fifty Paise Only".';

-- ---------------------------------------------------------------------------
-- Safe text -> inet conversion. Proxy headers are untrusted input; an invalid
-- value must never abort the caller's transaction.
-- ---------------------------------------------------------------------------
create or replace function public.try_inet(p_value text)
returns inet
language plpgsql
immutable
as $$
declare
  v_candidate text;
begin
  if p_value is null or btrim(p_value) = '' then
    return null;
  end if;

  v_candidate := btrim(split_part(p_value, ',', 1));

  begin
    return v_candidate::inet;
  exception when others then
    return null;
  end;
end $$;

comment on function public.try_inet(text) is
  'Returns the first address from a forwarded-for header as inet, or NULL when unparseable.';
