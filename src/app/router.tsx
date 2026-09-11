import { createBrowserRouter, Navigate } from 'react-router-dom';
import { AppShell } from '../components/layout/AppShell';
import { RequireAuth } from '../features/auth/AuthGate';
import { LoginPage } from '../features/auth/LoginPage';
import { HomePage } from '../pages/HomePage';
import { NotFoundPage } from '../pages/NotFoundPage';

/**
 * Application routes.
 *
 * Everything inside <RequireAuth> needs a signed-in user with an active ERP
 * profile. Modules from later phases are not routed yet — the sidebar advertises
 * them as pending instead of linking to an empty page.
 */
export const router = createBrowserRouter([
  {
    path: '/login',
    element: <LoginPage />,
  },
  {
    element: <RequireAuth />,
    children: [
      {
        element: <AppShell />,
        children: [
          { index: true, element: <HomePage /> },
          { path: '404', element: <NotFoundPage /> },
          { path: '*', element: <NotFoundPage /> },
        ],
      },
    ],
  },
  {
    path: '*',
    element: <Navigate to="/" replace />,
  },
]);
