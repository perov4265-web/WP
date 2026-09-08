#!/usr/bin/env bash
# lib/wordpress.sh — загрузка WordPress, wp-config.php, установка ядра, права доступа.
# shellcheck shell=bash

WP_CLI_BIN="/usr/local/bin/wp"
WP_URL_SCHEME="http"

wp_cli() {
  sudo -u www-data env HOME=/tmp WP_CLI_CACHE_DIR=/tmp/.wp-cli-cache \
    "$WP_CLI_BIN" --path="$WP_PATH" "$@"
}

install_wp_cli() {
  info "WP-CLI"
  if [[ -x "$WP_CLI_BIN" ]] && "$WP_CLI_BIN" --info >/dev/null 2>&1; then
    ok "WP-CLI уже установлен"; WP_CLI_OK=1; return 0
  fi
  step "Загрузка WP-CLI"
  if run curl -fsSL -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
     && php /tmp/wp-cli.phar --info >>"$LOG_FILE" 2>&1; then
    install -m 0755 /tmp/wp-cli.phar "$WP_CLI_BIN"
    WP_CLI_OK=1
    ok "WP-CLI установлен ($("$WP_CLI_BIN" --version --allow-root 2>/dev/null | head -n1))"
  else
    WP_CLI_OK=0
    warn "WP-CLI недоступен — установка будет выполнена встроенным способом (без WP-CLI)."
  fi
}

download_wordpress() {
  info "Загрузка WordPress"

  if [[ -d "$WP_PATH" ]] && [[ -n "$(ls -A "$WP_PATH" 2>/dev/null)" ]]; then
    warn "Каталог ${WP_PATH} не пуст."
    if [[ "${FORCE:-0}" == "1" ]] || confirm "Переместить его содержимое в резервную копию и продолжить?" "no"; then
      local bak
      bak="${WP_PATH}.bak-$(date +%Y%m%d%H%M%S)"
      mv "$WP_PATH" "$bak"
      ok "Старый каталог сохранён: ${bak}"
    else
      die "Установка остановлена: выберите другой каталог (--path) или домен."
    fi
  fi

  mkdir -p "$WP_PATH"
  chown www-data:www-data "$WP_PATH"

  if [[ "${WP_CLI_OK:-0}" == "1" ]]; then
    step "wp core download (локаль ${WP_LOCALE})"
    if ! wp_cli core download --locale="$WP_LOCALE" --force >>"$LOG_FILE" 2>&1; then
      warn "Загрузка локализованной сборки не удалась — берём международную версию."
      wp_cli core download --force >>"$LOG_FILE" 2>&1 || die "Не удалось загрузить WordPress."
    fi
  else
    step "Загрузка архива wordpress.org"
    run curl -fL --retry 3 -o /tmp/wordpress-latest.tar.gz https://wordpress.org/latest.tar.gz \
      || die "Не удалось скачать WordPress с wordpress.org (проверьте интернет)."
    run tar -xzf /tmp/wordpress-latest.tar.gz -C /tmp
    cp -a /tmp/wordpress/. "$WP_PATH"/
    rm -rf /tmp/wordpress /tmp/wordpress-latest.tar.gz
  fi
  [[ -f "${WP_PATH}/wp-includes/version.php" ]] || die "WordPress не распакован в ${WP_PATH}."
  ok "WordPress загружен в ${WP_PATH}"
}

fetch_salts() {
  local salts=""
  salts="$(curl -fsSL --max-time 20 https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null || true)"
  if [[ "$salts" == *"AUTH_KEY"* ]]; then
    printf '%s\n' "$salts"; return 0
  fi
  # автономный вариант: генерируем ключи локально
  local k
  for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
    printf "define('%s', '%s');\n" "$k" "$(rand_pass 64)"
  done
}

php_quote() { # экранирование для строки PHP в одинарных кавычках
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  printf '%s' "$s"
}

configure_wordpress() {
  info "Создание wp-config.php"
  local cfg="${WP_PATH}/wp-config.php"
  local q_name q_user q_pass q_prefix q_locale
  q_name="$(php_quote "$DB_NAME")"
  q_user="$(php_quote "$DB_USER")"
  q_pass="$(php_quote "$DB_PASS")"
  q_prefix="$(php_quote "$TABLE_PREFIX")"
  q_locale="$(php_quote "$WP_LOCALE")"

  {
    echo "<?php"
    echo "/**"
    echo " * Конфигурация WordPress — создано wp-autoinstall $(date '+%F %T')."
    echo " */"
    echo ""
    echo "define( 'DB_NAME', '${q_name}' );"
    echo "define( 'DB_USER', '${q_user}' );"
    echo "define( 'DB_PASSWORD', '${q_pass}' );"
    echo "define( 'DB_HOST', 'localhost' );"
    echo "define( 'DB_CHARSET', 'utf8mb4' );"
    echo "define( 'DB_COLLATE', '' );"
    echo ""
    echo "/* Уникальные ключи и соли. */"
    fetch_salts
    echo ""
    echo "\$table_prefix = '${q_prefix}';"
    echo ""
    echo "define( 'WP_HOME', '${WP_URL_SCHEME}://${SITE_DOMAIN}' );"
    echo "define( 'WP_SITEURL', '${WP_URL_SCHEME}://${SITE_DOMAIN}' );"
    echo "define( 'WPLANG', '${q_locale}' );"
    if [[ "${WP_DEBUG_MODE:-no}" == "yes" ]]; then
      echo "define( 'WP_DEBUG', true );"
      echo "define( 'WP_DEBUG_LOG', true );      // журнал: wp-content/debug.log"
      echo "define( 'WP_DEBUG_DISPLAY', false ); // ошибки не показываем посетителям"
      echo "@ini_set( 'display_errors', '0' );"
    else
      echo "define( 'WP_DEBUG', false );"
      echo "// Диагностика: раскомментируйте три строки ниже, ошибки лягут"
      echo "// в wp-content/debug.log и не будут видны посетителям."
      echo "// define( 'WP_DEBUG', true );"
      echo "// define( 'WP_DEBUG_LOG', true );"
      echo "// define( 'WP_DEBUG_DISPLAY', false );"
    fi
    echo "define( 'FS_METHOD', 'direct' );"
    echo "define( 'WP_MEMORY_LIMIT', '${PHP_MEMORY_LIMIT:-256M}' );"
    echo "define( 'DISALLOW_FILE_EDIT', true );"
    echo "define( 'WP_AUTO_UPDATE_CORE', 'minor' );"
    echo ""
    echo "if ( ! defined( 'ABSPATH' ) ) {"
    echo "    define( 'ABSPATH', __DIR__ . '/' );"
    echo "}"
    echo ""
    echo "require_once ABSPATH . 'wp-settings.php';"
  } > "$cfg"

  chown www-data:www-data "$cfg"
  chmod 640 "$cfg"
  ok "wp-config.php создан"
}

install_wordpress_core() {
  info "Установка WordPress"
  if [[ "${WP_CLI_OK:-0}" == "1" ]]; then
    if wp_cli core is-installed >/dev/null 2>&1; then
      ok "WordPress уже установлен в этой базе"
    else
      wp_cli core install \
        --url="${WP_URL_SCHEME}://${SITE_DOMAIN}" \
        --title="$SITE_TITLE" \
        --admin_user="$WP_ADMIN_USER" \
        --admin_password="$WP_ADMIN_PASS" \
        --admin_email="$WP_EMAIL" \
        --skip-email >>"$LOG_FILE" 2>&1 || die "wp core install завершился с ошибкой (см. $LOG_FILE)."
      ok "Ядро WordPress установлено"
    fi

    if [[ "$WP_LOCALE" != "en_US" ]]; then
      if wp_cli language core install "$WP_LOCALE" --activate >>"$LOG_FILE" 2>&1; then
        ok "Языковой пакет ${WP_LOCALE} установлен"
      else
        warn "Не удалось установить языковой пакет ${WP_LOCALE}."
      fi
    fi

    wp_cli rewrite structure '/%postname%/' >>"$LOG_FILE" 2>&1 || true
    wp_cli option update timezone_string 'UTC' >>"$LOG_FILE" 2>&1 || true
    wp_cli plugin delete hello >>"$LOG_FILE" 2>&1 || true
    ok "Постоянные ссылки: /%postname%/"
  else
    install_wordpress_core_fallback
  fi
}

# Установка без WP-CLI: вызываем wp_install() напрямую через PHP CLI.
install_wordpress_core_fallback() {
  step "Установка ядра встроенным способом"
  local php_script="/tmp/wp-install-$$.php"
  cat > "$php_script" <<'PHPEOF'
<?php
$path   = $argv[1];
$title  = $argv[2];
$user   = $argv[3];
$pass   = $argv[4];
$email  = $argv[5];
$locale = $argv[6];

define( 'WP_INSTALLING', true );
require_once $path . '/wp-load.php';
require_once ABSPATH . 'wp-admin/includes/upgrade.php';
require_once ABSPATH . 'wp-includes/wp-db.php';

if ( is_blog_installed() ) {
    echo "already-installed\n";
    exit( 0 );
}
$result = wp_install( $title, $user, $email, true, '', $pass, $locale );
if ( is_wp_error( $result ) ) {
    fwrite( STDERR, $result->get_error_message() . "\n" );
    exit( 1 );
}
update_option( 'permalink_structure', '/%postname%/' );
echo "installed\n";
PHPEOF
  chmod 644 "$php_script"
  # shellcheck disable=SC2024  # лог пишется root-шеллом, а не www-data
  sudo -u www-data env HOME=/tmp php "$php_script" \
    "$WP_PATH" "$SITE_TITLE" "$WP_ADMIN_USER" "$WP_ADMIN_PASS" "$WP_EMAIL" "$WP_LOCALE" >>"$LOG_FILE" 2>&1 \
    || die "Не удалось выполнить установку WordPress (см. $LOG_FILE)."
  rm -f "$php_script"
  ok "Ядро WordPress установлено"
}

harden_permissions() {
  info "Права доступа"
  chown -R www-data:www-data "$WP_PATH"
  find "$WP_PATH" -type d -exec chmod 755 {} +
  find "$WP_PATH" -type f -exec chmod 644 {} +
  [[ -f "${WP_PATH}/wp-config.php" ]] && chmod 640 "${WP_PATH}/wp-config.php"
  mkdir -p "${WP_PATH}/wp-content/uploads"
  chown -R www-data:www-data "${WP_PATH}/wp-content"
  ok "Владелец www-data, каталоги 755, файлы 644, wp-config.php 640"
}

# Переключение адреса сайта на https после выпуска сертификата
switch_site_to_https() {
  WP_URL_SCHEME="https"
  local cfg="${WP_PATH}/wp-config.php"
  sed -i "s#'WP_HOME', 'http://#'WP_HOME', 'https://#; s#'WP_SITEURL', 'http://#'WP_SITEURL', 'https://#" "$cfg"
  if [[ "${WP_CLI_OK:-0}" == "1" ]]; then
    wp_cli option update home "https://${SITE_DOMAIN}" >>"$LOG_FILE" 2>&1 || true
    wp_cli option update siteurl "https://${SITE_DOMAIN}" >>"$LOG_FILE" 2>&1 || true
  fi
  ok "Адрес сайта переключён на https"
}
