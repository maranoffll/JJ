/**
 * Authentication provider.
 *
 * Responsibilities:
 *   * restore and follow the Supabase session
 *   * resolve the ERP profile and permission list from the database
 *   * expose sign-in / sign-out / retry to the UI
 *
 * The provider never derives a role locally: it only mirrors what
 * public.user_profiles says about the signed-in user.
 */
import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import type { Session } from '@supabase/supabase-js';
import { getSupabaseGateway } from '../../lib/supabase';
import { toAppError } from '../../lib/errors';
import { NO_PERMISSIONS } from '../../lib/permissions';
import {
  fetchPermissions,
  fetchProfile,
  recordLogin,
  signInWithPassword,
  signOut as signOutRequest,
  type UserProfile,
} from './auth-service';
import { authReducer, initialAuthState, type AuthState } from './auth-state';
import { AuthContext, type AuthContextValue } from './auth-context';

export function AuthProvider({ children }: { children: ReactNode }): React.JSX.Element {
  const [state, dispatch] = useReducer(authReducer, initialAuthState);
  const [attempt, setAttempt] = useState(0);
  const recordedForUser = useRef<string | null>(null);
  const gateway = useMemo(() => getSupabaseGateway(), []);

  const resolveIdentity = useCallback(
    async (session: Session | null): Promise<AuthState | null> => {
      if (!session) {
        dispatch({ type: 'signed_out' });
        return null;
      }

      try {
        const profile = await fetchProfile(session.user.id);

        if (!profile) {
          dispatch({ type: 'profile_missing', session });
          return null;
        }

        if (!profile.isActive) {
          dispatch({ type: 'profile_inactive', session, profile });
          return null;
        }

        const permissions = await fetchPermissions(profile.role);

        // One LOGIN audit entry per signed-in user per browser session.
        if (recordedForUser.current !== profile.id) {
          recordedForUser.current = profile.id;
          void recordLogin();
        }

        dispatch({ type: 'authenticated', session, profile, permissions });
        return null;
      } catch (error) {
        dispatch({ type: 'failed', error: toAppError(error) });
        return null;
      }
    },
    [],
  );

  // Initial session restore + subscription to auth changes.
  useEffect(() => {
    const client = gateway.client;

    if (!client) {
      dispatch({ type: 'signed_out' });
      return undefined;
    }

    let active = true;
    dispatch({ type: 'initialising' });

    void (async () => {
      try {
        const { data, error } = await client.auth.getSession();
        if (!active) return;
        if (error) throw error;
        await resolveIdentity(data.session);
      } catch (error) {
        if (!active) return;
        dispatch({ type: 'failed', error: toAppError(error) });
      }
    })();

    const { data: subscription } = client.auth.onAuthStateChange((event, session) => {
      if (!active) return;

      if (event === 'SIGNED_OUT') {
        recordedForUser.current = null;
        dispatch({ type: 'signed_out' });
        return;
      }

      // SIGNED_IN, INITIAL_SESSION, TOKEN_REFRESHED, USER_UPDATED
      void resolveIdentity(session);
    });

    return () => {
      active = false;
      subscription.subscription.unsubscribe();
    };
  }, [gateway.client, resolveIdentity, attempt]);

  const signIn = useCallback(async (email: string, password: string): Promise<void> => {
    const session = await signInWithPassword(email, password);
    await resolveIdentity(session);
  }, [resolveIdentity]);

  const signOut = useCallback(async (): Promise<void> => {
    try {
      await signOutRequest();
    } finally {
      recordedForUser.current = null;
      dispatch({ type: 'signed_out' });
    }
  }, []);

  const retry = useCallback(() => {
    setAttempt((value) => value + 1);
  }, []);

  const value = useMemo<AuthContextValue>(
    () => ({
      ...state,
      configProblems: gateway.problems,
      permissions: state.checker.permissions.length > 0 ? state.checker.permissions : NO_PERMISSIONS.permissions,
      signIn,
      signOut,
      retry,
    }),
    [state, gateway.problems, signIn, signOut, retry],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export type { UserProfile };
