import { useId, type InputHTMLAttributes, type ReactNode } from 'react';

export interface TextFieldProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'id'> {
  label: string;
  hint?: string;
  error?: string | null;
  required?: boolean;
  addon?: ReactNode;
}

export function TextField({
  label,
  hint,
  error,
  required = false,
  addon,
  className = '',
  ...rest
}: TextFieldProps): React.JSX.Element {
  const id = useId();
  const describedBy = error ? `${id}-error` : hint ? `${id}-hint` : undefined;

  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className="block text-sm font-medium text-ink-700">
        {label}
        {required ? <span className="ml-0.5 text-critical-600">*</span> : null}
      </label>

      <div className="relative">
        <input
          id={id}
          aria-invalid={error ? true : undefined}
          aria-describedby={describedBy}
          className={[
            'block w-full rounded-lg border-0 bg-white px-3 py-2 text-sm text-ink-900 shadow-sm',
            'ring-1 ring-inset placeholder:text-ink-400',
            error ? 'ring-critical-600' : 'ring-ink-300 focus:ring-2 focus:ring-brand-600',
            addon ? 'pr-10' : '',
            className,
          ].join(' ')}
          {...rest}
        />
        {addon ? (
          <div className="absolute inset-y-0 right-0 flex items-center pr-3 text-ink-400">{addon}</div>
        ) : null}
      </div>

      {error ? (
        <p id={`${id}-error`} className="text-sm text-critical-600">
          {error}
        </p>
      ) : hint ? (
        <p id={`${id}-hint`} className="text-xs text-ink-500">
          {hint}
        </p>
      ) : null}
    </div>
  );
}
