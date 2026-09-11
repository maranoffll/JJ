import { useState } from 'react';
import { Outlet } from 'react-router-dom';
import { LogOut, Menu, UserRound } from 'lucide-react';
import { useAuth } from '../../features/auth/useAuth';
import { ROLE_LABELS } from '../../lib/permissions';
import { Sidebar } from './Sidebar';
import { Button } from '../ui/Button';

const PHASE_LABEL = 'Phase 2 — authentication & application shell';

export function AppShell(): React.JSX.Element {
  const { profile, checker, signOut, configProblems } = useAuth();
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [signingOut, setSigningOut] = useState(false);

  /** The mobile drawer closes itself as soon as a navigation link is followed. */
  const closeDrawer = (): void => {
    setDrawerOpen(false);
  };

  const handleSignOut = async (): Promise<void> => {
    setSigningOut(true);
    try {
      await signOut();
    } finally {
      setSigningOut(false);
    }
  };

  return (
    <div className="flex min-h-screen bg-ink-100">
      {/* Desktop sidebar */}
      <aside className="sticky top-0 hidden h-screen lg:block">
        <Sidebar checker={checker} />
      </aside>

      {/* Mobile drawer */}
      {drawerOpen ? (
        <div className="fixed inset-0 z-40 lg:hidden">
          <button
            type="button"
            aria-label="Close navigation overlay"
            className="absolute inset-0 bg-ink-900/60"
            onClick={closeDrawer}
          />
          <div className="relative h-full w-72 shadow-xl">
            <Sidebar checker={checker} onClose={closeDrawer} onNavigate={closeDrawer} />
          </div>
        </div>
      ) : null}

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-30 border-b border-ink-200 bg-white/95 backdrop-blur">
          <div className="flex items-center gap-3 px-4 py-3 sm:px-6">
            <button
              type="button"
              onClick={() => setDrawerOpen(true)}
              aria-label="Open navigation"
              className="rounded-md p-2 text-ink-600 hover:bg-ink-100 lg:hidden"
            >
              <Menu aria-hidden className="size-5" />
            </button>

            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-semibold text-ink-900">
                {profile?.fullName ?? 'Signed in'}
              </p>
              <p className="truncate text-xs text-ink-500">
                {profile ? `${ROLE_LABELS[profile.role]} · ${profile.email}` : ''}
              </p>
            </div>

            <Button
              variant="secondary"
              size="sm"
              onClick={() => void handleSignOut()}
              loading={signingOut}
              icon={<LogOut aria-hidden className="size-3.5" />}
            >
              <span className="hidden sm:inline">Sign out</span>
            </Button>
          </div>
        </header>

        {configProblems.length > 0 ? (
          <div className="border-b border-caution-600/20 bg-caution-50 px-4 py-2 text-xs text-caution-700 sm:px-6">
            Supabase is not configured — reads and writes will fail until the environment is set.
          </div>
        ) : null}

        <main className="mx-auto w-full max-w-7xl flex-1 px-4 py-6 sm:px-6 lg:py-8">
          <Outlet />
        </main>

        <footer className="border-t border-ink-200 bg-white px-4 py-3 sm:px-6">
          <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-2 text-xs text-ink-500">
            <span className="inline-flex items-center gap-1.5">
              <UserRound aria-hidden className="size-3.5" />
              {profile ? `${profile.email} · ${ROLE_LABELS[profile.role]}` : ''}
            </span>
            <span>{PHASE_LABEL}</span>
          </div>
        </footer>
      </div>
    </div>
  );
}
