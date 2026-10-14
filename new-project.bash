#!/usr/bin/env bash
# Interactive, resumable Laravel project setup for this server.
# Usage: bash new-project.sh
#
# Progress is saved in ~/.project-setup/<name>/ :
#   config        saved answers (reused on re-run)
#   <stage-id>    one empty file per completed stage
# To redo a stage, delete its file. To start over, delete the folder.
set -uo pipefail

WEBROOT="/var/www/html"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
STATE_ROOT="$HOME/.project-setup"
STAGE_OK=1

step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
pause() { read -rp "Press Enter to continue (Ctrl+C to abort)... " _; }
ask()   { # ask VAR "Prompt" [default]
  local __var=$1 __prompt=$2 __def=${3:-} __val
  read -rp "$__prompt${__def:+ [$__def]}: " __val
  printf -v "$__var" '%s' "${__val:-$__def}"
}
run() {
  echo "+ $*"
  "$@" && return 0
  echo "FAILED: $*"
  read -rp "Continue anyway? (stage will NOT be marked done) [y/N] " a
  [[ $a =~ ^[Yy]$ ]] || exit 1
  STAGE_OK=0
}

# stage <id> <title> <function>: runs once, skipped if already completed
stage() {
  local id=$1 title=$2 fn=$3
  if [[ -f $MARK_DIR/$id ]]; then
    echo -e "\n\033[1;32m==> [skip] $title (already done)\033[0m"
    return
  fi
  step "$title"
  STAGE_OK=1
  "$fn"
  if (( STAGE_OK )); then
    touch "$MARK_DIR/$id"
  else
    echo "Stage '$id' had failures, so it will run again next time."
  fi
}

# ---------- Inputs ----------
step "Project details"
ask NAME "Project name (used for key, ssh alias, supervisor)"
[[ $NAME =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Use only letters, numbers, - and _"; exit 1; }

MARK_DIR="$STATE_ROOT/$NAME"
CONF="$MARK_DIR/config"
mkdir -p "$MARK_DIR"

REUSE=n
if [[ -f $CONF ]]; then
  read -rp "Saved settings found for '$NAME'. Reuse them? [Y/n] " REUSE
  [[ ${REUSE:-y} =~ ^[Nn]$ ]] && REUSE=n || REUSE=y
fi

if [[ $REUSE == y ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
else
  ask DIR         "Directory name under $WEBROOT" "$NAME"
  ask REPO        "GitHub repo (owner/repo or full git URL)"
  ask DOMAIN      "Domain (e.g. app.example.com)"
  ask ENV_SRC     "Copy .env from which project dir ('' to use .env.example)" "washway"
  ask NGINX_NAME  "Shared nginx site file in $NGINX_AVAIL" "mywill"
  ask PHP_SOCK    "PHP-FPM socket" "/run/php/php8.3-fpm.sock"

  # Accept owner/repo, git@github.com:owner/repo(.git) or https://github.com/owner/repo(.git)
  REPO=$(echo "$REPO" | sed -E 's#^(git@github\.com:|https?://github\.com/)##; s#\.git/?$##; s#/$##')
  [[ $REPO =~ ^[^/]+/[^/]+$ ]] || { echo "Could not parse repo '$REPO' (expected owner/repo)"; exit 1; }

  {
    printf 'DIR=%q\nREPO=%q\nDOMAIN=%q\nENV_SRC=%q\nNGINX_NAME=%q\nPHP_SOCK=%q\n' \
      "$DIR" "$REPO" "$DOMAIN" "$ENV_SRC" "$NGINX_NAME" "$PHP_SOCK"
  } > "$CONF"
fi

KEY="$HOME/.ssh/id_ed25519_$NAME"
ALIAS="github-$NAME"
APP="$WEBROOT/$DIR"
SUP_CONF="/etc/supervisor/conf.d/$NAME-worker.conf"
NGINX_FILE="$NGINX_AVAIL/$NGINX_NAME"

echo
echo "Key:     $KEY"
echo "Alias:   $ALIAS"
echo "Repo:    git@$ALIAS:$REPO.git"
echo "Path:    $APP"
echo "Domain:  $DOMAIN"
pause

# ---------- Stages ----------
s_apt() {
  run sudo apt update
  run sudo apt upgrade -y
}

s_sshkey() {
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  if [[ -f $KEY ]]; then
    echo "Key already exists, reusing."
  else
    run ssh-keygen -t ed25519 -f "$KEY" -N ""
  fi

  if ! grep -q "^Host $ALIAS\$" ~/.ssh/config 2>/dev/null; then
    cat >> ~/.ssh/config <<EOF

Host $ALIAS
    HostName github.com
    User git
    IdentityFile $KEY
    IdentitiesOnly yes
EOF
    chmod 600 ~/.ssh/config
    echo "Added Host $ALIAS to ~/.ssh/config"
  fi

  touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
  grep -qF "$(cat "$KEY.pub")" ~/.ssh/authorized_keys || cat "$KEY.pub" >> ~/.ssh/authorized_keys

  echo -e "\nAdd this public key to GitHub (repo > Settings > Deploy keys):\n"
  cat "$KEY.pub"
  echo
  pause
}

s_clone() {
  cd "$WEBROOT" || exit 1
  if [[ -d $APP/.git ]]; then
    echo "$APP already cloned."
  else
    run git clone "git@$ALIAS:$REPO.git" "$DIR"
  fi
  [[ -d $APP ]] || { echo "Clone failed: $APP missing."; exit 1; }
  git config --global --add safe.directory "$APP"
}

s_composer() { cd "$APP" || exit 1; run composer install; }
s_npm()      { cd "$APP" || exit 1; run npm install; }

s_env() {
  cd "$APP" || exit 1
  if [[ -f .env ]]; then
    echo ".env already exists, not overwriting."
  elif [[ -n $ENV_SRC && -f $WEBROOT/$ENV_SRC/.env ]]; then
    cp "$WEBROOT/$ENV_SRC/.env" .env
  elif [[ -f .env.example ]]; then
    cp .env.example .env
  fi
  echo "Opening nano: set APP_URL, DB_*, etc."
  pause
  nano .env
}

s_keygen()      { cd "$APP" || exit 1; run php artisan key:generate; }
s_migrate()     { cd "$APP" || exit 1; run php artisan migrate; }
s_storagelink() { cd "$APP" || exit 1; [[ -L public/storage ]] || run php artisan storage:link; }
s_config()      { cd "$APP" || exit 1; run php artisan config:cache; run php artisan config:clear; }
s_perms()       { run sudo chown -R www-data:www-data "$APP/storage" "$APP/bootstrap"; }
s_build()       { cd "$APP" || exit 1; run npm run build; }

s_nginx() {
  [[ -f $NGINX_FILE ]] || { echo "Missing $NGINX_FILE"; exit 1; }

  if sudo grep -q "server_name $DOMAIN;" "$NGINX_FILE"; then
    echo "$DOMAIN already in $NGINX_FILE, skipping append."
  else
    sudo cp "$NGINX_FILE" "$NGINX_FILE.bak.$(date +%F-%H%M%S)"
    sudo tee -a "$NGINX_FILE" >/dev/null <<EOF

# $NAME
server {
   server_name $DOMAIN;
   root $APP/public;

   index index.php;

   location / {
       try_files \$uri \$uri/ /index.php?\$query_string;
   }

   location ~ \.php\$ {
       try_files \$uri =404;
       fastcgi_pass unix:$PHP_SOCK;
       fastcgi_index index.php;
       fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
       include fastcgi_params;
   }
}
EOF
    echo "Appended server block for $DOMAIN to $NGINX_FILE (backup saved alongside)."
  fi
  echo "Opening nano to review (certbot will add the SSL parts after)."
  pause
  sudo nano "$NGINX_FILE"
  [[ -e $NGINX_ENABLED/$NGINX_NAME ]] || sudo ln -s "$NGINX_FILE" "$NGINX_ENABLED/$NGINX_NAME"
  run sudo nginx -t
  run sudo systemctl reload nginx
}

s_ssl() {
  echo "Make sure DNS for $DOMAIN points to this server."
  pause
  run sudo certbot --nginx -d "$DOMAIN"
  run sudo systemctl reload nginx
}

s_supconf() {
  command -v supervisorctl >/dev/null || run sudo apt-get install -y supervisor
  mkdir -p "$APP/storage/logs"
  touch "$APP/storage/logs/worker.log"
  sudo chown -R www-data:www-data "$APP/storage/logs"
  sudo chmod 755 "$APP/storage/logs"

  sudo tee "$SUP_CONF" >/dev/null <<EOF
[program:$NAME-worker]
process_name=%(program_name)s_%(process_num)02d
command=php $APP/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=$APP/storage/logs/worker.log
stopwaitsecs=3600
EOF
  echo "Opening nano to review $SUP_CONF"
  pause
  sudo nano "$SUP_CONF"
}

s_supstart() {
  run sudo supervisorctl reread
  run sudo supervisorctl update
  run sudo supervisorctl start "$NAME-worker:*"
  sudo supervisorctl status
}

s_cron() {
  if crontab -l 2>/dev/null | grep -qF "$APP"; then
    echo "Crontab already mentions $APP, not opening."
    return
  fi
  echo "Suggested line:  * * * * * cd $APP && php artisan schedule:run >> /dev/null 2>&1"
  pause
  crontab -e
}

s_finalenv() {
  cd "$APP" || exit 1
  echo "Opening .env once more for last tweaks, then clearing config cache."
  pause
  nano .env
  run php artisan config:clear
}

stage apt         "System update"                 s_apt
stage sshkey      "SSH key, config, authorized_keys" s_sshkey
stage clone       "Clone repo"                    s_clone
stage composer    "composer install"              s_composer
stage npm         "npm install"                   s_npm
stage env         ".env setup"                    s_env
stage keygen      "artisan key:generate"          s_keygen
stage migrate     "artisan migrate"               s_migrate
stage storagelink "artisan storage:link"          s_storagelink
stage config      "Config cache/clear"            s_config
stage perms       "Permissions"                   s_perms
stage build       "npm run build"                 s_build
stage nginx       "Nginx server block"            s_nginx
stage ssl         "SSL (certbot)"                 s_ssl
stage supconf     "Supervisor config"             s_supconf
stage supstart    "Supervisor start"              s_supstart
stage cron        "Cron scheduler"                s_cron
stage finalenv    "Final .env check"              s_finalenv

step "Done: https://$DOMAIN"
echo "To redo a stage: rm $MARK_DIR/<stage-id>   (ids: $(ls "$MARK_DIR" | grep -vx config | tr '\n' ' '))"