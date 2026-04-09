#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s extglob

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[0;33m'
readonly CYAN=$'\033[0;36m'
readonly PLAIN=$'\033[0m'

readonly CONF_DIR='/etc/nft_manager'
readonly BACKUP_DIR='/etc/nft_manager_backups'
readonly RUNTIME_DIR="$BACKUP_DIR/runtime"

readonly ALLOW_FILE="$CONF_DIR/allow.list"
readonly ALLOW_RANGE_FILE="$CONF_DIR/allow_range.list"
readonly ALLOW_ACL_FILE="$CONF_DIR/allow_acl.list"
readonly FORWARD_FILE="$CONF_DIR/forward.list"
readonly BLOCK_IP_FILE="$CONF_DIR/block_ip.list"
readonly BLOCK_PORT_FILE="$CONF_DIR/block_port.list"
readonly RATELIMIT_FILE="$CONF_DIR/ratelimit.list"
readonly CONNLIMIT_FILE="$CONF_DIR/connlimit.list"
readonly TRACE_FILE="$CONF_DIR/trace.list"
readonly SETTINGS_FILE="$CONF_DIR/settings.conf"

readonly NFT_RULE_FILE="$CONF_DIR/rules.nft"
readonly PREVIEW_RULE_FILE="$CONF_DIR/rules.preview.nft"
readonly LAST_RULE_FILE="$RUNTIME_DIR/last_active_ruleset.nft"
readonly LAST_SYSCTL_FILE="$RUNTIME_DIR/last_active_sysctl.conf"
readonly PREV_RULE_FILE="$RUNTIME_DIR/previous_active_ruleset.nft"
readonly PREV_SYSCTL_FILE="$RUNTIME_DIR/previous_active_sysctl.conf"
readonly SYSCTL_FILE='/etc/sysctl.d/99-nft-manager.conf'
readonly SERVICE_FILE='/etc/systemd/system/nft-manager.service'
readonly SERVICE_WANTS_LINK='/etc/systemd/system/multi-user.target.wants/nft-manager.service'
readonly LOADER_FILE="$CONF_DIR/load_saved_rules.sh"
readonly LOCK_FILE='/run/nft_manager.lock'

readonly TABLE_FW='custom_fw'
readonly TABLE_NAT='custom_nat'

readonly NFT_BIN="$(type -P nft 2>/dev/null || true)"
readonly IPTABLES_BIN="$(type -P iptables 2>/dev/null || true)"
readonly SYSCTL_BIN="$(type -P sysctl 2>/dev/null || true)"
readonly SYSTEMCTL_BIN="$(type -P systemctl 2>/dev/null || true)"

readonly -A CFG_DEFAULT=(
  [INPUT_POLICY]='drop'
  [FORWARD_POLICY]='drop'
  [OUTPUT_POLICY]='accept'
  [ENABLE_DROP_LOG]='no'
  [DROP_LOG_RATE]='10/second'
  [WAN_IFACE]=''
  [AUTO_OPEN_SSH_PORT]='yes'
  [ALLOW_PING_V4]='yes'
  [PING_V4_RATE]='5/second'
  [ALLOW_PING_V6]='yes'
  [PING_V6_RATE]='5/second'
  [ALLOW_IPV6_ND]='yes'
  [ENABLE_IPV6_FORWARD]='no'
  [WARN_IPTABLES_NAT_CONFLICT]='yes'
  [ENABLE_COUNTERS]='yes'
  [ENABLE_FORWARD_SNAT]='yes'
)

declare -gA CFG=()
declare -ga TMP_PATHS=()
declare -gi LOCK_HELD=0 RULE_SEQ=0
declare -g SYSCTL_LAST_SYNC_MODE='unknown'

declare -g P_PROTO='' P_PORT='' P_SRC='' P_RATE='' P_BURST='' P_LIMIT='' P_MASK='' P_ACTION=''
declare -g B_IP=''
declare -g F_PROTO='' F_EXT_PORT='' F_TARGET_IP='' F_TARGET_PORT='' F_SRC=''
declare -g NEXT_METER_NAME=''

log() { local color=$1; shift; printf '%b%s%b\n' "$color" "$*" "$PLAIN"; }
info() { log "$CYAN" "$@"; }
ok() { log "$GREEN" "$@"; }
warn() { log "$YELLOW" "$@"; }
err() { log "$RED" "$@" >&2; }
die() { err "$*"; exit 1; }

cleanup() {
  local p
  for p in "${TMP_PATHS[@]:-}"; do [[ -n $p ]] && rm -rf -- "$p" 2>/dev/null || true; done
  (( LOCK_HELD )) && flock -u 9 2>/dev/null || true
}
trap cleanup EXIT

need_root() { (( EUID == 0 )) || die '错误：请使用 root 用户运行此脚本。'; }
need_cmds() { [[ -n $NFT_BIN && -n $SYSCTL_BIN ]] || die '错误：未找到 nft 或 sysctl。'; }

acquire_lock() {
  mkdir -p -- "${LOCK_FILE%/*}" || return 1
  exec 9>"$LOCK_FILE" || return 1
  flock -n 9 || return 1
  LOCK_HELD=1
}

tmp_file() { local f; f=$(mktemp) || return 1; TMP_PATHS+=("$f"); printf '%s' "$f"; }
tmp_dir() { local d; d=$(mktemp -d) || return 1; TMP_PATHS+=("$d"); printf '%s' "$d"; }

atomic_install() {
  local src=$1 dst=$2 mode=$3 tmp
  mkdir -p -- "${dst%/*}" || return 1
  tmp=$(mktemp "${dst%/*}/.tmp.${dst##*/}.XXXXXX") || return 1
  cat -- "$src" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod "$mode" -- "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dst"
}

copy_or_empty() { [[ -f $1 ]] && cp -f -- "$1" "$2" || : >"$2"; }

service_is_enabled() {
  if [[ -n $SYSTEMCTL_BIN ]]; then
    "$SYSTEMCTL_BIN" is-enabled --quiet nft-manager.service >/dev/null 2>&1
  else
    [[ -L $SERVICE_WANTS_LINK ]]
  fi
}

save_service_state() {
  if service_is_enabled; then
    printf 'enabled\n' >"$1"
  else
    printf 'disabled\n' >"$1"
  fi
}

restore_service_state() {
  local state_file=$1 state='disabled'
  [[ -f $state_file ]] && IFS= read -r state <"$state_file" || true
  if [[ -n $SYSTEMCTL_BIN ]]; then
    "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
    if [[ $state == enabled ]]; then
      "$SYSTEMCTL_BIN" enable nft-manager.service >/dev/null 2>&1 || return 1
    else
      "$SYSTEMCTL_BIN" disable nft-manager.service >/dev/null 2>&1 || true
      rm -f -- "$SERVICE_WANTS_LINK" 2>/dev/null || true
    fi
  else
    mkdir -p -- "${SERVICE_WANTS_LINK%/*}" || return 1
    if [[ $state == enabled ]]; then
      ln -sfn -- "$SERVICE_FILE" "$SERVICE_WANTS_LINK"
    else
      rm -f -- "$SERVICE_WANTS_LINK"
    fi
  fi
}

snapshot_paths() {
  local snap; snap=$(tmp_dir) || return 1
  copy_or_empty "$NFT_RULE_FILE" "$snap/rules.nft" || return 1
  copy_or_empty "$PREVIEW_RULE_FILE" "$snap/rules.preview.nft" || return 1
  copy_or_empty "$LAST_RULE_FILE" "$snap/last_active_ruleset.nft" || return 1
  copy_or_empty "$LAST_SYSCTL_FILE" "$snap/last_active_sysctl.conf" || return 1
  copy_or_empty "$PREV_RULE_FILE" "$snap/previous_active_ruleset.nft" || return 1
  copy_or_empty "$PREV_SYSCTL_FILE" "$snap/previous_active_sysctl.conf" || return 1
  copy_or_empty "$SYSCTL_FILE" "$snap/sysctl.conf" || return 1
  copy_or_empty "$LOADER_FILE" "$snap/load_saved_rules.sh" || return 1
  copy_or_empty "$SERVICE_FILE" "$snap/nft-manager.service" || return 1
  save_service_state "$snap/service_enabled.state" || return 1
  printf '%s' "$snap"
}

restore_snapshot() {
  local snap=$1
  atomic_install "$snap/rules.nft" "$NFT_RULE_FILE" 600 || return 1
  atomic_install "$snap/rules.preview.nft" "$PREVIEW_RULE_FILE" 600 || return 1
  atomic_install "$snap/last_active_ruleset.nft" "$LAST_RULE_FILE" 600 || return 1
  atomic_install "$snap/last_active_sysctl.conf" "$LAST_SYSCTL_FILE" 600 || return 1
  atomic_install "$snap/previous_active_ruleset.nft" "$PREV_RULE_FILE" 600 || return 1
  atomic_install "$snap/previous_active_sysctl.conf" "$PREV_SYSCTL_FILE" 600 || return 1
  atomic_install "$snap/sysctl.conf" "$SYSCTL_FILE" 644 || return 1
  atomic_install "$snap/load_saved_rules.sh" "$LOADER_FILE" 700 || return 1
  atomic_install "$snap/nft-manager.service" "$SERVICE_FILE" 644 || return 1
  restore_service_state "$snap/service_enabled.state" || return 1
}

trim() {
  local s=$1
  s=${s#${s%%[![:space:]]*}}
  s=${s%${s##*[![:space:]]}}
  printf '%s' "$s"
}

strip_inline_comment() {
  local s=$1 out='' q='' c i
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    [[ -z $q && $c == '#' ]] && break
    if [[ $c == '"' || $c == "'" ]]; then
      [[ -z $q ]] && q=$c || [[ $q == $c ]] && q=''
    fi
    out+=$c
  done
  printf '%s' "$out"
}

normalize_line() { trim "$(strip_inline_comment "$1")"; }

to_dec() { [[ $1 =~ ^[0-9]+$ ]] || return 1; printf '%u' "$((10#$1))"; }
validate_rate() { [[ $1 =~ ^[0-9]+/(second|minute|hour|day)$ ]]; }
validate_policy() { [[ $1 == accept || $1 == drop ]]; }
validate_iface() { [[ -z $1 || $1 =~ ^[A-Za-z0-9_.:-]+$ ]]; }
is_ipv6() { [[ $1 == *:* ]]; }
normalize_proto() { case ${1,,} in tcp|udp|both) printf '%s' "${1,,}" ;; *) return 1 ;; esac; }
normalize_bool() { case ${1,,} in yes|true|1|on) echo yes ;; no|false|0|off) echo no ;; *) return 1 ;; esac; }
normalize_burst() { [[ $1 =~ ^[0-9]+$ ]] || return 1; printf '%s packets' "$1"; }

validate_ipv4_host() {
  local ip=$1 IFS=. part
  local -a octets=()
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<<"$ip"
  ((${#octets[@]} == 4)) || return 1
  for part in "${octets[@]}"; do
    [[ $part =~ ^[0-9]+$ ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
}

validate_ipv4_host_or_prefix() {
  local host bits
  if [[ $1 == */* ]]; then
    host=${1%/*}; bits=${1##*/}
    validate_ipv4_host "$host" || return 1
    [[ $bits =~ ^[0-9]+$ ]] || return 1
    (( 10#$bits <= 32 )) || return 1
    return 0
  fi
  validate_ipv4_host "$1"
}

validate_ipv6_core() {
  local host=${1,,} left right part count=0
  [[ $host == *:* ]] || return 1
  [[ $host != *:::* ]] || return 1
  [[ $host =~ ^[0-9a-f:.]+$ ]] || return 1

  if [[ $host == *::* ]]; then
    left=${host%%::*}
    right=${host#*::}
    [[ $left != *::* && $right != *::* ]] || return 1
  else
    left=$host
    right=''
  fi

  if [[ -n $left ]]; then
    IFS=':' read -r -a _ipv6_left_parts <<<"$left"
    for part in "${_ipv6_left_parts[@]}"; do
      [[ -n $part && $part =~ ^[0-9a-f]{1,4}$ ]] || return 1
      ((++count))
    done
  fi

  if [[ -n $right ]]; then
    IFS=':' read -r -a _ipv6_right_parts <<<"$right"
    for part in "${_ipv6_right_parts[@]}"; do
      [[ -n $part && $part =~ ^[0-9a-f]{1,4}$ ]] || return 1
      ((++count))
    done
  fi

  if [[ $host == *::* ]]; then
    (( count < 8 )) || return 1
  else
    (( count == 8 )) || return 1
  fi
}

validate_ipv6_host_or_prefix() {
  local host=$1 bits
  if [[ $host == */* ]]; then
    bits=${host##*/}; host=${host%/*}
    [[ $bits =~ ^[0-9]+$ ]] || return 1
    (( 10#$bits <= 128 )) || return 1
  fi
  validate_ipv6_core "$host"
}

validate_addr_or_prefix() {
  [[ -n $1 ]] || return 1
  if [[ $1 == *:* ]]; then
    validate_ipv6_host_or_prefix "$1"
  else
    validate_ipv4_host_or_prefix "$1"
  fi
}

validate_ipv4_match_token() { [[ -z $1 ]] || validate_ipv4_host_or_prefix "$1"; }
validate_addr_match_token() { [[ -z $1 ]] || validate_addr_or_prefix "$1"; }

normalize_port_or_range() {
  local a b
  if [[ $1 =~ ^[0-9]+$ ]]; then
    a=$(to_dec "$1") || return 1
    (( a >= 1 && a <= 65535 )) || return 1
    printf '%s' "$a"
    return 0
  fi
  if [[ $1 =~ ^([0-9]+)-([0-9]+)$ ]]; then
    a=$(to_dec "${BASH_REMATCH[1]}") || return 1
    b=$(to_dec "${BASH_REMATCH[2]}") || return 1
    (( a >= 1 && b <= 65535 && a <= b )) || return 1
    printf '%s-%s' "$a" "$b"
    return 0
  fi
  return 1
}

port_is_range() { [[ $1 == *-* ]]; }

port_span_len() {
  local a b
  if [[ $1 =~ ^([0-9]+)-([0-9]+)$ ]]; then
    a=$(to_dec "${BASH_REMATCH[1]}") || return 1
    b=$(to_dec "${BASH_REMATCH[2]}") || return 1
    printf '%s' "$((b - a + 1))"
  else
    printf '1'
  fi
}

validate_forward_port_mapping() {
  local ext=$1 target=$2
  if port_is_range "$ext" || port_is_range "$target"; then
    port_is_range "$ext" && port_is_range "$target" || return 1
    [[ $(port_span_len "$ext") == $(port_span_len "$target") ]] || return 1
  fi
}

strip_quotes() {
  local v=$1
  [[ ${#v} -ge 2 && ${v:0:1} == '"' && ${v: -1} == '"' ]] && v=${v:1:${#v}-2}
  [[ ${#v} -ge 2 && ${v:0:1} == "'" && ${v: -1} == "'" ]] && v=${v:1:${#v}-2}
  printf '%s' "$v"
}

counter_stmt() { [[ ${CFG[ENABLE_COUNTERS]:-yes} == yes ]] && printf 'counter '; }

proto_each() {
  local proto=$1 fn=$2; shift 2
  case $proto in
    tcp|udp) "$fn" "$proto" "$@" ;;
    both) "$fn" tcp "$@"; "$fn" udp "$@" ;;
    *) return 1 ;;
  esac
}

src_expr() {
  local src=${1:-}
  [[ -z $src ]] && return 0
  if is_ipv6 "$src"; then printf 'ip6 saddr %s' "$src"; else printf 'ip saddr %s' "$src"; fi
}

ipv4_mask_from_bits() {
  local bits=$1 full rem vals=(0 0 0 0) i
  [[ $bits =~ ^[0-9]+$ ]] || return 1
  (( bits >= 0 && bits <= 32 )) || return 1
  full=$((bits / 8)); rem=$((bits % 8))
  for ((i=0; i<full; i++)); do vals[i]=255; done
  (( full < 4 && rem > 0 )) && vals[full]=$((256 - (1 << (8 - rem))))
  printf '%s.%s.%s.%s' "${vals[0]}" "${vals[1]}" "${vals[2]}" "${vals[3]}"
}

selector_for_mask() {
  local family=$1 bits=$2
  if [[ $family == ip ]]; then
    [[ -z $bits || $bits == 32 ]] && { printf 'ip saddr'; return 0; }
    printf 'ip saddr and %s' "$(ipv4_mask_from_bits "$bits")"
    return 0
  fi
  [[ -z $bits || $bits == 128 ]] && { printf 'ip6 saddr'; return 0; }
  return 1
}

read_lines_with_lineno() {
  local file=$1 raw line n=0
  [[ -f $file ]] || return 0
  while IFS= read -r raw || [[ -n $raw ]]; do
    ((++n))
    line=$(normalize_line "$raw")
    [[ -n $line ]] && printf '%s\t%s\n' "$n" "$line"
  done <"$file"
}

walk_parsed_lines() {
  local file=$1 parser=$2 label=$3 handler=$4 n line
  while IFS=$'\t' read -r n line; do
    "$parser" "$line" || die "$label 第 $n 行格式错误：$line"
    "$handler"
  done < <(read_lines_with_lineno "$file")
}

parse_kv_opts() {
  local -n out=$1; shift
  local tok key val
  out=([src]='' [burst]='' [mask]='' [action]='')
  for tok in "$@"; do
    key=${tok%%=*}; val=${tok#*=}
    case $key in
      src) out[src]=$val ;;
      burst) out[burst]=$(normalize_burst "$val") || return 1 ;;
      mask) [[ $val =~ ^[0-9]+$ ]] || return 1; out[mask]=$val ;;
      action) [[ $val == drop || $val == reject ]] || return 1; out[action]=$val ;;
      *) return 1 ;;
    esac
  done
}

parse_allow_port_line() {
  local -a a; read -r -a a <<<"$1"
  (( ${#a[@]} == 2 )) || return 1
  P_PROTO=$(normalize_proto "${a[0]}") || return 1
  P_PORT=$(normalize_port_or_range "${a[1]}") || return 1
  P_SRC=''
}

parse_acl_line() {
  local -a a; read -r -a a <<<"$1"
  (( ${#a[@]} == 3 )) || return 1
  P_PROTO=$(normalize_proto "${a[0]}") || return 1
  P_PORT=$(normalize_port_or_range "${a[1]}") || return 1
  P_SRC=${a[2]}
  validate_addr_match_token "$P_SRC" || return 1
}

parse_block_ip_line() {
  B_IP=$1
  validate_addr_or_prefix "$B_IP" || return 1
}
parse_block_port_line() { parse_allow_port_line "$1"; }

parse_rate_line() {
  local -a a; local -A opt=([src]='' [burst]='' [mask]='' [action]='')
  read -r -a a <<<"$1"
  (( ${#a[@]} >= 3 )) || return 1
  P_PROTO=$(normalize_proto "${a[0]}") || return 1
  P_PORT=$(normalize_port_or_range "${a[1]}") || return 1
  P_RATE=${a[2]}; validate_rate "$P_RATE" || return 1
  (( ${#a[@]} == 3 )) || parse_kv_opts opt "${a[@]:3}" || return 1
  P_SRC=${opt[src]}
  P_BURST=${opt[burst]}
  validate_addr_match_token "$P_SRC" || return 1
}

parse_connlimit_line() {
  local -a a; local -A opt=([src]='' [burst]='' [mask]='' [action]='')
  read -r -a a <<<"$1"
  (( ${#a[@]} >= 3 )) || return 1
  P_PROTO=$(normalize_proto "${a[0]}") || return 1
  P_PORT=$(normalize_port_or_range "${a[1]}") || return 1
  P_LIMIT=$(to_dec "${a[2]}") || return 1
  (( P_LIMIT >= 1 )) || return 1
  P_SRC='' P_MASK='' P_ACTION='drop'
  if (( ${#a[@]} > 3 )); then
    if [[ ${a[3]} =~ ^[0-9]+$ ]]; then
      P_MASK=${a[3]}
      (( ${#a[@]} == 4 )) || parse_kv_opts opt "${a[@]:4}" || return 1
    else
      parse_kv_opts opt "${a[@]:3}" || return 1
    fi
    [[ -n ${opt[src]} ]] && P_SRC=${opt[src]}
    [[ -n ${opt[mask]} ]] && P_MASK=${opt[mask]}
    [[ -n ${opt[action]} ]] && P_ACTION=${opt[action]}
  fi
  validate_addr_match_token "$P_SRC" || return 1
  if [[ -n $P_MASK ]]; then
    [[ $P_MASK =~ ^[0-9]+$ ]] || return 1
    (( 10#$P_MASK <= 32 )) || return 1
    [[ -z $P_SRC || $P_SRC != *:* ]] || return 1
  fi
}

parse_trace_line() {
  local -a a; local -A opt
  read -r -a a <<<"$1"
  (( ${#a[@]} >= 2 )) || return 1
  P_PROTO=$(normalize_proto "${a[0]}") || return 1
  P_PORT=$(normalize_port_or_range "${a[1]}") || return 1
  P_SRC=''
  (( ${#a[@]} > 2 )) && { parse_kv_opts opt "${a[@]:2}" || return 1; P_SRC=${opt[src]:-}; }
  validate_addr_match_token "$P_SRC" || return 1
}

parse_forward_line() {
  local -a a; local i tok
  read -r -a a <<<"$1"
  (( ${#a[@]} >= 3 )) || return 1
  F_PROTO=$(normalize_proto "${a[0]}") || return 1
  F_EXT_PORT=$(normalize_port_or_range "${a[1]}") || return 1
  F_TARGET_IP=${a[2]}
  validate_ipv4_host "$F_TARGET_IP" || return 1
  F_TARGET_PORT=$F_EXT_PORT
  F_SRC=''
  if (( ${#a[@]} >= 4 )); then
    if [[ ${a[3]} == *=* ]]; then
      for ((i=3; i<${#a[@]}; i++)); do
        tok=${a[i]}
        [[ $tok == src=* ]] || return 1
        F_SRC=${tok#src=}
      done
    else
      F_TARGET_PORT=$(normalize_port_or_range "${a[3]}") || return 1
      for ((i=4; i<${#a[@]}; i++)); do
        tok=${a[i]}
        [[ $tok == src=* ]] || return 1
        F_SRC=${tok#src=}
      done
    fi
  fi
  validate_forward_port_mapping "$F_EXT_PORT" "$F_TARGET_PORT" || return 1
  validate_ipv4_match_token "$F_SRC" || return 1
}

count_valid_forward_entries() {
  local n line c=0
  while IFS=$'\t' read -r n line; do parse_forward_line "$line" || return 1; ((++c)); done < <(read_lines_with_lineno "$FORWARD_FILE")
  printf '%s' "$c"
}

emit_port_action_one() {
  local proto=$1 port=$2 verdict=$3 src=${4:-}
  printf '    %s%s dport %s %s%s\n' "${src:+$src }" "$proto" "$port" "$(counter_stmt)" "$verdict"
}

emit_allow_rule() { proto_each "$1" emit_port_action_one "$2" accept "${3:-}"; }
emit_block_port_rule() { proto_each "$1" emit_port_action_one "$2" drop; }

emit_trace_one() {
  local proto=$1 port=$2 src=${3:-}
  printf '    %s%s dport %s meta nftrace set 1 %s\n' "${src:+$src }" "$proto" "$port" "$(counter_stmt)"
}
emit_trace_rule() { proto_each "$1" emit_trace_one "$2" "${3:-}"; }

next_meter() { printf -v NEXT_METER_NAME '%s_%04d' "$1" "$((++RULE_SEQ))"; }

connlimit_family() {
  local src=${1:-}
  if [[ -n $src && $src == *:* ]]; then printf 'ip6'; else printf 'ip'; fi
}

connlimit_set_name() { printf 'connlimit_l%04d_%s' "$1" "$2"; }
connlimit_set_type() { [[ $1 == ip ]] && printf 'ipv4_addr' || printf 'ipv6_addr'; }

emit_connlimit_set_decl_one() {
  local lineno=$1 proto=$2 src=$3 mask=$4 family type setname
  family=$(connlimit_family "$src")
  [[ -n $mask && $family == ip6 ]] && die "connlimit 第 $lineno 行对 IPv6 不支持 mask=；请改用 src=前缀。"
  type=$(connlimit_set_type "$family")
  setname=$(connlimit_set_name "$lineno" "$proto")
  printf '  set %s {\n    type %s\n    size 65535\n    flags dynamic\n  }\n' "$setname" "$type"
}

emit_connlimit_set_decls_for_parsed() {
  local lineno=$1
  case $P_PROTO in
    tcp|udp) emit_connlimit_set_decl_one "$lineno" "$P_PROTO" "$P_SRC" "$P_MASK" ;;
    both)
      emit_connlimit_set_decl_one "$lineno" tcp "$P_SRC" "$P_MASK"
      emit_connlimit_set_decl_one "$lineno" udp "$P_SRC" "$P_MASK"
      ;;
  esac
}

render_connlimit_sets() {
  local n line
  while IFS=$'\t' read -r n line; do
    parse_connlimit_line "$line" || die "connlimit.list 第 $n 行格式错误：$line"
    emit_connlimit_set_decls_for_parsed "$n"
  done < <(read_lines_with_lineno "$CONNLIMIT_FILE")
}

emit_rate_limit_one() {
  local proto=$1 port=$2 rate=$3 burst=$4 src=$5 family=ip expr selector
  [[ -n $src ]] && is_ipv6 "$src" && family=ip6
  next_meter ratelimit
  selector="$family saddr"
  expr='ct state new '
  [[ -n $src ]] && expr+="$family saddr $src "
  expr+="$proto dport $port meter $NEXT_METER_NAME { $selector limit rate over $rate"
  [[ -n $burst ]] && expr+=" burst $burst"
  expr+=" } $(counter_stmt)drop"
  printf '    %s\n' "$expr"
}
emit_rate_limit_rule() { proto_each "$1" emit_rate_limit_one "$2" "$3" "$4" "$5"; }

emit_connlimit_one() {
  local lineno=$1 proto=$2 port=$3 limit=$4 mask=$5 src=$6 action=$7 family selector verdict='drop' setname src_match=''
  family=$(connlimit_family "$src")
  if [[ -n $mask ]]; then
    selector=$(selector_for_mask "$family" "$mask") || die "connlimit 第 $lineno 行使用了不支持的 mask=$mask（IPv6 请改用 src=前缀）。"
  else
    selector=$(selector_for_mask "$family" "$([[ $family == ip ]] && echo 32 || echo 128)") || return 1
  fi
  [[ -n $src ]] && src_match="$family saddr $src "
  [[ $action == reject ]] && verdict=$([[ $proto == tcp ]] && echo 'reject with tcp reset' || echo 'reject')
  setname=$(connlimit_set_name "$lineno" "$proto")
  printf '    ct state new %s%s dport %s add @%s { %s ct count over %s } %s%s\n' \
    "$src_match" "$proto" "$port" "$setname" "$selector" "$limit" "$(counter_stmt)" "$verdict"
}

emit_connlimit_rule() {
  local lineno=$1 proto=$2 port=$3 limit=$4 mask=$5 src=$6 action=$7
  case $proto in
    tcp|udp) emit_connlimit_one "$lineno" "$proto" "$port" "$limit" "$mask" "$src" "$action" ;;
    both)
      emit_connlimit_one "$lineno" tcp "$port" "$limit" "$mask" "$src" "$action"
      emit_connlimit_one "$lineno" udp "$port" "$limit" "$mask" "$src" "$action"
      ;;
    *) return 1 ;;
  esac
}

emit_plain_allow_parsed() { emit_allow_rule "$P_PROTO" "$P_PORT"; }
emit_acl_allow_parsed() { emit_allow_rule "$P_PROTO" "$P_PORT" "$(src_expr "$P_SRC")"; }
emit_block_port_parsed() { emit_block_port_rule "$P_PROTO" "$P_PORT"; }
emit_rate_limit_parsed() { emit_rate_limit_rule "$P_PROTO" "$P_PORT" "$P_RATE" "$P_BURST" "$P_SRC"; }
emit_connlimit_parsed() { emit_connlimit_rule "$1" "$P_PROTO" "$P_PORT" "$P_LIMIT" "$P_MASK" "$P_SRC" "$P_ACTION"; }
emit_trace_parsed() { emit_trace_rule "$P_PROTO" "$P_PORT" "$(src_expr "$P_SRC")"; }

render_connlimit_rules() {
  local n line
  while IFS=$'\t' read -r n line; do
    parse_connlimit_line "$line" || die "connlimit.list 第 $n 行格式错误：$line"
    emit_connlimit_parsed "$n"
  done < <(read_lines_with_lineno "$CONNLIMIT_FILE")
}

emit_forward_accept_one() {
  local proto=$1 target_ip=$2 target_port=$3 src=$4
  printf '    ct status dnat ip daddr %s %s%s dport %s %saccept\n' "$target_ip" "${src:+ip saddr $src }" "$proto" "$target_port" "$(counter_stmt)"
}
emit_forward_accept_parsed() { proto_each "$F_PROTO" emit_forward_accept_one "$F_TARGET_IP" "$F_TARGET_PORT" "$F_SRC"; }

emit_dnat_one() {
  local proto=$1 ext_port=$2 target_ip=$3 target_port=$4 src=$5
  printf '    iifname "%s" %s%s dport %s dnat to %s:%s\n' "${CFG[WAN_IFACE]}" "${src:+ip saddr $src }" "$proto" "$ext_port" "$target_ip" "$target_port"
}
emit_prerouting_dnat_parsed() { proto_each "$F_PROTO" emit_dnat_one "$F_EXT_PORT" "$F_TARGET_IP" "$F_TARGET_PORT" "$F_SRC"; }

emit_masq_one() {
  printf '    ct status dnat oifname "%s" masquerade\n' "${CFG[WAN_IFACE]}"
}
emit_postrouting_masq_parsed() { emit_masq_one; }

emit_block_sets() {
  local n line e; local -a v4=() v6=()
  while IFS=$'\t' read -r n line; do
    parse_block_ip_line "$line" || return 1
    is_ipv6 "$B_IP" && v6+=("$B_IP") || v4+=("$B_IP")
  done < <(read_lines_with_lineno "$BLOCK_IP_FILE")

  printf '  set blocked_v4 {\n    type ipv4_addr\n    flags interval\n    auto-merge\n    elements = { '
  if ((${#v4[@]})); then printf '%s' "${v4[0]}"; for e in "${v4[@]:1}"; do printf ', %s' "$e"; done; else printf '127.255.255.255/32'; fi
  printf ' }\n  }\n'

  printf '  set blocked_v6 {\n    type ipv6_addr\n    flags interval\n    auto-merge\n    elements = { '
  if ((${#v6[@]})); then printf '%s' "${v6[0]}"; for e in "${v6[@]:1}"; do printf ', %s' "$e"; done; else printf '::1/128'; fi
  printf ' }\n  }\n'
}

render_base_chain() {
  local chain=$1 hook=$2 policy=$3
  printf '  chain %s {\n' "$chain"
  printf '    type filter hook %s priority filter; policy %s;\n' "$hook" "$policy"
  printf '    ct state invalid %sdrop\n' "$(counter_stmt)"
  [[ $chain != output ]] && printf '    ct state established,related %saccept\n' "$(counter_stmt)"
  [[ $chain == input ]] && printf '    iifname "lo" %saccept\n' "$(counter_stmt)"
  [[ $chain != output ]] && {
    printf '    ip saddr @blocked_v4 %sdrop\n' "$(counter_stmt)"
    printf '    ip6 saddr @blocked_v6 %sdrop\n' "$(counter_stmt)"
  }
}

render_input_chain() {
  render_base_chain input input "${CFG[INPUT_POLICY]}"
  [[ ${CFG[AUTO_OPEN_SSH_PORT]} == yes ]] && printf '    tcp dport 22 %saccept\n' "$(counter_stmt)"
  [[ ${CFG[ALLOW_PING_V4]} == yes ]] && printf '    ip protocol icmp icmp type echo-request limit rate %s %saccept\n' "${CFG[PING_V4_RATE]}" "$(counter_stmt)"
  [[ ${CFG[ALLOW_PING_V6]} == yes ]] && printf '    ip6 nexthdr icmpv6 icmpv6 type echo-request limit rate %s %saccept\n' "${CFG[PING_V6_RATE]}" "$(counter_stmt)"
  [[ ${CFG[ALLOW_IPV6_ND]} == yes ]] && printf '    ip6 nexthdr icmpv6 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } %saccept\n' "$(counter_stmt)"

  walk_parsed_lines "$BLOCK_PORT_FILE" parse_block_port_line 'block_port.list' emit_block_port_parsed
  walk_parsed_lines "$RATELIMIT_FILE" parse_rate_line 'ratelimit.list' emit_rate_limit_parsed
  render_connlimit_rules
  walk_parsed_lines "$TRACE_FILE" parse_trace_line 'trace.list' emit_trace_parsed
  walk_parsed_lines "$ALLOW_ACL_FILE" parse_acl_line 'allow_acl.list' emit_acl_allow_parsed
  walk_parsed_lines "$ALLOW_FILE" parse_allow_port_line 'allow.list' emit_plain_allow_parsed
  walk_parsed_lines "$ALLOW_RANGE_FILE" parse_allow_port_line 'allow_range.list' emit_plain_allow_parsed

  [[ ${CFG[ENABLE_DROP_LOG]} == yes ]] && printf '    limit rate %s log prefix "nft-manager input drop: " flags all\n' "${CFG[DROP_LOG_RATE]}"
  printf '  }\n'
}

render_forward_chain() {
  render_base_chain forward forward "${CFG[FORWARD_POLICY]}"
  walk_parsed_lines "$FORWARD_FILE" parse_forward_line 'forward.list' emit_forward_accept_parsed
  [[ ${CFG[ENABLE_DROP_LOG]} == yes ]] && printf '    limit rate %s log prefix "nft-manager forward drop: " flags all\n' "${CFG[DROP_LOG_RATE]}"
  printf '  }\n'
}

render_output_chain() {
  render_base_chain output output "${CFG[OUTPUT_POLICY]}"
  printf '  }\n'
}

render_filter_table() {
  printf 'table inet %s {\n' "$TABLE_FW"
  emit_block_sets
  render_connlimit_sets
  render_input_chain
  render_forward_chain
  render_output_chain
  printf '}\n'
}

render_nat_table() {
  local valid
  valid=$(count_valid_forward_entries) || die 'forward.list 存在格式错误，拒绝生成 NAT。'
  (( valid > 0 )) || return 0
  [[ -n ${CFG[WAN_IFACE]} ]] || die 'forward.list 存在有效规则，但 settings.conf 中未设置 WAN_IFACE。'

  printf 'table ip %s {\n' "$TABLE_NAT"
  printf '  chain prerouting {\n    type nat hook prerouting priority dstnat; policy accept;\n'
  walk_parsed_lines "$FORWARD_FILE" parse_forward_line 'forward.list' emit_prerouting_dnat_parsed
  printf '  }\n'
  printf '  chain postrouting {\n    type nat hook postrouting priority srcnat; policy accept;\n'
  if [[ ${CFG[ENABLE_FORWARD_SNAT]} == yes ]]; then
    emit_masq_one
  fi
  printf '  }\n}\n'
}

compile_rules_to_file() {
  RULE_SEQ=0
  : >"$1" || return 1
  render_filter_table >>"$1" || return 1
  render_nat_table >>"$1" || return 1
}

build_sysctl_file() {
  local out=$1 valid
  valid=$(count_valid_forward_entries) || die 'forward.list 存在格式错误，拒绝生成 sysctl。'
  if (( valid > 0 )); then
    SYSCTL_LAST_SYNC_MODE='forward-enabled'
  else
    SYSCTL_LAST_SYNC_MODE='forward-disabled'
  fi
  [[ ${CFG[ENABLE_IPV6_FORWARD]} == yes ]] && SYSCTL_LAST_SYNC_MODE+=' + ipv6-manual'
  {
    printf '# managed by nftables-manager-bash\n'
    printf 'net.ipv4.ip_forward=%s\n' "$(( valid > 0 ? 1 : 0 ))"
    printf 'net.ipv6.conf.all.forwarding=%s\n' "$([[ ${CFG[ENABLE_IPV6_FORWARD]} == yes ]] && echo 1 || echo 0)"
  } >"$out"
}

validate_rules_file() { "$NFT_BIN" -c -f "$1"; }

purge_managed_tables() {
  "$NFT_BIN" delete table inet "$TABLE_FW" >/dev/null 2>&1 || true
  "$NFT_BIN" delete table ip "$TABLE_NAT" >/dev/null 2>&1 || true
}

apply_managed_tables() {
  purge_managed_tables
  "$NFT_BIN" -f "$1"
}

apply_sysctl_file() { "$SYSCTL_BIN" -p "$1" >/dev/null; }

write_loader_file() {
  cat >"$1" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

nft_bin=${NFT_BIN@Q}
sysctl_bin=${SYSCTL_BIN@Q}
rules_file=${NFT_RULE_FILE@Q}
sysctl_file=${SYSCTL_FILE@Q}
fw_table=${TABLE_FW@Q}
nat_table=${TABLE_NAT@Q}

tmp_rules=\$(mktemp)
cleanup_loader() { rm -f -- "\$tmp_rules"; }
trap cleanup_loader EXIT

cp -- "\$rules_file" "\$tmp_rules"
"\$nft_bin" -c -f "\$tmp_rules"
"\$nft_bin" delete table inet "\$fw_table" >/dev/null 2>&1 || true
"\$nft_bin" delete table ip "\$nat_table" >/dev/null 2>&1 || true
"\$nft_bin" -f "\$tmp_rules"
"\$sysctl_bin" -p "\$sysctl_file" >/dev/null
EOF
}

write_service_file() {
  cat >"$1" <<EOF
[Unit]
Description=nft-manager managed rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$LOADER_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

persist_generated_files() {
  local rules=$1 sysctl_tmp=$2 loader_tmp=$3 service_tmp=$4
  if [[ -s $LAST_RULE_FILE ]]; then atomic_install "$LAST_RULE_FILE" "$PREV_RULE_FILE" 600 || return 1; else : >"$PREV_RULE_FILE" && chmod 600 "$PREV_RULE_FILE" || return 1; fi
  if [[ -s $LAST_SYSCTL_FILE ]]; then atomic_install "$LAST_SYSCTL_FILE" "$PREV_SYSCTL_FILE" 600 || return 1; else : >"$PREV_SYSCTL_FILE" && chmod 600 "$PREV_SYSCTL_FILE" || return 1; fi
  atomic_install "$rules" "$PREVIEW_RULE_FILE" 600 || return 1
  atomic_install "$rules" "$NFT_RULE_FILE" 600 || return 1
  atomic_install "$rules" "$LAST_RULE_FILE" 600 || return 1
  atomic_install "$sysctl_tmp" "$SYSCTL_FILE" 644 || return 1
  atomic_install "$sysctl_tmp" "$LAST_SYSCTL_FILE" 600 || return 1
  atomic_install "$loader_tmp" "$LOADER_FILE" 700 || return 1
  atomic_install "$service_tmp" "$SERVICE_FILE" 644 || return 1
}

persist_rollback_files() {
  local rules_tmp=$1 sysctl_tmp=$2 loader_tmp=$3 service_tmp=$4 prior_rules=$5 prior_sysctl=$6 prev_rules_tmp prev_sysctl_tmp
  prev_rules_tmp=$(tmp_file) || return 1
  prev_sysctl_tmp=$(tmp_file) || return 1
  [[ -s $prior_rules ]] && cat -- "$prior_rules" >"$prev_rules_tmp" || : >"$prev_rules_tmp"
  [[ -s $prior_sysctl ]] && cat -- "$prior_sysctl" >"$prev_sysctl_tmp" || : >"$prev_sysctl_tmp"
  chmod 600 -- "$prev_rules_tmp" "$prev_sysctl_tmp" 2>/dev/null || true
  atomic_install "$rules_tmp" "$PREVIEW_RULE_FILE" 600 || return 1
  atomic_install "$rules_tmp" "$NFT_RULE_FILE" 600 || return 1
  atomic_install "$rules_tmp" "$LAST_RULE_FILE" 600 || return 1
  atomic_install "$prev_rules_tmp" "$PREV_RULE_FILE" 600 || return 1
  atomic_install "$sysctl_tmp" "$SYSCTL_FILE" 644 || return 1
  atomic_install "$sysctl_tmp" "$LAST_SYSCTL_FILE" 600 || return 1
  atomic_install "$prev_sysctl_tmp" "$PREV_SYSCTL_FILE" 600 || return 1
  atomic_install "$loader_tmp" "$LOADER_FILE" 700 || return 1
  atomic_install "$service_tmp" "$SERVICE_FILE" 644 || return 1
}

warn_iptables_nat_conflict() {
  [[ ${CFG[WARN_IPTABLES_NAT_CONFLICT]} == yes && -n $IPTABLES_BIN ]] || return 0
  "$IPTABLES_BIN" -t nat -S 2>/dev/null | grep -qE '^-A ' && warn '检测到 iptables nat 表仍有规则，可能与 nftables DNAT/MASQUERADE 冲突。' || true
}

reset_settings() {
  CFG=()
  local k
  for k in "${!CFG_DEFAULT[@]}"; do CFG[$k]=${CFG_DEFAULT[$k]}; done
}

load_settings() {
  local line key val norm
  reset_settings
  [[ -f $SETTINGS_FILE ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(normalize_line "$line")
    [[ -n $line ]] || continue
    [[ $line == *=* ]] || { warn "忽略 settings.conf 非法行：$line"; continue; }
    key=$(trim "${line%%=*}")
    val=$(strip_quotes "$(trim "${line#*=}")")
    case $key in
      INPUT_POLICY|FORWARD_POLICY|OUTPUT_POLICY)
        validate_policy "$val" || die "settings.conf 中 $key 非法：$val"
        CFG[$key]=$val ;;
      ENABLE_DROP_LOG|AUTO_OPEN_SSH_PORT|ALLOW_PING_V4|ALLOW_PING_V6|ALLOW_IPV6_ND|ENABLE_IPV6_FORWARD|WARN_IPTABLES_NAT_CONFLICT|ENABLE_COUNTERS|ENABLE_FORWARD_SNAT)
        norm=$(normalize_bool "$val") || die "settings.conf 中 $key 非法：$val"
        CFG[$key]=$norm ;;
      DROP_LOG_RATE|PING_V4_RATE|PING_V6_RATE)
        validate_rate "$val" || die "settings.conf 中 $key 非法：$val"
        CFG[$key]=$val ;;
      WAN_IFACE)
        validate_iface "$val" || die "settings.conf 中 WAN_IFACE 非法：$val"
        CFG[WAN_IFACE]=$val ;;
      '') ;;
      *) warn "忽略 settings.conf 未识别键：$key" ;;
    esac
  done <"$SETTINGS_FILE"
}

write_default_settings() {
  cat <<'EOF'
# 基础策略：accept / drop
INPUT_POLICY=drop
FORWARD_POLICY=drop
OUTPUT_POLICY=accept

# yes / no
ENABLE_DROP_LOG=no
DROP_LOG_RATE=10/second
WAN_IFACE=
AUTO_OPEN_SSH_PORT=yes
ALLOW_PING_V4=yes
PING_V4_RATE=5/second
ALLOW_PING_V6=yes
PING_V6_RATE=5/second
ALLOW_IPV6_ND=yes
ENABLE_IPV6_FORWARD=no
# 注意：IPv6 forwarding 是手动开关，不依赖 forward.list
WARN_IPTABLES_NAT_CONFLICT=yes
ENABLE_COUNTERS=yes
# 端口转发是否自动对 DNAT 流量追加 WAN 口 MASQUERADE
ENABLE_FORWARD_SNAT=yes
EOF
}

write_sample_lists() {
  cat <<'EOF'
# ===== allow.list =====
# 格式： proto port_or_range
# 例如：
# tcp 22
# udp 53
# both 80

# ===== allow_range.list =====
# 格式同 allow.list，通常用于端口范围：
# tcp 10000-10100

# ===== allow_acl.list =====
# 格式： proto port_or_range src_cidr
# 例如：
# tcp 22 198.51.100.0/24
# udp 53 2001:db8::/32

# ===== block_ip.list =====
# 每行一个 IP 或 CIDR：
# 203.0.113.5
# 198.51.100.0/24
# 2001:db8::/32

# ===== block_port.list =====
# 格式： proto port_or_range
# 例如：
# tcp 23
# both 135-139

# ===== ratelimit.list =====
# 格式： proto port_or_range rate [burst=N] [src=CIDR]
# 说明：按来源地址做 keyed meter；超过 rate 后丢弃。
# 例如：
# tcp 80 30/second burst=60
# tcp 22 5/minute src=198.51.100.0/24

# ===== connlimit.list =====
# 格式： proto port_or_range limit [mask=N] [src=CIDR] [action=drop|reject]
# 说明：限制新建连接数。
# 例如：
# tcp 22 20 action=reject
# tcp 443 100 mask=24
# tcp 8443 30 src=198.51.100.0/24
# 注意：IPv6 非 /128 聚合请优先用 src=前缀；mask= 仅稳定支持 IPv4。

# ===== trace.list =====
# 格式： proto port_or_range [src=CIDR]
# 说明：设置 nftrace。
# 例如：
# tcp 443
# udp 53 src=198.51.100.0/24

# ===== forward.list =====
# 格式： proto ext_port_or_range target_ip [target_port_or_range] [src=CIDR]
# 例如：
# tcp 443 192.168.1.10 443
# tcp 10000-10010 192.168.1.20 10000-10010
# udp 51820 192.168.1.30 51820 src=198.51.100.0/24
# 说明：
# - 只有“解析成功”的 forward 规则才会启用 net.ipv4.ip_forward=1
# - forward 放行与 postrouting masquerade 都会绑定 ct status dnat，只匹配命中过 DNAT 的流量
EOF
}

ensure_layout() {
  local f files=(
    "$ALLOW_FILE" "$ALLOW_RANGE_FILE" "$ALLOW_ACL_FILE" "$FORWARD_FILE"
    "$BLOCK_IP_FILE" "$BLOCK_PORT_FILE" "$RATELIMIT_FILE" "$CONNLIMIT_FILE" "$TRACE_FILE"
  )
  mkdir -p -- "$CONF_DIR" "$BACKUP_DIR" "$RUNTIME_DIR" || return 1
  for f in "${files[@]}"; do [[ -e $f ]] || : >"$f"; chmod 600 -- "$f" 2>/dev/null || true; done
  if [[ ! -f $SETTINGS_FILE ]]; then write_default_settings >"$SETTINGS_FILE" || return 1; chmod 600 -- "$SETTINGS_FILE" 2>/dev/null || true; fi
}

apply_rules() {
  local rules_tmp sysctl_tmp loader_tmp service_tmp snap
  rules_tmp=$(tmp_file) || return 1
  sysctl_tmp=$(tmp_file) || return 1
  loader_tmp=$(tmp_file) || return 1
  service_tmp=$(tmp_file) || return 1
  snap=$(snapshot_paths) || return 1

  load_settings
  warn_iptables_nat_conflict
  compile_rules_to_file "$rules_tmp" || return 1
  validate_rules_file "$rules_tmp" || die 'nft -c 校验失败，请检查上面的报错。'
  build_sysctl_file "$sysctl_tmp" || return 1
  write_loader_file "$loader_tmp" || return 1
  write_service_file "$service_tmp" || return 1

  apply_managed_tables "$rules_tmp" || die '应用 nft 规则失败。'
  if ! apply_sysctl_file "$sysctl_tmp"; then
    err '应用 sysctl 失败，正在尝试恢复旧运行态。'
    [[ -s $LAST_RULE_FILE ]] && apply_managed_tables "$LAST_RULE_FILE" || { "$NFT_BIN" delete table inet "$TABLE_FW" >/dev/null 2>&1 || true; "$NFT_BIN" delete table ip "$TABLE_NAT" >/dev/null 2>&1 || true; }
    [[ -f $snap/sysctl.conf ]] && atomic_install "$snap/sysctl.conf" "$SYSCTL_FILE" 644 || true
    [[ -f $snap/sysctl.conf ]] && "$SYSCTL_BIN" -p "$snap/sysctl.conf" >/dev/null 2>&1 || true
    return 1
  fi

  if ! persist_generated_files "$rules_tmp" "$sysctl_tmp" "$loader_tmp" "$service_tmp"; then
    err '持久化文件失败，正在回滚运行态与文件态。'
    [[ -s $snap/last_active_ruleset.nft ]] && apply_managed_tables "$snap/last_active_ruleset.nft" || { "$NFT_BIN" delete table inet "$TABLE_FW" >/dev/null 2>&1 || true; "$NFT_BIN" delete table ip "$TABLE_NAT" >/dev/null 2>&1 || true; }
    atomic_install "$snap/sysctl.conf" "$SYSCTL_FILE" 644 || true
    "$SYSCTL_BIN" -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    restore_snapshot "$snap" || true
    return 1
  fi

  ok '规则已应用并持久化成功。'
  info "sysctl 同步模式：$SYSCTL_LAST_SYNC_MODE"
}

preview_rules() {
  local rules_tmp sysctl_tmp
  rules_tmp=$(tmp_file) || return 1
  sysctl_tmp=$(tmp_file) || return 1
  load_settings
  compile_rules_to_file "$rules_tmp" || return 1
  validate_rules_file "$rules_tmp" || die 'nft -c 校验失败，请检查上面的报错。'
  build_sysctl_file "$sysctl_tmp" || return 1
  atomic_install "$rules_tmp" "$PREVIEW_RULE_FILE" 600 || return 1
  ok "预览规则已生成并通过 nft -c 校验：$PREVIEW_RULE_FILE"
  info '对应 sysctl 预览：'
  cat -- "$sysctl_tmp"
}

rollback_rules() {
  local rules_src sysctl_src rules_tmp sysctl_tmp loader_tmp service_tmp snap prior_rules prior_sysctl
  snap=$(snapshot_paths) || return 1
  if [[ -s $PREV_RULE_FILE ]]; then
    rules_src=$PREV_RULE_FILE; sysctl_src=$PREV_SYSCTL_FILE
  elif [[ -s $LAST_RULE_FILE ]]; then
    rules_src=$LAST_RULE_FILE; sysctl_src=$LAST_SYSCTL_FILE
  else
    die '没有可回滚的历史规则。'
  fi
  prior_rules="$snap/last_active_ruleset.nft"
  prior_sysctl="$snap/last_active_sysctl.conf"

  validate_rules_file "$rules_src" || die '历史规则文件自身无效，拒绝回滚。'
  apply_managed_tables "$rules_src" || die '回滚 nft 规则失败。'
  [[ -s $sysctl_src ]] && apply_sysctl_file "$sysctl_src" || true

  rules_tmp=$(tmp_file) || return 1
  sysctl_tmp=$(tmp_file) || return 1
  loader_tmp=$(tmp_file) || return 1
  service_tmp=$(tmp_file) || return 1
  cat -- "$rules_src" >"$rules_tmp" || return 1
  [[ -s $sysctl_src ]] && cat -- "$sysctl_src" >"$sysctl_tmp" || build_sysctl_file "$sysctl_tmp"
  write_loader_file "$loader_tmp" || return 1
  write_service_file "$service_tmp" || return 1

  if ! persist_rollback_files "$rules_tmp" "$sysctl_tmp" "$loader_tmp" "$service_tmp" "$prior_rules" "$prior_sysctl"; then
    err '回滚后同步持久化文件失败，正在恢复回滚前的运行态与文件态。'
    [[ -s $prior_rules ]] && apply_managed_tables "$prior_rules" || { purge_managed_tables; }
    atomic_install "$snap/sysctl.conf" "$SYSCTL_FILE" 644 || true
    [[ -f $snap/sysctl.conf ]] && "$SYSCTL_BIN" -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    restore_snapshot "$snap" || true
    return 1
  fi
  ok '已完成回滚，并同步 nft 运行态 + sysctl + LAST/PREV 历史文件。'
}

install_service() {
  local loader_tmp service_tmp
  loader_tmp=$(tmp_file) || return 1
  service_tmp=$(tmp_file) || return 1
  write_loader_file "$loader_tmp" || return 1
  write_service_file "$service_tmp" || return 1
  atomic_install "$loader_tmp" "$LOADER_FILE" 700 || return 1
  atomic_install "$service_tmp" "$SERVICE_FILE" 644 || return 1
  if [[ -n $SYSTEMCTL_BIN ]]; then
    "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || return 1
    "$SYSTEMCTL_BIN" enable nft-manager.service >/dev/null 2>&1 || return 1
  else
    mkdir -p -- "${SERVICE_WANTS_LINK%/*}" || return 1
    ln -sfn -- "$SERVICE_FILE" "$SERVICE_WANTS_LINK"
  fi
  ok '已安装并启用 nft-manager.service'
}

disable_service() {
  if [[ -n $SYSTEMCTL_BIN ]]; then
    "$SYSTEMCTL_BIN" disable nft-manager.service >/dev/null 2>&1 || true
    "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f -- "$SERVICE_WANTS_LINK" 2>/dev/null || true
  ok '已禁用 nft-manager.service'
}

status_report() {
  load_settings
  printf '配置目录: %s\n规则文件: %s\n预览文件: %s\nWAN_IFACE: %s\n策略: input=%s forward=%s output=%s\n计数器: %s\nIPv6 forwarding: %s\nPING 速率: v4=%s v6=%s\n转发 SNAT: %s\nservice 启用: %s\n' \
    "$CONF_DIR" "$NFT_RULE_FILE" "$PREVIEW_RULE_FILE" "${CFG[WAN_IFACE]:-<未设置>}" \
    "${CFG[INPUT_POLICY]}" "${CFG[FORWARD_POLICY]}" "${CFG[OUTPUT_POLICY]}" \
    "${CFG[ENABLE_COUNTERS]}" "${CFG[ENABLE_IPV6_FORWARD]}" "${CFG[PING_V4_RATE]}" "${CFG[PING_V6_RATE]}" "${CFG[ENABLE_FORWARD_SNAT]}" "$(service_is_enabled && echo yes || echo no)"
  [[ -f $SYSCTL_FILE ]] && { printf '\n当前持久化 sysctl:\n'; cat -- "$SYSCTL_FILE"; }
  printf '\n有效 DNAT 条数: %s\n\n' "$(count_valid_forward_entries 2>/dev/null || echo 0)"
  "$NFT_BIN" list table inet "$TABLE_FW" >/dev/null 2>&1 && ok "运行态存在表：inet $TABLE_FW" || warn "运行态不存在表：inet $TABLE_FW"
  "$NFT_BIN" list table ip "$TABLE_NAT" >/dev/null 2>&1 && ok "运行态存在表：ip $TABLE_NAT" || warn "运行态不存在表：ip $TABLE_NAT"
}

init_layout() { ensure_layout || return 1; ok "初始化完成：$CONF_DIR"; printf '\n'; write_sample_lists; }


normalize_cli_src() {
  local s=${1:-}
  [[ -z $s ]] && return 0
  [[ $s == src=* ]] && s=${s#src=}
  printf '%s' "$s"
}

build_open_rule_entry() {
  local proto=$1 port=$2 src=${3:-}
  src=$(normalize_cli_src "$src")
  if [[ -n $src ]]; then
    parse_acl_line "$proto $port $src" || return 1
    ENTRY_FILE=$ALLOW_ACL_FILE
    ENTRY_LINE="$P_PROTO $P_PORT $P_SRC"
  else
    parse_allow_port_line "$proto $port" || return 1
    ENTRY_FILE=$([[ $P_PORT == *-* ]] && printf '%s' "$ALLOW_RANGE_FILE" || printf '%s' "$ALLOW_FILE")
    ENTRY_LINE="$P_PROTO $P_PORT"
  fi
  return 0
}

build_forward_rule_entry() {
  local proto=$1 ext_port=$2 target_ip=$3 target_port=${4:-} src=${5:-} line
  src=$(normalize_cli_src "$src")
  line="$proto $ext_port $target_ip"
  [[ -n $target_port ]] && line+=" $target_port"
  [[ -n $src ]] && line+=" src=$src"
  parse_forward_line "$line" || return 1
  ENTRY_FILE=$FORWARD_FILE
  ENTRY_LINE="$F_PROTO $F_EXT_PORT $F_TARGET_IP"
  [[ $F_TARGET_PORT != "$F_EXT_PORT" ]] && ENTRY_LINE+=" $F_TARGET_PORT"
  [[ -n $F_SRC ]] && ENTRY_LINE+=" src=$F_SRC"
  return 0
}

append_unique_line() {
  local file=$1 line=$2 raw norm
  [[ -f $file ]] || : >"$file"
  while IFS= read -r raw || [[ -n $raw ]]; do
    norm=$(normalize_line "$raw")
    [[ -n $norm && $norm == "$line" ]] && { ok "规则已存在：$line"; return 0; }
  done <"$file"
  printf '%s\n' "$line" >>"$file" || return 1
  chmod 600 -- "$file" 2>/dev/null || true
  ok "已写入 ${file##*/}: $line"
}

remove_normalized_line_from_file() {
  local file=$1 target=$2 tmp raw norm removed=0
  tmp=$(tmp_file) || return 1
  while IFS= read -r raw || [[ -n $raw ]]; do
    norm=$(normalize_line "$raw")
    if [[ -n $norm && $norm == "$target" ]]; then
      ((++removed))
      continue
    fi
    printf '%s\n' "$raw" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
  done <"$file"
  chmod 600 -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
  REMOVED_COUNT=$removed
}

delete_line_from_files() {
  local target=$1; shift
  local file removed_total=0
  for file in "$@"; do
    [[ -f $file ]] || continue
    remove_normalized_line_from_file "$file" "$target" || return 1
    (( removed_total += REMOVED_COUNT ))
  done
  if (( removed_total > 0 )); then
    ok "已删除规则：$target"
  else
    warn "未找到规则：$target"
    return 1
  fi
}

open_add_cmd() {
  local proto=${1:-} port=${2:-} src=${3:-}
  (( $# >= 2 && $# <= 3 )) || die '用法：open-add <tcp|udp|both> <port|start-end> [CIDR|src=CIDR]'
  build_open_rule_entry "$proto" "$port" "$src" || die '开放端口参数非法。'
  append_unique_line "$ENTRY_FILE" "$ENTRY_LINE"
}

open_del_cmd() {
  local proto=${1:-} port=${2:-} src=${3:-}
  (( $# >= 2 && $# <= 3 )) || die '用法：open-del <tcp|udp|both> <port|start-end> [CIDR|src=CIDR]'
  build_open_rule_entry "$proto" "$port" "$src" || die '开放端口参数非法。'
  if [[ -n $(normalize_cli_src "$src") ]]; then
    delete_line_from_files "$ENTRY_LINE" "$ALLOW_ACL_FILE"
  else
    delete_line_from_files "$ENTRY_LINE" "$ALLOW_FILE" "$ALLOW_RANGE_FILE"
  fi
}

forward_add_cmd() {
  local proto=${1:-} ext_port=${2:-} target_ip=${3:-} arg4=${4:-} arg5=${5:-} target_port='' src=''
  (( $# >= 3 && $# <= 5 )) || die '用法：forward-add <tcp|udp|both> <ext_port|range> <target_ip> [target_port|range] [src=CIDR]'
  if (( $# >= 4 )); then
    if [[ $arg4 == src=* ]]; then
      src=$arg4
    else
      target_port=$arg4
    fi
  fi
  (( $# == 5 )) && src=$arg5
  build_forward_rule_entry "$proto" "$ext_port" "$target_ip" "$target_port" "$src" || die '端口转发参数非法。'
  append_unique_line "$ENTRY_FILE" "$ENTRY_LINE"
}

forward_del_cmd() {
  local proto=${1:-} ext_port=${2:-} target_ip=${3:-} arg4=${4:-} arg5=${5:-} target_port='' src=''
  (( $# >= 3 && $# <= 5 )) || die '用法：forward-del <tcp|udp|both> <ext_port|range> <target_ip> [target_port|range] [src=CIDR]'
  if (( $# >= 4 )); then
    if [[ $arg4 == src=* ]]; then
      src=$arg4
    else
      target_port=$arg4
    fi
  fi
  (( $# == 5 )) && src=$arg5
  build_forward_rule_entry "$proto" "$ext_port" "$target_ip" "$target_port" "$src" || die '端口转发参数非法。'
  delete_line_from_files "$ENTRY_LINE" "$FORWARD_FILE"
}


print_open_row() {
  local src=${1:-不限}
  printf '%-8s %-18s %-22s %-16s
' "$P_PROTO" "$P_PORT" "$src" "$2"
}

print_forward_row() {
  local tgt_port=$F_TARGET_PORT src=${F_SRC:-不限}
  printf '%-8s %-14s %-16s %-14s %-18s
' "$F_PROTO" "$F_EXT_PORT" "$F_TARGET_IP" "$tgt_port" "$src"
}

open_list_cmd() {
  local n line found=0
  printf '%-8s %-18s %-22s %-16s
' '协议' '端口/范围' '来源限制' '来源文件'
  printf '%-8s %-18s %-22s %-16s
' '--------' '------------------' '----------------------' '----------------'
  while IFS=$'	' read -r n line; do
    parse_allow_port_line "$line" || die "allow.list 第 $n 行格式错误：$line"
    print_open_row '不限' 'allow.list'
    found=1
  done < <(read_lines_with_lineno "$ALLOW_FILE")
  while IFS=$'	' read -r n line; do
    parse_allow_port_line "$line" || die "allow_range.list 第 $n 行格式错误：$line"
    print_open_row '不限' 'allow_range.list'
    found=1
  done < <(read_lines_with_lineno "$ALLOW_RANGE_FILE")
  while IFS=$'	' read -r n line; do
    parse_acl_line "$line" || die "allow_acl.list 第 $n 行格式错误：$line"
    print_open_row "$P_SRC" 'allow_acl.list'
    found=1
  done < <(read_lines_with_lineno "$ALLOW_ACL_FILE")
  (( found )) || printf '（当前没有开放端口规则）
'
}

forward_list_cmd() {
  local n line found=0
  printf '%-8s %-14s %-16s %-14s %-18s
' '协议' '外部端口' '目标IP' '目标端口' '来源限制'
  printf '%-8s %-14s %-16s %-14s %-18s
' '--------' '--------------' '----------------' '--------------' '------------------'
  while IFS=$'	' read -r n line; do
    parse_forward_line "$line" || die "forward.list 第 $n 行格式错误：$line"
    print_forward_row
    found=1
  done < <(read_lines_with_lineno "$FORWARD_FILE")
  (( found )) || printf '（当前没有端口转发规则）
'
}

prompt_open_add() {
  local proto port src
  read -r -p '协议 (tcp/udp/both): ' proto || return 1
  read -r -p '开放端口或范围: ' port || return 1
  read -r -p '来源限制（留空表示不限，可填 CIDR）: ' src || return 1
  open_add_cmd "$proto" "$port" "${src:-}"
}

prompt_open_del() {
  local proto port src
  read -r -p '协议 (tcp/udp/both): ' proto || return 1
  read -r -p '删除的开放端口或范围: ' port || return 1
  read -r -p '来源限制（若有；留空表示不限）: ' src || return 1
  open_del_cmd "$proto" "$port" "${src:-}"
}

prompt_forward_add() {
  local proto ext_port target_ip target_port src
  read -r -p '协议 (tcp/udp/both): ' proto || return 1
  read -r -p '外部端口或范围: ' ext_port || return 1
  read -r -p '目标 IPv4: ' target_ip || return 1
  read -r -p '目标端口或范围（留空表示同外部端口）: ' target_port || return 1
  read -r -p '来源限制（留空表示不限，可填 CIDR）: ' src || return 1
  forward_add_cmd "$proto" "$ext_port" "$target_ip" "${target_port:-}" "${src:+src=$src}"
}

prompt_forward_del() {
  local proto ext_port target_ip target_port src
  read -r -p '协议 (tcp/udp/both): ' proto || return 1
  read -r -p '外部端口或范围: ' ext_port || return 1
  read -r -p '目标 IPv4: ' target_ip || return 1
  read -r -p '目标端口或范围（留空表示同外部端口）: ' target_port || return 1
  read -r -p '来源限制（若有；留空表示不限）: ' src || return 1
  forward_del_cmd "$proto" "$ext_port" "$target_ip" "${target_port:-}" "${src:+src=$src}"
}


menu() {
  local choice
  while true; do
    cat <<'EOF'

===== nftables-manager-bash =====
1) 初始化目录与默认配置
2) 生成预览并校验
3) 应用规则
4) 回滚
5) 查看状态
6) 输出配置格式示例
7) 安装并启用 systemd 服务
8) 禁用 systemd 服务
9) 增加开放端口
10) 删除开放端口
11) 查看开放端口
12) 增加端口转发
13) 删除端口转发
14) 查看端口转发
15) 退出
EOF
    read -r -p '请选择: ' choice || return 0
    case $choice in
      1) init_layout ;;
      2) preview_rules ;;
      3) apply_rules ;;
      4) rollback_rules ;;
      5) status_report ;;
      6) write_sample_lists ;;
      7) install_service ;;
      8) disable_service ;;
      9) prompt_open_add ;;
      10) prompt_open_del ;;
      11) open_list_cmd ;;
      12) prompt_forward_add ;;
      13) prompt_forward_del ;;
      14) forward_list_cmd ;;
      15) return 0 ;;
      *) warn '无效选择。' ;;
    esac
  done
}

usage() {
  cat <<'EOF'
用法：
  nftables-manager-bash.sh init
  nftables-manager-bash.sh preview
  nftables-manager-bash.sh apply
  nftables-manager-bash.sh rollback
  nftables-manager-bash.sh status
  nftables-manager-bash.sh sample
  nftables-manager-bash.sh enable-service
  nftables-manager-bash.sh disable-service
  nftables-manager-bash.sh open-add <tcp|udp|both> <port|start-end> [CIDR|src=CIDR]
  nftables-manager-bash.sh open-del <tcp|udp|both> <port|start-end> [CIDR|src=CIDR]
  nftables-manager-bash.sh open-list
  nftables-manager-bash.sh forward-add <tcp|udp|both> <ext_port|range> <target_ip> [target_port|range] [src=CIDR]
  nftables-manager-bash.sh forward-del <tcp|udp|both> <ext_port|range> <target_ip> [target_port|range] [src=CIDR]
  nftables-manager-bash.sh forward-list
  nftables-manager-bash.sh menu

示例：
  nftables-manager-bash.sh open-add tcp 443
  nftables-manager-bash.sh open-add tcp 22 198.51.100.0/24
  nftables-manager-bash.sh open-del both 10000-10010
  nftables-manager-bash.sh open-list
  nftables-manager-bash.sh forward-add tcp 8443 192.168.1.10 443
  nftables-manager-bash.sh forward-add udp 51820 192.168.1.30 src=198.51.100.0/24
  nftables-manager-bash.sh forward-del udp 51820 192.168.1.30 src=198.51.100.0/24
  nftables-manager-bash.sh forward-list
EOF
}

main() {
  local cmd=${1:-menu}
  need_root
  need_cmds
  acquire_lock || die '错误：已有另一个 nft_manager 实例在运行。'
  ensure_layout || return 1
  case $cmd in
    init) init_layout ;;
    preview) preview_rules ;;
    apply) apply_rules ;;
    rollback) rollback_rules ;;
    status) status_report ;;
    sample) write_sample_lists ;;
    enable-service) install_service ;;
    disable-service) disable_service ;;
    open-add) shift; open_add_cmd "$@" ;;
    open-del) shift; open_del_cmd "$@" ;;
    open-list) open_list_cmd ;;
    forward-add) shift; forward_add_cmd "$@" ;;
    forward-del) shift; forward_del_cmd "$@" ;;
    forward-list) forward_list_cmd ;;
    menu) menu ;;
    -h|--help|help) usage ;;
    *) usage; return 1 ;;
  esac
}

[[ ${NTM_SKIP_MAIN:-0} == 1 ]] || main "$@"
