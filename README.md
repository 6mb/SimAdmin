# SimAdmin Backup Control

This branch hosts the protected mirror workflow for `6mb/SimAdmin`.

- `main` is reserved as a direct mirror of `3899/SimAdmin`.
- This control branch must remain the repository default branch so scheduled
  GitHub Actions can run even when `main` is force-synced to upstream.
- The mirror job stops before pushing if upstream looks deleted, empty, or
  unexpectedly incomplete.
