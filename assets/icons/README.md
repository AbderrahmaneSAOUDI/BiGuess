# BiGuess UI icon sources

These 22 SVGs were supplied for Studio. Source filenames, paths, colors, titles,
IDs and embedded source credits are preserved. Conservative SVGO 4.0.2
optimization removes document boilerplate and unused dimensions, inlines CSS
and minifies XML without rounding or rewriting geometry.

```bash
# Run from the repository root. This updates only the SVGs in this folder.
npx --yes svgo@4.0.2 --config studio/scripts/svgo.config.mjs --folder assets/icons --multipass
```

The initial optimization reduced the SVG total from **27,880 to 25,427 bytes
(8.8%)**. Before/after renders of every file were pixel-identical at both 96×96
and 384×384 pixels using librsvg. The source artwork remains vector-based.

Studio bundles optimized copies of only these nine: `dashboard.svg`, `topic.svg`,
`pack.svg`, `card.svg`, `profile.svg`, `signin.svg`, `menu.svg`, `error.svg` and
`offline.svg`. They live in `studio/assets/icons/` so Studio runs independently.
When changing a used source icon, copy it to that folder and run Studio checks.
Other icons remain available as sources; they do not enable new app features
and are not registered in the Mobile or Studio asset bundles.
