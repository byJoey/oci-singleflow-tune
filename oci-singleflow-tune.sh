#!/usr/bin/env bash
set -Eeuo pipefail

# OCI / Ubuntu single-flow tuning helper.
# Defaults come from an OCI Singapore ARM test where MTU 1500 + BBR + fq
# with the original large fq quantum reduced retransmits for single TCP flows.
#
# Usage:
#   sudo bash oci-singleflow-tune.sh
#
# Optional overrides:
#   IFACE=enp0s6 MTU=1500 FQ_QUANTUM=18028 FQ_INITIAL_QUANTUM=90140 sudo -E bash oci-singleflow-tune.sh
#   NETPLAN_FILE=/etc/netplan/50-cloud-init.yaml sudo -E bash oci-singleflow-tune.sh

MTU="${MTU:-1500}"
FQ_QUANTUM="${FQ_QUANTUM:-18028}"
FQ_INITIAL_QUANTUM="${FQ_INITIAL_QUANTUM:-90140}"
TCP_WMEM_MAX="${TCP_WMEM_MAX:-33554432}"
TCP_RMEM_MAX="${TCP_RMEM_MAX:-33554432}"
TCP_LIMIT_OUTPUT_BYTES="${TCP_LIMIT_OUTPUT_BYTES:-4194304}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-singleflow-tcp-optimization.conf}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/singleflow-fq-quantum.service}"
NETPLAN_FILE="${NETPLAN_FILE:-}"
IFACE="${IFACE:-}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root, for example: sudo bash $0" >&2
    exit 1
  fi
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

detect_iface() {
  if [[ -n "${IFACE}" ]]; then
    echo "${IFACE}"
    return
  fi

  local detected
  detected="$(ip route show default 2>/dev/null | awk 'NR==1 {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  if [[ -z "${detected}" ]]; then
    echo "Could not detect default network interface. Set IFACE=enp0s6 and rerun." >&2
    exit 1
  fi
  echo "${detected}"
}

detect_netplan_file() {
  if [[ -n "${NETPLAN_FILE}" ]]; then
    echo "${NETPLAN_FILE}"
    return
  fi

  local file
  file="$(find /etc/netplan -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort | head -n 1)"
  if [[ -z "${file}" ]]; then
    echo ""
    return
  fi
  echo "${file}"
}

backup_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    cp -a "${file}" "${file}.bak.singleflow.$(date +%Y%m%d%H%M%S)"
  fi
}

set_netplan_mtu() {
  local iface="$1"
  local file="$2"

  if [[ -z "${file}" || ! -f "${file}" ]]; then
    echo "No netplan file found. Applying runtime MTU only; set NETPLAN_FILE to persist netplan MTU." >&2
    ip link set dev "${iface}" mtu "${MTU}"
    return
  fi

  backup_file "${file}"

  python3 - "$file" "$iface" "$MTU" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
iface = sys.argv[2]
mtu = sys.argv[3]
text = path.read_text()
lines = text.splitlines()

iface_line = None
iface_indent = None
for i, line in enumerate(lines):
    m = re.match(r"^(\s*)" + re.escape(iface) + r":\s*$", line)
    if m:
        iface_line = i
        iface_indent = len(m.group(1))
        break

if iface_line is None:
    raise SystemExit(f"Interface {iface!r} was not found in {path}")

end = len(lines)
for i in range(iface_line + 1, len(lines)):
    stripped = lines[i].strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(lines[i]) - len(lines[i].lstrip(" "))
    if indent <= iface_indent:
        end = i
        break

mtu_idx = None
for i in range(iface_line + 1, end):
    if re.match(r"^\s*mtu:\s*", lines[i]):
        mtu_idx = i
        break

child_indent = None
for i in range(iface_line + 1, end):
    stripped = lines[i].strip()
    if stripped and not stripped.startswith("#"):
        indent = len(lines[i]) - len(lines[i].lstrip(" "))
        if indent > iface_indent:
            child_indent = indent
            break

if child_indent is None:
    child_indent = iface_indent + 2

new_line = " " * child_indent + f"mtu: {mtu}"
if mtu_idx is not None:
    lines[mtu_idx] = new_line
else:
    lines.insert(end, new_line)

path.write_text("\n".join(lines) + "\n")
PY

  chmod 600 "${file}" || true
  netplan generate
  netplan apply
}

write_sysctl() {
  cat > "${SYSCTL_FILE}" <<EOF
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_wmem = 4096 16384 ${TCP_WMEM_MAX}
net.ipv4.tcp_rmem = 4096 131072 ${TCP_RMEM_MAX}
net.ipv4.tcp_limit_output_bytes = ${TCP_LIMIT_OUTPUT_BYTES}
EOF
  sysctl --system >/tmp/singleflow-sysctl.log
}

write_qdisc_service() {
  local iface="$1"

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Set fq qdisc quantum for single-flow throughput
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=-/usr/sbin/tc qdisc del dev ${iface} root
ExecStart=/usr/sbin/tc qdisc add dev ${iface} root fq quantum ${FQ_QUANTUM} initial_quantum ${FQ_INITIAL_QUANTUM}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$(basename "${SERVICE_FILE}")" >/dev/null
  systemctl restart "$(basename "${SERVICE_FILE}")"
}

show_status() {
  local iface="$1"
  local netplan_file="$2"

  echo
  echo "Applied single-flow tuning."
  echo
  echo "Interface:"
  ip link show dev "${iface}" | head -n 1
  echo
  echo "TCP sysctl:"
  sysctl net.ipv4.tcp_congestion_control \
         net.core.default_qdisc \
         net.ipv4.tcp_wmem \
         net.ipv4.tcp_rmem \
         net.ipv4.tcp_limit_output_bytes
  echo
  echo "qdisc:"
  tc qdisc show dev "${iface}"
  echo
  echo "systemd:"
  systemctl is-enabled "$(basename "${SERVICE_FILE}")"
  systemctl is-active "$(basename "${SERVICE_FILE}")"
  echo
  if [[ -n "${netplan_file}" ]]; then
    echo "Netplan file: ${netplan_file}"
    echo "Backup files: ${netplan_file}.bak.singleflow.*"
  fi
  echo "Sysctl file: ${SYSCTL_FILE}"
  echo "Service file: ${SERVICE_FILE}"
}

main() {
  need_root
  need_cmd ip
  need_cmd tc
  need_cmd sysctl
  need_cmd systemctl
  need_cmd python3

  local iface
  local netplan_file
  iface="$(detect_iface)"
  netplan_file="$(detect_netplan_file)"

  if [[ ! -d "/sys/class/net/${iface}" ]]; then
    echo "Interface does not exist: ${iface}" >&2
    exit 1
  fi

  echo "Interface: ${iface}"
  echo "MTU: ${MTU}"
  echo "fq quantum: ${FQ_QUANTUM}"
  echo "fq initial_quantum: ${FQ_INITIAL_QUANTUM}"
  echo "tcp_wmem max: ${TCP_WMEM_MAX}"
  echo "tcp_rmem max: ${TCP_RMEM_MAX}"
  echo "tcp_limit_output_bytes: ${TCP_LIMIT_OUTPUT_BYTES}"
  echo "Netplan file: ${netplan_file:-none}"

  set_netplan_mtu "${iface}" "${netplan_file}"
  write_sysctl
  write_qdisc_service "${iface}"
  show_status "${iface}" "${netplan_file}"
}

main "$@"
