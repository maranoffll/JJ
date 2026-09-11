# Phase 2 — Authentication & Application Shell (complete, verified)

**Scope delivered:** the React + TypeScript + Vite frontend scaffold, the Supabase
client (publishable-key-only), session restoration, sign-in / sign-out, ERP
identity resolution from `public.user_profiles`, permission mirroring from
`public.role_permissions`, protected routing, the application shell, and the
supporting UI primitives. No business module was started — clients, projects,
quotations, invoices, payments, expenses and HDD arrive in their own phases.

---

## 1. Toolchain (installed, pinned)

| Area | Package | Version |
| ---- | ------- | ------- |
| UI | react / react-dom | 19.1.0 |
| Routing | react-router-dom | 7.18.3 |
| Icons | lucide-react | 1.44.0 |
| Backend client | @supabase/supabase-js | 2.116.0 |
| Build | vite | 7.3.6 |
| Build | @vitejs/plugin-react | 5.2.0 |
| Styles | tailwindcss + @tailwindcss/vite | 4.3.3 |
| Types | typescript | 5.9.3 |
| Tests | vitest 3.2.7, jsdom 30, @testing-library/react 16.3.3 + dom + jest-dom | — |
| Lint | eslint 9.39.5, typescript-eslint 8.70.0, react-hooks 7.1.1, react-refresh 0.5.6 | — |

Stable, mutually compatible majors were chosen over the newest published ones
(TypeScript 5.9 rather than 7.x, Vitest 3 rather than 5.x, Vite 7 rather than 8.x,
ESLint 9 rather than 10.x) so the phase gate is reproducible. `npm audit --omit=dev`
reports **0 vulnerabilities**; the browser bundle contains no dependency with a
known advisory.

Tailwind v4 runs through the `@tailwindcss/vite` plugin with the design tokens
declared in `src/index.css` (`@theme`); there is no `tailwind.config.js` or PostCSS
chain to keep in sync.

---

## 2. Files added

| File | Responsibility |
| ---- | -------------- |
| `index.html`, `src/main.tsx` | Mount point and React root |
| `src/App.tsx`, `src/app/router.tsx` | Composition root and the route table |
| `src/app/navigation.ts` | Module registry: each entry carries its permission gate and delivery phase |
| `src/index.css` | Tailwind entry + design tokens (`ink`, `brand`, `positive`, `caution`, `critical`), tabular figures, print rules |
| `src/lib/env.ts` | Environment validation; `assertPublishableKey` refuses `service_role`, `sb_secret_…` and unrecognised credentials |
| `src/lib/supabase.ts` | Lazy, memoised client (`flowType: 'pkce'`, storage key `jj-erp-auth`) + test seam |
| `src/lib/permissions.ts` | The 47 permission codes, role labels, `createPermissionChecker` — presentation mirror only |
| `src/lib/errors.ts` | `AppError`, PostgREST code mapping, sign-in messages that never leak account existence |
| `src/features/auth/auth-service.ts` | `signInWithPassword`, `signOut`, `fetchProfile`, `fetchPermissions`, non-blocking `recordLogin` |
| `src/features/auth/auth-state.ts` | Pure reducer: `initializing / unauthenticated / authenticated / no_profile / inactive / error` |
| `src/features/auth/auth-context.ts` | Context object (separate module so the provider file exports components only) |
| `src/features/auth/AuthProvider.tsx` | Session restore, `onAuthStateChange`, identity resolution, one `record_login` per user |
| `src/features/auth/AuthGate.tsx` | `RequireAuth` (route guard) and `RequirePermission` (module guard) |
| `src/features/auth/LoginPage.tsx` | Sign-in screen |
| `src/features/auth/ConfigurationPage.tsx` | Fail-safe screen for an unconfigured build |
| `src/features/auth/AccountStatusPage.tsx` | Full-page status screen for blocked accounts |
| `src/features/auth/useAuth.ts` | Context hook |
| `src/pages/HomePage.tsx`, `src/pages/NotFoundPage.tsx` | Landing page (identity + permissions + roadmap) and 404 |
| `src/components/layout/AppShell.tsx`, `Sidebar.tsx` | Header, responsive drawer, permission-filtered navigation, footer |
| `src/components/ui/*` | `Button`, `TextField`, `Alert`, `EmptyState`, `ErrorState`, `Spinner`, `Card`, `PageHeader`, `Badge` |
| Config | `tsconfig*.json`, `vite.config.ts`, `vitest.setup.ts`, `eslint.config.js` |
| Scripts | `dev`, `build`, `preview`, `typecheck`, `lint`, `test`, `test:watch`, `verify:app`, `verify:db` (existing DB scripts unchanged) |

---

## 3. Security decisions worth recording

1. **No privileged credential can reach the browser.** `assertPublishableKey`
   rejects `service_role` JWTs, `sb_secret_…` keys and anything it cannot verify as
   publishable. An invalid configuration renders `ConfigurationPage` — the app
   fails closed instead of half-working.
2. **Roles are never inferred client-side.** The role, the profile and the
   permission list are read from `public.user_profiles` and `public.role_permissions`
   under RLS. `src/lib/permissions.ts` only decides what to *render*; every query is
   still authorised by PostgreSQL (`RequirePermission` even documents this).
3. **Account states are explicit.** A session with no profile, an inactive account
   and a profile-read failure each produce a distinct screen with the next step, and
   none of them renders the shell.
4. **Login auditing is non-blocking.** `record_login()` failure is logged, never
   fatal — a database hiccup cannot lock users out.
5. **Sign-in errors do not enumerate accounts.** "Incorrect email or password" is
   returned for unknown accounts and wrong passwords alike.

---

## 4. Verification executed

### Static analysis

```
npx tsc -b --pretty false     → 0 errors
npm run lint                  → 0 errors, 0 warnings (eslint . --max-warnings 0)
```

Lint runs `typescript-eslint`'s **type-checked** rule set, so the commented-out
escape hatches normally used to silence it are not present anywhere in `src/`.

### Unit / component tests — `npm test` → 53 tests in 6 files, 0 failures

| File | Tests | Covers |
| ---- | ----- | ------ |
| `src/lib/env.test.ts` | 14 | JWT decoding, publishable-key acceptance, rejection of `service_role` / `sb_secret_` / unrecognised keys, URL validation, reporting every problem at once |
| `src/lib/permissions.test.ts` | 15 | Role catalogue, duplicate-free permission set, dropping unknown codes, catalogue ordering, `has`/`hasAny`/`hasAll`, the no-permission checker |
| `src/features/auth/auth-state.test.ts` | 9 | Every reducer transition, permission mirroring, error retention, predicates |
| `src/features/auth/LoginPage.test.tsx` | 6 | Field validation before any network call, trimmed/lower-cased credentials, non-enumerating error message, unconfigured-build notice |
| `src/features/auth/AuthGate.test.tsx` | 7 | Anonymous redirect, missing profile, inactive account, profile-read failure, admitted user, module hidden without the permission, unconfigured build |
| `src/App.test.tsx` | 2 | Full composition (provider + router + shell) fails closed when unconfigured; anonymous deep link redirects to `/login` |

### Production build

```
npm run build → vite build
dist/index.html                0.64 kB │ gzip:   0.39 kB
dist/assets/index-*.css       25.67 kB │ gzip:   5.37 kB
dist/assets/index-*.js       549.83 kB │ gzip: 162.56 kB
✓ built in 4.00s   (1941 modules transformed)
```

### Dev-server smoke test

`npm run dev` was started and every entry point fetched over HTTP (`/`,
`/src/main.tsx`, `/src/App.tsx`, `/src/app/router.tsx`, `/src/features/auth/LoginPage.tsx`,
`/src/components/layout/AppShell.tsx`, `/src/index.css`) — all `200`, no transform or
resolution errors.

### Regression — the Phase 1 database suite was re-run unchanged

| Command | Result |
| ------- | ------ |
| `npm run db:test` | 248 / 248 assertions (schema 39, financial 92, RLS/RBAC 38, HDD 35, views 44) |
| `npm run db:concurrency` | 15 / 15 checks |
| `npm run db:verify` | 6 / 6 checks (RLS on all business tables, 58 policies, append-only audit) |
| `npm run secret:scan` | 76 files scanned — 0 findings |

Phase 2 added **no migration** and changed no SQL: the schema is exactly the Phase 1
schema. `src/features/auth/auth-service.ts` calls the Phase 1 `record_login()` RPC
and reads only `user_profiles` / `role_permissions`.

---

## 5. Remaining issues / caveats

1. **The sandbox cannot reach `supabase.co`**, so a live sign-in was not executed
   here. The auth flow is verified through the mocked Supabase boundary plus the
   real database for everything the database owns (`record_login`, RLS on
   `user_profiles` / `role_permissions`). The user must run one manual check after
   deploying: sign in with a real account and confirm the landing page shows the
   database-provided role and permissions.
2. **`npm run dev` in an unconfigured checkout shows `ConfigurationPage`** by
   design. Create `.env.local` from `.env.example` (project URL + **anon /
   publishable** key) to see the login screen.
3. **First user creation.** Public sign-up remains disabled; create the first
   account in Supabase → Authentication → Users. The database trigger promotes the
   very first account to `ADMIN`; later accounts start as `VIEWER`.
4. **Bundle size.** 549.81 kB raw / 162.56 kB gzip in a single chunk. Route-level
   code splitting is deliberate deferred work — the module pages that justify it do
   not exist yet; it belongs with the reporting/document phases.

---

## 6. Next

**Phase 3 — RBAC & permissions (UI surface):** the administration screen for
accounts and roles (`public.set_user_role`, `public.set_user_active`), permission
matrix display and the assigned-to-me view — building on the Phase 1 RPCs and the
permission mirror delivered here.
