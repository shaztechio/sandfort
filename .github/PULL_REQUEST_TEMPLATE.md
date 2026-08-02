## What this changes and why

<!-- Explain the reasoning, not only the diff. -->

## Verification

<!-- State what you actually ran. Do not describe a live UTM boot unless you booted one. -->

- [ ] `make test` passes
- [ ] `make app` and `codesign --verify --deep --strict "dist/Sandfort.app"` (packaging or UI changes)
- [ ] Real UTM boot tested (required for guest provisioning changes) — describe what you exercised:

## Impact on existing users

- [ ] Users must **Rebuild** their baseline (guest provisioning changed)
- [ ] Profile revision bumped accordingly
- [ ] No effect on existing baselines

## Checklist

- [ ] Docs in `docs/` updated where this changes intent
- [ ] Apache-2.0 header on any new source file
- [ ] No new runtime shell/AppleScript dependency, host sharing, or relaxed image verification
