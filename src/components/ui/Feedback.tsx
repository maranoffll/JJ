import type { ReactNode } from 'react';
import { AlertTriangle, Inbox, Info, Loader2, RefreshCw, ShieldAlert } from 'lucide-react';
import { Button } from './Button';

/* -------------------------------------------------------------------------- */
/* Spinner + loading block                                                     */
/* -------------------------------------------------------------------------- */

export function Spinner({ className = 'size-5' }: { className?: string }): React.JSX.Element {
  return <Loader2 aria-hidden className={`animate-spin text-brand-600 ${className}`} />;
}

export function LoadingState({ label = 'Loading…' }: { label?: string }): React.JSX.Element {
  return (
    <div role="status" aria-live="polite" className="flex items-center justify-center gap-3 py-12 text-ink-500">
      <Spinner />
      <span className="text-sm">{label}</span>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Alerts                                                                      */
/* -------------------------------------------------------------------------- */

type Tone = 'info' | 'warning' | 'error' | 'success';

const TONE_CLASSES: Record<Tone, string> = {
  info: 'bg-brand-50 text-brand-900 ring-brand-200',
  warning: 'bg-caution-50 text-caution-700 ring-caution-600/20',
  error: 'bg-critical-50 text-critical-700 ring-critical-600/20',
  success: 'bg-positive-50 text-positive-700 ring-positive-600/20',
};

const TONE_ICONS: Record<Tone, ReactNode> = {
  info: <Info aria-hidden className="size-5 shrink-0" />,
  warning: <AlertTriangle aria-hidden className="size-5 shrink-0" />,
  error: <ShieldAlert aria-hidden className="size-5 shrink-0" />,
  success: <Info aria-hidden className="size-5 shrink-0" />,
};

export interface AlertProps {
  tone?: Tone;
  title: string;
  children?: ReactNode;
  actions?: ReactNode;
}

export function Alert({ tone = 'info', title, children, actions }: AlertProps): React.JSX.Element {
  return (
    <div role={tone === 'error' ? 'alert' : 'status'} className={`rounded-xl p-4 ring-1 ring-inset ${TONE_CLASSES[tone]}`}>
      <div className="flex gap-3">
        {TONE_ICONS[tone]}
        <div className="min-w-0 flex-1 space-y-1">
          <p className="text-sm font-semibold">{title}</p>
          {children ? <div className="text-sm opacity-90">{children}</div> : null}
          {actions ? <div className="pt-2">{actions}</div> : null}
        </div>
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Empty / error states                                                        */
/* -------------------------------------------------------------------------- */

export interface EmptyStateProps {
  title: string;
  description?: string;
  icon?: ReactNode;
  action?: ReactNode;
}

export function EmptyState({ title, description, icon, action }: EmptyStateProps): React.JSX.Element {
  return (
    <div className="flex flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-ink-300 bg-white/60 px-6 py-12 text-center">
      <div className="text-ink-400">{icon ?? <Inbox aria-hidden className="size-8" />}</div>
      <div>
        <p className="text-sm font-semibold text-ink-800">{title}</p>
        {description ? <p className="mt-1 max-w-md text-sm text-ink-500">{description}</p> : null}
      </div>
      {action}
    </div>
  );
}

export interface ErrorStateProps {
  title?: string;
  message: string;
  hint?: string | null;
  onRetry?: () => void;
}

export function ErrorState({
  title = 'Something went wrong',
  message,
  hint,
  onRetry,
}: ErrorStateProps): React.JSX.Element {
  return (
    <div role="alert" className="rounded-xl bg-critical-50 p-5 ring-1 ring-inset ring-critical-600/20">
      <div className="flex gap-3">
        <ShieldAlert aria-hidden className="size-5 shrink-0 text-critical-600" />
        <div className="space-y-2">
          <p className="text-sm font-semibold text-critical-700">{title}</p>
          <p className="text-sm text-critical-700/90">{message}</p>
          {hint ? <p className="text-xs text-critical-700/80">{hint}</p> : null}
          {onRetry ? (
            <Button
              variant="secondary"
              size="sm"
              onClick={onRetry}
              icon={<RefreshCw aria-hidden className="size-3.5" />}
            >
              Try again
            </Button>
          ) : null}
        </div>
      </div>
    </div>
  );
}
