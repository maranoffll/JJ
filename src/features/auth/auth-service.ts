/**
 * Authentication and identity service.
 *
 * Everything here talks to Supabase (Auth + public tables protected by RLS):
 *   auth.users          — credentials and sessions (Supabase managed)
 *   public.user_profiles — the ERP profile and server-side role
 *   public.role_permissions — the permission matrix for that role
 *
 * No business data is cached in the browser and no role is ever inferred from
 * anything the client supplies.
 */
import type { Session } from '@supabase/supabase-js';
import { requireSupabase } from '../../lib/supabase';
import { AppError, toAppError } from '../../lib/errors';
import { isUserRole, normalisePermissions, type Permission, type UserRole } from '../../lib/permissions';

export interface UserProfile {
  id: string;
  email: string;
  fullName: string;
  role: UserRole;
  phone: string | null;
  designation: string | null;
  isActive: boolean;
  lastLoginAt: string | null;
}

interface ProfileRow {
  id: string;
  email: string;
  full_name: string | null;
  role: string;
  phone: string | null;
  designation: string | null;
  is_active: boolean;
  last_login_at: string | null;
}

interface PermissionRow {
  permission: string;
}

function mapProfileRow(row: ProfileRow): UserProfile {
  return {
    id: row.id,
    email: row.email,
    fullName: row.full_name?.trim() ? row.full_name.trim() : row.email.split('@')[0]!,
    role: isUserRole(row.role) ? row.role : 'VIEWER',
    phone: row.phone,
    designation: row.designation,
    isActive: row.is_active,
    lastLoginAt: row.last_login_at,
  };
}

export async function getSession(): Promise<Session | null> {
  const { data, error } = await requireSupabase().auth.getSession();
  if (error) throw toAppError(error);
  return data.session;
}

export async function signInWithPassword(email: string, password: string): Promise<Session> {
  const client = requireSupabase();
  const { data, error } = await client.auth.signInWithPassword({
    email: email.trim().toLowerCase(),
    password,
  });

  if (error) {
    throw new AppError(error.message, { code: error.code ?? null, cause: error });
  }

  if (!data.session) {
    throw new AppError('Sign-in did not return a session. Check that email confirmation is disabled.', {
      code: 'no_session',
    });
  }

  return data.session;
}

export async function signOut(): Promise<void> {
  const { error } = await requireSupabase().auth.signOut();
  if (error) throw toAppError(error);
}

/** Reads the caller's own profile. RLS permits only their own row (plus directory access for admins). */
export async function fetchProfile(userId: string): Promise<UserProfile | null> {
  const { data, error } = await requireSupabase()
    .from('user_profiles')
    .select('id, email, full_name, role, phone, designation, is_active, last_login_at')
    .eq('id', userId)
    .returns<ProfileRow>()
    .maybeSingle();

  if (error) throw toAppError(error);
  if (!data) return null;

  return mapProfileRow(data);
}

/** Permissions granted to a role, straight from the database matrix. */
export async function fetchPermissions(role: UserRole): Promise<Permission[]> {
  const { data, error } = await requireSupabase()
    .from('role_permissions')
    .select('permission')
    .eq('role', role)
    .returns<PermissionRow[]>();

  if (error) throw toAppError(error);

  return normalisePermissions((data ?? []).map((row) => row.permission));
}

/**
 * Stamps last_login_at and appends a LOGIN audit record.
 * Failure here must never block a sign-in, so it is reported, not thrown.
 */
export async function recordLogin(): Promise<boolean> {
  const { error } = await requireSupabase().rpc('record_login');
  if (error) {
    console.warn('Could not record the login event:', error.message);
    return false;
  }
  return true;
}
