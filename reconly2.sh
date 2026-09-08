#!/usr/bin/env bash

export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"

color_reset="\e[0m"
color_cyan="\e[36;1m"
color_red="\e[31;1m"
color_yellow="\e[33;1m"
color_green="\e[32;1m"
color_magenta="\e[35;1m"
color_white="\e[97;1m"

ALLOW_INSECURE="${ALLOW_INSECURE:-n}"
export ALLOW_INSECURE

html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

md5_hash() {
    if command -v md5sum &>/dev/null; then
        md5sum | awk '{print $1}'
    else
        md5 -q
    fi
}

redact_secret_value() {
    local val="$1"
    val=$(printf '%s' "$val" | sed -E 's/[A-Za-z0-9_-]{20,}/[REDACTED]/g')
    val=$(printf '%s' "$val" | sed -E 's#([a-zA-Z]+://)[^/@]+:[^/@]+@#\1[REDACTED]@#g')
    printf '%s' "$val"
}

trap_ctrlc() {
    echo -e "\n${color_red}[!] Ctrl+C Detected! Aborting scan...${color_reset}"
    echo -e "${color_yellow}[*] Terminating active child processes...${color_reset}"
    trap '' SIGINT SIGTERM

    if [[ $$ -eq $(ps -o pgid= -p $$ | tr -d ' ') ]]; then
        kill -- -$$ 2>/dev/null
    else
        pkill -P $$ 2>/dev/null
    fi
    sleep 0.3
    echo -e "${color_yellow}[*] Cleaning up temporary files...${color_reset}"
    if [[ -n "$SESSION_DIR" && -d "$SESSION_DIR" ]]; then
        cd "$SESSION_DIR" || exit
        rm -f t.txt l1.txt l2.txt l3.txt l4.txt resolvers.txt trusted-resolvers.txt all-URLs-temp.txt 2>/dev/null
        echo -e "${color_green}[+] Cleanup done. Session saved in: $SESSION_DIR/reconly.log${color_reset}"
    else
        echo -e "${color_green}[+] Cleanup done. No active session to log.${color_reset}"
    fi
    stty sane 2>/dev/null
    exit 2
}
trap trap_ctrlc SIGINT SIGTERM

clear
echo -e "${color_red}
                  ______ _______ _______  _____  __   _        __   __
                 |_____/ |______ |       |     | | \  | |        \_/  
                 |    \_ |______ |_____  |_____| |  \_| |_____    |   
${color_reset}"
echo -e "                                  github.com/Ln0rag\n"

printf "${color_cyan}+-------------------+-----------------------------+-----------------------------------+${color_reset}\n"
printf "${color_cyan}| ${color_yellow}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "Tool" "GitHub Repo" "Role in Reconly"
printf "${color_cyan}+-------------------+-----------------------------+-----------------------------------+${color_reset}\n"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "curl" "curl/curl" "HTTP Client & JS Fetching"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "subfinder" "projectdiscovery/subfinder" "Passive Subdomain Enumeration"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "assetfinder" "tomnomnom/assetfinder" "Passive Subdomain Enumeration"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "findomain" "findomain/findomain" "Passive Subdomain Enumeration"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "github-subdomains" "gwen001/github-subdomains" "GitHub API Subdomain Scraping"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "shosubgo" "incogbyte/shosubgo" "Shodan API Subdomain Scraping"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "puredns" "d3mondev/puredns" "Active DNS Bruteforcing"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "massdns" "blechschmidt/massdns" "High-Performance DNS Resolver"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "httpx" "projectdiscovery/httpx" "Live Host Probing & Tech Detect"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "gau" "lc/gau" "Passive URL Fetching"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "katana" "projectdiscovery/katana" "Active Web Crawling"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "uro" "s0md3v/uro" "URL Deduplication & Filtering"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "arjun" "s0md3v/Arjun" "HTTP Parameter Discovery"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "ffuf" "ffuf/ffuf" "Stealth Fuzzing (Dirs & Params)"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "prettier/jsbeaut" "prettier + js-beautify" "JS Code Beautification"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "trufflehog" "trufflesecurity/trufflehog" "Verified Secret & Token Scanning"
printf "${color_cyan}| ${color_white}%-17s ${color_cyan}| ${color_magenta}%-27s ${color_cyan}| ${color_green}%-33s ${color_cyan}|${color_reset}\n" "jq" "jqlang/jq" "JSON Processing for TruffleHog"
printf "${color_cyan}+-------------------+-----------------------------+-----------------------------------+${color_reset}\n"

RAW_DOMAIN=""
AUTH_HEADERS=()
AUTH_COOKIE=""
NOTIFY_WEBHOOK=""
while getopts "d:H:c:n:h" opt; do
    case $opt in
        d) RAW_DOMAIN="$OPTARG" ;;
        H) AUTH_HEADERS+=("$OPTARG") ;;
        c) AUTH_COOKIE="$OPTARG" ;;
        n) NOTIFY_WEBHOOK="$OPTARG" ;;
        h) echo -e "Usage: reconly.sh -d <domain.com> [-H \"Header: value\"] [-c \"cookie=value\"] [-n <Discord/Telegram webhook_url>]\n\nExample:\n reconly.sh -d example.com -H \"Authorization: Bearer eyJ...\" -c \"session=abc\" -n \"Discord/Telegram webhook_url\""; exit 0 ;;
        \?) echo "Invalid option. Use -h for help."; exit 1 ;;
    esac
done

if [ -z "$RAW_DOMAIN" ]; then
    echo -e "${color_red}[!] Domain is required.${color_reset}"
    exit 1
fi

DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|^www\.||')
DOMAIN_ESCAPED="${DOMAIN//./\.}"

if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo -e "${color_red}[!] Invalid domain format: $DOMAIN${color_reset}"
    exit 1
fi

KATANA_AUTH_ARGS=()
HTTPX_AUTH_ARGS=()
FFUF_AUTH_ARGS=()
ARJUN_AUTH_HEADER=""
AUTH_HEADERS_STR=""

for h in "${AUTH_HEADERS[@]}"; do
    KATANA_AUTH_ARGS+=(-H "$h")
    HTTPX_AUTH_ARGS+=(-H "$h")
    FFUF_AUTH_ARGS+=(-H "$h")
    ARJUN_AUTH_HEADER="${ARJUN_AUTH_HEADER}${h}\n"
    AUTH_HEADERS_STR+="${h}"$'\n'
done

if [ -n "$AUTH_COOKIE" ]; then
    KATANA_AUTH_ARGS+=(-H "Cookie: $AUTH_COOKIE")
    HTTPX_AUTH_ARGS+=(-H "Cookie: $AUTH_COOKIE")
    FFUF_AUTH_ARGS+=(-H "Cookie: $AUTH_COOKIE")
    ARJUN_AUTH_HEADER="${ARJUN_AUTH_HEADER}Cookie: ${AUTH_COOKIE}\n"
fi
if [ ${#AUTH_HEADERS[@]} -gt 0 ] || [ -n "$AUTH_COOKIE" ]; then
    echo -e "${color_magenta}[*] Authenticated recon enabled — session state will be sent to katana/httpx/ffuf/arjun.${color_reset}"
fi
LOGOUT_EXCLUDE_REGEX='(^|/)(logout|log-out|signout|sign-out|logoff|log-off)(/|\?|$)'

notify_webhook() {
    local msg="$1"
    [ -z "$NOTIFY_WEBHOOK" ] && return 0
    if [[ "$NOTIFY_WEBHOOK" == *"discord.com"* ]]; then
        curl -s -m 10 -H "Content-Type: application/json" -d "{\"content\": \"**Reconly** [$DOMAIN]: ${msg}\"}" "$NOTIFY_WEBHOOK" >/dev/null 2>&1 || true
    elif [[ "$NOTIFY_WEBHOOK" == *"api.telegram.org"* ]]; then
        curl -s -m 10 --data-urlencode "text=Reconly [$DOMAIN]: ${msg}" "$NOTIFY_WEBHOOK" >/dev/null 2>&1 || true
    else
        curl -s -m 10 -H "Content-Type: application/json" -d "{\"text\": \"Reconly [$DOMAIN]: ${msg}\"}" "$NOTIFY_WEBHOOK" >/dev/null 2>&1 || true
    fi
}

BASE_DIR="$HOME/reconly/$DOMAIN"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
START_PHASE=1

if [ -d "$BASE_DIR" ]; then
    LATEST_SESSION=$(find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
    [ -z "$LATEST_SESSION" ] && LATEST_SESSION=$(ls -td "$BASE_DIR"/*/ 2>/dev/null | head -1)

    if [ -n "$LATEST_SESSION" ] && [ -d "$LATEST_SESSION" ]; then
        echo -e "${color_magenta}[!] Previous scans detected for $DOMAIN!${color_reset}"
        echo "  [1] Start fresh (New Scan)"
        echo "  [2] Resume: Active DNS Bruteforce"
        echo "  [3] Resume: Live URLs Probing (httpx)"
        echo "  [4] Resume: Crawling (gau & katana)"
        echo "  [5] Resume: Smart Filtering"
        echo "  [6] Resume: Fuzzing (Params & Dirs)"
        echo "  [7] Resume: JavaScript Analysis"
        read -p "Select a starting point [1-7] (Default 1): " choice
        if [[ "$choice" =~ ^[1-7]$ ]]; then
            echo ""; echo ""
            START_PHASE=$choice
        fi
        if [ "$START_PHASE" -ne 1 ]; then
            SESSION_DIR="$LATEST_SESSION"
            echo -e "${color_green}[+] Resuming scan in: $SESSION_DIR${color_reset}\n"
        else
            SESSION_DIR="$BASE_DIR/$TIMESTAMP"
            mkdir -p "$SESSION_DIR"
        fi
    else
        SESSION_DIR="$BASE_DIR/$TIMESTAMP"
        mkdir -p "$SESSION_DIR"
    fi
else
    SESSION_DIR="$BASE_DIR/$TIMESTAMP"
    mkdir -p "$SESSION_DIR"
fi

cd "$SESSION_DIR" || exit
exec > >(trap "" INT TERM; tee -a reconly.log) 2>&1

if [ "$START_PHASE" -le 4 ]; then
    echo -e "${color_cyan}[*] Checking internet connection...${color_reset}"
    if ! ping -c 1 -W 2 1.1.1.1 &> /dev/null; then
        echo -e "${color_yellow}[*] ICMP ping failed, trying HTTPS request...${color_reset}"
        if ! curl -sI -m 5 https://1.1.1.1 >/dev/null 2>&1; then
            echo -e "${color_red}[!] No internet connection! Please check your network and try again.${color_reset}"
            exit 1
        fi
    fi
    echo -ne "${color_yellow}[*] Testing connection speed... ${color_reset}"
    SPEED_BPS=$(curl -s -w "%{speed_download}" -o /dev/null -m 5 https://speed.cloudflare.com/__down?bytes=3000000 2>/dev/null || echo "0")
    if command -v bc &>/dev/null; then
        SPEED_MBPS=$(echo "scale=2; $SPEED_BPS / 1024 / 1024" | bc)
    else
        SPEED_MBPS=$(awk -v bps="$SPEED_BPS" 'BEGIN{printf "%.2f", bps/1024/1024}')
    fi
    echo -e "${color_green}${SPEED_MBPS} MB/s${color_reset}\n"
fi

declare -A tools=(
    ["subfinder"]="go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    ["assetfinder"]="go install github.com/tomnomnom/assetfinder@latest"
    ["findomain"]="wget -q https://github.com/findomain/findomain/releases/latest/download/findomain-linux -O findomain && chmod +x findomain && sudo mv findomain /usr/local/bin/"
    ["github-subdomains"]="go install github.com/gwen001/github-subdomains@latest"
    ["shosubgo"]="go install github.com/incogbyte/shosubgo@latest"
    ["puredns"]="go install github.com/d3mondev/puredns/v2@latest"
    ["httpx"]="go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest"
    ["gau"]="go install github.com/lc/gau/v2/cmd/gau@latest"
    ["katana"]="go install github.com/projectdiscovery/katana/cmd/katana@latest"
    ["ffuf"]="go install github.com/ffuf/ffuf@latest"
    ["trufflehog"]="go install github.com/trufflesecurity/trufflehog/v3@latest"
    ["uro"]="pip install uro --break-system-packages"
    ["arjun"]="pip install arjun --break-system-packages"
)

check_deps() {
    local missing=0
    local tool
    for tool in "$@"; do
        if command -v "$tool" &> /dev/null; then
            continue
        fi
        missing=1
        if [[ -n "${tools[$tool]+set}" ]]; then
            echo -e "${color_red}[!] $tool is not installed.${color_reset}"
            echo -e "    Run: ${color_cyan}${tools[$tool]}${color_reset}"
        else
            echo -e "${color_red}[!] Required utility '$tool' is not installed.${color_reset}"
        fi
    done
    return "$missing"
}

MANDATORY_DEPS=()
[ "$START_PHASE" -le 1 ] && MANDATORY_DEPS+=(subfinder assetfinder findomain)
[ "$START_PHASE" -le 3 ] && MANDATORY_DEPS+=(httpx)
[ "$START_PHASE" -le 4 ] && MANDATORY_DEPS+=(gau katana)
[ "$START_PHASE" -le 7 ] && MANDATORY_DEPS+=(curl xargs tee)

if [ ${#MANDATORY_DEPS[@]} -gt 0 ]; then
    if ! check_deps "${MANDATORY_DEPS[@]}"; then
        echo -e "${color_red}[!] Install the missing core dependencies above and re-run.${color_reset}"
        exit 1
    fi
fi

use_shodan="n"; SHODAN_KEY=""
use_github="n"; GITHUB_KEY=""
use_dns_brute="n"; use_fuzzing="n"
DNS_WORDLIST=""; PARAM_WORDLIST=""; DIR_WORDLIST=""

if [ "$START_PHASE" -le 1 ]; then
    echo -e "Do you want to search in ${color_white}Shodan${color_reset} ? (Y/n) [Default: Y]: \c"
    read p_shodan
    if [[ -z "$p_shodan" || "$p_shodan" =~ ^[Yy]$ ]]; then
        read -p "Please Enter a valid Shodan KEY: " SHODAN_KEY
        if curl -s -f "https://api.shodan.io/api-info?key=$SHODAN_KEY" | grep -q "plan"; then
            if check_deps shosubgo; then
                echo -e "${color_green}Shodan key is valid ${color_reset}\n"; use_shodan="y"
            else
                echo -e "${color_yellow}[!] shosubgo binary missing, skipping Shodan search despite valid key.${color_reset}\n"
            fi
        else
            echo -e "${color_red}Shodan key is not valid, Skipping...${color_reset}\n"
        fi
    else
        echo -e "${color_cyan}Skipping Shodan search...${color_reset}\n"
    fi

    echo -e "Do you want to search in ${color_white}Github${color_reset} ? (Y/n) [Default: Y]: \c"
    read p_github
    if [[ -z "$p_github" || "$p_github" =~ ^[Yy]$ ]]; then
        read -p "Please Enter a valid Github Token: " GITHUB_KEY
        if curl -s -f -H "Authorization: token $GITHUB_KEY" "https://api.github.com/user" | grep -q "login"; then
            if check_deps github-subdomains; then
                echo -e "${color_green}Github token is valid ${color_reset}\n"; use_github="y"
            else
                echo -e "${color_yellow}[!] github-subdomains binary missing, skipping GitHub search despite valid token.${color_reset}\n"
            fi
        else
            echo -e "${color_red}Github token is not valid, Skipping...${color_reset}\n"
        fi
    else
        echo -e "${color_cyan}Skipping Github search...${color_reset}\n"
    fi
fi

if [ "$START_PHASE" -le 2 ]; then
    echo -e "Do you want to ${color_white}Actively Bruteforce Subdomains${color_reset} ? (Y/n) [Default: Y]: \c"
    read p_dns
    if [[ -z "$p_dns" || "$p_dns" =~ ^[Yy]$ ]]; then
        if check_deps puredns; then
            if ! command -v massdns &>/dev/null; then
                echo -e "${color_yellow}[!] massdns is not installed. puredns requires massdns. Skipping DNS bruteforcing.${color_reset}"
            else
                use_dns_brute="y"
            fi
        else
            echo -e "${color_yellow}[!] puredns binary missing, skipping DNS bruteforcing.${color_reset}\n"
        fi
    else
        echo -e "${color_cyan}Skipping DNS bruteforcing...${color_reset}\n"
    fi
else
    use_dns_brute="n"
fi

if [ "$START_PHASE" -le 6 ]; then
    echo -e "Do you want to ${color_white}Fuzz Parameters & Directories${color_reset} (Takes longer)? (Y/n) [Default: Y]: \c"
    read p_fuzz
    if [[ -z "$p_fuzz" || "$p_fuzz" =~ ^[Yy]$ ]]; then
        if check_deps ffuf; then
            use_fuzzing="y"
        else
            echo -e "${color_yellow}[!] ffuf binary missing, skipping Fuzzing.${color_reset}\n"
        fi
    else
        echo -e "${color_cyan}Skipping Fuzzing...${color_reset}\n"
    fi
else
    use_fuzzing="n"
fi

if [[ "$use_dns_brute" == "y" || "$use_fuzzing" == "y" ]]; then
    echo -e "\n${color_magenta}[Hint] Wordlist Configuration${color_reset}"
    echo -e "Do you want to use custom individual wordlist paths? (y/N): \c"
    read custom_wl
    
    if [[ "$custom_wl" =~ ^[Yy]$ ]]; then
        if [[ "$use_dns_brute" == "y" && "$START_PHASE" -le 2 ]]; then
            while true; do
                echo -e "Enter path for DNS bruteforce: \c"
                read DNS_WORDLIST
                [ -f "$DNS_WORDLIST" ] && break
                echo -e "${color_red}[!] File not found.${color_reset}"
            done
        fi
        
        if [[ "$use_fuzzing" == "y" ]]; then
            while true; do
                echo -e "Enter path for Parameters bruteforce: \c"
                read PARAM_WORDLIST
                [ -f "$PARAM_WORDLIST" ] && break
                echo -e "${color_red}[!] File not found.${color_reset}"
            done

            while true; do
                echo -e "Enter path for Directories bruteforce: \c"
                read DIR_WORDLIST
                [ -f "$DIR_WORDLIST" ] && break
                echo -e "${color_red}[!] File not found.${color_reset}"
            done
        fi
    else
        echo -e "Enter seclists base path [Default: /media/DATA/seclists]: \c"
        read seclists_base
        if [ -z "$seclists_base" ]; then
            seclists_base="/media/DATA/seclists"
        fi

        if [[ "$use_dns_brute" == "y" ]]; then
            DNS_WORDLIST="$seclists_base/Discovery/DNS/subdomains-top1million-5000.txt"
            if [ ! -f "$DNS_WORDLIST" ]; then echo -e "${color_red}[!] Warning: File not found -> $DNS_WORDLIST${color_reset}"; fi
        fi

        if [[ "$use_fuzzing" == "y" ]]; then
            PARAM_WORDLIST="$seclists_base/Discovery/Web-Content/burp-parameter-names.txt"
            DIR_WORDLIST="$seclists_base/Discovery/Web-Content/common.txt"
            if [ ! -f "$PARAM_WORDLIST" ]; then echo -e "${color_red}[!] Warning: File not found -> $PARAM_WORDLIST${color_reset}"; fi
            if [ ! -f "$DIR_WORDLIST" ]; then echo -e "${color_red}[!] Warning: File not found -> $DIR_WORDLIST${color_reset}"; fi
        fi
    fi
    
    echo -e "${color_green}[+] Wordlists configured successfully!${color_reset}"
    if [[ "$use_dns_brute" == "y" ]]; then echo -e "${color_cyan}  - DNS Target Path    : ${color_white}$DNS_WORDLIST${color_reset}"; fi
    if [[ "$use_fuzzing" == "y" ]]; then 
        echo -e "${color_cyan}  - Parameters Path    : ${color_white}$PARAM_WORDLIST${color_reset}"
        echo -e "${color_cyan}  - Directories Path   : ${color_white}$DIR_WORDLIST${color_reset}"
    fi
    echo -e ""
fi

if [ "$START_PHASE" -le 2 ] && [ "$use_dns_brute" == "y" ]; then
    echo -e "${color_cyan}[*] Fetching fresh DNS resolvers...${color_reset}"
    if ! curl -s -m 15 -f "https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt" -o resolvers.txt 2>/dev/null || [ ! -s resolvers.txt ]; then
        echo -e "${color_yellow}[!] Could not fetch fresh resolvers, falling back to the embedded static list.${color_reset}"
        cat << 'EOF' > resolvers.txt
1.0.0.1
1.1.1.1
134.195.4.2
149.112.112.112
159.89.120.99
185.228.168.9
185.228.169.9
195.46.39.39
195.46.39.40
205.171.2.65
205.171.3.65
208.67.220.220
208.67.222.222
216.146.35.35
216.146.36.36
64.6.64.6
64.6.65.6
74.82.42.42
76.76.10.0
76.76.2.0
77.88.8.1
77.88.8.8
8.20.247.20
8.26.56.26
8.8.4.4
8.8.8.8
84.200.69.80
84.200.70.40
89.233.43.71
9.9.9.9
91.239.100.100
EOF
    else
        echo -e "${color_green}[+] Fetched $(wc -l < resolvers.txt) fresh resolvers.${color_reset}"
    fi

    cat << 'EOF' > trusted-resolvers.txt
1.1.1.1
8.8.8.8
9.9.9.9
208.67.222.222
EOF
fi

UAS=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/119.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    "Mozilla/5.0 (X11; Linux x86_64; rv:102.0) Gecko/20100101 Firefox/102.0"
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/119.0.6045.109 Mobile/15E148 Safari/604.1"
)

safe_output() {
    local cmd_name="$1"
    shift
    local output_file="$1"
    shift
    local temp_file
    temp_file=$(mktemp) || return 1
    if "$cmd_name" "$@" > "$temp_file"; then
        mv "$temp_file" "$output_file"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

if [ "$START_PHASE" -le 1 ]; then
    echo -e "\n${color_yellow}=== [Phase 1] Passive Subdomain Enumeration ===${color_reset}"
    echo -e ""

    echo -e "${color_cyan}[~]$ subfinder -d $DOMAIN -all -recursive -rl 30 -t 10 -silent | sort -u${color_reset}"
    if safe_output subfinder subfinder.txt -d "$DOMAIN" -all -recursive -rl 30 -t 10 -silent; then
        sort -u subfinder.txt -o subfinder.txt
    else
        echo -e "${color_red}[!] subfinder failed. Preserving previous subfinder.txt if any.${color_reset}"
    fi

    echo -e ""
    echo -e "${color_cyan}[~]$ assetfinder --subs-only $DOMAIN | grep -Ei \"(^|\\.)${DOMAIN_ESCAPED}$\" | sort -u${color_reset}"
    if safe_output assetfinder assetfinder.txt --subs-only "$DOMAIN"; then
        grep -Ei "(^|\.)${DOMAIN_ESCAPED}$" assetfinder.txt | sort -u -o assetfinder.txt
    else
        echo -e "${color_red}[!] assetfinder failed. Preserving previous assetfinder.txt if any.${color_reset}"
    fi

    echo -e ""
    echo -e "${color_cyan}[~]$ findomain -t $DOMAIN -q | grep -Ei \"(^|\\.)${DOMAIN_ESCAPED}$\" | sort -u${color_reset}"
    if safe_output findomain findomain.txt -t "$DOMAIN" -q; then
        grep -Ei "(^|\.)${DOMAIN_ESCAPED}$" findomain.txt | sort -u -o findomain.txt
    else
        echo -e "${color_red}[!] findomain failed. Preserving previous findomain.txt if any.${color_reset}"
    fi

    if [[ "$use_github" == "y" ]]; then
        echo -e ""
        echo -e "${color_cyan}[~]$ github-subdomains -d $DOMAIN -t \"***\" | grep -Ei \"(^|\\.)${DOMAIN_ESCAPED}$\" | sort -u${color_reset}"
        if safe_output github-subdomains github-subs.txt -d "$DOMAIN" -t "$GITHUB_KEY"; then
            grep -Ei "(^|\.)${DOMAIN_ESCAPED}$" github-subs.txt | sort -u -o github-subs.txt
            if [ ! -s github-subs.txt ]; then
                echo -e "${color_white}[*] No subdomains found on GitHub for this domain.${color_reset}"
            fi
        else
            echo -e "${color_red}[!] github-subdomains failed. Preserving previous github-subs.txt if any.${color_reset}"
        fi
    fi

    if [[ "$use_shodan" == "y" ]]; then
        echo -e ""
        echo -e "${color_cyan}[~]$ shosubgo -d $DOMAIN -s \"***\" | grep -Ei \"(^|\\.)${DOMAIN_ESCAPED}$\" | sort -u${color_reset}"
        if safe_output shosubgo shosubgo.txt -d "$DOMAIN" -s "$SHODAN_KEY"; then
            grep -Ei "(^|\.)${DOMAIN_ESCAPED}$" shosubgo.txt | sort -u -o shosubgo.txt
        else
            echo -e "${color_red}[!] shosubgo failed. Preserving previous shosubgo.txt if any.${color_reset}"
        fi
    fi
fi

if [ "$START_PHASE" -le 2 ]; then
    if [[ "$use_dns_brute" == "y" ]]; then
        echo -e "\n${color_yellow}=== [Phase 2] Active DNS Bruteforcing (Root Domain) ===${color_reset}"
        echo -e ""
        echo -e "${color_cyan}[~]$ puredns bruteforce $DNS_WORDLIST $DOMAIN${color_reset}"
        W="$DNS_WORDLIST"; R="resolvers.txt"; RT="trusted-resolvers.txt"; D="$DOMAIN"
        PUREDNS_OPTS=(-r "$R" --resolvers-trusted "$RT" --wildcard-tests 5 --wildcard-batch 1000000 --rate-limit 2000)
        temp_active=$(mktemp)
        if puredns bruteforce "$W" "$D" "${PUREDNS_OPTS[@]}" -w "$temp_active"; then
            mv "$temp_active" active-subs.txt
            echo -e "${color_green}[+] DNS Bruteforce done. $(wc -l < active-subs.txt) hosts resolved.${color_reset}"
        else
            rm -f "$temp_active"
            echo -e "${color_red}[!] puredns failed. Preserving previous active-subs.txt if any.${color_reset}"
        fi
        [ -f active-subs.txt ] || touch active-subs.txt
    fi

    echo -e ""
    echo -e "${color_cyan}[*] Merging all discovered subdomains safely...${color_reset}"
    {
        [ -f subfinder.txt ] && cat subfinder.txt
        [ -f assetfinder.txt ] && cat assetfinder.txt
        [ -f findomain.txt ] && cat findomain.txt
        [ -f github-subs.txt ] && cat github-subs.txt
        [ -f shosubgo.txt ] && cat shosubgo.txt
    } | sort -u > passive-subs.txt

    {
        [ -f passive-subs.txt ] && cat passive-subs.txt
        [ -f active-subs.txt ] && cat active-subs.txt
    } | sort -u > all-subs.txt
    
    echo -e "${color_green}[+] Total Unique Subdomains: $(wc -l < all-subs.txt 2>/dev/null || echo 0) ${color_reset}"
    cat all-subs.txt
    notify_webhook "Phase 1-2 done — $(wc -l < all-subs.txt 2>/dev/null || echo 0) unique subdomains found."
fi

if [ "$START_PHASE" -le 3 ]; then
    echo -e "\n${color_yellow}=== [Phase 3] Live Probing >> httpx ===${color_reset}"
    echo -e ""
    if [ ! -s all-subs.txt ]; then
        echo -e "${color_red}[!] Prerequisite missing: all-subs.txt${color_reset}"
        echo -e "${color_yellow}[*] Phase 3 requires Phase 1 & 2 to be completed. Skipping httpx.${color_reset}"
    else
        if [ -x "$HOME/go/bin/httpx" ]; then
            HTTPX_BIN="$HOME/go/bin/httpx"
        else
            HTTPX_BIN="httpx"
        fi
        temp_httpx=$(mktemp)
        echo -e "${color_cyan}[~]$ cat all-subs.txt | $HTTPX_BIN -silent -threads 50 -rate-limit 150 -status-code -tech-detect -title -location${color_reset}"
        if cat all-subs.txt | "$HTTPX_BIN" -silent -threads 50 -rate-limit 150 -status-code -tech-detect -title -location "${HTTPX_AUTH_ARGS[@]}" > "$temp_httpx"; then
            cat "$temp_httpx"
            awk '{print $1}' "$temp_httpx" > live-URLs.txt.tmp && mv live-URLs.txt.tmp live-URLs.txt
            rm -f "$temp_httpx"
        else
            rm -f "$temp_httpx"
            echo -e "${color_red}[!] httpx failed. Preserving previous live-URLs.txt if any.${color_reset}"
        fi
    fi
    notify_webhook "Phase 3 done — $(wc -l < live-URLs.txt 2>/dev/null || echo 0) live hosts found."
fi

if [ "$START_PHASE" -le 4 ]; then
    echo -e "\n${color_yellow}=== [Phase 4] Crawling >> gau & katana ===${color_reset}"
    echo -e ""

    temp_gau=$(mktemp)
    echo -e "${color_cyan}[~]$ gau --subs --threads 10 $DOMAIN | grep -E -v '\.(jpg|jpeg|gif|css|tif|tiff|png|ttf|woff|woff2|ico|svg|eot)(\?|$)' | sort -u${color_reset}"
    if gau --subs --threads 10 "$DOMAIN" > "$temp_gau"; then
        grep -E -v '\.(jpg|jpeg|gif|css|tif|tiff|png|ttf|woff|woff2|ico|svg|eot)(\?|$)' "$temp_gau" | sort -u > gauURLs-passive.txt
        rm -f "$temp_gau"
    else
        rm -f "$temp_gau"
        echo -e "${color_red}[!] gau failed. Preserving previous gauURLs-passive.txt if any.${color_reset}"
    fi

    if [ ! -s live-URLs.txt ]; then
        echo -e "${color_red}[!] Prerequisite missing: live-URLs.txt${color_reset}"
        echo -e "${color_yellow}[*] Phase 4 Katana crawling requires Phase 3 to be completed. Skipping Katana.${color_reset}"
    else
        temp_katana=$(mktemp)
        echo -e ""
        echo -e "${color_cyan}[~]$ katana -list live-URLs.txt -d 3 -timeout 15 -jc -kf all -rl 20 -c 10 -silent -fr \"\$LOGOUT_EXCLUDE_REGEX\"${color_reset}"
        if command -v timeout &>/dev/null; then
            if timeout 1800 katana -list live-URLs.txt -d 3 -timeout 15 -jc -kf all -rl 20 -c 10 -silent -fr "$LOGOUT_EXCLUDE_REGEX" "${KATANA_AUTH_ARGS[@]}" > "$temp_katana"; then
                mv "$temp_katana" katanaURLs_active.txt
            else
                rm -f "$temp_katana"
                echo -e "${color_red}[!] katana failed. Preserving previous katanaURLs_active.txt if any.${color_reset}"
            fi
        else
            if katana -list live-URLs.txt -d 3 -timeout 15 -jc -kf all -rl 20 -c 10 -silent -fr "$LOGOUT_EXCLUDE_REGEX" "${KATANA_AUTH_ARGS[@]}" > "$temp_katana"; then
                mv "$temp_katana" katanaURLs_active.txt
            else
                rm -f "$temp_katana"
                echo -e "${color_red}[!] katana failed. Preserving previous katanaURLs_active.txt if any.${color_reset}"
            fi
        fi
    fi
fi

if [ "$START_PHASE" -le 5 ]; then
    echo -e "\n${color_yellow}=== [Phase 5] Smart Filtering ===${color_reset}"
    echo -e ""
    
    {
        [ -f gauURLs-passive.txt ] && cat gauURLs-passive.txt
        [ -f katanaURLs_active.txt ] && cat katanaURLs_active.txt
    } | sort -u > all-URLs-temp.txt

    if [ -s all-URLs-temp.txt ] && command -v uro &> /dev/null; then
        echo -e "${color_cyan}[*] Deduplicating URLs with uro...${color_reset}"
        before_count=$(wc -l < all-URLs-temp.txt)
        if uro -i all-URLs-temp.txt -o all-URLs-temp.uro.txt 2>/dev/null; then
            mv all-URLs-temp.uro.txt all-URLs-temp.txt
            echo -e "${color_green}[+] URLs reduced from $before_count to $(wc -l < all-URLs-temp.txt).${color_reset}"
        else
            echo -e "${color_yellow}[!] uro failed; continuing with unfiltered URLs.${color_reset}"
        fi
    fi

    if [ -s all-URLs-temp.txt ]; then
        echo -e "${color_cyan}[*] Extracting In-Scope URLs...${color_reset}"
        grep -E "https?://([a-zA-Z0-9-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" all-URLs-temp.txt | sort -u > all-URLs.txt
        grep -E -v "https?://([a-zA-Z0-9-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" all-URLs-temp.txt | sort -u > external-URLs.txt

        inscope_count=$(wc -l < all-URLs.txt 2>/dev/null || echo 0)
        external_count=$(wc -l < external-URLs.txt 2>/dev/null || echo 0)
        echo -e "${color_green}[+] In-scope URLs: $inscope_count | External URLs: $external_count${color_reset}"

        if [ "$inscope_count" -eq 0 ]; then
            echo -e "${color_red}[!] Warning: No in-scope URLs were extracted. Check if gau/katana produced valid URLs.${color_reset}"
        fi

        rm -f all-URLs-temp.txt

        echo -e "${color_cyan}[*] Extracting Parameters, JS, APIs, and Sensitive Files...${color_reset}"
        cat all-URLs.txt | grep '=' | grep -E -v '\.(css|js|jpg|png|svg|ico)(\?|$)' | sort -u > URLs_with_params.txt.tmp && mv URLs_with_params.txt.tmp URLs_with_params.txt
        cat all-URLs.txt | grep -E "\.js(\?|$)" | sort -u > js_files.txt.tmp && mv js_files.txt.tmp js_files.txt
        cat all-URLs.txt | grep -E "\.(xls|xml|xlsx|json|pdf|sql|doc|docx|pptx|txt|zip|tar\.gz|tgz|bak|7z|rar|log|cache|secret|db|backup|yml|gz|config|csv|yaml|md|md5|tar|xz|7zip|p12|pem|key|crt|csr|sh|pl|py|java|class|jar|war|ear|sqlitedb|sqlite3|dbf|db3|accdb|mdb|sqlcipher|gitignore|env|ini|conf|properties|plist|cfg)(\?|$)" | sort -u > sensitiveFiles.txt.tmp && mv sensitiveFiles.txt.tmp sensitiveFiles.txt
        cat all-URLs.txt | grep -E "\b(api|v[0-9]+|graphql|rest|endpoint|ajax)\b" | grep -E -v "\.(css|js)(\?|$)" | sort -u > api_endpoints.txt.tmp && mv api_endpoints.txt.tmp api_endpoints.txt
    else
        echo -e "${color_red}[!] No URLs found to filter.${color_reset}"
    fi
fi

if [ "$START_PHASE" -le 6 ] && [[ "$use_fuzzing" == "y" ]]; then
    mkdir -p fuzz_params fuzz_dirs

    if [ -s "$DIR_WORDLIST" ]; then
        if command -v shuf &>/dev/null; then
            shuf "$DIR_WORDLIST" -o dir_wordlist.shuffled.txt
        else
            sort -R "$DIR_WORDLIST" -o dir_wordlist.shuffled.txt 2>/dev/null || cp "$DIR_WORDLIST" dir_wordlist.shuffled.txt
        fi
        DIR_WORDLIST="dir_wordlist.shuffled.txt"
    fi

    echo -e "\n${color_yellow}=== [Phase 6.A] Parameter Discovery >> Arjun ===${color_reset}"
    echo -e ""
    if command -v arjun &> /dev/null; then
        if [ -s api_endpoints.txt ]; then
            ARJUN_HEADER_ARGS=()
            if [ -n "$ARJUN_AUTH_HEADER" ]; then
                ARJUN_HEADER_ARGS=(--headers "$(printf '%b' "$ARJUN_AUTH_HEADER")")
            fi
            ARJUN_WORDLIST_ARG=()
            if [ -n "$PARAM_WORDLIST" ] && [ -f "$PARAM_WORDLIST" ]; then
                ARJUN_WORDLIST_ARG=(-w "$PARAM_WORDLIST")
                echo -e "${color_cyan}[~]$ arjun -i api_endpoints.txt -w $PARAM_WORDLIST -oT fuzz_params/arjun_results.txt -t 5 -d 1${color_reset}"
            else
                echo -e "${color_cyan}[~]$ arjun -i api_endpoints.txt -oT fuzz_params/arjun_results.txt -t 5 -d 1${color_reset}"
            fi
            if arjun -i api_endpoints.txt "${ARJUN_WORDLIST_ARG[@]}" -oT fuzz_params/arjun_results.txt -t 5 -d 1 "${ARJUN_HEADER_ARGS[@]}" >/dev/null 2>&1; then
                [ -f fuzz_params/arjun_results.txt ] && echo -e "${color_green}[+] Arjun found $(wc -l < fuzz_params/arjun_results.txt) hidden parameter(s).${color_reset}"
            else
                echo -e "${color_yellow}[!] arjun failed. Preserving previous results if any.${color_reset}"
            fi
        else
            echo -e "${color_red}[!] api_endpoints.txt is empty! Skipping parameter discovery.${color_reset}"
        fi
    else
        echo -e "${color_yellow}[!] arjun is not installed, skipping parameter discovery.${color_reset}"
    fi

    echo -e "\n${color_yellow}=== [Phase 6.B] Stealth Fuzzing >> ffuf > Dir ===${color_reset}"
    echo -e ""
    if [ -s live-URLs.txt ]; then
        awk -F/ '{print $1"//"$3}' live-URLs.txt | sort -u > unique_base_urls.txt
        total_hosts=$(wc -l < unique_base_urls.txt)
        counter=1
        while read -r clean_url; do
            [ -z "$clean_url" ] && continue
            echo -e "${color_cyan}[ $counter / $total_hosts ] Fuzzing Dirs: $clean_url${color_reset}"
            RANDOM_UA=${UAS[$RANDOM % ${#UAS[@]}]}
            dir_report="fuzz_dirs/dir_fuzz_$(echo "$clean_url" | md5_hash).json"
            ffuf -u "$clean_url/FUZZ" \
                 -w "$DIR_WORDLIST" \
                 -mc 200,301,302,307,401,405 \
                 -fc 403,404,473,500,502 \
                 -ac -ic -sa -sf -rate 5 -p "0.1-0.5" \
                 -e .html,.php,.txt,.bak,.zip,.json,.config,.env,.sql \
                 -H "User-Agent: $RANDOM_UA" \
                 -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
                 -H "Accept-Language: en-US,en;q=0.5" \
                 "${FFUF_AUTH_ARGS[@]}" \
                 -o "$dir_report"
            ((counter++))
        done < unique_base_urls.txt
        rm -f unique_base_urls.txt
    else
         echo -e "${color_red}[!] live-URLs.txt is empty! Skipping directory fuzzing.${color_reset}"
    fi
fi

JS_SESSION_DIR=""
JS_OUTPUT_DIR=""
JS_FORMATTED_DIR=""
JS_GREP_DIR=""
JS_MAPS_DIR=""
JS_URL_MAP_FILE=""

if [ "$START_PHASE" -le 7 ]; then
    if [ ! -s "$SESSION_DIR/js_files.txt" ]; then
        echo -e "\n${color_red}[!] Prerequisite missing: js_files.txt${color_reset}"
        echo -e "${color_yellow}[*] JavaScript Analysis requires Phase 4 (Crawling) and Phase 5 (Smart Filtering) to be completed.${color_reset}"
        echo -e "${color_yellow}[*] Skipping Phase 7.${color_reset}"
    else
        EXISTING_JS_SESSION=$(find "$SESSION_DIR" -maxdepth 1 -type d -name 'JS_Scan_*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
        [ -z "$EXISTING_JS_SESSION" ] && EXISTING_JS_SESSION=$(ls -td "$SESSION_DIR"/JS_Scan_* 2>/dev/null | head -1)
        
        if [ -n "$EXISTING_JS_SESSION" ] && [ -d "$EXISTING_JS_SESSION" ]; then
            JS_SESSION_DIR="$EXISTING_JS_SESSION"
            echo -e "${color_cyan}[*] Resuming existing JS Analysis Session: ${color_yellow}$JS_SESSION_DIR${color_reset}"
        else
            JS_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
            JS_SESSION_DIR="$SESSION_DIR/JS_Scan_$JS_TIMESTAMP"
            echo -e "${color_cyan}[*] Initializing new JS Analysis Session: ${color_yellow}$JS_SESSION_DIR${color_reset}"
        fi
        
        JS_OUTPUT_DIR="$JS_SESSION_DIR/js_files"
        JS_FORMATTED_DIR="$JS_SESSION_DIR/js_formatted"
        JS_GREP_DIR="$JS_SESSION_DIR/js_grep_results"
        JS_MAPS_DIR="$JS_SESSION_DIR/recovered_sources"
        JS_URL_MAP_FILE="$JS_SESSION_DIR/url_mapping.txt"
        MAP_PARTS_DIR="$JS_SESSION_DIR/map_parts"

        mkdir -p "$JS_OUTPUT_DIR" "$JS_FORMATTED_DIR" "$JS_GREP_DIR" "$JS_MAPS_DIR" "$MAP_PARTS_DIR"
        touch "$JS_URL_MAP_FILE"

        js_check_dependencies() {
            local deps=("curl" "grep" "awk" "sed")
            for dep in "${deps[@]}"; do
                if ! command -v "$dep" &> /dev/null; then
                    echo -e "${color_red}[!] Critical Error: Required dependency '$dep' is not installed.${color_reset}"
                    exit 1
                fi
            done
            if ! command -v jq &> /dev/null; then
                echo -e "${color_yellow}[!] jq not found. TruffleHog JSON parsing will be skipped.${color_reset}"
            fi
        }

        js_fetch_url() {
            local url="$1"
            local output_dir="$2"
            local map_file="$3"
            local map_parts_dir="$4"
            local safe_name
            safe_name=$(printf '%s' "$url" | md5_hash)
            local part_file="$output_dir/$safe_name.js"
            
            local temp_file
            temp_file=$(mktemp "${part_file}.tmp.XXXXXX") || return 1
            
            sleep "0.$((RANDOM % 5))"
            local ua_arr
            IFS='|' read -ra ua_arr <<< "$UA_POOL"
            local req_ua="${ua_arr[$RANDOM % ${#ua_arr[@]}]}"

            local curl_tls_args=()
            [[ "${ALLOW_INSECURE:-n}" == "y" ]] && curl_tls_args=(-k)

            local curl_auth_args=()
            if [ -n "$AUTH_COOKIE" ]; then curl_auth_args+=(-H "Cookie: $AUTH_COOKIE"); fi
            if [ -n "$AUTH_HEADERS_STR" ]; then
                while IFS= read -r h; do
                    [ -n "$h" ] && curl_auth_args+=(-H "$h")
                done <<< "$AUTH_HEADERS_STR"
            fi

            if [ -s "$part_file" ]; then
                http_code=$(curl -s -L -m 15 "${curl_tls_args[@]}" "${curl_auth_args[@]}" --max-filesize 5242880 --retry 3 --retry-delay 2 -A "$req_ua" -z "$part_file" -w "%{http_code}" -o "$temp_file" "$url" 2>/dev/null)
                curl_rc=$?
            else
                http_code=$(curl -s -L -m 15 "${curl_tls_args[@]}" "${curl_auth_args[@]}" --max-filesize 5242880 --retry 3 --retry-delay 2 -A "$req_ua" -w "%{http_code}" -o "$temp_file" "$url" 2>/dev/null)
                curl_rc=$?
            fi

            if [ "$curl_rc" -ne 0 ]; then
                rm -f "$temp_file"
                echo -e "${color_red}[-] Failed (curl exit $curl_rc):${color_reset} $url"
                return 1
            fi

            case "$http_code" in
                200)
                    if [ -s "$temp_file" ]; then
                        mv "$temp_file" "$part_file"
                        echo "$safe_name.js|$url" > "$map_parts_dir/$safe_name"
                        echo -e "${color_green}[+] Downloaded:${color_reset} $url"
                        return 0
                    else
                        rm -f "$temp_file"
                        echo -e "${color_red}[-] Empty response:${color_reset} $url"
                        return 1
                    fi
                    ;;
                304)
                    if [ -s "$part_file" ]; then
                        rm -f "$temp_file"
                        echo "$safe_name.js|$url" > "$map_parts_dir/$safe_name"
                        echo -e "${color_green}[+] Cached (304):${color_reset} $url"
                        return 0
                    else
                        rm -f "$temp_file"
                        echo -e "${color_red}[-] 304 but no local file:${color_reset} $url"
                        return 1
                    fi
                    ;;
                *)
                    rm -f "$temp_file"
                    echo -e "${color_red}[-] Failed (HTTP $http_code):${color_reset} $url"
                    return 1
                    ;;
            esac
        }

        js_recover_source_maps() {
            echo -e "\n${color_yellow}[>] Checking for exposed Source Maps (.js.map) & recovering source trees...${color_reset}"
            local map_file="$JS_GREP_DIR/source_maps.txt"
            [ -f "$map_file" ] || return 0
            while IFS= read -r line; do
                local file_part="${line%%:*}"
                local rest="${line#*:}"
                local line_num="${rest%%:*}"
                local map_url="${rest#*:}"
                local original_url=""
                [ -f "$JS_URL_MAP_FILE" ] && original_url=$(grep "^${file_part}|" "$JS_URL_MAP_FILE" | head -n 1 | cut -d'|' -f2)

                local full_map_url=""
                if [[ "$map_url" == "//"* ]]; then
                    local proto="${original_url%%:*}"
                    full_map_url="${proto}:${map_url}"
                elif [[ "$map_url" =~ ^https?:// ]]; then
                    full_map_url="$map_url"
                elif [ -n "$original_url" ]; then
                    local proto="${original_url%%://*}"
                    local url_rest="${original_url#*://}"
                    local host_port="${url_rest%%/*}"
                    local path_part="${url_rest#*/}"
                    [ "$path_part" = "$url_rest" ] && base_path="/" || base_path="/$path_part"
                    base_path="${base_path%%\?*}"; base_path="${base_path%%#*}"
                    if [[ "$map_url" == /* ]]; then
                        full_map_url="${proto}://${host_port}${map_url}"
                    else
                        local dir="${base_path%/*}"
                        [ "$dir" = "$base_path" ] && dir=""
                        local result="$dir"
                        local IFS='/'
                        read -ra parts <<< "$map_url"
                        for part in "${parts[@]}"; do
                            if [ "$part" = ".." ]; then result="${result%/*}"; [ -z "$result" ] && result="/"
                            elif [ "$part" = "." ] || [ -z "$part" ]; then continue
                            else
                                if [ "$result" = "/" ] || [ -z "$result" ]; then result="/$part"; else result="$result/$part"; fi
                            fi
                        done
                        result="${result//\/\//\/}"
                        full_map_url="${proto}://${host_port}${result}"
                    fi
                else
                    continue
                fi

                if [[ "$full_map_url" =~ ^https?:// ]]; then
                    local safe_name
                    safe_name=$(printf '%s' "$full_map_url" | md5_hash)
                    echo -e "${color_green}[+] Recovering source map: $full_map_url${color_reset}"
                    local curl_tls_args=()
                    [[ "${ALLOW_INSECURE:-n}" == "y" ]] && curl_tls_args=(-k)
                    local curl_auth_args=()
                    [ -n "$AUTH_COOKIE" ] && curl_auth_args+=(-H "Cookie: $AUTH_COOKIE")
                    if [ -n "$AUTH_HEADERS_STR" ]; then
                        while IFS= read -r h; do [ -n "$h" ] && curl_auth_args+=(-H "$h"); done <<< "$AUTH_HEADERS_STR"
                    fi
                    local temp_map_file=$(mktemp "${JS_MAPS_DIR}/${safe_name}.map.tmp.XXXXXX") || continue
                    local map_http_code=$(curl -s -L -m 15 "${curl_tls_args[@]}" "${curl_auth_args[@]}" --max-filesize 5242880 -w "%{http_code}" -o "$temp_map_file" "$full_map_url" 2>/dev/null)
                    if [ "$map_http_code" = "200" ] && [ -s "$temp_map_file" ]; then
                        mv "$temp_map_file" "${JS_MAPS_DIR}/${safe_name}.map"
                    else
                        rm -f "$temp_map_file"
                        echo -e "${color_red}[-] Source map fetch failed (HTTP $map_http_code):${color_reset} $full_map_url"
                    fi
                fi
            done < "$map_file"
        }

        js_safe_grep() {
            local msg="$1" regex="$2" outfile="$3" exclude="${4:-}"
            echo -e "${color_yellow}[>] $msg...${color_reset}"
            if [ -z "$exclude" ]; then
                (cd "$O" && grep -a -r -n -P -o -e "$regex" . | sed 's|^\./||' | sort -u > "$R/$outfile" || true)
            else
                (cd "$O" && grep -a -r -n -P -o -e "$regex" . | grep -v -i -P -e "$exclude" | sed 's|^\./||' | sort -u > "$R/$outfile" || true)
            fi
        }

        js_hunt_ip_addresses() {
            local O="$JS_FORMATTED_DIR" R="$JS_GREP_DIR"
            local regex='[\x22\x27](?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])[\x22\x27]'
            echo -e "${color_yellow}[>] Hunting for IP Addresses...${color_reset}"
            if command -v perl &>/dev/null; then
                (cd "$O" && grep -a -r -n -i -P -e "$regex" . \
                    | grep -v -i -P '(version|semver|"v"\s*:|release)' \
                    | sed 's|^\./||' \
                    | perl -ne 'if (/(.*?):(\d+):(.*)/) { my ($f,$l,$c)=($1,$2,$3); while ($c =~ /(((?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9]))/g) { print "$f:$l:$1\n" } }' \
                    | grep -v -E ':(127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.255)$' \
                    | sort -u > "$R/ip_addresses.txt" || true)
            else
                echo -e "${color_yellow}[!] perl not found, skipping IP extraction.${color_reset}"
                > "$R/ip_addresses.txt"
            fi
        }

        js_run_trufflehog() {
            local O="$JS_OUTPUT_DIR" R="$JS_GREP_DIR"
            if ! command -v trufflehog &> /dev/null; then
                echo -e "${color_yellow}[!] trufflehog not installed — skipping verified-secret scan.${color_reset}"
                > "$R/cloud_tokens.txt"; > "$R/auth_tokens.txt"; > "$R/rsa_keys.txt"; > "$R/generic_secrets.txt"
                return 0
            fi
            echo -e "\n${color_cyan}[*] TruffleHog Verified Secret Scan${color_reset}"
            local raw_tmp="$R/trufflehog_raw.tmp"
            if trufflehog filesystem "$O" --json > "$raw_tmp" 2>/dev/null; then
                if [ -s "$raw_tmp" ] && command -v jq &> /dev/null; then
                    > "$R/cloud_tokens.txt.tmp"; > "$R/auth_tokens.txt.tmp"; > "$R/rsa_keys.txt.tmp"; > "$R/generic_secrets.txt.tmp"
                    while IFS=$'\t' read -r detector verified file line raw; do
                        [ -z "$detector" ] && continue
                        file_short=$(basename "${file:-unknown}")
                        line_num="${line:-"-"}"
                        tag="[unverified]"; [ "$verified" = "true" ] && tag="[VERIFIED]"
                        raw_redacted=$(redact_secret_value "$raw")
                        line_out="${file_short}:${line_num}:${tag} ${detector} => ${raw_redacted}"
                        case "$detector" in
                            AWS|GCP|Slack|Stripe|Github*|GitHub*|Twilio|SendGrid|Mailgun) echo "$line_out" | cut -c 1-250 >> "$R/cloud_tokens.txt.tmp" ;;
                            JWT|*Bearer*) echo "$line_out" | cut -c 1-250 >> "$R/auth_tokens.txt.tmp" ;;
                            PrivateKey|RSA*) echo "$line_out" | cut -c 1-250 >> "$R/rsa_keys.txt.tmp" ;;
                            *) echo "$line_out" | cut -c 1-250 >> "$R/generic_secrets.txt.tmp" ;;
                        esac
                    done < <(jq -r '[.SourceMetadata.Data.Filesystem.file // "unknown", (.SourceMetadata.Data.Filesystem.line // "-"), (.Verified // false | tostring), .DetectorName, (.Raw // "" | .[0:80])] | @tsv' "$raw_tmp" 2>/dev/null | awk -F'\t' '{print $4"\t"$3"\t"$1"\t"$2"\t"$5}')
                    mv "$raw_tmp" "$R/trufflehog_raw.json"
                    mv "$R/cloud_tokens.txt.tmp" "$R/cloud_tokens.txt"
                    mv "$R/auth_tokens.txt.tmp" "$R/auth_tokens.txt"
                    mv "$R/rsa_keys.txt.tmp" "$R/rsa_keys.txt"
                    mv "$R/generic_secrets.txt.tmp" "$R/generic_secrets.txt"
                else
                    rm -f "$raw_tmp"
                    echo -e "${color_yellow}[!] TruffleHog parsing skipped (jq missing or empty raw).${color_reset}"
                fi
            else
                rm -f "$raw_tmp"
                echo -e "${color_red}[!] TruffleHog scan failed. Preserving previous findings if any.${color_reset}"
            fi
            echo -e "${color_green}[+] TruffleHog scan complete.${color_reset}"
        }

        js_run_static_analysis() {
            local O="$JS_FORMATTED_DIR" R="$JS_GREP_DIR"
            js_safe_grep "Hidden paths" '(?<=[\x22\x27])/?(api|admin|v[0-9]|internal|graphql|dev|staging|auth|login|users|config|payment|upload|download)/[a-zA-Z0-9_/?=&.-]*(?=[\x22\x27])' "hidden_paths.txt"
            js_safe_grep "External URLs" 'https?://[a-zA-Z0-9./?=_-]+' "all_urls.txt" '(w3\.org|react\.dev|nextjs\.org|schema\.org|localhost|github\.com|npmjs\.com|mozilla\.org)'
            js_safe_grep "WebSockets" 'wss?://[a-zA-Z0-9./?=_-]+' "websockets.txt"
            js_safe_grep "Firebase/Supabase" '[a-zA-Z0-9.-]+\.(firebaseio\.com|supabase\.co|appwrite\.io)' "baas_urls.txt"
            js_safe_grep "Basic Auth URLs" 'https?://[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+@[a-zA-Z0-9.-]+' "basic_auth.txt"
            js_hunt_ip_addresses
            js_safe_grep "S3 Buckets" '([a-z0-9.-]+\.s3-[a-z0-9-]+\.amazonaws\.com|[a-z0-9.-]+\.s3\.amazonaws\.com|s3://[a-zA-Z0-9.-]+)' "s3_buckets.txt"
            js_safe_grep "Emails" '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "emails.txt" '(sentry\.io)'
            js_safe_grep "DOM XSS sinks" '(innerHTML|outerHTML|document\.write|eval|setTimeout|setInterval)\s*[\(|=]' "dom_sinks.txt"
            js_safe_grep "Dev comments" '(?<=//|/\*)\s*(TODO|FIXME|HACK|BUG|XXX)[^\n\r]{0,100}' "dev_comments.txt"
            js_safe_grep "UUIDs" '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b' "uuids.txt" '(00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)'
            js_safe_grep "OAuth IDs" '(?i)(client_id|client_secret|app_id|app_secret|tenant_id)[\x22\x27\s]*[:=][\x22\x27\s]*[a-zA-Z0-9\-_]{10,}' "oauth_configs.txt" '(function|undefined|null|true|false)'
            js_safe_grep "GraphQL queries" '(query|mutation)\s+[a-zA-Z0-9_]+\s*\{' "graphql.txt"
            js_safe_grep "Source maps" '(?<=//# sourceMappingURL=)[a-zA-Z0-9_./-]+\.map' "source_maps.txt"
            js_run_trufflehog
            js_recover_source_maps
        }

        js_beautify_files() {
            local beautifier=""
            local PRETTIER_BIN=$(command -v prettier 2>/dev/null || true)
            if [ -n "$PRETTIER_BIN" ]; then beautifier="prettier"
            elif command -v js-beautify &>/dev/null; then beautifier="js-beautify"
            elif npx --no-install prettier --version &>/dev/null 2>&1; then beautifier="npx-prettier"
            else echo -e "${color_yellow}[!] Neither prettier nor js-beautify found — skipping beautification.${color_reset}"; return 0; fi

            local total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 4194304)
            local PARALLEL_WORKERS=4
            [ "$total_mem_kb" -lt 1572864 ] && PARALLEL_WORKERS=1
            [ "$total_mem_kb" -ge 1572864 ] && [ "$total_mem_kb" -lt 4194304 ] && PARALLEL_WORKERS=2
            local node_mem_mb=$(( total_mem_kb / 1024 * 75 / 100 / PARALLEL_WORKERS ))
            [ "$node_mem_mb" -lt 256 ] && node_mem_mb=256
            [ "$node_mem_mb" -gt 1024 ] && node_mem_mb=1024
            export NODE_OPTIONS="--max-old-space-size=${node_mem_mb}"

            find "$JS_OUTPUT_DIR" -type f -name "*.js" -size -5120k -print0 \
                | xargs -0 -r -P "$PARALLEL_WORKERS" -I {} sh -c 'f="$1"; out="$2/$(basename "$f")"; "$0" --parser babel "$f" > "$out" 2>/dev/null' "$PRETTIER_BIN" {} "$JS_FORMATTED_DIR"
        }

        run_js_analysis() {
            js_check_dependencies
            JS_FILE_PATH="$SESSION_DIR/js_files.txt"
            [ -s "$JS_FILE_PATH" ] || return 0

            export JS_OUTPUT_DIR JS_FORMATTED_DIR JS_URL_MAP_FILE JS_MAPS_DIR MAP_PARTS_DIR
            export UA_POOL ALLOW_INSECURE AUTH_COOKIE AUTH_HEADERS_STR
            printf -v UA_POOL '%s|' "${UAS[@]}"
            export -f js_fetch_url md5_hash redact_secret_value

            total_urls=$(awk 'NF' "$JS_FILE_PATH" | wc -l)
            echo -e "\n${color_yellow}[*] Fetching $total_urls JS files...${color_reset}"
            tr -d '\r' < "$JS_FILE_PATH" | awk 'NF' | xargs -P 5 -I {} bash -c 'js_fetch_url "$1" "$2" "$3" "$4"' _ {} "$JS_OUTPUT_DIR" "$JS_URL_MAP_FILE" "$MAP_PARTS_DIR"

            if [ -d "$MAP_PARTS_DIR" ] && [ "$(ls -A "$MAP_PARTS_DIR" 2>/dev/null)" ]; then
                cat "$MAP_PARTS_DIR"/* 2>/dev/null | sort -u > "$JS_URL_MAP_FILE.tmp" && mv "$JS_URL_MAP_FILE.tmp" "$JS_URL_MAP_FILE"
                rm -f "$MAP_PARTS_DIR"/*
            fi

            js_beautify_files
            js_run_static_analysis
        }

        run_js_analysis
    fi
fi

rm -f resolvers.txt trusted-resolvers.txt param_wordlist.shuffled.txt dir_wordlist.shuffled.txt

C_SUBS=$(wc -l < all-subs.txt 2>/dev/null || echo 0)
C_LIVE=$(wc -l < live-URLs.txt 2>/dev/null || echo 0)
C_URLS=$(wc -l < all-URLs.txt 2>/dev/null || echo 0)
C_PARAMS=$(wc -l < URLs_with_params.txt 2>/dev/null || echo 0)
C_JS=$(wc -l < js_files.txt 2>/dev/null || echo 0)
C_APIS=$(wc -l < api_endpoints.txt 2>/dev/null || echo 0)
C_SENS=$(wc -l < sensitiveFiles.txt 2>/dev/null || echo 0)

js_count_lines() { local file="$JS_GREP_DIR/$1"; [ -f "$file" ] && wc -l < "$file" || echo 0; }
JS_C_PATHS=$(js_count_lines "hidden_paths.txt"); JS_C_IPS=$(js_count_lines "ip_addresses.txt"); JS_C_S3=$(js_count_lines "s3_buckets.txt"); JS_C_EMAILS=$(js_count_lines "emails.txt"); JS_C_OAUTH=$(js_count_lines "oauth_configs.txt"); JS_C_CLOUD=$(js_count_lines "cloud_tokens.txt"); JS_C_AUTH=$(js_count_lines "auth_tokens.txt"); JS_C_RSA=$(js_count_lines "rsa_keys.txt"); JS_C_SECRETS=$(js_count_lines "generic_secrets.txt"); JS_C_GQL=$(js_count_lines "graphql.txt"); JS_C_SINKS=$(js_count_lines "dom_sinks.txt"); JS_C_WS=$(js_count_lines "websockets.txt"); JS_C_BAAS=$(js_count_lines "baas_urls.txt"); JS_C_BAUTH=$(js_count_lines "basic_auth.txt"); JS_C_DEV=$(js_count_lines "dev_comments.txt"); JS_C_UUID=$(js_count_lines "uuids.txt"); JS_C_URLS=$(js_count_lines "all_urls.txt"); JS_C_MAPS=$(js_count_lines "source_maps.txt")
JS_TOTAL_FINDINGS=$((JS_C_PATHS + JS_C_IPS + JS_C_S3 + JS_C_EMAILS + JS_C_OAUTH + JS_C_CLOUD + JS_C_AUTH + JS_C_RSA + JS_C_SECRETS + JS_C_GQL + JS_C_SINKS + JS_C_WS + JS_C_BAAS + JS_C_BAUTH + JS_C_DEV + JS_C_UUID + JS_C_URLS + JS_C_MAPS))

PRIORITY_TSV="priority_targets.tsv"
> "$PRIORITY_TSV"

add_priority() { local score="$1" reason="$2" file="$3"; [ -s "$file" ] || return 0; while IFS= read -r target; do [ -z "$target" ] && continue; printf "%s\t%s\t%s\n" "$score" "$target" "$reason" >> "$PRIORITY_TSV"; done < "$file"; }
add_priority_verified() { local vs="$1" us="$2" rv="$3" ru="$4" file="$5"; [ -s "$file" ] || return 0; while IFS= read -r target; do [ -z "$target" ] && continue; if [[ "$target" == *"[VERIFIED]"* ]]; then printf "%s\t%s\t%s\n" "$vs" "$target" "$rv" >> "$PRIORITY_TSV"; else printf "%s\t%s\t%s\n" "$us" "$target" "$ru" >> "$PRIORITY_TSV"; fi; done < "$file"; }

if [ -n "$JS_GREP_DIR" ] && [ -d "$JS_GREP_DIR" ]; then
    add_priority_verified 100 30 "RSA private key — VERIFIED" "RSA candidate" "$JS_GREP_DIR/rsa_keys.txt"
    add_priority_verified 90 30 "Cloud/SaaS key — VERIFIED" "Cloud candidate" "$JS_GREP_DIR/cloud_tokens.txt"
    add_priority_verified 85 30 "JWT/Bearer — VERIFIED" "JWT candidate" "$JS_GREP_DIR/auth_tokens.txt"
    add_priority_verified 50 20 "Generic secret — VERIFIED" "Generic candidate" "$JS_GREP_DIR/generic_secrets.txt"
    add_priority 85 "Basic auth URL" "$JS_GREP_DIR/basic_auth.txt"
    add_priority 60 "BaaS reference" "$JS_GREP_DIR/baas_urls.txt"
    add_priority 55 "S3 bucket" "$JS_GREP_DIR/s3_buckets.txt"
    add_priority 40 "OAuth IDs" "$JS_GREP_DIR/oauth_configs.txt"
    add_priority 35 "Source map" "$JS_GREP_DIR/source_maps.txt"
    add_priority 30 "Hidden paths" "$JS_GREP_DIR/hidden_paths.txt"
    add_priority 25 "GraphQL" "$JS_GREP_DIR/graphql.txt"
fi
add_priority 45 "Sensitive file" sensitiveFiles.txt
if [ -s all-subs.txt ]; then grep -E '^(dev|staging|stage|test|uat|qa|internal|admin|beta|preprod|sandbox)[.-]' all-subs.txt > weak_naming.tmp 2>/dev/null || true; add_priority 20 "Dev/staging/admin host" weak_naming.tmp; rm -f weak_naming.tmp; fi
sort -t$'\t' -k1,1nr -o "$PRIORITY_TSV" "$PRIORITY_TSV"

if [ -s "$PRIORITY_TSV" ]; then
    echo -e "\n${color_red}=== Top Priority Targets (highest signal first) ===${color_reset}"
    awk -F'\t' '{printf "  [%3d] %-45s %s\n", $1, $2, $3}' "$PRIORITY_TSV" | head -10
fi

echo -e "\n${color_green}"
cat << "EOF"
+-------------------------------------------------------------+
|                        RECON SUMMARY                        |
+-------------------------------------------------------------+
EOF
printf "| %-40s : %-16s |\n" "Total Subdomains Found" "$C_SUBS"
printf "| %-40s : %-16s |\n" "Live Web Hosts (httpx)" "$C_LIVE"
printf "| %-40s : %-16s |\n" "Total URLs Crawled" "$C_URLS"
printf "| %-40s : %-16s |\n" "URLs with Parameters" "$C_PARAMS"
printf "| %-40s : %-16s |\n" "JavaScript Files" "$C_JS"
printf "| %-40s : %-16s |\n" "Potential API Endpoints" "$C_APIS"
printf "| %-40s : %-16s |\n" "Sensitive Files Found" "$C_SENS"
printf "| %-40s : %-16s |\n" "JS Intelligence Findings" "$JS_TOTAL_FINDINGS"
echo "+-------------------------------------------------------------+"
echo -e "${color_reset}"

HTML_FILE="report.html"
copy_button_html() { local tab_id="$1"; echo "<button class=\"copy-btn\" onclick=\"copyTabContent('$tab_id')\">📋 Copy</button>"; }
append_js_tab() { local tab_id="$1" file_name="$2" title="$3" desc="$4" action="$5" is_active="${6:-}"; local style="display:none;"; [ "$is_active" = "true" ] && style="display:block;"; cat <<EOF
        <div id="$tab_id" class="tabcontent" style="$style">
           <div class="intel-box"><h4>$title</h4><p><strong>What is this?</strong> $desc</p><p><span class="action"> Actionable Impact:</span> $action</p></div>
           $(copy_button_html "$tab_id")
           <div class="table-container"><table class="results-table"><thead><tr><th>Source JS File</th><th>Line</th><th>Finding</th></tr></thead><tbody>
EOF
if [ -f "$JS_GREP_DIR/$file_name" ]; then
awk -v mapfile="$JS_URL_MAP_FILE" 'BEGIN { while((getline line < mapfile)>0){ split(line,p,"|"); if(length(p)==2) urlMap[p[1]]=p[2] } } { idx=index($0,":"); if(idx>0){ f=substr($0,1,idx-1); rest=substr($0,idx+1); idx2=index(rest,":"); if(idx2>0){ l=substr(rest,1,idx2-1); m=substr(rest,idx2+1) } else { l="-"; m=rest } if(f in urlMap) f=urlMap[f]; gsub(/&/,"\\&amp;",m); gsub(/</,"\\&lt;",m); gsub(/>/,"\\&gt;",m); gsub(/"/,"\\&quot;",m); gsub(/&/,"\\&amp;",f); gsub(/</,"\\&lt;",f); gsub(/>/,"\\&gt;",f); gsub(/"/,"\\&quot;",f); print "<tr><td><a href=\"" f "\">" f "</a></td><td>" l "</td><td><code>" m "</code></td></tr>" } }' "$JS_GREP_DIR/$file_name"
fi
cat <<'EOF'
</tbody></table></div></div>
EOF
}
append_js_summary() { cat <<EOF
        <div id="tab-js-summary" class="tabcontent">
           <div class="intel-box"><h4>JavaScript Intelligence Summary</h4><p>Consolidated findings from JS analysis.</p></div>
           <table class="results-table"><tr><th>Category</th><th>Count</th><th>Response</th></tr>
           <tr><td>Credentials/tokens</td><td>$((JS_C_OAUTH+JS_C_CLOUD+JS_C_AUTH+JS_C_RSA+JS_C_SECRETS))</td><td>Validate and rotate</td></tr>
           <tr><td>Infrastructure</td><td>$((JS_C_BAAS+JS_C_S3+JS_C_IPS+JS_C_BAUTH))</td><td>Restrict access</td></tr>
           <tr><td>Attack surface</td><td>$((JS_C_PATHS+JS_C_URLS+JS_C_WS+JS_C_GQL+JS_C_SINKS))</td><td>Review authorization</td></tr>
           <tr><td>Dev artifacts</td><td>$((JS_C_DEV+JS_C_UUID+JS_C_EMAILS+JS_C_MAPS))</td><td>Remove debug data</td></tr></table>
        </div>
EOF
}
append_priority_tab() { cat <<'HTML'
        <div id="tab-priority" class="tabcontent" style="display:block;">
           <div class="intel-box"><h4>Priority Targets</h4><p>Scored triage signals, not confirmed vulnerabilities.</p></div>
           <table class="results-table"><tr><th>Score</th><th>Target</th><th>Why It Matters</th></tr>
HTML
if [ -s "$PRIORITY_TSV" ]; then awk -F'\t' 'function esc(s){gsub(/&/,"\\&amp;",s);gsub(/</,"\\&lt;",s);gsub(/>/,"\\&gt;",s);gsub(/"/,"\\&quot;",s);return s} {printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n",$1,esc($2),esc($3)}' "$PRIORITY_TSV"; else echo '<tr><td colspan="3">No high-signal findings.</td></tr>'; fi
cat <<'HTML'
</table></div>
HTML
}
append_tree_tab() { cat <<'HTML'
        <div id="tab-tree" class="tabcontent">
           <div class="intel-box"><h4>Attack Surface Graph</h4><p>Interactive graph of URLs.</p></div>
           <textarea id="tree-data-source" style="display:none;">
HTML
{ [ -f all-URLs.txt ] && cat all-URLs.txt; [ -f live-URLs.txt ] && cat live-URLs.txt; } 2>/dev/null | html_escape
cat <<'HTML'
           </textarea>
           <div id="tree-graph" style="width:100%;height:650px;background:#010409;border:1px solid #30363d;border-radius:4px;"></div>
        </div>
HTML
}
append_executive_dashboard() { local crit; crit=$(awk -F'\t' '$1+0>=80' "$PRIORITY_TSV" 2>/dev/null); [ -z "$crit" ] && return 0; cat <<'HTML'
       <div class="exec-dashboard"><div class="exec-dashboard-title">CRITICAL EXPOSURE DETECTED</div><div class="exec-dashboard-list">
HTML
echo "$crit" | awk -F'\t' 'function esc(s){gsub(/&/,"\\&amp;",s);gsub(/</,"\\&lt;",s);gsub(/>/,"\\&gt;",s);gsub(/"/,"\\&quot;",s);return s} {printf "<div class=\"exec-item\"><span class=\"exec-score\">%s</span><span class=\"exec-target\">%s</span><span class=\"exec-reason\">%s</span></div>\n",$1,esc($2),esc($3)}'
cat <<'HTML'
          </div></div>
HTML
}

temp_html=$(mktemp) || { echo "Failed to create temp report"; exit 1; }
cat <<EOF > "$temp_html"
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Reconly Report - $DOMAIN</title>
<style>
body{background:#0d1117;color:#c9d1d9;font-family:sans-serif;margin:0;padding:3px}.container{max-width:1300px;margin:auto}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px}.card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:5px;text-align:center;border-top:3px solid #238636}.card h3{margin:0;color:#8b949e}.card p{margin:5px 0 0;font-size:24px;color:#fff}.alert-card{border-top:3px solid #f85149}.alert-card p{color:#f85149}.tabs{overflow:hidden;background:#161b22;border:1px solid #30363d;border-radius:8px 8px 0 0;display:flex;flex-wrap:wrap}.tabs button{background:inherit;border:none;padding:12px;color:#8b949e;cursor:pointer;flex-grow:1}.tabs button.active{background:#238636;color:#fff}.tabcontent{display:none;padding:20px;border:1px solid #30363d;border-top:none}.data-box{width:100%;height:500px;background:#010409;color:#39d353;padding:15px;font-family:monospace}.intel-box{background:#1f2428;border-left:4px solid #58a6ff;padding:15px}.results-table{width:100%;border-collapse:collapse}.results-table th{background:#238636;color:#fff}.results-table td{border-bottom:1px solid #21262d}.exec-dashboard{background:#2b0d0d;border:2px solid #f85149;animation:pulse 2s infinite;padding:16px}.exec-score{background:#f85149;color:#0d1117;font-weight:bold;padding:2px 8px;border-radius:4px}.copy-btn{background:#238636;color:#fff;border:none;padding:5px 10px;margin:5px}
</style>
<script src="https://unpkg.com/vis-network@9.1.9/standalone/umd/vis-network.min.js"></script></head><body><div class="container">
<div class="timestamp">Scan generated: $TIMESTAMP | Directory: $SESSION_DIR</div>
<div class="grid">
<div class="card"><h3>All Subs</h3><p>$C_SUBS</p></div>
<div class="card"><h3>Live Hosts</h3><p>$C_LIVE</p></div>
<div class="card"><h3>All URLs</h3><p>$C_URLS</p></div>
<div class="card"><h3>Params</h3><p>$C_PARAMS</p></div>
<div class="card"><h3>JS Files</h3><p>$C_JS</p></div>
<div class="card"><h3>APIs</h3><p>$C_APIS</p></div>
<div class="card alert-card"><h3>Sensitive</h3><p>$C_SENS</p></div>
<div class="card alert-card"><h3>JS Findings</h3><p>$JS_TOTAL_FINDINGS</p></div>
</div>
$(append_executive_dashboard)
<div class="tabs">
<button class="tablinks active" onclick="openTab(event,'tab-priority')">Priority</button>
<button class="tablinks" onclick="openTab(event,'tab-tree')">Graph</button>
<button class="tablinks" onclick="openTab(event,'tab-allsubs')">All Subs</button>
<button class="tablinks" onclick="openTab(event,'tab-live')">Live URLs</button>
<button class="tablinks" onclick="openTab(event,'tab-urls')">All URLs</button>
<button class="tablinks" onclick="openTab(event,'tab-params')">Params</button>
<button class="tablinks" onclick="openTab(event,'tab-js')">JS Files</button>
<button class="tablinks" onclick="openTab(event,'tab-api')">APIs</button>
<button class="tablinks" onclick="openTab(event,'tab-sens')">Sensitive</button>
<button class="tablinks" onclick="openTab(event,'tab-subfinder')">Subfinder</button>
<button class="tablinks" onclick="openTab(event,'tab-assetfinder')">Assetfinder</button>
<button class="tablinks" onclick="openTab(event,'tab-findomain')">Findomain</button>
<button class="tablinks" onclick="openTab(event,'tab-github')">GitHub</button>
<button class="tablinks" onclick="openTab(event,'tab-shodan')">Shodan</button>
<button class="tablinks" onclick="openTab(event,'tab-gau')">Gau</button>
<button class="tablinks" onclick="openTab(event,'tab-katana')">Katana</button>
<button class="tablinks" onclick="openTab(event,'tab-external')">External</button>
<button class="tablinks" onclick="openTab(event,'tab-js-summary')">JS Summary</button>
<button class="tablinks" onclick="openTab(event,'tab-log')">Log</button>
</div>
<div id="tab-allsubs" class="tabcontent">$(copy_button_html "tab-allsubs")<textarea class="data-box">$(cat all-subs.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-live" class="tabcontent">$(copy_button_html "tab-live")<textarea class="data-box">$(cat live-URLs.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-urls" class="tabcontent">$(copy_button_html "tab-urls")<textarea class="data-box">$(cat all-URLs.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-params" class="tabcontent">$(copy_button_html "tab-params")<textarea class="data-box">$(cat URLs_with_params.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-js" class="tabcontent">$(copy_button_html "tab-js")<textarea class="data-box">$(cat js_files.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-api" class="tabcontent">$(copy_button_html "tab-api")<textarea class="data-box">$(cat api_endpoints.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-sens" class="tabcontent">$(copy_button_html "tab-sens")<textarea class="data-box">$(cat sensitiveFiles.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-subfinder" class="tabcontent">$(copy_button_html "tab-subfinder")<textarea class="data-box">$(cat subfinder.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-assetfinder" class="tabcontent">$(copy_button_html "tab-assetfinder")<textarea class="data-box">$(cat assetfinder.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-findomain" class="tabcontent">$(copy_button_html "tab-findomain")<textarea class="data-box">$(cat findomain.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-github" class="tabcontent">$(copy_button_html "tab-github")<textarea class="data-box">$(cat github-subs.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-shodan" class="tabcontent">$(copy_button_html "tab-shodan")<textarea class="data-box">$(cat shosubgo.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-gau" class="tabcontent">$(copy_button_html "tab-gau")<textarea class="data-box">$(cat gauURLs-passive.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-katana" class="tabcontent">$(copy_button_html "tab-katana")<textarea class="data-box">$(cat katanaURLs_active.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-external" class="tabcontent">$(copy_button_html "tab-external")<textarea class="data-box">$(cat external-URLs.txt 2>/dev/null | html_escape || echo "No data")</textarea></div>
<div id="tab-log" class="tabcontent">$(copy_button_html "tab-log")<textarea class="terminal-box">$(cat reconly.log 2>/dev/null | html_escape || echo "No log")</textarea></div>
$(append_priority_tab)
$(append_tree_tab)
$(append_js_summary)
$(append_js_tab "tab-js-paths" "hidden_paths.txt" "Hidden API Paths & Endpoints" "Relative paths indicating internal APIs, admin panels, or staging environments." "Append these paths to the target domain and validate authorization and access control." "true")
$(append_js_tab "tab-js-urls" "all_urls.txt" "External URLs" "Full external URLs embedded within the discovered JavaScript files." "Review third-party trust relationships and check whether any endpoint exposes unintended data.")
$(append_js_tab "tab-js-ips" "ip_addresses.txt" "Exposed IP Addresses" "IPv4 addresses hardcoded by developers." "Confirm ownership and exposure; restrict internal services and review direct access paths.")
$(append_js_tab "tab-js-sinks" "dom_sinks.txt" "DOM XSS Sinks" "Potential dangerous JavaScript sinks like innerHTML or eval that handle untrusted inputs." "Trace user-controlled data into each sink and apply contextual output encoding or safe DOM APIs.")
$(append_js_tab "tab-js-maps" "source_maps.txt" "Source Maps Leaks (.js.map)" "Exposed source map references discovered in JavaScript." "Remove source maps from public production builds when they disclose original source or sensitive implementation details.")
$(append_js_tab "tab-js-ws" "websockets.txt" "WebSockets Endpoints" "Endpoints starting with ws:// or wss:// used for real-time communication." "Verify origin checks, authentication, authorization, and message-level validation.")
$(append_js_tab "tab-js-gql" "graphql.txt" "GraphQL Queries & Mutations" "Hardcoded GraphQL operations." "Review introspection, batching, object-level authorization, and mutation controls.")
$(append_js_tab "tab-js-dev" "dev_comments.txt" "Developer Comments" "Inline comments like TODO, FIXME, or BUG." "Review comments for implementation details, temporary credentials, debug behavior, and unfinished security controls.")
$(append_js_tab "tab-js-baas" "baas_urls.txt" "BaaS & Database URLs" "Direct links to Firebase, Supabase, or Appwrite instances." "Verify database rules and ensure unauthenticated reads and writes are not allowed.")
$(append_js_tab "tab-js-s3" "s3_buckets.txt" "AWS S3 Buckets" "Direct links to Amazon S3 storage buckets." "Review bucket policy, public access settings, and least-privilege access for read, write, and delete operations.")
$(append_js_tab "tab-js-oauth" "oauth_configs.txt" "OAuth & Tenant IDs" "Client IDs, tenant IDs, or application identifiers used for third-party integrations." "Treat exposed client secrets as compromised, rotate them, and review redirect URI and scope restrictions.")
$(append_js_tab "tab-js-cloud" "cloud_tokens.txt" "Cloud & SaaS Tokens" "API keys for services such as Stripe, Google Cloud, Slack, or GitHub." "Validate scope, revoke confirmed exposed tokens, rotate them, and inspect provider audit logs.")
$(append_js_tab "tab-js-auth" "auth_tokens.txt" "JWT & Bearer Tokens" "Authentication tokens embedded for API access." "Invalidate confirmed tokens, review signing and expiry controls, and verify server-side authorization.")
$(append_js_tab "tab-js-secrets" "generic_secrets.txt" "Generic Secrets & Passwords" "Variables named password, secret, or token." "Never test discovered credentials against unrelated systems; validate only within the authorized target, then rotate confirmed secrets immediately.")
$(append_js_tab "tab-js-emails" "emails.txt" "Email Addresses" "Email addresses embedded in the discovered JavaScript files." "Confirm whether the addresses are intentionally public and remove unnecessary internal or personal contact data from client bundles.")
$(append_js_tab "tab-js-basic-auth" "basic_auth.txt" "Basic Authentication URLs" "URLs containing an embedded username and password." "Treat the credential as compromised, rotate it immediately, and remove credentials from URLs and client-side code.")
$(append_js_tab "tab-js-rsa" "rsa_keys.txt" "RSA Private Keys" "Private-key headers discovered in JavaScript files." "Treat the key as compromised, revoke or replace it, and investigate any systems that trusted it.")
$(append_js_tab "tab-js-uuid" "uuids.txt" "UUIDs" "UUID values embedded in the discovered JavaScript files." "Determine whether each UUID is a public identifier or a sensitive object reference requiring authorization checks.")
<div class="footer">Built by <a href="https://github.com/Ln0rag">Ln0rag</a> | Reconly</div>
<script>
function openTab(evt, tabName){var i,tabcontent,tablinks;tabcontent=document.getElementsByClassName("tabcontent");for(i=0;i<tabcontent.length;i++)tabcontent[i].style.display="none";tablinks=document.getElementsByClassName("tablinks");for(i=0;i<tablinks.length;i++)tablinks[i].className=tablinks[i].className.replace(" active","");document.getElementById(tabName).style.display="block";evt.currentTarget.className+=" active";}
function copyTabContent(tabId){var tab=document.getElementById(tabId);if(!tab)return;var content="";var ta=tab.querySelector("textarea");if(ta)content=ta.value;else content=tab.innerText||tab.textContent;if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(content).then(function(){var btn=tab.querySelector('.copy-btn');if(btn){var old=btn.innerText;btn.innerText='✅ Copied!';setTimeout(function(){btn.innerText=old},1500)}})}else{var tmp=document.createElement('textarea');tmp.value=content;document.body.appendChild(tmp);tmp.select();document.execCommand('copy');document.body.removeChild(tmp)}}
function escapeHtml(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}
function riskClass(n){if(/(\.env|\.git|\.sql|\.bak|backup|secret|password|private|\.pem|\.key|credential)/i.test(n))return"risk-critical";if(/(admin|internal|staging|debug|config|graphql|token|auth|payment|upload)/i.test(n))return"risk-high";if(/(api|v[0-9]+|dev|test|beta|login|user|account)/i.test(n))return"risk-med";return""}
function riskColor(c){if(c==="risk-critical")return{border:"#f85149",background:"#3d1f1f"};if(c==="risk-high")return{border:"#d29922",background:"#332a12"};if(c==="risk-med")return{border:"#58a6ff",background:"#12233b"};return{border:"#30363d",background:"#161b22"}}
function buildGraphData(lines){var nodeIds={};var nodes=[];var edges=[];var rootId="root::__domain__";function addNode(id,label,cls,isRoot,isHost){if(nodeIds[id])return id;nodeIds[id]=true;var color=isRoot?{border:"#39d353",background:"#0d2b17"}:riskColor(cls);nodes.push({id:id,label:label,shape:"dot",size:isRoot?28:(isHost?18:10),font:{color:"#c9d1d9",size:isRoot?16:12},color:{background:color.background,border:color.border,highlight:color},borderWidth:isRoot?3:2});return id}addNode(rootId,"__ROOT_DOMAIN__","",true,false);for(var i=0;i<lines.length;i++){var line=lines[i].trim();if(!line)continue;var url;try{url=new URL(line)}catch(e){continue}var hostId="host::"+url.hostname;addNode(hostId,url.hostname,"host",false,true);edges.push({from:rootId,to:hostId});var parts=url.pathname.split("/").filter(Boolean);var parentId=hostId;var pathAcc="";for(var j=0;j<parts.length&&j<6;j++){pathAcc+="/"+parts[j];var segId="seg::"+url.hostname+pathAcc;var isNew=!nodeIds[segId];addNode(segId,parts[j],riskClass(parts[j]),false,false);if(isNew)edges.push({from:parentId,to:segId});parentId=segId}}return{nodes:nodes,edges:edges}}
function renderGraph(){var src=document.getElementById("tree-data-source");var container=document.getElementById("tree-graph");if(!src||!container||typeof vis==="undefined")return;var lines=src.value.split("\n");var data=buildGraphData(lines);var rootNode=data.nodes.find(function(n){return n.id==="root::__domain__"});if(rootNode)rootNode.label="$DOMAIN";if(data.nodes.length<=1){container.innerHTML="<p>No URLs to graph yet.</p>";return}new vis.Network(container,{nodes:new vis.DataSet(data.nodes),edges:new vis.DataSet(data.edges)},{physics:{stabilization:true,barnesHut:{gravitationalConstant:-4000,springLength:90}},interaction:{hover:true},edges:{color:{color:"#30363d",highlight:"#58a6ff"}}})}renderGraph();
</script>
</body></html>
EOF
mv "$temp_html" "$HTML_FILE"

echo -e "${color_cyan}[+] All results, logs, and HTML report are saved in:${color_reset}"
echo -e "${color_white} $SESSION_DIR${color_reset}"
echo -e "${color_yellow}[*] Opening dashboard in your browser...${color_reset}\n"

notify_webhook "Scan complete for $DOMAIN — $C_SUBS subdomains, $C_LIVE live hosts, $JS_TOTAL_FINDINGS JS findings. Report: $SESSION_DIR/$HTML_FILE"

if command -v brave-browser &> /dev/null; then brave-browser --incognito "$HTML_FILE" &> /dev/null &
elif command -v brave &> /dev/null; then brave --incognito "$HTML_FILE" &> /dev/null &
elif command -v xdg-open &> /dev/null; then xdg-open "$HTML_FILE" &> /dev/null &
elif command -v open &> /dev/null; then open "$HTML_FILE" &> /dev/null &
else echo "No Browser found"; fi
