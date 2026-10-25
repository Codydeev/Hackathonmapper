// Checks that the App Store Connect API key behind the TestFlight upload works, not just that the
// secrets are set: it signs in to Apple with ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 (the repository
// secrets .github/workflows/ios.yml uses) and asks for what the signed build needs. Run by
// .github/workflows/ios-keys.yml. Also works on Windows, to try a key before saving it as a secret:
//   $env:ASC_KEY_ID = 'ABC123DEFG'; $env:ASC_ISSUER_ID = '<issuer id>'
//   $env:ASC_KEY_P8 = Get-Content -Raw AuthKey_ABC123DEFG.p8
//   node .github/scripts/check-asc-key.mjs
// Never prints the key or the token. Exits 1 when a check fails.

import { createPrivateKey, sign } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';

const API = 'https://api.appstoreconnect.apple.com/v1';
const KEYS_PAGE = 'App Store Connect → Users and Access → Integrations → App Store Connect API';

// The app and team to check against, read from the XcodeGen spec so they can't drift apart.
const projectYml = readFileSync(new URL('../../ios/project.yml', import.meta.url), 'utf8');
const bundleId = projectYml.match(/PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)/)?.[1];
const teamId = projectYml.match(/DEVELOPMENT_TEAM:\s*(\S+)/)?.[1];

const results = [];

function report(status, check, detail) {
  results.push({ status, check, detail });
  console.log(`${{ pass: 'ok  ', warn: 'WARN', fail: 'FAIL' }[status]} ${check}: ${detail}`);
  if (process.env.GITHUB_ACTIONS && status !== 'pass') {
    console.log(`::${status === 'fail' ? 'error' : 'warning'} title=${check}::${detail}`);
  }
}

// xcodebuild reads the .p8 with CryptoKit, which is stricter than OpenSSL (and so than Node): a
// BEGIN line, base64 lines of exactly 64 characters (the last may be shorter) and a matching END
// line. A key pasted on one line, re-wrapped or indented fails there with "invalidPEMDocument" even
// though it is a valid key. Blank lines and Windows line endings are fine. Mirrors swift-asn1's
// PEMDocument(pemString:).
function pemProblem(p8) {
  const lines = p8.split(/\r\n|\r|\n/).filter((line) => line.length > 0);
  const begin = lines[0]?.match(/^-----BEGIN (.+)-----$/);
  const end = lines.at(-1)?.match(/^-----END (.+)-----$/);
  if (lines.length < 3 || !begin || !end || begin[1] !== end[1]) {
    return `it must start with a -----BEGIN PRIVATE KEY----- line and end with an -----END PRIVATE KEY----- line, each on a line of its own with nothing else on it, but it has ${lines.length} line(s)`;
  }
  const body = lines.slice(1, -1);
  const wrong = body.findIndex((line, index) => (index < body.length - 1 ? line.length !== 64 : line.length > 64));
  if (wrong >= 0) {
    return `the lines between BEGIN and END must be 64 characters each (only the last may be shorter), but they are ${body.map((line) => line.length).join(', ')}`;
  }
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(body.join(''))) return 'the lines between BEGIN and END hold characters that are not base64 (spaces or quotes?)';
  return null;
}

// Why a secret isn't a key at all, from its shape only: never echoes any of its characters.
function unreadableReason(p8) {
  const text = p8.trim();
  if (text.startsWith('LS0tLS1CRUdJTi')) return 'it is the .p8 file base64-encoded once more; save the text of the file itself';
  if (/^["']/.test(text)) return 'it is wrapped in quotes';
  if (text.includes('\\n')) return 'it has \\n written out where the line breaks should be';
  const lines = text.split(/\r?\n/);
  if (!text.includes('-----') && lines.every((line) => /^[A-Za-z0-9+/=]+$/.test(line))) {
    return `it holds only the ${lines.length} base64 line(s) from the middle of the file: the -----BEGIN PRIVATE KEY----- and -----END PRIVATE KEY----- lines are missing`;
  }
  if (!text.includes('-----BEGIN')) return `it has no -----BEGIN PRIVATE KEY----- line (${text.length} characters, ${lines.length} line(s))`;
  if (!text.includes('-----END')) return 'it has no -----END PRIVATE KEY----- line, so it was cut short';
  return pemProblem(p8) ?? 'its layout looks right, so the base64 inside is damaged or it is not a private key';
}

// The secrets are used exactly as ios.yml uses them, so a stray space or newline is a failure here
// rather than a confusing one in xcodebuild.
function readSecrets() {
  const missing = ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8'].filter((name) => !process.env[name]?.trim());
  if (missing.length > 0) {
    report('fail', 'Secrets', `${missing.join(', ')} not set (Settings → Secrets and variables → Actions; see the top of .github/workflows/ios.yml)`);
    return null;
  }
  const { ASC_KEY_ID: keyId, ASC_ISSUER_ID: issuerId, ASC_KEY_P8: p8 } = process.env;
  // The key ID stays out of the output: the repository is public and job summaries aren't masked.
  const saveAgain = `Save the secret again straight from the file, e.g. in PowerShell: Get-Content -Raw AuthKey_<key ID>.p8 | gh secret set ASC_KEY_P8 --repo ${process.env.GITHUB_REPOSITORY ?? '<owner>/<repo>'}`;
  let ok = true;
  if (!/^[A-Z0-9]{10}$/.test(keyId)) {
    report('fail', 'Secrets', `ASC_KEY_ID should be the 10-character key ID (like ABC123DEFG) with nothing around it; it is ${keyId.length} characters`);
    ok = false;
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(issuerId)) {
    report('fail', 'Secrets', `ASC_ISSUER_ID should be the issuer ID shown above the key list (a UUID) with nothing around it; it is ${issuerId.length} characters`);
    ok = false;
  }
  let key;
  try {
    key = createPrivateKey(p8);
  } catch {
    report('fail', 'Secrets', `ASC_KEY_P8 is not a readable private key: ${unreadableReason(p8)}. It should be the whole AuthKey_<key ID>.p8 file, BEGIN and END lines included, with its line breaks. ${saveAgain}`);
    return null;
  }
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
    report('fail', 'Secrets', 'ASC_KEY_P8 is a private key, but not an App Store Connect one (those are P-256 EC keys)');
    return null;
  }
  if (ok) report('pass', 'Secrets', 'all three set, and ASC_KEY_P8 is a P-256 private key');
  const problem = pemProblem(p8);
  if (problem) {
    report('fail', 'Key format', `xcodebuild can't read ASC_KEY_P8 ("invalidPEMDocument"): ${problem}. ${saveAgain}`);
  } else {
    report('pass', 'Key format', 'ASC_KEY_P8 is laid out the way xcodebuild reads it');
  }
  // Still signs in when only the layout is wrong: that tells whether saving the file again is enough.
  return ok ? { keyId, issuerId, key } : null;
}

// An ES256 token as App Store Connect wants it; Apple accepts at most 20 minutes, 10 is plenty here.
function token({ keyId, issuerId, key }) {
  const now = Math.floor(Date.now() / 1000);
  const part = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const unsigned = `${part({ alg: 'ES256', kid: keyId, typ: 'JWT' })}.${part({ iss: issuerId, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' })}`;
  const signature = sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' });
  return `${unsigned}.${signature.toString('base64url')}`;
}

async function get(jwt, path, query) {
  const response = await fetch(`${API}/${path}?${new URLSearchParams(query)}`, { headers: { Authorization: `Bearer ${jwt}` } });
  const body = await response.json().catch(() => ({}));
  const error = body.errors?.[0];
  const title = (error?.title ?? error?.code ?? '').replace(/\.$/, '');
  return { status: response.status, body, why: error ? `HTTP ${response.status}, ${title}${error.detail ? `: ${error.detail}` : ''}` : `HTTP ${response.status}` };
}

// Signing in: Apple only answers when key ID, issuer ID and .p8 belong together and the key is
// active. The answer also shows whether the key's team has the app the upload goes to.
async function checkSignIn(jwt) {
  const apps = await get(jwt, 'apps', { 'filter[bundleId]': bundleId, 'fields[apps]': 'name,bundleId' });
  if (apps.status === 401) {
    report('fail', 'Sign in', `Apple rejected the key (${apps.why}). The key ID, issuer ID and .p8 don't belong together, or the key was revoked: compare them with ${KEYS_PAGE}`);
    return false;
  }
  if (apps.status === 403) {
    report('fail', 'Sign in', `Apple accepted the key but refused the request (${apps.why}). If it mentions an agreement, the Account Holder has to accept it in App Store Connect`);
    return false;
  }
  if (apps.status !== 200) {
    report('fail', 'Sign in', `unexpected answer from App Store Connect (${apps.why}); try again later`);
    return false;
  }
  report('pass', 'Sign in', 'Apple accepted the key');
  const app = apps.body.data?.find((item) => item.attributes?.bundleId === bundleId);
  if (app) {
    report('pass', 'App record', `"${app.attributes.name}" (${bundleId}), where the upload goes`);
  } else {
    report('fail', 'App record', `the key sees no app with bundle ID ${bundleId}. Either the key belongs to another team than ${teamId}, or the app record is missing (App Store Connect → Apps → +)`);
  }
  return true;
}

// Signing: xcodebuild -allowProvisioningUpdates uses the key to fetch certificates and profiles,
// which needs access to Certificates, Identifiers & Profiles on the app's team.
async function checkSigning(jwt) {
  const ids = await get(jwt, 'bundleIds', { 'filter[identifier]': bundleId, 'fields[bundleIds]': 'identifier,seedId' });
  if (ids.status === 403) {
    report('fail', 'Signing access', `the key can't manage certificates and profiles (${ids.why}), so Xcode can't sign the build. Make a key with the Admin role`);
    return;
  }
  if (ids.status !== 200) {
    report('fail', 'Signing access', `unexpected answer from App Store Connect (${ids.why})`);
    return;
  }
  const id = ids.body.data?.find((item) => item.attributes?.identifier === bundleId);
  if (!id) {
    report('warn', 'Signing access', `the key can manage signing, but ${bundleId} isn't registered as an identifier; Xcode will try to register it during the build`);
  } else if (id.attributes.seedId !== teamId) {
    report('fail', 'Signing access', `${bundleId} is registered on team ${id.attributes.seedId}, but ios/project.yml signs with team ${teamId}`);
  } else {
    report('pass', 'Signing access', `the key can manage certificates and profiles, and ${bundleId} is registered on team ${teamId}`);
  }
}

// Role: Xcode's cloud signing (the distribution certificate Xcode makes and keeps at Apple) only
// works with an Admin key. Apple has no call that names a key's role; reading Users and Access is
// the closest test, as other roles can't open that page. So this warns rather than fails.
async function checkRole(jwt) {
  const users = await get(jwt, 'users', { limit: '1' });
  if (users.status === 200) {
    report('pass', 'Admin role', 'the key can read Users and Access, as Admin keys can');
  } else if (users.status === 403) {
    report('warn', 'Admin role', `the key can't read Users and Access (${users.why}), so it is probably not an Admin key. Xcode's cloud signing needs one: make a team key with the Admin role on ${KEYS_PAGE} and update the three secrets`);
  } else {
    report('warn', 'Admin role', `couldn't check (${users.why})`);
  }
}

function writeSummary() {
  if (!process.env.GITHUB_STEP_SUMMARY) return;
  const icon = { pass: '✅', warn: '⚠️', fail: '❌' };
  const failed = results.some((result) => result.status === 'fail');
  const lines = [
    `### App Store Connect API key: ${failed ? 'not working' : 'works'}`,
    `Checked against ${bundleId} on team ${teamId} (from ios/project.yml).`,
    '',
    '| | Check | Result |',
    '|---|---|---|',
    ...results.map((result) => `| ${icon[result.status]} | ${result.check} | ${result.detail.replaceAll('|', '\\|')} |`),
  ];
  appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${lines.join('\n')}\n`);
}

if (!bundleId || !teamId) {
  report('fail', 'Project', 'could not read PRODUCT_BUNDLE_IDENTIFIER and DEVELOPMENT_TEAM from ios/project.yml');
} else {
  const secrets = readSecrets();
  if (secrets) {
    try {
      const jwt = token(secrets);
      if (await checkSignIn(jwt)) {
        await checkSigning(jwt);
        await checkRole(jwt);
      }
    } catch (error) {
      report('fail', 'Sign in', `could not reach App Store Connect (${error.cause?.code ?? error.message})`);
    }
  }
}
writeSummary();
process.exitCode = results.some((result) => result.status === 'fail') ? 1 : 0;
