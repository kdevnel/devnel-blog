# Changelog

All notable changes to the devNel theme and tooling are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the theme uses
[semantic versioning](https://semver.org/).

## [Unreleased]

### Added

- Repo scaffold (#01): empty `devnel` block theme (header, `theme.json` v3, `index` template,
  `functions.php` loading `inc/*.php`), npm and Composer tooling, phpcs (WPCS, PHPCompatibilityWP
  8.4), PHPStan level 6, ESLint, stylelint, Prettier, shellcheck and Bats, GitHub Actions CI and
  Dependabot. `npm run check` runs everything.
- Local environment (#02): `.wp-env.json` (PHP 8.4, the theme, wordpress.org plugin zips),
  `npm run env:start|env:stop|env:reset`, `env:sync` (pins wp-env to production's versions in the
  gitignored `.wp-env.override.json`), `db:pull` (streams a read-only production export into a
  throwaway, network-less MySQL container, sanitises and checks it there, and only then imports it
  into wp-env), `db:check` (`scripts/check-sanitised.sh`), and `uploads:pull`. The sanitisation
  list is one set of data files in `scripts/sanitise/`. `uploads:pull` skips private plugin files
  (`uploads-exclude.txt`). See `docs/LOCAL.md`.
- Backups (#18): `scripts/backup/backup.sh` (daily verified DB dump, weekly wp-content + nginx
  config, atomic writes, disk guard, local and off-site retention, encrypted off-site copy via
  rclone crypt, Healthchecks heartbeat and failure email) and `scripts/backup/restore-test.sh`
  (weekly automated restore into a scratch database with a restricted MySQL user, compared against
  production, with its own disk guard). Runbooks for install, restore and cleanup in
  `docs/runbooks/`.
- Restore test memory guard (#18): `restore-test.sh` refuses to start without enough free memory
  (RAM + swap) and aborts the import, with an alert, if headroom falls too low while it runs.
  New settings `RESTORE_MIN_MEM_MB`, `RESTORE_ABORT_MEM_MB`, `RESTORE_MEM_POLL_SECONDS`.
