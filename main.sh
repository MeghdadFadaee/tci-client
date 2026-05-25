#!/usr/bin/env bash

set -euo pipefail

BASE_URL="https://internet.tci.ir"
CWD="$(pwd)"
ENV_PATH="$CWD/.env"
CAPTCHA_PATH="$CWD/captcha.jpg"
DASHBOARD_PATH="$CWD/dashboard.html"
COOKIE_HOST="internet.tci.ir"

COOKIE_JAR="$(mktemp "${TMPDIR:-/tmp}/tci-cookies.XXXXXX")"
LOGIN_HTML="$(mktemp "${TMPDIR:-/tmp}/tci-login.XXXXXX")"

cleanup() {
  rm -f "$COOKIE_JAR" "$LOGIN_HTML"
}
trap cleanup EXIT

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
}

load_env() {
  if [[ -f "$ENV_PATH" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_PATH"
    set +a
  fi
}

quote_env_value() {
  local escaped

  escaped="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g')"
  printf '"%s"' "$escaped"
}

set_env_key() {
  local key="$1"
  local value="$2"
  local quoted
  local replacement_file
  local tmp_file

  quoted="$(quote_env_value "$value")"
  replacement_file="$(mktemp "${TMPDIR:-/tmp}/tci-env-replacement.XXXXXX")"
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/tci-env.XXXXXX")"
  printf '%s=%s\n' "$key" "$quoted" >"$replacement_file"

  if [[ -f "$ENV_PATH" ]]; then
    awk -v key="$key" -v replacement_file="$replacement_file" '
      BEGIN {
        getline replacement < replacement_file
        close(replacement_file)
      }
      skip_multiline {
        if ($0 !~ "^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=") {
          next
        }
        skip_multiline = 0
      }
      $0 ~ "^[[:space:]]*(export[[:space:]]+)?" key "=" {
        print replacement
        found = 1
        if ($0 ~ "^[[:space:]]*(export[[:space:]]+)?" key "=[\x22\x27]" && $0 !~ /[\x22\x27][[:space:]]*$/) {
          skip_multiline = 1
        }
        next
      }
      { print }
      END {
        if (!found) {
          print replacement
        }
      }
    ' "$ENV_PATH" >"$tmp_file"
  else
    cp "$replacement_file" "$tmp_file"
  fi

  mv "$tmp_file" "$ENV_PATH"
  rm -f "$replacement_file"
}

init_cookie_jar() {
  printf '# Netscape HTTP Cookie File\n' >"$COOKIE_JAR"

  if [[ -z "${TCI_COOKIES:-}" ]]; then
    return 1
  fi

  if ! jq -e 'type == "object" and length > 0' <<<"$TCI_COOKIES" >/dev/null 2>&1; then
    return 1
  fi

  jq -r --arg domain "$COOKIE_HOST" '
    to_entries[]
    | [$domain, "FALSE", "/", "FALSE", "0", .key, (.value | tostring)]
    | @tsv
  ' <<<"$TCI_COOKIES" >>"$COOKIE_JAR"
}

save_cookies() {
  local cookies_json

  cookies_json="$(
    awk -F '\t' 'NF >= 7 { print $6 "\t" $7 }' "$COOKIE_JAR" |
      jq -Rnc '
        reduce inputs as $line ({};
          ($line | split("\t")) as $parts
          | if ($parts | length) >= 2
            then . + {($parts[0]): $parts[1]}
            else .
            end
        )
      '
  )"

  set_env_key "TCI_COOKIES" "$cookies_json"
}

curl_request() {
  curl -fsSL --compressed -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"
}

absolute_url() {
  local url="$1"

  case "$url" in
    http://* | https://*)
      printf '%s\n' "$url"
      ;;
    //*)
      printf 'https:%s\n' "$url"
      ;;
    /*)
      printf '%s%s\n' "$BASE_URL" "$url"
      ;;
    *)
      printf '%s/%s\n' "$BASE_URL" "$url"
      ;;
  esac
}

extract_form_action() {
  perl -CSD -Mutf8 -0ne '
    if (/<form\b[^>]*\baction\s*=\s*([\x22\x27])(.*?)\1/is) {
      print $2;
    } elsif (/<form\b[^>]*\baction\s*=\s*([^\x22\x27\s>]+)/is) {
      print $1;
    }
  ' "$1"
}

extract_captcha_url() {
  perl -CSD -Mutf8 -0ne '
    if (/<img\b(?=[^>]*\bid\s*=\s*[\x22\x27]loginCaptchaImage[\x22\x27])[^>]*\bsrc\s*=\s*([\x22\x27])(.*?)\1/is) {
      print $2;
    }
  ' "$1"
}

contains_login_marker() {
  local body="$1"

  [[ "${body,,}" == *logout* || "$body" == *خروج* ]]
}

is_logged_in() {
  local response

  response="$(curl_request "$BASE_URL/panel")" || return 1
  contains_login_marker "$response"
}

login() {
  local action_url
  local captcha_url
  local captcha
  local login_response

  : "${TCI_USERNAME:?TCI_USERNAME is not set in $ENV_PATH}"
  : "${TCI_PASSWORD:?TCI_PASSWORD is not set in $ENV_PATH}"

  curl_request "$BASE_URL/panel" >"$LOGIN_HTML"

  action_url="$(extract_form_action "$LOGIN_HTML")"
  captcha_url="$(extract_captcha_url "$LOGIN_HTML")"

  if [[ -z "$action_url" ]]; then
    printf 'Login form action not found\n' >&2
    return 1
  fi

  if [[ -z "$captcha_url" ]]; then
    printf 'Login captcha image not found\n' >&2
    return 1
  fi

  action_url="$(absolute_url "$action_url")"
  captcha_url="$(absolute_url "$captcha_url")"

  curl_request "$captcha_url" >"$CAPTCHA_PATH"

  if ! command -v kitty >/dev/null 2>&1; then
    printf 'kitty icat not available\n' >&2
    return 1
  fi

  kitty +kitten icat "$CAPTCHA_PATH"
  read -r -p "Captcha: " captcha

  login_response="$(
    curl -fsSL --compressed -L \
      -b "$COOKIE_JAR" \
      -c "$COOKIE_JAR" \
      --data-urlencode "username=$TCI_USERNAME" \
      --data-urlencode "password=$TCI_PASSWORD" \
      --data-urlencode "captcha=$captcha" \
      --data-urlencode "redirect=" \
      --data-urlencode "LoginFromWeb=1" \
      "$action_url"
  )" || return 1

  if contains_login_marker "$login_response"; then
    save_cookies
    return 0
  fi

  return 1
}

ensure_login() {
  if init_cookie_jar; then
    if is_logged_in; then
      printf 'Session still valid ✅\n'
      return 0
    fi

    printf 'Session expired ❌\n'
  fi

  login
}

extract_traffic() {
  perl -CSD -Mutf8 -0ne '
    my $key = "میزان ترافیک رزرو شما";

    while (m{(<h5\b[^>]*>.*?</h5>)}sig) {
      my $block = $1;
      next unless index($block, $key) >= 0;

      $block =~ s/<[^>]+>/ /g;
      $block =~ s/&nbsp;|&#160;/ /gi;
      $block =~ tr/۰۱۲۳۴۵۶۷۸۹/0123456789/;
      $block =~ s/میزان ترافیک رزرو شما/Reserved Traffic/g;
      $block =~ s/گیگابایت/GB/g;
      $block =~ s/مگابایت/MB/g;
      $block =~ s/:/: /g;
      $block =~ s/\s+/ /g;
      $block =~ s/^\s+|\s+$//g;

      my @parts = split /\s+/, $block;
      if (@parts >= 2) {
        print join(" ", split //, $parts[-2]), " ", $parts[-1], "\n";
      }
      last;
    }
  ' "$1"
}

terminal_cols() {
  local cols="${COLUMNS:-}"

  if [[ -z "$cols" && -t 1 ]] && command -v tput >/dev/null 2>&1; then
    cols="$(tput cols 2>/dev/null || true)"
  fi

  if [[ ! "$cols" =~ ^[0-9]+$ || "$cols" -lt 1 ]]; then
    cols=150
  fi

  printf '%s\n' "$cols"
}

center_line() {
  local line="$1"
  local cols="$2"
  local width

  width="${#line}"
  if ((width < cols)); then
    printf '%*s%s\n' "$(((cols - width) / 2))" '' "$line"
  else
    printf '%s\n' "$line"
  fi
}

large_glyph() {
  case "$1" in
    0)
      cat <<'GLYPH_0'
   ,a8888a,
 ,8P"'  `"Y8,
,8P        Y8,
88          88
88          88
`8b        d8'
 `8ba,  ,ad8'
   "Y8888P"
GLYPH_0
      ;;
    1)
      cat <<'GLYPH_1'
    88
  ,d88
888888
    88
    88
    88
    88
    88
GLYPH_1
      ;;
    2)
      cat <<'GLYPH_2'
 ad888888b,
d8"     "88
        a8P
     ,d8P"
   a8P"
 a8P'
d8"
88888888888
GLYPH_2
      ;;
    3)
      cat <<'GLYPH_3'
 ad888888b,
d8"     "88
        a8P
     aad8"
     ""Y8,
        "8b
Y8,     a88
 "Y888888P'
GLYPH_3
      ;;
    4)
      cat <<'GLYPH_4'
        ,d8
      ,d888
    ,d8" 88
  ,d8"   88
,d8"     88
8888888888888
         88
         88
GLYPH_4
      ;;
    5)
      cat <<'GLYPH_5'
8888888888
88
88  ____
88a8PPPP8b,
PP"     `8b
         d8
Y8a     a8P
 "Y88888P"
GLYPH_5
      ;;
    6)
      cat <<'GLYPH_6'
  ad8888ba,
 8P'    "Y8
d8
88,dd888bb,
88P'    `8b
88       d8
88a     a8P
 "Y88888P"
GLYPH_6
      ;;
    7)
      cat <<'GLYPH_7'
888888888888
        ,8P'
       d8"
     ,8P'
    d8"
  ,8P'
 d8"
8P'
GLYPH_7
      ;;
    8)
      cat <<'GLYPH_8'
 ad88888ba
d8"     "8b
Y8a     a8P
 "Y8aaa8P"
 ,d8"""8b,
d8"     "8b
Y8a     a8P
 "Y88888P"
GLYPH_8
      ;;
    9)
      cat <<'GLYPH_9'
 ad88888ba
d8"     "88
8P       88
Y8,    ,d88
 "PPPPPP"88
         8P
8b,    a8P
`"Y8888P'
GLYPH_9
      ;;
    .)
      cat <<'GLYPH_DOT'






888
888
GLYPH_DOT
      ;;
    G)
      cat <<'GLYPH_G'
  ,ad8888ba,
 d8"'    `"8b
d8'
88
88      88888
Y8,        88
 Y8a.    .a88
  `"Y88888P"
GLYPH_G
      ;;
    B)
      cat <<'GLYPH_B'
88888888ba
88      "8b
88      ,8P
88aaaaaa8P'
88""""""8b,
88      `8b
88      a8P
88888888P"
GLYPH_B
      ;;
    M)
      cat <<'GLYPH_M'
88b           d88
888b         d888
88`8b       d8'88
88 `8b     d8' 88
88  `8b   d8'  88
88   `8b d8'   88
88    `888'    88
88     `8'     88
GLYPH_M
      ;;
    ' ')
      printf '%s\n' \
        '    ' \
        '    ' \
        '    ' \
        '    ' \
        '    ' \
        '    ' \
        '    ' \
        '    '
      ;;
    *)
      cat <<'GLYPH_UNKNOWN'
 ad888888b,
d8"     "88
        a8P
     ,d8P"
   a8P"

   888
   888
GLYPH_UNKNOWN
      ;;
  esac
}

print_large_ascii() {
  local text="${1^^}"
  local cols
  local char
  local glyph
  local glyph_width
  local glyph_line
  local padded
  local -a glyph_lines
  local -a rows=('' '' '' '' '' '' '' '')

  for ((i = 0; i < ${#text}; i++)); do
    char="${text:i:1}"
    mapfile -t glyph_lines < <(large_glyph "$char")

    glyph_width=0
    for ((row = 0; row < 8; row++)); do
      glyph_line="${glyph_lines[$row]:-}"
      if ((${#glyph_line} > glyph_width)); then
        glyph_width="${#glyph_line}"
      fi
    done

    for ((row = 0; row < 8; row++)); do
      printf -v padded '%-*s' "$glyph_width" "${glyph_lines[$row]:-}"
      rows[$row]+="$padded "
    done
  done

  cols="$(terminal_cols)"
  for glyph in "${rows[@]}"; do
    center_line "${glyph%"${glyph##*[![:space:]]}"}" "$cols"
  done
}

space_characters() {
  local text="$1"
  local output=""
  local char
  local i

  for ((i = 0; i < ${#text}; i++)); do
    char="${text:i:1}"
    if [[ -n "$output" ]]; then
      output+=" "
    fi
    output+="$char"
  done

  printf '%s\n' "$output"
}

spaced_display_text() {
  local text="$1"
  local unit
  local number
  local last_index
  local -a parts

  read -r -a parts <<<"$text"
  if ((${#parts[@]} > 1)); then
    last_index=$((${#parts[@]} - 1))
    unit="${parts[$last_index]}"
    if [[ "$unit" =~ ^[[:alpha:]]+$ ]]; then
      unset "parts[$last_index]"
      number="${parts[*]}"
      number="${number//[[:space:]]/}"
      printf '%s %s\n' "$(space_characters "$number")" "$unit"
      return
    fi
  fi

  space_characters "$text"
}

render_banner() {
  local output

  if output="$("$@" 2>/dev/null)"; then
    printf '%s\n' "$output"
    return 0
  fi

  return 1
}

print_big() {
  local text="$1"
  local display_text

  display_text="$(spaced_display_text "$text")"

  printf '\033[92m\n'
  if [[ -x "$CWD/venv/bin/pyfiglet" ]] && render_banner "$CWD/venv/bin/pyfiglet" -f univers -w 150 -j center "$display_text"; then
    :
  elif [[ -x "$CWD/venv/bin/pyfiglet" ]] && render_banner "$CWD/venv/bin/pyfiglet" -f standard -w 150 -j center "$display_text"; then
    :
  elif command -v pyfiglet >/dev/null 2>&1 && render_banner pyfiglet -f univers -w 150 -j center "$display_text"; then
    :
  elif command -v pyfiglet >/dev/null 2>&1 && render_banner pyfiglet -f standard -w 150 -j center "$display_text"; then
    :
  elif command -v figlet >/dev/null 2>&1 && render_banner figlet -f univers -w 150 -c "$display_text"; then
    :
  elif command -v figlet >/dev/null 2>&1 && render_banner figlet -w 150 -c "$display_text"; then
    :
  else
    print_large_ascii "$display_text"
  fi
  printf '\033[0m\n'
}

main() {
  local traffic

  require_command curl
  require_command jq
  require_command perl

  load_env

  if ! ensure_login; then
    exit 1
  fi

  curl_request "$BASE_URL/panel" >"$DASHBOARD_PATH"

  traffic="$(extract_traffic "$DASHBOARD_PATH")"
  if [[ -n "$traffic" ]]; then
    print_big "$traffic"
  else
    printf 'Traffic info not found\n'
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
