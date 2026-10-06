#!/bin/bash

# wg-remove.sh
# removes any configs from this repos
#
# Environment variables:
#   INTERACTIVE         set to "no" to never prompt (default: yes)
#   DISABLE_FORWARDING  with INTERACTIVE=no, set to "n" to keep ip forwarding on
#   PRIVATE_SUBNET      only used if the subnet can not be read from the config

# removal is best effort, a failing step must not abort the rest
set -uo pipefail

WG_CONFIG="/etc/wireguard/wg0.conf"
SYSCTL_CONFIG="/etc/sysctl.d/99-wireguard-forward.conf"
INTERACTIVE="${INTERACTIVE:-yes}"
FAILED=0

info() { echo "[i] $*"; }
ok()   { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[-] $*" >&2; exit 1; }
try()  { "$@" || { warn "Command failed: $*"; FAILED=$((FAILED + 1)); }; }

# delete an iptables rule only if it is there
iptables_del() {
    if iptables -C "$@" > /dev/null 2>&1; then
        try iptables -D "$@"
    fi
}

save_iptables() {
    iptables-save > /etc/iptables/rules.v4
}

# firewalld_cleanup <port> <subnet> [--permanent]
firewalld_cleanup() {
    local port="$1" subnet="$2"
    shift 2
    if [[ -n "$port" ]] && firewall-cmd "$@" --zone=public --query-port="$port/udp" > /dev/null 2>&1; then
        try firewall-cmd "$@" --zone=public --remove-port="$port/udp"
    fi
    if firewall-cmd "$@" --zone=trusted --query-source="$subnet" > /dev/null 2>&1; then
        try firewall-cmd "$@" --zone=trusted --remove-source="$subnet"
    fi
}

restore_firewall() {
    local port="$1" subnet="$2"
    info "Restoring firewall configuration"

    if command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1; then
        firewalld_cleanup "$port" "$subnet"
        firewalld_cleanup "$port" "$subnet" --permanent
    elif command -v iptables > /dev/null 2>&1; then
        # the generic RELATED,ESTABLISHED FORWARD rule is left in place on
        # purpose, other services may rely on it
        iptables_del FORWARD -m conntrack --ctstate NEW -s "$subnet" -m policy --pol none --dir in -j ACCEPT
        if [[ -n "$port" ]]; then
            iptables_del INPUT -p udp --dport "$port" -j ACCEPT
        fi
        if [[ -f /etc/iptables/rules.v4 ]]; then
            try save_iptables
        fi
    else
        warn "No supported firewall found, skipping"
    fi
}

disable_ip_forwarding() {
    local disable_forwarding
    if [[ "$INTERACTIVE" == "yes" ]]; then
        read -r -p "[?] Do you want to disable ip forwarding in the kernel? [y/n]: " -e -i "y" disable_forwarding
    else
        disable_forwarding="${DISABLE_FORWARDING:-y}"
    fi
    if [[ "$disable_forwarding" =~ ^[Yy] ]]; then
        info "Disabling ip forwarding in kernel"
        try rm -f -- "$SYSCTL_CONFIG"
        # older versions of wg-install.sh appended these to /etc/sysctl.conf
        if [[ -f /etc/sysctl.conf ]]; then
            try sed -i \
                -e '/^net\.ipv4\.ip_forward=1$/d' \
                -e '/^net\.ipv4\.conf\.all\.forwarding=1$/d' \
                -e '/^net\.ipv6\.conf\.all\.forwarding=1$/d' \
                /etc/sysctl.conf
        fi
        try sysctl -q -w net.ipv4.ip_forward=0 net.ipv4.conf.all.forwarding=0 net.ipv6.conf.all.forwarding=0
    fi
}

main() {
    local port parsed_subnet subnet answer

    if [[ "$EUID" -ne 0 ]]; then
        die "Sorry, you need to run this as root"
    fi

    if [[ ! -f "$WG_CONFIG" ]]; then
        die "There is no config file in $WG_CONFIG"
    fi

    # read the settings before anything is removed
    port=$(awk '$1 == "ListenPort" { print $3; exit }' "$WG_CONFIG")
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        warn "Could not read ListenPort from $WG_CONFIG, skipping the firewall port rules"
        port=""
    fi

    # first line: "# <subnet> <host:port> <server public key> <dns>"
    parsed_subnet=$(awk 'NR == 1 { print $2 }' "$WG_CONFIG")
    if [[ "$parsed_subnet" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
        subnet="$parsed_subnet"
    else
        subnet="${PRIVATE_SUBNET:-10.9.0.0/24}"
    fi

    if [[ "$INTERACTIVE" == "yes" ]]; then
        read -r -p "[?] This will remove the wireguard server config and all its clients. Continue? [y/N]: " answer
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            die "Aborted"
        fi
    fi

    info "Stopping wireguard service and interface"
    try systemctl disable --now wg-quick@wg0.service
    if ip link show dev wg0 > /dev/null 2>&1; then
        try wg-quick down wg0
    fi

    restore_firewall "$port" "$subnet"
    disable_ip_forwarding

    info "Cleaning up config file at $WG_CONFIG"
    try rm -f -- "$WG_CONFIG" "$WG_CONFIG.bak"

    if (( FAILED > 0 )); then
        warn "Finished with $FAILED failed step(s), check the messages above"
        exit 1
    fi
    ok "wireguard config installed from this repo has been cleaned up"
    info "Client config files under $HOME (*-wg0.conf) and the installed packages were left in place"
}

main "$@"
