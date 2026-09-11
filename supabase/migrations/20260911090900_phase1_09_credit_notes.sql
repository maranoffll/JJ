-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 09 : credit notes + line items
-- ----------------------------------------------------------------------------
-- Credit notes are the controlled correction mechanism for issued invoices.
-- ============================================================================

create table if not exists public.credit_notes (
  id                        uuid primary key default gen_random_uuid(),
  credit_note_number        text not null,
  sequence_value            bigint not null default 0,
  scope_key                 text not null default 'GLOBAL',

  credit_note_date          date not null default current_date,
  client_id                 uuid not null references public.clients (id) on delete restrict,
  invoice_id                uuid references public.invoices (id) on delete restrict,
  project_id                uuid references public.projects (id) on delete set null,
  status                    public.credit_note_status not null default 'DRAFT',

  reason                    text,
  notes                     text,

  tax_type                  public.tax_type not null default 'INTRA_STATE',
  place_of_supply_state_code char(2),
  currency                  char(3) not null default 'INR',

  subtotal                  numeric(14,2) not null default 0,
  discount_total            numeric(14,2) not null default 0,
  taxable_total             numeric(14,2) not null default 0,
  cgst_total                numeric(14,2) not null default 0,
  sgst_total                numeric(14,2) not null default 0,
  igst_total                numeric(14,2) not null default 0,
  tax_total                 numeric(14,2) not null default 0,
  round_off                 numeric(14,2) not null default 0,
  grand_total               numeric(14,2) not null default 0,

  issued_at                 timestamptz,
  issued_by                 uuid references public.user_profiles (id) on delete set null,
  cancelled_at              timestamptz,
  cancelled_by              uuid references public.user_profiles (id) on delete set null,
  cancelled_reason          text,

  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  created_by                uuid,
  updated_by                uuid,

  constraint credit_notes_number_not_blank check (length(btrim(credit_note_number)) > 0),
  constraint credit_notes_amounts_non_negative check (
    subtotal >= 0 and discount_total >= 0 and taxable_total >= 0
    and cgst_total >= 0 and sgst_total >= 0 and igst_total >= 0 and tax_total >= 0
    and grand_total >= 0
  ),
  constraint credit_notes_issued_consistency check (
    (status = 'DRAFT' and issued_at is null)
    or (status = 'ISSUED' and issued_at is not null)
    or (status = 'CANCELLED')
  ),
  constraint credit_notes_cancelled_consistency check (
    (status <> 'CANCELLED' and cancelled_at is null)
    or (status = 'CANCELLED' and cancelled_at is not null)
  )
);

comment on table public.credit_notes is
  'Credit note against an invoice (or a standalone client credit). ISSUED credit notes reduce receivables.';

create unique index if not exists credit_notes_number_key on public.credit_notes (credit_note_number);
create index if not exists credit_notes_client_idx on public.credit_notes (client_id, credit_note_date desc);
create index if not exists credit_notes_invoice_idx on public.credit_notes (invoice_id) where invoice_id is not null;
create index if not exists credit_notes_status_idx on public.credit_notes (status, credit_note_date desc);

-- ---------------------------------------------------------------------------
create table if not exists public.credit_note_line_items (
  id               uuid primary key default gen_random_uuid(),
  credit_note_id   uuid not null references public.credit_notes (id) on delete cascade,
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

  constraint credit_note_line_items_description_not_blank check (length(btrim(description)) > 0),
  constraint credit_note_line_items_quantity_positive check (quantity > 0),
  constraint credit_note_line_items_unit_price_non_negative check (unit_price >= 0),
  constraint credit_note_line_items_discount_percent_range check (discount_percent >= 0 and discount_percent <= 100),
  constraint credit_note_line_items_discount_amount_non_negative check (discount_amount >= 0)
);

create index if not exists credit_note_line_items_parent_idx on public.credit_note_line_items (credit_note_id, sort_order);

-- ---------------------------------------------------------------------------
create or replace function public.recalc_credit_note_totals(p_credit_note_id uuid)
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
  from public.credit_note_line_items
  where credit_note_id = p_credit_note_id;

  select cs.round_off_enabled into v_enabled from public.company_settings cs limit 1;
  v_enabled := coalesce(v_enabled, false);

  v_grand := public.round_money(v_taxable + v_tax);
  v_round := case when v_enabled then public.round_money(round(v_grand) - v_grand) else 0 end;

  update public.credit_notes cn
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
   where cn.id = p_credit_note_id;
end $$;

-- ---------------------------------------------------------------------------
create or replace function public.credit_notes_guard_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_frozen_columns constant text[] := array[
    'credit_note_number', 'sequence_value', 'scope_key', 'credit_note_date',
    'client_id', 'invoice_id', 'tax_type', 'place_of_supply_state_code', 'currency',
    'subtotal', 'discount_total', 'taxable_total', 'cgst_total', 'sgst_total',
    'igst_total', 'tax_total', 'round_off', 'grand_total'
  ];
  v_col         text;
  v_old_json    jsonb;
  v_new_json    jsonb;
  v_lines       int;
  v_other_total numeric(14,2);
  v_invoice     public.invoices;
  v_prefix      text;
  v_row         record;
  v_client_state_code char(2);
  v_client_of_invoice uuid;
begin
  if tg_op = 'INSERT' then
    if new.credit_note_number is null or btrim(new.credit_note_number) = '' then
      select coalesce(cs.credit_note_prefix, 'CN') into v_prefix from public.company_settings cs limit 1;
      select * into v_row from public.next_document_number('credit_note', coalesce(v_prefix, 'CN'), null, 4);
      new.credit_note_number := v_row.document_number;
      new.sequence_value := v_row.sequence_value;
      new.scope_key := v_row.scope_key;
    end if;

    if new.invoice_id is not null then
      select * into v_invoice from public.invoices where id = new.invoice_id;
      if not found then
        raise exception 'invoice % not found', new.invoice_id using errcode = 'no_data_found';
      end if;
      if v_invoice.status = 'DRAFT' then
        raise exception 'a credit note cannot target a draft invoice; edit the draft instead'
          using errcode = 'check_violation';
      end if;
      new.client_id := v_invoice.client_id;
      new.tax_type := v_invoice.tax_type;
      new.place_of_supply_state_code := coalesce(new.place_of_supply_state_code, v_invoice.place_of_supply_state_code);
      new.project_id := coalesce(new.project_id, v_invoice.project_id);
    else
      select c.billing_state_code into v_client_state_code from public.clients c where c.id = new.client_id;
      new.tax_type := public.resolve_tax_type(v_client_state_code);
      new.place_of_supply_state_code := coalesce(new.place_of_supply_state_code, v_client_state_code);
    end if;

    if new.status = 'ISSUED' then
      perform public.require_permission('credit_notes.issue');
      perform public.credit_notes_assert_issuable(new.id, new.reason, null, new.grand_total, new.invoice_id);
      new.issued_at := coalesce(new.issued_at, now());
      new.issued_by := coalesce(new.issued_by, auth.uid());
    end if;

    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'credit note % is % and can never be deleted', old.credit_note_number, old.status
        using errcode = 'insufficient_privilege';
    end if;
    perform public.require_permission('credit_notes.create');
    return old;
  end if;

  v_old_json := to_jsonb(old);
  v_new_json := to_jsonb(new);

  if old.status = 'CANCELLED' then
    raise exception 'credit note % is CANCELLED and is terminal', old.credit_note_number
      using errcode = 'insufficient_privilege';
  end if;

  if old.status = 'ISSUED' then
    foreach v_col in array v_frozen_columns loop
      if v_new_json -> v_col is distinct from v_old_json -> v_col then
        raise exception 'credit note % is ISSUED: % cannot be changed', old.credit_note_number, v_col
          using errcode = 'insufficient_privilege';
      end if;
    end loop;

    if new.status not in ('ISSUED', 'CANCELLED') then
      raise exception 'invalid credit note status transition: % -> %', old.status, new.status
        using errcode = 'check_violation';
    end if;

    if new.status = 'CANCELLED' then
      perform public.require_permission('credit_notes.cancel');
      new.cancelled_at := coalesce(new.cancelled_at, now());
      new.cancelled_by := coalesce(new.cancelled_by, auth.uid());
      if coalesce(btrim(new.cancelled_reason), '') = '' then
        raise exception 'a cancellation reason is required' using errcode = 'check_violation';
      end if;
    end if;
  end if;

  if new.status is distinct from old.status and old.status = 'DRAFT' and new.status = 'ISSUED' then
    perform public.require_permission('credit_notes.issue');

    select count(*) into v_lines from public.credit_note_line_items where credit_note_id = new.id;
    if v_lines = 0 then
      raise exception 'credit note % cannot be issued without line items', new.credit_note_number
        using errcode = 'check_violation';
    end if;

    if coalesce(btrim(new.reason), '') = '' then
      raise exception 'a reason is required before issuing a credit note'
        using errcode = 'check_violation';
    end if;

    perform public.credit_notes_assert_issuable(new.id, new.reason, new.id, new.grand_total, new.invoice_id);

    new.issued_at := coalesce(new.issued_at, now());
    new.issued_by := coalesce(new.issued_by, auth.uid());
  end if;

  if new.status is distinct from old.status and new.status = 'CANCELLED' and old.status = 'DRAFT' then
    perform public.require_permission('credit_notes.cancel');
    new.cancelled_at := now();
    new.cancelled_by := coalesce(new.cancelled_by, auth.uid());
  end if;

  return new;
end $$;

-- Issue requirements, shared by the INSERT and UPDATE paths so a credit note
-- cannot be created directly in ISSUED state with no lines or an excess value.
create or replace function public.credit_notes_assert_issuable(
  p_credit_note_id uuid,
  p_reason         text,
  p_exclude_id     uuid,
  p_grand_total    numeric,
  p_invoice_id     uuid
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_lines       int;
  v_other_total numeric(14,2);
  v_invoice     public.invoices;
begin
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is required before issuing a credit note'
      using errcode = 'check_violation';
  end if;

  -- On INSERT the line items cannot exist yet; the check is then deferred to the
  -- status UPDATE, which is the only supported way to issue a created note.
  if p_credit_note_id is not null then
    select count(*) into v_lines from public.credit_note_line_items where credit_note_id = p_credit_note_id;
    if v_lines = 0 then
      raise exception 'a credit note must have at least one line item before it can be issued'
        using errcode = 'check_violation';
    end if;
  end if;

  if p_invoice_id is not null then
    select * into v_invoice from public.invoices where id = p_invoice_id for update;
    if not found then
      raise exception 'invoice % not found', p_invoice_id using errcode = 'no_data_found';
    end if;

    select coalesce(sum(cn.grand_total), 0) into v_other_total
    from public.credit_notes cn
    where cn.invoice_id = p_invoice_id
      and cn.status = 'ISSUED'
      and (p_exclude_id is null or cn.id <> p_exclude_id);

    if v_other_total + coalesce(p_grand_total, 0) > v_invoice.grand_total then
      raise exception
        'credit notes for invoice % (%) would exceed the invoice value (%)',
        v_invoice.invoice_number,
        public.round_money(v_other_total + coalesce(p_grand_total, 0)),
        v_invoice.grand_total
        using errcode = 'check_violation';
    end if;
  end if;
end $$;

-- Credit note line items may only change while the note is a draft.
create or replace function public.credit_note_line_items_guard_parent_state()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_status public.credit_note_status;
  v_number text;
begin
  select cn.status, cn.credit_note_number into v_status, v_number
  from public.credit_notes cn
  where cn.id = coalesce(new.credit_note_id, old.credit_note_id);

  if v_status <> 'DRAFT' then
    raise exception 'credit note % is % — line items can only be changed while it is a draft', v_number, v_status
      using errcode = 'insufficient_privilege';
  end if;

  return coalesce(new, old);
end $$;

drop trigger if exists credit_note_line_items_compute on public.credit_note_line_items;
create trigger credit_note_line_items_compute
  before insert or update on public.credit_note_line_items
  for each row execute function public.compute_document_line_amounts();

drop trigger if exists credit_note_line_items_stamp_actor on public.credit_note_line_items;
create trigger credit_note_line_items_stamp_actor
  before insert or update on public.credit_note_line_items
  for each row execute function public.stamp_actor_columns();

drop trigger if exists credit_note_line_items_guard_parent on public.credit_note_line_items;
create trigger credit_note_line_items_guard_parent
  before insert or update or delete on public.credit_note_line_items
  for each row execute function public.credit_note_line_items_guard_parent_state();

create or replace function public.credit_note_line_items_after_change()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.recalc_credit_note_totals(coalesce(new.credit_note_id, old.credit_note_id));
  return null;
end $$;

drop trigger if exists credit_note_line_items_recalc on public.credit_note_line_items;
create trigger credit_note_line_items_recalc
  after insert or update or delete on public.credit_note_line_items
  for each row execute function public.credit_note_line_items_after_change();

drop trigger if exists credit_notes_guard_lifecycle on public.credit_notes;
create trigger credit_notes_guard_lifecycle
  before insert or update or delete on public.credit_notes
  for each row execute function public.credit_notes_guard_lifecycle();

drop trigger if exists credit_notes_set_updated_at on public.credit_notes;
create trigger credit_notes_set_updated_at
  before update on public.credit_notes
  for each row execute function public.set_updated_at();

drop trigger if exists credit_notes_stamp_actor on public.credit_notes;
create trigger credit_notes_stamp_actor
  before insert or update on public.credit_notes
  for each row execute function public.stamp_actor_columns();

-- Issuing or cancelling a credit note changes the invoice's credited amount.
create or replace function public.credit_notes_after_status_change()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.invoice_id is not null and (old.status is distinct from new.status) then
    perform public.refresh_invoice_collections(new.invoice_id);
  end if;

  if tg_op = 'INSERT' and new.status = 'ISSUED' and new.invoice_id is not null then
    perform public.refresh_invoice_collections(new.invoice_id);
  end if;

  return null;
end $$;

drop trigger if exists credit_notes_refresh_invoice on public.credit_notes;
create trigger credit_notes_refresh_invoice
  after insert or update on public.credit_notes
  for each row execute function public.credit_notes_after_status_change();

drop trigger if exists credit_notes_audit on public.credit_notes;
create trigger credit_notes_audit
  after insert or update on public.credit_notes
  for each row execute function public.audit_row_change();

drop trigger if exists credit_note_line_items_audit on public.credit_note_line_items;
create trigger credit_note_line_items_audit
  after insert or update or delete on public.credit_note_line_items
  for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.credit_notes enable row level security;
alter table public.credit_note_line_items enable row level security;

drop policy if exists credit_notes_select on public.credit_notes;
create policy credit_notes_select on public.credit_notes
  for select to authenticated
  using (public.has_permission('credit_notes.view'));

drop policy if exists credit_notes_insert on public.credit_notes;
create policy credit_notes_insert on public.credit_notes
  for insert to authenticated
  with check (public.has_permission('credit_notes.create'));

drop policy if exists credit_notes_update on public.credit_notes;
create policy credit_notes_update on public.credit_notes
  for update to authenticated
  using (public.has_permission('credit_notes.create') or public.has_permission('credit_notes.cancel'))
  with check (public.has_permission('credit_notes.create') or public.has_permission('credit_notes.cancel'));

drop policy if exists credit_notes_delete on public.credit_notes;
create policy credit_notes_delete on public.credit_notes
  for delete to authenticated
  using (public.has_permission('credit_notes.create') and status = 'DRAFT');

drop policy if exists credit_note_line_items_select on public.credit_note_line_items;
create policy credit_note_line_items_select on public.credit_note_line_items
  for select to authenticated
  using (public.has_permission('credit_notes.view'));

drop policy if exists credit_note_line_items_write on public.credit_note_line_items;
create policy credit_note_line_items_write on public.credit_note_line_items
  for all to authenticated
  using (public.has_permission('credit_notes.create'))
  with check (public.has_permission('credit_notes.create'));
