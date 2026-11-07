# Studio icons

Optimized SVG copies of the user-provided sources in `../../../assets/icons/`.
Keep them as vectors; no WebP conversion is required.

| Filename | Current use |
| --- | --- |
| `dashboard.svg` | Dashboard navigation and empty state |
| `topic.svg` | Topics navigation and empty state |
| `pack.svg` | My Packs navigation and empty state |
| `card.svg` | Cards navigation and empty state |
| `profile.svg` | Profile navigation and empty state |
| `signin.svg` | Sign-in link and placeholder |
| `menu.svg` | Open mobile navigation |
| `error.svg` | Error and unavailable-page states |
| `offline.svg` | Offline state |

`StudioIcon` loads only bundled assets through the pinned `flutter_svg` renderer,
inheriting the enclosing icon color so selections and muted states remain
consistent. Buttons, navigation labels and status text own accessibility names.
The built-in loading spinner remains unchanged.

Only these nine files are individually registered in `studio/pubspec.yaml`.
This README and the unused source icons are not included in the browser bundle.
After changing a source, optimize it with `scripts/svgo.config.mjs` from the repo
root, copy the result here and run `bash studio/scripts/check.sh all`.
