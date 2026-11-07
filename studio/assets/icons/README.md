# Studio icons to supply

Put the following files in this folder (`studio/assets/icons/`). These cover
only the current Studio preview, not future editor or publishing features.

| Filename | Symbol | Used for |
| --- | --- | --- |
| `dashboard.webp` | Four-square grid | Dashboard navigation and empty state |
| `topics.webp` | Category shapes | Topics navigation and empty state |
| `packs.webp` | Archive box | My Packs navigation and empty state |
| `cards.webp` | Two overlapping cards | Cards navigation and empty state |
| `profile.webp` | Person outline | Profile navigation and empty state |
| `sign-in.webp` | Arrow entering a doorway | Sign-in link and placeholder |
| `menu.webp` | Three horizontal lines | Open mobile navigation |
| `error.webp` | Circle with exclamation mark | Error and unavailable-page states |
| `offline.webp` | Cloud with diagonal slash | Offline state |

Use one consistent outline family: **96×96 px transparent WebP**, with the icon
centered and drawn to the same optical size. Use charcoal **#27272A**, no colored
background, gradients, shadows or baked-in text. Aim for a 2 px stroke at a
24×24 display size (8 px in the 96×96 file), with a little clear edge padding.
The built-in loading spinner does not need an image.

The app continues to use its built-in Material icons until these files are
provided and wired in. This directory is deliberately not registered as a Flutter
asset directory yet, so this README and future unreviewed files are not bundled.
The supplied BiGuess logo is already copied to `../brand/biguess_logo.webp`.
