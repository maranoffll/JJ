-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 10 : payments (collection ledger)
-- ----------------------------------------------------------------------------
-- Lifecycle: POSTED -> VOIDED (terminal). Only POSTED payments count towards
-- collection; VOIDED payments stay on record for audit but are excluded from
-- every receivable, collection and receipt computation.
-- ============================================================================

create table if not exists public.payments (
  id               uuid primary key default gen_random_uuid(),
  payment_number   text not null,
  sequence_value   bigint not null default 0,
  scope_key        text not null default 'GLOBAL',

  payment_date     date not null default current_date,
  received_on      date not null default current_date,
  client_id        uuid not null references public.clients (id) on delete restrict,
  invoice_id       uuid references public.invoices (id) on delete restrict,

  amount           numeric(14,2) not null,
  currency         char(3) not null default 'INR',
  method           public.payment_method not null default 'BANK_TRANSFER',
  reference        text,
  instrument_date  date,
  bank_name        text,

  status           public.payment_status not null default 'POSTED',
  is_advance       boolean not null default false,
  notes            text,

  voided_at        timestamptz,
  voided_by        uuid references public.user_profiles (id) on delete set null,
  void_reason      text,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,
  updated_by       uuid,

  constraint payments_amount_positive check (amount > 0),
  constraint payments_number_not_blank check (length(btrim(payment_number)) > 0),
  constraint payments_void_consistency check (
    (status = 'POSTED' and voided_at is null)
    or (status = 'VOIDED' and voided_at is not null and coalesce(btrim(void_reason), '') <> '')
  ),
  constraint payments_advance_consistency check (not is_advance or invoice_id is null),
  constraint payments_instrument_date_order check (
    instrument_date is null or instrument_date <= received_on + 30
  )
);

comment on table public.payments is
  'Collection ledger. POSTED payments count towards collection; VOIDED payments are retained for audit and excluded from all totals.';

create unique index if not exists payments_number_key on public.payments (payment_number);
create index if not exists payments_invoice_idx on public.payments (invoice_id) where invoice_id is not null;
create index if not exists payments_client_idx on public.payments (client_id, received_on desc);
create index if not exists payments_posted_idx on public.payments (received_on desc) where status = 'POSTED';
create index if not exists payments_status_idx on public.payments (status, received_on desc);

-- ---------------------------------------------------------------------------
-- Insert-time validation. The invoice row is locked FOR UPDATE so concurrent
-- payments against the same invoice are serialised and over-collection is
-- impossible even when two requests arrive at the same instant.
-- ---------------------------------------------------------------------------
create or replace function public.payments_validate()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_invoice   public.invoices;
  v_outstanding numeric(14,2);
  v_prefix    text;
  v_row       record;
begin
  perform public.require_permission('payments.create');

  if new.amount is null or new.amount <= 0 then
    raise exception 'payment amount must be greater than zero' using errcode = 'check_violation';
  end if;

  if new.payment_number is null or btrim(new.payment_number) = '' then
    select coalesce(cs.payment_prefix, 'RCPT') into v_prefix from public.company_settings cs limit 1;
    select * into v_row from public.next_document_number('payment', coalesce(v_prefix, 'RCPT'), null, 4);
    new.payment_number := v_row.document_number;
    new.sequence_value := v_row.sequence_value;
    new.scope_key := v_row.scope_key;
  end if;

  if new.invoice_id is null then
    -- On-account / advance receipt: no invoice to reconcile against.
    if new.client_id is null then
      raise exception 'a payment needs either an invoice or a client' using errcode = 'check_violation';
    end if;
    new.is_advance := true;
    return new;
  end if;

  select * into v_invoice from public.invoices where id = new.invoice_id for update;

  if not found then
    raise exception 'invoice % not found', new.invoice_id using errcode = 'no_data_found';
  end if;

  if v_invoice.status = 'DRAFT' then
    raise exception 'payments cannot be recorded against draft invoice %', v_invoice.invoice_number
      using errcode = 'check_violation';
  end if;

  if v_invoice.status = 'CANCELLED' then
    raise exception 'payments cannot be recorded against cancelled invoice %', v_invoice.invoice_number
      using errcode = 'check_violation';
  end if;

  -- The client is always taken from the invoice: a payment can never be
  -- attributed to a different client than the invoice it settles.
  new.client_id := v_invoice.client_id;
  new.is_advance := false;

  v_outstanding := public.round_money(
    v_invoice.grand_total - v_invoice.amount_paid - v_invoice.amount_credited
  );

  if new.amount > v_outstanding then
    raise exception
      'payment of % exceeds the outstanding balance of invoice % (outstanding %)',
      public.round_money(new.amount), v_invoice.invoice_number, v_outstanding
      using errcode = 'check_violation';
  end if;

  if new.status = 'VOIDED' then
    raise exception 'a payment cannot be created as VOIDED' using errcode = 'check_violation';
  end if;

  return new;
end $$;

comment on function public.payments_validate() is
  'BEFORE INSERT trigger: validates and locks the invoice so concurrent payments cannot over-collect.';

-- Posted payments are immutable: reversing a receipt means voiding it.
create or replace function public.payments_guard_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_frozen_columns constant text[] := array[
    'payment_number', 'sequence_value', 'scope_key', 'payment_date', 'received_on',
    'client_id', 'invoice_id', 'amount', 'currency', 'method', 'reference',
    'instrument_date', 'bank_name', 'is_advance'
  ];
  v_col text;
  v_old_json jsonb := to_jsonb(old);
  v_new_json jsonb := to_jsonb(new);
begin
  if tg_op = 'DELETE' then
    raise exception 'payments cannot be deleted; void the payment instead'
      using errcode = 'insufficient_privilege';
  end if;

  if old.status = 'VOIDED' then
    raise exception 'payment % is VOIDED and is terminal', old.payment_number
      using errcode = 'insufficient_privilege';
  end if;

  foreach v_col in array v_frozen_columns loop
    if v_new_json -> v_col is distinct from v_old_json -> v_col then
      raise exception 'payment % is posted: % cannot be changed; void the payment instead',
        old.payment_number, v_col
        using errcode = 'insufficient_privilege';
    end if;
  end loop;

  if new.status is distinct from old.status then
    if new.status <> 'VOIDED' then
      raise exception 'invalid payment status transition: % -> %', old.status, new.status
        using errcode = 'check_violation';
    end if;

    perform public.require_permission('payments.void');
    new.voided_at := coalesce(new.voided_at, now());
    new.voided_by := coalesce(new.voided_by, auth.uid());

    if coalesce(btrim(new.void_reason), '') = '' then
      raise exception 'a reason is required to void a payment' using errcode = 'check_violation';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists payments_validate on public.payments;
create trigger payments_validate
  before insert on public.payments
  for each row execute function public.payments_validate();

drop trigger if exists payments_guard_mutation on public.payments;
create trigger payments_guard_mutation
  before update or delete on public.payments
  for each row execute function public.payments_guard_mutation();

drop trigger if exists payments_set_updated_at on public.payments;
create trigger payments_set_updated_at
  before update on public.payments
  for each row execute function public.set_updated_at();

drop trigger if exists payments_stamp_actor on public.payments;
create trigger payments_stamp_actor
  before insert or update on public.payments
  for each row execute function public.stamp_actor_columns();

-- Collection totals are always recomputed from the ledger.
create or replace function public.payments_refresh_collections()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if coalesce(new.invoice_id, old.invoice_id) is not null then
    perform public.refresh_invoice_collections(coalesce(new.invoice_id, old.invoice_id));
  end if;
  return null;
end $$;

drop trigger if exists payments_refresh_collections on public.payments;
create trigger payments_refresh_collections
  after insert or update on public.payments
  for each row execute function public.payments_refresh_collections();

drop trigger if exists payments_audit on public.payments;
create trigger payments_audit
  after insert or update on public.payments
  for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- Application-facing operations. All payment writes must go through these (or
-- the table itself, which enforces the same rules).
-- ---------------------------------------------------------------------------
create or replace function public.post_payment(
  p_amount       numeric,
  p_invoice_id   uuid default null,
  p_client_id    uuid default null,
  p_method       public.payment_method default 'BANK_TRANSFER',
  p_received_on  date default null,
  p_reference    text default null,
  p_bank_name    text default null,
  p_instrument_date date default null,
  p_notes        text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id uuid;
  v_invoice public.invoices;
begin
  perform public.require_permission('payments.create');

  insert into public.payments (
    invoice_id, client_id, amount, method, received_on, payment_date,
    reference, bank_name, instrument_date, notes, status
  )
  values (
    p_invoice_id, p_client_id, p_amount, coalesce(p_method, 'BANK_TRANSFER'),
    coalesce(p_received_on, current_date), coalesce(p_received_on, current_date),
    nullif(btrim(coalesce(p_reference, '')), ''), nullif(btrim(coalesce(p_bank_name, '')), ''),
    p_instrument_date, nullif(btrim(coalesce(p_notes, '')), ''), 'POSTED'
  )
  returning id into v_id;

  if p_invoice_id is not null then
    select * into v_invoice from public.invoices where id = p_invoice_id;

    perform public.write_audit_log(
      p_action       => 'OTHER',
      p_entity_table => 'payments',
      p_entity_id    => v_id,
      p_project_id   => v_invoice.project_id,
      p_summary      => format('Payment posted against invoice %s', v_invoice.invoice_number)
    );
  end if;

  return v_id;
end $$;

comment on function public.post_payment is
  'Records a POSTED payment. Validates outstanding balance and locks the invoice (concurrency-safe).';

create or replace function public.void_payment(p_payment_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_payment public.payments;
begin
  perform public.require_permission('payments.void');

  select * into v_payment from public.payments where id = p_payment_id for update;

  if not found then
    raise exception 'payment % not found', p_payment_id using errcode = 'no_data_found';
  end if;

  if v_payment.status = 'VOIDED' then
    raise exception 'payment % is already voided', v_payment.payment_number
      using errcode = 'check_violation';
  end if;

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is required to void a payment' using errcode = 'check_violation';
  end if;

  update public.payments
     set status = 'VOIDED',
         void_reason = p_reason,
         voided_at = now(),
         voided_by = auth.uid()
   where id = p_payment_id;

  perform public.write_audit_log(
    p_action       => 'VOID',
    p_entity_table => 'payments',
    p_entity_id    => p_payment_id,
    p_entity_label => v_payment.payment_number,
    p_summary      => format('Payment %s voided: %s', v_payment.payment_number, p_reason)
  );
end $$;

comment on function public.void_payment(uuid, text) is
  'Voids a posted payment, removing it from collection totals while preserving the audit trail.';

-- A receipt may only be produced for a POSTED payment (Phase 13 documents).
create or replace function public.payment_receipt_allowed(p_payment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists (
    select 1 from public.payments p
    where p.id = p_payment_id and p.status = 'POSTED'
  );
$$;

comment on function public.payment_receipt_allowed(uuid) is
  'True only for POSTED payments; VOIDED payments must never produce an official receipt.';

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.payments enable row level security;

drop policy if exists payments_select on public.payments;
create policy payments_select on public.payments
  for select to authenticated
  using (public.has_permission('payments.view'));

drop policy if exists payments_insert on public.payments;
create policy payments_insert on public.payments
  for insert to authenticated
  with check (public.has_permission('payments.create'));

drop policy if exists payments_update on public.payments;
create policy payments_update on public.payments
  for update to authenticated
  using (public.has_permission('payments.void'))
  with check (public.has_permission('payments.void'));

-- No DELETE policy: payments are never deleted, only voided.
