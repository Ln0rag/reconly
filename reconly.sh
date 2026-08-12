#!/usr/bin/env bash

color_reset="\e[0m"
color_cyan="\e[36;1m"
color_red="\e[31;1m"
color_yellow="\e[33;1m"
color_green="\e[32;1m"
color_magenta="\e[35;1m"
color_white="\e[97;1m"

trap_ctrlc() {
    echo -e "\n${color_red}[!] Ctrl+C Detected! Aborting scan...${color_reset}"
    echo -e "${color_yellow}[*] Cleaning up temporary files...${color_reset}"
    
    if [[ -n "$SESSION_DIR" && -d "$SESSION_DIR" ]]; then
        cd "$SESSION_DIR" || exit
        rm -f t.txt l1.txt l2.txt l3.txt l4.txt resolvers.txt all-URLs-temp.txt 2>/dev/null
        echo -e "${color_green}[+] Cleanup done. Session saved in: $SESSION_DIR/reconly.log${color_reset}"
    else
        echo -e "${color_green}[+] Cleanup done. No active session to log.${color_reset}"
    fi
    stty sane 2>/dev/null
    exit 2
}
trap trap_ctrlc SIGINT

clear
echo -e "${color_red}
                  ______ _______ _______  _____  __   _        __   __
                 |_____/ |______ |       |     | | \  | |        \_/  
                 |    \_ |______ |_____  |_____| |  \_| |_____    |   
${color_reset}"
echo -e "                                  github.com/Ln0rag\n"

echo -e "${color_cyan}+-------------------+-----------------------------+----------------------------------+${color_reset}"
echo -e "${color_cyan}| ${color_yellow}Tool${color_cyan}              | ${color_yellow}GitHub Repo${color_cyan}                 | ${color_yellow}Role in Reconly${color_cyan}                  |${color_reset}"
echo -e "${color_cyan}+-------------------+-----------------------------+----------------------------------+${color_reset}"
echo -e "${color_cyan}| ${color_white}subfinder${color_cyan}         | ${color_magenta}projectdiscovery/subfinder${color_cyan}  | ${color_green}Passive Subdomain Enumeration${color_cyan}    |${color_reset}"
echo -e "${color_cyan}| ${color_white}assetfinder${color_cyan}       | ${color_magenta}tomnomnom/assetfinder${color_cyan}       | ${color_green}Passive Subdomain Enumeration${color_cyan}    |${color_reset}"
echo -e "${color_cyan}| ${color_white}findomain${color_cyan}         | ${color_magenta}findomain/findomain${color_cyan}         | ${color_green}Passive Subdomain Enumeration${color_cyan}    |${color_reset}"
echo -e "${color_cyan}| ${color_white}github-subdomains${color_cyan} | ${color_magenta}gwen001/github-subdomains${color_cyan}   | ${color_green}GitHub API Subdomain Scraping${color_cyan}    |${color_reset}"
echo -e "${color_cyan}| ${color_white}shosubgo${color_cyan}          | ${color_magenta}incogbyte/shosubgo${color_cyan}          | ${color_green}Shodan API Subdomain Scraping${color_cyan}    |${color_reset}"
echo -e "${color_cyan}| ${color_white}puredns${color_cyan}           | ${color_magenta}d3mondev/puredns${color_cyan}            | ${color_green}Active DNS Bruteforcing (4 Lvls)${color_cyan} |${color_reset}"
echo -e "${color_cyan}| ${color_white}httpx${color_cyan}             | ${color_magenta}projectdiscovery/httpx${color_cyan}      | ${color_green}Live Host Probing & Tech Detect${color_cyan}  |${color_reset}"
echo -e "${color_cyan}| ${color_white}gau${color_cyan}               | ${color_magenta}lc/gau${color_cyan}                      | ${color_green}Passive URL Fetching${color_cyan}             |${color_reset}"
echo -e "${color_cyan}| ${color_white}katana${color_cyan}            | ${color_magenta}projectdiscovery/katana${color_cyan}     | ${color_green}Active Web Crawling${color_cyan}              |${color_reset}"
echo -e "${color_cyan}| ${color_white}ffuf${color_cyan}              | ${color_magenta}ffuf/ffuf${color_cyan}                   | ${color_green}Stealth Fuzzing (Dirs & Params)${color_cyan}  |${color_reset}"
echo -e "${color_cyan}+-------------------+-----------------------------+----------------------------------+${color_reset}\n"

RAW_DOMAIN=""
while getopts "d:h" opt; do
    case $opt in
        d) RAW_DOMAIN="$OPTARG" ;;
        h) echo "Usage: $0 -d <domain.com>"; exit 0 ;;
        \?) echo "Invalid option. Use -h for help."; exit 1 ;;
    esac
done

if [ -z "$RAW_DOMAIN" ]; then
    echo -e "${color_red}[!] Domain is required. Usage: $0 -d domain.com${color_reset}"
    exit 1
fi

DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|^www\.||')
DOMAIN_ESCAPED="${DOMAIN//./\.}"

if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo -e "${color_red}[!] Invalid domain format: $DOMAIN${color_reset}"
    exit 1
fi

echo -e "${color_cyan}[*] Checking internet connection...${color_reset}"
if ! ping -c 1 -W 2 1.1.1.1 &> /dev/null; then
    echo -e "${color_red}[!] No internet connection! Please check your network and try again.${color_reset}"
    exit 1
fi

echo -ne "${color_yellow}[*] Testing connection speed... ${color_reset}"

SPEED_BPS=$(curl -s -w "%{speed_download}" -o /dev/null -m 5 https://speed.cloudflare.com/__down?bytes=3000000 2>/dev/null || echo "0")
SPEED_MBPS=$(echo "scale=2; $SPEED_BPS / 1024 / 1024" | bc 2>/dev/null || echo "N/A")
echo -e "${color_green}${SPEED_MBPS} MB/s${color_reset}\n"

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
)

for tool in "${!tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${color_red}[!] $tool is not installed.${color_reset}"
        echo -e "    Run: ${color_cyan}${tools[$tool]}${color_reset}"
        exit 1
    fi
done


BASE_DIR="$HOME/reconly/$DOMAIN"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
START_PHASE=1

if [ -d "$BASE_DIR" ] && [ "$(ls -A "$BASE_DIR" 2>/dev/null)" ]; then
    echo -e "${color_magenta}[!] Previous scans detected for $DOMAIN!${color_reset}"
    echo "  [1] Start fresh (New Scan)"
    echo "  [2] Resume: Active DNS Bruteforce"
    echo "  [3] Resume: Live URLs Probing (httpx)"
    echo "  [4] Resume: Crawling (gau & katana)"
    echo "  [5] Resume: Smart Filtering"
    echo "  [6] Resume: Fuzzing (Params & Dirs)"
    read -p "Select a starting point [1-6] (Default 1): " choice
    if [[ "$choice" =~ ^[1-6]$ ]]; then
        echo ""
        echo ""
        START_PHASE=$choice
    fi
    
    if [ "$START_PHASE" -ne 1 ]; then
        SESSION_DIR=$(ls -td "$BASE_DIR"/*/ | head -1 | sed 's/\/$//')
        echo -e "${color_green}[+] Resuming scan in: $SESSION_DIR${color_reset}\n"
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

use_shodan="n"; SHODAN_KEY=""
use_github="n"; GITHUB_KEY=""
use_brute="n"; DNS_WORDLIST=""; PARAM_WORDLIST=""; DIR_WORDLIST=""

if [ "$START_PHASE" -le 1 ]; then
    echo -e "Do you want to search in ${color_white}Shodan${color_reset} ? (Y/n) [Default: Y]: \c"
    read p_shodan
    if [[ -z "$p_shodan" || "$p_shodan" =~ ^[Yy]$ ]]; then
        read -p "Please Enter a valid Shodan KEY: " SHODAN_KEY
        if curl -s -f "https://api.shodan.io/api-info?key=$SHODAN_KEY" | grep -q "plan"; then
            echo -e "${color_green}Shodan key is valid ${color_reset}\n"; use_shodan="y"
        else
            echo -e "${color_red}Shodan key is not valid, Skipping...${color_reset}\n"
        fi
    else
        echo -e "${color_cyan}Skipping Shodan search...${color_reset}\n"
    fi

    echo -e "Do you want to search in ${color_white}Github${color_reset}? (Y/n) [Default: Y]: \c"
    read p_github
    if [[ -z "$p_github" || "$p_github" =~ ^[Yy]$ ]]; then
        read -p "Please Enter a valid Github Token: " GITHUB_KEY
        if curl -s -f -H "Authorization: token $GITHUB_KEY" "https://api.github.com/user" | grep -q "login"; then
            echo -e "${color_green}Github token is valid ${color_reset}\n"; use_github="y"
        else
            echo -e "${color_red}Github token is not valid, Skipping...${color_reset}\n"
        fi
    else
        echo -e "${color_cyan}Skipping Github search...${color_reset}\n"
    fi
fi

echo -e "Do you want to Actively Bruteforce (Subdomains, Params, Dirs)? (Y/n) [Default: Y]: \c"
read p_brute
if [[ -z "$p_brute" || "$p_brute" =~ ^[Yy]$ ]]; then
    use_brute="y"
    echo -e "\n${color_magenta}[Hint] Wordlist Configuration${color_reset}"
    echo -e "Do you want to use custom individual wordlist paths? (y/N): \c"
    read custom_wl
    
    if [[ "$custom_wl" =~ ^[Yy]$ ]]; then
        if [ "$START_PHASE" -le 2 ]; then
            while true; do
                echo -e "Enter path for DNS bruteforce: \c"
                read DNS_WORDLIST
                [ -f "$DNS_WORDLIST" ] && break
                echo -e "${color_red}[!] File not found.${color_reset}"
            done
        fi
        
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
    else
        echo -e "Enter SecLists base path [Default: /media/DATA/SecLists]: \c"
        read seclists_base
        if [ -z "$seclists_base" ]; then
            seclists_base="/media/DATA/SecLists"
        fi

        DNS_WORDLIST="$seclists_base/Discovery/DNS/subdomains-top1million-5000.txt"
        PARAM_WORDLIST="$seclists_base/Discovery/Web-Content/burp-parameter-names.txt"
        DIR_WORDLIST="$seclists_base/Discovery/Web-Content/common.txt"

        for wordlist in "$DNS_WORDLIST" "$PARAM_WORDLIST" "$DIR_WORDLIST"; do
            if [ ! -f "$wordlist" ]; then
                echo -e "${color_red}[!] Warning: File not found -> $wordlist${color_reset}"
            fi
        done
    fi
    echo -e "${color_green}[+] Wordlists configured successfully!${color_reset}"
    echo -e "${color_cyan}  - DNS Target Path    : ${color_white}$DNS_WORDLIST${color_reset}"
    echo -e "${color_cyan}  - Parameters Path    : ${color_white}$PARAM_WORDLIST${color_reset}"
    echo -e "${color_cyan}  - Directories Path   : ${color_white}$DIR_WORDLIST${color_reset}\n"
else
    echo -e "${color_cyan}Skipping bruteforcing...${color_reset}\n"
fi

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

UAS=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/119.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    "Mozilla/5.0 (X11; Linux x86_64; rv:102.0) Gecko/20100101 Firefox/102.0"
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/119.0.6045.109 Mobile/15E148 Safari/604.1"
)

# [Phase 1] Passive Recon

if [ "$START_PHASE" -le 1 ]; then
    
    echo -e "\n${color_yellow}=== [Phase 1] Passive Subdomain Enumeration ===${color_reset}"
    echo -e ""
    echo -e "${color_cyan}[~]$ subfinder -d $DOMAIN -all -recursive -rl 30 -t 10 -silent | sort -u | tee subfinder.txt${color_reset}"
    subfinder -d "$DOMAIN" -all -recursive -rl 30 -t 10 -silent | sort -u | tee subfinder.txt
    echo -e ""
    echo -e "${color_cyan}[~]$ assetfinder --subs-only $DOMAIN | grep \"\.$DOMAIN_ESCAPED$\" | sort -u | tee assetfinder.txt${color_reset}"
    assetfinder --subs-only "$DOMAIN" | grep "\.$DOMAIN_ESCAPED$" | sort -u | tee assetfinder.txt
    echo -e ""
    echo -e "${color_cyan}[~]$ findomain -t $DOMAIN -q | grep \"$DOMAIN_ESCAPED$\" | sort -u | tee findomain.txt${color_reset}"
    findomain -t "$DOMAIN" -q | grep "$DOMAIN_ESCAPED$" | sort -u | tee findomain.txt

    if [[ "$use_github" == "y" ]]; then
        echo -e ""
        echo -e "${color_cyan}[~]$ github-subdomains -d $DOMAIN -t \"***\" | grep \"$DOMAIN_ESCAPED$\" | sort -u | tee github-subs.txt${color_reset}"
        github-subdomains -d "$DOMAIN" -t "$GITHUB_KEY" | grep "$DOMAIN_ESCAPED$" | sort -u | tee github-subs.txt
        
        if [ ! -s github-subs.txt ]; then
            echo -e "${color_white}[*] No subdomains found on GitHub for this domain.${color_reset}"
        fi
    fi

    if [[ "$use_shodan" == "y" ]]; then
        echo -e ""
        echo -e "${color_cyan}[~]$ shosubgo -d $DOMAIN -s \"***\" | grep \"\.$DOMAIN_ESCAPED$\" | sort -u | tee shosubgo.txt${color_reset}"
        shosubgo -d "$DOMAIN" -s "$SHODAN_KEY" | grep "\.$DOMAIN_ESCAPED$" | sort -u | tee shosubgo.txt
    fi
fi

# [Phase 2] Active DNS Bruteforce

if [ "$START_PHASE" -le 2 ]; then
    if [[ "$use_brute" == "y" ]]; then
        echo -e "\n${color_yellow}=== [Phase 2] Active DNS Bruteforcing ===${color_reset}"
        echo -e ""
        echo -e "${color_cyan}[~]$ puredns bruteforce $DNS_WORDLIST $DOMAIN (4 Levels)...${color_reset}"
        W="$DNS_WORDLIST"; R="resolvers.txt"; D="$DOMAIN"
        
        echo "[*] Starting Level 1..." && puredns bruteforce "$W" "$D" -r "$R" --rate-limit 2000 -w l1.txt >/dev/null 2>&1
        echo "[*] Level 1 Done. Starting Level 2..." && > l2.txt
        while read -r s; do
            rm -f t.txt; puredns bruteforce "$W" "$s" -r "$R" --rate-limit 2000 -w t.txt >/dev/null 2>&1
            [ -f t.txt ] && cat t.txt >> l2.txt
        done < l1.txt
        
        echo "[*] Level 2 Done. Starting Level 3..." && > l3.txt
        while read -r s; do
            rm -f t.txt; puredns bruteforce "$W" "$s" -r "$R" --rate-limit 2000 -w t.txt >/dev/null 2>&1
            [ -f t.txt ] && cat t.txt >> l3.txt
        done < l2.txt
        
        echo "[*] Level 3 Done. Starting Level 4..." && > l4.txt
        while read -r s; do
            rm -f t.txt; puredns bruteforce "$W" "$s" -r "$R" --rate-limit 2000 -w t.txt >/dev/null 2>&1
            [ -f t.txt ] && cat t.txt >> l4.txt
        done < l3.txt
        
        echo "[*] Merging and Cleaning up..."
        cat l1.txt l2.txt l3.txt l4.txt 2>/dev/null | sort -u > active-subs.txt
        rm -f l1.txt l2.txt l3.txt l4.txt t.txt
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
fi

# [Phase 3] Live Probing

if [ "$START_PHASE" -le 3 ]; then
    echo -e "\n${color_yellow}=== [Phase 3] Live Probing >> httpx ===${color_reset}"
    echo -e ""
    if [ -s all-subs.txt ]; then
        echo -e "${color_cyan}[~]$ cat all-subs.txt | httpx -silent -threads 200 -status-code -tech-detect -title -location${color_reset}"
        cat all-subs.txt | httpx -silent -threads 200 -status-code -tech-detect -title -location | tee >(awk '{print $1}' > live-URLs.txt)
    else
        echo -e "${color_red}[!] all-subs.txt is empty! Skipping httpx.${color_reset}"
        > live-URLs.txt
    fi
fi

# [Phase 4] Crawling

if [ "$START_PHASE" -le 4 ]; then
    echo -e "\n${color_yellow}=== [Phase 4] Crawling >> gau & katana ===${color_reset}"
    if [ -s all-subs.txt ]; then
        echo -e ""
        echo -e "${color_cyan}[~]$ cat all-subs.txt | gau --threads 10 | sort -u | tee gauURLs-passive.txt${color_reset}"
        cat all-subs.txt | gau --threads 10 | sort -u | tee gauURLs-passive.txt
    fi

    if [ -s live-URLs.txt ]; then
        echo -e ""
        echo -e "${color_cyan}[~]$ cat live-URLs.txt | katana -d 2 -rl 10 -c 5 -silent | tee katanaURLs_active.txt${color_reset}"
        cat live-URLs.txt | katana -d 2 -rl 10 -c 5 -silent | tee katanaURLs_active.txt
    fi
fi

# [Phase 5] Smart Filtering

if [ "$START_PHASE" -le 5 ]; then
    echo -e "\n${color_yellow}=== [Phase 5] Smart Filtering ===${color_reset}"
    echo -e ""
    
    {
        [ -f gauURLs-passive.txt ] && cat gauURLs-passive.txt
        [ -f katanaURLs_active.txt ] && cat katanaURLs_active.txt
    } | sort -u > all-URLs-temp.txt
    
    if [ -s all-URLs-temp.txt ]; then
        echo -e "${color_cyan}[*] Extracting In-Scope URLs...${color_reset}"
        cat all-URLs-temp.txt | grep "$DOMAIN_ESCAPED" | sort -u > all-URLs.txt
        cat all-URLs-temp.txt | grep -v "$DOMAIN_ESCAPED" | sort -u > external-URLs.txt
        rm -f all-URLs-temp.txt

        echo -e "${color_cyan}[*] Extracting Parameters, JS, APIs, and Sensitive Files...${color_reset}"
        cat all-URLs.txt | grep '=' | sort -u > URLs_with_params.txt
        cat all-URLs.txt | grep -E "\.js(\?|$)" | sort -u > js_files.txt
        cat all-URLs.txt | grep -E "\.(xls|xml|xlsx|json|pdf|sql|doc|docx|pptx|txt|zip|tar\.gz|tgz|bak|7z|rar|log|cache|secret|db|backup|yml|gz|config|csv|yaml|md|md5|tar|xz|7zip|p12|pem|key|crt|csr|sh|pl|py|java|class|jar|war|ear|sqlitedb|sqlite3|dbf|db3|accdb|mdb|sqlcipher|gitignore|env|ini|conf|properties|plist|cfg)(\?|$)" | sort -u > sensitiveFiles.txt
        cat all-URLs.txt | grep -E "\b(api|v[0-9]+|graphql|rest|endpoint|ajax)\b" | grep -E -v "\.(css|js)(\?|$)" | sort -u > api_endpoints.txt
    else
        echo -e "${color_red}[!] No URLs found to filter.${color_reset}"
        > all-URLs.txt; > URLs_with_params.txt; > js_files.txt; > sensitiveFiles.txt; > api_endpoints.txt
    fi
fi

# [Phase 6] Fuzzing

if [ "$START_PHASE" -le 6 ] && [[ "$use_brute" == "y" ]]; then
    mkdir -p fuzz_params fuzz_dirs
    
    # 1. API Parameter Fuzzing
    echo -e "\n${color_yellow}=== [Phase 6.A] Stealth Fuzzing >> ffuf > param ===${color_reset}"
    echo -e ""
    if [ -s api_endpoints.txt ]; then
        total_apis=$(wc -l < api_endpoints.txt)
        counter=1
        while read -r url; do
            [ -z "$url" ] && continue
            echo -e "${color_cyan}[ $counter / $total_apis ] Fuzzing: $url${color_reset}"
            RANDOM_UA=${UAS[$RANDOM % ${#UAS[@]}]}
            
            if [[ "$url" == *\?* ]]; then target_url="${url}&FUZZ=1"
            else target_url="${url}?FUZZ=1"; fi

            ffuf -u "$target_url" \
                 -w "$PARAM_WORDLIST" \
                 -fc 403,404,473,500 \
                 -ac -rate 3 \
                 -H "User-Agent: $RANDOM_UA" \
                 -o "fuzz_params/fuzz_$(echo "$url" | md5sum | awk '{print $1}').json"
            ((counter++))
        done < api_endpoints.txt
    else
        echo -e "${color_red}[!] api_endpoints.txt is empty! Skipping parameter fuzzing.${color_reset}"
    fi

    # 2. Directory Fuzzing
    echo -e "\n${color_yellow}=== [Phase 6.B] Stealth Fuzzing >> ffuf > Dir ===${color_reset}"
    echo -e ""
    if [ -s live-URLs.txt ]; then
        total_hosts=$(wc -l < live-URLs.txt)
        counter=1
        while read -r base_url; do
            [ -z "$base_url" ] && continue
            echo -e "${color_cyan}[ $counter / $total_hosts ] Fuzzing Dirs: $base_url${color_reset}"
            RANDOM_UA=${UAS[$RANDOM % ${#UAS[@]}]}
            
            clean_url=$(echo "$base_url" | awk -F/ '{print $1"//"$3}')
            ffuf -u "$clean_url/FUZZ" \
                 -w "$DIR_WORDLIST" \
                 -mc 200,301,302,307,401,405 \
                 -fc 403,404,473,500,502 \
                 -ac -ic -rate 5 \
                 -e .html,.php,.txt,.bak,.zip,.json,.config,.env,.sql \
                 -H "User-Agent: $RANDOM_UA" \
                 -o "fuzz_dirs/dir_fuzz_$(echo "$clean_url" | md5sum | awk '{print $1}').json"
            ((counter++))
        done < live-URLs.txt
    else
         echo -e "${color_red}[!] live-URLs.txt is empty! Skipping directory fuzzing.${color_reset}"
    fi
fi

# Cleanup & ASCII Summary Table

rm -f resolvers.txt

C_SUBS=$(wc -l < all-subs.txt 2>/dev/null || echo 0)
C_LIVE=$(wc -l < live-URLs.txt 2>/dev/null || echo 0)
C_URLS=$(wc -l < all-URLs.txt 2>/dev/null || echo 0)
C_PARAMS=$(wc -l < URLs_with_params.txt 2>/dev/null || echo 0)
C_JS=$(wc -l < js_files.txt 2>/dev/null || echo 0)
C_APIS=$(wc -l < api_endpoints.txt 2>/dev/null || echo 0)
C_SENS=$(wc -l < sensitiveFiles.txt 2>/dev/null || echo 0)

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
echo "+-------------------------------------------------------------+"
echo -e "${color_reset}"


# HTML Report

HTML_FILE="report.html"

cat << EOF > "$HTML_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Reconly report - $DOMAIN</title>
  <style>
     body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #0d1117; color: #c9d1d9; margin: 0; padding: 3px; }
     .container { max-width: 1300px; margin: auto; }
     h1 { color: #58a6ff; text-align: center; border-bottom: 1px solid #30363d; padding-bottom: 3px; font-size: 2.5em; margin-top: 3px; }
     .timestamp { text-align: center; color: #8b949e; font-size: 16px; margin-bottom: 3px; }
     
     /* Grid Stats */
     .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-bottom: 3px; }
     .card { background-color: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 5px; text-align: center; border-top: 3px solid #238636; }
     .card h3 { margin: 0 0 8px 0; color: #8b949e; font-size: 14px; text-transform: uppercase; }
     .card p { margin: 0; font-size: 24px; font-weight: bold; color: #ffffff; }
     .alert-card { border-top: 3px solid #f85149; }
     .alert-card p { color: #f85149; }
     
     /* Tabs CSS */
     .tabs { overflow: hidden; background-color: #161b22; border: 1px solid #30363d; border-radius: 8px 8px 0 0; display: flex; flex-wrap: wrap; }
     .tabs button { background-color: inherit; border: none; outline: none; cursor: pointer; padding: 12px 15px; transition: 0.3s; color: #8b949e; font-size: 13px; font-weight: bold; flex-grow: 1; }
     .tabs button:hover { background-color: #30363d; color: #c9d1d9; }
     .tabs button.active { background-color: #238636; color: #ffffff; }
     
     /* Tab Content */
     .tabcontent { display: none; padding: 20px; border: 1px solid #30363d; border-top: none; background-color: #0d1117; border-radius: 0 0 8px 8px; }
     .data-box { width: 100%; height: 500px; background-color: #010409; color: #39d353; border: 1px solid #30363d; padding: 15px; font-family: 'Courier New', Courier, monospace; font-size: 14px; resize: vertical; outline: none; box-sizing: border-box; }
     
     /* Terminal Theme for Log Tab */
     .terminal-box { width: 100%; height: 500px; background-color: #000000; color: #00ff66; border: 1px solid #30363d; padding: 15px; font-family: 'Courier New', Courier, monospace; font-size: 13px; resize: vertical; outline: none; box-sizing: border-box; line-height: 1.4; }
     
     .footer { margin-top: 3px; text-align: center; font-size: 13px; color: #8b949e; border-top: 1px solid #30363d; padding-top: 20px; }
     a { color: #58a6ff; text-decoration: none; }
     a:hover { text-decoration: underline; }
  </style>
</head>
<body>
   <div class="container">
       <!-- <h1>Reconly Report: $DOMAIN</h1> -->
       <div class="timestamp">Scan generated on: <strong>$TIMESTAMP</strong> | Directory: <code>$SESSION_DIR</code></div>

       <!-- Summary Cards -->
       <div class="grid">
          <div class="card"><h3>All Subs</h3><p>$C_SUBS</p></div>
          <div class="card"><h3>Live Hosts</h3><p>$C_LIVE</p></div>
          <div class="card"><h3>All URLs</h3><p>$C_URLS</p></div>
          <div class="card"><h3>Params</h3><p>$C_PARAMS</p></div>
          <div class="card"><h3>JS Files</h3><p>$C_JS</p></div>
          <div class="card"><h3>APIs</h3><p>$C_APIS</p></div>
          <div class="card alert-card"><h3>Sensitive</h3><p>$C_SENS</p></div>
       </div>

       <!-- Tabs Navigation -->
       <div class="tabs">
          <button class="tablinks active" onclick="openTab(event, 'tab-allsubs')">All Subdomains</button>
          <button class="tablinks" onclick="openTab(event, 'tab-live')">Live URLs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-urls')">All Crawled URLs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-params')">Params</button>
          <button class="tablinks" onclick="openTab(event, 'tab-js')">JS Files</button>
          <button class="tablinks" onclick="openTab(event, 'tab-api')">APIs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-sens')" style="color:#f85149;">Sensitive</button>
          <button class="tablinks" onclick="openTab(event, 'tab-subfinder')">Subfinder</button>
          <button class="tablinks" onclick="openTab(event, 'tab-assetfinder')">Assetfinder</button>
          <button class="tablinks" onclick="openTab(event, 'tab-findomain')">Findomain</button>
          <button class="tablinks" onclick="openTab(event, 'tab-github')">GitHub Subs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-shodan')">Shodan Subs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-gau')">Gau Passives</button>
          <button class="tablinks" onclick="openTab(event, 'tab-katana')">Katana Actives</button>
          <button class="tablinks" onclick="openTab(event, 'tab-external')">External URLs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-log')" style="color:#00ff66;">💻 Terminal Log</button>
       </div>

       <!-- Tabs Content -->
       <div id="tab-allsubs" class="tabcontent" style="display:block;">
          <textarea class="data-box" readonly spellcheck="false">$(cat all-subs.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-live" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat live-URLs.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-urls" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat all-URLs.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-params" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat URLs_with_params.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-js" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat js_files.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-api" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat api_endpoints.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-sens" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat sensitiveFiles.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-subfinder" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat subfinder.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-assetfinder" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat assetfinder.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-findomain" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat findomain.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-github" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat github-subs.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-shodan" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat shosubgo.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-gau" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat gauURLs-passive.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-katana" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat katanaURLs_active.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-external" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat external-URLs.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-log" class="tabcontent">
          <textarea class="terminal-box" readonly spellcheck="false">$(cat reconly.log 2>/dev/null || echo "No log found.")</textarea>
       </div>

       <div class="footer">
          Built by <a href="https://github.com/Ln0rag" target="_blank">Ln0rag</a> | Reconly
       </div>
   </div>

   <script>
      function openTab(evt, tabName) {
         var i, tabcontent, tablinks;
         tabcontent = document.getElementsByClassName("tabcontent");
         for (i = 0; i < tabcontent.length; i++) {
            tabcontent[i].style.display = "none";
         }
         tablinks = document.getElementsByClassName("tablinks");
         for (i = 0; i < tablinks.length; i++) {
            tablinks[i].className = tablinks[i].className.replace(" active", "");
         }
         document.getElementById(tabName).style.display = "block";
         evt.currentTarget.className += " active";
      }
   </script>
</body>
</html>
EOF

echo -e "${color_cyan}[+] All results, logs, and HTML report are saved in:${color_reset}"
echo -e "${color_white} $SESSION_DIR${color_reset}"
echo -e "${color_yellow}[*] Opening dashboard in your browser...${color_reset}\n"

if command -v xdg-open &> /dev/null; then
    xdg-open "$HTML_FILE" &> /dev/null &
elif command -v open &> /dev/null; then
    open "$HTML_FILE" &> /dev/null &
fi
