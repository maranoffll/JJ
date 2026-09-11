/**
 * Module registry.
 *
 * Each entry carries the permission that gates it and the delivery phase that
 * implements it. The shell renders an item only when the signed-in user holds
 * the permission, and shows the phase for modules that are not built yet — the
 * navigation therefore never links to a page that does not exist.
 *
 * The permission gate is presentation only; PostgreSQL enforces the real rules.
 */
import {
  BarChart3,
  Building2,
  ClipboardList,
  FileSpreadsheet,
  FileText,
  FolderKanban,
  HardDrive,
  LayoutDashboard,
  Receipt,
  ScrollText,
  Settings,
  Users,
  Wallet,
  type LucideIcon,
} from 'lucide-react';
import type { Permission } from '../lib/permissions';

export interface NavItem {
  id: string;
  label: string;
  path: string;
  icon: LucideIcon;
  /** Permission required to see the entry. `null` means "any signed-in user". */
  permission: Permission | null;
  /** Phase that implements the module; `null` when it is available now. */
  phase: number | null;
  description: string;
}

export interface NavSection {
  id: string;
  label: string;
  items: NavItem[];
}

export const NAVIGATION: NavSection[] = [
  {
    id: 'overview',
    label: 'Overview',
    items: [
      {
        id: 'overview',
        label: 'Overview',
        path: '/',
        icon: LayoutDashboard,
        permission: null,
        phase: null,
        description: 'Your session, role and available modules',
      },
    ],
  },
  {
    id: 'commercial',
    label: 'Commercial',
    items: [
      {
        id: 'clients',
        label: 'Clients & CRM',
        path: '/clients',
        icon: Users,
        permission: 'clients.view',
        phase: 5,
        description: 'Client master data, contacts and commercial terms',
      },
      {
        id: 'projects',
        label: 'Projects',
        path: '/projects',
        icon: FolderKanban,
        permission: 'projects.view',
        phase: 6,
        description: 'Production projects, schedules and delivery',
      },
      {
        id: 'quotations',
        label: 'Quotations',
        path: '/quotations',
        icon: ClipboardList,
        permission: 'quotations.view',
        phase: 7,
        description: 'Quotations with GST breakdown and conversion to invoices',
      },
      {
        id: 'invoices',
        label: 'Invoices & GST',
        path: '/invoices',
        icon: FileText,
        permission: 'invoices.view',
        phase: 8,
        description: 'Tax invoices, credit notes and cancellations',
      },
    ],
  },
  {
    id: 'finance',
    label: 'Finance',
    items: [
      {
        id: 'payments',
        label: 'Payments',
        path: '/payments',
        icon: Receipt,
        permission: 'payments.view',
        phase: 9,
        description: 'Receipts, reconciliation and voiding',
      },
      {
        id: 'expenses',
        label: 'Expenses',
        path: '/expenses',
        icon: Wallet,
        permission: 'expenses.view',
        phase: 10,
        description: 'Production costs and approvals',
      },
      {
        id: 'reports',
        label: 'Reports',
        path: '/reports',
        icon: BarChart3,
        permission: 'reports.view',
        phase: 12,
        description: 'Revenue, receivables, profitability and GST summaries',
      },
    ],
  },
  {
    id: 'operations',
    label: 'Operations',
    items: [
      {
        id: 'hdd',
        label: 'HDD & Media',
        path: '/hdd',
        icon: HardDrive,
        permission: 'hdd.view',
        phase: 11,
        description: 'Drive inventory, custody and overdue tracking',
      },
      {
        id: 'attachments',
        label: 'Documents',
        path: '/documents',
        icon: FileSpreadsheet,
        permission: 'attachments.upload',
        phase: 13,
        description: 'Quotation, invoice and receipt PDFs',
      },
    ],
  },
  {
    id: 'administration',
    label: 'Administration',
    items: [
      {
        id: 'audit',
        label: 'Audit trail',
        path: '/audit',
        icon: ScrollText,
        permission: 'audit.view',
        phase: 14,
        description: 'Append-only record of business operations',
      },
      {
        id: 'settings',
        label: 'Company settings',
        path: '/settings',
        icon: Settings,
        permission: 'settings.update',
        phase: 15,
        description: 'Legal details, GSTIN, banking and document defaults',
      },
      {
        id: 'users',
        label: 'Users & roles',
        path: '/users',
        icon: Building2,
        permission: 'users.manage',
        phase: 3,
        description: 'ERP accounts, roles and permissions',
      },
    ],
  },
];

export function flatNavigation(): NavItem[] {
  return NAVIGATION.flatMap((section) => section.items);
}

export function findNavItem(path: string): NavItem | undefined {
  return flatNavigation().find((item) => item.path === path);
}
