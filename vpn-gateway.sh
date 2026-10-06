#!/usr/bin/env bash
# =============================================================================
#  vpn-gateway.sh - VPN Gateway with kill switch & port forwarding
#  Version : 1.1
#  Author  : MorphyDK
#  License : MIT
#  Tested  : Ubuntu 24.04 Desktop
#
#  Turns this machine into a VPN gateway for your LAN. Clients that use this
#  host as their default gateway go out through the VPN tunnel, forwarded
#  ports are sent straight on to one client, and a kill switch cuts those
#  LAN clients off the moment the tunnel drops.
#
#  NOTE: the kill switch protects the LAN CLIENTS routed through this
#  gateway. Traffic from the gateway machine itself is not blocked.
#
#  Providers (auto-detected):
#    TorGuard   - WireGuard / OpenConnect, static forwarded ports
#    Proton VPN - dynamic port via NAT-PMP, kept alive by a systemd service
#                 that follows port changes on reconnect / server change
#    Generic    - any WireGuard or tun interface, static ports
#
#  Usage:  sudo ./vpn-gateway.sh            interactive menu
#          sudo ./vpn-gateway.sh --apply    rebuild from saved settings, no menus
#          sudo ./vpn-gateway.sh --detect   list detected VPN tunnels
#          sudo ./vpn-gateway.sh --keeper   NAT-PMP keep-alive loop (run by systemd)
# =============================================================================
set -uo pipefail

VERSION="1.1"
CONF_FILE="/etc/vpn-gateway.conf"
OLD_CONF_FILE="/etc/torguard-gateway.conf"          # v2.x settings, migrated
LOG_FILE="/var/log/vpn-gateway.log"
SYSCTL_FILE="/etc/sysctl.d/99-vpn-gateway.conf"
OLD_SYSCTL_FILE="/etc/sysctl.d/99-torguard-gateway.conf"
INSTALL_PATH="/usr/local/sbin/vpn-gateway.sh"
SERVICE="vpn-gateway-keeper"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
STATE_DIR="/run/vpn-gateway"
STATE_FILE="$STATE_DIR/keeper.state"
CHAIN_DNAT="VPNGW_DNAT"
CHAIN_FWD="VPNGW_FWD"
TTY="/dev/tty"
REPO_URL="https://github.com/MorphyDK/vpn-gateway"
SETUP_MARKER="/etc/vpn-gateway.setup"

# Components:  command | package | required (1) or optional (0) | what it is for
DEPS=(
    "iptables|iptables|1|firewall rules: kill switch, NAT, port forwarding"
    "ip6tables|iptables|1|IPv6 leak protection"
    "ip|iproute2|1|interfaces and routing"
    "sysctl|procps|1|IP forwarding settings"
    "pgrep|procps|1|VPN app detection"
    "flock|util-linux|1|safe rebuilds (locking)"
    "ping|iputils-ping|0|client reachability check"
    "curl|curl|0|public IP through the tunnel"
    "natpmpc|natpmpc|0|Proton VPN port forwarding (NAT-PMP)"
    "wg|wireguard-tools|0|WireGuard tunnels (wg / wg-quick configs)"
)
LOCK_FILE="/run/vpn-gateway.lock"
IN_SERVICE=0                 # 1 when running as the background watcher

# --- Defaults (saved settings in $CONF_FILE override these) -----------------
LAN_IF="ens18"               # LAN card facing the client
PROVIDER="torguard"          # torguard | proton | generic
VPN_IFACES="torguard-wg tun0" # tunnel interface(s), space separated
CLIENT_IP="192.168.0.186"    # client that receives the forwarded port(s)
PORT_MODE="static"           # static | natpmp
PORTS="38271 38272"          # static mode: forwarded ports (empty = off)
PROTO="tcp"                  # static mode: tcp | udp | both
NATPMP_GW="10.2.0.1"         # natpmp mode: Proton VPN NAT-PMP gateway
LOCAL_PORT=""                # natpmp mode: fixed port on client (empty = same as public)
PORT_HOOK=""                 # natpmp mode: command run on port change, new port as $1
BLOCK_IPV6="yes"             # drop all IPv6 forwarding (leak protection)
MSS_CLAMP="yes"              # clamp TCP MSS to the tunnel MTU
AUTO_FOLLOW="yes"            # follow the active VPN automatically (TorGuard <-> Proton)

VPN_IFS=()
DIRTY=0
FAIL_FILE=""
MENU_CHOICE=""
PORTINFO=""
WG_IF=""; OC_IF=""           # only used when migrating v2.x settings
K_STATE=""; K_PORT=""; K_IFACE=""; K_UPDATED=""; K_MSG=""

# =============================================================================
#  Colours - "ui" keeps a black background, "cli" uses the terminal's own
# =============================================================================
set_palette() {
    if [[ $1 == ui ]]; then R=$'\033[0;37;40m'; else R=$'\033[0m'; fi
    TXT=$'\033[22;37m'; GRY=$'\033[22;90m'; WHT=$'\033[1;97m'
    RED=$'\033[1;31m';  GRN=$'\033[1;32m';  YLW=$'\033[1;33m'
    BLU=$'\033[1;34m';  MAG=$'\033[1;35m';  CYN=$'\033[1;36m'
}
set_palette cli

# =============================================================================
#  Shell UI
# =============================================================================
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
rep()  { local s="" i; for (( i = 0; i < $2; i++ )); do s+="$1"; done; printf '%s' "$s"; }
trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
nap()  { sleep "$1" & wait $!; }   # interruptible sleep for the keeper
kv()   { printf '%-26s%s%s%s' "$1" "$CYN" "$2" "$R"; }

ui_clear() { printf '%s\033[2J\033[H' "$R" >"$TTY"; }
hr()       { printf '  %s%s%s\n' "$GRY" "$(rep '─' 66)" "$R" >"$TTY"; }

colorize() {  # highlight status words in message text
    sed -E "s/\b(ARMED|UP|ON|AVAILABLE|WORKS|OK|yes)\b/${GRN}\1${TXT}/g; s/\b(DOWN|OFF|NOT|FAILED|NO|REMOVES|ERROR)\b/${RED}\1${TXT}/g"
}
body()  { printf '%b\n' "$1" | colorize | sed "s/^/    ${TXT}/"; printf '%s' "$R"; }
title() { printf '\n  %s▌ %s%s\n' "$1" "$(trim "$2" | tr '[:lower:]' '[:upper:]')" "$R"; }

banner() {
    ui_clear
    {
        printf '\n  %s%s%s\n' "$BLU" "$(rep '━' 66)" "$R"
        printf '  %s ▓▒░ %sV P N   G A T E W A Y%s  %sv%s%s    %s// kill switch · port forwarding%s\n' \
            "$CYN" "$WHT" "$R" "$MAG" "$VERSION" "$R" "$GRY" "$R"
        printf '  %s%s%s\n' "$BLU" "$(rep '━' 66)" "$R"
    } >"$TTY"
}

msg() {  # $1=text $2=title
    {
        title "$MAG" "${2:-Info}"
        body "$1"
        printf '\n  %s[ press Enter ]%s' "$GRY" "$R"
    } >"$TTY"
    read -r _ <"$TTY" || true
}

ask() {  # $1=text $2=title - returns 0 on yes (default: no)
    local a
    {
        title "$YLW" "${2:-Confirm}"
        body "$1"
        printf '\n  %s❯%s %s[y/N]%s ' "$YLW" "$R" "$WHT" "$R"
    } >"$TTY"
    read -r a <"$TTY" || return 1
    [[ $a =~ ^[YyJj] ]]
}

input_box() {  # $1=title $2=text $3=current value - prints the new value
    local v
    {
        title "$CYN" "$1"
        body "$2"
        printf '    %s(edit the value, Enter to accept)%s\n' "$GRY" "$R"
    } >"$TTY"
    read -e -r -i "$3" -p "  > " v <"$TTY" || v=$3
    printf '%s' "$v"
}

MENU_REFRESH=0   # >0: single-key menu that returns 2 every N seconds to redraw
ui_menu() {  # $1=back label, then key/label pairs - sets MENU_CHOICE, returns 1 on back, 2 on refresh
    local back=$1 c k rc
    local -a keys=()
    shift
    {
        echo
        while (( $# >= 2 )); do
            if [[ $1 == "-" ]]; then
                printf '\n   %s%s\n' "$2" "$R"          # section header
            else
                keys+=("$1")
                printf '   %s[%s]%s  %s%s%s\n' "$CYN" "$1" "$R" "$WHT" "$2" "$R"
            fi
            shift 2
        done
        printf '   %s[Q]%s  %s%s%s\n' "$RED" "$R" "$GRY" "$back" "$R"
    } >"$TTY"
    hr
    while true; do
        printf '  %svpngw%s ❯ %s' "$GRN" "$CYN" "$WHT" >"$TTY"
        if (( MENU_REFRESH > 0 )); then
            read -rsn1 -t "$MENU_REFRESH" c <"$TTY"
            rc=$?
            if (( rc > 128 )); then printf '%s' "$R" >"$TTY"; return 2; fi   # timeout -> redraw
            (( rc == 0 )) || return 1
            printf '%s\n' "$c" >"$TTY"
        else
            read -r c <"$TTY" || return 1
        fi
        printf '%s' "$R" >"$TTY"
        c=$(trim "$c" | tr '[:lower:]' '[:upper:]')
        if [[ $c == Q || $c == B ]]; then return 1; fi
        for k in "${keys[@]}"; do
            if [[ $(tr '[:lower:]' '[:upper:]' <<<"$k") == "$c" ]]; then MENU_CHOICE=$k; return 0; fi
        done
        printf '\033[1A\033[2K' >"$TTY"   # wipe the line and ask again
    done
}

ui_choose() {  # $1=title $2=text $3=current key, then key/label pairs - prints chosen key
    local text=$2 cur=$3 c i mark
    local -a keys=() labels=()
    {
        title "$CYN" "$1"
        shift 3
        while (( $# >= 2 )); do keys+=("$1"); labels+=("$2"); shift 2; done
        if [[ -n $text ]]; then body "$text"; fi
        for i in "${!keys[@]}"; do
            if [[ ${keys[$i]} == "$cur" ]]; then mark="${GRN}●${R}"; else mark="${GRY}○${R}"; fi
            printf '    %s[%d]%s %s %s%-14s%s %s%s%s\n' "$CYN" $((i + 1)) "$R" "$mark" \
                "$WHT" "${keys[$i]}" "$R" "$GRY" "${labels[$i]}" "$R"
        done
        printf '    %s(number to choose, Enter = keep current)%s\n' "$GRY" "$R"
    } >"$TTY"
    while true; do
        printf '  > ' >"$TTY"
        read -r c <"$TTY" || { printf '%s' "$cur"; return 0; }
        c=$(trim "$c")
        if [[ -z $c ]]; then printf '%s' "$cur"; return 0; fi
        if [[ $c =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#keys[@]} )); then
            printf '%s' "${keys[$((c - 1))]}"; return 0
        fi
        printf '\033[1A\033[2K' >"$TTY"
    done
}

run_gauge() {  # $1=title $2=text, rest = command - spinner while it runs, returns its exit code
    local text pid rc i=0 start=$SECONDS spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    text=$(printf '%b' "$2" | head -n1)
    shift 2
    "$@" >>"$LOG_FILE" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s%s%s %s(%ds)%s\033[K' "$CYN" "${spin:i++%10:1}" "$R" \
            "$WHT" "$text" "$R" "$GRY" $(( SECONDS - start )) "$R" >"$TTY"
        sleep 0.15
    done
    wait "$pid"
    rc=$?
    if (( rc == 0 )); then
        printf '\r  %s✔%s %s %s(%ds)%s\033[K\n' "$GRN" "$R" "$text" "$GRY" $(( SECONDS - start )) "$R" >"$TTY"
    else
        printf '\r  %s✘%s %s %sfailed%s\033[K\n' "$RED" "$R" "$text" "$RED" "$R" >"$TTY"
    fi
    return "$rc"
}

colorize_rules() {  # colours for iptables listings and the log
    sed -E "s/^(Chain .*)$/${CYN}\1${TXT}/; s/^(=====.*)$/${YLW}\1${TXT}/; \
            s/\b(ACCEPT|OK)\b/${GRN}\1${TXT}/g; s/\b(DROP|REJECT|FAILED)\b/${RED}\1${TXT}/g; \
            s/\b(DNAT|MASQUERADE|TCPMSS|VPNGW_DNAT|VPNGW_FWD)\b/${MAG}\1${TXT}/g; \
            s/(vpngw-killswitch|vpngw-guard)/${YLW}\1${TXT}/g"
}

show_file() {  # $1=title $2=file - built-in pager: Enter/Space = next, b = back, q = menu
    local rows cols total start=0 end key line
    local -a lines
    rows=$(( $(tput lines 2>/dev/null || echo 30) - 9 )); (( rows < 8 )) && rows=8
    cols=$(( $(tput cols 2>/dev/null || echo 100) - 4 ))
    mapfile -t lines <"$2"
    total=${#lines[@]}
    while true; do
        end=$(( start + rows < total ? start + rows : total ))
        banner
        {
            title "$MAG" "$1"
            printf '   %slines %d-%d of %d%s\n\n' "$GRY" $(( total ? start + 1 : 0 )) "$end" "$total" "$R"
            for line in "${lines[@]:start:rows}"; do
                printf '  %s%s\n' "$TXT" "${line:0:cols}"
            done | colorize_rules
            printf '%s' "$R"
        } >"$TTY"
        hr
        if (( end >= total )); then
            printf '  %s[q] / [Enter]%s back to menu   %s[b]%s previous page ' "$CYN" "$R" "$CYN" "$R" >"$TTY"
        else
            printf '  %s[Enter]%s next page   %s[b]%s previous page   %s[q]%s back to menu ' "$CYN" "$R" "$CYN" "$R" "$CYN" "$R" >"$TTY"
        fi
        read -rsn1 key <"$TTY" || return 0
        case $key in
            q|Q) return 0 ;;
            b|B) start=$(( start - rows < 0 ? 0 : start - rows )) ;;
            *)   if (( end >= total )); then return 0; fi
                 start=$end ;;
        esac
    done
}

if_ipv4() { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
lan_ip()  { if_ipv4 "$LAN_IF"; }

ensure_pkg() {  # $1=command $2=package
    command -v "$1" >/dev/null && return 0
    log "Installing package $2"
    { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2"; } >>"$LOG_FILE" 2>&1
}

provider_label() {
    case $1 in
        torguard) echo "TorGuard" ;;
        proton)   echo "Proton VPN" ;;
        *)        echo "Generic" ;;
    esac
}
mode_label() {
    if [[ $PORT_MODE == natpmp ]]; then echo "Dynamic (NAT-PMP)"
    elif [[ -n $PORTS ]]; then echo "Static ports"
    else echo "Off"; fi
}
killswitch_state() {
    if iptables -S FORWARD 2>/dev/null | grep -qE 'vpngw-killswitch|tg-killswitch'; then echo "ARMED"; else echo "not active"; fi
}

usage() {
    echo "VPN Gateway v$VERSION"
    echo "  sudo $0            interactive menu"
    echo "  sudo $0 --apply    rebuild rules from $CONF_FILE without menus"
    echo "  sudo $0 --detect   list detected VPN tunnels"
    echo "  sudo $0 --keeper   NAT-PMP keep-alive loop (normally run by systemd)"
}

# =============================================================================
#  Validation
# =============================================================================
valid_ip() {
    local IFS=. o
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for o in $1; do (( 10#$o <= 255 )) || return 1; done
}
valid_ports() {
    local p
    [[ -n ${1// /} ]] || return 1
    for p in $1; do
        [[ $p =~ ^[0-9]{1,5}$ ]] || return 1
        (( 10#$p >= 1 && 10#$p <= 65535 )) || return 1
    done
}
valid_ifname() { [[ $1 =~ ^[A-Za-z0-9._-]{1,15}$ ]]; }
iface_exists() { [[ -n $1 && -e /sys/class/net/$1 ]]; }

build_vpn_ifs() {
    local v
    VPN_IFS=()
    for v in $VPN_IFACES; do VPN_IFS+=("$v"); done
}

check_settings() {  # prints problems, empty output = all good
    local err="" v
    build_vpn_ifs
    iface_exists "$LAN_IF"   || err+="- LAN interface '$LAN_IF' does not exist\n"
    (( ${#VPN_IFS[@]} > 0 )) || err+="- No VPN interface configured (try 'Detect VPN provider')\n"
    for v in "${VPN_IFS[@]}"; do
        valid_ifname "$v"    || err+="- VPN interface '$v' is not a valid name\n"
    done
    valid_ip "$CLIENT_IP"    || err+="- Client IP '$CLIENT_IP' is not valid\n"
    if [[ $PORT_MODE == natpmp ]]; then
        valid_ip "$NATPMP_GW" || err+="- NAT-PMP gateway '$NATPMP_GW' is not valid\n"
        if [[ -n $LOCAL_PORT ]] && ! valid_ports "$LOCAL_PORT"; then err+="- Client port '$LOCAL_PORT' is not valid\n"; fi
    elif [[ -n $PORTS ]] && ! valid_ports "$PORTS"; then
        err+="- Port list '$PORTS' is not valid\n"
    fi
    printf '%b' "$err"
}

# =============================================================================
#  Config
# =============================================================================
save_config() {
    local v
    {
        echo "# VPN Gateway settings - written by vpn-gateway.sh v$VERSION"
        for v in LAN_IF PROVIDER VPN_IFACES CLIENT_IP PORT_MODE PORTS PROTO \
                 NATPMP_GW LOCAL_PORT PORT_HOOK BLOCK_IPV6 MSS_CLAMP AUTO_FOLLOW; do
            printf '%s=%q\n' "$v" "${!v}"
        done
    } >"$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

load_config() {
    if [[ -f $CONF_FILE ]]; then
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    elif [[ -f $OLD_CONF_FILE ]]; then
        # shellcheck source=/dev/null
        source "$OLD_CONF_FILE"
        VPN_IFACES=$(echo "$WG_IF $OC_IF" | xargs)
        PROVIDER="torguard"; PORT_MODE="static"
        save_config
        log "Migrated settings from $OLD_CONF_FILE"
    fi
}

# =============================================================================
#  VPN detection
# =============================================================================
is_tunnel() {
    [[ -e /sys/class/net/$1/tun_flags ]] && return 0
    ip -d link show "$1" 2>/dev/null | grep -qw wireguard
}
tunnel_kind() { if [[ -e /sys/class/net/$1/tun_flags ]]; then echo "tun"; else echo "wireguard"; fi; }

nm_conn_name() {  # NetworkManager connection name for a device (Proton app uses NM)
    command -v nmcli >/dev/null || return 0
    nmcli -t -f DEVICE,NAME connection show --active 2>/dev/null \
        | awk -F: -v d="$1" '$1 == d { print $2; exit }'
}

guess_provider() {  # several independent hints, strongest first
    local i=$1 hint
    case ${i,,} in
        *torguard*|tg-*|tg[0-9]*)   echo torguard; return ;;
        proton*|pvpn*)              echo proton;   return ;;
    esac
    hint=$(nm_conn_name "$i")
    case ${hint,,} in
        *proton*)   echo proton;   return ;;
        *torguard*) echo torguard; return ;;
    esac
    if [[ -r /etc/wireguard/$i.conf ]]; then
        if grep -qi 'torguard' "/etc/wireguard/$i.conf"; then echo torguard; return; fi
        if grep -qiE 'proton|netshield|10\.2\.0\.' "/etc/wireguard/$i.conf"; then echo proton; return; fi
    fi
    if [[ $(if_ipv4 "$i") == 10.2.0.* || $(if_ipv4 "$i") == 10.96.* ]]; then echo proton; return; fi
    # Fall back on which VPN app is running
    if pgrep -i 'protonvpn|proton-vpn' >/dev/null; then echo proton; return; fi
    if pgrep -i '^torguard' >/dev/null || pgrep -x openconnect >/dev/null; then echo torguard; return; fi
    echo generic
}

detect_tunnels() {  # prints: iface|kind|ipv4|provider
    local p i
    for p in /sys/class/net/*; do
        i=${p##*/}
        case $i in
            lo|"$LAN_IF"|docker*|br-*|veth*|virbr*|pvpnksintrf*|ipv6leakintrf*|tailscale*|zt*) continue ;;
        esac
        is_tunnel "$i" || continue
        printf '%s|%s|%s|%s\n' "$i" "$(tunnel_kind "$i")" "$(if_ipv4 "$i")" "$(guess_provider "$i")"
    done
}

# --- Auto-follow: which known VPN is online right now? -----------------------
egress_iface() {  # the interface this machine's internet traffic leaves through right now
    ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}' | head -n1
}

auto_target() {  # prints "provider|iface" of the known VPN that actually carries the traffic
    local i kind addr prov egress egress_is_tunnel=0
    local -a known=()
    egress=$(egress_iface)
    while IFS='|' read -r i kind addr prov; do
        [[ -n $i && -n $addr ]] || continue
        [[ $i == "$egress" ]] && egress_is_tunnel=1
        [[ $prov == torguard || $prov == proton ]] || continue
        if [[ $i == "$egress" ]]; then echo "$prov|$i"; return 0; fi   # the one in use wins
        known+=("$prov|$i")
    done <<<"$(detect_tunnels)"
    # Traffic leaves through some other tunnel -> don't guess
    (( egress_is_tunnel )) && return 1
    # No tunnel carries the default route: only trust one single, unambiguous candidate
    if (( ${#known[@]} == 1 )); then echo "${known[0]}"; return 0; fi
    return 1
}

FOLLOW_SEEN=""
stable_target() {  # $1=target - true only when the same target is seen twice in a row
    if [[ $1 == "$FOLLOW_SEEN" ]]; then return 0; fi
    FOLLOW_SEEN=$1
    return 1
}
needs_switch() {  # $1=provider $2=iface - true when the settings don't match
    [[ $1 != "$PROVIDER" ]] && return 0
    [[ " $VPN_IFACES " == *" $2 "* ]] && return 1
    return 0
}
apply_switch() {  # $1=provider $2=iface - update and save the settings
    log "Auto-follow: $(provider_label "$PROVIDER") (${VPN_IFACES:-none}) -> $(provider_label "$1") ($2)"
    PROVIDER=$1
    VPN_IFACES=$2
    if [[ $1 == proton ]]; then PORT_MODE="natpmp"; else PORT_MODE="static"; fi
    save_config
}
sync_saved_rules() {  # keep /etc/iptables in step after an automatic rebuild
    if [[ -f /etc/iptables/rules.v4 ]] && command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save >>"$LOG_FILE" 2>&1
    fi
}

natpmp_probe() { timeout 8 natpmpc -g "$NATPMP_GW" >/dev/null 2>&1; }

detect_vpn() {
    local lines i kind addr prov table="" best="" ifaces="" pf=""
    banner
    lines=$(detect_tunnels)
    if [[ -z $lines ]]; then
        msg "No active VPN tunnel found.\n\nConnect your VPN first (Proton VPN app, TorGuard, wg-quick, OpenConnect...) and run detection again.\n\nYou can also set interfaces by hand under Settings." " Detect VPN " 14
        return
    fi
    while IFS='|' read -r i kind addr prov; do
        table+="$(printf '%-14s %-10s %-15s %s' "$i" "$kind" "${addr:-no IPv4}" "$(provider_label "$prov")")\n"
        ifaces+="$i "
        if [[ -z $best || $best == generic ]]; then best=$prov; fi
    done <<<"$lines"
    ifaces=$(xargs <<<"$ifaces")

    if [[ $best == proton ]]; then
        if ! command -v natpmpc >/dev/null && ! run_gauge " Detect VPN " "Proton VPN found - installing natpmpc to test port forwarding..." ensure_pkg natpmpc natpmpc; then
            pf="unknown"; table+="\nNAT-PMP: could not install natpmpc to test it"
        elif run_gauge " Detect VPN " "Checking Proton NAT-PMP port forwarding..." natpmp_probe; then
            pf="yes"; table+="\nNAT-PMP port forwarding: AVAILABLE"
        else
            pf="no"; table+="\nNAT-PMP port forwarding: NOT answering\n(needs a paid plan, a P2P server and port forwarding / NAT-PMP enabled)"
        fi
    fi

    ask "Found these VPN tunnels:\n\nInterface      Type       Address         Provider\n$table\n\nUse $(provider_label "$best") on: $ifaces ?" " Detect VPN " 22 || return

    PROVIDER=$best
    VPN_IFACES=$ifaces
    if [[ $PROVIDER == proton ]]; then
        if [[ $pf == no ]] && ! ask "NAT-PMP is not answering right now.\n\nYes = use dynamic port forwarding anyway (the keeper keeps trying)\nNo  = run the gateway without port forwarding" " Proton port forwarding " 12; then
            PORT_MODE="static"; PORTS=""
        else
            PORT_MODE="natpmp"
        fi
    else
        PORT_MODE="static"
    fi
    save_config
    DIRTY=1
    log "Detected provider $PROVIDER on '$VPN_IFACES' (port mode $PORT_MODE)"
    msg "Saved: $(provider_label "$PROVIDER") on $VPN_IFACES\nPort forwarding: $(mode_label)\n\nRebuild the gateway to apply." " Detect VPN " 11
}

# =============================================================================
#  Port forwarding chains (shared by the build, quick update and keeper)
# =============================================================================
chains_exist() { iptables -t nat -S "$CHAIN_DNAT" >/dev/null 2>&1; }

active_ports() {
    iptables -t nat -S "$CHAIN_DNAT" 2>/dev/null | grep DNAT \
        | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | sort -un | xargs
}
sorted_ports() { tr ' ' '\n' <<<"$1" | grep -v '^$' | sort -un | xargs; }

fill_portfwd() {  # $1=ports (empty = clear)  $2=tcp|udp|both  $3=fixed client port (optional)
    local port pr dest
    local -a protos
    case $2 in
        udp)  protos=(udp) ;;
        both) protos=(tcp udp) ;;
        *)    protos=(tcp) ;;
    esac
    iptables -t nat -F "$CHAIN_DNAT"
    iptables -F "$CHAIN_FWD"
    for port in $1; do
        dest=${3:-$port}
        for pr in "${protos[@]}"; do
            iptables -t nat -A "$CHAIN_DNAT" -p "$pr" --dport "$port" \
                -j DNAT --to-destination "$CLIENT_IP:$dest"
            iptables -A "$CHAIN_FWD" -p "$pr" -d "$CLIENT_IP" --dport "$dest" \
                -m conntrack --ctstate NEW -j ACCEPT
        done
    done
}

# =============================================================================
#  NAT-PMP keeper (Proton VPN) - runs as a systemd service
# =============================================================================
keeper_state() {  # $1=state $2=port $3=iface $4=message
    mkdir -p "$STATE_DIR"
    printf 'K_STATE=%q\nK_PORT=%q\nK_IFACE=%q\nK_UPDATED=%q\nK_MSG=%q\n' \
        "$1" "$2" "$3" "$(date +%s)" "$4" >"$STATE_FILE.tmp"
    mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}
read_state() {
    K_STATE=""; K_PORT=""; K_IFACE=""; K_UPDATED=""; K_MSG=""
    if [[ -r $STATE_FILE ]]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"
    fi
}
state_age() {
    if [[ -z $K_UPDATED ]]; then echo "never"; else echo "$(( $(date +%s) - K_UPDATED )) s ago"; fi
}

first_up_vpn() {
    local v
    for v in "${VPN_IFS[@]}"; do
        if iface_exists "$v" && [[ -n $(if_ipv4 "$v") ]]; then echo "$v"; return 0; fi
    done
    return 1
}

natpmp_map() {  # renews the UDP + TCP lease, prints the public port
    local out port
    timeout 10 natpmpc -a 1 0 udp 60 -g "$NATPMP_GW" >/dev/null 2>&1 || return 1
    out=$(timeout 10 natpmpc -a 1 0 tcp 60 -g "$NATPMP_GW" 2>&1) || return 1
    port=$(grep -oE 'Mapped public port [0-9]+' <<<"$out" | awk '{print $4}' | head -n1)
    [[ -n $port ]] || return 1
    echo "$port"
}

run_hook() {
    [[ -n $PORT_HOOK ]] || return 0
    log "Running port hook with port $1"
    timeout 30 bash -c "$PORT_HOOK" hook "$1" >>"$LOG_FILE" 2>&1 || log "Port hook failed (exit $?)"
}

run_keeper() {  # background watcher: follows the active VPN + keeps the Proton port alive
    local cur="" port iface fails=0 rc target tprov tif last_renew=-999
    log "Watcher started (pid $$)"
    trap 'log "Watcher stopped"; keeper_state stopped "" "" "service stopped"; exit 0' TERM INT
    while true; do
        load_config
        build_vpn_ifs

        # 1) Another VPN came online? Reconfigure and rebuild (only if the gateway is in use)
        if [[ $AUTO_FOLLOW == yes ]] && chains_exist && target=$(auto_target); then
            IFS='|' read -r tprov tif <<<"$target"
            if needs_switch "$tprov" "$tif" && stable_target "$target"; then
                log "Auto-follow evidence: egress=$(egress_iface) tunnels=[$(detect_tunnels | tr '\n' ' ')]"
                apply_switch "$tprov" "$tif"
                if apply_rules >/dev/null 2>&1; then
                    sync_saved_rules
                    log "Auto-follow: gateway rebuilt for $(provider_label "$tprov") on $tif"
                else
                    log "Auto-follow: rebuild FAILED at $(cat "$FAIL_FILE" 2>/dev/null)"
                fi
                cur=""; fails=0; last_renew=-999
                continue
            fi
        fi

        if [[ $PORT_MODE != natpmp ]]; then
            if iface=$(first_up_vpn); then
                keeper_state idle "" "$iface" "watching - $(provider_label "$PROVIDER") up, static ports"
            else
                keeper_state idle "" "" "watching - no VPN tunnel up"
            fi
            nap 10; continue
        fi
        if ! chains_exist; then
            keeper_state waiting "" "" "gateway not built yet"; nap 30; continue
        fi

        # 2) Proton: keep the NAT-PMP lease alive and follow port changes
        if ! iface=$(first_up_vpn); then
            if [[ -n $cur ]]; then
                log "Tunnel down - closing port $cur"
                ( set -e; fill_portfwd "" both "" ) >>"$LOG_FILE" 2>&1
                cur=""
            fi
            last_renew=-999
            keeper_state down "" "" "VPN tunnel is down"; nap 10; continue
        fi
        if (( SECONDS - last_renew < 40 )) && active_ports | grep -qw "${cur:-x}"; then
            nap 10; continue               # lease still fresh - just keep watching
        fi
        if ! port=$(natpmp_map); then
            fails=$((fails + 1))
            if (( fails == 1 || fails % 20 == 0 )); then log "NAT-PMP request failed on $iface (attempt $fails)"; fi
            keeper_state error "$cur" "$iface" "NAT-PMP not answering (paid plan + P2P server needed)"
            nap $(( fails < 5 ? 15 : 60 )); continue
        fi
        fails=0
        last_renew=$SECONDS
        # Apply when the port changed, or when a rebuild wiped our rules
        if [[ $port != "$cur" ]] || ! active_ports | grep -qw "$port"; then
            ( set -e; fill_portfwd "$port" both "$LOCAL_PORT" ) >>"$LOG_FILE" 2>&1
            rc=$?
            if (( rc == 0 )); then
                if [[ $port != "$cur" ]]; then
                    log "Port changed: ${cur:-none} -> $port on $iface (to $CLIENT_IP:${LOCAL_PORT:-$port})"
                    run_hook "$port"
                fi
                cur=$port
            else
                log "Failed to apply rules for port $port"
            fi
        fi
        keeper_state active "$cur" "$iface" "lease renewed"
        nap 10
    done
}

install_keeper() {
    local self
    self=$(readlink -f "$0")
    if [[ $self != "$INSTALL_PATH" ]]; then install -m 755 "$self" "$INSTALL_PATH"; fi
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=VPN Gateway - VPN watcher and NAT-PMP port keeper
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH --keeper
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"
}

remove_keeper() {
    if [[ -f $SERVICE_FILE ]]; then
        systemctl disable --now "$SERVICE" || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
    rm -f "$STATE_FILE"
}

# =============================================================================
#  Build steps - each runs in a subshell with set -e, so any failing command
#  stops the step and is reported. A failed build leaves FORWARD on DROP
#  (fail-closed: nothing leaks).
# =============================================================================
STEP_FUNCS=(step_sysctl step_flush step_policies step_guard step_forward
            step_nat step_portfwd step_killswitch step_extras step_keeper)
STEP_NAMES=("Enabling IP forwarding" "Flushing old rules" "Setting default policies"
            "Shielding gateway from VPN side" "Adding VPN forwarding rules"
            "Adding NAT masquerade" "Setting up port forwarding"
            "Arming kill switch" "IPv6 block + MSS clamp" "VPN watcher service")

step_sysctl() {
    rm -f "$OLD_SYSCTL_FILE"
    {
        echo "# Written by vpn-gateway.sh v$VERSION"
        echo "net.ipv4.ip_forward = 1"
        # No ICMP redirects: when the tunnel drops they would tell the client
        # to bypass this gateway and talk to the router directly (= leak).
        echo "net.ipv4.conf.all.send_redirects = 0"
        echo "net.ipv4.conf.default.send_redirects = 0"
        echo "net/ipv4/conf/${LAN_IF}/send_redirects = 0"
        if [[ $BLOCK_IPV6 == yes ]]; then echo "net.ipv6.conf.all.forwarding = 0"; fi
    } >"$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE"
}

step_flush() {
    local t
    for t in filter nat mangle; do
        iptables -t "$t" -F
        iptables -t "$t" -X
    done
}

step_policies() {
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD DROP
}

step_guard() {
    # Nothing on the VPN side may open new connections to the gateway itself
    local v
    for v in "${VPN_IFS[@]}"; do
        iptables -A INPUT -i "$v" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -i "$v" -m comment --comment "vpngw-guard" -j DROP
    done
}

step_forward() {
    local v
    for v in "${VPN_IFS[@]}"; do
        iptables -A FORWARD -i "$LAN_IF" -o "$v" -j ACCEPT
        iptables -A FORWARD -i "$v" -o "$LAN_IF" \
            -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    done
}

step_nat() {
    local v
    for v in "${VPN_IFS[@]}"; do
        iptables -t nat -A POSTROUTING -o "$v" -j MASQUERADE
    done
}

step_portfwd() {
    local v
    iptables -t nat -N "$CHAIN_DNAT"
    iptables -N "$CHAIN_FWD"
    for v in "${VPN_IFS[@]}"; do
        iptables -t nat -A PREROUTING -i "$v" -j "$CHAIN_DNAT"
        iptables -A FORWARD -i "$v" -o "$LAN_IF" -j "$CHAIN_FWD"
    done
    # Static ports go in now; in NAT-PMP mode the keeper fills the chains
    if [[ $PORT_MODE == static && -n $PORTS ]]; then
        fill_portfwd "$PORTS" "$PROTO" ""
    fi
}

step_killswitch() {
    # Anything from the LAN that did not match a VPN rule above dies here
    iptables -A FORWARD -i "$LAN_IF" -m comment --comment "vpngw-killswitch" -j DROP
}

step_extras() {
    local v
    if [[ $BLOCK_IPV6 == yes ]]; then
        ip6tables -F FORWARD
        ip6tables -P FORWARD DROP
    fi
    if [[ $MSS_CLAMP == yes ]]; then
        for v in "${VPN_IFS[@]}"; do
            iptables -t mangle -A FORWARD -o "$v" -p tcp --tcp-flags SYN,RST SYN \
                -j TCPMSS --clamp-mss-to-pmtu
        done
    fi
}

step_keeper() {
    if [[ $PORT_MODE == natpmp ]]; then ensure_pkg natpmpc natpmpc; fi
    (( IN_SERVICE )) && return 0          # the watcher is rebuilding - don't restart itself
    if [[ $PORT_MODE == natpmp || $AUTO_FOLLOW == yes ]]; then
        install_keeper
    else
        remove_keeper
    fi
}

# =============================================================================
#  Persistence
# =============================================================================
install_persistent_pkg() {
    # Pre-answer the debconf questions so apt doesn't pop up its own dialog
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
    apt-get -o DPkg::Lock::Timeout=180 update -qq &&
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq iptables-persistent
}

save_persistent() {
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        if dpkg -s ufw 2>/dev/null | grep -q "Status: install ok installed"; then
            ask "To keep rules after a reboot, the package 'iptables-persistent'\nmust be installed.\n\nOn Ubuntu this REMOVES UFW (the two cannot be installed together).\nThis gateway manages the firewall itself, so UFW isn't needed.\n\nContinue?" " Install iptables-persistent " 15 || return 1
        fi
        log "Installing iptables-persistent"
        if ! run_gauge " Installing " "Installing iptables-persistent...\nThis can take a minute (apt update + install)." install_persistent_pkg; then
            msg "Installing iptables-persistent failed.\n\nOften another update is running (apt lock). Wait a moment and\ntry again via 'Save rules persistently'.\n\nLast log lines:\n$(tail -n 5 "$LOG_FILE")" " Error " 18
            return 1
        fi
    fi
    if run_gauge " Saving " "Saving rules to /etc/iptables/..." netfilter-persistent save; then
        log "Rules saved persistently"
        return 0
    fi
    msg "Saving rules failed.\nSee $LOG_FILE" " Error " 9
    return 1
}

fwd_counts() {  # prints "<packets via VPN> <packets killed>" from LAN in FORWARD
    local pk tgt in out rest via=0 killed=0 v
    build_vpn_ifs
    while read -r pk _ tgt _ _ in out rest; do
        [[ $pk =~ ^[0-9]+$ ]] || continue
        [[ $in == "$LAN_IF" ]] || continue
        if [[ $tgt == DROP && $rest == *vpngw-killswitch* ]]; then
            killed=$(( killed + pk ))
        elif [[ $tgt == ACCEPT ]]; then
            for v in "${VPN_IFS[@]}"; do
                if [[ $out == "$v" ]]; then via=$(( via + pk )); fi
            done
        fi
    done < <(iptables -L FORWARD -v -n -x 2>/dev/null)
    echo "$via $killed"
}

apply_rules() {  # serialised wrapper - menu and watcher never rebuild at the same time
    local lockfd rc
    exec {lockfd}>"$LOCK_FILE"
    flock -w 120 "$lockfd" || true
    apply_rules_now
    rc=$?
    exec {lockfd}>&-
    return "$rc"
}

apply_rules_now() {  # prints a live step list; returns 1 on the first failing step
    local total=${#STEP_FUNCS[@]} i rc
    : >"$FAIL_FILE"
    build_vpn_ifs
    log "=== Applying gateway rules ($(provider_label "$PROVIDER"), $(mode_label)) ==="
    for i in "${!STEP_FUNCS[@]}"; do
        printf '  %s[%2d/%d]%s %s%-34s%s ' "$GRY" $((i + 1)) "$total" "$R" "$WHT" "${STEP_NAMES[$i]}" "$R"
        log "Step $((i + 1))/$total: ${STEP_NAMES[$i]}"
        ( set -e; "${STEP_FUNCS[$i]}" ) >>"$LOG_FILE" 2>&1
        rc=$?
        if (( rc != 0 )); then
            echo "${STEP_NAMES[$i]}" >"$FAIL_FILE"
            log "FAILED: ${STEP_NAMES[$i]} (exit $rc)"
            printf '%s✘ FAILED%s\n' "$RED" "$R"
            return 1
        fi
        printf '%s✔ OK%s\n' "$GRN" "$R"
    done
    log "=== Gateway rules applied ==="
}

# =============================================================================
#  Actions
# =============================================================================
wait_for_proton_port() {  # after a build: give the keeper up to 15 s (sets PORTINFO)
    local n spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    for n in {1..60}; do
        read_state
        if [[ $K_STATE == active && -n $K_PORT ]]; then break; fi
        printf '\r  %s%s%s Asking Proton VPN for a forwarded port... %s(%ds)%s\033[K' \
            "$CYN" "${spin:n%10:1}" "$R" "$GRY" $(( n / 4 )) "$R" >"$TTY"
        sleep 0.25
    done
    read_state
    if [[ $K_STATE == active && -n $K_PORT ]]; then
        printf '\r  %s✔%s Proton port received: %s%s%s\033[K\n' "$GRN" "$R" "$CYN" "$K_PORT" "$R" >"$TTY"
        PORTINFO="Proton port: $K_PORT -> $CLIENT_IP:${LOCAL_PORT:-$K_PORT}\n"
    else
        printf '\r  %s!%s No Proton port yet\033[K\n' "$YLW" "$R" >"$TTY"
        PORTINFO="No Proton port yet (${K_MSG:-keeper starting}).\nCheck it under 'Proton port & keep-alive'.\n"
    fi
}

build_gateway() {
    local errs warn="" summary v portinfo=""
    banner
    errs=$(check_settings)
    if [[ -n $errs ]]; then
        msg "Please fix these settings first:\n\n$errs" "Settings incomplete"
        return
    fi
    build_vpn_ifs
    for v in "${VPN_IFS[@]}"; do
        iface_exists "$v" || warn+="- $v is DOWN: LAN clients stay offline until the tunnel is up (kill switch).\n"
    done
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        warn+="- UFW is active: its rules will be wiped. Consider 'ufw disable'.\n"
    fi
    if command -v docker >/dev/null; then
        warn+="- Docker is installed: its iptables rules will be wiped (restart docker after).\n"
    fi

    summary="Provider       : $(provider_label "$PROVIDER")\n"
    summary+="LAN interface  : $LAN_IF ($(lan_ip))\n"
    summary+="VPN interfaces : ${VPN_IFS[*]}\n"
    summary+="Client IP      : $CLIENT_IP\n"
    if [[ $PORT_MODE == natpmp ]]; then
        summary+="Port forward   : dynamic NAT-PMP -> $CLIENT_IP:${LOCAL_PORT:-<same port>}\n"
        summary+="                 (installs the keep-alive service)\n"
    elif [[ -n $PORTS ]]; then
        summary+="Port forward   : $PORTS ($PROTO)\n"
    else
        summary+="Port forward   : OFF\n"
    fi
    summary+="Kill switch    : LAN clients only (this machine's own traffic is NOT blocked)\n"
    summary+="IPv6 block     : $BLOCK_IPV6     MSS clamp: $MSS_CLAMP\n"
    if [[ -n $warn ]]; then summary+="\nWarnings:\n$warn"; fi
    summary+="\nAll existing iptables rules will be replaced. Continue?"
    ask "$summary" "Build gateway" || return

    title "$CYN" "Building gateway" >"$TTY"
    echo >"$TTY"
    if ! apply_rules >"$TTY"; then
        msg "Step failed: $(cat "$FAIL_FILE")\n\nForwarding is blocked (fail-closed), so nothing leaks.\n\nLast log lines:\n$(tail -n 6 "$LOG_FILE")" "Build failed"
        return
    fi
    DIRTY=0
    if [[ $PORT_MODE == natpmp ]]; then wait_for_proton_port; portinfo=$PORTINFO; fi

    if ask "Gateway is UP and the kill switch is ARMED for your LAN clients.\n${portinfo}\nSave the rules so they survive a reboot?" "Done"; then
        if save_persistent; then
            if ask "Rules saved.\n\nReboot now to verify everything comes back up?" "Reboot"; then
                log "Rebooting on user request"
                printf '\033[0m\n  Rebooting now...\n'; reboot; exit 0
            fi
        fi
    else
        msg "Rules are active but NOT saved - they disappear on reboot.\nYou can save them later from the main menu." "Not saved"
    fi
}

change_ports() {  # static mode: quick update without a full rebuild
    local new old_live rc
    banner
    old_live=$(active_ports)
    new=$(input_box "Change forwarded ports" "Enter the port(s) from your VPN provider's portal, separated by spaces or commas.\n\nIn settings : ${PORTS:-none}\nActive now  : ${old_live:-none}" "$PORTS")
    new=$(echo "$new" | tr ',' ' ' | xargs)
    if ! valid_ports "$new"; then
        msg "Ports must be numbers between 1 and 65535." "Error"
        return
    fi
    if [[ $(sorted_ports "$new") == "$(sorted_ports "$PORTS")" && $(sorted_ports "$new") == "$old_live" ]]; then
        msg "Those ports are already active - nothing to change." "No change"
        return
    fi
    ask "Old ports : ${old_live:-none}\nNew ports : $new  ($PROTO -> $CLIENT_IP)\n\nThe old ports are closed and the new ones opened.\nThe kill switch stays ARMED. Continue?" "Confirm port change" || return

    PORTS=$new
    save_config
    log "Ports changed: '${old_live:-none}' -> '$new'"
    if ! chains_exist; then
        DIRTY=1
        msg "Ports saved. The gateway isn't built yet - choose 4 'Build / rebuild gateway'." "Saved"
        return
    fi
    ( set -e; fill_portfwd "$PORTS" "$PROTO" "" ) >>"$LOG_FILE" 2>&1
    rc=$?
    if (( rc != 0 )); then
        DIRTY=1
        msg "Updating the port rules FAILED.\nSee the log, or run 'Build / rebuild gateway'." "Error"
        return
    fi
    printf '\n  %s✔%s Now forwarding: %s%s%s\n' "$GRN" "$R" "$CYN" "$(active_ports)" "$R" >"$TTY"
    # Rules were saved before -> keep the saved copy in sync automatically
    if [[ -f /etc/iptables/rules.v4 ]]; then
        save_persistent && msg "Saved - survives reboot.\n\nRemember to change the port in the service on $CLIENT_IP\n(and its own firewall) if it listens on the old one." "Ports updated"
    elif ask "Save the rules so they survive a reboot?" "Ports updated"; then
        save_persistent
    fi
}

proton_port_menu() {
    local val svc stcol
    while true; do
        read_state
        svc=$(systemctl is-active "$SERVICE" 2>/dev/null)
        [[ -f $SERVICE_FILE ]] || svc="not installed"
        case $K_STATE in active) stcol=$GRN ;; error|down) stcol=$RED ;; *) stcol=$YLW ;; esac
        banner
        title "$MAG" "Proton port & keep-alive" >"$TTY"
        {
            printf '\n'
            printf '   %s%-16s%s %s\n' "$GRY" "KEEPER SERVICE" "$R" "$([[ $svc == active ]] && echo "${GRN}● active${R}" || echo "${RED}● ${svc:-unknown}${R}")"
            printf '   %s%-16s%s %s%s%s %s%s%s\n' "$GRY" "STATE" "$R" "$stcol" "${K_STATE:-unknown}" "$R" "$GRY" "${K_MSG:-no data yet}" "$R"
            printf '   %s%-16s%s %s\n' "$GRY" "TUNNEL" "$R" "${K_IFACE:--}"
            printf '   %s%-16s%s %s%s%s\n' "$GRY" "PUBLIC PORT" "$R" "$CYN" "${K_PORT:-none}" "$R"
            printf '   %s%-16s%s %s:%s\n' "$GRY" "FORWARDED TO" "$R" "$CLIENT_IP" "${LOCAL_PORT:-${K_PORT:-?}}"
            printf '   %s%-16s%s %s\n' "$GRY" "LAST RENEWAL" "$R" "$(state_age)"
            printf '\n   %sLease renewed every 45 s. Reconnect / new server = new port, followed automatically.%s\n\n' "$GRY" "$R"
        } >"$TTY"
        hr
        ui_menu "Back" \
            "1" "Refresh view" \
            "2" "Request port now (restart keeper)" \
            "3" "$(kv "Client port" "${LOCAL_PORT:-same as public port}")" \
            "4" "$(kv "On-change hook" "${PORT_HOOK:-(none)}")" \
            "5" "Show keeper log" || return 0
        case $MENU_CHOICE in
            1) ;;
            2) if [[ ! -f $SERVICE_FILE ]]; then
                   msg "The keeper isn't installed yet.\nChoose 'Build / rebuild gateway' first." "Keeper"
               else
                   systemctl restart "$SERVICE"
                   run_gauge "NAT-PMP" "Requesting a port from Proton VPN..." sleep 6
               fi ;;
            3) val=$(input_box "Client port" "Leave EMPTY to forward to the same port number on the client.\nThe app on the client must then follow the port (use the hook).\n\nOr enter a FIXED port (e.g. 8080): every new Proton port is\nmapped to that port on $CLIENT_IP. Ideal for web servers." "$LOCAL_PORT")
               val=$(xargs <<<"$val")
               if [[ -n $val ]] && { ! valid_ports "$val" || [[ $val == *" "* ]]; }; then msg "Enter one port between 1 and 65535, or leave empty." "Error"; continue; fi
               LOCAL_PORT=$val; save_config
               if [[ -f $SERVICE_FILE ]]; then systemctl restart "$SERVICE"; fi ;;
            4) val=$(input_box "On-change hook" "Command run as root every time the Proton port changes.\nThe new port is passed as \$1.\n\nExample: /usr/local/bin/set-qbit-port.sh\nLeave empty for no hook." "$PORT_HOOK")
               PORT_HOOK=$val; save_config
               log "Port hook set to: ${PORT_HOOK:-(none)}" ;;
            5) local tmp; tmp=$(mktemp)
               grep -E 'Keeper|Port changed|NAT-PMP|hook|Tunnel down' "$LOG_FILE" 2>/dev/null | tail -n 200 >"$tmp"
               [[ -s $tmp ]] || echo "(no keeper events yet)" >"$tmp"
               show_file "Keeper log" "$tmp"; rm -f "$tmp" ;;
        esac
    done
}

ports_menu() {
    if [[ $PORT_MODE == natpmp ]]; then proton_port_menu; else change_ports; fi
}

show_status() {
    local out v addr pub wanted live svc
    banner
    build_vpn_ifs
    out="Provider       : $(provider_label "$PROVIDER")   (port forward: $(mode_label))\n"
    out+="IP forwarding  : $([[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) == 1 ]] && echo ON || echo OFF)\n"
    out+="Kill switch    : $(killswitch_state)  (LAN clients only - not this machine)\n"
    if [[ -f /etc/iptables/rules.v4 ]]; then
        out+="Saved rules    : yes ($(date -r /etc/iptables/rules.v4 '+%F %T'))\n\n"
    else
        out+="Saved rules    : NO\n\n"
    fi

    printf '\n  %sChecking tunnels...%s' "$GRY" "$R" >"$TTY"
    for v in "${VPN_IFS[@]}"; do
        if iface_exists "$v"; then
            addr=$(if_ipv4 "$v")
            out+="$v : UP   ${addr:-no IPv4}\n"
            if command -v curl >/dev/null; then
                pub=$(curl -s --max-time 6 --interface "$v" https://api.ipify.org || true)
                out+="   public IP via tunnel: ${pub:-unreachable}\n"
            fi
        else
            out+="$v : DOWN\n"
        fi
    done
    printf '\r\033[K' >"$TTY"
    command -v curl >/dev/null || out+="(install curl to see the tunnel's public IP)\n"

    out+="\nClient $CLIENT_IP : $(ping -c1 -W1 "$CLIENT_IP" >/dev/null 2>&1 && echo reachable || echo "NO reply")\n"
    live=$(active_ports)
    if [[ $PORT_MODE == natpmp ]]; then
        read_state
        svc=$(systemctl is-active "$SERVICE" 2>/dev/null)
        [[ -f $SERVICE_FILE ]] || svc="not installed"
        out+="Keeper service : ${svc:-unknown}  (${K_STATE:-?}: ${K_MSG:-no data})\n"
        out+="Proton port    : ${K_PORT:-none} -> $CLIENT_IP:${LOCAL_PORT:-${K_PORT:-?}}\n"
        out+="Last renewal   : $(state_age)\n"
        out+="Active rules   : ${live:-none}\n"
    else
        wanted=$(sorted_ports "$PORTS")
        out+="Ports in settings : ${wanted:-none} ($PROTO)\n"
        out+="Ports active now  : ${live:-none}\n"
        if [[ $wanted != "$live" ]]; then
            out+="\n!! Settings and active rules differ - use 3 'Forwarded ports'\n   or 4 'Build / rebuild gateway' to apply.\n"
        fi
    fi
    msg "$out" "Status & tunnel check"
}

view_rules() {
    local tmp
    tmp=$(mktemp)
    {
        echo "===== filter ====="; iptables -L -v -n --line-numbers; echo
        echo "===== nat ====="; iptables -t nat -L -v -n --line-numbers; echo
        echo "===== mangle (FORWARD) ====="; iptables -t mangle -L FORWARD -v -n; echo
        echo "===== ip6tables FORWARD ====="; ip6tables -L FORWARD -v -n
    } >"$tmp" 2>&1
    show_file "Active rules" "$tmp"
    rm -f "$tmp"
}

view_log() {
    local tmp
    tmp=$(mktemp)
    tail -n 300 "$LOG_FILE" >"$tmp" 2>/dev/null
    [[ -s $tmp ]] || echo "(log is empty)" >"$tmp"
    show_file "Log" "$tmp"
    rm -f "$tmp"
}

remove_gateway() {
    local t
    banner
    ask "This removes all gateway rules and the kill switch:\n\n- flushes iptables\n- sets all policies to ACCEPT\n- turns IP forwarding OFF\n- stops and removes the port keep-alive service\n\nLAN clients using this host as gateway lose internet. Continue?" "Remove gateway" || return
    echo >"$TTY"
    run_gauge "Remove" "Removing gateway rules..." remove_all_rules
    log "Gateway rules removed"
    if [[ -f /etc/iptables/rules.v4 ]] && ask "Saved rules still exist and would come back at boot.\n\nSave the cleared state now?" "Saved rules"; then
        save_persistent && msg "Cleared state saved." "Done"
    else
        msg "Gateway rules removed." "Done"
    fi
}

remove_all_rules() {
    local t
    remove_keeper
    for t in filter nat mangle; do iptables -t "$t" -F; iptables -t "$t" -X; done
    iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT; iptables -P FORWARD ACCEPT
    ip6tables -P FORWARD ACCEPT
    rm -f "$SYSCTL_FILE" "$OLD_SYSCTL_FILE"
    # v1 of the old script wrote ip_forward into sysctl.conf - disable it too
    sed -i 's/^net.ipv4.ip_forward=1/#net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=0
}

killswitch_test() {
    local up a_via a_kill b_via b_kill d_via d_kill verdict n
    banner
    if [[ $(killswitch_state) != ARMED ]]; then
        msg "The kill switch is NOT active - build the gateway first (option 4)." "Kill switch test"
        return
    fi
    build_vpn_ifs
    if up=$(first_up_vpn); then up="UP ($up)"; else up="DOWN"; fi
    ask "VPN tunnel is currently: $up\n\nThe kill switch protects LAN CLIENTS routed through this gateway.\nThis machine's own browsing is NOT blocked - so test on the client.\n\n1. To test the kill switch: disconnect the VPN first.\n2. Answer y, then browse a few websites ON THE CLIENT ($CLIENT_IP).\n\nStart the 20 second test?" "Kill switch test" || return

    read -r a_via a_kill < <(fwd_counts)
    echo >"$TTY"
    for n in {20..1}; do
        printf '\r  %s⏱%s  Browse on the client %s%s%s now... %s%2d s left%s\033[K' \
            "$CYN" "$R" "$WHT" "$CLIENT_IP" "$R" "$YLW" "$n" "$R" >"$TTY"
        sleep 1
    done
    printf '\r  %s✔%s Test finished\033[K\n' "$GRN" "$R" >"$TTY"
    read -r b_via b_kill < <(fwd_counts)
    d_via=$(( b_via - a_via )); d_kill=$(( b_kill - a_kill ))
    if up=$(first_up_vpn); then up="UP"; else up="DOWN"; fi

    if (( d_via == 0 && d_kill == 0 )); then
        verdict="NO traffic from the LAN reached this gateway.\n\nIf the client could still browse, it is NOT using this gateway:\n- check the client's default gateway is $(lan_ip)\n- IPv6: the client probably gets IPv6 straight from your router\n  and bypasses the gateway completely - disable IPv6 on the client\n- testing on this machine itself? The kill switch protects LAN\n  clients, not the gateway's own browsing."
    elif [[ $up == DOWN ]] && (( d_kill > 0 )); then
        verdict="KILL SWITCH WORKS: $d_kill packets from the LAN were blocked.\n\nIf the client could still open websites, part of its traffic\ngoes around the gateway - almost always IPv6 from the router.\nDisable IPv6 on the client (or the router) to close that leak."
    elif [[ $up == UP ]] && (( d_via > 0 )); then
        verdict="Traffic is flowing through the VPN ($d_via packets).\n\nTo test the kill switch, disconnect the VPN and run the test again."
    else
        verdict="Via VPN: $d_via packets   Blocked: $d_kill packets\nTunnel state changed during the test - run it again."
    fi
    log "Kill switch test: tunnel $up, via VPN $d_via, blocked $d_kill"
    msg "Tunnel: $up   |   via VPN: $d_via pkts   |   blocked: $d_kill pkts\n\n$verdict" "Kill switch test - result"
}

# =============================================================================
#  Menus
# =============================================================================
pick_interface() {  # $1=title $2=current - prints chosen interface
    local p ifc state addr items=()
    for p in /sys/class/net/*; do
        ifc=${p##*/}
        [[ $ifc == lo ]] && continue
        state=$(cat "$p/operstate" 2>/dev/null || echo "?")
        addr=$(if_ipv4 "$ifc")
        items+=("$ifc" "$(printf '%-8s %s' "$state" "${addr:-no IPv4}")")
    done
    ui_choose "$1" "" "$2" "${items[@]}"
}

settings_menu() {
    local val ok v cur_mode
    local -a items
    while true; do
        banner
        title "$MAG" "Settings" >"$TTY"
        printf '   %sChanges are saved at once - rebuild the gateway to apply them.%s\n' "$GRY" "$R" >"$TTY"
        items=(
            "1" "$(kv "LAN interface" "$LAN_IF")"
            "2" "$(kv "VPN provider" "$(provider_label "$PROVIDER")")"
            "3" "$(kv "VPN interface(s)" "${VPN_IFACES:-(none)}")"
            "4" "$(kv "Client IP" "$CLIENT_IP")"
            "5" "$(kv "Port forwarding" "$(mode_label)")"
        )
        if [[ $PORT_MODE == natpmp ]]; then
            items+=("6" "$(kv "Client port" "${LOCAL_PORT:-same as public port}")"
                    "7" "$(kv "On-change hook" "${PORT_HOOK:-(none)}")"
                    "8" "$(kv "NAT-PMP gateway" "$NATPMP_GW")")
        else
            items+=("6" "$(kv "Forwarded ports" "${PORTS:-(none)}")"
                    "7" "$(kv "Protocol" "$PROTO")")
        fi
        items+=("I" "$(kv "IPv6 block (toggle)" "$BLOCK_IPV6")"
                "M" "$(kv "MSS clamp (toggle)" "$MSS_CLAMP")"
                "A" "$(kv "Auto-follow VPN (toggle)" "$AUTO_FOLLOW")")

        ui_menu "Back" "${items[@]}" || return 0

        case $MENU_CHOICE in
            1)  LAN_IF=$(pick_interface "LAN interface" "$LAN_IF") ;;
            2)  PROVIDER=$(ui_choose "VPN provider" "Tip: 'Detect VPN provider' in the main menu does this for you." "$PROVIDER" \
                    "torguard" "static ports" \
                    "proton"   "dynamic NAT-PMP port + keep-alive" \
                    "generic"  "any tunnel, static ports")
                if [[ $PROVIDER == proton ]]; then PORT_MODE="natpmp"; else PORT_MODE="static"; fi ;;
            3)  val=$(input_box "VPN interface(s)" "Tunnel interface name(s), separated by spaces.\n\nTunnels found right now : $(detect_tunnels | cut -d'|' -f1 | xargs)\nAll interfaces          : $(ls /sys/class/net | xargs)" "$VPN_IFACES")
                val=$(xargs <<<"$val"); ok=1
                for v in $val; do valid_ifname "$v" || ok=0; done
                if [[ -z $val || $ok == 0 ]]; then msg "Enter at least one valid interface name." "Error"; continue; fi
                VPN_IFACES=$val ;;
            4)  val=$(input_box "Client IP" "IP of the LAN client that receives the forwarded port(s).\nIts default gateway must be this server ($(lan_ip))." "$CLIENT_IP")
                if ! valid_ip "$val"; then msg "'$val' is NOT a valid IPv4 address." "Error"; continue; fi
                CLIENT_IP=$val ;;
            5)  cur_mode=$PORT_MODE
                if [[ $PORT_MODE == static && -z $PORTS ]]; then cur_mode="off"; fi
                val=$(ui_choose "Port forwarding" "How should ports be forwarded to the client?" "$cur_mode" \
                    "static" "fixed ports (TorGuard, generic)" \
                    "natpmp" "dynamic NAT-PMP with keep-alive (Proton)" \
                    "off"    "no port forwarding")
                case $val in
                    natpmp) PORT_MODE="natpmp" ;;
                    off)    PORT_MODE="static"; PORTS="" ;;
                    static) PORT_MODE="static"
                            if [[ -z $PORTS ]]; then
                                val=$(input_box "Forwarded ports" "Ports from your provider's portal, separated by spaces or commas." "")
                                val=$(echo "$val" | tr ',' ' ' | xargs)
                                if ! valid_ports "$val"; then msg "Ports must be numbers between 1 and 65535." "Error"; continue; fi
                                PORTS=$val
                            fi ;;
                esac ;;
            6)  if [[ $PORT_MODE == natpmp ]]; then
                    val=$(input_box "Client port" "Leave EMPTY to forward to the same port number on the client,\nor enter one FIXED port (e.g. 8080) that every Proton port maps to." "$LOCAL_PORT")
                    val=$(xargs <<<"$val")
                    if [[ -n $val ]] && { ! valid_ports "$val" || [[ $val == *" "* ]]; }; then msg "Enter one port between 1 and 65535, or leave empty." "Error"; continue; fi
                    LOCAL_PORT=$val
                else
                    val=$(input_box "Forwarded ports" "Ports from your provider's portal, separated by spaces or commas.\nLeave empty to turn port forwarding OFF." "$PORTS")
                    val=$(echo "$val" | tr ',' ' ' | xargs)
                    if [[ -n $val ]] && ! valid_ports "$val"; then msg "Ports must be numbers between 1 and 65535." "Error"; continue; fi
                    PORTS=$val
                fi ;;
            7)  if [[ $PORT_MODE == natpmp ]]; then
                    PORT_HOOK=$(input_box "On-change hook" "Command run as root every time the Proton port changes.\nThe new port is passed as \$1. Leave empty for no hook." "$PORT_HOOK")
                else
                    PROTO=$(ui_choose "Protocol" "Protocol for the forwarded ports:" "$PROTO" \
                        "tcp" "TCP only" "udp" "UDP only" "both" "TCP and UDP")
                fi ;;
            8)  [[ $PORT_MODE == natpmp ]] || continue
                val=$(input_box "NAT-PMP gateway" "Proton VPN uses 10.2.0.1. Only change this if you know why." "$NATPMP_GW")
                if ! valid_ip "$val"; then msg "'$val' is NOT a valid IPv4 address." "Error"; continue; fi
                NATPMP_GW=$val ;;
            I)  if [[ $BLOCK_IPV6 == yes ]]; then BLOCK_IPV6="no"; else BLOCK_IPV6="yes"; fi ;;
            M)  if [[ $MSS_CLAMP == yes ]]; then MSS_CLAMP="no"; else MSS_CLAMP="yes"; fi ;;
            A)  if [[ $AUTO_FOLLOW == yes ]]; then AUTO_FOLLOW="no"; else AUTO_FOLLOW="yes"; fi ;;
        esac
        save_config
        DIRTY=1
    done
}

header_line() {  # one-line summary (used on exit)
    local up port
    build_vpn_ifs
    if up=$(first_up_vpn); then up="$up up"; else up="DOWN"; fi
    if [[ $PORT_MODE == natpmp ]]; then
        read_state; port=${K_PORT:-waiting}
    else
        port=$(active_ports)
        if [[ -z $port && -n $PORTS ]]; then port="$PORTS (not active)"; fi
        port=${port:-none}
    fi
    echo "VPN: $(provider_label "$PROVIDER") ($up)  |  Port: $port  |  Kill switch: $(killswitch_state)"
}

gateway_note() {  # explains why the gateway isn't running, if it isn't
    if chains_exist; then
        return 0
    elif iptables -S FORWARD 2>/dev/null | grep -q 'tg-killswitch'; then
        echo "Rules from an older script version are loaded - choose 4 to rebuild"
    else
        echo "Gateway is NOT built (no rules loaded)"
    fi
}

auto_follow_check() {  # UI: switch to whichever known VPN is online right now
    local target tprov tif was
    [[ $AUTO_FOLLOW == yes ]] || return 0
    target=$(auto_target) || return 0
    IFS='|' read -r tprov tif <<<"$target"
    needs_switch "$tprov" "$tif" || return 0
    stable_target "$target" || return 0          # confirm on the next refresh (5 s)
    log "Auto-follow evidence: egress=$(egress_iface) tunnels=[$(detect_tunnels | tr '\n' ' ')]"

    was="$(provider_label "$PROVIDER") · ${VPN_IFACES:-none}"
    banner
    title "$CYN" "VPN change detected"
    {
        printf '\n   %s%-14s%s %s%s%s on %s%s%s\n' "$GRY" "ONLINE NOW" "$R" "$GRN" "$(provider_label "$tprov")" "$R" "$CYN" "$tif" "$R"
        printf '   %s%-14s%s %s\n\n' "$GRY" "CONFIGURED" "$R" "$was"
    } >"$TTY"
    apply_switch "$tprov" "$tif"
    printf '  %s✔%s Settings switched to %s%s%s\n' "$GRN" "$R" "$WHT" "$(provider_label "$tprov")" "$R" >"$TTY"

    if ! chains_exist; then
        DIRTY=1
        msg "The gateway isn't built yet.\nChoose 4 'Build / rebuild gateway' to start it with $(provider_label "$tprov")." "Auto-detect"
        return 0
    fi
    printf '\n' >"$TTY"
    if ! apply_rules >"$TTY"; then
        msg "Rebuild FAILED at: $(cat "$FAIL_FILE")\nForwarding is blocked (fail-closed). See 8 'View log'." "Auto-detect"
        return 0
    fi
    DIRTY=0
    run_gauge "Save" "Updating saved rules..." sync_saved_rules
    if [[ $PORT_MODE == natpmp ]]; then
        wait_for_proton_port
        msg "Gateway now runs on Proton VPN ($tif).\n${PORTINFO}\nThe port is kept open in the background and followed automatically\nif you change server or the tunnel reconnects." "Switched to Proton VPN"
    else
        msg "Gateway now runs on $(provider_label "$tprov") ($tif).\nForwarded ports: ${PORTS:-none} (static - set them under 3)." "Switched to $(provider_label "$tprov")"
    fi
}

detected_line() {  # what the auto-detection sees right now
    local all target egress i kind addr prov others=""
    all=$(detect_tunnels)
    if [[ -z $all ]]; then echo "${GRY}no VPN tunnel online${R}"; return; fi
    egress=$(egress_iface)
    if target=$(auto_target); then
        IFS='|' read -r prov i <<<"$target"
        while IFS='|' read -r kind _ _ _; do [[ $kind != "$i" ]] && others+="$kind "; done <<<"$all"
        echo "${CYN}$i${R} ${GRY}→${R} ${WHT}$(provider_label "$prov")${R} ${GRY}$([[ $i == "$egress" ]] && echo "(carries traffic)")${others:+ · also present: $others}${R}"
    else
        IFS='|' read -r i kind addr prov <<<"$(grep "^${egress}|" <<<"$all" || head -n1 <<<"$all")"
        echo "${YLW}$i${R} ${GRY}($kind ${addr:-no IPv4}, $(provider_label "$prov")) - not followed automatically (use 1)${R}"
    fi
}

watcher_line() {
    if [[ $AUTO_FOLLOW != yes && $PORT_MODE != natpmp ]]; then
        echo "${GRY}off (auto-follow disabled)${R}"
    elif systemctl is-active --quiet "$SERVICE"; then
        echo "${GRN}● running${R}  ${GRY}checks every 10 s · screen refreshes every 5 s${R}"
    elif chains_exist; then
        echo "${RED}● stopped${R}  ${GRY}- choose 4 to rebuild and start it${R}"
    else
        echo "${GRY}starts when the gateway is built (4)${R}"
    fi
}

status_block() {
    local up addr vpn port ks
    build_vpn_ifs
    if up=$(first_up_vpn); then
        addr=$(if_ipv4 "$up")
        vpn="${GRN}● UP  ${R}  ${WHT}$(provider_label "$PROVIDER")${R}  ${CYN}${up}${R}  ${GRY}${addr}${R}"
    else
        vpn="${RED}● DOWN${R}  ${WHT}no tunnel up${R}  ${GRY}configured: $(provider_label "$PROVIDER") · ${VPN_IFACES:-no interface set}${R}"
    fi
    if [[ $PORT_MODE == natpmp ]]; then
        read_state
        if [[ -n $K_PORT ]]; then port="${CYN}${K_PORT}${R}  ${GRY}NAT-PMP keep-alive · ${K_STATE} · renewed $(state_age)${R}"
        else port="${YLW}waiting${R}  ${GRY}NAT-PMP · ${K_MSG:-keeper not running}${R}"; fi
    else
        port=$(active_ports)
        if [[ -n $port ]]; then port="${CYN}${port}${R}  ${GRY}static · $PROTO${R}"
        elif [[ -n $PORTS ]] && chains_exist; then port="${YLW}${PORTS}${R}  ${GRY}configured · not applied - use 3 'Forwarded ports'${R}"
        elif [[ -n $PORTS ]]; then port="${YLW}${PORTS}${R}  ${GRY}configured · active once the gateway is built${R}"
        else port="${GRY}off${R}"; fi
    fi
    if [[ $(killswitch_state) == ARMED ]]; then ks="${GRN}● ARMED${R}"; else ks="${RED}● OFF${R}  "; fi
    {
        echo
        printf '   %s%-12s%s %s\n' "$GRY" "VPN" "$R" "$vpn"
        printf '   %s%-12s%s %s\n' "$GRY" "PORT" "$R" "$port"
        printf '   %s%-12s%s %s  %sprotects LAN clients only - not this machine%s\n' "$GRY" "KILL SWITCH" "$R" "$ks" "$GRY" "$R"
        printf '   %s%-12s%s %s%s%s  %svia %s %s%s\n' "$GRY" "CLIENT" "$R" "$WHT" "$CLIENT_IP" "$R" "$GRY" "$LAN_IF" "$(lan_ip)" "$R"
        printf '   %s%-12s%s %s\n' "$GRY" "DETECTED" "$R" "$(detected_line)"
        printf '   %s%-12s%s %s\n' "$GRY" "WATCHER" "$R" "$(watcher_line)"
    } >"$TTY"
}

ensure_watcher() {  # gateway built + auto-follow/NAT-PMP -> make sure the watcher runs the current script
    [[ $AUTO_FOLLOW == yes || $PORT_MODE == natpmp ]] || return 0
    chains_exist || return 0
    if systemctl is-active --quiet "$SERVICE" && cmp -s "$(readlink -f "$0")" "$INSTALL_PATH"; then
        return 0
    fi
    banner
    echo >"$TTY"
    run_gauge "Watcher" "Starting the background VPN watcher..." install_keeper
    sleep 0.5
}

main_menu() {
    local note port_item rc
    load_config
    ensure_watcher
    while true; do
        load_config
        auto_follow_check
        banner
        status_block
        note=$(gateway_note)
        if [[ -z $note ]] && (( DIRTY )); then note="Settings changed - choose 4 to rebuild and apply them"; fi
        if [[ -n $note ]]; then printf '\n   %s⚠  %s%s\n' "$YLW" "$note" "$R" >"$TTY"; fi
        if ! chains_exist; then
            printf '   %s▶  Setup order:  %s1%s Detect → %s2%s Settings → %s3%s Ports → %s4%s Build%s\n' \
                "$GRY" "$CYN" "$GRY" "$CYN" "$GRY" "$CYN" "$GRY" "$CYN" "$GRY" "$R" >"$TTY"
        fi
        echo >"$TTY"
        hr
        if [[ $PORT_MODE == natpmp ]]; then port_item="Proton port & keep-alive"; else port_item="Forwarded ports"; fi
        printf '   %sSETUP%s\n' "$MAG" "$R" >"$TTY"
        MENU_REFRESH=5
        ui_menu "Quit" \
            "1" "Detect VPN provider" \
            "2" "Settings" \
            "3" "$port_item" \
            "4" "Build / rebuild gateway" \
            "-" "${MAG}MONITOR${R}" \
            "5" "Status & tunnel check" \
            "6" "Test kill switch" \
            "7" "View active rules" \
            "8" "View log" \
            "-" "${MAG}MAINTENANCE${R}" \
            "9" "Save rules persistently" \
            "R" "Remove gateway rules"
        rc=$?
        MENU_REFRESH=0
        if (( rc == 2 )); then continue; fi      # nothing pressed - just refresh the screen
        if (( rc == 1 )); then break; fi
        case $MENU_CHOICE in
            1) detect_vpn ;;
            2) settings_menu ;;
            3) ports_menu ;;
            4) build_gateway ;;
            5) show_status ;;
            6) killswitch_test ;;
            7) view_rules ;;
            8) view_log ;;
            9) banner; echo >"$TTY"; save_persistent && msg "Rules saved to /etc/iptables/ and restored at boot." "Saved" ;;
            R) remove_gateway ;;
        esac
    done
    printf '\033[0m\033[2J\033[H'
    set_palette cli
    printf '%sVPN Gateway%s - %s\n' "$YLW" "$R" "$(header_line)"
}

# =============================================================================
#  First-run setup: welcome, component check, install bar, validation
# =============================================================================
missing_deps() {  # prints the DEPS lines whose command is missing
    local line cmd
    for line in "${DEPS[@]}"; do
        cmd=${line%%|*}
        command -v "$cmd" >/dev/null 2>&1 || echo "$line"
    done
}

draw_bar() {  # $1=percent $2=text
    local pct=$1 text=${2:0:34} width=40 fill
    fill=$(( pct * width / 100 ))
    printf '\r  %s[%s%s%s%s%s]%s %s%3d%%%s  %s%s%s\033[K' \
        "$GRY" "$CYN" "$(rep '█' "$fill")" "$GRY" "$(rep '░' $(( width - fill )))" "$GRY" "$R" \
        "$WHT" "$pct" "$R" "$GRY" "$text" "$R" >"$TTY"
}

progress_step() {  # $1=from% $2=to% $3=text, rest = command - animated bar while it runs
    local from=$1 to=$2 text=$3 pid rc p
    shift 3
    "$@" >>"$LOG_FILE" 2>&1 &
    pid=$!
    p=$from
    while kill -0 "$pid" 2>/dev/null; do
        draw_bar "$p" "$text"
        if (( p < to - 1 )); then p=$(( p + 1 )); fi
        sleep 0.25
    done
    wait "$pid"
    rc=$?
    draw_bar "$to" "$text"
    return "$rc"
}

step_line() {  # $1=ok|warn|fail $2=text - prints a result line above the bar
    local icon
    case $1 in ok) icon="${GRN}✔${R}" ;; warn) icon="${YLW}!${R}" ;; *) icon="${RED}✘${R}" ;; esac
    printf '\r\033[K    %s %s\n' "$icon" "$2" >"$TTY"
}

apt_update()  { apt-get -o DPkg::Lock::Timeout=180 update -qq; }
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$1"; }

run_setup() {  # $1 = welcome (first start) | repair (something went missing)
    local line cmd pkg req desc key i n from to step problems=0
    local -a pkgs=()

    if [[ $1 == welcome ]]; then
        banner
        {
            title "$MAG" "Welcome"
            printf '\n    %sVPN Gateway v%s%s\n' "$WHT" "$VERSION" "$R"
            printf '    %sTurns this Ubuntu machine into a VPN gateway for your LAN.%s\n' "$TXT" "$R"
            printf '    %skill switch · port forwarding · TorGuard & Proton VPN auto-follow%s\n\n' "$GRY" "$R"
            printf '    %s%-10s%s %s%s%s\n' "$GRY" "PROJECT" "$R" "$CYN" "$REPO_URL" "$R"
            printf '    %s%-10s%s %s\n' "$GRY" "AUTHOR" "$R" "MorphyDK"
            printf '    %s%-10s%s %s\n\n' "$GRY" "LICENSE" "$R" "MIT"
            printf '    %sThis first-time setup checks your system and installs anything%s\n' "$TXT" "$R"
            printf '    %sthat is missing. Your firewall is NOT changed until you choose%s\n' "$TXT" "$R"
            printf '    %s4 "Build / rebuild gateway" in the menu.%s\n\n' "$TXT" "$R"
            printf '  %s[Enter]%s start setup   %s[q]%s quit ' "$CYN" "$R" "$CYN" "$R"
        } >"$TTY"
        read -rsn1 key <"$TTY" || return 1
        if [[ $key == q || $key == Q ]]; then return 1; fi
    fi

    banner
    title "$CYN" "$([[ $1 == welcome ]] && echo "System setup" || echo "Missing components detected")" >"$TTY"

    # 1) Component check
    printf '\n   %sCOMPONENTS%s\n' "$MAG" "$R" >"$TTY"
    for line in "${DEPS[@]}"; do
        IFS='|' read -r cmd pkg req desc <<<"$line"
        if command -v "$cmd" >/dev/null 2>&1; then
            printf '    %s✔%s %s%-10s%s %s%s%s\n' "$GRN" "$R" "$WHT" "$cmd" "$R" "$GRY" "$desc" "$R" >"$TTY"
        else
            printf '    %s✘%s %s%-10s%s %s%s%s  %s(missing - package %s)%s\n' "$YLW" "$R" "$WHT" "$cmd" "$R" "$GRY" "$desc" "$R" "$YLW" "$pkg" "$R" >"$TTY"
            [[ " ${pkgs[*]} " == *" $pkg "* ]] || pkgs+=("$pkg")
        fi
    done

    # 2) Install bar 0-100 %
    printf '\n   %sINSTALLATION%s\n' "$MAG" "$R" >"$TTY"
    if (( ${#pkgs[@]} == 0 )); then
        draw_bar 100 "All components already present"
        printf '\n' >"$TTY"
    else
        log "Setup: installing ${pkgs[*]}"
        n=$(( ${#pkgs[@]} + 1 ))
        step=$(( 100 / n ))
        if progress_step 0 "$step" "Updating package lists" apt_update; then
            step_line ok "Package lists updated"
        else
            step_line warn "Package list update failed (no internet?) - trying anyway"
        fi
        for i in "${!pkgs[@]}"; do
            from=$(( (i + 1) * step ))
            to=$(( i == ${#pkgs[@]} - 1 ? 100 : (i + 2) * step ))
            if progress_step "$from" "$to" "Installing ${pkgs[$i]}" apt_install "${pkgs[$i]}"; then
                step_line ok "Installed ${pkgs[$i]}"
            else
                step_line fail "Could not install ${pkgs[$i]} - see $LOG_FILE"
            fi
        done
        draw_bar 100 "Installation finished"
        printf '\n' >"$TTY"
    fi

    # 3) Validation
    printf '\n   %sVALIDATION%s\n' "$MAG" "$R" >"$TTY"
    step_line ok "Running as root"
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
        step_line ok "systemd is running (needed for the background watcher)"
    else
        step_line fail "systemd not running - the background watcher can't work"; problems=1
    fi
    for line in "${DEPS[@]}"; do
        IFS='|' read -r cmd pkg req desc <<<"$line"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            if (( req )); then step_line fail "Required: $cmd ($pkg) is still missing"; problems=1
            else step_line warn "Optional: $cmd ($pkg) missing - $desc unavailable"; fi
        fi
    done
    if command -v iptables >/dev/null && iptables -w 5 -L -n >/dev/null 2>&1; then
        step_line ok "iptables works ($(iptables --version 2>/dev/null | awk '{print $2, $3}'))"
    else
        step_line fail "iptables can't access the kernel firewall"; problems=1
    fi
    if [[ -w /proc/sys/net/ipv4/ip_forward ]]; then
        step_line ok "IP forwarding can be enabled"
    else
        step_line fail "IP forwarding can't be changed on this system"; problems=1
    fi

    if (( problems )); then
        log "Setup: validation FAILED"
        msg "Setup could not complete - see the red lines above.\nFix them (or check $LOG_FILE) and start the script again." "Setup incomplete"
        return 1
    fi
    echo "$VERSION $(date '+%F %T')" >"$SETUP_MARKER"
    log "Setup: completed for v$VERSION"
    printf '\n  %s✔ System ready.%s  %s[Enter]%s open the dashboard ' "$GRN" "$R" "$CYN" "$R" >"$TTY"
    read -rsn1 _ <"$TTY" || true
    return 0
}

# =============================================================================
#  Start
# =============================================================================
need_root() {
    if [[ $EUID -ne 0 ]]; then
        printf '%sPlease run as root: sudo %s%s\n' "$RED" "$0" "$R"
        exit 1
    fi
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
}

preflight() {  # $1 = check (headless: missing commands are fatal) | setup (interactive)
    local cmd
    need_root
    if [[ ${1:-check} == check ]]; then
        for cmd in iptables ip6tables ip sysctl systemctl flock; do
            command -v "$cmd" >/dev/null || { printf '%sMissing command: %s - run "sudo %s" once to install it%s\n' "$RED" "$cmd" "$0" "$R"; exit 1; }
        done
    fi
    FAIL_FILE=$(mktemp)
    trap 'rm -f "$FAIL_FILE"; printf "\033[0m"' EXIT
}

main() {
    local errs lines i kind addr prov
    case "${1:-}" in
        --keeper|--watch)
            need_root
            IN_SERVICE=1
            FAIL_FILE=$(mktemp)
            load_config
            run_keeper
            ;;
        --apply)
            preflight
            load_config
            errs=$(check_settings)
            if [[ -n $errs ]]; then printf '%sSettings problem:%s\n' "$RED" "$R"; echo "$errs"; exit 1; fi
            printf '%sVPN Gateway v%s%s - %s, applying saved settings\n' "$YLW" "$VERSION" "$R" "$(provider_label "$PROVIDER")"
            apply_rules || { printf '%sBuild failed - see %s%s\n' "$RED" "$LOG_FILE" "$R"; exit 1; }
            printf '%sDone. Kill switch armed (LAN clients).%s\n' "$GRN" "$R"
            ;;
        --detect)
            need_root
            load_config
            lines=$(detect_tunnels)
            if [[ -z $lines ]]; then echo "No active VPN tunnel found."; exit 1; fi
            printf '%-14s %-10s %-15s %s\n' "INTERFACE" "TYPE" "ADDRESS" "PROVIDER"
            while IFS='|' read -r i kind addr prov; do
                printf '%-14s %-10s %-15s %s\n' "$i" "$kind" "${addr:-no IPv4}" "$(provider_label "$prov")"
            done <<<"$lines"
            ;;
        -h|--help)
            usage
            ;;
        "")
            if [[ ! -t 0 || ! -t 1 ]]; then echo "Interactive mode needs a terminal (or use --apply)."; exit 1; fi
            preflight setup
            set_palette ui
            trap 'printf "\033[0m\033[2J\033[H"; exit 130' INT
            if [[ ! -f $SETUP_MARKER ]]; then
                run_setup welcome || { printf '\033[0m\033[2J\033[H'; exit 1; }
            elif [[ -n $(missing_deps) ]]; then
                run_setup repair || { printf '\033[0m\033[2J\033[H'; exit 1; }
            fi
            if [[ -f $CONF_FILE || -f $OLD_CONF_FILE ]]; then
                load_config
            else
                save_config
            fi
            main_menu
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
