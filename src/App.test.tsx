import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import type { SupabaseClient } from '@supabase/supabase-js';
import { App } from './App';
import { __setSupabaseGateway } from './lib/supabase';

/**
 * Smoke test for the composed application: provider + router + shell.
 *
 * The sandbox has no Supabase credentials, so this asserts the fail-safe path —
 * an unconfigured build explains itself instead of rendering a blank page.
 */
describe('App', () => {
  beforeEach(() => {
    __setSupabaseGateway(null);
    window.history.pushState({}, '', '/');
  });

  afterEach(() => {
    __setSupabaseGateway(null);
  });

  it('renders the configuration screen when no Supabase credentials are present', async () => {
    __setSupabaseGateway({
      client: null,
      env: null,
      problems: [
        {
          variable: 'VITE_SUPABASE_URL',
          message: 'Not set.',
          hint: 'Example: VITE_SUPABASE_URL=https://<ref>.supabase.co',
        },
        {
          variable: 'VITE_SUPABASE_ANON_KEY',
          message: 'Not set.',
          hint: 'Use the anon / publishable key only.',
        },
      ],
    });

    render(<App />);

    expect(
      await screen.findByText(/the backend is not configured for this build/i),
    ).toBeInTheDocument();
    expect(screen.getByText('VITE_SUPABASE_URL')).toBeInTheDocument();
    expect(screen.getByText('VITE_SUPABASE_ANON_KEY')).toBeInTheDocument();
    // Fails closed: no application shell without a backend.
    expect(screen.queryByRole('navigation')).not.toBeInTheDocument();
  });

  it('redirects an anonymous visitor to the login route when the backend is configured', async () => {
    const client = {
      auth: {
        getSession: () => Promise.resolve({ data: { session: null }, error: null }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => undefined } } }),
        signInWithPassword: () => Promise.resolve({ data: {}, error: null }),
        signOut: () => Promise.resolve({ error: null }),
      },
      from: () => {
        const builder = {
          select: () => builder,
          eq: () => builder,
          returns: () => builder,
          maybeSingle: () => Promise.resolve({ data: null, error: null }),
        };
        return builder;
      },
      rpc: () => Promise.resolve({ data: null, error: null }),
    } as unknown as SupabaseClient;

    __setSupabaseGateway({
      client,
      env: {
        supabaseUrl: 'https://example.supabase.co',
        supabaseAnonKey: 'sb_publishable_test_key',
        appName: 'JJ Media ERP',
      },
      problems: [],
    });

    window.history.pushState({}, '', '/clients');

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument();
  });
});
