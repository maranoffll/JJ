/**
 * Environment configuration for JJ Media ERP.
 *
 * Only PUBLIC values may live in the frontend bundle:
 *   VITE_SUPABASE_URL        — the project URL
 *   VITE_SUPABASE_ANON_KEY   — the anon / publishable key
 *
 * A service_role key, a `sb_secret_…` key or a database password must never be
 * referenced here. `assertPublishableKey` below rejects privileged material at
 * runtime, and `npm run secret:scan` rejects it at commit time.
 */

export interface AppEnv {
  supabaseUrl: string;
  supabaseAnonKey: string;
  appName: string;
}

export interface EnvProblem {
  variable: string;
  message: string;
  hint: string;
}

export interface EnvResult {
  env: AppEnv | null;
  problems: EnvProblem[];
}

/** Decodes a JWT payload without verification (used only to inspect the role claim). */
export function decodeJwtPayload(token: string): Record<string, unknown> | null {
  const parts = token.split('.');
  if (parts.length !== 3) return null;

  try {
    const base64 = parts[1]!.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
    const json = typeof atob === 'function' ? atob(padded) : Buffer.from(padded, 'base64').toString('binary');
    const parsed: unknown = JSON.parse(json);
    return typeof parsed === 'object' && parsed !== null ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export class PrivilegedKeyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PrivilegedKeyError';
  }
}

/**
 * Refuses any key that is not a publishable Supabase key.
 * - new-style keys must start with `sb_publishable_`
 * - classic keys are JWTs whose `role` claim must be `anon`
 * - `service_role` material and `sb_secret_…` keys are rejected outright
 */
export function assertPublishableKey(key: string): void {
  const value = key.trim();

  if (value.length === 0) {
    throw new PrivilegedKeyError('The Supabase key is empty.');
  }

  if (/sb_secret_|service_role|service-role/i.test(value)) {
    throw new PrivilegedKeyError(
      'A privileged Supabase key (service_role / sb_secret_…) was supplied to the frontend. ' +
        'Use the anon / publishable key — privileged keys must never reach the browser.',
    );
  }

  if (value.startsWith('sb_publishable_')) return;

  const payload = decodeJwtPayload(value);
  if (payload) {
    const role = typeof payload.role === 'string' ? payload.role : null;
    if (role !== null && role !== 'anon') {
      throw new PrivilegedKeyError(
        `The supplied Supabase key carries the "${role}" role. Only an anon / publishable key may be used in the browser.`,
      );
    }
    return;
  }

  // Not a JWT and not a new-style publishable key: refuse rather than guess.
  throw new PrivilegedKeyError(
    'The Supabase key is neither a JWT nor an sb_publishable_… key. Refusing to start with an unrecognised credential.',
  );
}

function readRawEnv(): Record<string, string | undefined> {
  const meta = import.meta as unknown as { env?: Record<string, string | undefined> };
  return meta.env ?? {};
}

/** Validates the environment and reports every problem instead of the first one. */
export function loadEnv(raw: Record<string, string | undefined> = readRawEnv()): EnvResult {
  const problems: EnvProblem[] = [];

  const url = (raw.VITE_SUPABASE_URL ?? '').trim();
  const key = (raw.VITE_SUPABASE_ANON_KEY ?? raw.VITE_SUPABASE_PUBLISHABLE_KEY ?? '').trim();
  const appName = (raw.VITE_APP_NAME ?? 'JJ Media ERP').trim();

  if (url.length === 0) {
    problems.push({
      variable: 'VITE_SUPABASE_URL',
      message: 'Not set.',
      hint: 'Example: VITE_SUPABASE_URL=https://zfrgzunauxozqgdjghso.supabase.co',
    });
  } else if (!/^https:\/\/[a-z0-9-]+\.supabase\.(co|in)$/i.test(url)) {
    problems.push({
      variable: 'VITE_SUPABASE_URL',
      message: 'Does not look like a Supabase project URL.',
      hint: 'Expected https://<project-ref>.supabase.co',
    });
  }

  if (key.length === 0) {
    problems.push({
      variable: 'VITE_SUPABASE_ANON_KEY',
      message: 'Not set.',
      hint: 'Copy the anon / publishable key from Project settings → API. Never use the service_role key.',
    });
  } else {
    try {
      assertPublishableKey(key);
    } catch (error) {
      problems.push({
        variable: 'VITE_SUPABASE_ANON_KEY',
        message: error instanceof Error ? error.message : 'Invalid key.',
        hint: 'Use the anon / publishable key only.',
      });
    }
  }

  if (problems.length > 0) {
    return { env: null, problems };
  }

  return { env: { supabaseUrl: url, supabaseAnonKey: key, appName }, problems: [] };
}

export function formatEnvProblems(problems: EnvProblem[]): string {
  return problems
    .map((problem) => `• ${problem.variable}: ${problem.message} ${problem.hint}`)
    .join('\n');
}
