#!/usr/bin/env bash
# lib/security.sh — ловушки для ботов, fail2ban, защитный mu-плагин, SSH по ключу.
# shellcheck shell=bash
# shellcheck disable=SC2034  # переменные используются в соседних модулях
#
# Откуда взялось (опыт эксплуатации нескольких боевых серверов, осень 2026):
#   * пароли к wp-login подбирают медленно и с разных адресов одной /24 —
#     68 попыток с 25 адресов раз в 8–10 минут; правило «5 за 5 минут» этого
#     не видит, нужно окно в час и нарастающий бан (час → сутки → неделя);
#   * сканеры ищут .env, .git, бэкапы wp-config, phpinfo, phpunit — обычный
#     посетитель туда не ходит никогда, значит, одного такого запроса
#     достаточно для бана: это и есть ловушка;
#   * плохие боты читают robots.txt и идут именно в Disallow — скрытая ссылка
#     на запрещённый каталог ловит их, а Google и Яндекс туда не заходят;
#   * ИИ-сборщики (GPTBot, ClaudeBot, Bytespider, Meta) выедали PHP-FPM
#     на 2 ядрах: им — общий на всё семейство лимит и запрет на служебные
#     адреса (wp-login, wp-json, wp-admin), robots.txt Meta для них игнорирует;
#   * facebookexternalhit не трогаем — это превью ссылок, а не сборщик;
#   * свой адрес — в ignoreip, иначе первая же опечатка в пароле запирает
#     администратора вместе с ботами;
#   * в sshd побеждает ПЕРВОЕ значение, а файлы sshd_config.d читаются по
#     алфавиту — поэтому наш файл называется 01-*, иначе его перебьют
#     50-cloud-init.conf и прочие.

TRAP_LOG="/var/log/nginx/wp-trap.log"
TRAP_PATH="${TRAP_PATH:-}"
AI_BOT_RATE="${AI_BOT_RATE:-30r/m}"
ADMIN_IPS="${ADMIN_IPS:-}"

# Адрес, с которого сейчас зашли по SSH: под sudo SSH_CLIENT стёрт, берём из who
current_ssh_ip() {
  local ip="${SSH_CLIENT:-}"; ip="${ip%% *}"
  [[ -n "$ip" ]] || ip="$(who -m 2>/dev/null | sed -n 's/.*(\([0-9a-fA-F.:]*\)).*/\1/p' | head -n1)"
  printf '%s' "$ip"
}

trap_path_init() {
  [[ -n "$TRAP_PATH" ]] || TRAP_PATH="/archive-$(rand_suffix 8)/"
}

# ---------------------------------------------------------- nginx: общие map
# Вызывается из nginx_global_snippet и дописывается в тот же файл.
# shellcheck disable=SC2016  # $-переменные принадлежат nginx
nginx_bot_maps() {
  local pma_skip=""
  [[ "${INSTALL_PMA:-no}" == "yes" ]] && pma_skip='    "~*^/phpmyadmin/"                                   0;'
  cat <<NGX

# ---- ловушки (wp-autoinstall) --------------------------------------------
# Адреса, которых на этом сервере нет и которые просит только сканер.
# Попадание: соединение рвётся (444), строка уходит в ${TRAP_LOG},
# fail2ban банит адрес с первого раза.
map \$uri \$wp_trap_uri {
    default                                             0;
${pma_skip}
    "~*^/\\.(env|git|svn|hg|aws|ssh|htpasswd|DS_Store|vscode|idea)"  1;
    "~*^/wp-config\\.php"                               1;
    "~*^/\\.?wp-config\\.(bak|old|orig|save|swp|txt)"   1;
    "~*\\.sql(\\.gz)?\$"                                1;
    "~*^/[^/]+\\.(bak|old|swp)\$"                       1;
    "~*^/(backup|dump|db|database|site|www)\\.(zip|tar|gz|tgz|rar|7z)\$" 1;
    "~*/phpunit\\.xml"                                  1;
    "~*^/(phpinfo|info|php_info|shell|wso|alfa|c99|r57|adminer|eval-stdin)\\.php" 1;
    "~*/vendor/phpunit/"                                1;
    "~*^/(phpmyadmin|pma|myadmin|mysqladmin|dbadmin)(/|\$)" 1;
    "~*^/(cgi-bin|boaform|HNAP1|actuator|solr|owa|ecp|druid|telescope|_ignition|server-status|manager/html|remote/login)" 1;
}

# Сканеры, которые честно называют себя
map \$http_user_agent \$wp_trap_ua {
    default                                             0;
    "~*(sqlmap|nikto|nmap|masscan|zgrab|wpscan|dirbuster|gobuster|nuclei|acunetix|nessus|openvas|wfuzz|ffuf|feroxbuster)" 1;
}

map "\$wp_trap_uri\$wp_trap_ua" \$wp_trap {
    "00"    0;
    default 1;
}

# ---- ИИ-сборщики и агрессивные краулеры ------------------------------------
# Ключ — имя семейства: вся сеть бота делит одну корзину, иначе тысяча
# адресов Meta получает тысячу лимитов. facebookexternalhit сюда не входит.
map \$http_user_agent \$ai_bot_key {
    default "";
    "~*(?<aibot>gptbot|chatgpt-user|oai-searchbot|claudebot|claude-web|anthropic-ai|bytespider|meta-externalagent|meta-webindexer|amazonbot|perplexitybot|ccbot|petalbot|imagesiftbot|dataforseobot|ahrefsbot|semrushbot|mj12bot|blexbot)" \$aibot;
}
limit_req_zone \$ai_bot_key zone=aibots:10m rate=${AI_BOT_RATE};

# Служебные адреса этим ботам не нужны вовсе
map "\$ai_bot_key:\$uri" \$ai_bot_deny {
    default 0;
    "~^.+:/(wp-login\\.php|wp-json/|wp-admin/|xmlrpc\\.php)" 1;
}

# ---- вход в WordPress ------------------------------------------------------
# Лимит только на POST: просмотр формы входа не считается.
map \$request_method \$wp_login_key {
    default "";
    POST    \$binary_remote_addr;
}
limit_req_zone \$wp_login_key zone=wplogin:10m rate=6r/m;
NGX
}

# ------------------------------------------------- nginx: правила внутри server
# shellcheck disable=SC2016
nginx_bot_server_rules() {
  [[ "${BOT_TRAPS:-no}" == "yes" ]] || return 0
  cat <<NGX
    # ---- ловушки и боты (wp-autoinstall) ----
    access_log ${TRAP_LOG} wp_timed if=\$wp_trap;
    if (\$wp_trap)     { return 444; }
    if (\$ai_bot_deny) { return 403; }

    # Скрытая ссылка-приманка: на неё ведёт невидимая ссылка в подвале сайта,
    # а robots.txt запрещает этот каталог. Честный робот сюда не придёт.
    location ^~ ${TRAP_PATH} {
        access_log ${TRAP_LOG} wp_timed;
        return 444;
    }
NGX
}

# Отдельный location для wp-login.php: лимит на POST с одного адреса
# shellcheck disable=SC2016
nginx_login_location() {
  cat <<'NGX'

    location = /wp-login.php {
        limit_req zone=wplogin burst=5 nodelay;
        limit_req zone=aibots burst=10 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass __FPM_PASS__;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
NGX
}

# ---------------------------------------------------------------- fail2ban
setup_fail2ban() {
  apt_install fail2ban
  # без python3-systemd backend=systemd на 22.04 молча не читает журнал
  apt_install_optional python3-systemd

  local access_log ignore="127.0.0.1/8 ::1" ip
  if [[ "$WEB_SERVER" == "nginx" ]]; then
    access_log="/var/log/nginx/${SITE_DOMAIN}.access.log"
  else
    access_log="/var/log/apache2/${SITE_DOMAIN}-access.log"
  fi
  touch "$access_log" 2>/dev/null || true
  mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d

  ip="$(current_ssh_ip)"
  for ip in $ip ${SSH_ALLOW_FROM:-} ${ADMIN_IPS//,/ }; do
    [[ -n "$ip" && " $ignore " != *" $ip "* ]] && ignore+=" $ip"
  done

  # Только неудачный вход: при ошибке wp-login отдаёт форму заново (200),
  # при успехе — 302. 429 — это уже упёрлись в лимит nginx.
  cat > /etc/fail2ban/filter.d/wordpress-auth.conf <<'F2B'
# Создано wp-autoinstall: подбор паролей к wp-login.php и xmlrpc.php
[Definition]
failregex = ^<HOST> .* "POST [^"]*/wp-login\.php[^"]*" (?:200|429)
            ^<HOST> .* "POST [^"]*/xmlrpc\.php
ignoreregex =
F2B

  cat > /etc/fail2ban/filter.d/wp-trap.conf <<'F2B'
# Создано wp-autoinstall: в журнал ловушек попадают только сканеры
[Definition]
failregex = ^<HOST>
ignoreregex =
F2B

  # Бан нарастает: час → сутки → неделя. База fail2ban должна помнить
  # прошлые баны дольше недели, иначе «нарастание» обнуляется каждые сутки.
  cat > /etc/fail2ban/fail2ban.d/wp-autoinstall.local <<'F2B'
[Definition]
dbpurgeage = 8d
F2B

  {
    printf '# Создано wp-autoinstall\n'
    printf '[DEFAULT]\n'
    printf 'ignoreip = %s\n' "$ignore"
    printf 'bantime  = 1h\n'
    printf 'bantime.increment = true\n'
    printf 'bantime.multipliers = 1 24 168\n'
    printf 'bantime.maxtime = 1w\n'
    if [[ "${INSTALL_FIREWALL:-no}" == "yes" ]]; then
      printf '\n[sshd]\nenabled  = true\nbackend  = systemd\nmaxretry = 3\nfindtime = 1h\n'
      printf '\n[wordpress-auth]\nenabled  = true\nfilter   = wordpress-auth\nport     = http,https\n'
      printf 'logpath  = %s\nbackend  = auto\nmaxretry = 6\nfindtime = 1h\n' "$access_log"
    fi
    if [[ "${BOT_TRAPS:-no}" == "yes" ]]; then
      touch "$TRAP_LOG"
      printf '\n[wp-trap]\nenabled  = true\nfilter   = wp-trap\nlogpath  = %s\nbackend  = auto\n' "$TRAP_LOG"
      printf 'maxretry = 1\nfindtime = 1d\nbantime  = %s\nbanaction = %%(banaction_allports)s\n' "${TRAP_BANTIME:-1d}"
    fi
  } > /etc/fail2ban/jail.d/wp-autoinstall.local

  run systemctl enable fail2ban || true
  if run systemctl restart fail2ban; then
    ok "fail2ban: $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"
    ok "Не банятся: ${ignore}"
  else
    warn "fail2ban не запустился — проверьте: systemctl status fail2ban"
  fi
}

# ------------------------------------------------------- защитный mu-плагин
install_guard_plugin() {
  local dir="${WP_PATH}/wp-content/mu-plugins" f
  f="${dir}/wp-autoinstall-guard.php"
  mkdir -p "$dir"
  cat > "$f" <<'PHP'
<?php
/**
 * Plugin Name: wp-autoinstall guard
 * Description: Закрывает перебор имён пользователей, XML-RPC и подсказки при входе; ставит ссылку-приманку для ботов.
 */
defined( 'ABSPATH' ) || exit;

// XML-RPC — главный вход для подбора паролей «пачкой» (system.multicall)
add_filter( 'xmlrpc_enabled', '__return_false' );
add_filter( 'wp_headers', function ( $h ) { unset( $h['X-Pingback'] ); return $h; } );

// Имена пользователей не раздаём: /?author=1 и /wp-json/wp/v2/users
add_action( 'template_redirect', function () {
    if ( ! is_user_logged_in() && isset( $_GET['author'] ) ) {
        wp_safe_redirect( home_url( '/' ), 301 );
        exit;
    }
} );
add_filter( 'rest_endpoints', function ( $e ) {
    if ( ! is_user_logged_in() ) {
        unset( $e['/wp/v2/users'], $e['/wp/v2/users/(?P<id>[\d]+)'] );
    }
    return $e;
} );

// Не подсказывать, что именно неверно — логин или пароль
add_filter( 'login_errors', function () { return 'Неверный логин или пароль.'; } );

remove_action( 'wp_head', 'wp_generator' );

// Ссылка-приманка: людям не видна, честные роботы не идут (robots.txt)
add_action( 'wp_footer', function () {
    echo '<a href="__TRAP_PATH__" rel="nofollow" style="display:none" aria-hidden="true" tabindex="-1">archive</a>';
} );
PHP
  if [[ "${BOT_TRAPS:-no}" == "yes" ]]; then
    sed -i "s#__TRAP_PATH__#${TRAP_PATH}#" "$f"
  else
    # без ловушки в nginx ссылка бессмысленна — вырезаем блок целиком
    sed -i '/^\/\/ Ссылка-приманка/,$d' "$f"
  fi
  chown -R www-data:www-data "$dir"
  chmod 644 "$f"
  ok "Защитный mu-плагин: ${f}"
}

# -------------------------------------------------------------- SSH по ключу
harden_ssh() {
  [[ "${SSH_HARDEN:-no}" == "yes" ]] || return 0
  local keys=0 u home
  for u in root ${SUDO_USER:-}; do
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -s "${home}/.ssh/authorized_keys" ]] && keys=1
  done
  if (( keys == 0 )); then
    warn "SSH оставлен с паролем: ни у root, ни у ${SUDO_USER:-текущего пользователя} нет authorized_keys."
    warn "Сначала положите ключ и проверьте вход по нему, потом запустите с --ssh-harden."
    return 0
  fi
  grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config \
    || { warn "sshd_config не подключает sshd_config.d — настройку SSH пропускаю."; return 0; }

  local f=/etc/ssh/sshd_config.d/01-wp-autoinstall.conf
  cat > "$f" <<'SSHD'
# Создано wp-autoinstall. Имя на 01 нарочно: у sshd выигрывает первое
# значение, а 50-cloud-init.conf и подобные иначе вернули бы пароли.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
SSHD
  if ! sshd -t >>"$LOG_FILE" 2>&1; then
    rm -f "$f"; warn "sshd -t не принял настройку — файл убран, SSH не тронут."; return 0
  fi
  run systemctl reload ssh || run systemctl reload sshd || true
  ok "SSH: вход только по ключу, MaxAuthTries 3 (${f})"
  warn "Не закрывайте текущую сессию, пока не проверите вход по ключу в новом окне."
}

# ------------------------------------------------------------- общий шаг
setup_protection() {
  [[ "${BOT_TRAPS:-no}" == "yes" || "${INSTALL_FIREWALL:-no}" == "yes" || "${SSH_HARDEN:-no}" == "yes" ]] || return 0
  info "Защита от ботов и атак"
  install_guard_plugin
  if [[ "${BOT_TRAPS:-no}" == "yes" || "${INSTALL_FIREWALL:-no}" == "yes" ]]; then
    setup_fail2ban
  fi
  harden_ssh
}
