# BiGuess Studio

Independent Flutter Web application. The Android Mobile project stays at the
repository root. Studio supports Web Google/Firebase sign-in and Worker-derived Owner/Collector
sessions. Builds without public Firebase configuration retain the inert preview.
The deployed frontend has Firebase configuration but no Content API URL: signing
in cannot grant a role or expose private content until the separately gated
Worker integration is configured. No content dataset or server credentials are bundled.

## Local development

Use Flutter **3.47.9**, Dart **3.13.7** (the CI pin). From `studio/`:

```bash
flutter pub get
flutter run -d chrome
bash scripts/check.sh all
```

Individual gates: `bash scripts/check.sh format|analyze|test|build` (choose one).
Format fixes: `dart format lib test`. Release output: `studio/build/web`.
No Android platform, APK or installation package is created. The build bundles
CanvasKit and fallback fonts locally (`--no-web-resources-cdn`) and disables service workers.
After the static app resources load, all preview navigation works offline.
A first visit still needs the static files; offline installation is not promised.

## Brand and icons

The Studio logo and favicon are unchanged copies of `../assets/logos/biguess_logo.webp`.
The independent app registers the brand logo and nine local SVG icons; it does not
import Mobile assets at runtime. The UI uses neutral surfaces and the exact `BiGuessColors` palette in
`lib/app/studio_brand_colors.dart`: red `#EA4335`, blue `#4285F4`, green `#34A853`,
yellow `#F9AB00`, outline `#1A1919`. Blue is the primary accent; selected labels
stay dark for readability. Red, green and yellow have semantic theme roles. No decorative hero, generated illustration or promotional
copy is included.

The supplied SVGs are optimized in `../assets/icons/`. Studio bundles only the
nine it currently uses, with local copies under `studio/assets/icons/` and an
explicit asset list. The [icon map](assets/icons/README.md) lists current uses.
`flutter_svg` renders local assets. Firebase Core/Auth and `http` are the Web
identity and Worker-session adapters; no Mobile plugins are imported.

## Boundaries

- `lib/app/`: application composition, URL routing, responsive theme tokens.
- `lib/presentation/`: shell and reusable empty/loading/offline/error states.
  Loading and offline states are presentation components, not fake live status
  indicators; no network probes run. Startup HTML also reports loading/failure.
- `lib/auth/`: Firebase identity, short-lived Worker role checks and browser
  session lifecycle. Live Worker authorization and bearer tokens are never
  persisted by the dataset layer. `lib/data/` owns T28 account/role-isolated
  IndexedDB snapshots and local draft queues; publishing remains later work.
- Do not import root Mobile UI, providers, gameplay, native plugins or bundled
  character assets. No shared Dart models are needed for empty routes. When
  needed, stable wire contracts live under `../contracts/content/`; share only
  contracts that both apps actually use.
- `scripts/check_boundary.py` enforces the deliberately narrow initial import,
  dependency, platform and build-asset policy. It is not a general secret scanner;
  review future source/dependency changes before broadening this policy.

Navigation uses clean paths (`/dashboard`, `/topics`, `/my-packs`, `/cards`,
`/profile`, `/login`) with browser history and unknown-route fallback. A static
server must fall back to `index.html` for deep-link refresh. Flutter's development
server does this. Wide screens use a rail, narrow screens a labelled drawer;
Material controls support Tab/Enter, pointer and touch. Content scrolls at large
text sizes. Browser guards require a current Worker-authorized session. Every privileged
server request must independently verify Firebase identity, origin and role;
route guards alone never authorize access.

## Static deployment: T26A

The immediate target is **`https://studio.saoudi.online`**, using the
`biguess-studio` Cloudflare Pages Direct Upload project. The
`studio-web-deploy.yml` workflow validates pull requests and deploys only a
successful current `main` build through the `studio-production` environment.
See [deployment setup, status, evidence and rollback](DEPLOYMENT.md).
T26A is complete: DNS/TLS, encrypted CI credentials, live browser checks,
push-to-live, failure/branch guards and rollback/restore are verified. Only the `studio` DNS record is in scope; the apex domain and
other records are unchanged. Workers/D1/R2 remain local and undeployed.

## Verification

Widget tests cover all destinations, compact touch navigation, 200% text,
keyboard navigation, accessible status messages, URL parsing and route updates.
Enlarged text also exercises tablet/desktop navigation at the responsive boundary.
CI also runs `node scripts/browser_smoke.cjs` against the packaged release in
headless Chromium. Unconfigured builds verify inert navigation, history, offline
operation and zero external requests or account storage. Configured builds
verify protected deep links, the real Google popup and cancellation at desktop
and narrow touch sizes. Both modes reject runtime errors and service workers.
Auth controller/client tests also run in Chrome with injected identity and HTTP
adapters; they do not require real privileged accounts.
To run locally without adding browser tooling to the app dependencies:

```bash
npm install --prefix /tmp/biguess-studio-browser --no-save --package-lock=false playwright@1.65.0
/tmp/biguess-studio-browser/node_modules/.bin/playwright install chromium
NODE_PATH=/tmp/biguess-studio-browser/node_modules node scripts/browser_smoke.cjs
```

Set `CHROME_EXECUTABLE` to use an existing Chrome executable instead.
Root Mobile checks and the release browser results are recorded in
`VERIFICATION.md`. Studio CI/deployment runs only on Studio or its own workflow changes.
Root analysis excludes this separate package and continues checking Mobile.

## Firebase Web configuration (T27)

The user-selected Studio Firebase project is `biguess-firebase` (project number
`230843736734`), with Web app `1:230843736734:web:210d943207c2e8b5f1518f`.
Google sign-in is enabled. Authorized domains are `studio.saoudi.online`,
`localhost`, `127.0.0.1`, `biguess-firebase.firebaseapp.com` and
`biguess-firebase.web.app`. These settings were read back on 2026-11-09.
This supersedes the initially inferred Mobile-associated project; see the
correction evidence in [DEPLOYMENT.md](DEPLOYMENT.md).

CI optionally reads the repository variable `STUDIO_PUBLIC_CONFIG_JSON`. It
accepts only public client fields, validated before the Flutter build:

```json
{
  "STUDIO_FIREBASE_API_KEY": "public Firebase Web API key",
  "STUDIO_FIREBASE_APP_ID": "Firebase Web app ID",
  "STUDIO_FIREBASE_PROJECT_ID": "biguess-firebase",
  "STUDIO_FIREBASE_AUTH_DOMAIN": "biguess-firebase.firebaseapp.com",
  "STUDIO_FIREBASE_MESSAGING_SENDER_ID": "230843736734",
  "STUDIO_API_BASE_URL": ""
}
```

Public Firebase client configuration is expected in JavaScript bundles. Never
supply service-account keys, OAuth client secrets, Worker credentials or R2
credentials. Unknown JSON keys are rejected. The API URL intentionally remains
empty in the live frontend: no production Worker, D1 or private content has been
released. A future approved integration must set an HTTPS API base URL and match
its precise CORS origin allowlist before any privileged content request.

For a configured local build, save this public JSON outside source and use:

```bash
STUDIO_PUBLIC_CONFIG_FILE=/absolute/path/studio-public.json bash scripts/check.sh all
python3 scripts/prepare_deployment.py --commit "$(git rev-parse HEAD)" --public-config /absolute/path/studio-public.json --output build/pages-auth
```

Packaging receives the same public file and permits only Firebase's SDK loader,
Auth token endpoints and exact helper origin in CSP; the default unconfigured
build retains a same-origin policy. Prefer the supported popup flow on this
Cloudflare Pages site. A redirect flow on browsers blocking third-party storage
requires one of [Firebase's documented same-origin/helper solutions](https://firebase.google.com/docs/auth/web/redirect-best-practices);
adding an authorized domain alone does not solve browser storage restrictions.
See [Flutter federated authentication](https://firebase.google.com/docs/auth/flutter/federated-auth)
and [Google sign-in configuration](https://firebase.google.com/docs/auth/web/google-signin).

Google authentication alone never grants access. Session restoration, refresh,
focus/resume checks and denied/error transitions must obtain fresh server roles.
Logout and account switching discard the previous role immediately. T27 does not
implement cached private datasets or draft storage; T28 below adds those separately.

When Google authentication completes while the Content API is intentionally
disabled, Studio shows “Google sign-in completed” and explains that Studio access
is not enabled. This does not grant a role or expose the shell. A real Worker
connection failure or denied role remains a separate failure state.

## Account-isolated dataset and first sync (T28)

With an independently configured API, successful Worker authorization starts a
paginated `/studio/v1/sync/initial` scan. Only the scoped administrative dataset
is stored, never the anonymous catalog as an authoring dataset. All pages stage
in memory; the last page, resume cursor, last-sync timestamp and preserved local
drafts commit in one IndexedDB transaction. Interrupted scans retain the last
complete dataset. An expired cursor gets one bounded restart; other failures
require Retry/Refresh. Refresh verifies the session before the scan and checks
the same token's UID/role again before promotion. There is no content polling,
realtime subscription, upload or per-keystroke server write.

Production uses pinned `idb_shim` over native browser IndexedDB, with explicit
schema upgrades and no native filesystem/SQLite or silent in-memory fallback.
Namespaces include protocol/scope version, Firebase project, UID and role. An
account's current-role receipt gates every read/write. Immutable local revisions
provide compare-and-swap protection against stale tabs. Downgrading Owner to
Collector changes namespace; old role drafts remain stored but inaccessible to
the new role. Logout/switch/denial immediately clear rendered content, editors,
queries and open handles; late responses cannot reactivate them. Revocation
removes the offline receipt without deleting pending drafts. No tokens, email,
private image bytes, server credentials or authority-bearing claims are stored
in the dataset or static caches.

Topics, My Packs and Cards now browse that dataset. A minimal local name editor
demonstrates durable offline edits without implementing the later Topic/Pack/Card
administration tickets. **Save locally** creates a draft; **Queue commit** marks
an unsent local commit and sends nothing. Draft, Unsent commit, Conflict and Synced
labels are distinct. A changed or removed remote revision marks a retained draft
as Conflict. The API does not supply authoritative publication revisions, so the
UI labels publication as unknown rather than equating active content with a
published revision. Future publishing/sync work can populate the optional
published-revision field.

Offline reopening requires the same tab's restored Firebase identity, a complete
previously authorized snapshot, its current-role receipt, and a nonsecret
session-storage readiness marker. A new account/tab cannot authorize offline.
Readiness is cleared on known denial/logout and cannot be granted by stored
bearer data. Blocked marker reads/writes fail closed. The UI explicitly labels
offline access and local-only edits. Remote revocation cannot be discovered while
fully offline; reconnect/focus must verify the session before content reappears.
Storage quota, private-mode restrictions, browser eviction, cleared site data and
lost session identity can make offline data unavailable. Unsaved editor text
survives a failed save; success is shown only after the transaction commits.
Browser storage is not a backup or an encryption boundary against someone with
access to the same browser profile.

API-configured T26A packages opt into a static offline shell. Its generated worker
preloads only the exact public build allowlist; API, bearer, query, cross-origin,
private and `no-store` requests/responses never enter CacheStorage. The worker
does no runtime cache writes. API-empty live builds remain inert and install no
worker; packaging automatically unregisters an older Studio shell on rollback to
that mode. Offline shell installation itself needs one successful online visit
and enough browser storage. Firebase's SDK/session must also remain available.

See [T28 verification and reproducible browser checks](T28-VERIFICATION.md).

## Topic administration and classification (T29)

Topics now use a local working view over the synchronized records and durable
pending changes. Owner can search/filter Topics, create or rename one, hide an
active Topic, and prepare confirmed soft deletion or restoration. Restoration
returns the selected Topic to hidden state; it does not restore descendants or
publish anything. Synced records and relationships remain intact until a later
explicit server commit. Save locally and Queue Topic commit are separate actions;
this ticket adds no mutation uploads, per-keystroke writes or publishing.

Collectors receive only the permitted `id`, `name`, `state` and `revision`
classification projection. They have no Topic management controls, and direct
controller calls to change, queue or discard a Topic operation are also denied.
Topic author/audit/count/child metadata is not part of the picker or Collector
Topic list. Active and hidden Topics are eligible under the approved taxonomy
contract; deleted, purged, unsynced new Topics and pending restorations are not.

The reusable Topic picker is available from **My Packs → New Pack draft**, not
only from the Topics screen. This small entry point saves a Pack name and one
existing Topic ID locally, without assigning creator ownership or adding full
Pack administration. Unsynced Pack drafts can change that classification before
queueing; existing synced Packs cannot be moved between Topics. Topic deletion
is blocked when local Pack/Card changes depend on it, and the picker excludes
pending deletions. A refresh that removes a new Pack draft's parent marks it as
Conflict. These checks run again on queueing and in storage transactions guarded
against stale-tab writes.

Each pending change carries its operation (`create`, `update`, `hide`,
`softDelete` or `restore`) and the original revision. A Topic can have one final
operation at a time; incompatible edits require discarding/completing the first
change instead of silently losing it. Existing T28 name drafts read as `update`
when the new field is absent. Older app versions may refuse newer operation
metadata rather than reinterpret it; they do not delete those stored drafts.

See [T29 verification](T29-VERIFICATION.md). Pack lifecycle is covered by T30
below; Card authoring is covered by T31 and server mutation transport remains a later ticket. The
private Content Backend is not activated or deployed by this work.

## Contributor Pack administration (T30)

My Packs provides local name/ID search, lifecycle and pending/synced filters,
creation with one existing eligible Topic, explicit editing and hiding. Owner
sees all Packs and readonly creator attribution, including unassigned legacy
content. Collector membership comes from the authenticated Worker's scoped
snapshot; no creator UID input, ownership claim or transfer is offered. The
server assigns ownership from verified identity. A synchronized Pack's Topic is
fixed; a new unsynced creation can be reclassified through the reusable picker.

Each Pack has at most one pending operation. Saving changes persists locally;
Queue commit explicitly marks an unsent operation and makes no network mutation.
Conflicting revisions, ineligible parents, stale modal edits, incompatible
pending operations and dependent Card drafts block unsafe changes. Refresh
retains pending work and marks stale revisions as conflicts. Browser storage
transactions reject stale-tab writes, and existing account/role isolation and
offline access rules continue to apply.

Only Owner can prepare soft deletion, restoration or permanent deletion, each
through an explicit confirmation with cancellation. Soft deletion cascades to
Cards when later committed; restoration selects only the Pack, returns it to
hidden state and requires an eligible Topic. Permanent deletion is irreversible
when uploaded and requires contained Cards to have been purged first, matching
the existing Worker contract. Pending operations can be discarded locally
before upload. Permanent deletion is stored as `permanentDelete`; older builds
may reject this new operation instead of misinterpreting it.

A Pack without active Cards with a nonempty name and image reference is shown
as a draft, never as playable or publishable. The administrative dataset does
not establish publication status, so even Packs with eligible Cards do not gain
a publication badge. Card authoring is covered by T31 below; mutation transport remains a later ticket.
No Content Backend deployment, API activation or mutation upload is added.
See [T30 verification](T30-VERIFICATION.md).

## Card editing and local image review (T31)

Open **My Packs → Review Cards** or use **Cards → Pack** to work inside one
existing scoped Pack. The Card form contains Name, Image selection, Difficulty
1–3 and its fixed Pack relationship. IDs and readonly creator/revision/lifecycle
information are separate review metadata. There are no semantic fields such as
biography, tags or aliases, and no Card publishing route.

Collectors create/edit/hide only within their authenticated Worker's scoped
Packs. They cannot delete, restore, purge or move Cards. Owner can edit any
scoped Card and prepare confirmed soft deletion, restoration into hidden state,
or permanent deletion. A Card's ID and Pack are preserved through name,
difficulty and image changes, including before its first upload. Authoring needs
an existing eligible Pack and Topic; unsynced/deleted/restoring/conflicting
parents are unavailable. Pending Card changes block destructive parent changes.
Account or role changes close private review/editor dialogs and clear inputs.

The browser file picker accepts one JPEG/PNG/WebP candidate and uses the T32
preparation pipeline below before previewing local bytes. A filename suggests the name only
when the name field is empty; replacing an image preserves an entered name and
the Card ID. Cancelled or failed selection retains the previous image. These
include local decoding/normalization; publication validation is separate.
Existing server references remain readonly; their private bytes are
not fetched for preview by this ticket.

Saving persists the candidate attachment separately from the four canonical
product fields in the account's IndexedDB draft. Reopening offline restores its
name, difficulty, original ID and image preview if site storage survives.
Queue Card commit explicitly persists an unsent local intent. A selected image
has no fabricated remote reference and cannot become an upload-ready metadata
operation until T32A authenticated ingestion supplies a valid Pack-bound image
reference. Local queueing does not execute the Card mutation.
Uncommitted/replaced images and hidden/deleted/conflicting Cards do not make a
Pack playable. Quota failures retain form inputs and the prior saved snapshot.
Legacy T28 name drafts remain compatible; matching readonly metadata is stripped
when queueing. See [T31 verification](T31-VERIFICATION.md).

## Browser image preparation (T32)

The Card picker and **Cards → Prepare images** use a local JavaScript Worker
with `createImageBitmap`, `OffscreenCanvas` and Web Crypto. JPEG, PNG and still
WebP containers are checked before decode, resized without upscaling to a
maximum 1024-pixel edge, and redrawn into a fresh canvas to discard source
EXIF/XMP/text metadata. Encoding uses WebP quality 0.84 where available, otherwise
PNG with a visible warning; transparency is preserved. Output container, decoded
dimensions and SHA-256 are validated before the Card candidate is persisted.
Candidate names use NFC normalization, strip paths/control/bidi characters,
replace underscores/hyphens and keep an existing typed Card name.

Safety limits are 20 MiB per source, 16 megapixels before decode, 5 MiB per output
and 500 selected files per review. These are resource bounds. Around 50 KiB per
image and 10 MiB per Pack are advisory quality targets and do not reject valid
images. Each worker has a 30-second timeout. Cancellation terminates the active
worker; closing the dialog or losing account scope also clears private previews.
Unsupported formats/animation, corrupted containers, missing browser APIs and
memory/quota failures produce actionable errors without replacing prior images.

Batch review processes one lazy File handle at a time and retains summaries,
normalized hashes and one preview. Equal normalized bytes are identified as
duplicates even when filenames differ; Card editing also warns about matching
local candidates in the same Pack. Hashes identify encoded content, so results
from different browser encoders are not guaranteed to have the same hash.
Batch review does not create Cards or retain all prepared bytes. Save an image
through its Card editor; bulk Card import remains T33. Draft attachments keep
preparation details separate from canonical game fields and remain recoverable
offline subject to browser storage limits.

Browsers without Worker/OffscreenCanvas/decode/Web Crypto support are rejected
with an explanation; there is no synchronous main-thread decoder fallback.
Chromium is exercised by the automated acceptance suite; other browser engines
still need live validation. T32A must independently revalidate images and scope
before ingestion. No image upload or backend activation is added here. See
[T32 verification](T32-VERIFICATION.md) for results and reproduction commands.

## Private image ingestion (T32A)

Save a prepared Card image locally, then choose **Upload image privately** while
online and authorized. This explicit action sends only that image to the
configured Worker, with its normalized SHA-256 and the stored Pack revision.
There are no background image uploads. Cancellation, failed transfer or failed
receipt persistence retains the local image; retrying the same content is safe.
An account/role change aborts in-flight work and rejects late results.

The Worker checks Firebase UID/role, stored Pack ownership and its Topic before
reading bytes. It independently validates normalized PNG/WebP, bounded size and
dimensions, metadata, SHA-256 and decoded pixels. JPEG sources first pass through
T32. Exact-origin preflights permit the upload headers, while every actual upload
still requires authentication and scope. Private staging has no public read
route; no R2 credentials or signing keys are present in the app.

A validated upload receipt is stored with the account's draft outside canonical
game fields. The Card keeps its original ID and Pack and uses the returned scoped
image reference. **Queue Card commit** continues to persist a local unsent intent;
it does not send the Card mutation. T24 accepts the returned reference only in a
separate, explicit versioned batch with current aggregate revision/idempotency.
The backend verifies/promotes staged bytes and binds the image in that guarded
transaction. General browser queue transport remains T36; bulk import remains
T33. Uploading never publishes a Card or a Pack.

Ready images can expire after 24 hours without attachment. A local receipt is
not a permanent remote capability: repeat the private upload if its orphan
binding has expired. Server quotas are separate from T32 quality targets;
contact the Owner on a quota failure. Trusted operator cleanup reclaims expired
private staging, never published canonical objects. Contributors have no image
deletion endpoint, and discarding a local draft does not delete remote content.

The API remains independently configured; no production Content Backend
deployment, remote migration, API activation or bucket operation is performed by
this ticket. See the [versioned contract](../contracts/studio/v1/image-ingestion.md)
and [T32A verification](T32A-VERIFICATION.md).
