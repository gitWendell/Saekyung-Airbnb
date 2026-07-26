// Stamps the Supabase project details into the four pages.
//
// The keys live in four separate files because the pages are standalone — served straight
// off GitHub Pages with no build step. This script keeps them in step so a rotated key is
// one command instead of four hand edits, and it refuses to run rather than leaving two
// pages pointing at one project and two at another.
//
//   node scripts/set-config.mjs --url https://abc.supabase.co --key eyJ... --admin you@x.com
//
// Re-running it is safe: it replaces whatever is there now, placeholder or not.

import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const PAGES = ['index.html', 'booking-form.html', 'pay.html', 'admin.html'];

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
}

const url = arg('url');
const key = arg('key');
const admin = arg('admin');

if (!url || !key) {
  console.error(`Usage: node scripts/set-config.mjs --url <project-url> --key <anon-key> [--admin <email>]

  --url    https://YOUR-PROJECT-REF.supabase.co   (Dashboard -> Settings -> API -> Project URL)
  --key    the anon / public key from the same page
  --admin  the Supabase Auth account that unlocks admin.html (admin.html only)
`);
  process.exit(1);
}

if (!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/.test(url)) {
  console.error(`Refusing to write: "${url}" is not a Supabase project URL.`);
  process.exit(1);
}

// The service role key bypasses row level security completely. In a page served to the
// public it would hand every guest's name, email and mobile number to anyone who opened
// devtools, so it is worth refusing outright rather than trusting a paste.
// Supabase issues two generations of key. Newer projects hand out sb_publishable_… /
// sb_secret_… ; older ones hand out a signed JWT carrying a "role" claim. Both are accepted,
// and the dangerous half of each pair is refused by name.
if (/^sb_secret_/.test(key)) {
  console.error('Refusing to write: that is the secret key. These pages are public — use the publishable key.');
  process.exit(1);
}

if (!/^sb_publishable_/.test(key)) {
  let role;
  try {
    role = JSON.parse(Buffer.from(key.split('.')[1], 'base64').toString()).role;
  } catch {
    console.error(`Refusing to write: that key is neither a publishable key nor a readable Supabase JWT.
Expected either sb_publishable_… or a token starting eyJ…`);
    process.exit(1);
  }
  if (role !== 'anon') {
    console.error(`Refusing to write: that is the "${role}" key. These pages are public — use the anon key.`);
    process.exit(1);
  }
}

const clean = url.replace(/\/$/, '');
const edits = [
  [/const SUPABASE_URL = "[^"]*";/, `const SUPABASE_URL = "${clean}";`],
  [/const SUPABASE_ANON_KEY = "[^"]*";/, `const SUPABASE_ANON_KEY = "${key}";`],
  ...(admin ? [[/const ADMIN_EMAIL = "[^"]*";/, `const ADMIN_EMAIL = "${admin}";`]] : []),
];

let failed = false;
const staged = [];

for (const page of PAGES) {
  const path = join(root, page);
  let html = readFileSync(path, 'utf8');
  const applied = [];

  for (const [pattern, replacement] of edits) {
    // ADMIN_EMAIL only exists in admin.html; the other two must be in every page.
    const isAdminOnly = pattern.source.includes('ADMIN_EMAIL');
    if (!pattern.test(html)) {
      if (!isAdminOnly) {
        console.error(`  ${page}: no ${pattern.source.match(/SUPABASE_\w+|ADMIN_EMAIL/)[0]} line found`);
        failed = true;
      }
      continue;
    }
    html = html.replace(pattern, replacement);
    applied.push(pattern.source.match(/SUPABASE_\w+|ADMIN_EMAIL/)[0]);
  }

  staged.push([path, html, page, applied]);
}

// Nothing is written until every page checked out, so a bad run can't leave the site
// half-migrated and half-broken.
if (failed) {
  console.error('\nNo files were changed.');
  process.exit(1);
}

for (const [path, html, page, applied] of staged) {
  writeFileSync(path, html);
  console.log(`  ${page.padEnd(18)} ${applied.join(', ')}`);
}

console.log(`\nPointed 4 pages at ${clean}`);
if (!admin) console.log('admin.html still has its placeholder ADMIN_EMAIL — pass --admin to set it.');
