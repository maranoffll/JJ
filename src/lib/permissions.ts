/**
 * RBAC surface for the frontend.
 *
 * IMPORTANT: this module mirrors the database matrix so the UI can decide what
 * to render. It is NOT the security boundary — PostgreSQL enforces the real
 * rules through Row Level Security and `public.has_permission()`. Hiding a
 * button never grants or removes access.
 */

export const USER_ROLES = ['ADMIN', 'MANAGER', 'FINANCE', 'PRODUCTION', 'VIEWER'] as const;
export type UserRole = (typeof USER_ROLES)[number];

/** Permission codes seeded in public.role_permissions (Phase 1). */
export const PERMISSIONS = [
  'clients.view', 'clients.create', 'clients.update', 'clients.delete',
  'projects.view', 'projects.create', 'projects.update', 'projects.delete',
  'quotations.view', 'quotations.create', 'quotations.update', 'quotations.delete',
  'quotations.issue', 'quotations.convert',
  'invoices.view', 'invoices.create', 'invoices.update', 'invoices.issue', 'invoices.cancel',
  'payments.view', 'payments.create', 'payments.void',
  'credit_notes.view', 'credit_notes.create', 'credit_notes.issue', 'credit_notes.cancel',
  'expenses.view', 'expenses.create', 'expenses.update', 'expenses.approve', 'expenses.void',
  'hdd.view', 'hdd.create', 'hdd.update', 'hdd.delete', 'hdd.checkout', 'hdd.checkin', 'hdd.archive',
  'attachments.upload', 'attachments.delete',
  'reports.view', 'reports.financial',
  'audit.view',
  'settings.view', 'settings.update',
  'users.view', 'users.manage',
] as const;

export type Permission = (typeof PERMISSIONS)[number];

const PERMISSION_SET: ReadonlySet<string> = new Set<string>(PERMISSIONS);

export function isPermission(value: string): value is Permission {
  return PERMISSION_SET.has(value);
}

/** Keeps only codes the application knows about, in a stable order. */
export function normalisePermissions(values: readonly string[]): Permission[] {
  const seen = new Set<Permission>();
  for (const value of values) {
    if (isPermission(value)) seen.add(value);
  }
  return PERMISSIONS.filter((permission) => seen.has(permission));
}

export const ROLE_LABELS: Record<UserRole, string> = {
  ADMIN: 'Administrator',
  MANAGER: 'Manager',
  FINANCE: 'Finance',
  PRODUCTION: 'Production',
  VIEWER: 'Viewer',
};

export const ROLE_DESCRIPTIONS: Record<UserRole, string> = {
  ADMIN: 'Full control including users, permissions and company settings.',
  MANAGER: 'Clients, projects, quotations and production oversight.',
  FINANCE: 'Billing, GST documents, collections and statutory reports.',
  PRODUCTION: 'Projects, shoots, expenses and media custody.',
  VIEWER: 'Read-only access to operational records.',
};

export function isUserRole(value: string): value is UserRole {
  return (USER_ROLES as readonly string[]).includes(value);
}

export interface PermissionChecker {
  has(permission: Permission): boolean;
  hasAny(permissions: readonly Permission[]): boolean;
  hasAll(permissions: readonly Permission[]): boolean;
  readonly role: UserRole | null;
  readonly permissions: readonly Permission[];
}

/** Builds a checker over the permission list resolved from the database. */
export function createPermissionChecker(
  role: UserRole | null,
  permissions: readonly string[],
): PermissionChecker {
  const granted = new Set<Permission>(normalisePermissions(permissions));

  return {
    role,
    permissions: [...granted],
    has: (permission) => granted.has(permission),
    hasAny: (list) => list.some((permission) => granted.has(permission)),
    hasAll: (list) => list.every((permission) => granted.has(permission)),
  };
}

/** A checker that grants nothing — used before the profile has loaded. */
export const NO_PERMISSIONS: PermissionChecker = createPermissionChecker(null, []);
