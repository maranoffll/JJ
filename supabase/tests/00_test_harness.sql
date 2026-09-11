-- ============================================================================
-- DATABASE TEST HARNESS (no external extension required)
-- ----------------------------------------------------------------------------
-- Provides a tiny assertion framework that works on plain PostgreSQL as well
-- as on Supabase, where pgTAP is not installed. Test files call:
--     db_test.ok(condition, 'test name')
--     db_test.eq(actual, expected, 'test name')
--     db_test.near(actual, expected, 'test name')
--     db_test.throws('sql ...', 'test name')
--     db_test.plan_start('suite name')
-- Results are recorded in db_test.results and reported by scripts/db.mjs.
-- ============================================================================

create schema if not exists db_test;

create table if not exists db_test.results (
  id         bigint generated always as identity primary key,
  suite      text not null,
  name       text not null,
  ok         boolean not null,
  detail     text,
  created_at timestamptz not null default now()
);

create or replace function db_test.suite_name()
returns text
language sql
stable
as $$
  select coalesce(nullif(current_setting('db_test.suite', true), ''), 'database');
$$;

create or replace function db_test.record(p_ok boolean, p_name text, p_detail text default null)
returns boolean
language plpgsql
security definer
set search_path = public, db_test, pg_temp
as $$
begin
  insert into db_test.results (suite, name, ok, detail)
  values (db_test.suite_name(), p_name, coalesce(p_ok, false), p_detail);
  return coalesce(p_ok, false);
end $$;

-- Starts a suite and resets any session state (role / JWT claims) left behind
-- by earlier suites, so suites cannot influence each other.
create or replace function db_test.plan_start(p_suite text)
returns void
language plpgsql
as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', '', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('db_test.suite', p_suite, false);
  raise notice '--- suite: % ---', p_suite;
end $$;

create or replace function db_test.ok(p_condition boolean, p_name text, p_detail text default null)
returns boolean
language plpgsql
security definer
set search_path = public, db_test, pg_temp
as $$
begin
  return db_test.record(coalesce(p_condition, false), p_name, p_detail);
end $$;

create or replace function db_test.eq(p_actual anyelement, p_expected anyelement, p_name text)
returns boolean
language plpgsql
security definer
set search_path = public, db_test, pg_temp
as $$
declare
  v_ok boolean := p_actual is not distinct from p_expected;
begin
  return db_test.record(
    v_ok,
    p_name,
    case when v_ok then null
         else format('expected <%s> but got <%s>', p_expected, p_actual) end
  );
end $$;

create or replace function db_test.near(p_actual numeric, p_expected numeric, p_name text, p_tolerance numeric default 0.0001)
returns boolean
language plpgsql
security definer
set search_path = public, db_test, pg_temp
as $$
declare
  v_ok boolean := p_actual is not distinct from p_expected
                  or abs(coalesce(p_actual, 0) - coalesce(p_expected, 0)) <= coalesce(p_tolerance, 0.0001);
begin
  return db_test.record(
    v_ok,
    p_name,
    case when v_ok then null
         else format('expected approximately <%s> but got <%s>', p_expected, p_actual) end
  );
end $$;

-- Executes p_sql and asserts that it fails. Optionally asserts the message.
create or replace function db_test.throws(p_sql text, p_name text, p_message_like text default null)
returns boolean
language plpgsql
security definer
set search_path = public, db_test, pg_temp
as $$
declare
  v_failed   boolean := false;
  v_message  text;
begin
  begin
    execute p_sql;
  exception when others then
    v_failed := true;
    v_message := sqlerrm;
  end;

  if not v_failed then
    return db_test.record(false, p_name, 'statement was expected to fail but succeeded');
  end if;

  if p_message_like is not null and v_message not ilike '%' || p_message_like || '%' then
    return db_test.record(false, p_name, format('failed with unexpected message: %s', v_message));
  end if;

  return db_test.record(true, p_name, null);
end $$;

create or replace function db_test.assert_no_failures()
returns void
language plpgsql
security definer
set search_path = public, db_test, pg_temp
as $$
declare
  v_failed int;
  v_detail text;
begin
  select count(*), string_agg(format('%s [%s]', name, coalesce(detail, '')), E'\n' order by id)
    into v_failed, v_detail
  from db_test.results
  where not ok;

  if v_failed > 0 then
    raise exception E'% database test assertion(s) failed:\n%', v_failed, v_detail;
  end if;
end $$;

create or replace function db_test.summary()
returns table (suite text, total bigint, passed bigint, failed bigint)
language sql
stable
security definer
set search_path = public, db_test, pg_temp
as $$
  select r.suite, count(*), count(*) filter (where r.ok), count(*) filter (where not r.ok)
  from db_test.results r
  group by r.suite
  order by r.suite;
$$;

-- Test files run as an authenticated role during RLS checks, so the harness
-- functions must remain callable from those roles.
grant usage on schema db_test to anon, authenticated, service_role;
grant execute on all functions in schema db_test to anon, authenticated, service_role;
