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
