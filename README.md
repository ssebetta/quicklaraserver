# quicklaraserver

An interactive, resumable script that takes an Ubuntu/Debian server from zero to a live Laravel project: prerequisites, deploy key, clone, database, `.env`, migrations, Nginx, SSL, queue worker and cron.

Run it once per project. Run it again on the same server for each new project.

## Requirements

- Ubuntu or Debian server with root or sudo access
- A domain whose DNS A record already points to the server (needed for SSL)
- A GitHub repo for the project (you will add a deploy key to it during the run)

## Install

Public repo:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/ssebetta/quicklaraserver/main/quicklaraserver.sh \
  -o /usr/local/bin/quicklaraserver && sudo chmod +x /usr/local/bin/quicklaraserver
```

Private repo (clone with a read-only deploy key, then symlink so `git pull` updates it):

```bash
git clone git@github.com:ssebetta/quicklaraserver.git ~/quicklaraserver
sudo ln -s ~/quicklaraserver/quicklaraserver.sh /usr/local/bin/quicklaraserver
```

To update later, repeat the curl command (or run `git pull` in the clone).

## Use

```bash
quicklaraserver
```

You are asked for:

| Prompt | Example | Notes |
|---|---|---|
| Project name | `ooda` | Used for the SSH key, SSH alias, supervisor program and state folder. Letters, numbers, `-` and `_` only. |
| Directory | `ooda` | Folder under `/var/www/html` |
| GitHub repo | `ssebetta/ooda` | `owner/repo`, `git@github.com:owner/repo.git` and `https://github.com/owner/repo` all work |
| Domain | `app.example.com` | |
| Copy `.env` from | `washway` | Another project's folder to copy `.env` from. Leave empty to use `.env.example`. |
| Shared Nginx file | `mywill` | File in `/etc/nginx/sites-available`. Created if missing. |
| PHP-FPM socket | `/run/php/php8.3-fpm.sock` | |

Editors (`nano`, `crontab -e`) open at the points where you need to fill things in. Save and close them and the script continues.

## What it does

| Stage id | Step |
|---|---|
| `apt` | `apt update` and `apt upgrade` |
| `prereqs` | Checks for PHP (with Laravel extensions), Composer, Node.js, Nginx, MySQL, Certbot and Supervisor, and installs whatever is missing |
| `sshkey` | Creates `~/.ssh/id_ed25519_<name>`, adds the `Host github-<name>` entry to `~/.ssh/config`, adds the key to `authorized_keys`, then shows the public key so you can add it as a **deploy key** on the GitHub repo |
| `clone` | Clones the repo into `/var/www/html/<dir>` and marks it a git safe directory |
| `composer` | `composer install` |
| `npm` | `npm install` |
| `database` | Optionally creates a MySQL database and user (password is typed hidden and is not saved) |
| `env` | Copies `.env` and opens it in nano |
| `keygen` | `php artisan key:generate` |
| `migrate` | `php artisan migrate` |
| `storagelink` | `php artisan storage:link` |
| `config` | `config:cache` then `config:clear` |
| `perms` | `chown www-data` on `storage` and `bootstrap` |
| `build` | `npm run build` |
| `nginx` | Appends a server block to the shared Nginx file (backup made first), opens nano to review, then tests and reloads |
| `ssl` | Runs Certbot for the domain |
| `supconf` | Writes `/etc/supervisor/conf.d/<name>-worker.conf` and opens nano to review |
| `supstart` | Supervisor `reread`, `update` and `start` |
| `cron` | Opens `crontab -e` with the scheduler line suggested (skipped if the project is already in your crontab) |
| `finalenv` | One last `.env` edit and `config:clear` |

## Resuming after a failure

Progress is stored in `~/.project-setup/<name>/`:

- `config` holds your saved answers.
- One empty file per completed stage.

If something fails, fix the cause and run `quicklaraserver` again with the same project name. Choose to reuse the saved settings and completed stages are skipped. A stage is only marked done when all its commands succeeded.

To redo one stage:

```bash
rm ~/.project-setup/<name>/<stage-id>
```

To start a project over, delete the whole `~/.project-setup/<name>/` folder.

Use the same Linux user each time, because the state folder lives in that user's home.

## Options

Set these as environment variables when running:

```bash
PHP_VER=8.4 NODE_MAJOR=20 quicklaraserver
```

| Variable | Default | Meaning |
|---|---|---|
| `PHP_VER` | `8.3` | PHP version to check for and install. If it is not in the default repos, the `ondrej/php` PPA is added. |
| `NODE_MAJOR` | `22` | Node.js major version installed from NodeSource when Node is missing or older than 18 |

## Notes

- Existing `.env` files are never overwritten, and `key:generate` runs only once per project, so re-runs do not change `APP_KEY`.
- If a MySQL user already exists, its password is left unchanged.
- After the first MySQL install, consider running `sudo mysql_secure_installation`.
- If you use `ufw`, allow SSH and web traffic before running Certbot: `sudo ufw allow OpenSSH && sudo ufw allow 'Nginx Full'`.
- The script never stores secrets. Do not commit `~/.project-setup` or any `.env` file.