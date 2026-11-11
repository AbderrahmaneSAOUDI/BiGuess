# T35 local verification — 2026-11-11

Implemented deliberate Topic/Pack publication review in Studio, server-side
rights/initial approval, owned routine Pack release requests, unpublishing, and
a separately authenticated privileged entrypoint around T22. No Card publishing,
private browser signing key, anonymous publisher, cloud deployment, remote
migration, or real content publication was introduced.

## Acceptance evidence

`test/publication-review.test.mjs` builds a test-only router around the actual
public API and independent operator entrypoints. It uses real Workerd, D1/R2,
verified RS256 Firebase tokens (only Google's JWKS response is mocked), ephemeral
Ed25519 publisher keys and cleared Shapes archives produced by T22's preparer.

All 9 integration cases passed:

1. Missing authentication, foreign Collector IDs, Collector rights/initial
   approval, unapproved first publication and independent Card publication fail.
2. Too few Cards, missing/corrupt images and absent rights approval cannot pass
   approval or release. Public history/catalog remain empty.
3. Approval/request alone remains private. Missing/wrong operator credentials and
   a bad signature cannot activate. A valid release stays hidden beneath a draft
   Topic until that Topic's Owner approval/publication. Operator routes are absent
   from the public API. Replaying a released request conflicts.
4. An owning Collector edits the published Pack's actual name; the signed second
   revision matches that edit and passes without another initial Owner approval.
   Six interrupted R2 write stages leave the prior public revision/history intact.
   Successful activation advances the catalog atomically and retains revision 1.
5. Stale reviews, a subsequently hidden Pack and a revoked request actor cannot
   activate queued content.
6. New Card/image pairs require rights approval; a correctly signed artifact
   that differs from the approved authoring snapshot cannot release.
7. A concurrent Pack hide during R2 staging prevents public activation and leaves
   no new immutable history/head.
8. A generation-only intervening writer invalidates the initial review even when
   T22 subsequently reads a newer internally consistent snapshot. The additional
   review guard rolls back the entire final D1 batch.
9. Malformed operator allowlist configuration blocks previously approved actors
   without creating a public head.

Studio's 17 new transport/controller/widget tests cover safe request construction,
server error mapping, live role verification, pending local and descendant
lifecycle drafts, offline denial, account-change/late-result cancellation,
explicit rights evidence, initial/hidden Pack approval, pending release copy and
a 360px viewport with 200% text. No browser result claims a queued request is
already public.

An independent read-only backend review checked authorization, exact signed
snapshot matching, races and Topic visibility. Bounded request reading and
append-only rights evidence were verified after correction. The deliberate
PNG/WebP review input restriction is documented in PUBLICATION-REVIEW.md.

## Commands and results

- Root `flutter test`: PASS, 249 tests, including the existing offline gameplay
  gate (SQL/private images, 10 + 3 rounds, zero HTTP clients).
- Root `flutter analyze`: PASS, no issues.
- `python3 .agents/scripts/validate_setup.py`: PASS, 962 checks.
- `python3 -m unittest discover -s .agents/tests -v`: PASS, 163 tests.
- Backend `npm run typecheck`: PASS.
- Backend `npm test`: PASS, 208 existing regression tests. The final allowlist
  validation change was additionally covered by the focused 9-test suite below.
- Backend `node --test test/publication-review.test.mjs`: PASS, 9 tests.
- Studio `flutter test --concurrency=1`: PASS, 235 tests.
- Studio format and `flutter analyze --fatal-infos`: PASS.
- Studio Web release build: PASS.
- Studio `python3 scripts/check_boundary.py`: PASS.
- Studio Python deployment tests: PASS, 9 tests.
- Separate operator dry-run build: PASS; no deployment.

The first parallel Studio run failed the existing search timing benchmark
(1147ms against its 1000ms ceiling) while other checks were consuming CPU. The
complete serial rerun passed without modifying the benchmark or search code.
The old boundary checker also failed on the existing bulk-import page in a clean
HEAD archive. Its precise local-module prefix was added alongside the new
publication prefix; product behavior and dependency permissions are unchanged.

Raw command logs for this run are available locally as
`/tmp/biguess-t35-{backend,publication-review,typecheck,flutter-test,flutter-analyze,setup,agents,studio-test,studio-test-serial,studio-format,studio-analyze,studio-build,studio-boundary,studio-python,operator-build}.log`.
These ephemeral logs are not a production deployment record.

## Operational limits

PUBLICATION-REVIEW.md defines the separate operator/security review and
provisioning gate. No operator secret or private signing key was created.
The operator entrypoint has no configured public route and is absent from the
public API and website CI deployment path. T22 still accepts only cleared-test
provenance; production provenance needs its separate versioned contract decision.
Unverified Anime/Flags were not imported, published or otherwise changed.
Larger-than-reviewed Pack budgets, general JPEG authoring review and physical
browser/device trials are not claimed by these host tests. Retained signed JPEG
history and existing anonymous download behavior remain unchanged.
