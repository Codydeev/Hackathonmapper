// Checks that the App Store Connect API key in ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 works for the
// signed iOS build: it signs a token with the key and asks Apple's API for the app, its bundle ID
// (whose team must be TEAM_ID) and the signing certificates that automatic signing manages.
// Needs Node 18 or later and no packages. Run by .github/workflows/apple-keys.yml and before every
// TestFlight upload in ios.yml.
import { createPrivateKey, sign } from 'node:crypto';

const API = 'https://api.appstoreconnect.apple.com/v1';
const { ASC_KEY_ID: keyId = '', ASC_ISSUER_ID: issuerId = '', ASC_KEY_P8: p8 = '' } = process.env;
const bundleId = process.env.BUNDLE_ID || 'com.hackathonmapper.MeshMapper';
const teamId = process.env.TEAM_ID || 'Q485H7YK66';

let failed = false;
const ok = (msg) => console.log(`ok    ${msg}`);
const warn = (msg) => console.log(`::warning::${msg}`);
const fail = (msg) => {
  failed = true;
  console.log(`::error::${msg}`);
};
const done = () => {
  if (failed) {
    console.log('\nThe key does not work for the signed build. Secrets: Settings → Secrets and variables → Actions.');
    process.exit(1);
  }
  console.log('\nThe key works for the signed build.');
  process.exit(0);
};

// 1. The secrets are there and look like what App Store Connect hands out.
for (const [name, value] of [['ASC_KEY_ID', keyId], ['ASC_ISSUER_ID', issuerId], ['ASC_KEY_P8', p8]]) {
  if (!value.trim()) fail(`Repository secret ${name} is missing`);
}
if (failed) done();
if (!/^[A-Z0-9]{10}$/.test(keyId.trim())) fail(`ASC_KEY_ID should be the 10-character key ID, e.g. 2X9R4HXF34 (got ${keyId.trim().length} characters)`);
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(issuerId.trim())) fail('ASC_ISSUER_ID should be the issuer UUID shown above the key list, not the key ID or team ID');

// 2. The .p8 text is laid out as xcodebuild's PEM reader (CryptoKit) needs it. It is stricter than
// Node, so name each problem without printing key material, then go on with a repaired copy to learn
// whether the key itself is good.
const pemProblems = [];
let pem = p8;
if (pem.charCodeAt(0) === 0xfeff) {
  pemProblems.push('starts with an invisible byte-order mark');
  pem = pem.slice(1);
}
if (/^\s*["'`]/.test(pem) || /["'`]\s*$/.test(pem)) {
  pemProblems.push('is wrapped in quotes');
  pem = pem.trim().replace(/^["'`]+|["'`]+$/g, '');
}
if (pem.includes('\\n')) {
  pemProblems.push('has literal "\\n" text instead of line breaks');
  pem = pem.replace(/\\n/g, '\n');
}
if (pem.includes('\r')) {
  pemProblems.push('has Windows (CRLF) line endings');
  pem = pem.replace(/\r/g, '');
}
if (!pem.includes('-----BEGIN')) {
  const decoded = Buffer.from(pem.replace(/\s/g, ''), 'base64').toString('latin1');
  if (decoded.includes('-----BEGIN')) {
    pemProblems.push('is the .p8 file base64-encoded a second time, not the file text');
    pem = decoded;
  } else {
    pemProblems.push('has no "-----BEGIN PRIVATE KEY-----" line (only the middle of the file was pasted?)');
    pem = `-----BEGIN PRIVATE KEY-----\n${pem.replace(/\s/g, '').replace(/.{1,64}/g, '$&\n')}-----END PRIVATE KEY-----\n`;
  }
} else {
  const lines = pem.trim().split('\n');
  if (!/^-----BEGIN (EC )?PRIVATE KEY-----$/.test(lines[0].trim())) pemProblems.push(`has text before the "-----BEGIN PRIVATE KEY-----" line (${lines[0].trim().length} characters)`);
  if (!/^-----END (EC )?PRIVATE KEY-----$/.test(lines.at(-1).trim())) pemProblems.push('does not end with "-----END PRIVATE KEY-----"');
  if (lines.length < 3) pemProblems.push('is all on one line (the line breaks were lost when pasting)');
  if (lines.some((l) => l !== l.trim())) pemProblems.push('has spaces at the start or end of lines');
  if (pem.trim().split('-----BEGIN').length > 2) pemProblems.push('holds more than one key');
  if (lines.length < 3 || lines.some((l) => l !== l.trim())) {
    const body = pem.replace(/-----(BEGIN|END) (EC )?PRIVATE KEY-----/g, '').replace(/\s/g, '');
    pem = `-----BEGIN PRIVATE KEY-----\n${body.replace(/.{1,64}/g, '$&\n')}-----END PRIVATE KEY-----\n`;
  }
}
if (pemProblems.length) {
  fail(`ASC_KEY_P8 ${pemProblems.join('; ')}. xcodebuild rejects it ("invalidPEMDocument"). Open AuthKey_${keyId.trim()}.p8 in a text editor and paste its whole text, BEGIN and END lines included, as the secret`);
} else {
  ok(`ASC_KEY_P8 is laid out as a PEM file (${pem.trim().split('\n').length} lines)`);
}

let key;
try {
  key = createPrivateKey(pem);
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
    fail(`ASC_KEY_P8 is a ${key.asymmetricKeyType} key, not the P-256 key App Store Connect issues`);
  } else {
    ok(`ASC_KEY_P8 is a P-256 private key${pemProblems.length ? ' once its layout is repaired' : ''}`);
  }
} catch (err) {
  fail(`ASC_KEY_P8 is not a readable private key even after repairing its layout (${err.message}): it is not the .p8 file from App Store Connect`);
}
if (!key || key.asymmetricKeyType !== 'ec') done();

// 3. A token signed with the key is accepted by Apple.
const b64url = (data) => Buffer.from(data).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const unsigned = `${b64url(JSON.stringify({ alg: 'ES256', kid: keyId.trim(), typ: 'JWT' }))}.${b64url(
  JSON.stringify({ iss: issuerId.trim(), iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }),
)}`;
const token = `${unsigned}.${b64url(sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' }))}`;

async function get(path) {
  const res = await fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${token}` } });
  const body = await res.json().catch(() => ({}));
  const detail = body.errors?.map((e) => e.detail || e.title).join('; ') || res.statusText;
  return { status: res.status, body, detail };
}

const apps = await get(`/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&fields[apps]=name,bundleId`);
if (apps.status === 401) {
  fail(`Apple rejected the key (401: ${apps.detail}). The key ID, issuer ID and .p8 do not belong together, or the key was revoked`);
  done();
}
if (apps.status !== 200) {
  fail(`GET /apps failed (${apps.status}: ${apps.detail})`);
  done();
}
ok(`Apple accepts the key (key ID ${keyId.trim()})`);
const app = apps.body.data?.find((a) => a.attributes.bundleId === bundleId);
if (app) ok(`App record "${app.attributes.name}" exists for ${bundleId}`);
else fail(`This key's team has no App Store Connect app for ${bundleId}, so a TestFlight upload has nowhere to go`);

// 4. The bundle ID is on the team the project signs with. Needs the Admin, App Manager or Developer role.
const ids = await get(`/bundleIds?filter[identifier]=${encodeURIComponent(bundleId)}&fields[bundleIds]=identifier,seedId`);
if (ids.status === 403) {
  fail(`The key may not read bundle IDs (403: ${ids.detail}). Give it the Admin role`);
} else if (ids.status !== 200) {
  fail(`GET /bundleIds failed (${ids.status}: ${ids.detail})`);
} else {
  const match = ids.body.data?.find((b) => b.attributes.identifier === bundleId);
  if (!match) warn(`Bundle ID ${bundleId} is not registered yet; Xcode registers it on the first signed build`);
  else if (match.attributes.seedId !== teamId) fail(`Bundle ID ${bundleId} belongs to team ${match.attributes.seedId}, but the project signs with ${teamId}: the key is from the wrong team`);
  else ok(`Bundle ID ${bundleId} is on team ${teamId}`);
}

// 5. Automatic signing (-allowProvisioningUpdates) can see and create the distribution certificate.
const certs = await get('/certificates?limit=200&fields[certificates]=certificateType,expirationDate');
if (certs.status === 403) {
  fail(`The key may not manage certificates (403: ${certs.detail}). Automatic signing needs a key with the Admin role`);
} else if (certs.status !== 200) {
  fail(`GET /certificates failed (${certs.status}: ${certs.detail})`);
} else {
  const dist = (certs.body.data ?? []).filter((c) => ['DISTRIBUTION', 'IOS_DISTRIBUTION'].includes(c.attributes.certificateType));
  const valid = dist.filter((c) => new Date(c.attributes.expirationDate) > new Date());
  ok(`The key can manage certificates (${valid.length} valid distribution certificate(s); Xcode creates one if none fits)`);
  for (const c of valid) {
    const days = Math.floor((new Date(c.attributes.expirationDate) - Date.now()) / 86_400_000);
    if (days < 30) warn(`A distribution certificate expires in ${days} days (${c.attributes.expirationDate.slice(0, 10)})`);
  }
}

done();
