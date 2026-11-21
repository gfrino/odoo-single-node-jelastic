# Changelog

## [1.3.1] - 2026-11-21

### Fixed
- The environment domain no longer stays on "Not secure" when the Let's Encrypt
  certificate fails at install. The new `cert-env.sh` waits for the DNS, tries three
  times, and if it still fails starts `odoo-cert-env.timer`, which retries every
  15 minutes (below Let's Encrypt's limit of 5 failed validations per hour) and stops
  as soon as the certificate is there, or after two days.
- `post-update.sh` (Update scripts, nightly backup) starts the same retries on existing
  environments whose domain reaches the node through the public IP without a
  certificate. Environments without a public IP are not touched (the Jelastic resolver
  already serves a valid certificate).
- The certificate warning is shown right under the Odoo URL in the success message,
  and **Status** says when the retries are running.

### Why
- A new environment (climacontrol20) opened with "Not secure": with a public IP the
  environment domain reaches the node directly, which serves its self-signed certificate
  until Let's Encrypt succeeds. The single attempt at install had failed and nothing
  retried it; the warning was the last line of the success message.

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
