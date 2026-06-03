#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
REDSOCKS_PORT="${REDSOCKS_PORT:-12345}"
REDSOCKS6_PORT="${REDSOCKS6_PORT:-12346}"
ENABLE_IPV6_REDSOCKS="${ENABLE_IPV6_REDSOCKS:-0}"
HELPER=/usr/local/bin/warp-google
MANAGER=/usr/local/bin/warp
MODE_FILE=/etc/warp-google.mode
IPV6_FLAG_FILE=/etc/warp-google.ipv6
REDSOCKS_CONF=/etc/redsocks.conf
SERVICE_FILE=/etc/systemd/system/warp-google.service

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${RED}请使用 root 运行。${NC}"
        exit 1
    fi
}

detect_os() {
    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}无法检测系统。${NC}"
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS="${ID:-}"
    VERSION="${VERSION_ID:-}"
    CODENAME="${VERSION_CODENAME:-}"
    ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
}

show_banner() {
    clear || true
    echo -e "${CYAN}"
    echo "============================================================"
    echo "  WARP Google/Gemini 解锁脚本 - IPv4/IPv6 双栈分流"
    echo "============================================================"
    echo -e "${NC}"
}

install_packages() {
    echo -e "${CYAN}[1/4] 安装依赖与 Cloudflare WARP...${NC}"
    case "$OS" in
        ubuntu|debian)
            apt-get update -y
            apt-get install -y curl wget gnupg lsb-release ca-certificates iptables redsocks dnsutils
            install -d -m 0755 /usr/share/keyrings
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            if [ -z "$CODENAME" ] && command -v lsb_release >/dev/null 2>&1; then
                CODENAME="$(lsb_release -cs)"
            fi
            echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main" \
                > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -y
            apt-get install -y cloudflare-warp
            ;;
        centos|rhel|rocky|almalinux|fedora)
            cat > /etc/yum.repos.d/cloudflare-warp.repo <<'EOF'
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
EOF
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y curl wget iptables iptables-services redsocks bind-utils cloudflare-warp
            else
                yum install -y curl wget iptables iptables-services redsocks bind-utils cloudflare-warp
            fi
            ;;
        *)
            echo -e "${RED}暂不支持系统: $OS${NC}"
            echo "支持 Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux / Fedora。"
            exit 1
            ;;
    esac

    if ! command -v warp-cli >/dev/null 2>&1; then
        echo -e "${RED}cloudflare-warp 安装失败。${NC}"
        exit 1
    fi
}

configure_warp() {
    echo -e "${CYAN}[2/4] 配置 WARP SOCKS5 代理模式...${NC}"
    systemctl enable --now warp-svc >/dev/null 2>&1 || true
    warp-cli --accept-tos registration new >/dev/null 2>&1 || warp-cli --accept-tos register >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1 || warp-cli mode proxy >/dev/null 2>&1 || true
    warp-cli --accept-tos proxy port "$WARP_PROXY_PORT" >/dev/null 2>&1 || warp-cli proxy port "$WARP_PROXY_PORT" >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 || warp-cli connect >/dev/null 2>&1 || true
    sleep 2
    warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true
}

write_redsocks_conf() {
    cat > "$REDSOCKS_CONF" <<EOF
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = $REDSOCKS_PORT;
    ip = 127.0.0.1;
    port = $WARP_PROXY_PORT;
    type = socks5;
}
EOF
    rm -f "$IPV6_FLAG_FILE"
    if [ "$ENABLE_IPV6_REDSOCKS" = "1" ] && ip -6 addr show dev lo 2>/dev/null | grep -q '::1'; then
        cat >> "$REDSOCKS_CONF" <<EOF
redsocks {
    local_ip = "::1";
    local_port = $REDSOCKS6_PORT;
    ip = 127.0.0.1;
    port = $WARP_PROXY_PORT;
    type = socks5;
}
EOF
        echo "1" > "$IPV6_FLAG_FILE"
    fi
}

write_helper() {
    cat > "$HELPER" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

REDSOCKS_PORT="${REDSOCKS_PORT:-12345}"
REDSOCKS6_PORT="${REDSOCKS6_PORT:-12346}"
ENABLE_IPV6_REDSOCKS="${ENABLE_IPV6_REDSOCKS:-0}"
MODE_FILE=/etc/warp-google.mode
IPV6_FLAG_FILE=/etc/warp-google.ipv6
CHAIN4=WARP_GOOGLE
CHAIN6=WARP_GOOGLE6
BLOCK4=WARP_GOOGLE_BLOCK
BLOCK6=WARP_GOOGLE6_BLOCK

GOOGLE_CORE_V4="
8.8.4.0/24
8.8.8.0/24
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
72.14.192.0/18
74.125.0.0/16
108.177.0.0/17
142.250.0.0/15
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
"

GOOGLE_CLOUD_V4="
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
104.132.0.0/14
"

GOOGLE_V6="
2001:4860::/32
2404:6800::/32
2607:f8b0::/32
2a00:1450::/32
2c0f:fb50::/32
"

STREAMING_V4="
23.246.0.0/18
37.77.184.0/21
45.57.0.0/17
64.120.128.0/17
66.197.128.0/17
69.53.224.0/19
108.175.32.0/20
185.2.220.0/22
185.9.188.0/22
192.173.64.0/18
198.38.96.0/19
198.45.48.0/20
208.75.76.0/22
"

OPENAI_V4="
104.18.0.0/16
172.64.0.0/13
"

XAI_TWITTER_V4="
69.195.160.0/19
104.244.40.0/21
185.45.4.0/22
192.133.76.0/22
199.16.156.0/22
199.59.148.0/22
"

MODE1_DOMAINS="
gemini.google.com
ai.google.dev
aistudio.google.com
generativelanguage.googleapis.com
makersuite.google.com
alkalimakersuite-pa.clients6.google.com
bard.google.com
www.google.com
ogs.google.com
accounts.google.com
play.google.com
store.google.com
"

XAI_DOMAINS="
x.ai
www.x.ai
grok.x.ai
api.x.ai
accounts.x.ai
auth.x.ai
assets.x.ai
cdn.x.ai
grok.com
www.grok.com
api.grok.com
app.grok.com
auth.grok.com
assets.grok.com
cdn.grok.com
static.grok.com
x.com
www.x.com
api.x.com
graphql.x.com
grok.x.com
client-event-reporter.x.com
twitter.com
www.twitter.com
api.twitter.com
graphql.twitter.com
mobile.twitter.com
t.co
abs.twimg.com
abs-0.twimg.com
pbs.twimg.com
video.twimg.com
ton.twimg.com
ton.twitter.com
platform.twitter.com
syndication.twitter.com
"

OPENAI_DOMAINS="
chatgpt.com
chat.openai.com
api.openai.com
auth.openai.com
platform.openai.com
cdn.openai.com
oaistatic.com
oaiusercontent.com
"

CLAUDE_DOMAINS="
claude.ai
api.anthropic.com
console.anthropic.com
claudeusercontent.com
"

PERPLEXITY_DOMAINS="
perplexity.ai
www.perplexity.ai
api.perplexity.ai
assets.perplexity.ai
"

POE_DOMAINS="
poe.com
www.poe.com
api.poe.com
"

OPENROUTER_DOMAINS="
openrouter.ai
api.openrouter.ai
"

COHERE_DOMAINS="
cohere.com
dashboard.cohere.com
api.cohere.com
"

AI_DOMAINS="
$OPENAI_DOMAINS
$CLAUDE_DOMAINS
$PERPLEXITY_DOMAINS
$POE_DOMAINS
$OPENROUTER_DOMAINS
$COHERE_DOMAINS
"

DEEP_FIX_DOMAINS="
$MODE1_DOMAINS
$XAI_DOMAINS
$AI_DOMAINS
"

resolve_domains() {
    local family="$1"
    local domains="$2"
    local qtype="A"
    [ "$family" = "6" ] && qtype="AAAA"
    for domain in $domains; do
        if command -v dig >/dev/null 2>&1; then
            {
                dig +time=2 +tries=1 +short @"1.1.1.1" "$qtype" "$domain"
                dig +time=2 +tries=1 +short @"8.8.8.8" "$qtype" "$domain"
                dig +time=2 +tries=1 +short "$qtype" "$domain"
            } | awk '/^[0-9a-fA-F:.]+$/ {print}'
        else
            getent ahosts "$domain" | awk -v family="$family" '
                family == "4" && $1 ~ /^[0-9.]+$/ {print $1}
                family == "6" && $1 ~ /:/ {print $1}
            '
        fi
    done | sort -u
}

site_domains() {
    case "${1:-}" in
        gemini|google)
            echo "$MODE1_DOMAINS"
            ;;
        xai|x.ai|grok)
            echo "$XAI_DOMAINS"
            ;;
        openai|chatgpt)
            echo "$OPENAI_DOMAINS"
            ;;
        claude|anthropic)
            echo "$CLAUDE_DOMAINS"
            ;;
        perplexity)
            echo "$PERPLEXITY_DOMAINS"
            ;;
        poe)
            echo "$POE_DOMAINS"
            ;;
        openrouter)
            echo "$OPENROUTER_DOMAINS"
            ;;
        cohere)
            echo "$COHERE_DOMAINS"
            ;;
        all|ai)
            echo "$DEEP_FIX_DOMAINS"
            ;;
        *)
            return 1
            ;;
    esac
}

mode() {
    if [ -n "${1:-}" ]; then
        echo "$1" > "$MODE_FILE"
        return
    fi
    cat "$MODE_FILE" 2>/dev/null || echo "1"
}

ipv6_enabled() {
    [ "$ENABLE_IPV6_REDSOCKS" = "1" ] || [ -f "$IPV6_FLAG_FILE" ]
}

add_v4() {
    local cidr="$1"
    iptables -t nat -A "$CHAIN4" -d "$cidr" -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT"
    iptables -A "$BLOCK4" -d "$cidr" -p udp --dport 443 -j REJECT 2>/dev/null || true
}

add_v6() {
    local cidr="$1"
    if ipv6_enabled; then
        ip6tables -t nat -A "$CHAIN6" -d "$cidr" -p tcp -j REDIRECT --to-ports "$REDSOCKS6_PORT" 2>/dev/null || true
        ip6tables -A "$BLOCK6" -d "$cidr" -p udp --dport 443 -j REJECT 2>/dev/null || true
    else
        ip6tables -A "$BLOCK6" -d "$cidr" -p tcp -m multiport --dports 80,443 -j REJECT 2>/dev/null || true
        ip6tables -A "$BLOCK6" -d "$cidr" -p udp --dport 443 -j REJECT 2>/dev/null || true
    fi
}

flush_rules() {
    iptables -t nat -D OUTPUT -j "$CHAIN4" 2>/dev/null || true
    iptables -t nat -F "$CHAIN4" 2>/dev/null || true
    iptables -t nat -X "$CHAIN4" 2>/dev/null || true
    iptables -D OUTPUT -j "$BLOCK4" 2>/dev/null || true
    iptables -F "$BLOCK4" 2>/dev/null || true
    iptables -X "$BLOCK4" 2>/dev/null || true
    ip6tables -t nat -D OUTPUT -j "$CHAIN6" 2>/dev/null || true
    ip6tables -t nat -F "$CHAIN6" 2>/dev/null || true
    ip6tables -t nat -X "$CHAIN6" 2>/dev/null || true
    ip6tables -D OUTPUT -j "$BLOCK6" 2>/dev/null || true
    ip6tables -F "$BLOCK6" 2>/dev/null || true
    ip6tables -X "$BLOCK6" 2>/dev/null || true
}

build_rules() {
    local selected_mode
    selected_mode="$(mode)"
    flush_rules
    iptables -t nat -N "$CHAIN4" 2>/dev/null || iptables -t nat -F "$CHAIN4"
    iptables -N "$BLOCK4" 2>/dev/null || iptables -F "$BLOCK4"
    ip6tables -N "$BLOCK6" 2>/dev/null || ip6tables -F "$BLOCK6" 2>/dev/null || true
    if ipv6_enabled; then
        ip6tables -t nat -N "$CHAIN6" 2>/dev/null || ip6tables -t nat -F "$CHAIN6" 2>/dev/null || true
    fi

    case "$selected_mode" in
        site:*)
            site="${selected_mode#site:}"
            domains="$(site_domains "$site" || true)"
            if [ -z "$domains" ]; then
                echo "未知站点: $site"
                echo "可用站点: gemini, xai, openai, claude, perplexity, poe, openrouter, cohere, all"
                exit 1
            fi
            [ "$site" = "all" ] || [ "$site" = "ai" ] || echo "单站点修复: $site"
            case "$site" in
                xai|x.ai|grok|all|ai)
                    for ip in $XAI_TWITTER_V4; do add_v4 "$ip"; done
                    ;;
            esac
            for ip in $(resolve_domains 4 "$domains"); do add_v4 "$ip"; done
            for ip in $(resolve_domains 6 "$domains"); do add_v6 "$ip"; done
            ;;
        1)
            for ip in $(resolve_domains 4 "$MODE1_DOMAINS"); do add_v4 "$ip"; done
            for ip in $(resolve_domains 6 "$MODE1_DOMAINS"); do add_v6 "$ip"; done
            ;;
        2)
            for ip in $GOOGLE_CORE_V4 $GOOGLE_CLOUD_V4; do add_v4 "$ip"; done
            for ip in $GOOGLE_V6; do add_v6 "$ip"; done
            ;;
        3)
            for ip in $GOOGLE_CORE_V4 $GOOGLE_CLOUD_V4 $STREAMING_V4 $OPENAI_V4 $XAI_TWITTER_V4; do add_v4 "$ip"; done
            for ip in $(resolve_domains 4 "$XAI_DOMAINS $AI_DOMAINS"); do add_v4 "$ip"; done
            for ip in $(resolve_domains 6 "$XAI_DOMAINS $AI_DOMAINS"); do add_v6 "$ip"; done
            for ip in $GOOGLE_V6; do add_v6 "$ip"; done
            ;;
        4)
            for ip in $GOOGLE_CORE_V4 $GOOGLE_CLOUD_V4 $OPENAI_V4 $XAI_TWITTER_V4; do add_v4 "$ip"; done
            for ip in $(resolve_domains 4 "$DEEP_FIX_DOMAINS"); do add_v4 "$ip"; done
            for ip in $(resolve_domains 6 "$DEEP_FIX_DOMAINS"); do add_v6 "$ip"; done
            for ip in $GOOGLE_V6; do add_v6 "$ip"; done
            ;;
        *)
            echo "未知模式: $selected_mode"
            exit 1
            ;;
    esac

    iptables -t nat -C OUTPUT -j "$CHAIN4" 2>/dev/null || iptables -t nat -A OUTPUT -j "$CHAIN4"
    iptables -C OUTPUT -j "$BLOCK4" 2>/dev/null || iptables -A OUTPUT -j "$BLOCK4"
    ip6tables -C OUTPUT -j "$BLOCK6" 2>/dev/null || ip6tables -A OUTPUT -j "$BLOCK6" 2>/dev/null || true
    if ipv6_enabled; then
        ip6tables -t nat -C OUTPUT -j "$CHAIN6" 2>/dev/null || ip6tables -t nat -A OUTPUT -j "$CHAIN6" 2>/dev/null || true
    fi
}

start() {
    pkill redsocks 2>/dev/null || true
    redsocks -c /etc/redsocks.conf
    build_rules
    echo "WARP Google/Gemini 双栈分流已启动，模式: $(mode)"
}

stop() {
    flush_rules
    pkill redsocks 2>/dev/null || true
    echo "WARP Google/Gemini 分流已停止"
}

status() {
    echo "=== WARP ==="
    warp-cli status 2>/dev/null || echo "未安装或未运行"
    echo
    echo "=== redsocks ==="
    pgrep -x redsocks >/dev/null && echo "运行中" || echo "未运行"
    echo
    echo "=== mode ==="
    mode
    echo
    echo "=== IPv4 rules ==="
    iptables -t nat -L "$CHAIN4" -n 2>/dev/null | head -20 || echo "无 IPv4 规则"
    echo
    echo "=== IPv4 UDP/QUIC block ==="
    iptables -L "$BLOCK4" -n 2>/dev/null | head -20 || echo "无 IPv4 阻断规则"
    echo
    echo "=== IPv6 rules ==="
    if ipv6_enabled; then
        ip6tables -t nat -L "$CHAIN6" -n 2>/dev/null | head -20 || echo "无 IPv6 规则"
    else
        echo "未启用 IPv6 透明转发（当前 redsocks 版本通常不支持 IPv6 监听）。"
    fi
    echo
    echo "=== IPv6 leak block ==="
    ip6tables -L "$BLOCK6" -n 2>/dev/null | head -20 || echo "无 IPv6 阻断规则"
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    status) status ;;
    mode) mode "${2:-}"; start ;;
    site)
        if [ -z "${2:-}" ]; then
            echo "用法: $0 site {gemini|xai|openai|claude|perplexity|poe|openrouter|cohere|all}"
            exit 1
        fi
        mode "site:$2"
        start
        ;;
    *) echo "用法: $0 {start|stop|restart|status|mode 1|2|3|4|site <name>}" ;;
esac
SCRIPT
    chmod +x "$HELPER"
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=WARP Google/Gemini Dual Stack Transparent Proxy
After=network-online.target warp-svc.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HELPER start
ExecStop=$HELPER stop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-google >/dev/null 2>&1 || true
}

write_manager() {
    cat > "$MANAGER" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-}" in
    status)
        /usr/local/bin/warp-google status
        ;;
    start)
        warp-cli connect >/dev/null 2>&1 || true
        /usr/local/bin/warp-google start
        ;;
    stop)
        /usr/local/bin/warp-google stop
        warp-cli disconnect >/dev/null 2>&1 || true
        ;;
    restart)
        "$0" stop
        sleep 2
        "$0" start
        ;;
    mode)
        /usr/local/bin/warp-google mode "${2:-}"
        ;;
    site)
        if [ -z "${2:-}" ]; then
            echo "用法: warp site {gemini|xai|openai|claude|perplexity|poe|openrouter|cohere|all}"
            exit 1
        fi
        echo "启用单站点修复: $2"
        resolvectl flush-caches >/dev/null 2>&1 || systemd-resolve --flush-caches >/dev/null 2>&1 || true
        /usr/local/bin/warp-google site "$2"
        ;;
    fix|repair)
        echo "启用 AI 深度修复模式..."
        echo "4" > /etc/warp-google.mode
        echo "刷新 DNS 缓存..."
        resolvectl flush-caches >/dev/null 2>&1 || systemd-resolve --flush-caches >/dev/null 2>&1 || true
        systemctl restart nscd >/dev/null 2>&1 || true
        systemctl restart dnsmasq >/dev/null 2>&1 || true
        echo "重连 WARP..."
        warp-cli disconnect >/dev/null 2>&1 || true
        sleep 2
        warp-cli connect >/dev/null 2>&1 || true
        sleep 2
        /usr/local/bin/warp-google restart
        echo
        echo "已应用深度修复：AI 域名动态分流、QUIC 阻断、IPv6 防漏、DNS 缓存刷新。"
        echo "请在浏览器/客户端清理 DNS 缓存或重启客户端后重试 x.ai/Grok/Gemini。"
        ;;
    test)
        echo "直连 IPv4:"
        curl -4 -s --max-time 8 ip.sb || true
        echo
        echo "直连 IPv6:"
        curl -6 -s --max-time 8 ip.sb || true
        echo
        echo "WARP IPv4:"
        curl -4 -x socks5://127.0.0.1:40000 -s --max-time 8 ip.sb || true
        echo
        echo "WARP IPv6:"
        curl -6 -x socks5://127.0.0.1:40000 -s --max-time 8 ip.sb || true
        echo
        echo "Gemini:"
        curl -s --max-time 10 -o /dev/null -w "%{http_code}\n" https://gemini.google.com || true
        echo "x.ai:"
        curl -s --max-time 10 -o /dev/null -w "%{http_code}\n" https://x.ai || true
        echo "api.x.ai:"
        curl -s --max-time 10 -o /dev/null -w "%{http_code}\n" https://api.x.ai || true
        echo "grok.com:"
        curl -s --max-time 10 -o /dev/null -w "%{http_code}\n" https://grok.com || true
        echo "api.grok.com:"
        curl -s --max-time 10 -o /dev/null -w "%{http_code}\n" https://api.grok.com || true
        ;;
    diag)
        direct4="$(curl -4 -s --max-time 8 ip.sb || true)"
        direct6="$(curl -6 -s --max-time 8 ip.sb || true)"
        warp4="$(curl -4 -x socks5://127.0.0.1:40000 -s --max-time 8 ip.sb || true)"
        warp6="$(curl -6 -x socks5://127.0.0.1:40000 -s --max-time 8 ip.sb || true)"
        echo "直连 IPv4: ${direct4:-无}"
        [ -n "$direct4" ] && curl -s --max-time 8 "http://ip-api.com/line/$direct4?fields=country,regionName,city,isp,org,query" || true
        echo
        echo "直连 IPv6: ${direct6:-无}"
        [ -n "$direct6" ] && curl -s --max-time 8 "http://ip-api.com/line/$direct6?fields=country,regionName,city,isp,org,query" || true
        echo
        echo "WARP IPv4: ${warp4:-无}"
        [ -n "$warp4" ] && curl -s --max-time 8 "http://ip-api.com/line/$warp4?fields=country,regionName,city,isp,org,query" || true
        echo
        echo "WARP IPv6: ${warp6:-无}"
        [ -n "$warp6" ] && curl -s --max-time 8 "http://ip-api.com/line/$warp6?fields=country,regionName,city,isp,org,query" || true
        echo
        echo "站点 HTTP 状态:"
        for site in https://gemini.google.com https://x.ai https://grok.com https://grok.x.ai https://api.grok.com https://api.x.ai https://chatgpt.com https://claude.ai https://perplexity.ai; do
            printf "%-32s" "$site"
            curl -s --max-time 10 -o /dev/null -w "%{http_code}\n" "$site" || true
        done
        echo
        echo "当前规则:"
        /usr/local/bin/warp-google status
        ;;
    uninstall)
        /usr/local/bin/warp-google stop 2>/dev/null || true
        systemctl disable --now warp-google 2>/dev/null || true
        systemctl disable --now warp-svc 2>/dev/null || true
        rm -f /etc/systemd/system/warp-google.service /usr/local/bin/warp-google /usr/local/bin/warp /etc/warp-google.mode /etc/warp-google.ipv6 /etc/redsocks.conf
        systemctl daemon-reload 2>/dev/null || true
        echo "已卸载脚本文件。cloudflare-warp/redsocks 软件包如需移除，请手动执行 apt/yum/dnf remove。"
        ;;
    *)
        echo "WARP 管理命令"
        echo "用法: warp {status|start|stop|restart|mode <1|2|3|4>|site <name>|fix|repair|test|diag|uninstall}"
        echo "单站点: gemini, xai, openai, claude, perplexity, poe, openrouter, cohere, all"
        ;;
esac
SCRIPT
    chmod +x "$MANAGER"
}

run_manager_command() {
    if [ -x "$HELPER" ]; then
        write_helper
        write_manager
        "$MANAGER" "$@"
        return
    fi

    if [ -x "$MANAGER" ]; then
        "$MANAGER" "$@"
        return
    fi

    echo "尚未安装。"
    exit 1
}

prompt_site_name() {
    echo "可用站点: gemini, xai, openai, claude, perplexity, poe, openrouter, cohere, all"
    read -r -p "请输入站点名: " site
    if [ -z "$site" ]; then
        echo "站点名不能为空。"
        exit 1
    fi
    run_manager_command site "$site"
}

choose_mode() {
    echo -e "${CYAN}[3/4] 选择分流模式${NC}"
    echo "1. 仅 Gemini / Google 搜索 / Google Play / 商店（推荐，尽量保留 YouTube 直连）"
    echo "2. Google 全家桶（含 YouTube，IPv4/IPv6）"
    echo "3. Google + 常见流媒体 + OpenAI/x.ai（IPv4/IPv6 规则可用部分生效）"
    echo "4. AI 深度修复模式（Gemini + x.ai/Grok + OpenAI + Claude + Perplexity 等）"
    read -r -p "请输入模式 [1-4，默认 1]: " selected
    selected="${selected:-1}"
    case "$selected" in
        1|2|3|4) echo "$selected" > "$MODE_FILE" ;;
        *) echo "1" > "$MODE_FILE" ;;
    esac
}

setup_proxy() {
    echo -e "${CYAN}[4/4] 写入透明代理与双栈规则...${NC}"
    write_redsocks_conf
    write_helper
    write_service
    write_manager
    "$HELPER" start
}

test_connection() {
    echo -e "${CYAN}连接测试${NC}"
    echo -n "WARP IPv4: "
    curl -4 -x "socks5://127.0.0.1:$WARP_PROXY_PORT" -s --max-time 8 ip.sb || true
    echo
    echo -n "WARP IPv6: "
    curl -6 -x "socks5://127.0.0.1:$WARP_PROXY_PORT" -s --max-time 8 ip.sb || true
    echo
    echo -n "Gemini HTTP 状态: "
    curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://gemini.google.com || true
    echo
}

do_install() {
    install_packages
    configure_warp
    choose_mode
    setup_proxy
    test_connection
    echo -e "${GREEN}安装完成。管理命令: warp {status|start|stop|restart|mode <1|2|3|4>|fix|test|diag|uninstall}${NC}"
}

do_uninstall() {
    "$HELPER" stop 2>/dev/null || true
    systemctl disable --now warp-google 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$HELPER" "$MANAGER" "$MODE_FILE" "$IPV6_FLAG_FILE" "$REDSOCKS_CONF"
    systemctl daemon-reload 2>/dev/null || true
    echo -e "${GREEN}已清理分流规则与脚本文件。${NC}"
}

show_status() {
    if [ -x "$HELPER" ]; then
        "$HELPER" status
    else
        echo "尚未安装。"
    fi
}

show_menu() {
    echo "1. 安装 / 重装 WARP Google/Gemini 解锁"
    echo "2. 卸载"
    echo "3. 查看状态"
    echo "4. 切换分流模式"
    echo "5. AI 站点深度修复"
    echo "6. 单站点修复"
    echo "0. 退出"
    read -r -p "请选择 [0-6]: " choice
    case "$choice" in
        1) do_install ;;
        2) do_uninstall ;;
        3) show_status ;;
        4)
            if [ ! -x "$HELPER" ]; then
                echo "尚未安装。"
                exit 1
            fi
            choose_mode
            "$HELPER" restart
            ;;
        5)
            run_manager_command fix
            ;;
        6)
            prompt_site_name
            ;;
        0) exit 0 ;;
        *) echo "无效选项。" ;;
    esac
}

main() {
    require_root
    detect_os
    show_banner
    echo -e "${GREEN}系统: $OS $VERSION $ARCH${NC}"

    case "${1:-}" in
        install) do_install ;;
        uninstall) do_uninstall ;;
        status) show_status ;;
        start) "$HELPER" start ;;
        stop) "$HELPER" stop ;;
        restart) "$HELPER" restart ;;
        test) test_connection ;;
        fix|repair|5) run_manager_command fix ;;
        site)
            if [ -z "${2:-}" ]; then
                echo "用法: $0 site {gemini|xai|openai|claude|perplexity|poe|openrouter|cohere|all}"
                exit 1
            fi
            run_manager_command site "$2"
            ;;
        6)
            if [ -n "${2:-}" ]; then
                run_manager_command site "$2"
            else
                prompt_site_name
            fi
            ;;
        mode)
            if [ -n "${2:-}" ]; then
                echo "$2" > "$MODE_FILE"
                "$HELPER" restart
            else
                choose_mode
                "$HELPER" restart
            fi
            ;;
        *) show_menu ;;
    esac
}

main "$@"
