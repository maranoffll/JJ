/**
 * Authentication context object, kept in its own module so that
 * `AuthProvider.tsx` exports components only (React Fast Refresh).
 */
import { createContext } from 'react';
import type { EnvProblem } from '../../lib/env';
import type { Permission } from '../../lib/permissions';
import type { AuthState } from './auth-state';

export interface AuthContextValue extends AuthState {
  /** Non-empty when the build has no Supabase configuration. */
  configProblems: EnvProblem[];
  permissions: readonly Permission[];
  signIn: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  retry: () => void;
}

export const AuthContext = createContext<AuthContextValue | null>(null);
