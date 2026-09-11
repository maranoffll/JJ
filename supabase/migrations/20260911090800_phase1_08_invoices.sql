-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 08 : invoices, invoice line items, immutability, quotation
--                conversion
-- ----------------------------------------------------------------------------
-- An ISSUED invoice is a statutory document. Its financial content is frozen
-- by database triggers; corrections use credit notes or cancellation.
-- ============================================================================

create table if not exists public.invoices (
  id                        uuid primary key default gen_random_uuid(),
  invoice_number            text not null,
  sequence_value            bigint not null default 0,
  scope_key                 text not null default 'GLOBAL',

  invoice_date              date not null default current_date,
  due_date                  date,
  client_id                 uuid not null references public.clients (id) on delete restrict,
  project_id                uuid references public.projects (id) on delete set null,
  quotation_id              uuid references public.quotations (id) on delete set null,
  status                    public.invoice_status not null default 'DRAFT',

  title                     text,
  notes                     text,
  terms                     text,
  po_number                 text,
  reference                 text,

  tax_type                  public.tax_type not null default 'INTRA_STATE',
  place_of_supply_state     text,
  place_of_supply_state_code char(2),
  currency                  char(3) not null default 'INR',
  is_reverse_charge         boolean not null default false,

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

  -- derived collections, maintained from posted payments and issued credit notes
  amount_paid               numeric(14,2) not null default 0,
  amount_credited           numeric(14,2) not null default 0,

  issued_at                 timestamptz,
  issued_by                 uuid references public.user_profiles (id) on delete set null,
  cancelled_at              timestamptz,
  cancelled_by              uuid references public.user_profiles (id) on delete set null,
  cancelled_reason          text,

  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  created_by                uuid,
  updated_by                uuid,

  constraint invoices_number_not_blank check (length(btrim(invoice_number)) > 0),
  constraint invoices_due_date_order check (due_date is null or due_date >= invoice_date),
  constraint invoices_amounts_non_negative check (
    subtotal >= 0 and discount_total >= 0 and taxable_total >= 0
    and cgst_total >= 0 and sgst_total >= 0 and igst_total >= 0 and tax_total >= 0
    and amount_paid >= 0 and amount_credited >= 0
  ),
  constraint invoices_issued_consistency check (
    (status = 'DRAFT' and issued_at is null)
    or (status = 'ISSUED' and issued_at is not null)
    or (status = 'CANCELLED')
  ),
  constraint invoices_cancelled_consistency check (
    (status <> 'CANCELLED' and cancelled_at is null)
    or (status = 'CANCELLED' and cancelled_at is not null)
  ),
  constraint invoices_state_code_format check (place_of_supply_state_code is null or place_of_supply_state_code ~ '^[0-9]{2}$')
);

comment on table public.invoices is
  'Tax invoice. ISSUED invoices are immutable: only cancellation, posted payments and issued credit notes may change derived columns.';

create unique index if not exists invoices_number_key on public.invoices (invoice_number);
create index if not exists invoices_client_idx on public.invoices (client_id, invoice_date desc);
create index if not exists invoices_project_idx on public.invoices (project_id, invoice_date desc);
create index if not exists invoices_status_idx on public.invoices (status, invoice_date desc);
create index if not exists invoices_outstanding_idx on public.invoices (due_date)
  where status = 'ISSUED';
create index if not exists invoices_quotation_idx on public.invoices (quotation_id) where quotation_id is not null;
-- One live invoice per quotation: prevents double conversion under concurrency.
create unique index if not exists invoices_quotation_unique_live_idx
  on public.invoices (quotation_id)
  where quotation_id is not null and status <> 'CANCELLED';

-- ---------------------------------------------------------------------------
create table if not exists public.invoice_line_items (
  id               uuid primary key default gen_random_uuid(),
  invoice_id       uuid not null references public.invoices (id) on delete cascade,
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

  constraint invoice_line_items_description_not_blank check (length(btrim(description)) > 0),
  constraint invoice_line_items_quantity_positive check (quantity > 0),
  constraint invoice_line_items_unit_price_non_negative check (unit_price >= 0),
  constraint invoice_line_items_discount_percent_range check (discount_percent >= 0 and discount_percent <= 100),
  constraint invoice_line_items_discount_amount_non_negative check (discount_amount >= 0)
);

comment on table public.invoice_line_items is
  'Invoice line. Frozen while the parent invoice is ISSUED or CANCELLED.';

create index if not exists invoice_line_items_invoice_idx on public.invoice_line_items (invoice_id, sort_order);
create index if not exists invoice_line_items_gst_idx on public.invoice_line_items (gst_rate);

-- ---------------------------------------------------------------------------
-- Invoice total recalculation.
-- ---------------------------------------------------------------------------
create or replace function public.recalc_invoice_totals(p_invoice_id uuid)
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
  from public.invoice_line_items
  where invoice_id = p_invoice_id;

  select cs.round_off_enabled into v_enabled from public.company_settings cs limit 1;
  v_enabled := coalesce(v_enabled, false);

  v_grand := public.round_money(v_taxable + v_tax);
  v_round := case when v_enabled then public.round_money(round(v_grand) - v_grand) else 0 end;

  update public.invoices i
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
   where i.id = p_invoice_id;
end $$;

comment on function public.recalc_invoice_totals(uuid) is
  'Recomputes invoice header totals from its line items (single source of truth for money).';

-- Derived collection columns, always recomputed from the source ledgers.
create or replace function public.refresh_invoice_collections(p_invoice_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_paid     numeric(14,2);
  v_credited numeric(14,2);
begin
  select coalesce(sum(p.amount), 0) into v_paid
  from public.payments p
  where p.invoice_id = p_invoice_id and p.status = 'POSTED';

  select coalesce(sum(cn.grand_total), 0) into v_credited
  from public.credit_notes cn
  where cn.invoice_id = p_invoice_id and cn.status = 'ISSUED';

  update public.invoices i
     set amount_paid = v_paid,
         amount_credited = v_credited
   where i.id = p_invoice_id
     and (i.amount_paid is distinct from v_paid or i.amount_credited is distinct from v_credited);
end $$;

comment on function public.refresh_invoice_collections(uuid) is
  'Recomputes amount_paid (POSTED payments only) and amount_credited (ISSUED credit notes) for an invoice.';

-- ---------------------------------------------------------------------------
-- Immutability of ISSUED invoices.
--   DRAFT     -> freely editable
--   ISSUED    -> financial content frozen; only cancellation and derived
--                collection columns may change
--   CANCELLED -> terminal; nothing may change except derived collection columns
-- ---------------------------------------------------------------------------
create or replace function public.invoices_guard_immutability()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_frozen_columns constant text[] := array[
    'invoice_number', 'sequence_value', 'scope_key', 'invoice_date', 'client_id',
    'tax_type', 'place_of_supply_state', 'place_of_supply_state_code', 'currency',
    'subtotal', 'discount_total', 'taxable_total', 'cgst_total', 'sgst_total',
    'igst_total', 'tax_total', 'round_off', 'grand_total'
  ];
  v_allowed_columns constant text[] := array[
    'status', 'cancelled_at', 'cancelled_by', 'cancelled_reason',
    'amount_paid', 'amount_credited', 'updated_at', 'updated_by', 'notes'
  ];
  v_col      text;
  v_old_json jsonb := to_jsonb(old);
  v_new_json jsonb := to_jsonb(new);
begin
  if tg_op = 'INSERT' then
    if new.status = 'ISSUED' then
      perform public.require_permission('invoices.issue');
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'invoice % is % and can never be deleted', old.invoice_number, old.status
        using errcode = 'insufficient_privilege';
    end if;
    perform public.require_permission('invoices.update');
    return old;
  end if;

  -- UPDATE -------------------------------------------------------------
  if old.status = 'CANCELLED' then
    foreach v_col in array v_frozen_columns loop
      if v_new_json -> v_col is distinct from v_old_json -> v_col
         and not (v_col = any (v_allowed_columns)) then
        raise exception 'invoice % is CANCELLED and cannot be modified', old.invoice_number
          using errcode = 'insufficient_privilege';
      end if;
    end loop;

    if new.status <> 'CANCELLED' then
      raise exception 'a CANCELLED invoice is terminal; issue a fresh invoice instead'
        using errcode = 'check_violation';
    end if;

    -- derived collections may still move (late payment corrections)
    return new;
  end if;

  if old.status = 'ISSUED' then
    foreach v_col in array v_frozen_columns loop
      if v_new_json -> v_col is distinct from v_old_json -> v_col then
        raise exception
          'invoice % is ISSUED: % cannot be changed. Use a credit note or cancel the invoice.',
          old.invoice_number, v_col
          using errcode = 'insufficient_privilege';
      end if;
    end loop;

    if new.status not in ('ISSUED', 'CANCELLED') then
      raise exception 'invalid invoice status transition: % -> %', old.status, new.status
        using errcode = 'check_violation';
    end if;

    if new.status = 'CANCELLED' and old.status = 'ISSUED' then
      perform public.require_permission('invoices.cancel');
      new.cancelled_at := coalesce(new.cancelled_at, now());
      new.cancelled_by := coalesce(new.cancelled_by, auth.uid());
      if coalesce(btrim(new.cancelled_reason), '') = '' then
        raise exception 'a cancellation reason is required' using errcode = 'check_violation';
      end if;
    end if;

    return new;
  end if;

  -- DRAFT -> anything
  if new.status is distinct from old.status then
    if new.status = 'ISSUED' then
      if old.issued_at is not null then
        raise exception 'invoice % has already been issued', old.invoice_number
          using errcode = 'check_violation';
      end if;
      perform public.require_permission('invoices.issue');
      new.issued_at := now();
      new.issued_by := coalesce(new.issued_by, auth.uid());
    elsif new.status = 'CANCELLED' then
      perform public.require_permission('invoices.cancel');
      new.cancelled_at := now();
      new.cancelled_by := coalesce(new.cancelled_by, auth.uid());
    end if;
  end if;

  return new;
end $$;

comment on function public.invoices_guard_immutability() is
  'Freezes ISSUED invoices, makes CANCELLED terminal and blocks deletion of non-draft invoices.';

-- Line items follow the parent state machine.
create or replace function public.invoice_line_items_guard_parent_state()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_status public.invoice_status;
  v_number text;
begin
  select i.status, i.invoice_number into v_status, v_number
  from public.invoices i
  where i.id = coalesce(new.invoice_id, old.invoice_id);

  if v_status <> 'DRAFT' then
    raise exception 'invoice % is % — line items can only be changed while it is a draft',
      v_number, v_status
      using errcode = 'insufficient_privilege';
  end if;

  return coalesce(new, old);
end $$;

drop trigger if exists invoice_line_items_compute on public.invoice_line_items;
create trigger invoice_line_items_compute
  before insert or update on public.invoice_line_items
  for each row execute function public.compute_document_line_amounts();

drop trigger if exists invoice_line_items_stamp_actor on public.invoice_line_items;
create trigger invoice_line_items_stamp_actor
  before insert or update on public.invoice_line_items
  for each row execute function public.stamp_actor_columns();

drop trigger if exists invoice_line_items_guard_parent on public.invoice_line_items;
create trigger invoice_line_items_guard_parent
  before insert or update or delete on public.invoice_line_items
  for each row execute function public.invoice_line_items_guard_parent_state();

create or replace function public.invoice_line_items_after_change()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.recalc_invoice_totals(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;

drop trigger if exists invoice_line_items_recalc on public.invoice_line_items;
create trigger invoice_line_items_recalc
  after insert or update or delete on public.invoice_line_items
  for each row execute function public.invoice_line_items_after_change();

-- Issuing requires content and a client.
create or replace function public.invoices_guard_issue_requirements()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_lines int;
begin
  if new.status = 'ISSUED' and (tg_op = 'INSERT' or old.status <> 'ISSUED') then
    select count(*) into v_lines from public.invoice_line_items where invoice_id = new.id;
    if v_lines = 0 then
      raise exception 'invoice % cannot be issued without line items', new.invoice_number
        using errcode = 'check_violation';
    end if;
    if new.grand_total <= 0 then
      raise exception 'invoice % cannot be issued with a non-positive total', new.invoice_number
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

-- Invoice numbering + tax context, allocated by the database.
create or replace function public.invoices_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_prefix text;
  v_row    record;
  v_client_state_code char(2);
  v_terms_days int;
begin
  if new.invoice_number is null or btrim(new.invoice_number) = '' then
    select coalesce(cs.invoice_prefix, 'INV') into v_prefix from public.company_settings cs limit 1;
    v_prefix := coalesce(v_prefix, 'INV');

    select * into v_row from public.next_document_number('invoice', v_prefix, null, 4);
    new.invoice_number := v_row.document_number;
    new.sequence_value := v_row.sequence_value;
    new.scope_key := v_row.scope_key;
  end if;

  if new.client_id is not null then
    new.place_of_supply_state_code := public.derive_place_of_supply_state_code(new.client_id, new.place_of_supply_state_code);
    new.tax_type := public.derive_document_tax_type(new.client_id, new.place_of_supply_state_code);
  end if;

  if new.due_date is null then
    select coalesce(c.payment_terms_days, cs.payment_terms_days, 30)
      into v_terms_days
    from public.clients c
    left join public.company_settings cs on true
    where c.id = new.client_id;
    v_terms_days := coalesce(v_terms_days, 30);
    new.due_date := new.invoice_date + v_terms_days;
  end if;

  return new;
end $$;

drop trigger if exists invoices_assign_number on public.invoices;
create trigger invoices_assign_number
  before insert on public.invoices
  for each row execute function public.invoices_assign_number();

-- Place of supply / GST treatment is recomputed for drafts. For an ISSUED
-- invoice the immutability trigger below rejects any resulting change, which is
-- exactly what a statutory document requires.
create or replace function public.invoices_derive_tax_context()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if old.status <> 'DRAFT' then
    return new;
  end if;

  if new.client_id is not null then
    new.place_of_supply_state_code := public.derive_place_of_supply_state_code(new.client_id, new.place_of_supply_state_code);
    new.tax_type := public.derive_document_tax_type(new.client_id, new.place_of_supply_state_code);
  end if;

  return new;
end $$;

drop trigger if exists invoices_derive_tax_context on public.invoices;
create trigger invoices_derive_tax_context
  before update on public.invoices
  for each row execute function public.invoices_derive_tax_context();

drop trigger if exists invoices_guard_immutability on public.invoices;
create trigger invoices_guard_immutability
  before insert or update or delete on public.invoices
  for each row execute function public.invoices_guard_immutability();

drop trigger if exists invoices_guard_issue_requirements on public.invoices;
create trigger invoices_guard_issue_requirements
  before insert or update on public.invoices
  for each row execute function public.invoices_guard_issue_requirements();

drop trigger if exists invoices_set_updated_at on public.invoices;
create trigger invoices_set_updated_at
  before update on public.invoices
  for each row execute function public.set_updated_at();

drop trigger if exists invoices_stamp_actor on public.invoices;
create trigger invoices_stamp_actor
  before insert or update on public.invoices
  for each row execute function public.stamp_actor_columns();

drop trigger if exists invoices_audit on public.invoices;
create trigger invoices_audit
  after insert or update on public.invoices
  for each row execute function public.audit_row_change();

drop trigger if exists invoice_line_items_audit on public.invoice_line_items;
create trigger invoice_line_items_audit
  after insert or update or delete on public.invoice_line_items
  for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- Quotation -> invoice conversion.
-- Runs in one transaction, locks the quotation row and relies on
-- invoices_quotation_unique_live_idx so a quotation can never be converted
-- twice, even under concurrent requests.
-- ---------------------------------------------------------------------------
create or replace function public.convert_quotation_to_invoice(
  p_quotation_id uuid,
  p_invoice_date date default null,
  p_issue        boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_q          public.quotations;
  v_invoice_id uuid;
  v_lines      int;
begin
  perform public.require_permission('quotations.convert');
  perform public.require_permission('invoices.create');

  select * into v_q
  from public.quotations
  where id = p_quotation_id
  for update;

  if not found then
    raise exception 'quotation % not found', p_quotation_id using errcode = 'no_data_found';
  end if;

  if v_q.status = 'CONVERTED' then
    raise exception 'quotation % has already been converted', v_q.quotation_number
      using errcode = 'check_violation';
  end if;

  if v_q.status not in ('SENT', 'ACCEPTED') then
    raise exception 'only a sent or accepted quotation can be converted (current status: %)', v_q.status
      using errcode = 'check_violation';
  end if;

  select count(*) into v_lines from public.quotation_line_items where quotation_id = v_q.id;
  if v_lines = 0 then
    raise exception 'quotation % has no line items', v_q.quotation_number
      using errcode = 'check_violation';
  end if;

  -- Always created as a draft so the issue requirements (line items, positive
  -- total) run through the normal validation path.
  insert into public.invoices (
    invoice_date, client_id, project_id, quotation_id, status,
    title, notes, terms, tax_type, place_of_supply_state, place_of_supply_state_code,
    currency, created_by, updated_by
  )
  values (
    coalesce(p_invoice_date, current_date), v_q.client_id, v_q.project_id, v_q.id,
    'DRAFT'::public.invoice_status,
    v_q.title, v_q.notes, v_q.terms, v_q.tax_type, v_q.place_of_supply_state,
    v_q.place_of_supply_state_code, v_q.currency, auth.uid(), auth.uid()
  )
  returning id into v_invoice_id;

  insert into public.invoice_line_items (
    invoice_id, sort_order, description, hsn_sac, unit, quantity, unit_price,
    discount_percent, notes
  )
  select v_invoice_id, li.sort_order, li.description, li.hsn_sac, li.unit, li.quantity,
         li.unit_price, li.discount_percent, li.notes
  from public.quotation_line_items li
  where li.quotation_id = v_q.id
  order by li.sort_order, li.created_at;

  perform public.recalc_invoice_totals(v_invoice_id);

  if p_issue then
    update public.invoices set status = 'ISSUED' where id = v_invoice_id;
  end if;

  update public.quotations
     set status = 'CONVERTED',
         converted_at = now(),
         converted_invoice_id = v_invoice_id
   where id = v_q.id;

  perform public.write_audit_log(
    p_action       => 'OTHER',
    p_entity_table => 'quotations',
    p_entity_id    => v_q.id,
    p_entity_label => v_q.quotation_number,
    p_project_id   => v_q.project_id,
    p_summary      => format('Quotation %s converted to invoice', v_q.quotation_number)
  );

  return v_invoice_id;
end $$;

comment on function public.convert_quotation_to_invoice(uuid, date, boolean) is
  'Atomically converts an accepted/sent quotation into an invoice (draft by default).';

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.invoices enable row level security;
alter table public.invoice_line_items enable row level security;

drop policy if exists invoices_select on public.invoices;
create policy invoices_select on public.invoices
  for select to authenticated
  using (public.has_permission('invoices.view'));

drop policy if exists invoices_insert on public.invoices;
create policy invoices_insert on public.invoices
  for insert to authenticated
  with check (public.has_permission('invoices.create'));

drop policy if exists invoices_update on public.invoices;
create policy invoices_update on public.invoices
  for update to authenticated
  using (public.has_permission('invoices.update') or public.has_permission('invoices.cancel'))
  with check (public.has_permission('invoices.update') or public.has_permission('invoices.cancel'));

-- Drafts are the only deletable invoices; the immutability trigger enforces this
-- as well, so a policy mistake cannot destroy an issued document.
drop policy if exists invoices_delete on public.invoices;
create policy invoices_delete on public.invoices
  for delete to authenticated
  using (public.has_permission('invoices.update') and status = 'DRAFT');

drop policy if exists invoice_line_items_select on public.invoice_line_items;
create policy invoice_line_items_select on public.invoice_line_items
  for select to authenticated
  using (public.has_permission('invoices.view'));

drop policy if exists invoice_line_items_write on public.invoice_line_items;
create policy invoice_line_items_write on public.invoice_line_items
  for all to authenticated
  using (public.has_permission('invoices.update'))
  with check (public.has_permission('invoices.update'));
