import { useEffect, useState, type FormEvent } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { KeyRound, Mail, ShieldCheck } from 'lucide-react';
import { useAuth } from './useAuth';
import { describeSignInError } from '../../lib/errors';
import { Button } from '../../components/ui/Button';
import { TextField } from '../../components/ui/Field';
import { Alert } from '../../components/ui/Feedback';

interface LocationState {
  from?: { pathname?: string };
}

export function LoginPage(): React.JSX.Element {
  const { signIn, status, configProblems } = useAuth();
  const location = useLocation();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [fieldErrors, setFieldErrors] = useState<{ email?: string; password?: string }>({});
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    document.title = 'Sign in · JJ Media ERP';
  }, []);

  // Already signed in (for example after a page refresh on /login).
  if (status === 'authenticated') {
    const target = (location.state as LocationState | null)?.from?.pathname ?? '/';
    return <Navigate to={target} replace />;
  }

  const validate = (): boolean => {
    const next: { email?: string; password?: string } = {};

    if (email.trim().length === 0) next.email = 'Enter your email address.';
    else if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim())) next.email = 'Enter a valid email address.';

    if (password.length === 0) next.password = 'Enter your password.';

    setFieldErrors(next);
    return Object.keys(next).length === 0;
  };

  const handleSubmit = async (event: FormEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault();
    setError(null);

    if (!validate()) return;

    setSubmitting(true);
    try {
      await signIn(email, password);
    } catch (caught) {
      setError(describeSignInError(caught));
    } finally {
      setSubmitting(false);
    }
  };

  const redirectTo = (location.state as LocationState | null)?.from?.pathname ?? '/';
  const misconfigured = configProblems.length > 0;

  return (
    <div className="grid min-h-screen lg:grid-cols-2">
      {/* Brand panel */}
      <div className="hidden flex-col justify-between bg-ink-900 px-10 py-12 text-ink-200 lg:flex">
        <div className="flex items-center gap-3">
          <span
            aria-hidden
            className="grid size-11 place-items-center rounded-xl bg-brand-600 text-base font-bold text-white"
          >
            JJ
          </span>
          <span className="leading-tight">
            <span className="block text-base font-semibold text-white">JJ Media ERP</span>
            <span className="block text-xs text-ink-400">Production planning &amp; billing</span>
          </span>
        </div>

        <div className="max-w-md space-y-4">
          <h1 className="text-3xl font-semibold leading-tight text-white">
            Clients, projects, GST billing and media custody — in one system.
          </h1>
          <p className="text-sm text-ink-300">
            Every figure shown in this application comes from the PostgreSQL database through Row
            Level Security. Nothing is mocked, and no financial value is computed in the browser.
          </p>
          <ul className="space-y-2 text-sm text-ink-300">
            <li className="flex items-center gap-2">
              <ShieldCheck aria-hidden className="size-4 text-brand-400" />
              Roles and permissions are enforced by the database
            </li>
            <li className="flex items-center gap-2">
              <ShieldCheck aria-hidden className="size-4 text-brand-400" />
              Issued invoices are immutable; corrections use credit notes
            </li>
            <li className="flex items-center gap-2">
              <ShieldCheck aria-hidden className="size-4 text-brand-400" />
              Append-only audit trail for every business operation
            </li>
          </ul>
        </div>

        <p className="text-xs text-ink-500">
          Access is provisioned by an administrator. Public sign-up is disabled.
        </p>
      </div>

      {/* Form panel */}
      <div className="flex items-center justify-center bg-ink-100 px-4 py-12">
        <div className="w-full max-w-sm space-y-6">
          <div className="lg:hidden">
            <span
              aria-hidden
              className="grid size-10 place-items-center rounded-xl bg-brand-600 text-sm font-bold text-white"
            >
              JJ
            </span>
            <h1 className="mt-4 text-xl font-semibold text-ink-900">JJ Media ERP</h1>
          </div>

          <div>
            <h2 className="text-lg font-semibold text-ink-900">Sign in</h2>
            <p className="mt-1 text-sm text-ink-500">
              Use the account your administrator created for you.
            </p>
          </div>

          {misconfigured ? (
            <Alert tone="warning" title="Backend not configured">
              <p>
                Set <code className="font-mono">VITE_SUPABASE_URL</code> and{' '}
                <code className="font-mono">VITE_SUPABASE_ANON_KEY</code> in{' '}
                <code className="font-mono">.env.local</code> (copy{' '}
                <code className="font-mono">.env.example</code>), then restart the dev server.
              </p>
              <ul className="mt-2 space-y-1 font-mono text-xs">
                {configProblems.map((problem) => (
                  <li key={problem.variable}>
                    {problem.variable}: {problem.message}
                  </li>
                ))}
              </ul>
            </Alert>
          ) : null}

          {error ? (
            <Alert tone="error" title="Sign-in failed">
              {error}
            </Alert>
          ) : null}

          <form
            onSubmit={(event) => {
              void handleSubmit(event);
            }}
            className="space-y-4 rounded-xl bg-white p-5 shadow-sm ring-1 ring-ink-200"
            noValidate
          >
            <TextField
              label="Email"
              type="email"
              name="email"
              autoComplete="username"
              required
              value={email}
              error={fieldErrors.email ?? null}
              onChange={(event) => {
                setEmail(event.target.value);
              }}
              addon={<Mail aria-hidden className="size-4" />}
              placeholder="you@jjmedia.example"
            />

            <TextField
              label="Password"
              type="password"
              name="password"
              autoComplete="current-password"
              required
              value={password}
              error={fieldErrors.password ?? null}
              onChange={(event) => {
                setPassword(event.target.value);
              }}
              addon={<KeyRound aria-hidden className="size-4" />}
            />

            <Button
              type="submit"
              className="w-full"
              loading={submitting}
              disabled={misconfigured && !submitting}
            >
              {submitting ? 'Signing in…' : 'Sign in'}
            </Button>

            <p className="text-center text-xs text-ink-500">
              Redirects to <span className="font-mono">{redirectTo}</span> after sign-in.
            </p>
          </form>

          <p className="text-center text-xs text-ink-500">
            Lost access? Ask an ERP administrator to reset your role or password.
          </p>
        </div>
      </div>
    </div>
  );
}
