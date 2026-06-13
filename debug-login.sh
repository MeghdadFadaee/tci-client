#!/usr/bin/env bash

set -euo pipefail

BASE_URL="https://internet.tci.ir"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_PATH="$SCRIPT_DIR/.env"
RUN_DIR="$SCRIPT_DIR/debug-runs/$(date '+%Y%m%d-%H%M%S')"
COOKIE_JAR="$RUN_DIR/cookies.txt"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

extract_form_action() {
  perl -0ne '
    if (/<form\b[^>]*\baction\s*=\s*(["'\''])(.*?)\1/is) {
      print $2;
    }
  ' "$1"
}

extract_captcha_url() {
  perl -0ne '
    if (/<img\b(?=[^>]*\bid\s*=\s*(["'\''])loginCaptchaImage\1)[^>]*\bsrc\s*=\s*(["'\''])(.*?)\2/is) {
      print $3;
    }
  ' "$1"
}

request() {
  local name="$1"
  shift

  curl -sS --compressed -L \
    -b "$COOKIE_JAR" \
    -c "$COOKIE_JAR" \
    -D "$RUN_DIR/$name.headers" \
    -o "$RUN_DIR/$name.body" \
    -w 'http_code=%{http_code}\neffective_url=%{url_effective}\nredirects=%{num_redirects}\ncontent_type=%{content_type}\n' \
    "$@" >"$RUN_DIR/$name.meta"
}

display_captcha() {
  if command -v kitty >/dev/null 2>&1 && kitty +kitten icat "$RUN_DIR/captcha.jpg" 2>/dev/null; then
    return
  fi

  printf 'Open captcha: %s\n' "$RUN_DIR/captcha.jpg"
}

main() {
  local action_url
  local captcha_url
  local captcha

  require_command curl
  require_command perl

  if [[ ! -f "$ENV_PATH" ]]; then
    printf 'Missing environment file: %s\n' "$ENV_PATH" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$ENV_PATH"
  set +a

  : "${TCI_USERNAME:?TCI_USERNAME is not set in $ENV_PATH}"
  : "${TCI_PASSWORD:?TCI_PASSWORD is not set in $ENV_PATH}"

  umask 077
  mkdir -p "$RUN_DIR"
  printf '# Netscape HTTP Cookie File\n' >"$COOKIE_JAR"

  printf 'GET %s/panel\n' "$BASE_URL"
  request 01-login-page "$BASE_URL/panel"

  action_url="$(extract_form_action "$RUN_DIR/01-login-page.body")"
  captcha_url="$(extract_captcha_url "$RUN_DIR/01-login-page.body")"

  if [[ -z "$action_url" || -z "$captcha_url" ]]; then
    printf 'Could not extract login action or captcha URL. Inspect: %s\n' "$RUN_DIR" >&2
    exit 1
  fi

  printf 'GET captcha\n'
  request 02-captcha "$captcha_url"
  mv "$RUN_DIR/02-captcha.body" "$RUN_DIR/captcha.jpg"
  display_captcha
  read -r -p "Captcha: " captcha

  printf 'POST login\n'
  request 03-login-post \
    --data-urlencode "redirect=" \
    --data-urlencode "username=$TCI_USERNAME" \
    --data-urlencode "password=$TCI_PASSWORD" \
    --data-urlencode "captcha=$captcha" \
    --data-urlencode "LoginFromWeb=" \
    "$action_url"

  printf 'GET panel after login\n'
  request 04-panel-after-login "$BASE_URL/panel"

  printf '\nSaved diagnostic responses to:\n%s\n\n' "$RUN_DIR"
  printf 'Status summary:\n'
  for meta in "$RUN_DIR"/*.meta; do
    printf '\n%s\n' "$(basename "$meta")"
    cat "$meta"
  done
}

main "$@"
