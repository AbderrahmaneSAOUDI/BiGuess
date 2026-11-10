# T32 browser image preparation verification — 2026-11-10

[Policy and limits](README.md#browser-image-preparation-t32).

## Check results

| Check | Result | Log |
| --- | --- | --- |
| Studio format/analyze/tests/release build/boundary | PASS: 180 tests | `/tmp/t32-studio-final.log` |
| Worker/Canvas Chromium acceptance | PASS: 120-image batch, 787 main-thread timer ticks | `/tmp/t32-image-browser-final.log` |
| Static packaging tests | PASS: 9 tests | `/tmp/t32-packaging.log` |
| Packaged shell desktop/mobile smoke | PASS | `/tmp/t32-smoke.log` |
| Chromium IndexedDB transactions | PASS: 10 tests | `/tmp/t32-store-browser.log` |
| Packaged T28–T32 dataset browser | PASS: 82 private GETs, zero uploads | `/tmp/t32-dataset-browser.log` |
| Dataset fixture release build | PASS | `/tmp/t32-dataset-build.log` |
| Root Mobile tests including offline gate | PASS: 249 tests | `/tmp/t32-mobile-test.log` |
| Root Mobile analysis | PASS: no issues | `/tmp/t32-mobile-analyze.log` |
| Agent setup | PASS: 962 checks | `/tmp/t32-setup-final.log` |
| Agent Python suite | PASS: 162 tests | `/tmp/t32-agents.log` |

The initial Studio attempt failed on an outdated selection-error expectation
and two offscreen test taps; the corrected full run above passed. The original
attempt remains in `/tmp/t32-studio.log` and is not counted as a passing gate.
Release builds emit existing WebAssembly dry-run/font warnings; JavaScript
release compilation and boundary checks complete successfully.

## Acceptance evidence

The real Chromium suite runs production JavaScript in Workers and native
browser decoders/canvases. Generated JPEG/PNG/WebP fixtures verify 2000 × 1000
resizing to 1024 × 512, transparency retention, WebP output and decoded output
validation. EXIF/text metadata marker fixtures do not survive redraw. PNG
fallback, unsupported decoding/canvas, simulated quota and allocation failures,
invalid encoder output, source byte/pixel limits, damaged PNG CRC/JPEG ending,
MIME mismatch, path/Unicode/bidi naming, duplicate hashes, cancellation and
concurrent-job rejection are checked. A 120-image sequential batch verifies
that main-thread timers continue running while every result is validated.

Flutter tests exercise sequential lazy-source preparation, duplicate summaries,
failure isolation, progress, cancellation rejecting late results, file-handle
release, account-loss cleanup including late picker completion, cancellation
retaining the previous Card image/name, and 360-pixel/200-percent-text layout.
Existing Card identity, permissions, offline draft and explicit queue tests
remain in the suite. Preparation metadata is serialized separately from the
canonical product fields and invalid metadata is rejected.

The packaged dataset browser additionally selects actual files through the
Flutter UI, verifies persisted output MIME/dimensions/hash, reviews a batch with
one duplicate and one corrupt image, and proves no extra Card draft is created.
Offline replacement/reload retains the Card ID and normalized hash. The
existing T28–T31 account-isolation/lifecycle flows remain included.

## Reproduce

Use the pinned isolated Playwright installation in
[T28 verification](T28-VERIFICATION.md#reproduce-browser-checks), then from Studio:

```bash
bash scripts/check.sh all
python3 -m unittest discover -s test -p 'test_*.py' -v
node scripts/image_preparation_browser.cjs
flutter test --platform chrome test/dataset_store_test.dart
flutter build web --release --no-web-resources-cdn --pwa-strategy=none --target test/browser_dataset_app.dart --output build/dataset-web
node scripts/dataset_browser.cjs
```

The dedicated image-browser acceptance suite is part of the existing static
Studio workflow, after its packaged dataset browser checks.

## Limits

Chromium is tested live. Missing browser APIs are simulated in fresh Workers;
this does not prove compatibility with Safari or Firefox. Source/output/pixel
limits bound a single job; they do not guarantee a low-memory device can decode
every image under those limits. Termination, timeout and resource-specific errors
provide recovery. Still images only; animated PNG/WebP are explicitly rejected.
Encoding and normalized hashes may differ between browsers. The size targets
are warnings rather than quality-degrading compression mandates.

The batch review retains summaries and one preview, not an import queue of all
image bytes. Card save persists one prepared attachment locally; bulk import
remains T33. Image metadata/hashes from local storage are not server trust:
T32A must independently validate scope, bytes, hash and format at ingestion.
No image upload, mutation transport, publication, Content Backend deployment,
API activation or Mobile gameplay change is part of T32.
