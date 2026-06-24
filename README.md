# forge-wp-update

Automatic same-major WordPress plugin updates on Laravel Forge servers, driven by wp-cli and cron. WordPress core, themes, and the database are never touched. Each site is health-checked after its updates and rolled back automatically if it stops responding.

## What it does

For every WordPress install found under `SITES_ROOT`, running wp-cli as the site owner:

1. Lists plugins with available updates.
2. Skips any slug listed in the site's exclude file.
3. Updates a plugin only when the latest version stays in the same major (4.3 to 4.9 yes, 4.x to 5.0 no). Major bumps are skipped and logged.
4. Fetches the site home URL. If the status code is not healthy, it rolls back the plugins it just updated on that site.

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
sudo forge-wp-update            # apply same-major plugin updates
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

## Excluding plugins per site

Create a file named `.forge-wp-update-ignore` in a site root (next to `wp-config.php`). List one plugin slug per line. Lines starting with `#` are comments. Those plugins are never auto-updated on that site.

```
woocommerce
elementor
```

## Git commit after update (optional)

Set `COMMIT_AFTER_UPDATE=1` in the config to record plugin updates in the site's git repo. After a successful same-major update on a site that is a git repo (repo root assumed to be the site root), the updated plugin directories are committed with a path-scoped commit. Only `wp-content/plugins/<slug>` of the plugins that were updated is committed. Any other modified or staged files are left untouched, and their count is written to the log so you can review them yourself. Set `GIT_COMMIT_NAME` and `GIT_COMMIT_EMAIL` to control the commit author. The feature is off by default.

Set `PUSH_AFTER_COMMIT=1` to push the commit to the tracked remote. The push is never forced, so a remote that has moved ahead rejects it (the rejection is logged and the run continues). The site owner needs push credentials for the remote. Useful when sites deploy by pulling from that remote, so the server and the remote stay in sync.

## Cron schedule

The installer writes `/etc/cron.d/forge-wp-update` running as root, daily at 04:00. Edit that file to change timing.

## Safety model

Updates are applied per site, then the home URL is requested. A response outside `HEALTHCHECK_CODES` triggers an automatic rollback of the plugins updated in that run, using the versions recorded before the update. The result is logged either way. Runs are serialized with a lock file so two cron runs never overlap.

## Restore (manual)

To pin a plugin back to a known version yourself:

```bash
sudo -u <owner> wp --path=/home/<owner>/<site> plugin update <slug> --version=<old-version>
```

## Troubleshooting

* Log file: the path set by `LOG` in the config (default `/var/log/forge-wp-update.log`).
* Dry run to see candidates without changing anything: `sudo forge-wp-update --dry-run`.
* "config not found": the installer did not complete, or `/etc/forge-wp-update/config` is missing.
* A site stuck in maintenance mode: `sudo -u <owner> wp --path=<site> maintenance-mode deactivate`.
