# Sandfort project site

The public marketing and orientation site for Sandfort. It is a single
self-contained page: `index.html` carries its own CSS, its own SVG diagram, and
no external scripts, fonts, or stylesheets.

```
gh-pages/
├── index.html          the whole site
├── assets/Sandfort.png app icon, used as hero art and favicon
├── .nojekyll           serve the files as-is, no Jekyll processing
└── README.md           this file
```

Preview it by opening `index.html` in a browser. There is no build step.

## Publishing

**A `gh-pages/` folder on `main` is not a valid Pages source.** GitHub Pages can
only serve a branch root or a `/docs` folder, and `/docs` already holds this
project's technical documentation. So the folder has to be published as the
*root* of a branch, or uploaded by a workflow.

### Option A — push the folder to a `gh-pages` branch

```bash
git subtree push --prefix gh-pages origin gh-pages
```

Then set **Settings → Pages → Source** to *Deploy from a branch*, branch
`gh-pages`, folder `/ (root)`. Re-run the same command after each change.

### Option B — deploy with Actions

Set **Settings → Pages → Source** to *GitHub Actions*, then add
`.github/workflows/pages.yml`:

```yaml
name: Deploy project site
on:
  push:
    branches: [main]
    paths: ['gh-pages/**', '.github/workflows/pages.yml']
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
concurrency:
  group: pages
  cancel-in-progress: true
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/upload-pages-artifact@v3
        with:
          path: gh-pages
      - id: deploy
        uses: actions/deploy-pages@v4
```

This publishes on every push to `main` that touches the folder, with no second
branch to keep in sync. Add the workflow only after selecting *GitHub Actions*
as the source, or its deploy step will fail.

### Before either option works

- **The repository is private.** Pages on a private repository requires GitHub
  Pro, Team, or Enterprise. On a free plan, publishing the site means making the
  repository public first.
- **`README.md` already advertises <https://sandfort.app/>** as the project site.
  To serve it from that name rather than `shaztechio.github.io/sandfort`, add a
  `CNAME` file containing `sandfort.app` to this folder and point the DNS records
  at GitHub. Do not add `CNAME` before DNS is configured — it takes the
  `github.io` address out of service.

## Editing

Keep the page honest. Its claims are drawn from `docs/security-model.md` and
`LinuxGuestCatalog.swift`, including the distribution list, the enforced
boundaries, and the residual-risk panel. That panel is not filler: a sandbox
that oversells itself gets trusted with things it cannot protect. When the
security model changes, update the page in the same commit.

Distribution facts that appear on the page and drift easily:

- the four supported profiles and their release names,
- 4 GB RAM, 4 vCPU, and a 64 GiB disk,
- which distributions have signature-verified checksums. Ubuntu, Fedora, and
  openSUSE do; Debian publishes no signature for its cloud manifest and is
  hash-only.

The page has no screenshot. `assets/Sandfort-screenshot.png` in the repository
root predates the current window layout, so adding it here would ship a picture
of an interface that no longer exists.
