import { describe, expect, it } from 'vitest';
import {
  assertPublishableKey,
  decodeJwtPayload,
  formatEnvProblems,
  loadEnv,
  PrivilegedKeyError,
} from './env';

/** Builds an unsigned JWT with the given payload (structure only, never a real credential). */
function fakeJwt(payload: Record<string, unknown>): string {
  const encode = (value: Record<string, unknown>): string =>
    btoa(JSON.stringify(value)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode(payload)}.signature`;
}

const ANON_JWT = fakeJwt({ iss: 'supabase', role: 'anon', ref: 'local' });
const SERVICE_JWT = fakeJwt({ iss: 'supabase', role: 'service_role', ref: 'local' });

describe('decodeJwtPayload', () => {
  it('decodes a well-formed JWT payload', () => {
    expect(decodeJwtPayload(ANON_JWT)).toMatchObject({ role: 'anon' });
  });

  it('returns null for anything that is not a JWT', () => {
    expect(decodeJwtPayload('not-a-jwt')).toBeNull();
    expect(decodeJwtPayload('a.b')).toBeNull();
  });
});

describe('assertPublishableKey', () => {
  it('accepts a classic anon JWT', () => {
    expect(() => {
      assertPublishableKey(ANON_JWT);
    }).not.toThrow();
  });

  it('accepts a new-style publishable key', () => {
    expect(() => {
      assertPublishableKey('sb_publishable_abc123');
    }).not.toThrow();
  });

  it('rejects a service_role JWT', () => {
    expect(() => {
      assertPublishableKey(SERVICE_JWT);
    }).toThrow(PrivilegedKeyError);
  });

  it('rejects any key containing service_role even when not a JWT', () => {
    expect(() => {
      assertPublishableKey('prefix-service_role-suffix');
    }).toThrow(/privileged/i);
  });

  it('rejects a secret key', () => {
    expect(() => {
      assertPublishableKey('sb_secret_abcdef');
    }).toThrow(PrivilegedKeyError);
  });

  it('rejects an unrecognised credential rather than guessing', () => {
    expect(() => {
      assertPublishableKey('some-random-api-key-value');
    }).toThrow(/unrecognised/i);
  });

  it('rejects an empty key', () => {
    expect(() => {
      assertPublishableKey('   ');
    }).toThrow(PrivilegedKeyError);
  });
});

describe('loadEnv', () => {
  const valid = {
    VITE_SUPABASE_URL: 'https://zfrgzunauxozqgdjghso.supabase.co',
    VITE_SUPABASE_ANON_KEY: ANON_JWT,
    VITE_APP_NAME: 'JJ Media ERP',
  };

  it('accepts a valid configuration', () => {
    const result = loadEnv(valid);
    expect(result.problems).toHaveLength(0);
    expect(result.env?.supabaseUrl).toBe('https://zfrgzunauxozqgdjghso.supabase.co');
    expect(result.env?.appName).toBe('JJ Media ERP');
  });

  it('reports every missing variable at once', () => {
    const result = loadEnv({});
    expect(result.env).toBeNull();
    expect(result.problems.map((p) => p.variable)).toEqual([
      'VITE_SUPABASE_URL',
      'VITE_SUPABASE_ANON_KEY',
    ]);
  });

  it('rejects a non-Supabase URL', () => {
    const result = loadEnv({ ...valid, VITE_SUPABASE_URL: 'http://localhost:8000' });
    expect(result.problems.some((p) => p.variable === 'VITE_SUPABASE_URL')).toBe(true);
  });

  it('rejects a privileged key and explains why', () => {
    const result = loadEnv({ ...valid, VITE_SUPABASE_ANON_KEY: SERVICE_JWT });
    expect(result.env).toBeNull();
    expect(result.problems[0]?.message).toMatch(/anon \/ publishable key/i);
  });

  it('falls back to a default application name', () => {
    const result = loadEnv({ ...valid, VITE_APP_NAME: undefined });
    expect(result.env?.appName).toBe('JJ Media ERP');
  });
});

describe('formatEnvProblems', () => {
  it('renders one bullet per problem', () => {
    const text = formatEnvProblems([
      { variable: 'A', message: 'missing', hint: 'set it' },
      { variable: 'B', message: 'invalid', hint: 'fix it' },
    ]);
    expect(text.split('\n')).toHaveLength(2);
    expect(text).toContain('• A: missing set it');
  });
});
