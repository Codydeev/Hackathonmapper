# Uploading to TestFlight from GitHub (no Mac)

As of 25 October 2026. `.github/workflows/ios.yml` builds a signed Release on GitHub's macOS runners and
uploads it to TestFlight when someone presses **Run workflow** on `main`. This page is the one-time
setup and what to do when an upload fails.

## Where uploads run

The upload needs three repository secrets, and only a repository **admin** can add them. The team's
repository `Codydeev/Hackathonmapper` has none. The fork **`gymnasiet-larpan/Hackathonmapper`** has all
three (added 25 October), so uploads run there.

- **Sync the fork first:** on the fork's page, **Sync fork → Update branch**, or
  `gh repo sync gymnasiet-larpan/Hackathonmapper`. The upload builds the fork's `main`.
- **Upload from one repository only.** Build numbers are 100 + that repository's run number, and the
  two repositories count separately, so uploading from both can repeat a number.

## 1. Create the API key (App Store Connect Admin)

The app is "MeshMapperSTUHI" on STUHI's Apple team (`Q485H7YK66`).

1. https://appstoreconnect.apple.com → **Users and Access** → **Integrations** → **App Store Connect API**
   → **Team Keys** (not Individual Keys).
2. **Generate API Key** (or **+**): name `GitHub Actions MeshMapper`, access **Admin**. Only an Admin key
   may sign with Apple's cloud-managed distribution certificate, which the upload needs.
3. Note the **Key ID** (in the key's row) and the **Issuer ID** (above the list), and **Download** the
   key, `AuthKey_<KeyID>.p8`. Apple allows only one download.

No "App Store Connect API" under Integrations → Keys? Your role isn't Admin, or API access was never
turned on for the team: only the Account Holder can turn it on (**Request Access**, once).

## 2. Add the secrets (repository admin)

In the browser: the repository → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `ASC_KEY_ID` | the Key ID |
| `ASC_ISSUER_ID` | the Issuer ID |
| `ASC_KEY_P8` | the whole text of the `.p8`, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |

Or from PowerShell with the GitHub CLI (`gh auth login` first):

```powershell
$repo = "gymnasiet-larpan/Hackathonmapper"
gh secret set ASC_KEY_ID --repo $repo --body "<Key ID>"
gh secret set ASC_ISSUER_ID --repo $repo --body "<Issuer ID>"
Get-Content -Raw .\AuthKey_<Key ID>.p8 | gh secret set ASC_KEY_P8 --repo $repo
gh secret list --repo $repo
```

Then delete the `.p8` from Downloads, or keep it only in a password manager. Send it only privately,
never in the group chat. A leaked or unused key is revoked on the same App Store Connect page.

## 3. First upload

1. Sync the fork (above).
2. GitHub → the fork → **Actions** → **iOS app** → **Run workflow** → branch `main` → **Run workflow**.
3. It takes about 20 minutes: the gate (about 7), then the **Upload to TestFlight** job (check the
   secrets, archive, upload). The run's summary says `Build N uploaded to TestFlight` with the commit
   and the wire version.
4. App Store Connect → Apps → **MeshMapperSTUHI** → **TestFlight** → iOS builds: `0.1.0 (N)` shows as
   Processing, then ready to test after 5 to 15 minutes. The internal group gets it automatically.
   An external group (public link) gets it only once someone adds the build to that group, and Apple
   may review it first.
5. Record it: update the "Same build on every phone" table and the "newest TestFlight build" line in
   `HANDOVER.md` with N, the commit and the wire version. Every phone that should link needs the same
   build.

## 4. Troubleshooting

`gh run view <run id> --repo gymnasiet-larpan/Hackathonmapper --log-failed` prints the failing step.

| Fails at | The log says | Cause | Fix |
|---|---|---|---|
| Check the secrets | `Repository secret … is missing` | The secret isn't set in the repository that ran | Add it (step 2), or run from the fork |
| Upload to TestFlight | `Cloud signing permission error` and `No profiles for 'com.hackathonmapper.MeshMapper' were found` | The key works but may not use the cloud-managed distribution certificate: it isn't a **Team** key with **Admin** access | Generate a Team key with Admin access, replace `ASC_KEY_ID` and `ASC_KEY_P8` (the Issuer ID stays), run again. This stopped the fork's first upload (run 40187345980, 25 October) after the archive had succeeded |
| Archive | authentication failed, invalid key, or HTTP 401 | `ASC_KEY_P8` is incomplete (only the middle lines saved), the IDs don't belong together, or the key was revoked | Paste the whole `.p8` again; check the Key ID and Issuer ID on the same App Store Connect page |
| Archive or Upload | mentions an agreement | Apple updated the developer agreement and nobody accepted it yet | The Account Holder signs in to App Store Connect (or developer.apple.com) and accepts it |
| Upload to TestFlight | `Redundant Binary Upload`, or the build number must be higher | That build number was already uploaded | Run again (a new run gets a new number). Upload from one repository only; if the numbers are still too low, raise the `100 +` offset in `ios.yml` |
| Gate | a Swift or TypeScript check | The code doesn't build or a test fails | Fix it on a branch; the gate runs on every push |
| (job skipped) | Upload to TestFlight: skipped | Started by a push, or Run workflow on a branch other than `main` | Run workflow on `main` |
