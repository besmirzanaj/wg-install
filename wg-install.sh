#!/bin/bash

# wg-install.sh
# run on the first time to configure the server and the first client config
# the following times it will just generate additional client configs
#
# Usage: wg-install.sh [client-name]
#
# Environment variables:
#   INTERACTIVE         set to "no" to never prompt (default: yes)
#   PRIVATE_SUBNET      VPN subnet, must be a /24 like 10.9.0.0/24 (default)
#   SERVER_HOST         public IP/hostname of the server (default: detected)
#   SERVER_PORT         UDP listen port (default: random free port)
#   CLIENT_DNS          comma separated DNS servers pushed to the clients
#   WAN_INTERFACE_NAME  outgoing interface used for NAT (default: detected)
#
# Besmir Zanaj - 2020

set -Eeuo pipefail
umask 077

WG_DIR="/etc/wireguard"
WG_CONFIG="$WG_DIR/wg0.conf"
SYSCTL_CONFIG="/etc/sysctl.d/99-wireguard-forward.conf"
INTERACTIVE="${INTERACTIVE:-yes}"
TMP_CONFIG=""
DISTRO=""
VER=""

info() { echo "[i] $*"; }
ok()   { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[-] $*" >&2; exit 1; }

cleanup() {
    if [[ -n "$TMP_CONFIG" && -f "$TMP_CONFIG" ]]; then
        rm -f -- "$TMP_CONFIG"
    fi
}
trap cleanup EXIT
trap 'echo "[-] Error on line $LINENO: $BASH_COMMAND" >&2' ERR

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" > /dev/null 2>&1 || die "Required command '$cmd' not found"
    done
}

is_interactive() {
    [[ "$INTERACTIVE" == "yes" ]]
}

port_in_use() {
    ss -lun | awk -v p="$1" '{ for (i = 1; i <= NF; i++) if ($i ~ (":" p "$")) found = 1 } END { exit !found }'
}

generate_port() {
    local port attempt
    for attempt in $(seq 1 50); do
        port=$(shuf -i 35000-65000 -n 1) # lets choose something higher than 35000
        if ! port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    die "Could not find a free UDP port after $attempt attempts, set SERVER_PORT manually"
}

# only /24 networks of the form A.B.C.0/24 are supported
validate_subnet() {
    local subnet="$1" octet
    if [[ ! "$subnet" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/24$ ]]; then
        die "Unsupported subnet '$subnet', it must look like 10.9.0.0/24"
    fi
    for octet in "${BASH_REMATCH[@]:1:3}"; do
        (( 10#$octet <= 255 )) || die "Invalid subnet '$subnet'"
    done
}

detect_distro() {
    if [[ -e /etc/rocky-release ]]; then
        VER=$(rpm -E '%{rhel}')
        DISTRO="RockyLinux"
    elif [[ -e /etc/debian_version ]]; then
        if command -v lsb_release > /dev/null 2>&1; then
            DISTRO=$(lsb_release -ds)
        elif [[ -r /etc/os-release ]]; then
            # shellcheck disable=SC1091
            DISTRO=$(. /etc/os-release && echo "${PRETTY_NAME:-}")
        fi
        [[ -n "$DISTRO" ]] || die "Could not detect the Debian/Ubuntu release"
    else
        die "Your distribution is not supported (yet)"
    fi
    info "OS: $DISTRO${VER:+ $VER}"
}

apt_install() {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

install_packages() {
    info "Installing Wireguard package and its depencencies"
    if [[ "$DISTRO" =~ ^Ubuntu\ (22|24|26)\.04 ]]; then
        apt_install wireguard qrencode iptables
    elif [[ "$DISTRO" =~ ^Debian\ GNU/Linux\ (12|13)\  ]]; then
        apt_install wireguard qrencode iptables
    elif [[ "$DISTRO" == "RockyLinux" && "$VER" == "8" ]]; then
        dnf install -y epel-release
        dnf install -y wireguard-tools qrencode iptables
    elif [[ "$DISTRO" == "RockyLinux" && "$VER" =~ ^(9|10)$ ]]; then
        dnf install -y epel-release
        # plain "iptables" resolves to iptables-legacy from EPEL here
        dnf install -y wireguard-tools qrencode iptables-nft
    else
        die "Not supported OS: $DISTRO $VER"
    fi
    require_cmd wg wg-quick
    info "Installed Wireguard package and its depencencies"
}

choose_wan_interface() {
    local detected answer
    if [[ -z "${WAN_INTERFACE_NAME:-}" ]]; then
        detected=$(ip -4 route show default | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
        detected="${detected:-eth0}"
        if is_interactive; then
            read -r -p "Enter the name of the WAN network interface ([ENTER] set to default: $detected): " answer
        fi
        WAN_INTERFACE_NAME="${answer:-$detected}"
    fi
    ip link show dev "$WAN_INTERFACE_NAME" > /dev/null 2>&1 \
        || die "Network interface '$WAN_INTERFACE_NAME' does not exist. Use environment variable WAN_INTERFACE_NAME to set the correct one"
}

choose_server_host() {
    local confirm
    if [[ -z "${SERVER_HOST:-}" ]]; then
        require_cmd curl
        SERVER_HOST=$(curl -4 -fsS --max-time 10 https://ifconfig.me) \
            || die "Could not detect the public IP address. Use environment variable SERVER_HOST to set it"
        if is_interactive; then
            read -r -p "[i] Servers public IP address is $SERVER_HOST  Is that correct? [y/n]: " -e -i "y" confirm
            if [[ ! "$confirm" =~ ^[Yy] ]]; then
                die "Aborted. Use environment variable SERVER_HOST to set the correct public IP address"
            fi
        fi
    fi
    [[ "$SERVER_HOST" =~ ^[][A-Za-z0-9.:_-]+$ ]] || die "Invalid SERVER_HOST '$SERVER_HOST'"
}

choose_server_port() {
    if [[ -z "${SERVER_PORT:-}" ]]; then
        SERVER_PORT=$(generate_port)
    fi
    if [[ ! "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$SERVER_PORT < 1 || 10#$SERVER_PORT > 65535 )); then
        die "Invalid SERVER_PORT '$SERVER_PORT', it must be a number between 1 and 65535"
    fi
}

choose_dns() {
    local dns_choice=1
    if [[ -z "${CLIENT_DNS:-}" ]]; then
        if is_interactive; then
            echo "Which DNS do you want to use with the VPN?"
            echo "   1) Cloudflare [Default]"
            echo "   2) Google"
            echo "   3) OpenDNS (has phishing protection and other security filters)"
            echo "   4) Quad9 (Malware protection)"
            echo "   5) AdGuard DNS (automatically blocks ads)"
            read -r -p "[?] DNS (1-5)[1]: " -e -i 1 dns_choice
        fi

        case "$dns_choice" in
            1) CLIENT_DNS="1.1.1.1,1.0.0.1" ;;
            2) CLIENT_DNS="8.8.8.8,8.8.4.4" ;;
            3) CLIENT_DNS="208.67.222.222,208.67.220.220" ;;
            4) CLIENT_DNS="9.9.9.9" ;;
            5) CLIENT_DNS="94.140.14.14,94.140.15.15" ;;
            *) die "Invalid DNS choice '$dns_choice'" ;;
        esac
    fi
    # the value is stored space separated in the first line of $WG_CONFIG
    [[ "$CLIENT_DNS" =~ ^[0-9A-Fa-f.:,]+$ ]] || die "Invalid CLIENT_DNS '$CLIENT_DNS', use comma separated IP addresses"
}

# prints "<private key> <public key>"
generate_keypair() {
    local privkey pubkey
    privkey=$(wg genkey)
    pubkey=$(printf '%s\n' "$privkey" | wg pubkey)
    [[ -n "$privkey" && -n "$pubkey" ]] || die "Could not generate a wireguard key pair"
    echo "$privkey $pubkey"
}

# write_client_config <name> <private key> <address> <mask> <dns> <server public key> <endpoint>
write_client_config() {
    local client_config="$HOME/$1-wg0.conf"
    echo "[Interface]
PrivateKey = $2
Address = $3/$4
DNS = $5
[Peer]
PublicKey = $6
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $7
PersistentKeepalive = 25" > "$client_config"
    chmod 600 "$client_config"
}

show_qr() {
    if command -v qrencode > /dev/null 2>&1; then
        qrencode -t ansiutf8 -l L < "$1" || warn "Could not generate the QR code for $1"
    else
        warn "qrencode is not installed, skipping the QR code"
    fi
}

enable_ip_forwarding() {
    mkdir -p "$(dirname "$SYSCTL_CONFIG")"
    echo "net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv6.conf.all.forwarding=1" > "$SYSCTL_CONFIG"
    chmod 644 "$SYSCTL_CONFIG"

    # Enable these settings right now, no need to reboot
    sysctl -q -p "$SYSCTL_CONFIG"
}

# append an iptables rule unless it is already there
iptables_add() {
    iptables -C "$@" > /dev/null 2>&1 || iptables -A "$@"
}

configure_firewall() {
    if [[ "$DISTRO" == "RockyLinux" ]]; then
        # Install some basic packages
        dnf install -y firewalld
        systemctl enable --now firewalld
        # Configure Firewall and natting
        firewall-cmd --zone=public --add-port="$SERVER_PORT/udp"
        firewall-cmd --zone=trusted --add-source="$PRIVATE_SUBNET"
        firewall-cmd --permanent --zone=public --add-port="$SERVER_PORT/udp"
        firewall-cmd --permanent --zone=trusted --add-source="$PRIVATE_SUBNET"
    else
        require_cmd iptables iptables-save
        iptables_add FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        iptables_add FORWARD -m conntrack --ctstate NEW -s "$PRIVATE_SUBNET" -m policy --pol none --dir in -j ACCEPT
        iptables_add INPUT -p udp --dport "$SERVER_PORT" -j ACCEPT
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
    fi
}

install_server() {
    local subnet_prefix subnet_mask gateway_address client_address
    local keys server_privkey server_pubkey client_privkey client_pubkey

    ### Install server and add default client
    PRIVATE_SUBNET="${PRIVATE_SUBNET:-10.9.0.0/24}"
    validate_subnet "$PRIVATE_SUBNET"
    subnet_prefix="${PRIVATE_SUBNET%.*}."
    subnet_mask="${PRIVATE_SUBNET#*/}"
    gateway_address="${subnet_prefix}1"
    client_address="${subnet_prefix}3"

    require_cmd ip ss shuf systemctl sysctl
    choose_wan_interface
    choose_server_host
    choose_server_port
    choose_dns

    install_packages

    keys=$(generate_keypair)
    read -r server_privkey server_pubkey <<< "$keys"
    keys=$(generate_keypair)
    read -r client_privkey client_pubkey <<< "$keys"

    # build the config in a temp file, so a failed run never leaves a
    # half written $WG_CONFIG behind that looks like an installed server
    mkdir -p "$WG_DIR"
    TMP_CONFIG=$(mktemp "$WG_CONFIG.XXXXXX")

    echo "# $PRIVATE_SUBNET $SERVER_HOST:$SERVER_PORT $server_pubkey $CLIENT_DNS
[Interface]
Address = $gateway_address/$subnet_mask
ListenPort = $SERVER_PORT
PrivateKey = $server_privkey
SaveConfig = false
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE;
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE;
# client
[Peer]
PublicKey = $client_pubkey
AllowedIPs = $client_address/32" > "$TMP_CONFIG"

    enable_ip_forwarding
    configure_firewall

    chmod 600 "$TMP_CONFIG"
    mv -f "$TMP_CONFIG" "$WG_CONFIG"

    write_client_config client "$client_privkey" "$client_address" "$subnet_mask" "$CLIENT_DNS" "$server_pubkey" "$SERVER_HOST:$SERVER_PORT"

    systemctl enable --now wg-quick@wg0.service \
        || die "Could not start wireguard, check 'journalctl -u wg-quick@wg0'. Run wg-remove.sh before trying again"

    show_qr "$HOME/client-wg0.conf"

    ok "Your first client config is saved at -> $HOME/client-wg0.conf"
    echo " "
    ok "You can use your mobile device to scan the above barcode."
    ok "The Wireguard VPN server is up and running. Enjoy your fresh VPN installation! :^)"
    ok "To add more client configs run the same script again and enter the client config name."
}

add_client() {
    local client_name="${1:-}"
    local private_subnet server_endpoint server_pubkey client_dns extra
    local subnet_prefix subnet_mask last_ip client_address keys client_privkey client_pubkey

    ### Server is installed, add a new client
    require_cmd wg
    if [[ -z "$client_name" ]]; then
        is_interactive || die "Missing client name, usage: $0 <client-name>"
        echo "[?] Tell me a name for the client config file [no special characters]."
        read -r -p "[+] Client name: " -e client_name
    fi
    [[ "$client_name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] \
        || die "Invalid client name '$client_name', use up to 32 letters, digits, '_' or '-'"
    [[ ! -e "$HOME/$client_name-wg0.conf" ]] || die "$HOME/$client_name-wg0.conf already exists"
    if grep -qxF "# $client_name" "$WG_CONFIG"; then
        die "A client named '$client_name' already exists in $WG_CONFIG"
    fi

    # first line: "# <subnet> <host:port> <server public key> <dns>"
    read -r _ private_subnet server_endpoint server_pubkey client_dns extra < "$WG_CONFIG" || true
    if [[ -z "$private_subnet" || -z "$server_endpoint" || -z "$server_pubkey" || -z "$client_dns" || -n "$extra" ]]; then
        die "Could not read the server settings from the first line of $WG_CONFIG"
    fi
    validate_subnet "$private_subnet"
    subnet_prefix="${private_subnet%.*}."
    subnet_mask="${private_subnet#*/}"

    # next free address: highest one in use + 1, .1 is the gateway
    last_ip=$(awk '$1 == "AllowedIPs" && $3 ~ /\/32$/ { split($3, a, /[.\/]/); if (a[4] + 0 > max) max = a[4] + 0 } END { print (max < 2 ? 2 : max) }' "$WG_CONFIG")
    (( last_ip < 254 )) || die "No free addresses left in $private_subnet"
    client_address="${subnet_prefix}$((last_ip + 1))"

    keys=$(generate_keypair)
    read -r client_privkey client_pubkey <<< "$keys"

    cp -p -- "$WG_CONFIG" "$WG_CONFIG.bak"
    TMP_CONFIG=$(mktemp "$WG_CONFIG.XXXXXX")
    cat -- "$WG_CONFIG" > "$TMP_CONFIG"
    echo "# $client_name
[Peer]
PublicKey = $client_pubkey
AllowedIPs = $client_address/32" >> "$TMP_CONFIG"
    chmod 600 "$TMP_CONFIG"
    mv -f "$TMP_CONFIG" "$WG_CONFIG"

    write_client_config "$client_name" "$client_privkey" "$client_address" "$subnet_mask" "$client_dns" "$server_pubkey" "$server_endpoint"
    show_qr "$HOME/$client_name-wg0.conf"

    if wg show wg0 > /dev/null 2>&1; then
        wg set wg0 peer "$client_pubkey" allowed-ips "$client_address/32"
    else
        warn "wg0 is not running, the new client will be active once it is started"
    fi
    ok "Client added, new configuration file --> $HOME/$client_name-wg0.conf"
}

main() {
    if [[ "$EUID" -ne 0 ]]; then
        die "Sorry, you need to run this as root"
    fi

    if [[ ! -e /dev/net/tun ]]; then
        die "The TUN device is not available. You need to enable TUN before running this script"
    fi

    detect_distro

    if [[ ! -f "$WG_CONFIG" ]]; then
        install_server
    else
        add_client "$@"
    fi
}

main "$@"
