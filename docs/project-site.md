# Project site

The public site for Sandfort lives in this folder and is served by GitHub Pages
from `main`, so publishing is an ordinary push with no second branch to keep in
sync.

```
docs/
├── index.html          the whole site: its own CSS, its own SVG, no external requests
├── assets/Sandfort.png hero art and favicon
├── .nojekyll           serve these files as-is
└── *.md                the technical documentation, unchanged
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

`assets/Sandfort-screenshot.png` is a copy of the one in the repository root,
duplicated for the same reason as the icon: only files under `docs/` are
published. It shows 0.16.1 with four environments in three different states,
which is the thing a single-environment shot cannot convey. Retake it when the
window layout changes, and update both copies — a screenshot of an interface
that no longer exists is worse than none, which is why the page went without one
for a while.
