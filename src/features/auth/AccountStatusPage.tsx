import { LogOut, RefreshCw } from 'lucide-react';
import { Alert } from '../../components/ui/Feedback';
import { Button } from '../../components/ui/Button';

export interface AccountStatusPageProps {
  tone: 'warning' | 'error';
  title: string;
  message: string;
  hint?: string;
  onSignOut?: () => Promise<void> | void;
  onRetry?: () => void;
}

/** Full-page status screen used when the session exists but access is blocked. */
export function AccountStatusPage({
  tone,
  title,
  message,
  hint,
  onSignOut,
  onRetry,
}: AccountStatusPageProps): React.JSX.Element {
  return (
    <div className="grid min-h-screen place-items-center bg-ink-100 px-4 py-12">
      <div className="w-full max-w-lg space-y-4">
        <div className="flex items-center gap-3">
          <span
            aria-hidden
            className="grid size-10 place-items-center rounded-xl bg-brand-600 text-sm font-bold text-white"
          >
            JJ
          </span>
          <span className="text-sm font-semibold text-ink-900">JJ Media ERP</span>
        </div>

        <Alert tone={tone} title={title}>
          <p>{message}</p>
          {hint ? <p className="mt-1 text-xs opacity-80">{hint}</p> : null}
        </Alert>

        <div className="flex flex-wrap gap-2">
          {onRetry ? (
            <Button variant="secondary" onClick={onRetry} icon={<RefreshCw aria-hidden className="size-4" />}>
              Try again
            </Button>
          ) : null}
          {onSignOut ? (
            <Button
              variant="ghost"
              icon={<LogOut aria-hidden className="size-4" />}
              onClick={() => {
                void onSignOut();
              }}
            >
              Sign out
            </Button>
          ) : null}
        </div>
      </div>
    </div>
  );
}
