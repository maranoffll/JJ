import { ShieldCheck } from 'lucide-react';
import { useAuth } from '../features/auth/useAuth';
import { Card, PageHeader, Badge } from '../components/ui/Card';
import { EmptyState } from '../components/ui/Feedback';
import { ROLE_DESCRIPTIONS, ROLE_LABELS } from '../lib/permissions';
import { NAVIGATION } from '../app/navigation';

/**
 * Landing page for Phase 2.
 *
 * It reports the identity and permissions that the database returned for the
 * signed-in user, and lists the modules that are still pending. It deliberately
 * shows no business figures: those arrive with the dashboard phase, computed by
 * the database, not by the browser.
 */
export function HomePage(): React.JSX.Element {
  const { profile, checker, session } = useAuth();

  const pendingModules = NAVIGATION.flatMap((section) =>
    section.items.filter((item) => item.phase !== null).map((item) => ({ ...item, section: section.label })),
  );

  return (
    <>
      <PageHeader
        title={`Welcome${profile ? `, ${profile.fullName}` : ''}`}
        description="The database foundation (Phase 1) and authentication (Phase 2) are in place. Business modules are delivered in the phases listed below."
      />

      <div className="grid gap-4 lg:grid-cols-3">
        <Card title="Signed in as" description="Identity resolved from public.user_profiles">
          <dl className="space-y-2 text-sm">
            <div className="flex justify-between gap-3">
              <dt className="text-ink-500">Name</dt>
              <dd className="font-medium text-ink-900">{profile?.fullName ?? '—'}</dd>
            </div>
            <div className="flex justify-between gap-3">
              <dt className="text-ink-500">Email</dt>
              <dd className="truncate font-medium text-ink-900">{profile?.email ?? session?.user.email ?? '—'}</dd>
            </div>
            <div className="flex items-center justify-between gap-3">
              <dt className="text-ink-500">Role</dt>
              <dd>{profile ? <Badge tone="brand">{ROLE_LABELS[profile.role]}</Badge> : '—'}</dd>
            </div>
            <div className="flex justify-between gap-3">
              <dt className="text-ink-500">Session expires</dt>
              <dd className="font-medium text-ink-900">
                {session?.expires_at ? new Date(session.expires_at * 1000).toLocaleString() : '—'}
              </dd>
            </div>
          </dl>
          {profile ? <p className="mt-3 text-xs text-ink-500">{ROLE_DESCRIPTIONS[profile.role]}</p> : null}
        </Card>

        <Card
          title="Your permissions"
          description={`${checker.permissions.length} permission(s) granted by public.role_permissions`}
          className="lg:col-span-2"
        >
          {checker.permissions.length === 0 ? (
            <EmptyState
              title="No permissions granted"
              description="Your role currently grants no module access. An administrator can adjust it in the users & roles module."
            />
          ) : (
            <>
              <div className="flex flex-wrap gap-1.5">
                {checker.permissions.map((permission) => (
                  <span
                    key={permission}
                    className="rounded-md bg-ink-100 px-2 py-0.5 font-mono text-[0.6875rem] text-ink-700 ring-1 ring-inset ring-ink-200"
                  >
                    {permission}
                  </span>
                ))}
              </div>
              <p className="mt-3 flex items-start gap-2 text-xs text-ink-500">
                <ShieldCheck aria-hidden className="mt-0.5 size-3.5 shrink-0 text-positive-600" />
                These are mirrored for display only. Every query and mutation is authorised by
                PostgreSQL Row Level Security, so the list above cannot grant access by itself.
              </p>
            </>
          )}
        </Card>
      </div>

      <div className="mt-6">
        <Card
          title="Module roadmap"
          description="Modules become available as their phase is completed and verified"
        >
          <ul className="divide-y divide-ink-200">
            {pendingModules.map((item) => {
              const Icon = item.icon;
              return (
                <li key={item.id} className="flex items-center gap-3 py-3">
                  <Icon aria-hidden className="size-4 shrink-0 text-ink-400" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium text-ink-800">{item.label}</p>
                    <p className="truncate text-xs text-ink-500">{item.description}</p>
                  </div>
                  <span className="shrink-0 text-xs text-ink-500">{item.section}</span>
                  <Badge tone={item.phase === 3 ? 'caution' : 'neutral'}>Phase {item.phase}</Badge>
                </li>
              );
            })}
          </ul>
        </Card>
      </div>

      <p className="mt-6 text-xs text-ink-500">
        Database tooling runs outside the browser: <code className="font-mono">npm run verify</code>{' '}
        executes the migration, RLS, RBAC, concurrency and secret-scan checks against PostgreSQL. The
        schema reference lives in <code className="font-mono">docs/DATABASE.md</code>.
      </p>
    </>
  );
}
