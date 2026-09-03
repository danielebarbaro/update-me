# forge-wp-update

Automatic WordPress updates on Laravel Forge servers, driven by wp-cli and cron. Core is kept current on minor and patch releases, plugins and themes are updated within their major. Core major releases are always left to a human, and the database is never dumped or restored. Each site is health-checked after its updates and rolled back automatically if it stops responding.

> **Upgrading from a version before core and theme support:** those releases only touched plugins. After updating the script, core minor releases and theme updates start being applied on the next run without any config change. Set `UPDATE_THEMES=""` to keep themes off, and put a `core` line in a site's ignore file to keep its core pinned.

## What it does

For every WordPress install found under `SITES_ROOT`, running wp-cli as the site owner:

1. Updates WordPress core with `core update --minor`, so 6.8.1 to 6.8.2 yes, 6.8 to 6.9 no, then runs `core update-db`. Health-checks the site. If it is down, the core files are put back at the previous version and the site is left alone for the rest of the run. The database is never touched, because a minor release does not migrate the schema.
2. Lists plugins and themes with available updates.
3. Skips anything listed in the site's exclude file.
4. Updates a plugin or theme only when the latest version stays in the same major (4.3 to 4.9 yes, 4.x to 5.0 no). Major bumps are skipped and logged.
5. Fetches the site home URL. If the status code is not healthy, it rolls back everything it just updated on that site, themes first.

It scans every home under `/home` and finds each WordPress install (nested installs included).

## Requirements

* A Laravel Forge server (Ubuntu, bash 5+).
* `wp-cli` on PATH (the installer offers to install it if missing).
* `sudo`, `curl`, `find`. The tool runs as root so it can drop to each site owner.

## Install

Run on each server. Pick a unique `SERVER_NAME` per server.

```bash
curl -fsSL https://raw.githubusercontent.com/danielebarbaro/update-me/main/install.sh | sudo bash
```

The installer checks dependencies, prompts for the server name, sites root, and log path, writes the config, installs the command to `/usr/local/bin/forge-wp-update`, and schedules a root cron entry. It finishes with a dry run.

Re-running the installer is safe. It updates the config and cron in place without duplicating anything.

## Manual usage

```bash
sudo forge-wp-update            # apply core minor and same-major extension updates
sudo forge-wp-update --dry-run  # show what would change, change nothing
```

## Configuration

Config lives at `/etc/forge-wp-update/config` (mode `0600`). It is sourced as bash. See `config.example` for the full template.

| Key | Meaning |
| --- | --- |
| `SERVER_NAME` | Unique per server. Used in log lines. |
| `SITES_ROOT` | Root scanned for WordPress installs. Default `/home`. |
| `LOG` | Log file path. |
| `HEALTHCHECK_CODES` | Space separated HTTP codes treated as healthy. Default `200 301 302`. |
| `IGNORE_FILENAME` | Per-site exclude filename. Default `.forge-wp-update-ignore`. |
| `UPDATE_THEMES` | Same-major theme updates. On by default. Set to `""` to turn them off server-wide. |

Core minor updates have no config switch. They are always applied, and a single site opts out with a `core` line in its ignore file.

## Excluding things per site

Create a file named `.forge-wp-update-ignore` in a site root (next to `wp-config.php`). One entry per line. Lines starting with `#` are comments.

```
woocommerce      # a plugin slug
elementor
theme:avada      # a theme slug
core             # this site's core stays where it is
```

## Git commit after update (optional)

Set `COMMIT_AFTER_UPDATE=1` in the config to record updates in the site's git repo. After a successful same-major update on a site that is a git repo (repo root assumed to be the site root), the updated directories are committed with a path-scoped commit. Plugins and themes get one commit each, so either can be reverted on its own, and only `wp-content/plugins/<slug>` or `wp-content/themes/<slug>` of what was actually updated is committed. Core files are never committed. Any other modified or staged files are left untouched, and their count is written to the log so you can review them yourself. Set `GIT_COMMIT_NAME` and `GIT_COMMIT_EMAIL` to control the commit author. The feature is off by default.

Set `PUSH_AFTER_COMMIT=1` to push to the tracked remote. The push runs once per site per run, after both commits, so plugin and theme commits travel together. The push is never forced, so a remote that has moved ahead rejects it (the rejection is logged and the run continues). The site owner needs push credentials for the remote. Useful when sites deploy by pulling from that remote, so the server and the remote stay in sync.

## Cron schedule

The installer writes `/etc/cron.d/forge-wp-update` running as root, daily at 04:00. Edit that file to change timing.

## Safety model

Each site is updated in two stages, core first, then plugins and themes, and the home URL is requested after each. A response outside `HEALTHCHECK_CODES` triggers an automatic rollback of that stage: the core files go back to the version read before the update, plugins and themes to the versions recorded before the run. A core failure stops the run for that site, so a broken core is never compounded by extension updates. The database is never dumped or restored, which is why core major releases are out of scope: those do migrate the schema, and a file-only rollback would not be enough. The result is logged either way. Runs are serialized with a lock file so two cron runs never overlap.

## Restore (manual)

To put a plugin, a theme, or core back to a known version yourself:

```bash
sudo -u <owner> wp --path=/home/<owner>/<site> plugin update <slug> --version=<old-version>
sudo -u <owner> wp --path=/home/<owner>/<site> theme update <slug> --version=<old-version>
sudo -u <owner> wp --path=/home/<owner>/<site> core update --version=<old-version> --force
```

## Troubleshooting

* Log file: the path set by `LOG` in the config (default `/var/log/forge-wp-update.log`).
* Dry run to see candidates without changing anything: `sudo forge-wp-update --dry-run`.
* "config not found": the installer did not complete, or `/etc/forge-wp-update/config` is missing.
* A site stuck in maintenance mode: `sudo -u <owner> wp --path=<site> maintenance-mode deactivate`.
