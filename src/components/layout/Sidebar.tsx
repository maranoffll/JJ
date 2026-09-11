import { NavLink } from 'react-router-dom';
import { X } from 'lucide-react';
import { NAVIGATION, type NavItem } from '../../app/navigation';
import type { PermissionChecker } from '../../lib/permissions';

interface SidebarProps {
  checker: PermissionChecker;
  /** Closes the mobile drawer. */
  onNavigate?: () => void;
  onClose?: () => void;
}

function isVisible(item: NavItem, checker: PermissionChecker): boolean {
  if (item.permission === null) return true;
  return checker.has(item.permission);
}

export function Sidebar({ checker, onNavigate, onClose }: SidebarProps): React.JSX.Element {
  const sections = NAVIGATION.map((section) => ({
    ...section,
    items: section.items.filter((item) => isVisible(item, checker)),
  })).filter((section) => section.items.length > 0);

  return (
    <nav
      aria-label="Main navigation"
      className="flex h-full w-72 shrink-0 flex-col bg-ink-900 text-ink-200"
    >
      <div className="flex items-center justify-between px-5 py-4">
        <div className="flex items-center gap-2.5">
          <span
            aria-hidden
            className="grid size-9 place-items-center rounded-lg bg-brand-600 text-sm font-bold text-white"
          >
            JJ
          </span>
          <span className="leading-tight">
            <span className="block text-sm font-semibold text-white">JJ Media</span>
            <span className="block text-xs text-ink-400">Production ERP</span>
          </span>
        </div>

        {onClose ? (
          <button
            type="button"
            onClick={onClose}
            aria-label="Close navigation"
            className="rounded-md p-1.5 text-ink-400 hover:bg-ink-800 hover:text-white lg:hidden"
          >
            <X aria-hidden className="size-5" />
          </button>
        ) : null}
      </div>

      <div className="flex-1 space-y-6 overflow-y-auto px-3 pb-6">
        {sections.map((section) => (
          <div key={section.id}>
            <p className="px-3 pb-1.5 text-[0.6875rem] font-semibold uppercase tracking-wider text-ink-500">
              {section.label}
            </p>
            <ul className="space-y-0.5">
              {section.items.map((item) => {
                const Icon = item.icon;
                const pending = item.phase !== null;

                return (
                  <li key={item.id}>
                    {pending ? (
                      <div
                        aria-disabled="true"
                        className="flex items-center gap-3 rounded-lg px-3 py-2 text-sm text-ink-500"
                        title={`Arrives in Phase ${item.phase}: ${item.description}`}
                      >
                        <Icon aria-hidden className="size-4 shrink-0" />
                        <span className="flex-1 truncate">{item.label}</span>
                        <span className="rounded bg-ink-800 px-1.5 py-0.5 text-[0.625rem] font-medium text-ink-400">
                          P{item.phase}
                        </span>
                      </div>
                    ) : (
                      <NavLink
                        to={item.path}
                        end={item.path === '/'}
                        onClick={onNavigate}
                        className={({ isActive }) =>
                          [
                            'flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors',
                            isActive
                              ? 'bg-brand-600 font-medium text-white'
                              : 'text-ink-300 hover:bg-ink-800 hover:text-white',
                          ].join(' ')
                        }
                      >
                        <Icon aria-hidden className="size-4 shrink-0" />
                        <span className="truncate">{item.label}</span>
                      </NavLink>
                    )}
                  </li>
                );
              })}
            </ul>
          </div>
        ))}
      </div>

      <div className="border-t border-ink-800 px-5 py-3 text-[0.6875rem] text-ink-500">
        Modules marked <span className="font-semibold text-ink-400">P#</span> are delivered in a later
        phase.
      </div>
    </nav>
  );
}
