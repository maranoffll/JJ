/**
 * Pure auth state machine — kept free of React and network calls so it can be
 * unit-tested directly.
 */
import type { Session } from '@supabase/supabase-js';
import type { AppError } from '../../lib/errors';
import { createPermissionChecker, NO_PERMISSIONS, type PermissionChecker } from '../../lib/permissions';
import type { UserProfile } from './auth-service';

export type AuthStatus =
  | 'initializing'
  | 'unauthenticated'
  | 'authenticated'
  | 'no_profile'
  | 'inactive'
  | 'error';

export interface AuthState {
  status: AuthStatus;
  session: Session | null;
  profile: UserProfile | null;
  checker: PermissionChecker;
  error: AppError | null;
}

export type AuthAction =
  | { type: 'initialising' }
  | { type: 'signed_out' }
  | { type: 'profile_missing'; session: Session }
  | { type: 'profile_inactive'; session: Session; profile: UserProfile }
  | { type: 'authenticated'; session: Session; profile: UserProfile; permissions: readonly string[] }
  | { type: 'failed'; error: AppError };

export const initialAuthState: AuthState = {
  status: 'initializing',
  session: null,
  profile: null,
  checker: NO_PERMISSIONS,
  error: null,
};

export function authReducer(state: AuthState, action: AuthAction): AuthState {
  switch (action.type) {
    case 'initialising':
      return { ...state, status: 'initializing', error: null };

    case 'signed_out':
      return { ...initialAuthState, status: 'unauthenticated' };

    case 'profile_missing':
      return {
        status: 'no_profile',
        session: action.session,
        profile: null,
        checker: NO_PERMISSIONS,
        error: null,
      };

    case 'profile_inactive':
      return {
        status: 'inactive',
        session: action.session,
        profile: action.profile,
        checker: NO_PERMISSIONS,
        error: null,
      };

    case 'authenticated':
      return {
        status: 'authenticated',
        session: action.session,
        profile: action.profile,
        checker: createPermissionChecker(action.profile.role, action.permissions),
        error: null,
      };

    case 'failed':
      return { ...state, status: 'error', error: action.error };

    default: {
      const exhaustive: never = action;
      return exhaustive;
    }
  }
}

/** True when the shell may be rendered. */
export function isSignedIn(state: AuthState): boolean {
  return state.status === 'authenticated' && state.session !== null && state.profile !== null;
}

/** True when credentials are established but the ERP profile blocks access. */
export function needsAccountAttention(state: AuthState): boolean {
  return state.status === 'no_profile' || state.status === 'inactive';
}
