# T26 verification — 2026-11-07

Environment: Linux, Flutter 3.47.9 / Dart 3.13.7, Chrome 155.0.8059.84,
Playwright 1.65.0. No live services or production accounts were used.

| Check | Result |
| --- | --- |
| `bash studio/scripts/check.sh all` | Format, fatal-info analysis, 6 widget/route tests, release web build and public-boundary check pass. |
| `node studio/scripts/browser_smoke.cjs` with local Playwright and Chrome | Desktop 1440×900 and mobile touch 360×740 pass. All destinations, inert login, browser back/forward, direct refresh of `/my-packs`, and loaded-app offline navigation work. Desktop keyboard navigation also passes. |
| Widget compact layout | 320×640 with 200% text passes every destination without layout exceptions. |
| Browser public boundary | Zero external requests, runtime exceptions, service-worker registrations, localStorage entries or IndexedDB databases in fresh contexts. |
| Root `flutter test` | 249 tests pass, including the SQL/private-image offline gameplay gate. |
| Root `flutter analyze` | Pass, no issues. |
| Root Dart formatting (`lib test`) | Pass, no changes. |
| `python3 .agents/scripts/validate_setup.py` | Pass, 959 checks. |
| `python3 -m unittest discover -s .agents/tests -v` | Pass, 154 tests. |
| Shell/Node/Python script syntax and scoped `git diff --check` | Pass. |

Release compilation reports Flutter's deprecated `--pwa-strategy` flag and an
unused default Cupertino font-family warning; it exits successfully. Only
Material icons are used. `--pwa-strategy=none` leaves a zero-byte worker file;
the custom bootstrap does not register it. No private data is persisted or cached.
The build bundles its renderer resources instead of fetching them from a CDN.

Screenshots of the desktop and mobile release were visually inspected. Browser
smoke uses a temporary local static server with SPA fallback, not remote hosting.
Fresh offline visits cannot load uncached static files; offline navigation is
verified after the app loads. Mobile emits the existing non-Shorebird host-runtime
notice, with tests still passing. Its initial SQLite native dependency download
was slow but completed without changing Mobile dependencies or configuration.

Source and dependency review found only Studio-owned SDK dependencies, public
placeholder copy, routing and presentation. There are no API clients, auth SDKs,
Mobile imports, native Studio platform folders or content assets. The independent
package is excluded from root analysis and has its own scoped validation workflow.

T26A remains the immediate next ticket: owner-authorized static frontend hosting
at `https://studio.saoudi.online`. No DNS, hosting, deploy workflow, backend
publishing, authentication integration or Studio Android artifact was introduced.
Existing edits to `TODO.md`, editor settings and historical-source deletions were
outside this task's scope and were preserved.

## Studio visual refresh

The preview now uses an ivory workspace, a dark green navigation sidebar,
consistent emerald accents, rounded status surfaces and a decorative card deck.
The illustration is drawn with Flutter widgets; there are no new assets,
packages, network calls or content-management actions. The sidebar adapts to
available space and text scaling; smaller layouts use the scrolling drawer.

The refreshed Studio suite contains **7 tests**, including new 200% text checks
at 800×600, 1024×768 and 1440×900. Release Chrome smoke tests retain desktop
pointer/keyboard, mobile touch, history, refresh, offline and public-boundary
checks, and also capture the dashboard for visual review. Root Mobile's 249
tests, analysis, setup validation and 158 tooling tests pass independently.


## Logo-based minimal UI

The green visual refresh above is historical. The current Studio uses the supplied
BiGuess logo and favicon, neutral surfaces, a restrained blue accent, simple
navigation and a single empty-state panel per route. Promotional copy, repeated
preview badges and the decorative card illustration have been removed.
The app bundles only the approved logo as media; the public-boundary check now
allows that exact asset instead of rejecting all application media. Icon requests
and delivery specifications are in `assets/icons/README.md`; Material icons remain
in use pending delivery. The current verification gates still apply.


## Supplied SVG icon integration

All 22 user-supplied SVG sources were conservatively optimized with SVGO 4.0.2,
from 27,880 to 25,427 bytes (8.8% smaller). Every source rendered pixel-identically
before and after at 96 and 384 px using librsvg. Original geometry, colors,
source credits, IDs and filenames are retained. Studio now bundles only the nine
icons needed for its existing public preview, as self-contained local copies.

The direct dependency allowlist now includes pinned `flutter_svg` 2.3.0. Only
asset loading is used. The build boundary allows exactly the logo and nine SVGs
and rejects SVG embedded browser code/external resources. A new test decodes
every bundled icon with the actual Flutter SVG renderer; the Studio suite now
has eight tests. Browser navigation, 200% text, accessible names and offline
behavior retain their existing checks. No additional app features are enabled.

Icon integration verification: all eight Studio tests, Studio analysis and release
web build pass. Desktop/mobile Chrome smoke checks pass with local SVG assets,
zero external requests and offline navigation. Root Mobile's 249 tests and
158 tooling tests pass; source/asset comparisons and script syntax checks pass.
