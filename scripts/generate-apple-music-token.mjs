#!/usr/bin/env node
// Generates an Apple Music API developer token (ES256 JWT) from a MusicKit key.
// No dependencies — uses Node's built-in crypto (Node 16+).
//
// One-time setup in your Apple Developer account (developer.apple.com/account):
//   1. Certificates, Identifiers & Profiles → Identifiers → add a
//      Media ID (e.g. media.com.songsmash.app).
//   2. Keys → add a key with "Media Services (MusicKit)" enabled,
//      then download the AuthKey_XXXXXXXXXX.p8 file (downloadable only once).
//   3. Note the Key ID (10 chars, in the key name) and your Team ID
//      (top right of the membership page).
//
// Usage:
//   node scripts/generate-apple-music-token.mjs \
//     --key ~/Downloads/AuthKey_ABC123DEFG.p8 \
//     --key-id ABC123DEFG \
//     --team-id XYZ987WXYZ \
//     [--days 180]
//
// Put the output in .env as APPLE_MUSIC_DEV_TOKEN=... (never commit the .p8).

import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';

const MAX_DAYS = 180; // Apple caps developer tokens at ~6 months

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const name = argv[i]?.replace(/^--/, '');
    args[name] = argv[i + 1];
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const { key, 'key-id': keyId, 'team-id': teamId } = args;
const days = Math.min(parseInt(args.days ?? `${MAX_DAYS}`, 10) || MAX_DAYS, MAX_DAYS);

if (!key || !keyId || !teamId) {
  console.error('Usage: node scripts/generate-apple-music-token.mjs --key <AuthKey.p8> --key-id <KEY_ID> --team-id <TEAM_ID> [--days 180]');
  process.exit(1);
}

const b64url = (input) =>
  Buffer.from(input).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const now = Math.floor(Date.now() / 1000);
const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
const payload = b64url(JSON.stringify({ iss: teamId, iat: now, exp: now + days * 86400 }));
const signingInput = `${header}.${payload}`;

const privateKey = createPrivateKey(readFileSync(key, 'utf8'));
const signature = sign('sha256', Buffer.from(signingInput), {
  key: privateKey,
  dsaEncoding: 'ieee-p1363', // JWT ES256 wants raw r||s, not DER
});

const token = `${signingInput}.${b64url(signature)}`;

console.log('\nApple Music developer token (valid ' + days + ' days):\n');
console.log(token);
console.log('\nAdd it to your .env file:\n');
console.log('APPLE_MUSIC_DEV_TOKEN=' + token + '\n');
