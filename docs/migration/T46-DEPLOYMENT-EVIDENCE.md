# T46 static frontend deployment evidence

Audited 2026-11-12 against source `20bb0ed`, using read-only GitHub, HTTPS,
DNS and Cloudflare Worker deployment queries. No dispatch, deployment, database
migration, Pack publication, Mobile release, rollback or cloud mutation was run.
Raw command outputs are in `/tmp/t46/deployment/` for this run.

| Check | Result | Evidence and limits |
| --- | --- | --- |
| Automatic release scope | PASS, source and live environment | `.github/workflows/studio-web-deploy.yml` triggers automatic pushes only on `main`, limited to `studio/**` and its workflow. Deploy requires verified artifact, exact repository, `refs/heads/main`, non-PR event and current-main SHA. Live `studio-production` branch policy contains only `main`; authenticated `gh api .../environments/studio-production/deployment-branch-policies` confirmed it. Explicit manual dispatch also exists; it is not an automatic push trigger. |
| Successful Studio push | PASS, prior production revision | [Run 42989752335](https://github.com/AbderrahmaneSAOUDI/BiGuess/actions/runs/42989752335), push `66051ccfaeded38b8ffab4b744ed551f19aff3bb`: verify and deploy succeeded. GitHub deployment `7705822586` succeeded at `2026-11-11T08:53:38Z`; live `/release.json` still names that SHA. |
| Failed build/test blocks deployment | PASS, fail-closed protection; current release freshness FAIL | [Latest Studio push 43105349840](https://github.com/AbderrahmaneSAOUDI/BiGuess/actions/runs/43105349840), `2f3016670817cee1b08685fe944022c50cbd60a8`, failed the dataset browser step waiting for `Conflict — review before queueing`; deploy was skipped. Live release remains the prior successful SHA. Current `main` Studio behavior is therefore not all deployed/verified in production. This was an existing failure, not an induced production probe. |
| Deliberate failing-test negative control | PASS, historical evidence re-queried | [Run 42416753486](https://github.com/AbderrahmaneSAOUDI/BiGuess/actions/runs/42416753486): quality gates failed and deploy skipped. No new intentionally broken push was created. |
| Non-main production restriction | PASS, source/live policy and historical run | [Run 42416796343](https://github.com/AbderrahmaneSAOUDI/BiGuess/actions/runs/42416796343): verification succeeded, deployment skipped. Current environment branch policy independently restricts production to `main`. |
| DNS and HTTPS | PASS | `getent ahosts studio.saoudi.online` resolves through `biguess-studio.pages.dev` to Cloudflare addresses. `curl --fail --silent --show-error --dump-header ... https://studio.saoudi.online/release.json` returned HTTP/2 200 with normal TLS verification; HSTS, CSP, `nosniff`, DENY framing and public metadata revalidation are present. |
| Static packaging | PASS | `python3 -m unittest discover -s studio/test -p 'test_*.py' -v`: 9 tests passed. |
| Production Chromium popup smoke | FAIL, strict existing browser check | `NODE_PATH=/tmp/biguess-t36-browser/node_modules STUDIO_ORIGIN=https://studio.saoudi.online STUDIO_AUTH_ENABLED=1 STUDIO_OFFLINE_SHELL=1 STUDIO_EXPECTED_FIREBASE_AUTH_DOMAIN=biguess-firebase.firebaseapp.com node studio/scripts/browser_smoke.cjs` exited 1. Desktop reached real `accounts.google.com`, cancellation and protected deep links, then line113 rejected two `Cross-Origin-Opener-Policy policy would block the window.closed call.` console messages. The script aborted before its narrow pass; this is not a clean cross-viewport popup result. No Google account was signed in. |
| Content Backend remains unchanged | PASS, read-only before/after query | `wrangler deployments list --config backend/content-api/wrangler.production.json --json` before/after lists were equal. Most recent listed deployment is `c876e479-6bd8-403d-8d09-53bebdd1c937`, version `4f9c63ae-6834-4835-af5f-1092eada9746`, `2026-11-11T08:45:30.257912Z`, before the successful frontend run. This checks deployment history, not database/R2 contents. |
| No automatic backend/migration/publication/Mobile release | PASS, all current workflows audited | Only production mutation command in the three workflow files is `wrangler pages deploy public --project-name=biguess-studio`. Content API workflow runs typecheck and `npm test`; its build is `wrangler deploy --env staging --dry-run`. Mobile CI performs checks only. No remote migration, publication operator, APK/Store or Shorebird release action exists. |
| Hosted backend checks | FAIL, existing CI environment dependency | [Run 43119955799](https://github.com/AbderrahmaneSAOUDI/BiGuess/actions/runs/43119955799), `6c6cef6599f200f3ef0b1327185cad395df350cd`: npm test failed because the sync-delta fixture invokes Python Pillow, but runner reports `ModuleNotFoundError: No module named 'PIL'`. The workflow lacks its installation; passing local tests alone cannot clear this hosted failure. |
| Production rollback | NOT RE-RUN; historical pass | `studio/DEPLOYMENT.md` records actual rollback from `ed0e02d8-f4aa-49f6-b13d-42b34fd92a7a` to `6958e587-fe33-4dd0-a908-2f5d3193e2fb`, then restore, with `/release.json`, routes and JS checked. Procedure selects a prior successful production deployment, verifies HTTPS/release SHA, and fixes/pauses new pushes before resuming. No current production rollback was performed during T46. |

The Cloudflare annotation `Automatic deployment on upload` in an old manual
Worker upload describes activation of that upload; it is not a GitHub push-to-
Worker deployment mechanism. The current backend production connection is real
(`studio/DEPLOYMENT.md` and `backend/content-api/README.md` record its separately
approved 2026-11-11 activation); historical T26A backend-disabled statements must
not be treated as current production configuration.

## Evidence fingerprints

SHA-256 of retained run-local outputs (fingerprints identify the evidence; `/tmp`
files are ephemeral and are not a replacement for the linked GitHub run history):

| File under `/tmp/t46/deployment/` | SHA-256 |
| --- | --- |
| `failed-run.log` | `3eafbcb48c195fb8af2f5e79b4e0a7ff7230b0099a338f50b91bc9ef5445c31c` |
| `backend-failed-run.log` | `c02bf44db2f4bb16d2443bb6fcbd942d4354283ef351a10d48f098917d3baeff` |
| `live-browser.log` | `6019f7bf8e052159433032c1b9114288480fbd61dd73cb9a0734c45fa5585e48` |
| `headers.txt` | `a76ca007503796dac528759133a0019bd3a8a908ec994854cbc49950c6090149` |
| `backend-deployments.json` | `8fc6bdefeb81150749fed67dd6bc35dadc355ec00c89f8ced1b36e97ca9b03c6` |

## Supplementary production viewport check

A separate read-only Playwright script (`/tmp/t46/deployment/live-check.cjs`) ran
against production with Chromium at **1440×900** and **360×900**, the latter with
mobile/touch emulation. In each context `/dashboard`, `/topics`, `/my-packs`,
`/cards`, `/profile` and `/login` returned 200 and displayed the protected
**Continue with Google** gate; a browser reload still displayed it. Both recorded
zero `/content/v1/` requests before authentication and zero page exceptions. The
360-pixel screenshot was inspected: the heading, explanatory text, Google action
and redirect link fit the viewport without horizontal clipping. This is a PASS
for the anonymous production gate and narrow layout, not authenticated content,
a physical mobile browser, or the failing strict Google-popup smoke above.

`live-check.json` SHA-256:
`6f4d82b5b23b78c9f1fbb008e9bb8ef14966258d027703ec985e3b522d918e63`.
The run retained `live-1440.png` and `live-360.png` beside that result.
