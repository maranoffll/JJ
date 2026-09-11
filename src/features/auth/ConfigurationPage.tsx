import { TerminalSquare } from 'lucide-react';
import { useAuth } from './useAuth';
import { Alert } from '../../components/ui/Feedback';
import { Card } from '../../components/ui/Card';

/**
 * Rendered when the build has no usable Supabase configuration. Explains exactly
 * what to set instead of failing with a blank screen or a silent error.
 */
export function ConfigurationPage(): React.JSX.Element {
  const { configProblems } = useAuth();

  return (
    <div className="grid min-h-screen place-items-center bg-ink-100 px-4 py-12">
      <div className="w-full max-w-2xl space-y-4">
        <div className="flex items-center gap-3">
          <span
            aria-hidden
            className="grid size-10 place-items-center rounded-xl bg-brand-600 text-sm font-bold text-white"
          >
            JJ
          </span>
          <span className="text-sm font-semibold text-ink-900">JJ Media ERP</span>
        </div>

        <Alert tone="warning" title="The backend is not configured for this build">
          <p>
            The application needs the Supabase project URL and the <strong>anon / publishable</strong>{' '}
            key. Privileged keys (service_role) must never be used here.
          </p>
        </Alert>

        <Card title="Configuration problems" description="Reported by the environment validator">
          <ul className="space-y-3">
            {configProblems.map((problem) => (
              <li key={problem.variable} className="text-sm">
                <p className="font-mono text-xs font-semibold text-ink-900">{problem.variable}</p>
                <p className="text-ink-600">{problem.message}</p>
                <p className="text-xs text-ink-500">{problem.hint}</p>
              </li>
            ))}
          </ul>
        </Card>

        <Card
          title="How to fix it"
          description="Create .env.local in the project root (it is git-ignored)"
          actions={<TerminalSquare aria-hidden className="size-4 text-ink-400" />}
        >
          <pre className="overflow-x-auto rounded-lg bg-ink-900 p-4 text-xs leading-relaxed text-ink-100">
            <code>{`cp .env.example .env.local

# then edit .env.local
VITE_SUPABASE_URL=https://zfrgzunauxozqgdjghso.supabase.co
VITE_SUPABASE_ANON_KEY=<anon / publishable key>

# restart the dev server
npm run dev`}</code>
          </pre>
          <p className="mt-3 text-xs text-ink-500">
            The anon key is public by design and ships in the browser bundle. Everything it can reach
            is limited by Row Level Security in PostgreSQL.
          </p>
        </Card>
      </div>
    </div>
  );
}
