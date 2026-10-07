# Changelog

## [1.3.0] - 2026-10-07

### Changed
- Odoo workers are sized on the **reserved** cloudlets instead of the cloudlet limit.
  The manifest saves them in `/etc/odoo/jps.env` (`RESERVED_CLOUDLETS`) at install, after
  every change of cloudlets and on **Update scripts**; nodes without it keep the old sizing.
  Per-worker memory limits and the PostgreSQL tuning still follow the limit.
- **Status** lists every domain once (the environment domain was shown twice when it had
  a certificate) and says when the workers are sized on the reserved RAM.

### Added
- `/etc/odoo/odoo.local.conf` is created empty, with commented examples under `[options]`,
  by `post-update.sh` (so at install, on **Update scripts** and before the nightly backup).
  An existing file is never touched.

### Why
- A node with 4 reserved and 32 maximum cloudlets started 6 workers for ten users: about
  1 GB that stays in memory all day and is billed as dynamic cloudlets every hour.
- Nobody knew where local settings go: `odoo.local.conf` did not exist, and edits made in
  the generated `odoo.conf` were lost at the next Odoo start.
