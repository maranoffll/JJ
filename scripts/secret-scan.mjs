#!/usr/bin/env node
/**
 * JJ Media ERP — repository secret scanner.
 *
 * Fails the build if credentials, private keys or privileged Supabase material
 * are present in the working tree. Safe-by-default: only publishable keys may
 * ever appear in frontend code.
 *
 * Usage: npm run secret:scan
 */
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const IGNORED_DIRS = new Set([
  'node_modules', '.git', 'dist', 'build', 'out', 'coverage', '.next', '.turbo',
  '.cache', '.venv', 'target', '.vite', '__pycache__',
]);

const IGNORED_FILES = new Set([
  'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'secret-scan.mjs',
]);

const SCAN_EXTENSIONS = new Set([
  '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.json', '.md', '.sql', '.yml',
  '.yaml', '.toml', '.env', '.example', '.txt', '.html', '.css', '', '.sh',
]);

const RULES = [
  {
    id: 'service-role-key',
    // A Supabase service_role JWT contains the "service_role" claim.
    test: (line) => /service_role/.test(line) && /eyJ[A-Za-z0-9_-]{20,}/.test(line),
    message: 'Supabase service_role key material detected',
  },
  {
    id: 'service-role-env',
    test: (line) => /SUPABASE_SERVICE_ROLE_KEY\s*[=:]\s*['"]?[A-Za-z0-9._-]{20,}/.test(line),
    message: 'SUPABASE_SERVICE_ROLE_KEY assigned a value',
  },
  {
    id: 'database-url-credentials',
    // Flags real credentials only: placeholders, local instances and the
    // documented template are not findings.
    test: (line) => {
      const match = line.match(/postgres(?:ql)?:\/\/([^\s:'"@/]+):([^\s:'"@/]+)@([^\s/]+)/);
      if (!match) return false;
      const [, , password, host] = match;
      if (/^<.*>$/.test(password)) return false;
      if (/password|example|placeholder|dummy|xxx|redacted|change[_-]?me|\$\{/i.test(password)) return false;
      if (/^(localhost|127\.0\.0\.1|::1)(:\d+)?$/.test(host)) return false;
      return true;
    },
    message: 'database URL containing an inline password',
  },
  {
    id: 'supabase-secret-key',
    test: (line) => /sb_secret_[A-Za-z0-9_-]{10,}/.test(line),
    message: 'Supabase secret key (sb_secret_…) detected',
  },
  {
    id: 'private-key-block',
    test: (line) => /-----BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/.test(line),
    message: 'private key block detected',
  },
  {
    id: 'aws-credential',
    test: (line) => /(AKIA|ASIA)[0-9A-Z]{16}/.test(line),
    message: 'AWS access key id detected',
  },
  {
    id: 'google-api-key',
    test: (line) => /AIza[0-9A-Za-z_-]{35}/.test(line),
    message: 'Google API key detected',
  },
  {
    id: 'slack-token',
    test: (line) => /xox[baprs]-[0-9A-Za-z-]{10,}/.test(line),
    message: 'Slack token detected',
  },
  {
    id: 'github-token',
    test: (line) => /(ghp|gho|ghs|ghr)_[A-Za-z0-9]{30,}/.test(line),
    message: 'GitHub token detected',
  },
  {
    id: 'jwt-hardcoded',
    // Any literal JWT that is not an obvious placeholder/example.
    test: (line) =>
      /eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/.test(line) &&
      !/example|placeholder|your-|dummy|xxxx|\.\.\.|redacted/i.test(line),
    message: 'hardcoded JWT detected',
  },
  {
    id: 'generic-secret-assignment',
    test: (line) =>
      /\b(api[_-]?secret|client[_-]?secret|secret[_-]?key|private[_-]?key|access[_-]?token|auth[_-]?token|password)\s*[=:]\s*['"][^'"\s]{16,}['"]/i.test(line) &&
      !/example|placeholder|your-|dummy|xxxx|redacted|change[_-]?me|test|local|postgres/i.test(line),
    message: 'hardcoded secret assignment',
  },
  {
    id: 'forbidden-env-file',
    test: () => false, // handled by the file-name check below
    message: '',
  },
];

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    if (IGNORED_DIRS.has(entry)) continue;
    const full = path.join(dir, entry);
    const stats = statSync(full);
    if (stats.isDirectory()) {
      walk(full, out);
    } else {
      out.push(full);
    }
  }
  return out;
}

const findings = [];
const files = existsSync(ROOT) ? walk(ROOT) : [];

for (const file of files) {
  const rel = path.relative(ROOT, file).split(path.sep).join('/');
  const base = path.basename(file);

  // Committed environment files are forbidden outright.
  if (/^\.env(\..+)?$/.test(base) && !base.endsWith('.example')) {
    findings.push({ file: rel, line: 0, rule: 'committed-env-file', message: 'environment file must not be committed' });
    continue;
  }

  if (IGNORED_FILES.has(base)) continue;

  const ext = path.extname(file).toLowerCase();
  if (!SCAN_EXTENSIONS.has(ext)) continue;

  let content;
  try {
    content = readFileSync(file, 'utf8');
  } catch {
    continue;
  }

  if (content.includes('\u0000')) continue; // binary

  const lines = content.split(/\r?\n/);
  lines.forEach((line, index) => {
    // Skip comment-only lines that document forbidden patterns inside the scanner.
    for (const rule of RULES) {
      if (rule.id === 'forbidden-env-file') continue;
      if (rule.test(line)) {
        findings.push({ file: rel, line: index + 1, rule: rule.id, message: rule.message, snippet: line.trim().slice(0, 120) });
      }
    }
  });
}

console.log(`Scanned ${files.length} files for credentials.\n`);

if (findings.length === 0) {
  console.log('\x1b[32m✓ No secrets, private keys or privileged credentials found.\x1b[0m');
  console.log('\x1b[2mReminder: the frontend may only ever contain the Supabase anon/publishable key.\x1b[0m');
  process.exit(0);
}

console.error('\x1b[31m✗ Potential secrets found:\x1b[0m');
for (const f of findings) {
  console.error(`  ${f.file}${f.line ? `:${f.line}` : ''}  [${f.rule}] ${f.message}`);
  if (f.snippet) console.error(`\x1b[2m      ${f.snippet}\x1b[0m`);
}
console.error(`\n${findings.length} finding(s). Remove the material before committing.`);
process.exit(1);
