import { useContext } from 'react';
import { AuthContext, type AuthContextValue } from './auth-context';

/** Access the authentication context. Throws when used outside the provider. */
export function useAuth(): AuthContextValue {
  const context = useContext(AuthContext);

  if (!context) {
    throw new Error('useAuth must be used inside <AuthProvider>.');
  }

  return context;
}
