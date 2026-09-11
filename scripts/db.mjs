#!/usr/bin/env node
/**
 * JJ Media ERP — database task runner.
 *
 * Commands
 *   node scripts/db.mjs migrate   Apply supabase/migrations/*.sql in order.
 *   node scripts/db.mjs reset     Drop and recreate the public schema, then migrate (local only).
 *   node scripts/db.mjs test      Apply migrations + test files inside ONE transaction, report, roll back.
 *   node scripts/db.mjs verify    Read-only verification of an existing database (safe against live).
 *
 * Connection resolution (first match wins)
 *   1. DATABASE_URL or SUPABASE_DB_URL
 *   2. PGHOST / PGPORT / PGUSER / PGPASSWORD / PGDATABASE
 *   3. Local defaults: postgres://postgres:postgres@127.0.0.1:55432/postgres
 *
 * Destructive commands refuse to run against a non-local host unless
 * ALLOW_REMOTE_MIGRATIONS=1 is set explicitly.
 */
import { createRequire } from 'node:module';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MIGRATIONS_DIR = path.join(ROOT, 'supabase', 'migrations');
const TESTS_DIR = path.join(ROOT, 'supabase', 'tests');

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', 'host.docker.internal']);

function resolveConnection() {
  const url = process.env.DATABASE_URL || process.env.SUPABASE_DB_URL;
  if (url) return { connectionString: url, host: safeHost(url) };
  const host = process.env.PGHOST || '127.0.0.1';
  return {
    host,
    port: Number(process.env.PGPORT || 55432),
    user: process.env.PGUSER || 'postgres',
    password: process.env.PGPASSWORD || 'postgres',
    database: process.env.PGDATABASE || 'postgres',
  };
}

function safeHost(url) {
  try {
    return new URL(url).hostname;
  } catch {
    return '';
  }
}

const colors = {
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
  yellow: (s) => `\x1b[33m${s}\x1b[0m`,
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
  bold: (s) => `\x1b[1m${s}\x1b[0m`,
};

function migrationFiles() {
  if (!existsSync(MIGRATIONS_DIR)) return [];
  return readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .map((f) => ({ name: f, full: path.join(MIGRATIONS_DIR, f) }));
}

function testFiles() {
  if (!existsSync(TESTS_DIR)) return [];
  return readdirSync(TESTS_DIR)
    .filter((f) => f.endsWith('.test.sql'))
    .sort()
    .map((f) => ({ name: f, full: path.join(TESTS_DIR, f) }));
}

function harnessFiles() {
  return [
    { name: '00_local_supabase_stub.sql', full: path.join(TESTS_DIR, '00_local_supabase_stub.sql') },
    { name: '00_test_harness.sql', full: path.join(TESTS_DIR, '00_test_harness.sql') },
  ].filter((f) => existsSync(f.full));
}

async function loadPg() {
  try {
    return require('pg');
  } catch {
    console.error(colors.red('The "pg" package is required. Run: npm install'));
    process.exit(2);
  }
}

async function connect() {
  const pg = await loadPg();
  const config = resolveConnection();
  const client = new pg.Client({ ...config, application_name: 'jj-erp-db-runner' });
  await client.connect();
  return { client, host: config.host || safeHost(config.connectionString || '') };
}

function assertDestructiveAllowed(host, command) {
  const isLocal = LOCAL_HOSTS.has(host) || /^10\.|^192\.168\.|^172\.(1[6-9]|2\d|3[01])\./.test(host || '');
  if (isLocal) return;
  if (process.env.ALLOW_REMOTE_MIGRATIONS === '1') {
    console.log(colors.yellow(`⚠  ${command} against non-local host ${host} (ALLOW_REMOTE_MIGRATIONS=1)`));
    return;
  }
  console.error(
    colors.red(
      `\nRefusing to run "${command}" against non-local host "${host}".\n` +
        'This guards live business data. Set ALLOW_REMOTE_MIGRATIONS=1 only when you intend it.\n'
    )
  );
  process.exit(3);
}

async function applySqlFile(client, { name, full }, { mode = 'transaction', label } = {}) {
  const sql = readFileSync(full, 'utf8');
  const started = Date.now();
  const tag = label ? `${name} ${label}` : name;

  if (mode === 'transaction') await client.query('begin');
  if (mode === 'savepoint') await client.query('savepoint file_sp');

  try {
    await client.query(sql);
    if (mode === 'transaction') await client.query('commit');
    if (mode === 'savepoint') await client.query('release savepoint file_sp');
    console.log(`  ${colors.green('✓')} ${tag} ${colors.dim(`${Date.now() - started}ms`)}`);
    return true;
  } catch (error) {
    try {
      if (mode === 'transaction') await client.query('rollback');
      if (mode === 'savepoint') await client.query('rollback to savepoint file_sp');
    } catch { /* the connection may already be aborted */ }
    console.error(`  ${colors.red('✗')} ${tag}`);
    console.error(colors.red(`    ${error.message}`));
    if (error.position) console.error(colors.dim(`    at character ${error.position}`));
    if (process.env.DEBUG_SQL && error.query) {
      const q = String(error.query);
      const pos = Number(error.position || 0);
      console.error(colors.dim(q.slice(Math.max(0, pos - 240), pos + 160)));
    }
    return false;
  }
}

async function runMigrations(client, { verbose = false, mode = 'transaction' } = {}) {
  const files = migrationFiles();
  if (!files.length) {
    console.log(colors.yellow('No migrations found.'));
    return true;
  }
  console.log(colors.bold(`\nApplying ${files.length} migration(s)...`));
  let ok = true;
  for (const file of files) {
    const applied = await applySqlFile(client, file, { mode });
    if (!applied) {
      ok = false;
      break;
    }
  }
  if (verbose) {
    const { rows } = await client.query(
      `select count(*)::int as tables
         from information_schema.tables
        where table_schema = 'public' and table_type = 'BASE TABLE'`
    );
    console.log(colors.dim(`  public tables: ${rows[0].tables}`));
  }
  return ok;
}

async function runTestFiles(client, { mode = 'transaction' } = {}) {
  const files = testFiles();
  if (!files.length) {
    console.log(colors.yellow('No test files found (supabase/tests/*.test.sql).'));
    return { ok: true, ran: 0 };
  }
  console.log(colors.bold(`\nRunning ${files.length} database test file(s)...`));
  let ok = true;
  for (const file of files) {
    const applied = await applySqlFile(client, file, { mode });
    if (!applied) ok = false;
  }
  return { ok, ran: files.length };
}

async function reportTestResults(client) {
  let rows = [];
  try {
    ({ rows } = await client.query('select * from db_test.summary()'));
  } catch {
    return { ok: false, total: 0, failed: 0 };
  }

  let total = 0;
  let failed = 0;
  console.log(colors.bold('\nTest summary'));
  for (const row of rows) {
    total += Number(row.total);
    failed += Number(row.failed);
    const status = Number(row.failed) === 0 ? colors.green('PASS') : colors.red('FAIL');
    console.log(
      `  ${status}  ${row.suite.padEnd(34)} ${row.passed}/${row.total} assertions passed`
    );
  }

  if (failed > 0) {
    const { rows: failures } = await client.query(
      `select suite, name, detail from db_test.results where not ok order by id limit 50`
    );
    console.log(colors.red('\nFailures:'));
    for (const f of failures) {
      console.log(colors.red(`  ✗ [${f.suite}] ${f.name}`));
      if (f.detail) console.log(colors.dim(`      ${f.detail}`));
    }
  }

  console.log(
    `\n  ${total} assertions — ${colors.green(`${total - failed} passed`)}, ` +
      (failed ? colors.red(`${failed} failed`) : '0 failed')
  );
  return { ok: failed === 0 && rows.length > 0, total, failed };
}


async function ensurePrereqs(client, host) {
  const { rows } = await client.query(
    `select exists (select 1 from information_schema.schemata where schema_name = 'auth') as has_auth`
  );
  if (rows[0].has_auth) return;
  if (!LOCAL_HOSTS.has(host)) {
    console.error(colors.red('Schema "auth" is missing on a non-local database. Aborting.'));
    process.exit(3);
  }
  const stub = path.join(TESTS_DIR, '00_local_supabase_stub.sql');
  if (!existsSync(stub)) return;
  console.log(colors.yellow('No "auth" schema (plain PostgreSQL) — installing the local Supabase stub.'));
  await applySqlFile(client, { name: '00_local_supabase_stub.sql', full: stub }, { mode: 'transaction' });
}

async function cmdMigrate() {
  const { client, host } = await connect();
  assertDestructiveAllowed(host, 'migrate');
  try {
    await ensurePrereqs(client, host);
    const ok = await runMigrations(client, { verbose: true });
    process.exitCode = ok ? 0 : 1;
  } finally {
    await client.end();
  }
}

async function cmdReset() {
  const { client, host } = await connect();
  assertDestructiveAllowed(host, 'reset');
  try {
    console.log(colors.yellow('Dropping schema public cascade...'));
    await client.query('drop schema if exists public cascade; create schema public;');
    // Prerequisite roles exist on Supabase; provision them on a plain instance.
    await client.query(`
      do $$
      declare v_role text;
      begin
        foreach v_role in array array['anon','authenticated','service_role'] loop
          if not exists (select 1 from pg_roles where rolname = v_role) then
            execute format('create role %I nologin noinherit', v_role);
          end if;
        end loop;
      end $$;
      grant usage on schema public to anon, authenticated, service_role;
    `);
    await ensurePrereqs(client, host);
    const ok = await runMigrations(client, { verbose: true });
    process.exitCode = ok ? 0 : 1;
  } finally {
    await client.end();
  }
}

async function cmdTest() {
  const { client, host } = await connect();
  assertDestructiveAllowed(host, 'test');
  const keepChanges = process.argv.includes('--keep');
  let migrationsOk = false;
  let testsOk = false;

  try {
    console.log(colors.bold('=== JJ Media ERP — database test run ==='));
    console.log(colors.dim(`host: ${host}${keepChanges ? ' (changes will be COMMITTED)' : ' (transaction will be ROLLED BACK)'}`));

    await client.query('begin');
    for (const file of harnessFiles()) {
      const ok = await applySqlFile(client, file, { mode: 'savepoint' });
      if (!ok) {
        await client.query('rollback');
        process.exitCode = 1;
        return;
      }
    }

    migrationsOk = await runMigrations(client, { verbose: true, mode: 'savepoint' });
    if (migrationsOk) {
      const { ok } = await runTestFiles(client, { mode: 'savepoint' });
      testsOk = ok;
    } else {
      console.log(colors.red('\nMigrations failed — skipping test files.'));
    }

    const summary = migrationsOk ? await reportTestResults(client) : { ok: false };

    if (keepChanges) {
      await client.query('commit');
      console.log(colors.yellow('\nChanges committed (--keep).'));
    } else {
      await client.query('rollback');
      console.log(colors.dim('\nTransaction rolled back — no data was modified.'));
    }

    process.exitCode = migrationsOk && testsOk && summary.ok ? 0 : 1;
  } catch (error) {
    try {
      await client.query('rollback');
    } catch { /* ignore */ }
    console.error(colors.red(`\nFatal: ${error.message}`));
    process.exitCode = 1;
  } finally {
    await client.end();
  }
}

async function cmdVerify() {
  const { client, host } = await connect();
  const checks = [];
  const push = (name, ok, detail = '') => checks.push({ name, ok, detail });

  try {
    const { rows: tables } = await client.query(
      `select table_name from information_schema.tables
        where table_schema = 'public' and table_type = 'BASE TABLE' order by 1`
    );
    const names = tables.map((r) => r.table_name);
    const required = [
      'audit_logs', 'clients', 'company_settings', 'credit_note_line_items', 'credit_notes',
      'document_sequences', 'expense_categories', 'expenses', 'hdd_assignments', 'hdd_locations',
      'hdd_logs', 'hdds', 'invoice_line_items', 'invoices', 'payments', 'projects',
      'quotation_line_items', 'quotations', 'role_permissions', 'user_profiles',
    ];
    const missing = required.filter((t) => !names.includes(t));
    push(`tables present (${required.length} required)`, missing.length === 0, missing.join(', '));

    const { rows: rlsOff } = await client.query(
      `select c.relname
         from pg_class c
         join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r'
          and c.relname <> 'document_sequences'
          and not c.relrowsecurity
        order by 1`
    );
    push('row level security enabled on all business tables', rlsOff.length === 0,
      rlsOff.map((r) => r.relname).join(', '));

    const { rows: policyCount } = await client.query(
      `select count(*)::int as n from pg_policies where schemaname = 'public'`
    );
    push('RLS policies defined', policyCount[0].n > 0, `${policyCount[0].n} policies`);

    const { rows: fnMissing } = await client.query(
      `select unnest(array[
          'next_document_number','peek_next_document_number','has_permission','has_role',
          'app_current_user_role','write_audit_log','amount_in_words','split_gst',
          'post_payment','void_payment'
        ]) as fn
        except
        select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'`
    );
    push('required database functions present', fnMissing.length === 0,
      fnMissing.map((r) => r.fn).join(', '));

    const { rows: seqCheck } = await client.query(
      `select count(*)::int as n from public.document_sequences`
    ).catch(() => ({ rows: [{ n: 0 }] }));
    push('document numbering table readable', Number.isInteger(seqCheck[0]?.n));

    const { rows: auditImmutable } = await client.query(
      `select count(*)::int as n from pg_trigger
        where tgname in ('audit_logs_immutable_update','audit_logs_immutable_delete')`
    );
    push('audit log is append-only (guard triggers installed)', auditImmutable[0].n === 2);

    console.log(colors.bold(`\n=== Verification against ${host} ===`));
    let failed = 0;
    for (const c of checks) {
      if (!c.ok) failed += 1;
      console.log(`  ${c.ok ? colors.green('PASS') : colors.red('FAIL')}  ${c.name}${c.detail ? colors.dim(` — ${c.detail}`) : ''}`);
    }
    console.log(failed === 0 ? colors.green('\nVerification passed.') : colors.red(`\n${failed} check(s) failed.`));
    process.exitCode = failed === 0 ? 0 : 1;
  } finally {
    await client.end();
  }
}

const command = process.argv[2] || 'help';
const commands = { migrate: cmdMigrate, reset: cmdReset, test: cmdTest, verify: cmdVerify };

if (!commands[command]) {
  console.log(`JJ Media ERP database runner

Usage: node scripts/db.mjs <command>

  migrate   Apply supabase/migrations/*.sql in filename order
  reset     Drop schema public and re-apply all migrations (local only)
  test      Apply migrations + run supabase/tests/*.test.sql in one rolled-back transaction
  verify    Read-only verification of schema, RLS, functions (safe against live)

Environment: DATABASE_URL | SUPABASE_DB_URL | PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE
`);
  process.exit(command === 'help' ? 0 : 1);
}

await commands[command]();
