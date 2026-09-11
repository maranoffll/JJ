import { describe, expect, it } from 'vitest';
import type { Session } from '@supabase/supabase-js';
import { AppError } from '../../lib/errors';
import { authReducer, initialAuthState, isSignedIn, needsAccountAttention } from './auth-state';
import type { UserProfile } from './auth-service';

const session = {
  access_token: 'access',
  refresh_token: 'refresh',
  expires_at: 1_800_000_000,
  user: { id: 'user-1', email: 'ops@jjmedia.example' },
} as unknown as Session;

const profile: UserProfile = {
  id: 'user-1',
  email: 'ops@jjmedia.example',
  fullName: 'Ops Lead',
  role: 'MANAGER',
  phone: null,
  designation: null,
  isActive: true,
  lastLoginAt: null,
};

describe('authReducer', () => {
  it('starts in the initializing state', () => {
    expect(initialAuthState.status).toBe('initializing');
    expect(initialAuthState.checker.permissions).toEqual([]);
  });

  it('moves to unauthenticated on signed_out', () => {
    const state = authReducer(
      { ...initialAuthState, status: 'error', error: new AppError('boom') },
      { type: 'signed_out' },
    );
    expect(state.status).toBe('unauthenticated');
    expect(state.session).toBeNull();
    expect(state.error).toBeNull();
  });

  it('records a missing profile', () => {
    const state = authReducer(initialAuthState, { type: 'profile_missing', session });
    expect(state.status).toBe('no_profile');
    expect(state.session).toEqual(session);
    expect(state.profile).toBeNull();
    expect(state.checker.permissions).toEqual([]);
  });

  it('records an inactive profile', () => {
    const state = authReducer(initialAuthState, {
      type: 'profile_inactive',
      session,
      profile: { ...profile, isActive: false },
    });
    expect(state.status).toBe('inactive');
    expect(state.profile?.isActive).toBe(false);
  });

  it('builds a checker from the permissions returned by the database', () => {
    const state = authReducer(initialAuthState, {
      type: 'authenticated',
      session,
      profile,
      permissions: ['clients.view', 'not.a.real.permission'],
    });
    expect(state.status).toBe('authenticated');
    expect(state.checker.role).toBe('MANAGER');
    expect(state.checker.permissions).toEqual(['clients.view']);
    expect(state.checker.has('clients.view')).toBe(true);
  });

  it('keeps the last known identity when an error is raised', () => {
    const authenticated = authReducer(initialAuthState, {
      type: 'authenticated',
      session,
      profile,
      permissions: ['clients.view'],
    });
    const state = authReducer(authenticated, { type: 'failed', error: new AppError('offline') });
    expect(state.status).toBe('error');
    expect(state.error?.message).toBe('offline');
  });

  it('re-entering initialising clears a previous error', () => {
    const state = authReducer(
      { ...initialAuthState, status: 'error', error: new AppError('boom') },
      { type: 'initialising' },
    );
    expect(state.status).toBe('initializing');
    expect(state.error).toBeNull();
  });
});

describe('auth state predicates', () => {
  it('isSignedIn requires both a session and a profile', () => {
    const authenticated = authReducer(initialAuthState, {
      type: 'authenticated',
      session,
      profile,
      permissions: [],
    });
    expect(isSignedIn(authenticated)).toBe(true);
    expect(isSignedIn({ ...authenticated, profile: null })).toBe(false);
    expect(isSignedIn(initialAuthState)).toBe(false);
  });

  it('needsAccountAttention covers missing and inactive profiles', () => {
    expect(needsAccountAttention(authReducer(initialAuthState, { type: 'profile_missing', session }))).toBe(true);
    expect(needsAccountAttention(initialAuthState)).toBe(false);
  });
});
