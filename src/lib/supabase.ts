/**
 * Supabase client — the single gateway to the authoritative backend.
 *
 * The client is created lazily and only when the environment is valid, so a
 * misconfigured deployment renders an explanatory screen instead of a blank
 * page. Row Level Security is the security boundary; the frontend holds no
 * privileged credentials and performs no business-logic aggregation of its own.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { formatEnvProblems, loadEnv, type AppEnv, type EnvProblem } from './env';

export interface SupabaseGateway {
  client: SupabaseClient | null;
  env: AppEnv | null;
  problems: EnvProblem[];
}

let gateway: SupabaseGateway | null = null;

function build(): SupabaseGateway {
  const { env, problems } = loadEnv();

  if (!env) {
    if (problems.length > 0 && typeof console !== 'undefined') {
      console.error(
        `Supabase is not configured. Create .env.local from .env.example and set:\n${formatEnvProblems(problems)}`,
      );
    }
    return { client: null, env: null, problems };
  }

  const client = createClient(env.supabaseUrl, env.supabaseAnonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      storageKey: 'jj-erp-auth',
      flowType: 'pkce',
    },
    global: {
      headers: { 'x-application-name': 'jj-media-erp' },
    },
  });

  return { client, env, problems: [] };
}

/** Returns the memoised gateway (client may be null when unconfigured). */
export function getSupabaseGateway(): SupabaseGateway {
  gateway ??= build();
  return gateway;
}

/**
 * Returns the client or throws a descriptive error. Use in call sites that can
 * only proceed with a configured backend (login, data loading).
 */
export function requireSupabase(): SupabaseClient {
  const { client, problems } = getSupabaseGateway();

  if (!client) {
    throw new Error(
      `Supabase is not configured. ${problems.map((p) => `${p.variable}: ${p.message}`).join(' ')}`,
    );
  }

  return client;
}

/** Test seam: replaces the memoised gateway. */
export function __setSupabaseGateway(next: SupabaseGateway | null): void {
  gateway = next;
}
