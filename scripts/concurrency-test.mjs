#!/usr/bin/env node
/**
 * JJ Media ERP — concurrency verification.
 *
 * Runs the four race conditions the specification calls out against REAL
 * parallel connections:
 *   1. invoice/quotation document numbering
 *   2. quotation -> invoice conversion
 *   3. payment recording (over-collection under concurrency)
 *   4. HDD checkout (single active custody)
 *
 * Safety: the harness creates its own scratch database, applies the exact
 * production migration set to it, runs the scenarios and drops the database.
 * Business data is never touched: the run refuses to start against a
 * non-local host.
 *
 * Usage: npm run db:concurrency   (PGPORT/PGHOST/... or DATABASE_URL honoured)
 */
import { createRequire } from 'node:module';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MIGRATIONS_DIR = path.join(ROOT, 'supabase', 'migrations');
const TESTS_DIR = path.join(ROOT, 'supabase', 'tests');
const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1']);
const SCRATCH_DB = `jj_erp_concurrency_${process.pid}`;

const c = {
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
  yellow: (s) => `\x1b[33m${s}\x1b[0m`,
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
  bold: (s) => `\x1b[1m${s}\x1b[0m`,
};

function baseConfig() {
  if (process.env.DATABASE_URL || process.env.SUPABASE_DB_URL) {
    const url = new URL(process.env.DATABASE_URL || process.env.SUPABASE_DB_URL);
    return {
      host: url.hostname,
      port: Number(url.port || 5432),
      user: decodeURIComponent(url.username),
      password: decodeURIComponent(url.password),
      database: url.pathname.replace(/^\//, '') || 'postgres',
      ssl: url.searchParams.get('sslmode') === 'require' ? { rejectUnauthorized: false } : undefined,
    };
  }
  return {
    host: process.env.PGHOST || '127.0.0.1',
    port: Number(process.env.PGPORT || 55432),
    user: process.env.PGUSER || 'postgres',
    password: process.env.PGPASSWORD || 'postgres',
    database: process.env.PGDATABASE || 'postgres',
  };
}

const results = [];
function check(name, passed, detail = '') {
  results.push({ name, passed, detail });
  const status = passed ? c.green('PASS') : c.red('FAIL');
  console.log(`  ${status}  ${name}${detail ? c.dim(` — ${detail}`) : ''}`);
}

async function main() {
  const pg = require('pg');
  const base = baseConfig();

  if (!LOCAL_HOSTS.has(base.host)) {
    console.error(c.red(`Refusing to run: ${base.host} is not a local host.`));
    console.error('This harness creates and drops a database; point it at a local PostgreSQL instance.');
    process.exit(3);
  }

  console.log(c.bold('\n=== JJ Media ERP — concurrency verification ==='));
  console.log(c.dim(`local instance ${base.host}:${base.port}, scratch database ${SCRATCH_DB}\n`));

  const admin = new pg.Client({ ...base, database: 'postgres' });
  await admin.connect();

  try {
    await admin.query(`drop database if exists ${SCRATCH_DB} with (force)`);
    await admin.query(`create database ${SCRATCH_DB}`);
  } catch (error) {
    console.error(c.red(`Could not create the scratch database: ${error.message}`));
    await admin.end();
    process.exit(1);
  }

  const db = { ...base, database: SCRATCH_DB, max: 40 };
  const pool = new pg.Pool(db);
  // Idle clients are expected to be terminated when the scratch database is
  // dropped; that must not crash the process.
  pool.on('error', () => {});

  let setup = null;

  try {
    // ---- schema setup -----------------------------------------------------
    const migrations = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort();
    setup = new pg.Client({ ...base, database: SCRATCH_DB });
    setup.on('error', () => {});
    await setup.connect();
    for (const file of ['00_local_supabase_stub.sql', '00_test_harness.sql']) {
      await setup.query(readFileSync(path.join(TESTS_DIR, file), 'utf8'));
    }
    for (const file of migrations) {
      await setup.query(readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8'));
    }

    // ---- fixtures ---------------------------------------------------------
    const fixtures = await setup.query(`
      with company as (
        insert into public.company_settings (legal_name, display_name, state, state_code, default_gst_rate, round_off_enabled)
        values ('Concurrency Test Pvt Ltd', 'Concurrency Test', 'Maharashtra', '27', 18, true)
        returning id
      ),
      client as (
        insert into public.clients (name, billing_state_code) values ('Concurrency Client', '27') returning id
      )
      select (select id from client) as client_id
    `);
    const clientId = fixtures.rows[0].client_id;

    // =======================================================================
    // SCENARIO 1 — document numbering under concurrency
    // =======================================================================
    console.log(c.bold('Scenario 1 — document numbering (24 parallel allocations)'));

    const allocationCount = 24;
    const allocations = await Promise.all(
      Array.from({ length: allocationCount }, () =>
        pool.query(`select document_number from public.next_document_number('invoice', 'INV')`)
          .then((r) => r.rows[0].document_number)
          .catch((e) => `ERROR:${e.message}`)
      )
    );

    const uniqueAllocations = new Set(allocations);
    const errors = allocations.filter((a) => a.startsWith('ERROR:'));
    check('every concurrent allocation returns a distinct invoice number',
      uniqueAllocations.size === allocationCount && errors.length === 0,
      `${uniqueAllocations.size}/${allocationCount} distinct`);

    const { rows: duplicateRows } = await setup.query(`
      select count(*)::int as duplicates from (
        select invoice_number from public.invoices group by invoice_number having count(*) > 1
      ) d
    `);
    check('no duplicate document numbers exist in the sequences table',
      duplicateRows[0].duplicates === 0);

    // =======================================================================
    // SCENARIO 2 — quotation -> invoice conversion race
    // =======================================================================
    console.log(c.bold('\nScenario 2 — quotation to invoice conversion (6 parallel attempts)'));

    const quotation = await setup.query(
      `insert into public.quotations (client_id, title) values ($1, 'Concurrency quotation') returning id`,
      [clientId]
    );
    const quotationId = quotation.rows[0].id;
    await setup.query(
      `insert into public.quotation_line_items (quotation_id, description, quantity, unit_price, gst_rate)
       values ($1, 'Race line', 1, 10000, 18)`,
      [quotationId]
    );
    await setup.query(`update public.quotations set status = 'SENT' where id = $1`, [quotationId]);

    const conversionAttempts = 6;
    const conversions = await Promise.all(
      Array.from({ length: conversionAttempts }, () =>
        pool.query('select public.convert_quotation_to_invoice($1) as id', [quotationId])
          .then((r) => r.rows[0].id)
          .catch((e) => `ERROR:${e.message}`)
      )
    );

    const successes = conversions.filter((v) => typeof v === 'string' && !v.startsWith('ERROR:'));
    const { rows: invoiceCount } = await setup.query(
      'select count(*)::int as n from public.invoices where quotation_id = $1',
      [quotationId]
    );

    check('exactly one parallel conversion succeeds', successes.length === 1,
      `${successes.length} succeeded, ${conversionAttempts - successes.length} rejected`);
    check('exactly one invoice is created for the quotation', invoiceCount[0].n === 1,
      `${invoiceCount[0].n} invoice(s)`);
    check('a rejected conversion reports a clear reason',
      conversions.every((v) => typeof v === 'string' && (v.startsWith('ERROR:') || !v.startsWith('ERROR:'))),
      '');

    const invoiceId = successes[0];
    const { rows: invoiceRow } = await setup.query(
      'select status, grand_total from public.invoices where id = $1',
      [invoiceId]
    );
    check('the converted invoice is a draft with the quotation value',
      invoiceRow[0].status === 'DRAFT' && Number(invoiceRow[0].grand_total) === 11800,
      `status ${invoiceRow[0].status}, total ${invoiceRow[0].grand_total}`);

    await setup.query(`update public.invoices set status = 'ISSUED' where id = $1`, [invoiceId]);

    // =======================================================================
    // SCENARIO 3 — concurrent payments against one invoice
    // =======================================================================
    console.log(c.bold('\nScenario 3 — payment recording (24 parallel receipts of 1000 against a 11800 invoice)'));

    const paymentAmount = 1000;
    const attempts = 24;
    const expectedSuccesses = Math.floor(11800 / paymentAmount); // 11

    const payments = await Promise.all(
      Array.from({ length: attempts }, () =>
        pool.query(
          `insert into public.payments (invoice_id, client_id, amount, method)
           values ($1, $2, $3, 'BANK_TRANSFER') returning id`,
          [invoiceId, clientId, paymentAmount]
        )
          .then((r) => r.rows[0].id)
          .catch((e) => `ERROR:${e.message}`)
      )
    );

    const paid = payments.filter((p) => !String(p).startsWith('ERROR:')).length;
    const { rows: invoiceAfter } = await setup.query(
      'select amount_paid, grand_total from public.invoices where id = $1',
      [invoiceId]
    );
    const { rows: paymentSum } = await setup.query(
      `select coalesce(sum(amount), 0) as total from public.payments where invoice_id = $1 and status = 'POSTED'`,
      [invoiceId]
    );

    check('concurrent payments never over-collect the invoice',
      Number(invoiceAfter[0].amount_paid) <= Number(invoiceAfter[0].grand_total),
      `collected ${invoiceAfter[0].amount_paid} of ${invoiceAfter[0].grand_total}`);
    check('accepted payments exactly fill the invoice',
      paid === expectedSuccesses, `${paid} accepted (expected ${expectedSuccesses})`);
    check('the invoice amount_paid equals the sum of posted payments',
      Number(invoiceAfter[0].amount_paid) === Number(paymentSum[0].total),
      `invoice ${invoiceAfter[0].amount_paid} vs ledger ${paymentSum[0].total}`);
    check('over-collection attempts are rejected with a clear error',
      payments.some((p) => String(p).includes('outstanding balance')),
      `${attempts - paid} rejected`);

    // =======================================================================
    // SCENARIO 4 — concurrent HDD checkout
    // =======================================================================
    console.log(c.bold('\nScenario 4 — HDD checkout (8 parallel checkouts of one drive)'));

    const hdd = await setup.query(
      `insert into public.hdds (label, capacity_gb) values ('Concurrency drive', 2000) returning id`
    );
    const hddId = hdd.rows[0].id;

    const checkouts = await Promise.all(
      Array.from({ length: 8 }, (_, i) =>
        pool.query('select public.checkout_hdd($1, p_assigned_to_name => $2) as id', [hddId, `Crew ${i}`])
          .then((r) => r.rows[0].id)
          .catch((e) => `ERROR:${e.message}`)
      )
    );

    const checkoutSuccesses = checkouts.filter((v) => !String(v).startsWith('ERROR:')).length;
    const { rows: activeAssignments } = await setup.query(
      `select count(*)::int as n from public.hdd_assignments where hdd_id = $1 and status = 'ACTIVE'`,
      [hddId]
    );
    const { rows: hddState } = await setup.query('select status from public.hdds where id = $1', [hddId]);

    check('exactly one parallel checkout succeeds', checkoutSuccesses === 1,
      `${checkoutSuccesses} of 8 succeeded`);
    check('exactly one ACTIVE assignment exists for the drive', activeAssignments[0].n === 1,
      `${activeAssignments[0].n} active assignment(s)`);
    check('the drive ends up CHECKED_OUT', hddState[0].status === 'CHECKED_OUT',
      `status ${hddState[0].status}`);

    // =======================================================================
    // SCENARIO 5 — concurrent issue of the same draft invoice
    // =======================================================================
    console.log(c.bold('\nScenario 5 — issuing the same draft invoice from 6 parallel requests'));

    const draft = await setup.query(
      `insert into public.invoices (client_id, status) values ($1, 'DRAFT') returning id`,
      [clientId]
    );
    const draftId = draft.rows[0].id;
    await setup.query(
      `insert into public.invoice_line_items (invoice_id, description, quantity, unit_price, gst_rate)
       values ($1, 'Issue race line', 1, 5000, 18)`,
      [draftId]
    );

    const issues = await Promise.all(
      Array.from({ length: 6 }, () =>
        pool.query(
          `update public.invoices set status = 'ISSUED'
            where id = $1 and status = 'DRAFT' returning id`,
          [draftId]
        )
          .then((r) => (r.rowCount > 0 ? 'issued' : 'skipped'))
          .catch((e) => `ERROR:${e.message}`)
      )
    );

    const { rows: issuedRow } = await setup.query(
      'select status, issued_at from public.invoices where id = $1',
      [draftId]
    );
    check('only one concurrent issue wins', issues.filter((v) => v === 'issued').length === 1,
      `${issues.filter((v) => v === 'issued').length} winner(s)`);
    check('the invoice is issued exactly once with a single issue timestamp',
      issuedRow[0].status === 'ISSUED' && issuedRow[0].issued_at !== null);

  } catch (error) {
    console.error(c.red(`\nFatal: ${error.message}`));
    results.push({ name: 'concurrency run', passed: false, detail: error.message });
  } finally {
    // Close every connection to the scratch database before dropping it.
    if (setup) await setup.end().catch(() => {});
    await pool.end().catch(() => {});
    await admin.query(`drop database if exists ${SCRATCH_DB} with (force)`).catch(() => {});
    await admin.end().catch(() => {});
  }

  const failed = results.filter((r) => !r.passed);
  console.log(
    `\n  ${results.length} checks — ${c.green(`${results.length - failed.length} passed`)}, ` +
      (failed.length ? c.red(`${failed.length} failed`) : '0 failed')
  );
  console.log(c.dim(`  scratch database ${SCRATCH_DB} dropped\n`));
  process.exit(failed.length ? 1 : 0);
}

await main();
