import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import type { SupabaseClient } from '@supabase/supabase-js';
import { AuthProvider } from './AuthProvider';
import { LoginPage } from './LoginPage';
import { __setSupabaseGateway } from '../../lib/supabase';

const ANON_KEY = 'sb_publishable_test_key';

interface GatewayOptions {
  configured?: boolean;
  signInError?: { message: string; code?: string };
  profile?: { is_active: boolean } | null;
}

interface TestGateway {
  client: SupabaseClient;
  signInWithPassword: ReturnType<typeof vi.fn>;
}

/** Minimal Supabase stand-in: only the surface the auth flow touches. */
function makeClient(options: GatewayOptions): TestGateway {
  const signInWithPassword = vi.fn(() => {
    if (options.signInError) {
      return Promise.resolve({
        data: { user: null, session: null },
        error: options.signInError,
      });
    }

    return Promise.resolve({
      data: {
        user: { id: 'user-1', email: 'ops@jjmedia.example' },
        session: {
          access_token: 'token',
          refresh_token: 'refresh',
          expires_at: 1_800_000_000,
          user: { id: 'user-1', email: 'ops@jjmedia.example' },
        },
      },
      error: null,
    });
  });

  const client = {
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null }, error: null })),
      onAuthStateChange: vi.fn(() => ({
        data: { subscription: { unsubscribe: vi.fn() } },
      })),
      signInWithPassword,
      signOut: vi.fn(() => Promise.resolve({ error: null })),
    },
    from: vi.fn(() => {
      const builder = {
        select: vi.fn(() => builder),
        eq: vi.fn(() => builder),
        returns: vi.fn(() => builder),
        maybeSingle: vi.fn(() => Promise.resolve({ data: options.profile ?? null, error: null })),
      };
      return builder;
    }),
    rpc: vi.fn(() => Promise.resolve({ data: null, error: { message: 'not tested' } })),
  } as unknown as SupabaseClient;

  return { client, signInWithPassword };
}

function installGateway(options: GatewayOptions): TestGateway {
  const gateway = makeClient(options);

  if (options.configured === false) {
    __setSupabaseGateway({
      client: null,
      env: null,
      problems: [
        { variable: 'VITE_SUPABASE_URL', message: 'Not set.', hint: 'Set it in .env.local.' },
      ],
    });
  } else {
    __setSupabaseGateway({
      client: gateway.client,
      env: {
        supabaseUrl: 'https://example.supabase.co',
        supabaseAnonKey: ANON_KEY,
        appName: 'JJ Media ERP',
      },
      problems: [],
    });
  }

  return gateway;
}

function renderLogin(): void {
  render(
    <MemoryRouter initialEntries={['/login']}>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route path="/" element={<p>Dashboard</p>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

describe('LoginPage', () => {
  beforeEach(() => {
    __setSupabaseGateway(null);
  });

  afterEach(() => {
    __setSupabaseGateway(null);
    vi.restoreAllMocks();
  });

  it('renders the sign-in form', async () => {
    installGateway({});
    renderLogin();

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument();
    expect(screen.getByLabelText(/email/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/password/i)).toBeInTheDocument();
  });

  it('validates the form before calling the backend', async () => {
    const gateway = installGateway({});
    const user = userEvent.setup();
    renderLogin();

    await user.click(await screen.findByRole('button', { name: /^sign in$/i }));

    expect(await screen.findByText('Enter your email address.')).toBeInTheDocument();
    expect(screen.getByText('Enter your password.')).toBeInTheDocument();
    expect(gateway.signInWithPassword).not.toHaveBeenCalled();
  });

  it('rejects a malformed email address', async () => {
    installGateway({});
    const user = userEvent.setup();
    renderLogin();

    await user.type(await screen.findByLabelText(/email/i), 'not-an-email');
    await user.type(screen.getByLabelText(/password/i), 'secret');
    await user.click(screen.getByRole('button', { name: /^sign in$/i }));

    expect(await screen.findByText('Enter a valid email address.')).toBeInTheDocument();
  });

  it('signs in with trimmed lowercase credentials and leaves the page', async () => {
    const gateway = installGateway({
      profile: { is_active: true },
    });
    const user = userEvent.setup();
    renderLogin();

    await user.type(await screen.findByLabelText(/email/i), '  Ops@JJMedia.example ');
    await user.type(screen.getByLabelText(/password/i), 'secret');
    await user.click(screen.getByRole('button', { name: /^sign in$/i }));

    await waitFor(() => {
      expect(gateway.signInWithPassword).toHaveBeenCalledWith({
        email: 'ops@jjmedia.example',
        password: 'secret',
      });
    });
  });

  it('shows a message when the credentials are rejected, without revealing whether the account exists', async () => {
    installGateway({ signInError: { message: 'Invalid login credentials', code: 'invalid_credentials' } });
    const user = userEvent.setup();
    renderLogin();

    await user.type(await screen.findByLabelText(/email/i), 'ops@jjmedia.example');
    await user.type(screen.getByLabelText(/password/i), 'wrong');
    await user.click(screen.getByRole('button', { name: /^sign in$/i }));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(/incorrect email or password/i);
    expect(alert.textContent ?? '').not.toMatch(/not found|no such user/i);
  });

  it('explains that the backend is not configured instead of failing silently', async () => {
    installGateway({ configured: false });
    renderLogin();

    expect(await screen.findByText(/backend not configured/i)).toBeInTheDocument();
    // The validator reports the specific variable that is missing.
    expect(screen.getByText('VITE_SUPABASE_URL: Not set.')).toBeInTheDocument();
  });
});
