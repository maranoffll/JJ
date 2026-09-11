import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import type { Session, SupabaseClient } from '@supabase/supabase-js';
import { AuthProvider } from './AuthProvider';
import { RequireAuth, RequirePermission } from './AuthGate';
import { LoginPage } from './LoginPage';
import { __setSupabaseGateway } from '../../lib/supabase';

const ANON_KEY = 'sb_publishable_test_key';

const session = {
  access_token: 'token',
  refresh_token: 'refresh',
  expires_at: 1_800_000_000,
  user: { id: 'user-1', email: 'ops@jjmedia.example' },
} as unknown as Session;

interface ProfileRow {
  id: string;
  email: string;
  full_name: string;
  role: string;
  phone: string | null;
  designation: string | null;
  is_active: boolean;
  last_login_at: string | null;
}

interface Options {
  session: Session | null;
  profile?: ProfileRow | null;
  permissions?: { permission: string }[];
  profileError?: { message: string; code?: string } | null;
}

/** A complete public.user_profiles row, as PostgREST would return it. */
function profileRow(overrides: Partial<ProfileRow> = {}): ProfileRow {
  return {
    id: 'user-1',
    email: 'ops@jjmedia.example',
    full_name: 'Ops Lead',
    role: 'MANAGER',
    phone: null,
    designation: null,
    is_active: true,
    last_login_at: null,
    ...overrides,
  };
}

function installGateway(options: Options): void {
  const client = {
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: options.session }, error: null })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
      signInWithPassword: vi.fn(() => Promise.resolve({ data: {}, error: null })),
      signOut: vi.fn(() => Promise.resolve({ error: null })),
    },
    from: vi.fn((table: string) => {
      const builder = {
        select: vi.fn(() => builder),
        eq: vi.fn(() => builder),
        returns: vi.fn(() => builder),
        maybeSingle: vi.fn(() =>
          Promise.resolve({ data: options.profile ?? null, error: options.profileError ?? null }),
        ),
        then: undefined,
      };
      // role_permissions is awaited directly (no maybeSingle), user_profiles is not.
      if (table === 'role_permissions') {
        return {
          select: vi.fn(() => ({
            eq: vi.fn(() => ({
              returns: vi.fn(() =>
                Promise.resolve({ data: options.permissions ?? [], error: null }),
              ),
            })),
          })),
        };
      }
      return builder;
    }),
    rpc: vi.fn(() => Promise.resolve({ data: null, error: null })),
  } as unknown as SupabaseClient;

  __setSupabaseGateway({
    client,
    env: {
      supabaseUrl: 'https://example.supabase.co',
      supabaseAnonKey: ANON_KEY,
      appName: 'JJ Media ERP',
    },
    problems: [],
  });
}

function renderApp(): void {
  render(
    <MemoryRouter initialEntries={['/']}>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route element={<RequireAuth />}>
            <Route
              path="/"
              element={
                <RequirePermission permission="clients.view">
                  <p>Client list</p>
                </RequirePermission>
              }
            />
          </Route>
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

describe('RequireAuth', () => {
  beforeEach(() => {
    __setSupabaseGateway(null);
  });

  afterEach(() => {
    __setSupabaseGateway(null);
    vi.restoreAllMocks();
  });

  it('redirects an anonymous visitor to the login page', async () => {
    installGateway({ session: null });
    renderApp();

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument();
    expect(screen.queryByText('Client list')).not.toBeInTheDocument();
  });

  it('blocks a session without an ERP profile', async () => {
    installGateway({ session, profile: null });
    renderApp();

    expect(await screen.findByText(/not provisioned yet/i)).toBeInTheDocument();
    expect(screen.queryByText('Client list')).not.toBeInTheDocument();
  });

  it('blocks a deactivated account', async () => {
    installGateway({ session, profile: profileRow({ is_active: false }) });
    renderApp();

    expect(await screen.findByText(/has been deactivated/i)).toBeInTheDocument();
  });

  it('blocks access when the profile cannot be read', async () => {
    installGateway({
      session,
      profile: null,
      profileError: { message: 'permission denied', code: '42501' },
    });
    renderApp();

    expect(await screen.findByText(/could not verify your access/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /try again/i })).toBeInTheDocument();
  });

  it('admits an active profile that holds the required permission', async () => {
    installGateway({
      session,
      profile: profileRow(),
      permissions: [{ permission: 'clients.view' }, { permission: 'projects.view' }],
    });
    renderApp();

    expect(await screen.findByText('Client list')).toBeInTheDocument();
  });

  it('hides a module the role does not hold, even with a valid session', async () => {
    installGateway({
      session,
      profile: profileRow({ role: 'PRODUCTION' }),
      permissions: [{ permission: 'hdd.checkout' }],
    });
    renderApp();

    expect(await screen.findByText(/do not have access to this module/i)).toBeInTheDocument();
    expect(screen.queryByText('Client list')).not.toBeInTheDocument();
  });

  it('shows the configuration screen instead of the app when the build is unconfigured', async () => {
    __setSupabaseGateway({
      client: null,
      env: null,
      problems: [{ variable: 'VITE_SUPABASE_ANON_KEY', message: 'Not set.', hint: 'Set it.' }],
    });
    renderApp();

    expect(await screen.findByText(/not configured for this build/i)).toBeInTheDocument();
    expect(screen.queryByText('Client list')).not.toBeInTheDocument();
  });
});
