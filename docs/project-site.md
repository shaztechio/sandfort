# Project site

The public site for Sandfort lives in this folder and is served by GitHub Pages
from `main`, so publishing is an ordinary push with no second branch to keep in
sync.

```
docs/
├── index.html               the whole site: its own CSS, its own SVG, one external script
├── assets/Sandfort-600.webp the hero icon at 2× the size it renders
├── assets/Sandfort.png      favicon, nav mark, and the hero's fallback
├── assets/social-card.png   the 1200×630 link preview
├── .nojekyll                serve these files as-is
└── *.md                     the technical documentation, unchanged
```

Preview it by opening `docs/index.html` in a browser. There is no build step.

## Publishing

Set **Settings → Pages → Source** to *Deploy from a branch*, branch `main`,
folder `/docs`. GitHub serves `docs/index.html` at the site root and
`docs/assets/` at `/assets/`.

Two things have to be true before that works:

- **The repository must be public**, or the account needs GitHub Pro, Team, or
  Enterprise. Pages on a private repository is a paid feature.
- **`README.md` advertises <https://sandfort.app/>** as the project site. To
  serve it from that name rather than `shaztechio.github.io/sandfort`, add a
  `CNAME` file containing `sandfort.app` to this folder and point the DNS
  records at GitHub. Do not add `CNAME` before DNS is configured — it takes the
  `github.io` address out of service.

## Sharing the folder with the documentation

The site and the Markdown coexist because their names do not collide: Pages only
claims `index.html` and `assets/`, and every document keeps its own path. Two
consequences are worth knowing.

**The Markdown becomes publicly fetchable** at addresses like
`/security-model.md` once the site is live. That is not a leak — these files are
already readable in the repository — but it does mean anything written here is
published, not merely committed.

**`.nojekyll` is load-bearing.** Without it, GitHub runs Jekyll over the folder,
which renders every `.md` file into an unstyled HTML page and treats `{{` and
`{%` in any file as Liquid template syntax. Documents here contain YAML and
shell examples that would either break the build or be silently mangled. Keep
the file.

Do not add a `docs/README.md`. GitHub would show it instead of the folder
listing, and Pages would have two candidate index documents.

## Editing the site

Keep the page honest. Its claims come from `security-model.md` and
`LinuxGuestCatalog.swift`, including the distribution list, the enforced
boundaries, and the residual-risk panel. That panel is not filler: a sandbox
that oversells itself gets trusted with work it cannot protect. When the
security model changes, update the page in the same commit.

The hero's primary action and the Get started section both link to
`releases/latest`, which always resolves to the newest published release. Nothing
on the page names a version, so a release needs no site edit.

Facts on the page that drift easily:

- the four supported profiles and their release names,
- 4 GB RAM, 4 vCPU, and a 64 GiB disk,
- which distributions have signature-verified checksums. Ubuntu, Fedora, and
  openSUSE do; Debian publishes no signature for its cloud manifest and is
  hash-only.

`assets/Sandfort.png` is a copy of the icon in the repository root `assets/`.
The duplicate is deliberate: only files under `docs/` are published, so a
`../assets/` reference would resolve during local preview and 404 on the live
site. Update both if the icon changes.

At 256×256 it is too small for the hero, which renders at 300 CSS px and so was
upscaled even before a retina display doubled it. The hero is a `<picture>`
serving `assets/Sandfort-600.webp` with the PNG as its fallback; the favicon,
the nav mark, `README.md`, and the Help Book icon all still use the PNG, so
nothing in the packaging pipeline moves.

Regenerate the WebP from the icon set rather than from the 256 PNG:

```sh
iconutil -c iconset assets/Sandfort.icns -o /tmp/Sandfort.iconset
sips -Z 600 /tmp/Sandfort.iconset/icon_512x512@2x.png --out /tmp/hero.png
cwebp -q 90 /tmp/hero.png -o docs/assets/Sandfort-600.webp
```

Two things about that source. **Nothing in the `.icns` is masked** — all seven
elements, 16 through 1024, are full-bleed squares with opaque corners — so the
hero's rounded corners come from the `border-radius: 28%` already on
`.hero-art img`, not from the file. That is also a bug in the shipped app icon
rather than a fact about the site; see issue #68. And WebP is worth the format
change rather than a larger PNG: the icon is a render with fine sand texture
that PNG stores badly, so 600px costs 620 KB as a PNG and 43 KB as WebP, which
is *less* than the 93 KB the 256 PNG cost.

`.hero-art picture { display: contents }` keeps the `<img>` as the flex child it
was before the `<picture>` wrapper existed, so the layout is unchanged.

`assets/Sandfort-screenshot.png` is a copy of the one in the repository root,
duplicated for the same reason as the icon: only files under `docs/` are
published. It shows 0.16.1 with four environments in three different states,
which is the thing a single-environment shot cannot convey. Retake it when the
window layout changes, and update both copies — a screenshot of an interface
that no longer exists is worse than none, which is why the page went without one
for a while.

## Analytics

The page loads PostHog from `us-assets.i.posthog.com` and sends events to
`us.i.posthog.com`. It is the only external request the site makes, and it is
configured with `person_profiles: 'identified_only'`, so anonymous visitors get
no person profile. The project key in the snippet is a public write-only key and
is meant to be readable in the page source.

This measures **the website**, not the app. Sandfort itself still collects and
transmits nothing, which is what the "Local credentials" bullet on the page
claims — keep that distinction intact if the analytics setup grows, because a
reader who conflates the two will reasonably conclude the app phones home.

## The link preview

`assets/social-card.png` is what Slack, Mastodon, iMessage, and the rest render
when someone posts a link. It is generated from `tools/packaging/social-card.html`:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1200,630 --screenshot=docs/assets/social-card.png \
  "file://$PWD/tools/packaging/social-card.html"
```

Three things about the `og:` tags are easy to get wrong and were all wrong at
once before this file existed:

- **`og:image` must be an absolute URL.** A relative one resolves correctly in a
  browser and is simply ignored by most crawlers, so the page looks fine and the
  preview is blank. Every URL in the tags is written against `https://sandfort.app`,
  the custom domain, not the `shaztechio.github.io` origin that redirects to it.
- **The image has to match the card type.** `twitter:card` is
  `summary_large_image`, which wants roughly 1.91:1 and refuses anything under
  300px wide. The 256×256 app icon was being offered for that slot and could not
  have rendered.
- **`og:url` pins the canonical address.** Without it a crawler keys its cache on
  whichever of the two hostnames it was handed.

The card repeats the page's own claims and adds none of its own; keep it that way,
because nothing validates it against `security-model.md`.
