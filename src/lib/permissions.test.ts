import { describe, expect, it } from 'vitest';
import {
  createPermissionChecker,
  isPermission,
  isUserRole,
  normalisePermissions,
  NO_PERMISSIONS,
  PERMISSIONS,
  ROLE_LABELS,
  USER_ROLES,
} from './permissions';

describe('role and permission catalogue', () => {
  it('exposes exactly the five ERP roles', () => {
    expect([...USER_ROLES]).toEqual(['ADMIN', 'MANAGER', 'FINANCE', 'PRODUCTION', 'VIEWER']);
  });

  it('labels every role', () => {
    for (const role of USER_ROLES) {
      expect(ROLE_LABELS[role]).toBeTruthy();
    }
  });

  it('contains no duplicate permission codes', () => {
    expect(new Set(PERMISSIONS).size).toBe(PERMISSIONS.length);
  });

  it('recognises known codes and rejects unknown ones', () => {
    expect(isPermission('invoices.issue')).toBe(true);
    expect(isPermission('invoices.delete')).toBe(false);
    expect(isPermission('')).toBe(false);
  });

  it('recognises roles case-sensitively', () => {
    expect(isUserRole('ADMIN')).toBe(true);
    expect(isUserRole('admin')).toBe(false);
  });
});

describe('normalisePermissions', () => {
  it('drops unknown codes', () => {
    expect(normalisePermissions(['clients.view', 'made.up', 'invoices.issue'])).toEqual([
      'clients.view',
      'invoices.issue',
    ]);
  });

  it('deduplicates and returns catalogue order', () => {
    const result = normalisePermissions(['invoices.issue', 'clients.view', 'invoices.issue']);
    expect(result).toEqual(['clients.view', 'invoices.issue']);
  });

  it('returns an empty list for an empty input', () => {
    expect(normalisePermissions([])).toEqual([]);
  });
});

describe('createPermissionChecker', () => {
  const checker = createPermissionChecker('FINANCE', [
    'invoices.view',
    'invoices.issue',
    'payments.create',
  ]);

  it('reports the role it was built with', () => {
    expect(checker.role).toBe('FINANCE');
  });

  it('answers has() correctly', () => {
    expect(checker.has('invoices.issue')).toBe(true);
    expect(checker.has('payments.void')).toBe(false);
    expect(checker.has('hdd.checkout')).toBe(false);
  });

  it('answers hasAny() correctly', () => {
    expect(checker.hasAny(['payments.void', 'payments.create'])).toBe(true);
    expect(checker.hasAny(['payments.void', 'hdd.checkout'])).toBe(false);
    expect(checker.hasAny([])).toBe(false);
  });

  it('answers hasAll() correctly', () => {
    expect(checker.hasAll(['invoices.view', 'invoices.issue'])).toBe(true);
    expect(checker.hasAll(['invoices.view', 'hdd.checkout'])).toBe(false);
    expect(checker.hasAll([])).toBe(true);
  });

  it('ignores permissions that are not in the catalogue', () => {
    const squatter = createPermissionChecker('VIEWER', ['root.everything']);
    expect(squatter.permissions).toEqual([]);
    expect(squatter.has('clients.view')).toBe(false);
  });
});

describe('NO_PERMISSIONS', () => {
  it('grants nothing', () => {
    expect(NO_PERMISSIONS.role).toBeNull();
    expect(NO_PERMISSIONS.permissions).toEqual([]);
    expect(NO_PERMISSIONS.has('clients.view')).toBe(false);
    expect(NO_PERMISSIONS.hasAny(PERMISSIONS)).toBe(false);
  });
});
