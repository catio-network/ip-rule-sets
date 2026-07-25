#!/usr/bin/env bash

set -euo pipefail

# Add or remove raw artifact URLs here. Each file must contain one IPv4 or IPv6
# prefix per line. Blank lines and lines beginning with # are ignored.
RULE_URLS=(
  "https://raw.githubusercontent.com/catio-network/ip-rule-sets/master/artifacts/colocrossing.txt"
)

IPV4_CHAIN="IP_BLOCK_V4"
IPV6_CHAIN="IP_BLOCK_V6"
PARENT_CHAIN="INPUT"
TEMPORARY_DIRECTORY=""

cleanup() {
  if [[ -n $TEMPORARY_DIRECTORY ]]; then
    rm -rf -- "$TEMPORARY_DIRECTORY"
  fi
}

trap cleanup EXIT

usage() {
  printf 'Usage: %s {install|uninstall}\n' "${0##*/}" >&2
  exit 2
}

log() {
  printf '%s\n' "$*"
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    printf 'Error: this script must be run as root.\n' >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

remove_chain() {
  local command=$1
  local chain=$2

  if ! "$command" -w -t filter -nL "$chain" >/dev/null 2>&1; then
    return
  fi

  while "$command" -w -t filter -C "$PARENT_CHAIN" -j "$chain" >/dev/null 2>&1; do
    "$command" -w -t filter -D "$PARENT_CHAIN" -j "$chain"
  done

  "$command" -w -t filter -F "$chain"
  "$command" -w -t filter -X "$chain"
}

uninstall_rules() {
  remove_chain iptables "$IPV4_CHAIN"
  remove_chain ip6tables "$IPV6_CHAIN"
  log "Removed managed iptables and ip6tables rules."
}

download_lists() {
  local output=$1
  local url

  : >"$output"
  for url in "${RULE_URLS[@]}"; do
    log "Downloading $url"
    curl --fail --location --silent --show-error "$url" >>"$output"
    printf '\n' >>"$output"
  done
}

split_and_validate_prefixes() {
  local input=$1
  local ipv4_output=$2
  local ipv6_output=$3
  local line
  local line_number=0

  : >"$ipv4_output"
  : >"$ipv6_output"

  while IFS= read -r line || [[ -n $line ]]; do
    line_number=$((line_number + 1))
    line=${line%$'\r'}

    if [[ -z $line || $line == \#* ]]; then
      continue
    fi

    if [[ $line =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
      printf '%s\n' "$line" >>"$ipv4_output"
    elif [[ $line =~ ^[0-9A-Fa-f:]+/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$ && $line == *:* ]]; then
      printf '%s\n' "$line" >>"$ipv6_output"
    else
      printf 'Error: invalid prefix at downloaded line %d: %s\n' "$line_number" "$line" >&2
      exit 1
    fi
  done <"$input"

  sort -u -o "$ipv4_output" "$ipv4_output"
  sort -u -o "$ipv6_output" "$ipv6_output"

  if [[ ! -s $ipv4_output && ! -s $ipv6_output ]]; then
    printf 'Error: the configured URLs returned no prefixes.\n' >&2
    exit 1
  fi
}

load_chain() {
  local command=$1
  local chain=$2
  local prefixes=$3
  local prefix

  [[ -s $prefixes ]] || return

  "$command" -w -t filter -N "$chain" || return 1
  while IFS= read -r prefix; do
    "$command" -w -t filter -A "$chain" -s "$prefix" -j DROP || return 1
  done <"$prefixes"
  "$command" -w -t filter -A "$chain" -j RETURN || return 1
  "$command" -w -t filter -I "$PARENT_CHAIN" 1 -j "$chain" || return 1
}

install_rules() {
  TEMPORARY_DIRECTORY=$(mktemp -d)

  download_lists "$TEMPORARY_DIRECTORY/prefixes.txt"
  split_and_validate_prefixes \
    "$TEMPORARY_DIRECTORY/prefixes.txt" \
    "$TEMPORARY_DIRECTORY/ipv4.txt" \
    "$TEMPORARY_DIRECTORY/ipv6.txt"

  uninstall_rules

  if ! load_chain iptables "$IPV4_CHAIN" "$TEMPORARY_DIRECTORY/ipv4.txt" ||
    ! load_chain ip6tables "$IPV6_CHAIN" "$TEMPORARY_DIRECTORY/ipv6.txt"; then
    printf 'Error: failed to install rules; removing the partially installed chains.\n' >&2
    uninstall_rules
    exit 1
  fi

  log "Installed $(wc -l <"$TEMPORARY_DIRECTORY/ipv4.txt" | tr -d ' ') IPv4 and $(wc -l <"$TEMPORARY_DIRECTORY/ipv6.txt" | tr -d ' ') IPv6 prefixes."
}

main() {
  [[ $# -eq 1 ]] || usage

  case $1 in
    install | uninstall) ;;
    *) usage ;;
  esac

  require_root
  require_command iptables
  require_command ip6tables

  case $1 in
    install)
      require_command curl
      require_command sort
      require_command mktemp
      install_rules
      ;;
    uninstall)
      uninstall_rules
      ;;
  esac
}

main "$@"
