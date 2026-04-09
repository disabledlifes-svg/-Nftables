#!/usr/bin/env bash
set -Eeuo pipefail

# run-nft-manager-v2.sh
# 适用于 Rust 重构版 nft-manager-rs 的安装/编译/初始化/预览/应用包装脚本
#
# 主要改进：
#  - 自动探测项目根目录（Cargo.toml 所在目录）
#  - 支持从 tar.gz 解包
#  - 自动加载 ~/.cargo/env
#  - 错误提示更明确
#
# 用法示例：
#   sudo ./run-nft-manager-v2.sh unpack /root/nft-manager-rs-hardened.tar.gz /root
#   sudo ./run-nft-manager-v2.sh install /root/nft-manager-rs
#   sudo ./run-nft-manager-v2.sh init /root/nft-manager-rs
#   sudo ./run-nft-manager-v2.sh sample /root/nft-manager-rs
#   sudo ./run-nft-manager-v2.sh preview /root/nft-manager-rs
#   sudo ./run-nft-manager-v2.sh apply /root/nft-manager-rs
#   sudo ./run-nft-manager-v2.sh enable-service /root/nft-manager-rs
#
# 也支持不传项目目录，自动查找：
#   sudo ./run-nft-manager-v2.sh install
#   sudo ./run-nft-manager-v2.sh preview

TS() { date '+%F %T'; }
log() { echo "[$(TS)] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

ACTION="${1:-}"
ARG1="${2:-}"
ARG2="${3:-}"

if [[ -z "$ACTION" ]]; then
  cat >&2 <<'EOF'
用法：
  run-nft-manager-v2.sh <action> [project_dir|tarball] [dest_dir]

动作：
  unpack          从 tar.gz 解包项目
  locate          探测 Rust 项目根目录
  install         安装依赖并编译
  build           仅编译
  init            初始化配置目录
  sample          生成样例配置
  preview         预览并进行 nft 语法检查
  apply           应用规则
  status          查看状态
  rollback        回滚
  enable-service  启用 systemd service
  disable-service 禁用 systemd service
  full-setup      install + init + sample + preview

示例：
  sudo ./run-nft-manager-v2.sh unpack /root/nft-manager-rs-hardened.tar.gz /root
  sudo ./run-nft-manager-v2.sh install /root/nft-manager-rs
EOF
  exit 2
fi

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 执行"
}

load_cargo_env() {
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1090
    . "$HOME/.cargo/env"
  fi
}

find_project_root() {
  local hint="${1:-}"
  local d c

  if [[ -n "$hint" ]]; then
    if [[ -f "$hint/Cargo.toml" ]]; then
      printf '%s\n' "$hint"
      return 0
    fi
    if [[ -d "$hint" ]]; then
      c="$(find "$hint" -maxdepth 3 -type f -name Cargo.toml 2>/dev/null | head -n1 || true)"
      if [[ -n "$c" ]]; then
        dirname "$c"
        return 0
      fi
    fi
    if [[ -f "$hint" && "$hint" == *.tar.gz ]]; then
      return 1
    fi
  fi

  for d in \
    "$PWD" \
    "$PWD/nft-manager-rs" \
    "$PWD/nft-manager-rs-hardened" \
    "/root/nft-manager-rs" \
    "/root/nft-manager-rs-hardened" \
    "/root"
  do
    if [[ -f "$d/Cargo.toml" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done

  c="$(find /root "$PWD" -maxdepth 3 -type f -name Cargo.toml 2>/dev/null | grep -E '/(nft-manager-rs|nft-manager)/' | head -n1 || true)"
  if [[ -n "$c" ]]; then
    dirname "$c"
    return 0
  fi

  return 1
}

resolve_project_root() {
  local root
  root="$(find_project_root "${1:-}" || true)"
  [[ -n "$root" ]] || die "找不到 Cargo.toml。请确认项目已解压，并传入正确项目目录。可先执行：./run-nft-manager-v2.sh locate"
  [[ -f "$root/Cargo.toml" ]] || die "目录不正确，未找到 Cargo.toml：$root"
  printf '%s\n' "$root"
}

project_bin() {
  local root="$1"
  printf '%s\n' "$root/target/release/nft-manager-rs"
}

require_bin() {
  local bin="$1"
  [[ -x "$bin" ]] || die "未找到可执行文件：$bin，请先执行 install 或 build"
}

install_deps() {
  log "安装依赖..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y nftables curl ca-certificates build-essential pkg-config tar
  if ! command -v cargo >/dev/null 2>&1; then
    log "安装 Rust toolchain..."
    curl https://sh.rustup.rs -sSf | sh -s -- -y
  fi
  load_cargo_env
  command -v cargo >/dev/null 2>&1 || die "cargo 不在 PATH 中，请执行：source ~/.cargo/env"
  command -v rustc >/dev/null 2>&1 || die "rustc 不在 PATH 中，请执行：source ~/.cargo/env"
  log "依赖安装完成"
}

do_unpack() {
  local tarball="${1:-}"
  local dest="${2:-/root}"
  [[ -n "$tarball" ]] || die "unpack 需要 tar.gz 文件路径"
  [[ -f "$tarball" ]] || die "tar.gz 文件不存在：$tarball"
  mkdir -p "$dest"
  log "解包 $tarball 到 $dest ..."
  tar -xzf "$tarball" -C "$dest"
  log "解包完成，正在尝试定位项目目录..."
  local root
  root="$(find_project_root "$dest" || true)"
  if [[ -n "$root" ]]; then
    log "已定位项目目录：$root"
  else
    err "已解包，但暂未自动定位到 Cargo.toml。请手工检查：find $dest -maxdepth 3 -name Cargo.toml"
  fi
}

do_locate() {
  local root
  root="$(find_project_root "${1:-}" || true)"
  if [[ -n "$root" ]]; then
    log "项目目录：$root"
  else
    die "未找到 Cargo.toml。请先上传并解压 Rust 项目源码。"
  fi
}

do_build() {
  local root="$1"
  load_cargo_env
  command -v cargo >/dev/null 2>&1 || die "cargo 不在 PATH 中，请先执行 install 或 source ~/.cargo/env"
  log "开始编译：$root"
  ( cd "$root" && cargo fmt && cargo check && cargo build --release )
  local bin
  bin="$(project_bin "$root")"
  [[ -x "$bin" ]] || die "编译后仍未找到二进制：$bin"
  log "编译完成：$bin"
}

do_install() {
  install_deps
  local root="$1"
  do_build "$root"
}

run_subcmd() {
  local root="$1"
  local sub="$2"
  local bin
  bin="$(project_bin "$root")"
  require_bin "$bin"
  "$bin" "$sub"
}

do_preview() {
  local root="$1"
  local bin
  bin="$(project_bin "$root")"
  require_bin "$bin"
  "$bin" preview
  [[ -f /etc/nft_manager/rules.preview.nft ]] || die "未生成 /etc/nft_manager/rules.preview.nft"
  nft -c -f /etc/nft_manager/rules.preview.nft
  log "preview 和 nft 语法检查通过"
}

do_apply() {
  local root="$1"
  local bin
  bin="$(project_bin "$root")"
  require_bin "$bin"
  log "提醒：远程服务器第一次 apply 前，请先确认 SSH 端口已放行"
  "$bin" apply
}

do_enable_service() {
  local root="$1"
  run_subcmd "$root" enable-service
  systemctl daemon-reload
  systemctl enable --now nft-manager.service
  systemctl status nft-manager.service --no-pager || true
}

main() {
  require_root

  case "$ACTION" in
    unpack)
      do_unpack "$ARG1" "${ARG2:-/root}"
      ;;
    locate)
      do_locate "$ARG1"
      ;;
    install)
      ROOT="$(resolve_project_root "$ARG1")"
      do_install "$ROOT"
      ;;
    build)
      ROOT="$(resolve_project_root "$ARG1")"
      do_build "$ROOT"
      ;;
    init)
      ROOT="$(resolve_project_root "$ARG1")"
      run_subcmd "$ROOT" init
      ;;
    sample)
      ROOT="$(resolve_project_root "$ARG1")"
      run_subcmd "$ROOT" sample
      ;;
    preview)
      ROOT="$(resolve_project_root "$ARG1")"
      do_preview "$ROOT"
      ;;
    apply)
      ROOT="$(resolve_project_root "$ARG1")"
      do_apply "$ROOT"
      ;;
    status)
      ROOT="$(resolve_project_root "$ARG1")"
      run_subcmd "$ROOT" status
      ;;
    rollback)
      ROOT="$(resolve_project_root "$ARG1")"
      run_subcmd "$ROOT" rollback
      ;;
    enable-service)
      ROOT="$(resolve_project_root "$ARG1")"
      do_enable_service "$ROOT"
      ;;
    disable-service)
      ROOT="$(resolve_project_root "$ARG1")"
      run_subcmd "$ROOT" disable-service
      systemctl daemon-reload || true
      ;;
    full-setup)
      ROOT="$(resolve_project_root "$ARG1")"
      do_install "$ROOT"
      run_subcmd "$ROOT" init
      run_subcmd "$ROOT" sample || true
      do_preview "$ROOT"
      ;;
    *)
      die "未知动作：$ACTION"
      ;;
  esac
}

main "$@"
