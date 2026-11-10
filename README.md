# Office PC Care Toolkit

Self-service problem solver for the office team PCs. Staff install it once from
https://office-pc-care.vercel.app and it keeps itself up to date silently.

## How a change reaches every PC

1. Edit files in `src/` (`toolkit-additions.ps1` for features, `config.json` for settings).
2. Get it onto `main`:
   - Repository admin: push to `main`.
   - Everyone else: push a branch, open a pull request, the admin approves and merges.
3. GitHub Actions (`.github/workflows/release.yml`) builds `toolkit/PC-Care-Toolkit.bat` with the next
   build number and signs `toolkit/manifest.json`. Vercel redeploys the download page.
4. Each office PC's Auto Care (10 min after start, 15:30 and 20:30 Bangladesh time) downloads the
   manifest, checks the RSA signature against the public key built into the toolkit, checks every
   file's SHA-256, and installs only if all match. Staff see nothing.

## Layout

- `src/base-v11.bat` - original v11 toolkit (menus and fixes reused by v13)
- `src/toolkit-additions.ps1` - v12/v13 features
- `src/config.json` - settings sent to every PC (Chrome memory level, never-rest sites, allowed
  extensions, services to turn off, startup delay, Outlook offline months, Defender limits)
- `src/signing-key.public.xml` - public key only; the private key is a secret of the `release` environment
- `tools/build.py` - builds the .bat; `tools/ci-sign.ps1` - signs in CI
- `toolkit/` - signed output (written by the release bot; do not edit by hand)
- `index.html`, `vercel.json` - download page

## Security

- The signing key exists only as a secret of the `release` environment, usable only by the `main` branch.
- `main` requires a reviewed pull request; the admin and the release bot's deploy key can bypass.
- Files not signed by the release pipeline are rejected by every PC.
- No passwords, personal data or private keys are stored in this repository.
