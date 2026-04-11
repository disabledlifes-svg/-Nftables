#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s extglob
umask 077

# ===== 基础常量与路径 =====
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
readonly LOGROTATE_SAMPLE_FILE="$CONF_DIR/logrotate-drop-log.sample"

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
  [SSH_PORT]='22'
  [ALLOW_PING_V4]='yes'
  [PING_V4_RATE]='5/second'
  [ALLOW_PING_V6]='yes'
  [PING_V6_RATE]='5/second'
  [ALLOW_IPV6_ND]='yes'
  [ENABLE_IPV6_FORWARD]='no'
  [WARN_IPTABLES_NAT_CONFLICT]='yes'
  [ENABLE_COUNTERS]='yes'
  [ENABLE_FORWARD_SNAT]='yes'
  [RATELIMIT_TIMEOUT]='1m'
  [FORWARD_MARK_HEX]='0x20000000'
  [FORWARD_MARK_MASK]='0x20000000'
)

declare -gA CFG=()
declare -ga TMP_PATHS=()
declare -gi LOCK_HELD=0 RULE_SEQ=0 ERR_TRAP_ACTIVE=0
declare -g SYSCTL_LAST_SYNC_MODE='unknown'

declare -g P_PROTO='' P_PORT='' P_SRC='' P_RATE='' P_BURST='' P_LIMIT='' P_MASK='' P_ACTION=''
declare -g B_IP=''
declare -g F_PROTO='' F_EXT_PORT='' F_TARGET_IP='' F_TARGET_PORT='' F_SRC=''
declare -g ENTRY_FILE='' ENTRY_LINE='' REMOVED_COUNT=0

# ===== 基础输出与错误处理 =====
log() { local color=$1; shift; printf '%b%s%b\n' "$color" "$*" "$PLAIN"; }
info() { log "$CYAN" "$@"; }
ok() { log "$GREEN" "$@"; }
warn() { log "$YELLOW" "$@"; }
err() { log "$RED" "$@" >&2; }
die() { err "$*"; exit 1; }

on_err() {
  local rc=$1 line=$2 cmd=${3:-}
  (( ERR_TRAP_ACTIVE )) && exit "$rc"
  ERR_TRAP_ACTIVE=1
  err "执行失败：rc=$rc line=$line cmd=$cmd"
  local i
  for ((i=1; i<${#FUNCNAME[@]}; i++)); do
    err "  调用栈: ${FUNCNAME[$i]}:${BASH_LINENO[$((i-1))]}"
  done
  exit "$rc"
}

cleanup() {
  local p
  for p in "${TMP_PATHS[@]:-}"; do [[ -n $p ]] && rm -rf -- "$p" 2>/dev/null || true; done
  (( LOCK_HELD )) && flock -u 9 2>/dev/null || true
}
trap 'on_err $? ${LINENO} "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ===== 运行环境与依赖检查 =====
need_root() { (( EUID == 0 )) || die '错误：请使用 root 用户运行此脚本。'; }

need_bash() {
  [[ -n ${BASH_VERSINFO[0]:-} ]] || die '错误：必须使用 Bash 运行此脚本。'
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) || die '错误：要求 Bash 4.3 或更高版本。'
}

require_cmds() {
  local missing=() cmd
  for cmd in "$@"; do
    case $cmd in
      nft) [[ -n $NFT_BIN ]] || missing+=('nft') ;;
      sysctl) [[ -n $SYSCTL_BIN ]] || missing+=('sysctl') ;;
      systemctl) [[ -n $SYSTEMCTL_BIN ]] || missing+=('systemctl') ;;
      awk) type -P awk >/dev/null 2>&1 || missing+=('awk') ;;
      *) type -P "$cmd" >/dev/null 2>&1 || missing+=("$cmd") ;;
    esac
  done
  (( ${#missing[@]} == 0 )) || die "错误：缺少依赖：${missing[*]}"
}

need_cmds_for() {
  local cmd=$1
  case $cmd in
    preview) require_cmds nft flock mktemp ;;
    apply) require_cmds nft sysctl flock mktemp grep ;;
    rollback) require_cmds nft sysctl flock mktemp ;;
    status) require_cmds nft awk ;;
    init|disable-service|open-add|open-del|forward-add|forward-del) require_cmds flock mktemp ;;
    enable-service) require_cmds nft sysctl flock mktemp cmp ;;
    sample|menu|open-list|forward-list) : ;;
    *) : ;;
  esac
}

acquire_lock() {
  (( LOCK_HELD )) && return 0
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

# ===== 快照、恢复与 service 状态 =====
snapshot_one() {
  local src=$1 dst=$2
  if [[ -e $src ]]; then
    printf 'present\n' >"${dst}.state" || return 1
    cp -f -- "$src" "$dst" || return 1
  else
    printf 'absent\n' >"${dst}.state" || return 1
    : >"$dst" || return 1
  fi
}

snapshot_state_of() {
  local snapfile=$1 state='absent'
  [[ -f ${snapfile}.state ]] && IFS= read -r state <"${snapfile}.state" || true
  printf '%s' "$state"
}

snapshot_has_file() { [[ $(snapshot_state_of "$1") == present ]]; }

restore_path_from_snapshot() {
  local snapfile=$1 dst=$2 mode=$3
  if snapshot_has_file "$snapfile"; then
    atomic_install "$snapfile" "$dst" "$mode"
  else
    rm -f -- "$dst"
  fi
}

service_is_enabled() {
  if [[ -n $SYSTEMCTL_BIN ]]; then
    "$SYSTEMCTL_BIN" is-enabled --quiet nft-manager.service >/dev/null 2>&1
  else
    [[ -L $SERVICE_WANTS_LINK ]]
  fi
}

service_active_state() {
  local state='inactive'
  if [[ -n $SYSTEMCTL_BIN ]]; then
    state=$("$SYSTEMCTL_BIN" is-active nft-manager.service 2>/dev/null || true)
    [[ -n $state ]] || state='inactive'
    printf '%s' "$state"
  else
    [[ -f $SERVICE_FILE ]] && printf 'unknown' || printf 'inactive'
  fi
}

save_service_state() {
  local enabled_file=$1 active_file=${2:-}
  if service_is_enabled; then
    printf 'enabled\n' >"$enabled_file"
  else
    printf 'disabled\n' >"$enabled_file"
  fi
  if [[ -n $active_file ]]; then
    service_active_state >"$active_file" || return 1
  fi
}

restore_service_state() {
  local enabled_file=$1 active_file=${2:-} enabled_state='disabled' active_state='inactive'
  [[ -f $enabled_file ]] && IFS= read -r enabled_state <"$enabled_file" || true
  [[ -n $active_file && -f $active_file ]] && IFS= read -r active_state <"$active_file" || true
  if [[ -n $SYSTEMCTL_BIN ]]; then
    "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
    if [[ $enabled_state == enabled ]]; then
      "$SYSTEMCTL_BIN" enable nft-manager.service >/dev/null 2>&1 || return 1
    else
      "$SYSTEMCTL_BIN" disable nft-manager.service >/dev/null 2>&1 || true
      rm -f -- "$SERVICE_WANTS_LINK" 2>/dev/null || true
    fi
    case $active_state in
      active|activating|reloading)
        "$SYSTEMCTL_BIN" start nft-manager.service >/dev/null 2>&1 || return 1
        ;;
      inactive|deactivating|failed)
        "$SYSTEMCTL_BIN" stop nft-manager.service >/dev/null 2>&1 || true
        ;;
      *)
        :
        ;;
    esac
  else
    mkdir -p -- "${SERVICE_WANTS_LINK%/*}" || return 1
    if [[ $enabled_state == enabled ]]; then
      ln -sfn -- "$SERVICE_FILE" "$SERVICE_WANTS_LINK"
    else
      rm -f -- "$SERVICE_WANTS_LINK"
    fi
  fi
}

snapshot_paths() {
  local snap; snap=$(tmp_dir) || return 1
  snapshot_one "$NFT_RULE_FILE" "$snap/rules.nft" || return 1
  snapshot_one "$PREVIEW_RULE_FILE" "$snap/rules.preview.nft" || return 1
  snapshot_one "$LAST_RULE_FILE" "$snap/last_active_ruleset.nft" || return 1
  snapshot_one "$LAST_SYSCTL_FILE" "$snap/last_active_sysctl.conf" || return 1
  snapshot_one "$PREV_RULE_FILE" "$snap/previous_active_ruleset.nft" || return 1
  snapshot_one "$PREV_SYSCTL_FILE" "$snap/previous_active_sysctl.conf" || return 1
  snapshot_one "$SYSCTL_FILE" "$snap/sysctl.conf" || return 1
  snapshot_one "$LOADER_FILE" "$snap/load_saved_rules.sh" || return 1
  snapshot_one "$SERVICE_FILE" "$snap/nft-manager.service" || return 1
  save_service_state "$snap/service_enabled.state" "$snap/service_active.state" || return 1
  printf '%s' "$snap"
}

restore_snapshot() {
  local snap=$1
  restore_path_from_snapshot "$snap/rules.nft" "$NFT_RULE_FILE" 600 || return 1
  restore_path_from_snapshot "$snap/rules.preview.nft" "$PREVIEW_RULE_FILE" 600 || return 1
  restore_path_from_snapshot "$snap/last_active_ruleset.nft" "$LAST_RULE_FILE" 600 || return 1
  restore_path_from_snapshot "$snap/last_active_sysctl.conf" "$LAST_SYSCTL_FILE" 600 || return 1
  restore_path_from_snapshot "$snap/previous_active_ruleset.nft" "$PREV_RULE_FILE" 600 || return 1
  restore_path_from_snapshot "$snap/previous_active_sysctl.conf" "$PREV_SYSCTL_FILE" 600 || return 1
  restore_path_from_snapshot "$snap/sysctl.conf" "$SYSCTL_FILE" 644 || return 1
  restore_path_from_snapshot "$snap/load_saved_rules.sh" "$LOADER_FILE" 700 || return 1
  restore_path_from_snapshot "$snap/nft-manager.service" "$SERVICE_FILE" 644 || return 1
  restore_service_state "$snap/service_enabled.state" "$snap/service_active.state" || return 1
}

# ===== 文本标准化与基础校验 =====
trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
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

line_has_unsafe_chars() {
  local s=$1
  s=${s//$'\t'/}
  [[ $s =~ [[:cntrl:]] ]] && return 0
  return 1
}

validate_line_tokens_safe() {
  local s=$1
  line_has_unsafe_chars "$s" && return 1
  [[ $s != *'`'* && $s != *'\'* ]] || return 1
  return 0
}

to_dec() { [[ $1 =~ ^[0-9]+$ ]] || return 1; printf '%u' "$((10#$1))"; }
validate_rate() { [[ $1 =~ ^[0-9]+/(second|minute|hour|day)$ ]]; }

validate_timeout() { [[ $1 =~ ^[0-9]+(ms|s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hour|hours|d|day|days|w|week|weeks)$ ]]; }
validate_policy() { [[ $1 == accept || $1 == drop ]]; }
validate_iface() { [[ -z $1 || $1 =~ ^[A-Za-z0-9_.:-]+$ ]]; }
validate_hex_u32() { [[ $1 =~ ^0x[0-9a-fA-F]+$ ]]; (( 16#${1#0x} <= 0xFFFFFFFF )); }

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
  local host=${1,,} left right part count=0 i
  local -a _left_parts=() _right_parts=()
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
    IFS=':' read -r -a _left_parts <<<"$left"
    for i in "${!_left_parts[@]}"; do
      part=${_left_parts[$i]}
      [[ -n $part ]] || return 1
      if [[ $part == *.* ]]; then
        (( i == ${#_left_parts[@]} - 1 )) || return 1
        [[ -z $right ]] || return 1
        validate_ipv4_host "$part" || return 1
        (( count += 2 ))
      else
        [[ $part =~ ^[0-9a-f]{1,4}$ ]] || return 1
        ((++count))
      fi
    done
  fi

  if [[ -n $right ]]; then
    IFS=':' read -r -a _right_parts <<<"$right"
    for i in "${!_right_parts[@]}"; do
      part=${_right_parts[$i]}
      [[ -n $part ]] || return 1
      if [[ $part == *.* ]]; then
        (( i == ${#_right_parts[@]} - 1 )) || return 1
        validate_ipv4_host "$part" || return 1
        (( count += 2 ))
      else
        [[ $part =~ ^[0-9a-f]{1,4}$ ]] || return 1
        ((++count))
      fi
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

port_spec_contains() {
  local spec=$1 target=$2 a b
  [[ $target =~ ^[0-9]+$ ]] || return 1
  if [[ $spec =~ ^[0-9]+$ ]]; then
    [[ $spec == "$target" ]]
    return
  fi
  if [[ $spec =~ ^([0-9]+)-([0-9]+)$ ]]; then
    a=$(to_dec "${BASH_REMATCH[1]}") || return 1
    b=$(to_dec "${BASH_REMATCH[2]}") || return 1
    (( target >= a && target <= b ))
    return
  fi
  return 1
}

validate_single_port() {
  local normalized=''
  normalized=$(normalize_port_or_range "$1") || return 1
  [[ $normalized != *-* ]] || return 1
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

# ===== 规则片段输出辅助 =====
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
  local bits=$1 full rem
  local -a vals=(0 0 0 0)
  [[ $bits =~ ^[0-9]+$ ]] || return 1
  (( bits >= 0 && bits <= 32 )) || return 1
  full=$((bits / 8)); rem=$((bits % 8))
  local i
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

# ===== 列表解析与命令参数解析 =====
read_lines_with_lineno() {
  local file=$1 raw line n=0
  [[ -f $file ]] || return 0
  while IFS= read -r raw || [[ -n $raw ]]; do
    ((++n))
    line=$(normalize_line "$raw")
    [[ -z $line ]] && continue
    validate_line_tokens_safe "$line" || die "${file##*/} 第 $n 行包含控制字符或危险转义字符。"
    printf '%s\t%s\n' "$n" "$line"
  done <"$file"
}

walk_parsed_lines() {
  local file=$1 parser=$2 label=$3 handler=$4 n line
  while IFS=$'\t' read -r n line; do
    "$parser" "$line" || die "$label 第 $n 行格式错误：$line"
    "$handler" "$n"
  done < <(read_lines_with_lineno "$file")
}

parse_kv_opts() {
  local target_name=$1; shift
  local -n out="$target_name"
  local tok key val
  local -A seen=()
  out=([src]='' [burst]='' [mask]='' [action]='')
  for tok in "$@"; do
    key=${tok%%=*}; val=${tok#*=}
    [[ -n ${seen[$key]+x} ]] && return 1
    seen[$key]=1
    case $key in
      src) out[src]=$val ;;
      burst) out[burst]=$(normalize_burst "$val") || return 1 ;;
      mask) [[ $val =~ ^[0-9]+$ ]] || return 1; out[mask]=$val ;;
      action) [[ $val == drop || $val == reject ]] || return 1; out[action]=$val ;;
      *) return 1 ;;
    esac
  done
}

parse_rate_opts() {
  local target_name=$1; shift
  local -n out="$target_name"
  local tok key val
  local -A seen=()
  out=([src]='' [burst]='')
  for tok in "$@"; do
    key=${tok%%=*}; val=${tok#*=}
    [[ -n ${seen[$key]+x} ]] && return 1
    seen[$key]=1
    case $key in
      src) out[src]=$val ;;
      burst) out[burst]=$(normalize_burst "$val") || return 1 ;;
      *) return 1 ;;
    esac
  done
}

parse_trace_opts() {
  local target_name=$1; shift
  local -n out="$target_name"
  local tok key val
  local -A seen=()
  out=([src]='')
  for tok in "$@"; do
    key=${tok%%=*}; val=${tok#*=}
    [[ -n ${seen[$key]+x} ]] && return 1
    seen[$key]=1
    case $key in
      src) out[src]=$val ;;
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

parse_block_ip_line() { B_IP=$1; validate_addr_or_prefix "$B_IP" || return 1; }
parse_block_port_line() { parse_allow_port_line "$1"; }

parse_rate_line() {
  local -a a; local -A opt=([src]='' [burst]='')
  read -r -a a <<<"$1"
  (( ${#a[@]} >= 3 )) || return 1
  P_PROTO=$(normalize_proto "${a[0]}") || return 1
  P_PORT=$(normalize_port_or_range "${a[1]}") || return 1
  P_RATE=${a[2]}; validate_rate "$P_RATE" || return 1
  (( ${#a[@]} == 3 )) || parse_rate_opts opt "${a[@]:3}" || return 1
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
  local -a a; local -A opt=([src]='')
  read -r -a a <<<"$1"
  (( ${#a[@]} >= 2 )) || return 1
  P_PROTO=$(normalize_proto "${a[0]}") || return 1
  P_PORT=$(normalize_port_or_range "${a[1]}") || return 1
  P_SRC=''
  (( ${#a[@]} > 2 )) && { parse_trace_opts opt "${a[@]:2}" || return 1; P_SRC=${opt[src]}; }
  validate_addr_match_token "$P_SRC" || return 1
}

parse_forward_line() {
  local -a a; local i tok family src_family saw_src=0
  read -r -a a <<<"$1"
  (( ${#a[@]} >= 3 )) || return 1
  F_PROTO=$(normalize_proto "${a[0]}") || return 1
  F_EXT_PORT=$(normalize_port_or_range "${a[1]}") || return 1
  F_TARGET_IP=${a[2]}
  validate_addr_or_prefix "$F_TARGET_IP" || return 1
  [[ $F_TARGET_IP != */* ]] || return 1
  F_TARGET_PORT=$F_EXT_PORT
  F_SRC=''
  if (( ${#a[@]} >= 4 )); then
    if [[ ${a[3]} == *=* ]]; then
      for ((i=3; i<${#a[@]}; i++)); do
        tok=${a[i]}
        [[ $tok == src=* ]] || return 1
        (( saw_src == 0 )) || return 1
        saw_src=1
        F_SRC=${tok#src=}
      done
    else
      F_TARGET_PORT=$(normalize_port_or_range "${a[3]}") || return 1
      for ((i=4; i<${#a[@]}; i++)); do
        tok=${a[i]}
        [[ $tok == src=* ]] || return 1
        (( saw_src == 0 )) || return 1
        saw_src=1
        F_SRC=${tok#src=}
      done
    fi
  fi
  validate_forward_port_mapping "$F_EXT_PORT" "$F_TARGET_PORT" || return 1
  validate_addr_match_token "$F_SRC" || return 1
  family=$(forward_target_family "$F_TARGET_IP")
  if [[ -n $F_SRC ]]; then
    src_family=$(forward_target_family "$F_SRC")
    [[ $src_family == $family ]] || return 1
  fi
}

count_valid_forward_entries() {
  local n line c=0
  while IFS=$'\t' read -r n line; do parse_forward_line "$line" || return 1; ((++c)); done < <(read_lines_with_lineno "$FORWARD_FILE")
  printf '%s' "$c"
}

count_valid_forward_entries_family() {
  local family=$1 n line c=0
  while IFS=$'\t' read -r n line; do
    parse_forward_line "$line" || return 1
    [[ $(forward_target_family "$F_TARGET_IP") == "$family" ]] || continue
    ((++c))
  done < <(read_lines_with_lineno "$FORWARD_FILE")
  printf '%s' "$c"
}

hex32_not() {
  local v=$1
  printf '0x%08x' $(( (0xFFFFFFFF ^ v) & 0xFFFFFFFF ))
}

validate_mark_field() {
  local hex=${CFG[FORWARD_MARK_HEX]} mask=${CFG[FORWARD_MARK_MASK]}
  (( mask != 0 )) || die 'settings.conf 中 FORWARD_MARK_MASK 不能为 0。'
  (( hex  != 0 )) || die 'settings.conf 中 FORWARD_MARK_HEX 不能为 0。'
  (( (hex & mask) == hex )) || die 'settings.conf 中 FORWARD_MARK_HEX 必须完全落在 FORWARD_MARK_MASK 指定的 field 内。'
}

mark_match_expr() {
  printf 'ct mark and %s == %s' "${CFG[FORWARD_MARK_MASK]}" "${CFG[FORWARD_MARK_HEX]}"
}

mark_set_expr() {
  local clear_mask
  clear_mask=$(hex32_not "${CFG[FORWARD_MARK_MASK]}") || return 1
  printf 'meta mark set (meta mark and %s) or %s ct mark set (ct mark and %s) or %s' \
    "$clear_mask" "${CFG[FORWARD_MARK_HEX]}" "$clear_mask" "${CFG[FORWARD_MARK_HEX]}"
}

dnat_to_expr() {
  local family=$1 addr=$2 port=$3
  if [[ $family == ip6 ]]; then
    printf 'dnat to [%s]:%s' "$addr" "$port"
  else
    printf 'dnat to %s:%s' "$addr" "$port"
  fi
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

ratelimit_set_name() { printf 'ratelimit_l%04d_%s_%s' "$1" "$2" "$3"; }
ratelimit_set_type() { [[ $1 == ip ]] && printf 'ipv4_addr' || printf 'ipv6_addr'; }
ratelimit_families() {
  local src=${1:-}
  if [[ -n $src ]]; then
    [[ $src == *:* ]] && printf 'ip6\n' || printf 'ip\n'
  else
    printf 'ip\nip6\n'
  fi
}

connlimit_families() {
  local src=${1:-} mask=${2:-}
  if [[ -n $src ]]; then
    [[ $src == *:* ]] && printf 'ip6\n' || printf 'ip\n'
  elif [[ -n $mask ]]; then
    printf 'ip\n'
  else
    printf 'ip\nip6\n'
  fi
}

forward_target_family() { [[ -n ${1:-} && ${1:-} == *:* ]] && printf 'ip6' || printf 'ip'; }
connlimit_set_name() { printf 'connlimit_l%04d_%s_%s' "$1" "$2" "$3"; }
connlimit_set_type() { [[ $1 == ip ]] && printf 'ipv4_addr' || printf 'ipv6_addr'; }

emit_ratelimit_set_decl_one() {
  local lineno=$1 proto=$2 family=$3 setname type
  setname=$(ratelimit_set_name "$lineno" "$proto" "$family")
  type=$(ratelimit_set_type "$family")
  printf '  set %s {\n    type %s\n    size 65535\n    timeout %s\n    flags dynamic\n  }\n' \
    "$setname" "$type" "${CFG[RATELIMIT_TIMEOUT]}"
}

render_ratelimit_sets() {
  local n line family proto
  while IFS=$'\t' read -r n line; do
    parse_rate_line "$line" || die "ratelimit.list 第 $n 行格式错误：$line"
    for proto in $( [[ $P_PROTO == both ]] && echo "tcp udp" || echo "$P_PROTO" ); do
      while IFS= read -r family; do
        [[ -n $family ]] || continue
        emit_ratelimit_set_decl_one "$n" "$proto" "$family"
      done < <(ratelimit_families "$P_SRC")
    done
  done < <(read_lines_with_lineno "$RATELIMIT_FILE")
}

emit_connlimit_set_decl_one() {
  local lineno=$1 proto=$2 family=$3 setname type
  type=$(connlimit_set_type "$family")
  setname=$(connlimit_set_name "$lineno" "$proto" "$family")
  printf '  set %s {\n    type %s\n    size 65535\n    flags dynamic\n  }\n' "$setname" "$type"
}

emit_connlimit_set_decls_for_parsed() {
  local lineno=$1 proto family
  for proto in $( [[ $P_PROTO == both ]] && echo "tcp udp" || echo "$P_PROTO" ); do
    while IFS= read -r family; do
      [[ -n $family ]] || continue
      emit_connlimit_set_decl_one "$lineno" "$proto" "$family"
    done < <(connlimit_families "$P_SRC" "$P_MASK")
  done
}

render_connlimit_sets() {
  local n line
  while IFS=$'\t' read -r n line; do
    parse_connlimit_line "$line" || die "connlimit.list 第 $n 行格式错误：$line"
    emit_connlimit_set_decls_for_parsed "$n"
  done < <(read_lines_with_lineno "$CONNLIMIT_FILE")
}

emit_rate_limit_one() {
  local family=$1 proto=$2 port=$3 rate=$4 burst=$5 src=$6 setname expr
  setname=$(ratelimit_set_name "$7" "$proto" "$family")
  expr='ct state new '
  [[ -n $src ]] && expr+="$family saddr $src "
  expr+="$proto dport $port update @$setname { $family saddr timeout ${CFG[RATELIMIT_TIMEOUT]} limit rate over $rate"
  [[ -n $burst ]] && expr+=" burst $burst"
  expr+=" } $(counter_stmt)drop"
  printf '    %s\n' "$expr"
}

emit_rate_limit_rule() {
  local lineno=$1 family proto
  for proto in $( [[ $P_PROTO == both ]] && echo "tcp udp" || echo "$P_PROTO" ); do
    while IFS= read -r family; do
      [[ -n $family ]] || continue
      emit_rate_limit_one "$family" "$proto" "$P_PORT" "$P_RATE" "$P_BURST" "$P_SRC" "$lineno"
    done < <(ratelimit_families "$P_SRC")
  done
}

emit_connlimit_one() {
  local lineno=$1 family=$2 proto=$3 port=$4 limit=$5 mask=$6 src=$7 action=$8 selector verdict='drop' setname src_match=''
  if [[ -n $mask ]]; then
    selector=$(selector_for_mask "$family" "$mask") || die "connlimit 第 $lineno 行使用了不支持的 mask=$mask（IPv6 请改用 src=前缀）。"
  else
    selector=$(selector_for_mask "$family" "$([[ $family == ip ]] && echo 32 || echo 128)") || return 1
  fi
  [[ -n $src ]] && src_match="$family saddr $src "
  [[ $action == reject ]] && verdict=$([[ $proto == tcp ]] && echo 'reject with tcp reset' || echo 'reject')
  setname=$(connlimit_set_name "$lineno" "$proto" "$family")
  printf '    ct state new %s%s dport %s add @%s { %s ct count over %s } %s%s\n' \
    "$src_match" "$proto" "$port" "$setname" "$selector" "$limit" "$(counter_stmt)" "$verdict"
}

emit_connlimit_rule() {
  local lineno=$1 family proto
  for proto in $( [[ $P_PROTO == both ]] && echo "tcp udp" || echo "$P_PROTO" ); do
    while IFS= read -r family; do
      [[ -n $family ]] || continue
      emit_connlimit_one "$lineno" "$family" "$proto" "$P_PORT" "$P_LIMIT" "$P_MASK" "$P_SRC" "$P_ACTION"
    done < <(connlimit_families "$P_SRC" "$P_MASK")
  done
}

emit_plain_allow_parsed() { emit_allow_rule "$P_PROTO" "$P_PORT"; }
emit_acl_allow_parsed() { emit_allow_rule "$P_PROTO" "$P_PORT" "$(src_expr "$P_SRC")"; }
emit_block_port_parsed() { emit_block_port_rule "$P_PROTO" "$P_PORT"; }
emit_rate_limit_parsed() { emit_rate_limit_rule "$1"; }
emit_connlimit_parsed() { emit_connlimit_rule "$1"; }
emit_trace_parsed() { emit_trace_rule "$P_PROTO" "$P_PORT" "$(src_expr "$P_SRC")"; }

render_connlimit_rules() {
  local n line
  while IFS=$'\t' read -r n line; do
    parse_connlimit_line "$line" || die "connlimit.list 第 $n 行格式错误：$line"
    emit_connlimit_parsed "$n"
  done < <(read_lines_with_lineno "$CONNLIMIT_FILE")
}

emit_forward_accept_one() {
  local proto=$1 target_ip=$2 target_port=$3 src=$4 family src_clause=''
  family=$(forward_target_family "$target_ip")
  [[ -n $src ]] && src_clause="$family saddr $src "
  printf '    %s %s daddr %s %s%s dport %s %saccept\n' \
    "$(mark_match_expr)" "$family" "$target_ip" "$src_clause" "$proto" "$target_port" "$(counter_stmt)"
}
emit_forward_accept_parsed() { proto_each "$F_PROTO" emit_forward_accept_one "$F_TARGET_IP" "$F_TARGET_PORT" "$F_SRC"; }

emit_dnat_one() {
  local proto=$1 ext_port=$2 target_ip=$3 target_port=$4 src=$5 family src_clause='' dnat_expr
  family=$(forward_target_family "$target_ip")
  [[ -n $src ]] && src_clause="$family saddr $src "
  dnat_expr=$(dnat_to_expr "$family" "$target_ip" "$target_port") || return 1
  printf '    iifname "%s" %s%s dport %s %s %s\n' \
    "${CFG[WAN_IFACE]}" "$src_clause" "$proto" "$ext_port" "$(mark_set_expr)" "$dnat_expr"
}
emit_prerouting_dnat_parsed() { proto_each "$F_PROTO" emit_dnat_one "$F_EXT_PORT" "$F_TARGET_IP" "$F_TARGET_PORT" "$F_SRC"; }

emit_masq_one() {
  local family=$1
  printf '    %s oifname "%s" masquerade\n' "$(mark_match_expr)" "${CFG[WAN_IFACE]}"
}
emit_postrouting_masq_parsed() { emit_masq_one "$1"; }

# ===== ruleset 渲染 =====
emit_block_sets() {
  local n line e; local -a v4=() v6=()
  while IFS=$'\t' read -r n line; do
    parse_block_ip_line "$line" || return 1
    is_ipv6 "$B_IP" && v6+=("$B_IP") || v4+=("$B_IP")
  done < <(read_lines_with_lineno "$BLOCK_IP_FILE")

  printf '  set blocked_v4 {\n    type ipv4_addr\n    flags interval\n    auto-merge\n'
  if ((${#v4[@]})); then
    printf '    elements = { %s' "${v4[0]}"
    for e in "${v4[@]:1}"; do printf ', %s' "$e"; done
    printf ' }\n'
  fi
  printf '  }\n'

  printf '  set blocked_v6 {\n    type ipv6_addr\n    flags interval\n    auto-merge\n'
  if ((${#v6[@]})); then
    printf '    elements = { %s' "${v6[0]}"
    for e in "${v6[@]:1}"; do printf ', %s' "$e"; done
    printf ' }\n'
  fi
  printf '  }\n'
}

render_block_ip_rules() {
  local chain=$1
  case $chain in
    input)
      printf '    ip saddr @blocked_v4 %sdrop\n' "$(counter_stmt)"
      printf '    ip6 saddr @blocked_v6 %sdrop\n' "$(counter_stmt)"
      ;;
    output)
      printf '    ip daddr @blocked_v4 %sdrop\n' "$(counter_stmt)"
      printf '    ip6 daddr @blocked_v6 %sdrop\n' "$(counter_stmt)"
      ;;
    forward)
      printf '    ip saddr @blocked_v4 %sdrop\n' "$(counter_stmt)"
      printf '    ip daddr @blocked_v4 %sdrop\n' "$(counter_stmt)"
      printf '    ip6 saddr @blocked_v6 %sdrop\n' "$(counter_stmt)"
      printf '    ip6 daddr @blocked_v6 %sdrop\n' "$(counter_stmt)"
      ;;
  esac
}

render_base_chain() {
  local chain=$1 hook=$2 policy=$3
  printf '  chain %s {\n' "$chain"
  printf '    type filter hook %s priority filter; policy %s;\n' "$hook" "$policy"
  printf '    ct state invalid %sdrop\n' "$(counter_stmt)"
  [[ $chain == input ]] && printf '    iifname "lo" %saccept\n' "$(counter_stmt)"
  [[ $chain == output ]] && printf '    oifname "lo" %saccept\n' "$(counter_stmt)"
  render_block_ip_rules "$chain"
  printf '    ct state established,related %saccept\n' "$(counter_stmt)"
}

has_explicit_ssh_open_rule() {
  local n line ssh_port
  ssh_port=${CFG[SSH_PORT]:-22}

  while IFS=$'\t' read -r n line; do
    parse_allow_port_line "$line" || continue
    port_spec_contains "$P_PORT" "$ssh_port" || continue
    [[ $P_PROTO == tcp || $P_PROTO == both ]] && return 0
  done < <(read_lines_with_lineno "$ALLOW_FILE")

  while IFS=$'\t' read -r n line; do
    parse_allow_port_line "$line" || continue
    port_spec_contains "$P_PORT" "$ssh_port" || continue
    [[ $P_PROTO == tcp || $P_PROTO == both ]] && return 0
  done < <(read_lines_with_lineno "$ALLOW_RANGE_FILE")

  while IFS=$'\t' read -r n line; do
    parse_acl_line "$line" || continue
    port_spec_contains "$P_PORT" "$ssh_port" || continue
    [[ $P_PROTO == tcp || $P_PROTO == both ]] && return 0
  done < <(read_lines_with_lineno "$ALLOW_ACL_FILE")

  return 1
}

render_input_chain() {
  render_base_chain input input "${CFG[INPUT_POLICY]}"
  [[ ${CFG[AUTO_OPEN_SSH_PORT]} == yes ]] && ! has_explicit_ssh_open_rule && printf '    tcp dport %s %saccept\n' "${CFG[SSH_PORT]}" "$(counter_stmt)"
  [[ ${CFG[ALLOW_PING_V4]} == yes ]] && printf '    ip protocol icmp icmp type echo-request limit rate %s %saccept\n' "${CFG[PING_V4_RATE]}" "$(counter_stmt)"
  [[ ${CFG[ALLOW_PING_V6]} == yes ]] && printf '    ip6 nexthdr icmpv6 icmpv6 type echo-request limit rate %s %saccept\n' "${CFG[PING_V6_RATE]}" "$(counter_stmt)"
  printf '    ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } %saccept\n' "$(counter_stmt)"
  [[ ${CFG[ALLOW_IPV6_ND]} == yes ]] && printf '    ip6 nexthdr icmpv6 icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } %saccept\n' "$(counter_stmt)"

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
  render_ratelimit_sets
  render_connlimit_sets
  render_input_chain
  render_forward_chain
  render_output_chain
  printf '}\n'
}

render_nat_table_family() {
  local family=$1 n line valid
  valid=$(count_valid_forward_entries_family "$family") || die 'forward.list 存在格式错误，拒绝生成 NAT。'
  (( valid > 0 )) || return 0

  printf 'table %s %s {\n' "$family" "$TABLE_NAT"
  printf '  chain prerouting {\n    type nat hook prerouting priority dstnat; policy accept;\n'
  while IFS=$'\t' read -r n line; do
    parse_forward_line "$line" || die "forward.list 第 $n 行格式错误：$line"
    [[ $(forward_target_family "$F_TARGET_IP") == "$family" ]] || continue
    emit_prerouting_dnat_parsed
  done < <(read_lines_with_lineno "$FORWARD_FILE")
  printf '  }\n'
  printf '  chain postrouting {\n    type nat hook postrouting priority srcnat; policy accept;\n'
  if [[ ${CFG[ENABLE_FORWARD_SNAT]} == yes ]]; then
    emit_postrouting_masq_parsed "$family"
  fi
  printf '  }\n}\n'
}

render_nat_table() {
  local valid4 valid6
  valid4=$(count_valid_forward_entries_family ip) || die 'forward.list 存在格式错误，拒绝生成 NAT。'
  valid6=$(count_valid_forward_entries_family ip6) || die 'forward.list 存在格式错误，拒绝生成 NAT。'
  (( valid4 + valid6 > 0 )) || return 0
  [[ -n ${CFG[WAN_IFACE]} ]] || die 'forward.list 存在有效规则，但 settings.conf 中未设置 WAN_IFACE。'
  if (( valid4 > 0 )); then
    render_nat_table_family ip
  fi
  if (( valid6 > 0 )); then
    render_nat_table_family ip6
  fi
  return 0
}

# ===== 规则文件、sysctl 与运行态应用 =====
compile_rules_to_file() {
  local out=$1
  RULE_SEQ=0
  : >"$out" || return 1
  render_filter_table >>"$out" || return 1
  render_nat_table >>"$out" || return 1
}

build_sysctl_file() {
  local out=$1 valid4 valid6 v4=0 v6=0 modes=()
  valid4=$(count_valid_forward_entries_family ip) || die 'forward.list 存在格式错误，拒绝生成 sysctl。'
  valid6=$(count_valid_forward_entries_family ip6) || die 'forward.list 存在格式错误，拒绝生成 sysctl。'
  (( valid4 > 0 )) && { v4=1; modes+=(forward4-enabled); } || modes+=(forward4-disabled)
  if (( valid6 > 0 )) || [[ ${CFG[ENABLE_IPV6_FORWARD]} == yes ]]; then
    v6=1
  fi
  (( valid6 > 0 )) && modes+=(forward6-enabled) || modes+=(forward6-disabled)
  [[ ${CFG[ENABLE_IPV6_FORWARD]} == yes ]] && modes+=(ipv6-manual)
  SYSCTL_LAST_SYNC_MODE=$(IFS=' '; printf '%s' "${modes[*]}")
  {
    printf '# managed by nftables-manager-bash\n'
    printf 'net.ipv4.ip_forward=%s\n' "$v4"
    if sysctl_key_exists 'net.ipv6.conf.all.forwarding'; then
      printf 'net.ipv6.conf.all.forwarding=%s\n' "$v6"
    else
      modes+=(ipv6-sysctl-missing)
      SYSCTL_LAST_SYNC_MODE=$(IFS=' '; printf '%s' "${modes[*]}")
    fi
  } >"$out"
}

validate_rules_file() { "$NFT_BIN" -c -f "$1"; }

validate_sysctl_persist_file() {
  local file=$1 raw line key value
  local -A seen=()
  [[ -f $file ]] || return 1
  while IFS= read -r raw || [[ -n $raw ]]; do
    line=$(normalize_line "$raw")
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || return 1
    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")
    [[ -n $key ]] || return 1
    [[ $key =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    [[ $value == 0 || $value == 1 ]] || return 1
    [[ -z ${seen[$key]+x} ]] || return 1
    case $key in
      net.ipv4.ip_forward|net.ipv6.conf.all.forwarding) seen[$key]=1 ;;
      *) return 1 ;;
    esac
  done <"$file"
  [[ -n ${seen[net.ipv4.ip_forward]+x} ]] || return 1
}

sysctl_key_exists() {
  local key=$1 path
  path=/proc/sys/${key//./\/}
  [[ -e $path ]]
}
table_exists() { "$NFT_BIN" list table "$1" "$2" >/dev/null 2>&1; }

probe_table_state() {
  local family=$1 table=$2 __state_ref=${3:-} __err_ref=${4:-} out msg _state _probe_err
  _probe_err=''
  if out=$("$NFT_BIN" list table "$family" "$table" 2>&1 >/dev/null); then
    _state='present'
  else
    _probe_err=$out
    msg=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')
    case $msg in
      *'no such table'*|*'no such file or directory'*|*'no such file'*|*'not found'*|*'does not exist'*|*'unknown table'*)
        _state='absent'
        ;;
      *'operation not supported'*|*'protocol not supported'*|*'operation not permitted'*|*'permission denied'*|*'access denied'*|*'you must be root'*|*'not permitted'*)
        _state='unreadable'
        ;;
      *)
        _state='error'
        ;;
    esac
  fi
  if [[ -n $__state_ref ]]; then
    printf -v "$__state_ref" '%s' "$_state"
  else
    printf '%s' "$_state"
  fi
  [[ -n $__err_ref ]] && printf -v "$__err_ref" '%s' "$_probe_err"
}

purge_managed_tables_fallback() {
  local family table state probe_err
  while read -r family table; do
    probe_table_state "$family" "$table" state probe_err
    case $state in
      absent)
        ;;
      present)
        if ! "$NFT_BIN" delete table "$family" "$table" >/dev/null 2>&1; then
          err "删除托管表失败：$family $table"
          [[ -n $probe_err ]] && err "  上次探测 stderr: $(printf '%s' "$probe_err" | tr '\n' ' ')"
          return 1
        fi
        probe_table_state "$family" "$table" state probe_err
        [[ $state == absent ]] || {
          err "删除托管表后仍未消失：$family $table（state=$state）"
          [[ -n $probe_err ]] && err "  nft stderr: $(printf '%s' "$probe_err" | tr '\n' ' ')"
          return 1
        }
        ;;
      unreadable)
        err "无法读取托管表状态：$family $table（权限不足或环境受限），拒绝继续。"
        [[ -n $probe_err ]] && err "  nft stderr: $(printf '%s' "$probe_err" | tr '\n' ' ')"
        return 1
        ;;
      error|*)
        err "无法确认托管表状态：$family $table，拒绝继续。"
        [[ -n $probe_err ]] && err "  nft stderr: $(printf '%s' "$probe_err" | tr '\n' ' ')"
        return 1
        ;;
    esac
  done <<EOF
inet $TABLE_FW
ip $TABLE_NAT
ip6 $TABLE_NAT
EOF
}

snapshot_live_managed_tables() {
  local snapdir=$1 manifest rules family table state listed=0 table_tmp table_err probe_err
  manifest="$snapdir/manifest.tsv"
  rules="$snapdir/rules.nft"
  : >"$manifest" || return 1
  : >"$rules" || return 1

  while read -r family table; do
    probe_table_state "$family" "$table" state probe_err
    printf '%s\t%s\t%s\n' "$family" "$table" "$state" >>"$manifest" || return 1
    case $state in
      absent)
        ;;
      present)
        table_tmp=$(tmp_file) || return 1
        table_err=$(tmp_file) || return 1
        if ! "$NFT_BIN" list table "$family" "$table" >"$table_tmp" 2>"$table_err"; then
          err "无法导出 live 运行态表：$family $table"
          [[ -s $table_err ]] && err "  nft stderr: $(tr '\n' ' ' <"$table_err")"
          return 1
        fi
        (( listed )) && printf '\n' >>"$rules"
        cat -- "$table_tmp" >>"$rules" || return 1
        listed=1
        ;;
      unreadable)
        err "无法读取 live 运行态表：$family $table（权限不足或环境受限），拒绝继续。"
        [[ -n $probe_err ]] && err "  nft stderr: $(printf '%s' "$probe_err" | tr '\n' ' ')"
        return 1
        ;;
      error)
        err "无法确认 live 运行态表状态：$family $table，拒绝继续。"
        [[ -n $probe_err ]] && err "  nft stderr: $(printf '%s' "$probe_err" | tr '\n' ' ')"
        return 1
        ;;
      *)
        err "live 运行态表状态返回非法值：$family $table => $state"
        return 1
        ;;
    esac
  done <<EOF
inet $TABLE_FW
ip $TABLE_NAT
ip6 $TABLE_NAT
EOF
}

restore_live_managed_tables() {
  local snapdir=$1 manifest rules family table state had_present=0 key expected_key
  local -A seen=()
  local -a expected=(
    "inet:$TABLE_FW"
    "ip:$TABLE_NAT"
    "ip6:$TABLE_NAT"
  )
  manifest="$snapdir/manifest.tsv"
  rules="$snapdir/rules.nft"
  [[ -f $manifest ]] || { err 'live nft 快照状态文件缺失，拒绝恢复。'; return 1; }

  while IFS=$'\t' read -r family table state || [[ -n ${family:-}${table:-}${state:-} ]]; do
    [[ -n ${family:-} && -n ${table:-} && -n ${state:-} ]] || continue
    key="${family}:${table}"
    [[ -n ${seen[$key]+x} ]] && { err "live nft 快照状态文件包含重复表项：$family $table"; return 1; }
    seen[$key]=1
    case $family in
      inet|ip|ip6) ;;
      *)
        err "live nft 快照状态文件 family 非法：$family"
        return 1
        ;;
    esac
    case $state in
      present)
        had_present=1
        ;;
      absent)
        ;;
      *)
        err "live nft 快照状态文件非法：$family $table => $state"
        return 1
        ;;
    esac
  done <"$manifest"

  for expected_key in "${expected[@]}"; do
    [[ -n ${seen[$expected_key]+x} ]] || { err "live nft 快照状态文件缺少托管表项：$expected_key"; return 1; }
  done
  ((${#seen[@]} == ${#expected[@]})) || { err 'live nft 快照状态文件包含额外表项，拒绝恢复。'; return 1; }

  if (( had_present )); then
    [[ -f $rules ]] || { err 'live nft 快照规则文件缺失，拒绝恢复。'; return 1; }
    [[ -s $rules ]] || { err 'live nft 快照存在 present 表，但规则文件为空，拒绝恢复。'; return 1; }
    if ! apply_managed_tables "$rules"; then
      err "live nft 快照恢复失败：rules=$rules manifest=$manifest"
      err 'live nft 快照状态如下：'
      while IFS= read -r line || [[ -n $line ]]; do
        err "  $line"
      done <"$manifest"
      return 1
    fi
  else
    [[ -f $rules ]] || { err 'live nft 快照规则文件缺失，拒绝恢复。'; return 1; }
    [[ ! -s $rules ]] || { err 'live nft 快照全部 absent，但规则文件非空，拒绝恢复。'; return 1; }
    purge_managed_tables_fallback
  fi
}

list_sysctl_keys_from_file() {
  local file=$1 raw line key
  [[ -f $file ]] || return 0
  while IFS= read -r raw || [[ -n $raw ]]; do
    line=$(normalize_line "$raw")
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || continue
    key=$(trim "${line%%=*}")
    [[ -n $key ]] && printf '%s\n' "$key"
  done <"$file"
}

probe_sysctl_key_state() {
  local key=$1 __state_ref=${2:-} path _state
  path=/proc/sys/${key//./\/}
  if [[ -r $path ]]; then
    _state='present'
  elif [[ -e $path ]]; then
    _state='unreadable'
  else
    _state='absent'
  fi
  if [[ -n $__state_ref ]]; then
    printf -v "$__state_ref" '%s' "$_state"
  else
    printf '%s' "$_state"
  fi
}

snapshot_live_sysctl_for_file() {
  local spec=$1 out=$2 key path value state
  : >"$out" || return 1
  while IFS= read -r key || [[ -n $key ]]; do
    [[ -n $key ]] || continue
    probe_sysctl_key_state "$key" state
    path=/proc/sys/${key//./\/}
    case $state in
      present)
        value=$(<"$path")
        printf 'present\t%s\t%s\n' "$key" "$value" >>"$out" || return 1
        ;;
      absent)
        printf 'absent\t%s\t\n' "$key" >>"$out" || return 1
        ;;
      unreadable)
        err "无法读取 live sysctl 键：$key，拒绝继续。"
        return 1
        ;;
      *)
        err "live sysctl 键状态返回非法值：$key => $state"
        return 1
        ;;
    esac
  done < <(list_sysctl_keys_from_file "$spec")
}

restore_live_sysctl_snapshot() {
  local snap_file=$1 state key value
  local -A seen=()
  [[ -f $snap_file ]] || return 0
  while IFS=$'\t' read -r state key value || [[ -n ${state:-}${key:-}${value:-} ]]; do
    [[ -n ${state:-}${key:-}${value:-} ]] || continue
    [[ -n ${key:-} ]] || { err 'live sysctl 快照存在空键名。'; return 1; }
    [[ $key =~ ^[A-Za-z0-9_.-]+$ ]] || { err "live sysctl 快照键名非法：$key"; return 1; }
    [[ -z ${seen[$key]+x} ]] || { err "live sysctl 快照存在重复键：$key"; return 1; }
    seen[$key]=1
    case $state in
      present)
        "$SYSCTL_BIN" -w "${key}=${value}" >/dev/null || return 1
        ;;
      absent|missing)
        :
        ;;
      *)
        err "live sysctl 快照状态非法：$key => $state"
        return 1
        ;;
    esac
  done <"$snap_file"
}

build_apply_batch_file() {
  local out=$1 rules_file=$2
  : >"$out" || return 1
  table_exists inet "$TABLE_FW" && printf 'delete table inet %s\n' "$TABLE_FW" >>"$out"
  table_exists ip "$TABLE_NAT" && printf 'delete table ip %s\n' "$TABLE_NAT" >>"$out"
  table_exists ip6 "$TABLE_NAT" && printf 'delete table ip6 %s\n' "$TABLE_NAT" >>"$out"
  cat -- "$rules_file" >>"$out" || return 1
}

apply_managed_tables() {
  local rules_file=$1 batch
  batch=$(tmp_file) || return 1
  build_apply_batch_file "$batch" "$rules_file" || return 1
  "$NFT_BIN" -c -f "$batch" || return 1
  "$NFT_BIN" -f "$batch"
}

apply_sysctl_file() { "$SYSCTL_BIN" -p "$1" >/dev/null; }

write_loader_file() {
  local nft_bin_fallback_q sysctl_bin_fallback_q rules_file_q sysctl_file_q fw_table_q nat_table_q
  printf -v nft_bin_fallback_q '%q' "$NFT_BIN"
  printf -v sysctl_bin_fallback_q '%q' "$SYSCTL_BIN"
  printf -v rules_file_q '%q' "$NFT_RULE_FILE"
  printf -v sysctl_file_q '%q' "$SYSCTL_FILE"
  printf -v fw_table_q '%q' "$TABLE_FW"
  printf -v nat_table_q '%q' "$TABLE_NAT"

  cat >"$1" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

on_err() {
  local rc=\$1 line=\$2 cmd=\${3:-}
  printf '%s\n' "nft-manager loader failed: rc=\$rc line=\$line cmd=\$cmd" >&2
  exit "\$rc"
}
trap 'on_err \$? \${LINENO} "\$BASH_COMMAND"' ERR

nft_bin_fallback=$nft_bin_fallback_q
sysctl_bin_fallback=$sysctl_bin_fallback_q
nft_bin=\$(type -P nft 2>/dev/null || true)
sysctl_bin=\$(type -P sysctl 2>/dev/null || true)
[[ -n \$nft_bin ]] || nft_bin=\$nft_bin_fallback
[[ -n \$sysctl_bin ]] || sysctl_bin=\$sysctl_bin_fallback
[[ -n \$nft_bin ]] || { printf '%s\n' 'nft-manager loader failed: nft not found' >&2; exit 127; }
[[ -n \$sysctl_bin ]] || { printf '%s\n' 'nft-manager loader failed: sysctl not found' >&2; exit 127; }
rules_file=$rules_file_q
sysctl_file=$sysctl_file_q
fw_table=$fw_table_q
nat_table=$nat_table_q

tmp_batch=\$(mktemp)
cleanup_loader() { rm -f -- "\$tmp_batch"; }
trap cleanup_loader EXIT

table_exists() {
  "\$nft_bin" list table "\$1" "\$2" >/dev/null 2>&1
}

: >"\$tmp_batch"
table_exists inet "\$fw_table" && printf 'delete table inet %s\n' "\$fw_table" >>"\$tmp_batch"
table_exists ip "\$nat_table" && printf 'delete table ip %s\n' "\$nat_table" >>"\$tmp_batch"
table_exists ip6 "\$nat_table" && printf 'delete table ip6 %s\n' "\$nat_table" >>"\$tmp_batch"
cat -- "\$rules_file" >>"\$tmp_batch"
"\$nft_bin" -c -f "\$tmp_batch"
"\$nft_bin" -f "\$tmp_batch"
"\$sysctl_bin" -p "\$sysctl_file" >/dev/null
EOF
}

write_service_file() {
  cat >"$1" <<EOF
[Unit]
Description=nft-manager managed rules
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target
After=local-fs.target
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=$LOADER_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

export_prev_rules_from_live_snapshot() {
  local snapdir=$1 out=$2 manifest rules family table state had_present=0
  manifest="$snapdir/manifest.tsv"
  rules="$snapdir/rules.nft"
  [[ -f $manifest ]] || { err 'live nft 快照状态文件缺失，无法导出 PREV 规则。'; return 1; }
  while IFS=$'\t' read -r family table state || [[ -n ${family:-}${table:-}${state:-} ]]; do
    [[ -n ${family:-} && -n ${table:-} && -n ${state:-} ]] || continue
    case $state in
      present) had_present=1 ;;
      absent) ;;
      *)
        err "live nft 快照状态文件非法：$family $table => $state"
        return 1
        ;;
    esac
  done <"$manifest"
  if (( had_present )); then
    [[ -f $rules ]] || { err 'live nft 快照规则文件缺失，无法导出 PREV 规则。'; return 1; }
    [[ -s $rules ]] || { err 'live nft 快照存在 present 表，但规则文件为空，无法导出 PREV 规则。'; return 1; }
    cat -- "$rules" >"$out" || return 1
  else
    [[ -f $rules ]] || { err 'live nft 快照规则文件缺失，无法导出 PREV 规则。'; return 1; }
    [[ ! -s $rules ]] || { err 'live nft 快照全部 absent，但规则文件非空，无法导出 PREV 规则。'; return 1; }
    : >"$out" || return 1
  fi
}

export_prev_sysctl_from_live_snapshot() {
  local snap_file=$1 out=$2 state key value
  [[ -f $snap_file ]] || { err 'live sysctl 快照文件缺失，无法导出 PREV sysctl。'; return 1; }
  : >"$out" || return 1
  while IFS=$'\t' read -r state key value || [[ -n ${state:-}${key:-}${value:-} ]]; do
    [[ -n ${state:-} && -n ${key:-} ]] || continue
    case $state in
      present)
        printf '%s=%s\n' "$key" "$value" >>"$out" || return 1
        ;;
      absent|missing)
        :
        ;;
      *)
        err "live sysctl 快照状态文件非法：$key => $state"
        return 1
        ;;
    esac
  done <"$snap_file"
}

persist_generated_files() {
  local rules=$1 sysctl_tmp=$2 loader_tmp=$3 service_tmp=$4 live_rules_snap=$5 prev_sysctl_snap=$6
  local prev_rules_tmp prev_sysctl_tmp
  prev_rules_tmp=$(tmp_file) || return 1
  prev_sysctl_tmp=$(tmp_file) || return 1
  export_prev_rules_from_live_snapshot "$live_rules_snap" "$prev_rules_tmp" || return 1
  export_prev_sysctl_from_live_snapshot "$prev_sysctl_snap" "$prev_sysctl_tmp" || return 1

  atomic_install "$prev_rules_tmp" "$PREV_RULE_FILE" 600 || return 1
  atomic_install "$prev_sysctl_tmp" "$PREV_SYSCTL_FILE" 600 || return 1
  atomic_install "$rules" "$PREVIEW_RULE_FILE" 600 || return 1
  atomic_install "$rules" "$NFT_RULE_FILE" 600 || return 1
  atomic_install "$rules" "$LAST_RULE_FILE" 600 || return 1
  atomic_install "$sysctl_tmp" "$SYSCTL_FILE" 644 || return 1
  atomic_install "$sysctl_tmp" "$LAST_SYSCTL_FILE" 600 || return 1
  atomic_install "$loader_tmp" "$LOADER_FILE" 700 || return 1
  atomic_install "$service_tmp" "$SERVICE_FILE" 644 || return 1
  reload_systemd_manager || return 1
}

persist_rollback_files() {
  local rules_tmp=$1 sysctl_tmp=$2 loader_tmp=$3 service_tmp=$4 live_rules_snap=$5 prev_sysctl_snap=$6
  local prev_rules_tmp prev_sysctl_tmp
  prev_rules_tmp=$(tmp_file) || return 1
  prev_sysctl_tmp=$(tmp_file) || return 1
  export_prev_rules_from_live_snapshot "$live_rules_snap" "$prev_rules_tmp" || return 1
  export_prev_sysctl_from_live_snapshot "$prev_sysctl_snap" "$prev_sysctl_tmp" || return 1

  atomic_install "$rules_tmp" "$PREVIEW_RULE_FILE" 600 || return 1
  atomic_install "$rules_tmp" "$NFT_RULE_FILE" 600 || return 1
  atomic_install "$rules_tmp" "$LAST_RULE_FILE" 600 || return 1
  atomic_install "$prev_rules_tmp" "$PREV_RULE_FILE" 600 || return 1
  atomic_install "$sysctl_tmp" "$SYSCTL_FILE" 644 || return 1
  atomic_install "$sysctl_tmp" "$LAST_SYSCTL_FILE" 600 || return 1
  atomic_install "$prev_sysctl_tmp" "$PREV_SYSCTL_FILE" 600 || return 1
  atomic_install "$loader_tmp" "$LOADER_FILE" 700 || return 1
  atomic_install "$service_tmp" "$SERVICE_FILE" 644 || return 1
  reload_systemd_manager || return 1
}

reload_systemd_manager() {
  [[ -n $SYSTEMCTL_BIN ]] || return 0
  "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1
}

warn_iptables_nat_conflict() {
  [[ ${CFG[WARN_IPTABLES_NAT_CONFLICT]} == yes && -n $IPTABLES_BIN ]] || return 0
  "$IPTABLES_BIN" -t nat -S 2>/dev/null | grep -qE '^-A ' && warn '检测到 iptables nat 表仍有规则，可能与 nftables DNAT/MASQUERADE 冲突。' || true
}

write_logrotate_sample() {
  cat >"$1" <<'EOF'
/var/log/kern.log /var/log/messages {
  weekly
  rotate 8
  compress
  delaycompress
  missingok
  notifempty
  create 0640 root adm
}
EOF
}

warn_drop_log_capacity() {
  [[ ${CFG[ENABLE_DROP_LOG]} == yes ]] || return 0
  warn 'ENABLE_DROP_LOG=yes：请确认 journald / rsyslog / logrotate 的容量策略，避免高强度攻击下日志快速膨胀。'
  [[ -f $LOGROTATE_SAMPLE_FILE ]] && info "已提供日志轮转样例：$LOGROTATE_SAMPLE_FILE"
}

warn_ipv6_forward_risk() {
  local valid6=${1:-0}
  if [[ ${CFG[ENABLE_IPV6_FORWARD]} == yes && ${CFG[FORWARD_POLICY]} != drop ]]; then
    warn 'ENABLE_IPV6_FORWARD=yes 且 FORWARD_POLICY 不是 drop；请确认 IPv6 forward 规则覆盖充分。'
  elif [[ ${CFG[ENABLE_IPV6_FORWARD]} == yes && $valid6 == 0 ]]; then
    warn 'ENABLE_IPV6_FORWARD=yes 但当前无有效 IPv6 DNAT 规则；请确认 IPv6 forward 策略符合预期。'
  fi
}

# ===== 配置加载、初始化与布局维护 =====
reset_settings() {
  CFG=()
  local k
  for k in "${!CFG_DEFAULT[@]}"; do CFG[$k]=${CFG_DEFAULT[$k]}; done
}

load_settings() {
  local line key val norm raw
  reset_settings
  [[ -f $SETTINGS_FILE ]] || { validate_mark_field; return 0; }
  while IFS= read -r raw || [[ -n $raw ]]; do
    line=$(normalize_line "$raw")
    [[ -z $line ]] && continue
    validate_line_tokens_safe "$line" || die "settings.conf 包含控制字符或危险转义字符。"
    [[ $line == *=* ]] || { warn "忽略 settings.conf 非法行：$line"; continue; }
    key=${line%%=*}
    val=${line#*=}
    key=$(trim "$key")
    val=$(trim "$val")
    val=$(strip_quotes "$val")
    case $key in
      INPUT_POLICY|FORWARD_POLICY|OUTPUT_POLICY)
        validate_policy "$val" || die "settings.conf 中 $key 非法：$val"
        CFG[$key]=$val ;;
      ENABLE_DROP_LOG|AUTO_OPEN_SSH_PORT|ALLOW_PING_V4|ALLOW_PING_V6|ALLOW_IPV6_ND|ENABLE_IPV6_FORWARD|WARN_IPTABLES_NAT_CONFLICT|ENABLE_COUNTERS|ENABLE_FORWARD_SNAT)
        norm=$(normalize_bool "$val") || die "settings.conf 中 $key 非法：$val"
        CFG[$key]=$norm ;;
      SSH_PORT)
        validate_single_port "$val" || die "settings.conf 中 SSH_PORT 非法：$val（必须是 1-65535 的单个 TCP 端口）"
        CFG[SSH_PORT]=$(normalize_port_or_range "$val") ;;
      DROP_LOG_RATE|PING_V4_RATE|PING_V6_RATE)
        validate_rate "$val" || die "settings.conf 中 $key 非法：$val"
        CFG[$key]=$val ;;
      RATELIMIT_TIMEOUT)
        validate_timeout "$val" || die "settings.conf 中 $key 非法：$val"
        CFG[$key]=$val ;;
      WAN_IFACE)
        validate_iface "$val" || die "settings.conf 中 WAN_IFACE 非法：$val"
        CFG[WAN_IFACE]=$val ;;
      FORWARD_MARK_HEX|FORWARD_MARK_MASK)
        validate_hex_u32 "$val" || die "settings.conf 中 $key 非法：$val"
        CFG[$key]=${val,,} ;;
      '') ;;
      *) warn "忽略 settings.conf 未识别键：$key" ;;
    esac
  done <"$SETTINGS_FILE"
  if [[ ${CFG[AUTO_OPEN_SSH_PORT]} == yes ]]; then
    validate_single_port "${CFG[SSH_PORT]}" || die "settings.conf 中 SSH_PORT 非法：${CFG[SSH_PORT]}（必须是 1-65535 的单个 TCP 端口）"
  fi
  validate_mark_field
}

write_default_settings() {
  cat <<'EOF'
INPUT_POLICY=drop
FORWARD_POLICY=drop
OUTPUT_POLICY=accept

ENABLE_DROP_LOG=no
DROP_LOG_RATE=10/second
WAN_IFACE=
AUTO_OPEN_SSH_PORT=yes
SSH_PORT=22
ALLOW_PING_V4=yes
PING_V4_RATE=5/second
ALLOW_PING_V6=yes
PING_V6_RATE=5/second
ALLOW_IPV6_ND=yes
ENABLE_IPV6_FORWARD=no
WARN_IPTABLES_NAT_CONFLICT=yes
ENABLE_COUNTERS=yes
ENABLE_FORWARD_SNAT=yes
RATELIMIT_TIMEOUT=1m
FORWARD_MARK_HEX=0x20000000
FORWARD_MARK_MASK=0x20000000
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
# 说明：
# - input 按源地址拦截
# - output 按目标地址拦截
# - forward 同时按源地址和目标地址拦截
# - 脚本会把黑名单收敛到 nft set，而不是为每个 IP 生成独立 rule。

# ===== block_port.list =====
# 格式： proto port_or_range
# 例如：
# tcp 23
# both 135-139

# ===== ratelimit.list =====
# 格式： proto port_or_range rate [burst=N] [src=CIDR]
# 说明：按来源地址做 dynamic set + update；超过 rate 后丢弃。
# 例如：
# tcp 80 30/second burst=60
# tcp 22 5/minute src=198.51.100.0/24

# ===== connlimit.list =====
# 格式： proto port_or_range limit [mask=N] [src=CIDR] [action=drop|reject]
# 说明：限制新建连接数；使用 dynamic set + add，不使用 timeout。
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
# tcp 8443 2001:db8::10 443
# udp 51820 2001:db8::30 51820 src=2001:db8:100::/64
# 说明：
# - 只有“解析成功”的 forward 规则才会启用对应 family 的 forwarding sysctl
# - 本脚本会在 prerouting DNAT 时为该连接打专属 mark
# - forward 放行与 postrouting masquerade 仅匹配带该 mark 的连接，避免误放行/误 SNAT 其他管理器的 DNAT 流量
EOF
}

ensure_layout() {
  local f files=(
    "$ALLOW_FILE" "$ALLOW_RANGE_FILE" "$ALLOW_ACL_FILE" "$FORWARD_FILE"
    "$BLOCK_IP_FILE" "$BLOCK_PORT_FILE" "$RATELIMIT_FILE" "$CONNLIMIT_FILE" "$TRACE_FILE"
  )
  mkdir -p -- "$CONF_DIR" "$BACKUP_DIR" "$RUNTIME_DIR" || return 1
  for f in "${files[@]}"; do [[ -e $f ]] || : >"$f"; chmod 600 -- "$f" 2>/dev/null || true; done
  if [[ ! -f $SETTINGS_FILE ]]; then
    write_default_settings >"$SETTINGS_FILE" || return 1
  elif ! grep -Eq '^[[:space:]]*SSH_PORT[[:space:]]*=' "$SETTINGS_FILE" 2>/dev/null; then
    printf '
SSH_PORT=22
' >>"$SETTINGS_FILE" || return 1
  fi
  chmod 600 -- "$SETTINGS_FILE" 2>/dev/null || true
  if [[ ! -f $LOGROTATE_SAMPLE_FILE ]]; then write_logrotate_sample "$LOGROTATE_SAMPLE_FILE" || return 1; chmod 644 -- "$LOGROTATE_SAMPLE_FILE" 2>/dev/null || true; fi
}

preview_rules() {
  local rules_tmp sysctl_tmp valid6=0
  rules_tmp=$(tmp_file) || return 1
  sysctl_tmp=$(tmp_file) || return 1
  load_settings
  compile_rules_to_file "$rules_tmp" || return 1
  validate_rules_file "$rules_tmp" || die 'nft -c 校验失败，请检查上面的报错。'
  build_sysctl_file "$sysctl_tmp" || return 1
  valid6=$(count_valid_forward_entries_family ip6 2>/dev/null || echo 0)
  warn_drop_log_capacity
  warn_ipv6_forward_risk "$valid6"
  atomic_install "$rules_tmp" "$PREVIEW_RULE_FILE" 600 || return 1
  ok "预览规则已生成并通过 nft -c 校验：$PREVIEW_RULE_FILE"
  info '对应 sysctl 预览：'
  cat -- "$sysctl_tmp"
}

apply_rules() {
  local rules_tmp sysctl_tmp loader_tmp service_tmp snap live_rules_snap live_sysctl_snap
  rules_tmp=$(tmp_file) || return 1
  sysctl_tmp=$(tmp_file) || return 1
  loader_tmp=$(tmp_file) || return 1
  service_tmp=$(tmp_file) || return 1
  live_rules_snap=$(tmp_dir) || return 1
  live_sysctl_snap=$(tmp_file) || return 1
  snap=$(snapshot_paths) || return 1

  local valid6=0
  load_settings
  warn_iptables_nat_conflict
  compile_rules_to_file "$rules_tmp" || return 1
  validate_rules_file "$rules_tmp" || die 'nft -c 校验失败，请检查上面的报错。'
  build_sysctl_file "$sysctl_tmp" || return 1
  write_loader_file "$loader_tmp" || return 1
  write_service_file "$service_tmp" || return 1
  snapshot_live_managed_tables "$live_rules_snap" || return 1
  snapshot_live_sysctl_for_file "$sysctl_tmp" "$live_sysctl_snap" || return 1
  valid6=$(count_valid_forward_entries_family ip6 2>/dev/null || echo 0)
  warn_drop_log_capacity
  warn_ipv6_forward_risk "$valid6"

  apply_managed_tables "$rules_tmp" || die '应用 nft 规则失败。'
  if ! apply_sysctl_file "$sysctl_tmp"; then
    err '应用 sysctl 失败，正在尝试恢复 live 运行态。'
    restore_live_managed_tables "$live_rules_snap" || true
    restore_live_sysctl_snapshot "$live_sysctl_snap" || true
    return 1
  fi

  if ! persist_generated_files "$rules_tmp" "$sysctl_tmp" "$loader_tmp" "$service_tmp" "$live_rules_snap" "$live_sysctl_snap"; then
    err '持久化文件失败，正在回滚 live 运行态与文件态。'
    restore_live_managed_tables "$live_rules_snap" || true
    restore_live_sysctl_snapshot "$live_sysctl_snap" || true
    restore_snapshot "$snap" || true
    return 1
  fi

  ok '规则已应用并持久化成功。'
  info "sysctl 同步模式：$SYSCTL_LAST_SYNC_MODE"
}

rollback_rules() {
  local rules_src sysctl_src rules_tmp sysctl_tmp loader_tmp service_tmp snap live_rules_snap live_sysctl_snap
  snap=$(snapshot_paths) || return 1
  if [[ -f $PREV_RULE_FILE && -f $PREV_SYSCTL_FILE ]]; then
    rules_src=$PREV_RULE_FILE
    sysctl_src=$PREV_SYSCTL_FILE
  elif [[ -s $LAST_RULE_FILE && -f $LAST_SYSCTL_FILE ]]; then
    rules_src=$LAST_RULE_FILE
    sysctl_src=$LAST_SYSCTL_FILE
  else
    die '没有可回滚的历史规则。'
  fi
  [[ -f $sysctl_src ]] || die '历史 sysctl 快照缺失，拒绝回滚。'
  live_rules_snap=$(tmp_dir) || return 1
  live_sysctl_snap=$(tmp_file) || return 1

  validate_rules_file "$rules_src" || die '历史规则文件自身无效，拒绝回滚。'
  snapshot_live_managed_tables "$live_rules_snap" || return 1
  snapshot_live_sysctl_for_file "$sysctl_src" "$live_sysctl_snap" || return 1
  apply_managed_tables "$rules_src" || die '回滚 nft 规则失败。'
  apply_sysctl_file "$sysctl_src" || {
    err '回滚 sysctl 失败，正在恢复回滚前的 live 运行态。'
    restore_live_managed_tables "$live_rules_snap" || true
    restore_live_sysctl_snapshot "$live_sysctl_snap" || true
    restore_snapshot "$snap" || true
    die '回滚 sysctl 失败。'
  }

  rules_tmp=$(tmp_file) || return 1
  sysctl_tmp=$(tmp_file) || return 1
  loader_tmp=$(tmp_file) || return 1
  service_tmp=$(tmp_file) || return 1
  cat -- "$rules_src" >"$rules_tmp" || return 1
  cat -- "$sysctl_src" >"$sysctl_tmp" || return 1
  write_loader_file "$loader_tmp" || return 1
  write_service_file "$service_tmp" || return 1

  if ! persist_rollback_files "$rules_tmp" "$sysctl_tmp" "$loader_tmp" "$service_tmp" "$live_rules_snap" "$live_sysctl_snap"; then
    err '回滚后同步持久化文件失败，正在恢复回滚前的 live 运行态与文件态。'
    restore_live_managed_tables "$live_rules_snap" || true
    restore_live_sysctl_snapshot "$live_sysctl_snap" || true
    restore_snapshot "$snap" || true
    return 1
  fi
  ok '已完成回滚，并同步 nft 运行态 + sysctl + LAST/PREV 历史文件。'
  info '注意：rollback 不会回滚 .list 与 settings.conf；下次 preview/apply 会按当前配置重新生成规则。'
}

ensure_service_assets_present() {
  [[ -f $NFT_RULE_FILE && -f $LAST_RULE_FILE && -f $SYSCTL_FILE && -f $LAST_SYSCTL_FILE ]] || {
    err '错误：请先成功执行 apply/rollback，确认 ruleset 与 sysctl 资产已生成后再启用服务。'
    return 1
  }

  validate_rules_file "$NFT_RULE_FILE" || {
    err "错误：当前规则文件无效：$NFT_RULE_FILE"
    return 1
  }
  validate_rules_file "$LAST_RULE_FILE" || {
    err "错误：历史规则文件无效：$LAST_RULE_FILE"
    return 1
  }

  validate_sysctl_persist_file "$SYSCTL_FILE" || {
    err "错误：当前 sysctl 文件无效：$SYSCTL_FILE"
    return 1
  }
  validate_sysctl_persist_file "$LAST_SYSCTL_FILE" || {
    err "错误：历史 sysctl 文件无效：$LAST_SYSCTL_FILE"
    return 1
  }

  cmp -s -- "$NFT_RULE_FILE" "$LAST_RULE_FILE" || {
    err '错误：当前 ruleset 与 LAST ruleset 不一致，拒绝启用服务。'
    return 1
  }
  cmp -s -- "$SYSCTL_FILE" "$LAST_SYSCTL_FILE" || {
    err '错误：当前 sysctl 与 LAST sysctl 不一致，拒绝启用服务。'
    return 1
  }
}

install_service() {
  local loader_tmp service_tmp
  ensure_service_assets_present || return 1
  loader_tmp=$(tmp_file) || return 1
  service_tmp=$(tmp_file) || return 1
  write_loader_file "$loader_tmp" || return 1
  write_service_file "$service_tmp" || return 1
  atomic_install "$loader_tmp" "$LOADER_FILE" 700 || return 1
  atomic_install "$service_tmp" "$SERVICE_FILE" 644 || return 1
  if [[ -n $SYSTEMCTL_BIN ]]; then
    reload_systemd_manager || return 1
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
    "$SYSTEMCTL_BIN" stop nft-manager.service >/dev/null 2>&1 || true
    "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f -- "$SERVICE_WANTS_LINK" 2>/dev/null || true
  ok '已禁用并停止 nft-manager.service（当前运行态 ruleset 未清空）'
}

status_report() {
  local enabled_state='unknown' active_state='unknown'
  local forward_count=0 v4_count=0 v6_count=0 counts_ok=yes
  local fw_state nat4_state nat6_state fw_err='' nat4_err='' nat6_err=''

  load_settings
  enabled_state=$(service_is_enabled && echo yes || echo no)
  active_state=$(service_active_state) || true

  printf '配置目录: %s\n规则文件: %s\n预览文件: %s\nWAN_IFACE: %s\n策略: input=%s forward=%s output=%s\n计数器: %s\nSSH 自动放行: %s\nSSH 端口: %s\nIPv6 forwarding: %s\nPING 速率: v4=%s v6=%s\nratelimit timeout: %s\n转发 SNAT: %s\n转发 mark: hex=%s mask=%s\nservice 启用: %s\nservice 当前状态: %s\n黑名单结构: nft set\n日志轮转样例: %s\n回滚范围: 已应用 ruleset / sysctl / loader / service（不含 .list 与 settings.conf）\n' \
    "$CONF_DIR" "$NFT_RULE_FILE" "$PREVIEW_RULE_FILE" "${CFG[WAN_IFACE]:-<未设置>}" \
    "${CFG[INPUT_POLICY]}" "${CFG[FORWARD_POLICY]}" "${CFG[OUTPUT_POLICY]}" \
    "${CFG[ENABLE_COUNTERS]}" "${CFG[AUTO_OPEN_SSH_PORT]}" "${CFG[SSH_PORT]}" "${CFG[ENABLE_IPV6_FORWARD]}" "${CFG[PING_V4_RATE]}" "${CFG[PING_V6_RATE]}" \
    "${CFG[RATELIMIT_TIMEOUT]}" "${CFG[ENABLE_FORWARD_SNAT]}" "${CFG[FORWARD_MARK_HEX]}" "${CFG[FORWARD_MARK_MASK]}" \
    "$enabled_state" "$active_state" "$LOGROTATE_SAMPLE_FILE"

  [[ -f $SYSCTL_FILE ]] && { printf '\n当前持久化 sysctl:\n'; cat -- "$SYSCTL_FILE"; }

  if v4_count=$(count_valid_forward_entries_family ip 2>/dev/null) && \
     v6_count=$(count_valid_forward_entries_family ip6 2>/dev/null) && \
     forward_count=$(count_valid_forward_entries 2>/dev/null); then
    printf '\n有效 DNAT 条数: %s（IPv4=%s IPv6=%s）\n\n' "$forward_count" "$v4_count" "$v6_count"
  else
    counts_ok=no
    v4_count='格式错误'
    v6_count='格式错误'
    printf '\n有效 DNAT 条数: %s（IPv4=%s IPv6=%s）\n\n' 'forward.list 格式错误' "$v4_count" "$v6_count"
  fi


  probe_table_state inet "$TABLE_FW" fw_state fw_err
  case $fw_state in
    present) ok "运行态存在表：inet $TABLE_FW" ;;
    absent) warn "运行态不存在表：inet $TABLE_FW" ;;
    unreadable)
      warn "无法读取运行态表：inet $TABLE_FW（权限不足或环境受限）"
      [[ -n $fw_err ]] && warn "  nft stderr: $(status_err_summary "$fw_err")"
      ;;
    *)
      warn "无法确认运行态表状态：inet $TABLE_FW"
      [[ -n $fw_err ]] && warn "  nft stderr: $(status_err_summary "$fw_err")"
      ;;
  esac

  probe_table_state ip "$TABLE_NAT" nat4_state nat4_err
  case $nat4_state in
    present)
      ok "运行态存在表：ip $TABLE_NAT"
      ;;
    absent)
      [[ $counts_ok == yes && $v4_count == 0 ]] && info "运行态不存在表：ip $TABLE_NAT（当前无有效 IPv4 DNAT 规则，属正常状态）" || warn "运行态不存在表：ip $TABLE_NAT"
      ;;
    unreadable)
      warn "无法读取运行态表：ip $TABLE_NAT（权限不足或环境受限）"
      [[ -n $nat4_err ]] && warn "  nft stderr: $(status_err_summary "$nat4_err")"
      ;;
    *)
      warn "无法确认运行态表状态：ip $TABLE_NAT"
      [[ -n $nat4_err ]] && warn "  nft stderr: $(status_err_summary "$nat4_err")"
      ;;
  esac

  probe_table_state ip6 "$TABLE_NAT" nat6_state nat6_err
  case $nat6_state in
    present)
      ok "运行态存在表：ip6 $TABLE_NAT"
      ;;
    absent)
      [[ $counts_ok == yes && $v6_count == 0 ]] && info "运行态不存在表：ip6 $TABLE_NAT（当前无有效 IPv6 DNAT 规则，属正常状态）" || warn "运行态不存在表：ip6 $TABLE_NAT"
      ;;
    unreadable)
      warn "无法读取运行态表：ip6 $TABLE_NAT（权限不足或环境受限）"
      [[ -n $nat6_err ]] && warn "  nft stderr: $(status_err_summary "$nat6_err")"
      ;;
    *)
      warn "无法确认运行态表状态：ip6 $TABLE_NAT"
      [[ -n $nat6_err ]] && warn "  nft stderr: $(status_err_summary "$nat6_err")"
      ;;
  esac
}

status_err_summary() {
  local s=${1:-} max=${2:-256}
  s=$(printf '%s' "$s" | tr '\n\t' '   ')
  s=$(printf '%s' "$s" | awk '{$1=$1; print}')
  ((${#s} <= max)) && { printf '%s' "$s"; return 0; }
  printf '%s...' "${s:0:max}"
}

# ===== 列表条目规范化与增删辅助 =====
canonicalize_entry_for_file() {
  local file=$1 raw=$2 norm base
  norm=$(normalize_line "$raw")
  [[ -n $norm ]] || return 1
  base=${file##*/}
  case $base in
    allow.list|allow_range.list)
      parse_allow_port_line "$norm" || { printf '%s' "$norm"; return 0; }
      printf '%s %s' "$P_PROTO" "$P_PORT"
      ;;
    allow_acl.list)
      parse_acl_line "$norm" || { printf '%s' "$norm"; return 0; }
      printf '%s %s %s' "$P_PROTO" "$P_PORT" "$P_SRC"
      ;;
    forward.list)
      parse_forward_line "$norm" || { printf '%s' "$norm"; return 0; }
      printf '%s %s %s' "$F_PROTO" "$F_EXT_PORT" "$F_TARGET_IP"
      [[ $F_TARGET_PORT != "$F_EXT_PORT" ]] && printf ' %s' "$F_TARGET_PORT"
      [[ -n $F_SRC ]] && printf ' src=%s' "$F_SRC"
      ;;
    *)
      printf '%s' "$norm"
      ;;
  esac
  return 0
}

normalize_cli_src() {
  local s=${1:-}
  [[ $s == src=* ]] && s=${s#src=}
  printf '%s' "$s"
}

build_open_rule_entry() {
  local proto=$1 port=$2 src
  src=$(normalize_cli_src "${3:-}")
  if [[ -n $src ]]; then
    parse_acl_line "$proto $port $src" || return 1
    ENTRY_FILE=$ALLOW_ACL_FILE
    ENTRY_LINE="$P_PROTO $P_PORT $P_SRC"
  else
    parse_allow_port_line "$proto $port" || return 1
    ENTRY_FILE=$([[ $P_PORT == *-* ]] && printf '%s' "$ALLOW_RANGE_FILE" || printf '%s' "$ALLOW_FILE")
    ENTRY_LINE="$P_PROTO $P_PORT"
  fi
}

parse_forward_cli_args() {
  local arg4=${1:-} arg5=${2:-}
  F_TARGET_PORT_ARG='' F_SRC_ARG=''
  if [[ -n $arg4 ]]; then
    if [[ $arg4 == src=* ]]; then
      F_SRC_ARG=$arg4
    else
      F_TARGET_PORT_ARG=$arg4
    fi
  fi
  [[ -n $arg5 ]] && F_SRC_ARG=$arg5
  return 0
}

build_forward_rule_entry() {
  local proto=$1 ext_port=$2 target_ip=$3 target_port=${4:-} src line
  src=$(normalize_cli_src "${5:-}")
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
  local file=$1 line=$2 raw norm target
  [[ -f $file ]] || : >"$file"
  target=$(canonicalize_entry_for_file "$file" "$line") || target=$(normalize_line "$line")
  while IFS= read -r raw || [[ -n $raw ]]; do
    norm=$(canonicalize_entry_for_file "$file" "$raw") || norm=''
    [[ -n $norm && $norm == "$target" ]] && { ok "规则已存在：$target"; return 0; }
  done <"$file"
  printf '%s\n' "$line" >>"$file" || return 1
  chmod 600 -- "$file" 2>/dev/null || true
  ok "已写入 ${file##*/}: $line"
}

remove_normalized_line_from_file() {
  local file=$1 target=$2 tmp raw norm want removed=0
  tmp=$(tmp_file) || return 1
  want=$(canonicalize_entry_for_file "$file" "$target") || want=$(normalize_line "$target")
  while IFS= read -r raw || [[ -n $raw ]]; do
    norm=$(canonicalize_entry_for_file "$file" "$raw") || norm=''
    [[ -n $norm && $norm == "$want" ]] && { ((++removed)); continue; }
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
    removed_total=$((removed_total + REMOVED_COUNT))
  done
  (( removed_total > 0 )) && { ok "已删除规则：$target"; return 0; }
  warn "未找到规则：$target"
  return 1
}

open_cmd() {
  local op=$1 proto=${2:-} port=${3:-} src=${4:-}
  (( $# >= 3 && $# <= 4 )) || { err "用法：open-$op <tcp|udp|both> <port|start-end> [CIDR|src=CIDR]"; return 1; }
  build_open_rule_entry "$proto" "$port" "$src" || { err '开放端口参数非法。'; return 1; }
  if [[ $op == add ]]; then
    append_unique_line "$ENTRY_FILE" "$ENTRY_LINE"
  elif [[ -n $(normalize_cli_src "$src") ]]; then
    delete_line_from_files "$ENTRY_LINE" "$ALLOW_ACL_FILE"
  else
    delete_line_from_files "$ENTRY_LINE" "$ALLOW_FILE" "$ALLOW_RANGE_FILE"
  fi
}

forward_cmd() {
  local op=$1 proto=${2:-} ext_port=${3:-} target_ip=${4:-}
  (( $# >= 4 && $# <= 6 )) || { err "用法：forward-$op <tcp|udp|both> <ext_port|range> <target_ip> [target_port|range] [src=CIDR]"; return 1; }
  parse_forward_cli_args "${5:-}" "${6:-}"
  build_forward_rule_entry "$proto" "$ext_port" "$target_ip" "$F_TARGET_PORT_ARG" "$F_SRC_ARG" || { err '端口转发参数非法。'; return 1; }
  if [[ $op == add ]]; then
    append_unique_line "$ENTRY_FILE" "$ENTRY_LINE"
  else
    delete_line_from_files "$ENTRY_LINE" "$FORWARD_FILE"
  fi
}

open_add_cmd() { open_cmd add "$@"; }
open_del_cmd() { open_cmd del "$@"; }
forward_add_cmd() { forward_cmd add "$@"; }
forward_del_cmd() { forward_cmd del "$@"; }

print_forward_row() { printf '%-8s %-14s %-16s %-14s %-18s\n' "$F_PROTO" "$F_EXT_PORT" "$F_TARGET_IP" "$F_TARGET_PORT" "${F_SRC:-不限}"; }

list_parsed_rows() {
  local file=$1 parser=$2 label=$3 printer=$4 arg=${5:-} n line found=0
  while IFS=$'\t' read -r n line; do
    "$parser" "$line" || die "$label 第 $n 行格式错误：$line"
    "$printer" "$arg"
    found=1
  done < <(read_lines_with_lineno "$file")
  (( found ))
}

print_open_row() {
  local label=$1 src='不限'
  [[ $label == allow_acl.list ]] && src=$P_SRC
  printf '%-8s %-18s %-22s %-16s\n' "$P_PROTO" "$P_PORT" "$src" "$label"
}

open_list_cmd() {
  local found=0
  printf '%-8s %-18s %-22s %-16s\n' '协议' '端口/范围' '来源限制' '来源文件'
  printf '%-8s %-18s %-22s %-16s\n' '--------' '------------------' '----------------------' '----------------'
  list_parsed_rows "$ALLOW_FILE" parse_allow_port_line 'allow.list' print_open_row 'allow.list' && found=1 || true
  list_parsed_rows "$ALLOW_RANGE_FILE" parse_allow_port_line 'allow_range.list' print_open_row 'allow_range.list' && found=1 || true
  list_parsed_rows "$ALLOW_ACL_FILE" parse_acl_line 'allow_acl.list' print_open_row 'allow_acl.list' && found=1 || true
  (( found )) || printf '（当前没有开放端口规则）\n'
}

forward_list_cmd() {
  printf '%-8s %-14s %-16s %-14s %-18s\n' '协议' '外部端口' '目标IP' '目标端口' '来源限制'
  printf '%-8s %-14s %-16s %-14s %-18s\n' '--------' '--------------' '----------------' '--------------' '------------------'
  list_parsed_rows "$FORWARD_FILE" parse_forward_line 'forward.list' print_forward_row && return 0
  printf '（当前没有端口转发规则）\n'
}

# ===== 只读展示、交互菜单与命令分发 =====
prompt_ask() { local prompt=$1 __var=$2 value=''; read -r -p "$prompt" value || return 1; printf -v "$__var" '%s' "$value"; }

prompt_open_cmd() {
  local op=$1 proto port src cmd
  prompt_ask '协议 (tcp/udp/both): ' proto || return 1
  prompt_ask "$([[ $op == add ]] && echo '开放端口或范围: ' || echo '删除的开放端口或范围: ')" port || return 1
  prompt_ask "$([[ $op == add ]] && echo '来源限制（留空表示不限，可填 CIDR）: ' || echo '来源限制（若有；留空表示不限）: ')" src || return 1
  cmd=$([[ $op == add ]] && printf '%s' 'open-add' || printf '%s' 'open-del')
  menu_run_command "$cmd" "$proto" "$port" "${src:-}"
}

prompt_forward_cmd() {
  local op=$1 proto ext_port target_ip target_port src cmd
  prompt_ask '协议 (tcp/udp/both): ' proto || return 1
  prompt_ask '外部端口或范围: ' ext_port || return 1
  prompt_ask '目标 IP（IPv4/IPv6）: ' target_ip || return 1
  prompt_ask '目标端口或范围（留空表示同外部端口）: ' target_port || return 1
  prompt_ask "$([[ $op == add ]] && echo '来源限制（留空表示不限，可填 CIDR）: ' || echo '来源限制（若有；留空表示不限）: ')" src || return 1
  cmd=$([[ $op == add ]] && printf '%s' 'forward-add' || printf '%s' 'forward-del')
  menu_run_command "$cmd" "$proto" "$ext_port" "$target_ip" "${target_port:-}" "${src:+src=$src}"
}

menu_run_command() {
  local rc=0 old_err_trap=""
  old_err_trap=$(trap -p ERR || true)
  trap - ERR
  set +eE
  if run_command_with_context "$@"; then
    rc=0
  else
    rc=$?
  fi
  set -Ee
  [[ -n $old_err_trap ]] && eval "$old_err_trap"
  (( rc == 0 )) || warn "上一操作失败（rc=$rc）。"
  return 0
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
8) 禁用并停止 systemd 服务（不清空当前运行态 ruleset）
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
      1) menu_run_command init ;;
      2) menu_run_command preview ;;
      3) menu_run_command apply ;;
      4) menu_run_command rollback ;;
      5) menu_run_command status ;;
      6) menu_run_command sample ;;
      7) menu_run_command enable-service ;;
      8) menu_run_command disable-service ;;
      9) prompt_open_cmd add ;;
      10) prompt_open_cmd del ;;
      11) menu_run_command open-list ;;
      12) prompt_forward_cmd add ;;
      13) prompt_forward_cmd del ;;
      14) menu_run_command forward-list ;;
      15) return 0 ;;
      *) warn '无效选择。' ;;
    esac
  done
}

usage() {
  local me=${0##*/}
  cat <<EOF
用法：
  $me init
  $me preview
  $me apply
  $me rollback
  $me status
  $me sample
  $me enable-service
  $me disable-service
  $me open-add <tcp|udp|both> <port|start-end> [CIDR|src=CIDR]
  $me open-del <tcp|udp|both> <port|start-end> [CIDR|src=CIDR]
  $me open-list
  $me forward-add <tcp|udp|both> <ext_port|range> <target_ip> [target_port|range] [src=CIDR]
  $me forward-del <tcp|udp|both> <ext_port|range> <target_ip> [target_port|range] [src=CIDR]
  $me forward-list
  $me menu
EOF
}

is_known_command() {
  case $1 in
    init|preview|apply|rollback|status|sample|enable-service|disable-service|open-add|open-del|open-list|forward-add|forward-del|forward-list|menu) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_requires_root() {
  case $1 in
    init|preview|apply|rollback|status|enable-service|disable-service|open-add|open-del|forward-add|forward-del) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_requires_lock() {
  case $1 in
    init|preview|apply|rollback|enable-service|disable-service|open-add|open-del|forward-add|forward-del) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_requires_layout() {
  case $1 in
    init|preview|apply|rollback|enable-service|disable-service|open-add|open-del|forward-add|forward-del) return 0 ;;
    *) return 1 ;;
  esac
}

need_tools_for_command() {
  need_cmds_for "$1"
}

dispatch_command() {
  local cmd=${1:-}
  shift || true
  case $cmd in
    init) ensure_layout && ok "初始化完成：$CONF_DIR" ;;
    preview) preview_rules ;;
    apply) apply_rules ;;
    rollback) rollback_rules ;;
    status) status_report ;;
    sample) write_sample_lists ;;
    enable-service) install_service ;;
    disable-service) disable_service ;;
    open-add) open_add_cmd "$@" ;;
    open-del) open_del_cmd "$@" ;;
    open-list) open_list_cmd ;;
    forward-add) forward_add_cmd "$@" ;;
    forward-del) forward_del_cmd "$@" ;;
    forward-list) forward_list_cmd ;;
    menu) menu ;;
    *) usage; return 1 ;;
  esac
}

run_command_with_context() {
  local cmd=$1
  cmd_requires_root "$cmd" && need_root
  need_tools_for_command "$cmd"
  if cmd_requires_lock "$cmd"; then
    acquire_lock || die '错误：已有另一个 nft_manager 实例在运行。'
  fi
  if cmd_requires_layout "$cmd"; then
    ensure_layout || return 1
  fi
  dispatch_command "$@"
}

# ===== 程序入口 =====
main() {
  local cmd=${1:-menu}
  case $cmd in
    -h|--help|help) usage; return 0 ;;
    init|preview|apply|rollback|status|sample|enable-service|disable-service|open-add|open-del|open-list|forward-add|forward-del|forward-list|menu) ;;
    *) usage; return 1 ;;
  esac

  need_bash
  if (( $# == 0 )); then
    run_command_with_context "$cmd"
  else
    run_command_with_context "$@"
  fi
}

main "$@"
