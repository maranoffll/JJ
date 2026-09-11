import type { ReactNode } from 'react';

export interface CardProps {
  title?: string;
  description?: string;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
  padded?: boolean;
}

export function Card({
  title,
  description,
  actions,
  children,
  className = '',
  padded = true,
}: CardProps): React.JSX.Element {
  return (
    <section className={`rounded-xl bg-white shadow-sm ring-1 ring-ink-200 ${className}`}>
      {title || actions ? (
        <header className="flex flex-wrap items-start justify-between gap-3 border-b border-ink-200 px-5 py-4">
          <div>
            {title ? <h2 className="text-sm font-semibold text-ink-900">{title}</h2> : null}
            {description ? <p className="mt-0.5 text-sm text-ink-500">{description}</p> : null}
          </div>
          {actions}
        </header>
      ) : null}
      <div className={padded ? 'px-5 py-4' : ''}>{children}</div>
    </section>
  );
}

export interface PageHeaderProps {
  title: string;
  description?: string;
  actions?: ReactNode;
  breadcrumb?: ReactNode;
}

export function PageHeader({ title, description, actions, breadcrumb }: PageHeaderProps): React.JSX.Element {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div className="min-w-0">
        {breadcrumb ? <div className="mb-1 text-xs text-ink-500">{breadcrumb}</div> : null}
        <h1 className="truncate text-xl font-semibold text-ink-900">{title}</h1>
        {description ? <p className="mt-1 max-w-3xl text-sm text-ink-500">{description}</p> : null}
      </div>
      {actions ? <div className="flex shrink-0 items-center gap-2">{actions}</div> : null}
    </div>
  );
}

export function Badge({
  children,
  tone = 'neutral',
}: {
  children: ReactNode;
  tone?: 'neutral' | 'brand' | 'positive' | 'caution' | 'critical';
}): React.JSX.Element {
  const tones: Record<string, string> = {
    neutral: 'bg-ink-100 text-ink-700 ring-ink-200',
    brand: 'bg-brand-50 text-brand-700 ring-brand-200',
    positive: 'bg-positive-50 text-positive-700 ring-positive-600/20',
    caution: 'bg-caution-50 text-caution-700 ring-caution-600/20',
    critical: 'bg-critical-50 text-critical-700 ring-critical-600/20',
  };

  return (
    <span
      className={`inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium ring-1 ring-inset ${tones[tone]}`}
    >
      {children}
    </span>
  );
}
