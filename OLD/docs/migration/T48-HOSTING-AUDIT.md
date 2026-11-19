# T48 hosting and frontend delivery audit

Read-only audit on 2026-11-12, source `6c8115e` (T46). No hosting changes,
workflow dispatch, release, secret rotation, rollback or backend mutation was
performed. No local server or Flutter job was started. Sanitized run evidence is
under `/tmp/t48/hosting/`; T46 results are reused only where the workflow and
production source revision still match.

## Current production state

| Control | Evidence | Result / limit |
| --- | --- | --- |
| Established Pages project | Read-only `wrangler pages project list --json` and Cloudflare project GET: `biguess-studio`, Direct Upload (`Git Provider: No`), production branch `main`, domains `biguess-studio.pages.dev` and `studio.saoudi.online`. | Confirmed; no new project or provider configured. |
| Custom domain and TLS | Cloudflare custom-domain GET reports domain, verification and validation `active`. `getent ahosts` resolves the Pages alias; normal certificate-verifying HTTPS curl returns 200. | PASS. |
| Current frontend revision | Live `/release.json` remains `66051ccfaeded38b8ffab4b744ed551f19aff3bb`; current production deployment `fe64e729-5b47-4743-a1b8-5efc9b3755c3`. | Live frontend is older than current source. Latest Studio push [43105349840](https://github.com/AbderrahmaneSAOUDI/BiGuess/actions/runs/43105349840) failed its dataset conflict assertion and skipped deployment. This audit does not repair that failure. |
| Cache correctness | Fresh GETs of `/`, `/release.json`: `public, max-age=0, must-revalidate`. Revision-namespaced bootstrap and `main.dart.js`: `public, max-age=31536000, immutable`. | PASS for sampled live resources. No stale unversioned JS caching introduced. |
| Browser headers | HSTS `max-age=31536000`; `nosniff`; framing denied; `Referrer-Policy: no-referrer`; camera/microphone/geolocation disabled. CSP scopes script/auth helpers to explicit Google hosts and inline hashes, fonts to self/data, frames to `biguess-firebase.firebaseapp.com`, images to self/data/blob, objects/base/framing restricted. | PASS for actual current production responses. Styles retain `unsafe-inline` and scripts require `wasm-unsafe-eval` for the existing Flutter/Firebase implementation; these are not described as a strict no-inline policy. |
| Real backend configuration | Public config whitelist validation confirms Firebase project `biguess-firebase`, auth domain `biguess-firebase.firebaseapp.com`, HTTPS API `https://biguess-content-production.biguess-api.workers.dev`. Actual CSP allows precisely that API origin. | Backend is configured and deployed; historical backend-disabled T26A statements are not current state. No private owner UID or server credential is a build define. |

## URL, preview and authentication boundaries

The public Pages alias and the immutable production deployment URL
`https://fe64e729.biguess-studio.pages.dev/release.json` both return 200 without
identity. Public accessibility of static login code is confirmed; secrecy of a
frontend URL is not an authorization control. The Pages list returned 13
**Production** deployments and no Preview entries in that response. That does not
prove preview deployments are disabled account-wide.

Live read-only preflight requests to `/studio/v1/batches` demonstrate the
server boundary: origin `https://fe64e729.biguess-studio.pages.dev` returns **403**,
`Cache-Control: no-store`, without an access-control allow-origin header; canonical
`https://studio.saoudi.online` returns **204** with that exact allowed origin.
An anonymous GET of `/studio/v1/session` from the canonical origin returns **401**,
Bearer challenge and no-store. CORS approval alone grants no Studio identity or
role. Source `wrangler.production.json` permits only the canonical Studio origin
and disables Worker preview URLs.

The Cloudflare Access application-list GET returned **403** under the local OAuth
connection. Consequently this audit **cannot confirm a configured Access preview
policy**, its administrators or any account-wide preview restrictions. It does
not claim that public Pages URLs are protected by Access. Live Firebase authorized-
domain policy and authenticated Collector/Owner operations were not re-exercised
here; the T46 live identity and revocation gaps remain open.

T46's production desktop/narrow Chromium protected-route and refresh checks still
apply to the same `66051ccfa` frontend. T46 also records the strict Google-popup
smoke failure on COOP console messages. Neither that failure nor the failed
current-source dataset browser check is waived by successful HTTP header checks.

## Secrets and CI privileges

- GitHub plugin fetched the remote workflow source. Its workflow-runs URL was
  rejected by the connector's endpoint allowlist; `gh` was used for workflow and
  unsupported environment/branch metadata reads. No message or mutation tool was
  used.
- Production public config passes the existing six-key whitelist in
  `studio/scripts/public_config.py`; private/server keys are rejected. The nine
  static packaging tests pass, including rejecting a `private_key` build field
  and precise auth/API CSP construction. Firebase Web API configuration is public
  client configuration, not a server authorization credential.
- Scans of current `studio/lib` and `studio/web` and sampled live `index.html`,
  `flutter_bootstrap.js` and `main.dart.js` found no private-key PEM,
  service-account marker, Cloudflare token binding, Studio allowlist binding,
  signing-private-key binding, AWS access-key pattern or GitHub PAT pattern.
  Only zero counts/file matches were retained; no credential value was printed.
  This targeted scan is not proof against every possible secret encoding or every
  historical artifact.
- Live `studio-production` environment metadata exposes exactly the secret names
  `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`; GitHub never returns their
  values. The token's scope **cannot be proven from encrypted secret metadata**.
  Documented intended policy is account-scoped **Pages Edit only**, excluding DNS,
  Workers, D1 and R2; actual issued-token policy/expiry/rotation requires the
  credential custodian's separate Cloudflare review. Local Wrangler OAuth was
  used only locally, never copied into CI or a build.
- Environment deployment branch policy is exactly `main`. Current environment
  lists only branch-policy protection, with administrator bypass enabled; it does
  **not** establish a required human deployment reviewer. Main branch disallows
  force pushes and deletion but currently has no required PR review/status-check
  policy in its returned protection payload; ordinary authorized direct pushes
  remain possible. Main-only deployment is not described as mandatory review.
- Workflow default permission is `contents: read`, checkout credentials are not
  persisted, PR verification cannot enter deploy. Deploy alone has
  `deployments: write`; its Cloudflare credentials are limited to the upload step.
  It requires successful verify, the exact repository/main ref, non-PR event and
  a fresh current-main SHA. Static artifacts are commit-versioned. Explicit
  manual dispatch exists, including an opt-in failure probe; neither was invoked.
- The three current workflows contain no automatic Content Backend deployment,
  remote D1 migration, Pack publication, APK/Play Store release or Shorebird
  release. Content build uses Wrangler `--dry-run`. T46's hosted backend Pillow
  dependency failure remains unresolved; no passing hosted backend gate is implied.

## Rollback and operational ownership

The existing procedure in `studio/DEPLOYMENT.md` selects a previous successful
**production** Pages deployment, verifies its release SHA, HTTPS, routes and assets,
then corrects/pauses later Studio pushes before resuming. T26A recorded an actual
rollback to `6958e587-fe33-4dd0-a908-2f5d3193e2fb` and restoration to
`ed0e02d8-f4aa-49f6-b13d-42b34fd92a7a`. Those are historical proof, not a new T48
rehearsal or current incident recovery. No rollback or domain change was executed.

Repository ownership is `AbderrahmaneSAOUDI/BiGuess`; production documentation
names the default Studio Owner account `abderrahmane.saoudi.26@gmail.com`. These
are existing recorded identities, not newly assigned operators or proof that a
particular person has accepted on-call duties. Required operational responsibilities
belong to the accountable project Owner / authorized credential custodians:
review/approve main changes, inspect failed releases, verify Pages token scope and
rotation, maintain Firebase domains and server allowlists, execute an approved
rollback, and keep backend publication/migration authority separate from static
frontend deployment. **No named backup operator, support rota or acceptance of
those duties was confirmed in this read-only audit.** A Studio Owner role alone
is not proof of DNS/GitHub/Cloudflare administrative access.

## Run evidence fingerprints

Paths below are under `/tmp/t48/hosting/`; they are ephemeral run evidence.

| File | SHA-256 |
| --- | --- |
| `release.json` | `1fda91bc728fd7a8cef9389ec8b30c2e436a6445b5851efd5f973b5cb5d76681` |
| `index-headers.txt` | `b7a6227c0db33c2b686364a901070f47c74df23d470eb11280001474d27d715c` |
| `main-headers.txt` | `bd458962c80c6148e6d0f528622c72acdc958f3e1ef7a60f9e6d3b12d8747494` |
| `pages-settings-summary.json` | `2f2ddb5c103a1ff371fe17c7d6a1071ba630e2c7eed0c167c61ee36e9ec53d94` |
| `custom-domains-summary.json` | `b44747d43f93bbc4fd10ed7a56a153aab11456e3654dc890e2c9377e94c6e4c0` |
| `environment.json` | `5bf4a85b3348382a5514637bd1b5d683ba34bd6338419a1c026ea4a2f52a6b01` |
| `branch-policy.json` | `e996f7e2bb66bf0f89806988e816fa4357654b7e607db72b5d0e7661fcdd7342` |
| `secret-metadata.json` | `69121e71fd48232b06ee0d2ac2be9c81f92e0adc4b2274ee90673b7094552b6b` |
| `main-protection.json` | `128ea685c323ea0875bc5d974756ce5eef03638d24816b1c88423a3f934c8493` |
| `public-config-summary.json` | `bf897a1cbb7e944c7f2c04fa7fbc9f472e9f1057fc7422eac3feccda9b34b776` |
| `artifact-secret-scan.json` | `2c5f10abfdffeba7f11a594d285526781221e3ef2a5e078d6cd201fc6ab756b8` |
| `preview-origin-preflight-headers.txt` | `f7c70ad2117a57d5e4617be0e0a920668bf0563a707dfba1d9885aab1a3e98d0` |
| `studio-origin-preflight-headers.txt` | `59521b3333c69a7301b7bae52de91605ab04cacb15b5876918947fc4873b1603` |
| `unauth-session-headers.txt` | `a0938cbc74d2610ca6883644cfbc5e651818106d20918f36aaa61d41c80fd279` |
| `packaging-tests.log` | `db8f115bc8025b22417107360ab92562d7df7ab2a33b6ea8b4ae7f25223b576e` |
| `runs.json` | `ab03afa21e3c32f18cac407ee2eab07903b0be63b5ed29960ad876b574d1f9c2` |
