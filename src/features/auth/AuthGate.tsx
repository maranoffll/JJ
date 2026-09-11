/**
 * Route guards.
 *
 *   <RequireAuth>   — only signed-in users with an active profile reach the app
 *   <RequireProfile> — renders a helpful screen instead of a blank page when the
 *                      account exists but the ERP profile is missing/inactive
 *
 * These guards decide what the user *sees*. Data access is still governed by RLS
 * in PostgreSQL, so bypassing a guard in devtools yields no additional data.
 */
import type { ReactNode } from 'react';
import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { useAuth } from './useAuth';
import type { Permission } from '../../lib/permissions';
import { LoadingState } from '../../components/ui/Feedback';
import { AccountStatusPage } from './AccountStatusPage';
import { ConfigurationPage } from './ConfigurationPage';

export function RequireAuth(): React.JSX.Element {
  const auth = useAuth();
  const location = useLocation();

  if (auth.status === 'initializing') {
    return (
      <div className="grid min-h-screen place-items-center bg-ink-100">
        <div className="w-full max-w-sm rounded-xl bg-white p-6 shadow-sm ring-1 ring-ink-200">
          <LoadingState label="Restoring your session…" />
        </div>
      </div>
    );
  }

  if (auth.configProblems.length > 0) {
    return <ConfigurationPage />;
  }

  if (auth.status === 'error') {
    return (
      <AccountStatusPage
        tone="error"
        title="We could not verify your access"
        message={auth.error?.message ?? 'An unexpected error occurred while loading your profile.'}
        hint={auth.error?.hint ?? 'Check your connection and try again.'}
        onRetry={auth.retry}
      />
    );
  }

  if (auth.status === 'no_profile') {
    return (
      <AccountStatusPage
        tone="warning"
        title="Your ERP access is not provisioned yet"
        message={`Signed in as ${auth.session?.user.email ?? 'unknown user'}, but this account has no ERP profile.`}
        hint="Ask an administrator to provision your profile and assign a role."
        onSignOut={auth.signOut}
      />
    );
  }

  if (auth.status === 'inactive') {
    return (
      <AccountStatusPage
        tone="error"
        title="Your account has been deactivated"
        message={`The access for ${auth.profile?.email ?? 'this account'} is currently disabled.`}
        hint="Contact an ERP administrator if you believe this is a mistake."
        onSignOut={auth.signOut}
      />
    );
  }

  if (auth.status !== 'authenticated') {
    return <Navigate to="/login" replace state={{ from: location }} />;
  }

  return <Outlet />;
}

export interface RequirePermissionProps {
  permission: Permission;
  children: ReactNode;
  /** Rendered when the permission is missing (defaults to a 403 panel). */
  fallback?: ReactNode;
}

export function RequirePermission({
  permission,
  children,
  fallback,
}: RequirePermissionProps): React.JSX.Element {
  const { checker } = useAuth();

  if (!checker.has(permission)) {
    return (
      <>
        {fallback ?? (
          <AccountStatusPage
            tone="warning"
            title="You do not have access to this module"
            message={`Your role does not include the "${permission}" permission.`}
            hint="Ask an administrator if you need access."
          />
        )}
      </>
    );
  }

  return <>{children}</>;
}
