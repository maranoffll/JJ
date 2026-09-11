-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 07 : quotations + quotation line items
-- ============================================================================

create table if not exists public.quotations (
  id                        uuid primary key default gen_random_uuid(),
  quotation_number          text not null,
  sequence_value            bigint not null default 0,
  scope_key                 text not null default 'GLOBAL',
  revision                  int not null default 0,

  quotation_date            date not null default current_date,
  valid_until               date,
  client_id                 uuid not null references public.clients (id) on delete restrict,
  project_id                uuid references public.projects (id) on delete set null,
  status                    public.quotation_status not null default 'DRAFT',

  title                     text,
  subject                   text,
  brief                     text,

  -- GST context
  tax_type                  public.tax_type not null default 'INTRA_STATE',
  place_of_supply_state     text,
  place_of_supply_state_code char(2),

  currency                  char(3) not null default 'INR',

  -- totals, maintained exclusively by the line-item recalculation trigger
  subtotal                  numeric(14,2) not null default 0,
  discount_total            numeric(14,2) not null default 0,
  taxable_total             numeric(14,2) not null default 0,
  cgst_total                numeric(14,2) not null default 0,
  sgst_total                numeric(14,2) not null default 0,
  igst_total                numeric(14,2) not null default 0,
  tax_total                 numeric(14,2) not null default 0,
  round_off                 numeric(14,2) not null default 0,
  grand_total               numeric(14,2) not null default 0,

  terms                     text,
  notes                     text,

  sent_at                   timestamptz,
  accepted_at               timestamptz,
  rejected_at               timestamptz,
  cancelled_at              timestamptz,
  cancelled_reason          text,
  converted_at              timestamptz,
  converted_invoice_id      uuid,

  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  created_by                uuid,
  updated_by                uuid,

  constraint quotations_number_not_blank check (length(btrim(quotation_number)) > 0),
  constraint quotations_validity_order check (valid_until is null or valid_until >= quotation_date),
  constraint quotations_amounts_non_negative check (
    subtotal >= 0 and discount_total >= 0 and taxable_total >= 0
    and cgst_total >= 0 and sgst_total >= 0 and igst_total >= 0 and tax_total >= 0
  ),
  constraint quotations_state_code_format check (place_of_supply_state_code is null or place_of_supply_state_code ~ '^[0-9]{2}$')
);

comment on table public.quotations is
  'Client quotation with GST breakdown. Totals are derived from line items and can only be changed by the recalculation trigger.';

create unique index if not exists quotations_number_key on public.quotations (quotation_number);
create index if not exists quotations_client_idx on public.quotations (client_id, quotation_date desc);
create index if not exists quotations_project_idx on public.quotations (project_id, quotation_date desc);
create index if not exists quotations_status_idx on public.quotations (status, quotation_date desc);
create index if not exists quotations_open_idx on public.quotations (valid_until)
  where status in ('DRAFT', 'SENT');

-- ---------------------------------------------------------------------------
create table if not exists public.quotation_line_items (
  id               uuid primary key default gen_random_uuid(),
  quotation_id     uuid not null references public.quotations (id) on delete cascade,
  sort_order       int not null default 0,
  description      text not null,
  hsn_sac          text,
  unit             text not null default 'Nos',
  quantity         numeric(14,3) not null default 1,
  unit_price       numeric(14,2) not null default 0,
  discount_percent numeric(5,2) not null default 0,
  discount_amount  numeric(14,2) not null default 0,
  gross_amount     numeric(14,2) not null default 0,
  taxable_amount   numeric(14,2) not null default 0,
  gst_rate         numeric(5,2) not null references public.gst_rates (rate),
  cgst_amount      numeric(14,2) not null default 0,
  sgst_amount      numeric(14,2) not null default 0,
  igst_amount      numeric(14,2) not null default 0,
  tax_amount       numeric(14,2) not null default 0,
  total_amount     numeric(14,2) not null default 0,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,
  updated_by       uuid,

  constraint quotation_line_items_description_not_blank check (length(btrim(description)) > 0),
  constraint quotation_line_items_quantity_positive check (quantity > 0),
  constraint quotation_line_items_unit_price_non_negative check (unit_price >= 0),
  constraint quotation_line_items_discount_percent_range check (discount_percent >= 0 and discount_percent <= 100),
  constraint quotation_line_items_discount_amount_non_negative check (discount_amount >= 0)
);

comment on table public.quotation_line_items is
  'Quotation line. Monetary columns are computed by trigger; client-supplied tax values are ignored.';

create index if not exists quotation_line_items_quotation_idx on public.quotation_line_items (quotation_id, sort_order);
create index if not exists quotation_line_items_gst_idx on public.quotation_line_items (gst_rate);

-- ---------------------------------------------------------------------------
-- Line computation. The database is the only authority for money: gross,
-- discount, taxable value and GST split are all recomputed here.
-- ---------------------------------------------------------------------------
create or replace function public.compute_document_line_amounts()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_tax_type public.tax_type;
  v_gross    numeric(14,2);
  v_discount numeric(14,2);
  v_taxable  numeric(14,2);
  v_split    record;
begin
  new.quantity := coalesce(new.quantity, 1);
  new.unit_price := coalesce(new.unit_price, 0);
  new.discount_percent := coalesce(new.discount_percent, 0);
  new.discount_amount := coalesce(new.discount_amount, 0);
  new.gst_rate := public.effective_gst_rate(new.gst_rate);

  v_gross := public.round_money(new.quantity * new.unit_price);

  if new.discount_percent > 0 then
    v_discount := public.round_money(v_gross * new.discount_percent / 100.0);
  else
    v_discount := public.round_money(new.discount_amount);
  end if;

  if v_discount > v_gross then
    raise exception 'line discount (%) cannot exceed the line value (%)', v_discount, v_gross
      using errcode = 'check_violation';
  end if;

  new.discount_amount := v_discount;
  new.gross_amount := v_gross;
  v_taxable := public.round_money(v_gross - v_discount);
  new.taxable_amount := v_taxable;

  -- Tax treatment comes from the parent document, never from the browser.
  if tg_table_name = 'quotation_line_items' then
    select q.tax_type into v_tax_type from public.quotations q where q.id = new.quotation_id;
  elsif tg_table_name = 'invoice_line_items' then
    select i.tax_type into v_tax_type from public.invoices i where i.id = new.invoice_id;
  elsif tg_table_name = 'credit_note_line_items' then
    select cn.tax_type into v_tax_type from public.credit_notes cn where cn.id = new.credit_note_id;
  end if;

  select * into v_split from public.split_gst(v_taxable, new.gst_rate, coalesce(v_tax_type, 'INTRA_STATE'));

  new.cgst_amount := v_split.cgst;
  new.sgst_amount := v_split.sgst;
  new.igst_amount := v_split.igst;
  new.tax_amount := v_split.total_tax;
  new.total_amount := public.round_money(v_taxable + v_split.total_tax);

  return new;
end $$;

comment on function public.compute_document_line_amounts() is
  'BEFORE INSERT/UPDATE trigger: recomputes line money columns and the GST split deterministically.';

-- ---------------------------------------------------------------------------
-- Parent total recalculation (quotation flavour).
-- ---------------------------------------------------------------------------
create or replace function public.recalc_quotation_totals(p_quotation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_gross    numeric(14,2);
  v_discount numeric(14,2);
  v_taxable  numeric(14,2);
  v_cgst     numeric(14,2);
  v_sgst     numeric(14,2);
  v_igst     numeric(14,2);
  v_tax      numeric(14,2);
  v_enabled  boolean;
  v_grand    numeric(14,2);
  v_round    numeric(14,2);
begin
  select coalesce(sum(gross_amount), 0),
         coalesce(sum(discount_amount), 0),
         coalesce(sum(taxable_amount), 0),
         coalesce(sum(cgst_amount), 0),
         coalesce(sum(sgst_amount), 0),
         coalesce(sum(igst_amount), 0),
         coalesce(sum(tax_amount), 0)
    into v_gross, v_discount, v_taxable, v_cgst, v_sgst, v_igst, v_tax
  from public.quotation_line_items
  where quotation_id = p_quotation_id;

  select cs.round_off_enabled into v_enabled from public.company_settings cs limit 1;
  v_enabled := coalesce(v_enabled, false);

  v_grand := public.round_money(v_taxable + v_tax);
  v_round := case when v_enabled then public.round_money(round(v_grand) - v_grand) else 0 end;

  update public.quotations q
     set subtotal       = v_gross,
         discount_total = v_discount,
         taxable_total  = v_taxable,
         cgst_total     = v_cgst,
         sgst_total     = v_sgst,
         igst_total     = v_igst,
         tax_total      = v_tax,
         round_off      = v_round,
         grand_total    = public.round_money(v_grand + v_round),
         updated_at     = now()
   where q.id = p_quotation_id;
end $$;

comment on function public.recalc_quotation_totals(uuid) is
  'Recomputes quotation header totals from its line items (single source of truth for money).';

-- Line-item triggers ------------------------------------------------------
drop trigger if exists quotation_line_items_compute on public.quotation_line_items;
create trigger quotation_line_items_compute
  before insert or update on public.quotation_line_items
  for each row execute function public.compute_document_line_amounts();

drop trigger if exists quotation_line_items_stamp_actor on public.quotation_line_items;
create trigger quotation_line_items_stamp_actor
  before insert or update on public.quotation_line_items
  for each row execute function public.stamp_actor_columns();

create or replace function public.quotation_line_items_after_change()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.recalc_quotation_totals(coalesce(new.quotation_id, old.quotation_id));
  return null;
end $$;

drop trigger if exists quotation_line_items_recalc on public.quotation_line_items;
create trigger quotation_line_items_recalc
  after insert or update or delete on public.quotation_line_items
  for each row execute function public.quotation_line_items_after_change();

-- ---------------------------------------------------------------------------
-- Quotation lifecycle guard.
--   DRAFT / SENT            -> editable
--   ACCEPTED / REJECTED /
--   CONVERTED / CANCELLED   -> financial content frozen
-- ---------------------------------------------------------------------------
create or replace function public.quotations_guard_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_frozen_old boolean := old.status in ('ACCEPTED', 'REJECTED', 'CONVERTED', 'CANCELLED');
  v_line_count int;
  v_allowed    boolean;
begin
  if v_frozen_old then
    -- Only the status itself may change on a frozen quotation, and only from
    -- ACCEPTED to CONVERTED (handled by convert_quotation_to_invoice).
    if new.status is distinct from old.status
       and not (old.status = 'ACCEPTED' and new.status = 'CONVERTED') then
      raise exception 'quotation % is % and can no longer be modified',
        old.quotation_number, old.status
        using errcode = 'insufficient_privilege';
    end if;

    if (new.quotation_number, new.quotation_date, new.client_id, new.tax_type,
        new.subtotal, new.discount_total, new.taxable_total,
        new.cgst_total, new.sgst_total, new.igst_total, new.tax_total,
        new.round_off, new.grand_total)
       is distinct from
       (old.quotation_number, old.quotation_date, old.client_id, old.tax_type,
        old.subtotal, old.discount_total, old.taxable_total,
        old.cgst_total, old.sgst_total, old.igst_total, old.tax_total,
        old.round_off, old.grand_total) then
      raise exception 'quotation % is % — financial fields are read-only', old.quotation_number, old.status
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  if new.status is distinct from old.status then
    v_allowed := case old.status
      when 'DRAFT'     then new.status in ('SENT', 'ACCEPTED', 'REJECTED', 'EXPIRED', 'CANCELLED')
      when 'SENT'      then new.status in ('ACCEPTED', 'REJECTED', 'EXPIRED', 'CANCELLED', 'CONVERTED')
      when 'ACCEPTED'  then new.status in ('CONVERTED', 'CANCELLED')
      when 'REJECTED'  then new.status = 'CANCELLED'
      when 'EXPIRED'   then new.status in ('ACCEPTED', 'CANCELLED')
      else false
    end;

    if not v_allowed then
      raise exception 'invalid quotation status transition: % -> %', old.status, new.status
        using errcode = 'check_violation';
    end if;

    -- Issuing, accepting, rejecting or cancelling a quotation is a commercial
    -- commitment and needs the stronger permission. Permissive RLS policies are
    -- OR'ed, so this check cannot be expressed as a second policy.
    if new.status = 'CONVERTED' then
      perform public.require_permission('quotations.convert');
    else
      perform public.require_permission('quotations.issue');
    end if;

    if new.status = 'SENT' then
      select count(*) into v_line_count from public.quotation_line_items where quotation_id = new.id;
      if v_line_count = 0 then
        raise exception 'a quotation must have at least one line item before it can be sent'
          using errcode = 'check_violation';
      end if;
      new.sent_at := coalesce(new.sent_at, now());
    elsif new.status = 'ACCEPTED' then
      new.accepted_at := coalesce(new.accepted_at, now());
    elsif new.status = 'REJECTED' then
      new.rejected_at := coalesce(new.rejected_at, now());
    elsif new.status = 'CANCELLED' then
      new.cancelled_at := coalesce(new.cancelled_at, now());
      if coalesce(btrim(new.cancelled_reason), '') = '' then
        raise exception 'a cancellation reason is required'
          using errcode = 'check_violation';
      end if;
    elsif new.status = 'CONVERTED' then
      new.converted_at := coalesce(new.converted_at, now());
    end if;
  end if;

  return new;
end $$;

drop trigger if exists quotations_guard_lifecycle on public.quotations;
create trigger quotations_guard_lifecycle
  before update on public.quotations
  for each row execute function public.quotations_guard_lifecycle();

drop trigger if exists quotations_set_updated_at on public.quotations;
create trigger quotations_set_updated_at
  before update on public.quotations
  for each row execute function public.set_updated_at();

drop trigger if exists quotations_stamp_actor on public.quotations;
create trigger quotations_stamp_actor
  before insert or update on public.quotations
  for each row execute function public.stamp_actor_columns();

-- Numbering: allocated by the database, never supplied by the browser.
create or replace function public.quotations_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_prefix text;
  v_row    record;
  v_client_state_code char(2);
begin
  if new.quotation_number is null or btrim(new.quotation_number) = '' then
    select coalesce(cs.quotation_prefix, 'QT') into v_prefix from public.company_settings cs limit 1;
    v_prefix := coalesce(v_prefix, 'QT');

    select * into v_row from public.next_document_number('quotation', v_prefix, null, 4);
    new.quotation_number := v_row.document_number;
    new.sequence_value := v_row.sequence_value;
    new.scope_key := v_row.scope_key;
  end if;

  -- Tax context is derived from master data; a browser-supplied value is ignored.
  if new.client_id is not null then
    new.place_of_supply_state_code := public.derive_place_of_supply_state_code(new.client_id, new.place_of_supply_state_code);
    new.tax_type := public.derive_document_tax_type(new.client_id, new.place_of_supply_state_code);
  end if;

  if new.valid_until is null then
    select new.quotation_date + coalesce(cs.quotation_validity_days, 15) into new.valid_until
    from public.company_settings cs limit 1;
    new.valid_until := coalesce(new.valid_until, new.quotation_date + 15);
  end if;

  return new;
end $$;

-- Place of supply / GST treatment is recomputed on every write while the
-- quotation is still editable, so it can never be overridden by the client.
create or replace function public.quotations_derive_tax_context()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if old.status in ('ACCEPTED', 'REJECTED', 'CONVERTED', 'CANCELLED') then
    return new;
  end if;

  if new.client_id is not null then
    new.place_of_supply_state_code := public.derive_place_of_supply_state_code(new.client_id, new.place_of_supply_state_code);
    new.tax_type := public.derive_document_tax_type(new.client_id, new.place_of_supply_state_code);
  end if;

  return new;
end $$;

drop trigger if exists quotations_derive_tax_context on public.quotations;
create trigger quotations_derive_tax_context
  before update on public.quotations
  for each row execute function public.quotations_derive_tax_context();

drop trigger if exists quotations_assign_number on public.quotations;
create trigger quotations_assign_number
  before insert on public.quotations
  for each row execute function public.quotations_assign_number();

drop trigger if exists quotations_audit on public.quotations;
create trigger quotations_audit
  after insert or update on public.quotations
  for each row execute function public.audit_row_change();

drop trigger if exists quotation_line_items_audit on public.quotation_line_items;
create trigger quotation_line_items_audit
  after insert or update or delete on public.quotation_line_items
  for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.quotations enable row level security;
alter table public.quotation_line_items enable row level security;

drop policy if exists quotations_select on public.quotations;
create policy quotations_select on public.quotations
  for select to authenticated
  using (public.has_permission('quotations.view'));

drop policy if exists quotations_insert on public.quotations;
create policy quotations_insert on public.quotations
  for insert to authenticated
  with check (public.has_permission('quotations.create'));

drop policy if exists quotations_update on public.quotations;
create policy quotations_update on public.quotations
  for update to authenticated
  using (public.has_permission('quotations.update'))
  with check (public.has_permission('quotations.update'));

drop policy if exists quotation_line_items_select on public.quotation_line_items;
create policy quotation_line_items_select on public.quotation_line_items
  for select to authenticated
  using (public.has_permission('quotations.view'));

drop policy if exists quotation_line_items_write on public.quotation_line_items;
create policy quotation_line_items_write on public.quotation_line_items
  for all to authenticated
  using (public.has_permission('quotations.update'))
  with check (public.has_permission('quotations.update'));
