/** Error normalisation so the UI can always show something actionable. */

export class AppError extends Error {
  readonly code: string | null;
  readonly hint: string | null;

  constructor(message: string, options: { code?: string | null; hint?: string | null; cause?: unknown } = {}) {
    super(message, { cause: options.cause });
    this.name = 'AppError';
    this.code = options.code ?? null;
    this.hint = options.hint ?? null;
  }
}

interface PostgrestLikeError {
  message?: unknown;
  code?: unknown;
  details?: unknown;
  hint?: unknown;
}

function isPostgrestLike(error: unknown): error is PostgrestLikeError {
  return typeof error === 'object' && error !== null && 'message' in error;
}

const FRIENDLY_MESSAGES: Record<string, string> = {
  '42P01': 'The database schema is not up to date. Apply the Phase 1 migrations.',
  '42501': 'You do not have permission to perform this action.',
  PGRST116: 'The requested record was found more than once or not at all.',
  '23505': 'That record already exists.',
  '23503': 'A referenced record is missing.',
};

/** Converts anything thrown into an AppError with a human-readable message. */
export function toAppError(error: unknown): AppError {
  if (error instanceof AppError) return error;

  if (isPostgrestLike(error)) {
    const code = typeof error.code === 'string' ? error.code : null;
    const rawMessage = typeof error.message === 'string' ? error.message : 'Unexpected database error.';
    const hint = typeof error.hint === 'string' ? error.hint : null;

    return new AppError(code && FRIENDLY_MESSAGES[code] ? FRIENDLY_MESSAGES[code] : rawMessage, {
      code,
      hint,
      cause: error,
    });
  }

  if (error instanceof TypeError) {
    // fetch() failures surface as TypeError in the browser.
    return new AppError('Could not reach the backend. Check your network connection and try again.', {
      code: 'NETWORK',
      cause: error,
    });
  }

  if (error instanceof Error) {
    return new AppError(error.message, { cause: error });
  }

  return new AppError('An unexpected error occurred.', { cause: error });
}

/** Message for a failed sign-in that never leaks whether the account exists. */
export function describeSignInError(error: unknown): string {
  const appError = toAppError(error);
  const code = appError.code;

  if (code === 'invalid_credentials') return 'Incorrect email or password.';
  if (code === 'email_not_confirmed') return 'This account has not been confirmed yet.';
  if (code === 'over_email_send_rate_limit' || code === 'over_request_rate_limit') {
    return 'Too many attempts. Please wait a moment and try again.';
  }
  if (code === 'NETWORK') return appError.message;
  if (code === 'user_banned') return 'This account has been disabled.';
  if (code === 'signup_disabled') return 'Sign-up is disabled. Ask an administrator to create your account.';

  return appError.message;
}
