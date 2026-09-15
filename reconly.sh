#!/usr/bin/env bash

export LC_ALL=C
set -o pipefail

#	Colors
color_reset="\033[0m"
color_cyan="\033[36;1m"
color_red="\033[31;1m"
color_yellow="\033[33;1m"
color_green="\033[32;1m"
color_magenta="\033[35;1m"
color_white="\033[97;1m"

#	Config (edit here)
JS_THREADS=5
PRETTIER_MAX_MB=10
PRETTIER_BATCH=20
PRETTIER_JOBS=3
MAX_PAGES=100
OBF_MAX_FILES=20
TRUFFLEHOG_VERIFY=0
RESOLVERS="$HOME/githubTools/resolvers.txt"
HTTPX_BIN="$HOME/go/bin/httpx"
FAKE_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
REDACT=0

#	Ctrl + c
trap_ctrlc() {
    echo -e "\n${color_red}Scan halted - Cleanup complete${color_reset}"
    if [[ -n "$SESSION_DIR" && -d "$SESSION_DIR" ]]; then
        cd "$SESSION_DIR" || exit
        rm -f all-urls-temp.txt pages-temp.txt perms-temp.txt .prettier-list .js-urls-dedup.txt .js-done-urls.txt .js-pending.txt 2>/dev/null
    fi
    stty sane 2>/dev/null
    exit 2
}
trap trap_ctrlc SIGINT

#-----------------------------------------------------------------------------------
#	banner
#-----------------------------------------------------------------------------------

echo -e "${color_red}
 ______ _______ _______  _____  __   _        __   __
|_____/ |______ |       |     | | \  | |        \_/  
|    \_ |______ |_____  |_____| |  \_| |_____    |   
 ${color_reset}"
echo -e "		github.com/Ln0rag\n"

#-----------------------------------------------------------------------------------
#	validations
#-----------------------------------------------------------------------------------

RAW_DOMAIN=""
while getopts "d:rh" opt; do
    case $opt in
        d) RAW_DOMAIN="$OPTARG" ;;
        r) REDACT=1 ;;
        h)
            echo "Usage: reconly.sh -d domain.com [-r]"
            echo "  -d domain.com   target domain"
            echo "  -r              redact secrets in report.html (last 4 chars only)."
            echo "                  Full values are kept in secrets-unredacted.txt (chmod 600)."
            exit 0
            ;;
        \?) echo -e "${color_red}Invalid option, Use -h for help${color_reset}"; exit 1 ;;
    esac
done

if [ -z "$RAW_DOMAIN" ]; then
    echo -e "${color_red}Usage: reconly.sh -d domain.com [-r]${color_reset}"
    exit 1
fi

DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|^www\.||')
DOMAIN_ESCAPED="${DOMAIN//./\.}"

if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo -e "${color_red}Invalid domain format: $DOMAIN${color_reset}"
    exit 1
fi

declare -A tools=(
    ["subfinder"]="go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    ["assetfinder"]="go install github.com/tomnomnom/assetfinder@latest"
    ["findomain"]="wget -q https://github.com/findomain/findomain/releases/latest/download/findomain-linux -O findomain && chmod +x findomain && sudo mv findomain /usr/local/bin/"
    ["alterx"]="go install -v github.com/projectdiscovery/alterx/cmd/alterx@latest"
    ["dnsx"]="go install -v github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
    ["httpx"]="go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest"
    ["katana"]="go install github.com/projectdiscovery/katana/cmd/katana@latest"
    ["gau"]="go install github.com/lxndr/gau@latest"
    ["waybackurls"]="go install github.com/tomnomnom/waybackurls@latest"
    ["trufflehog"]="go install -v github.com/trufflesecurity/trufflehog@latest"
)

for tool in "${!tools[@]}"; do
    if [ "$tool" = "httpx" ]; then
        if [ ! -x "$HTTPX_BIN" ]; then
            echo -e "${color_red}httpx (projectdiscovery) not found at $HTTPX_BIN.${color_reset}"
            echo -e "    Run: ${color_cyan}${tools[$tool]}${color_reset}"
            exit 1
        fi
        continue
    fi
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${color_red}$tool is not installed.${color_reset}"
        echo -e "    Run: ${color_cyan}${tools[$tool]}${color_reset}"
        exit 1
    fi
done

if ! command -v flock &> /dev/null; then
    echo -e "${color_red}flock is required for safe parallel JS state updates. Install util-linux, then retry.${color_reset}"
    exit 1
fi

HAVE_GREP_P=1
if ! echo 'x1' | grep -qP '\d' 2>/dev/null; then
    HAVE_GREP_P=0
    echo -e "${color_yellow}grep -P not available, PHASE_5 regex hunting will be skipped.${color_reset}"
fi

HAVE_RG=0
if command -v rg &> /dev/null; then
    HAVE_RG=1
fi

BASE_DIR="$HOME/reconly/$DOMAIN"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
START_PHASE=1

#-----------------------------------------------------------------------------------
#	Resume
#-----------------------------------------------------------------------------------

if [ -d "$BASE_DIR" ] && [ "$(ls -A "$BASE_DIR" 2>/dev/null)" ]; then
    echo -e "${color_green}Previous scans detected for $DOMAIN${color_reset}"
    echo "  [1] Start fresh (New Scan)"
    echo "  [2] Resume: Live URLs Probing (httpx)"
    echo "  [3] Resume: Crawling + Archive (katana + gau)"
    echo "  [4] Resume: Filters"
    echo "  [5] Resume: JS Analysis (secrets & intel)"
    read -p "Select a starting point [1-5] (Default 1): " choice
    if [[ "$choice" =~ ^[1-5]$ ]]; then
        echo ""
        echo ""
        START_PHASE=$choice
    fi

    if [ "$START_PHASE" -ne 1 ]; then
        SESSION_DIR=$(ls -td "$BASE_DIR"/*/ | head -1 | sed 's/\/$//')
        echo -e "${color_green}Resuming scan in: $SESSION_DIR${color_reset}\n"
    else
        SESSION_DIR="$BASE_DIR/$TIMESTAMP"
        mkdir -p "$SESSION_DIR"
    fi
else
    SESSION_DIR="$BASE_DIR/$TIMESTAMP"
    mkdir -p "$SESSION_DIR"
fi

chmod 700 "$BASE_DIR" 2>/dev/null || true
chmod 700 "$SESSION_DIR" 2>/dev/null || true
cd "$SESSION_DIR" || exit

#-----------------------------------------------------------------------------------
#	Functions
#-----------------------------------------------------------------------------------

js_name_for_url() {
    local url="$1"
    local hash safe name
    hash=$(printf '%s' "$url" | md5sum | cut -c1-8)
    safe=$(echo "$url" | sed -e 's|^https*://||' -e 's/[^A-Za-z0-9.]/_/g' -e 's/__*/_/g')
    safe="${safe:0:60}"
    name="${safe}-${hash}.js"
    printf '%s\n' "$name"
}

js_fetch() {
    local url="$1"
    local name tmp
    name=$(js_name_for_url "$url")
    tmp="$JS_FILES_DIR/.${name}.part.$$"

    if [ -s "$JS_FILES_DIR/$name" ]; then
        flock 200
        if ! grep -Fqx "$name|$url" "$URL_MAP" 2>/dev/null; then
            printf '%s|%s\n' "$name" "$url" >> "$URL_MAP"
        fi
        echo -e "${color_yellow}[=] Exists:${color_reset} $url"
        flock -u 200
        return 0
    fi

    rm -f "$tmp" 2>/dev/null
    if curl -s -f -L -m 20 --retry 2 --retry-delay 2 -A "$FAKE_UA" "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f -- "$tmp" "$JS_FILES_DIR/$name"
        flock 200
        if ! grep -Fqx "$name|$url" "$URL_MAP" 2>/dev/null; then
            printf '%s|%s\n' "$name" "$url" >> "$URL_MAP"
        fi
        echo -e "${color_green}Downloaded:${color_reset} $url"
        flock -u 200
    else
        rm -f "$tmp" "$JS_FILES_DIR/$name" 2>/dev/null
        flock 200
        echo -e "${color_red}Failed/Empty:${color_reset} $url"
        flock -u 200
        return 1
    fi
}
export -f js_name_for_url js_fetch
export FAKE_UA
export color_reset color_green color_red

#	Rolling 10-line window
roller() {
    local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}"
    awk -v w="$cols" '
    {
        gsub(/\033\[[0-9;]*m/, "")
        line = substr($0, 1, w - 4)
        lines[NR % 10] = line
        if (NR <= 10) {
            print line
        } else {
            printf "\033[10A"
            for (i = 1; i <= 10; i++) {
                printf "\033[2K%s\n", lines[(NR - 10 + i) % 10]
            }
        }
        fflush()
    }'
}


hunt() {
    local msg="$1" regex="$2" outfile="$3" exclude="${4:-}"
    local tool_name="grep -a -r -n -P -o"
    [ "$HAVE_RG" -eq 1 ] && tool_name="rg -a -n -P -o"
    local shown="$tool_name -e '$regex' js-files/"
    [ -n "$exclude" ] && shown+=" | grep -v -i -P '$exclude'"
    printf '%b%s%b\n' "${color_red}RUNNING:: ${color_reset}${color_cyan}" "$shown → js-findings/$outfile" "${color_reset}" >&2

    local raw
    if [ "$HAVE_RG" -eq 1 ]; then
        raw=$( cd js-files && rg -a -n -P -o -e "$regex" . 2>/dev/null | sed 's|^\./||' )
    else
        raw=$( cd js-files && grep -a -r -n -P -o -e "$regex" . 2>/dev/null | sed 's|^\./||' )
    fi

    if [ -n "$exclude" ] && [ -n "$raw" ]; then
        raw=$(printf '%s\n' "$raw" | grep -v -i -P -e "$exclude" 2>/dev/null || true)
    fi

    printf '%s\n' "$raw" | awk 'NF' | sort -u | tee "js-findings/$outfile"

    if [ -s "js-findings/$outfile" ]; then
        awk -v type="$msg" '
        function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
        {
            i1 = index($0, ":")
            if (i1 == 0) { file = $0; line = "-"; m = "" }
            else {
                file = substr($0, 1, i1 - 1)
                rest = substr($0, i1 + 1)
                i2 = index(rest, ":")
                if (i2 > 0) { line = substr(rest, 1, i2 - 1); m = substr(rest, i2 + 1) }
                else { line = "-"; m = rest }
            }
            printf "{\"file\":\"%s\",\"line\":\"%s\",\"type\":\"%s\",\"match\":\"%s\"}\n", esc(file), esc(line), esc(type), esc(m)
        }' "js-findings/$outfile" >> js-findings/findings.jsonl
        echo -e ""
    else
        printf '%b0 findings%b\n' "${color_yellow}" "${color_reset}"
        echo -e ""
    fi
}

wildcard_dns_hits() {
    local domain="$1" total=0 i rnd hits
    for i in 1 2 3; do
        rnd="wchk${i}-$(date +%s)${RANDOM}"
        for rectype in a aaaa cname; do
            if [ -f "$RESOLVERS" ]; then
                hits=$(echo "$rnd.$domain" | dnsx -silent -r "$RESOLVERS" "-$rectype" 2>/dev/null | wc -l | tr -d '[:space:]')
            else
                hits=$(echo "$rnd.$domain" | dnsx -silent "-$rectype" 2>/dev/null | wc -l | tr -d '[:space:]')
            fi
            total=$((total + hits))
        done
    done
    echo "$total"
}

#-----------------------------------------------------------------------------------
#	PHASE_1: Passive Subdomain Enumeration + Permutations
#-----------------------------------------------------------------------------------

if [ "$START_PHASE" -le 1 ]; then
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    echo -e "\n${color_yellow}PHASE_1: Passive Subdomain Enumeration + Permutations${color_reset}"
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    echo -e "${color_red}RUNNING::${color_reset}${color_cyan} subfinder -d $DOMAIN -all -recursive -rl 30 -t 10 -silent | sort -u | tee subfinder.txt${color_reset}"
    subfinder -d "$DOMAIN" -all -recursive -rl 30 -t 10 -silent | sort -u | tee subfinder.txt
    echo -e ""
    echo -e "${color_red}RUNNING::${color_reset}${color_cyan} assetfinder --subs-only $DOMAIN | grep \"\.$DOMAIN_ESCAPED$\" | sort -u | tee assetfinder.txt${color_reset}"
    assetfinder --subs-only "$DOMAIN" | grep "\.$DOMAIN_ESCAPED$" | sort -u | tee assetfinder.txt
    echo -e ""
    echo -e "${color_red}RUNNING::${color_reset}${color_cyan} findomain -t $DOMAIN -q | grep \"$DOMAIN_ESCAPED$\" | sort -u | tee findomain.txt${color_reset}"
    findomain -t "$DOMAIN" -q | grep "$DOMAIN_ESCAPED$" | sort -u | tee findomain.txt
    echo -e ""
fi


if [ ! -s all-subs-final.txt ]; then
    {
        [ -f subfinder.txt ] && cat subfinder.txt
        [ -f assetfinder.txt ] && cat assetfinder.txt
        [ -f findomain.txt ] && cat findomain.txt
    } | sort -u > all-subs.txt
    echo -e "${color_green}Passive subdomains: $(wc -l < all-subs.txt 2>/dev/null || echo 0) ${color_reset}"
    cat all-subs.txt 2>/dev/null
    echo -e ""
    
    if [ -s all-subs.txt ]; then
        WILD_HITS=$(wildcard_dns_hits "$DOMAIN")
        if [ "$WILD_HITS" -gt 0 ]; then
            echo -e "${color_yellow}Wildcard DNS detected (*.$DOMAIN resolves) — skipping permutations${color_reset}"
            cp all-subs.txt all-subs-final.txt
        else
            echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-subs.txt | alterx | dnsx -silent -a -resp${color_reset}"
            cat all-subs.txt | alterx -silent 2>/dev/null | sort -u > perms-temp.txt
            if [ -s perms-temp.txt ]; then
                if [ -f "$RESOLVERS" ]; then
                    dnsx -silent -l perms-temp.txt -r "$RESOLVERS" -a -resp 2>/dev/null | awk '{gsub(/\.$/,"",$1); print $1}' | sort -u > perms-live.txt
                else
                    dnsx -silent -l perms-temp.txt -a -resp 2>/dev/null | awk '{gsub(/\.$/,"",$1); print $1}' | sort -u > perms-live.txt
                fi
                comm -23 perms-live.txt <(sort -u all-subs.txt) > perms-new.txt
                NEW_PERMS=$(wc -l < perms-new.txt | tr -d '[:space:]')
                if [ "$NEW_PERMS" -gt 0 ]; then
                    cat all-subs.txt perms-new.txt | sort -u > all-subs-final.txt
                    echo -e "${color_green}Permutations: $NEW_PERMS genuinely new live hosts${color_reset}"
                else
                    cp all-subs.txt all-subs-final.txt
                    echo -e "Permutations resolved but none were new"
                    echo -e ""
                fi
            else
                echo -e "${color_yellow}alterx generated no permutations${color_reset}"
                cp all-subs.txt all-subs-final.txt
            fi
        fi
        rm -f perms-temp.txt
    else
        cp all-subs.txt all-subs-final.txt
    fi
fi

echo -e "${color_green}Total unique subdomains: $(wc -l < all-subs-final.txt 2>/dev/null || echo 0) ${color_reset}"
cat all-subs-final.txt

#-----------------------------------------------------------------------------------
#	PHASE_2: Live probing by httpx
#-----------------------------------------------------------------------------------

if [ "$START_PHASE" -le 2 ]; then
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    echo -e "\n${color_yellow}PHASE_2: Live Probing by httpx${color_reset}"
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    if [ -s all-subs-final.txt ]; then
        echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-subs-final.txt | httpx -silent -threads 200 -status-code -tech-detect -title -location -ip -cname${color_reset}"
        cat all-subs-final.txt | "$HTTPX_BIN" -silent -threads 200 -status-code -tech-detect -title -location -ip -cname | tee httpx-raw.txt
        awk '{print $1}' httpx-raw.txt > live-urls.txt
    else
        echo -e "${color_red}all-subs-final.txt is empty, Skipping httpx${color_reset}"
        > live-urls.txt
    fi
fi

#-----------------------------------------------------------------------------------
#	PHASE_3: Crawling + Historical URLs
#-----------------------------------------------------------------------------------

if [ "$START_PHASE" -le 3 ]; then
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    echo -e "\n${color_yellow}PHASE_3: Crawling${color_reset}"
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    if [ -s live-urls.txt ]; then
        echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat live-urls.txt | katana -d 4 -rl 10 -c 5 -silent | tee crawled-urls.txt${color_reset}"
        cat live-urls.txt | katana -d 4 -rl 10 -c 5 -silent | tee crawled-urls.txt | roller
        echo -e ""
    else
        echo -e "${color_red}live-urls.txt Not Found${color_reset}"
    fi

    echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-subs-final.txt | gau --subs > archive-gau.txt${color_reset}"
    timeout 300 bash -c 'cat all-subs-final.txt | gau --subs 2>/dev/null' > archive-gau.txt || true
    
    echo -e ""
    
    echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-subs-final.txt | waybackurls > archive-wayback.txt${color_reset}"
    timeout 300 bash -c 'cat all-subs-final.txt | waybackurls 2>/dev/null' > archive-wayback.txt || true
    cat archive-gau.txt archive-wayback.txt 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > archive-urls.txt
    ARCHIVE_COUNT=$(wc -l < archive-urls.txt | tr -d '[:space:]')
    if [ "$ARCHIVE_COUNT" -gt 0 ]; then
        echo -e "${color_green}Historical URLs recovered: $ARCHIVE_COUNT${color_reset}"
    else
        echo -e "${color_yellow}Archive returned 0 URLs (providers rate-limiting or target too new)${color_reset}"
    fi
fi

#-----------------------------------------------------------------------------------
#	PHASE_4: Filters
#-----------------------------------------------------------------------------------

if [ "$START_PHASE" -le 4 ]; then
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    echo -e "\n${color_yellow}PHASE_4: Filters${color_reset}"
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    {
        [ -f crawled-urls.txt ] && cat crawled-urls.txt
        [ -f archive-urls.txt ] && cat archive-urls.txt
    } | sort -u > all-urls-temp.txt

    if [ -s all-urls-temp.txt ]; then
        echo -e "${color_green}Extracting In-Scope URLs::${color_reset}"
        echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-urls-temp.txt | grep -E '^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)' | sort -u > all-urls.txt${color_reset}"
        cat all-urls-temp.txt | grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" | sort -u > all-urls.txt
        echo -e "Done and saved in all-urls.txt"
        
        echo -e ""
        
        echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-urls-temp.txt | grep -vE '^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)' | sort -u > external-urls.txt${color_reset}"
        cat all-urls-temp.txt | grep -vE "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" | sort -u > external-urls.txt
        rm -f all-urls-temp.txt
        echo -e "Done and saved in external-urls.txt"
        
        echo -e ""

        echo -e "${color_green}Extracting Parameters, JS, APIs, and Sensitive Files::${color_reset}"
        echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-urls.txt | grep '=' | sort -u > urls-with-params.txt${color_reset}"
        cat all-urls.txt | grep '=' | sort -u > urls-with-params.txt
        echo -e "Done and saved in urls-with-params.txt"
        echo -e ""
        echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-urls.txt | grep -E '\.js(\?|$)' | sort -u > js-urls.txt${color_reset}"
        cat all-urls.txt | grep -E "\.js(\?|$)" | sort -u > js-urls.txt
        echo -e "Done and saved in js-urls.txt"
        echo -e ""
        echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-urls.txt | grep -E '\.(xls|xml|xlsx|json|pdf|sql|doc|docx|pptx|txt|zip|tar\.gz|tgz|bak|7z|rar|log|cache|secret|db|backup|yml|gz|config|csv|yaml|md|md5|tar|xz|7zip|p12|pem|key|crt|csr|sh|pl|py|java|class|jar|war|ear|sqlitedb|sqlite3|dbf|db3|accdb|mdb|sqlcipher|gitignore|env|ini|conf|properties|plist|cfg)(\?|$)' | sort -u > sensitive-files.txt${color_reset}"
        cat all-urls.txt | grep -E "\.(xls|xml|xlsx|json|pdf|sql|doc|docx|pptx|txt|zip|tar\.gz|tgz|bak|7z|rar|log|cache|secret|db|backup|yml|gz|config|csv|yaml|md|md5|tar|xz|7zip|p12|pem|key|crt|csr|sh|pl|py|java|class|jar|war|ear|sqlitedb|sqlite3|dbf|db3|accdb|mdb|sqlcipher|gitignore|env|ini|conf|properties|plist|cfg)(\?|$)" | sort -u > sensitive-files.txt
        echo -e "Done and saved in sensitive-files.txt"
        echo -e ""
        echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-urls.txt | grep -E '\b(api|v[0-9]+|graphql|rest|endpoint|ajax)\b' | grep -E -v '\.(css|js)(\?|$)' | sort -u > api-endpoints.txt${color_reset}"
        cat all-urls.txt | grep -E "\b(api|v[0-9]+|graphql|rest|endpoint|ajax)\b" | grep -E -v "\.(css|js)(\?|$)" | sort -u > api-endpoints.txt
        echo -e "Done and saved in api-endpoints.txt"
    else
        echo -e "${color_red}No URLs found to filter.${color_reset}"
        > all-urls.txt; > external-urls.txt; > urls-with-params.txt; > js-urls.txt; > sensitive-files.txt; > api-endpoints.txt
    fi
fi

#-----------------------------------------------------------------------------------
#	PHASE_5: JS Intelligence & Secrets
#-----------------------------------------------------------------------------------

if [ "$START_PHASE" -le 5 ] && [ "$HAVE_GREP_P" -eq 1 ]; then
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    echo -e "\n${color_yellow}PHASE_5: JS Intelligence & Secrets${color_reset}"
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"

    if ! command -v curl &> /dev/null || ! command -v xargs &> /dev/null || ! command -v md5sum &> /dev/null; then
        echo -e "${color_red}curl/xargs/md5sum missing, Skipping JS analysis${color_reset}"
    elif [ ! -s js-urls.txt ]; then
        echo -e "${color_red}js-urls.txt is empty/missing, Skipping JS analysis (run from PHASE_1)${color_reset}"
    else
        mkdir -p js-files js-findings js-sourcemaps html-pages js-deobf
        URL_MAP="url-map.txt"
        JS_FILES_DIR="js-files"
        export URL_MAP JS_FILES_DIR
        [ -f "$URL_MAP" ] || : > "$URL_MAP"
        : > js-findings/findings.jsonl

        exec 200>"$SESSION_DIR/.js-echo.lock"

        sort -u js-urls.txt | tr -d '\r' | awk -F'?' '!seen[$1]++' | awk 'NF' > .js-urls-dedup.txt
        EXPECTED_JS=$(wc -l < .js-urls-dedup.txt | tr -d '[:space:]')
        : > .js-done-urls.txt

        if [ -s "$URL_MAP" ]; then
            while IFS='|' read -r mapped_file mapped_url; do
                [ -n "$mapped_file" ] || continue
                [ -n "$mapped_url" ] || continue
                [ -s "js-files/$mapped_file" ] || continue
                printf '%s\n' "$mapped_url"
            done < "$URL_MAP" | sort -u > .js-done-urls.txt
        fi
        comm -23 <(sort -u .js-urls-dedup.txt) .js-done-urls.txt > .js-pending.txt
        PENDING_JS=$(wc -l < .js-pending.txt | tr -d '[:space:]')
        ALREADY_JS=$((EXPECTED_JS - PENDING_JS))

        if [ "$PENDING_JS" -gt 0 ]; then
            echo -e "${color_cyan}JS coverage: $ALREADY_JS/$EXPECTED_JS already downloaded — fetching $PENDING_JS pending${color_reset}"
            echo -e ""
            echo -e "${color_red}RUNNING::${color_reset}${color_cyan} xargs -P $JS_THREADS on pending URLs | roller${color_reset}"
            cat .js-pending.txt | xargs -P "$JS_THREADS" -I {} bash -c 'js_fetch "$1"' _ {} | roller
            echo -e "${color_green}JS files downloaded: $(find js-files -name '*.js' 2>/dev/null | wc -l) | Map entries: $(wc -l < "$URL_MAP")${color_reset}"
        else
            echo -e "${color_cyan}js-files already fully populated ($ALREADY_JS/$EXPECTED_JS) — skipping download${color_reset}"
        fi
        rm -f .js-urls-dedup.txt .js-done-urls.txt .js-pending.txt


        if [ -s all-urls.txt ]; then
            echo -e "\n${color_green}Downloading pages & extracting inline scripts::${color_reset}"
            CANDIDATE_PAGES=$(grep -vE '\.(js|css|png|jpe?g|gif|svg|ico|woff2?|ttf|map|json|xml|pdf|zip|mp4|mp3|avi|mov|webp)(\?|$)' all-urls.txt | awk 'NF' | sort -u | wc -l | tr -d '[:space:]')
            grep -vE '\.(js|css|png|jpe?g|gif|svg|ico|woff2?|ttf|map|json|xml|pdf|zip|mp4|mp3|avi|mov|webp)(\?|$)' all-urls.txt | awk 'NF' | sort -u | head -n "$MAX_PAGES" > pages-temp.txt
            PAGE_COUNT=$(wc -l < pages-temp.txt | tr -d '[:space:]')
            if [ "$CANDIDATE_PAGES" -gt "$MAX_PAGES" ]; then
                echo -e "${color_yellow}[!] Skipped $((CANDIDATE_PAGES - MAX_PAGES)) candidate pages beyond MAX_PAGES=$MAX_PAGES (edit config to raise)${color_reset}"
            fi
            if [ "$PAGE_COUNT" -gt 0 ]; then
                INLINE_COUNT=0
                while IFS= read -r page; do
                    phash=$(printf '%s' "$page" | md5sum | cut -c1-8)
                    psafe=$(echo "$page" | sed -e 's|^https*://||' -e 's/[^A-Za-z0-9.]/_/g' -e 's/__*/_/g')
                    psafe="${psafe:0:60}"
                    pfile="html-pages/${psafe}-${phash}.html"
                    ptmp="${pfile}.part.$$"
                    rm -f "$ptmp" 2>/dev/null
                    curl -s -f -L -m 20 --retry 1 -A "$FAKE_UA" "$page" -o "$ptmp" 2>/dev/null || true
                    if [ -s "$ptmp" ]; then
                        mv -f -- "$ptmp" "$pfile"
                    else
                        rm -f "$ptmp"
                    fi
                    if [ -s "$pfile" ]; then
                        perl -0777 -ne 'while (/<script(?![^>]*\bsrc=)[^>]*>(.*?)<\/script>/gis) { print "$1\n" }' "$pfile" > "html-pages/${psafe}-${phash}.inline" 2>/dev/null || true
                        if [ -s "html-pages/${psafe}-${phash}.inline" ]; then
                            INLINE_BYTES=$(wc -c < "html-pages/${psafe}-${phash}.inline")
                            if [ "$INLINE_BYTES" -ge 20 ]; then
                                mv "html-pages/${psafe}-${phash}.inline" "js-files/page_${psafe}-${phash}.js"
                                echo "page_${psafe}-${phash}.js|$page" >> "$URL_MAP"
                                INLINE_COUNT=$((INLINE_COUNT + 1))
                            else
                                rm -f "html-pages/${psafe}-${phash}.inline"
                            fi
                        fi
                    else
                        rm -f "$pfile"
                    fi
                done < pages-temp.txt
                rm -f pages-temp.txt
                echo -e "${color_cyan}Pages scanned: $PAGE_COUNT | Inline scripts captured: $INLINE_COUNT${color_reset}"
            else
                echo -e "${color_yellow}No pages to scan for inline scripts${color_reset}"
            fi
        fi


        if command -v npx &> /dev/null; then
            echo -e "\n${color_green}Formatting JS with prettier (max ${PRETTIER_MAX_MB}MB, batches of ${PRETTIER_BATCH}, ${PRETTIER_JOBS} jobs)::${color_reset}"
            : > .prettier-list
            P_SKIP=0
            while IFS= read -r -d '' f; do
                fsize=$(wc -c < "$f")
                if [ "$fsize" -le $((PRETTIER_MAX_MB * 1024 * 1024)) ]; then
                    printf '%s\0' "$f" >> .prettier-list
                else
                    P_SKIP=$((P_SKIP + 1))
                fi
            done < <(find js-files -name '*.js' -print0)
            P_ELIGIBLE=$(tr -dc '\0' < .prettier-list | wc -c | tr -d '[:space:]')
            echo -e "${color_red}RUNNING::${color_reset}${color_cyan} npx prettier --parser babel --write — $P_ELIGIBLE files in batches of $PRETTIER_BATCH${color_reset}"
            xargs -0 -n "$PRETTIER_BATCH" -P "$PRETTIER_JOBS" bash -c 'timeout 120 npx prettier --parser babel --write "$@" >/dev/null 2>&1' _ < .prettier-list || true
            rm -f .prettier-list
            echo -e "Formatted: $P_ELIGIBLE | Skipped >${PRETTIER_MAX_MB}MB: $P_SKIP"
        else
            echo -e "${color_yellow}npx not found — skipping prettier (files analyzed as-is)${color_reset}"
        fi


        if command -v npx &> /dev/null; then
            echo -e "\n${color_green}Detecting obfuscated files::${color_reset}"
            OBF_ALL=$(grep -rlP '(_0x[a-f0-9]{4,}.*_0x[a-f0-9]{4,}|eval\(function\(p,a,c,k|eval\(atob\()' js-files/ 2>/dev/null | grep -v '/deobf_' || true)
            OBF_TOTAL=$(printf '%s\n' "$OBF_ALL" | awk 'NF' | wc -l | tr -d '[:space:]')
            OBF_LIST=$(printf '%s\n' "$OBF_ALL" | awk 'NF' | head -n "$OBF_MAX_FILES")
            OBF_TAKEN=$(printf '%s\n' "$OBF_LIST" | awk 'NF' | wc -l | tr -d '[:space:]')
            OBF_SKIPPED=$((OBF_TOTAL - OBF_TAKEN))
            if [ "$OBF_SKIPPED" -gt 0 ]; then
                echo -e "${color_yellow}[!] Skipped $OBF_SKIPPED obfuscated files beyond OBF_MAX_FILES=$OBF_MAX_FILES (edit config to raise)${color_reset}"
            fi
            if [ -n "$OBF_LIST" ]; then
                echo -e "${color_red}RUNNING::${color_reset}${color_cyan} webcrack on $OBF_TAKEN detected files${color_reset}"
                echo "$OBF_LIST" | while IFS= read -r f; do
                    bname=$(basename "$f" .js)
                    timeout 120 npx webcrack "$f" -o "js-deobf/$bname" >/dev/null 2>&1 || true
                    if [ -d "js-deobf/$bname" ]; then
                        orig_url=$(grep -m1 "^$(basename "$f")|" "$URL_MAP" | cut -d'|' -f2)
                        find "js-deobf/$bname" -name '*.js' | while IFS= read -r df; do
                            dn="deobf_${bname}_$(basename "$df" .js | tr -cd 'a-zA-Z0-9' | cut -c1-24).js"
                            cp "$df" "js-files/$dn"
                            echo "$dn|${orig_url:-$(basename "$f")} (deobfuscated)" >> "$URL_MAP"
                        done
                    fi
                done
                DEOBF_COUNT=$(find js-files -name 'deobf_*.js' 2>/dev/null | wc -l | tr -d '[:space:]')
                echo -e "${color_green}Deobfuscated files: $DEOBF_COUNT${color_reset}"
            else
                echo -e "No obfuscated files detected"
                echo -e ""
            fi
        fi


        if command -v trufflehog &> /dev/null && command -v jq &> /dev/null; then
            TH_FLAGS="--json"
            [ "$TRUFFLEHOG_VERIFY" = "1" ] && TH_FLAGS="--only-verified --json"
            echo -e "${color_red}RUNNING::${color_reset}${color_cyan} trufflehog filesystem js-files/ $TH_FLAGS${color_reset}"
            trufflehog filesystem js-files/ $TH_FLAGS 2>/dev/null \
              | jq -r '[.SourceMetadata.Data.Filesystem.file // "unknown", (.SourceMetadata.Data.Filesystem.raw // "" | gsub("\n";" ") | .[0:160]), .DetectorName] | join("::")' 2>/dev/null \
              | sed 's|js-files/||' > js-findings/trufflehog.txt || true
            TH_COUNT=$(wc -l < js-findings/trufflehog.txt | tr -d '[:space:]')
            [ "$TH_COUNT" -gt 0 ] && echo -e "${color_green}Trufflehog findings: $TH_COUNT${color_reset}" || echo -e "${color_yellow}Trufflehog: 0 findings${color_reset}"
            echo -e ""
        else
            if ! command -v trufflehog &> /dev/null; then
                echo -e "${color_yellow}trufflehog not found — skipping verified secrets${color_reset}"
            else
                echo -e "${color_yellow}jq not found — skipping trufflehog JSON parsing${color_reset}"
            fi
        fi

        hunt "Cloud & SaaS tokens" '\b(AKIA[0-9A-Z]{16}|sk_live_[0-9a-zA-Z]{24}|gh[pousr]_[a-zA-Z0-9]{36}|AIza[0-9A-Za-z\-_]{35}|xox[baprs]-[0-9a-zA-Z-]{10,}|SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}|glpat-[0-9A-Za-z_-]{20,}|npm_[A-Za-z0-9]{36}|hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+|discord(app)?\.com/api/webhooks/[0-9]{15,}/[A-Za-z0-9_-]{50,}|[0-9]{8,10}:AA[A-Za-z0-9_-]{33}|key-[0-9a-f]{32}|AC[a-f0-9]{32})\b' "cloud-tokens.txt" '(EXAMPLE|YOUR_API_KEY|XXXX)' | roller

        hunt "JWT & Bearer tokens" '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?![A-Za-z0-9_-])|(?<![A-Za-z0-9])Bearer\s+[A-Za-z0-9\-\._~+/]{20,}' "auth-tokens.txt" | roller
        
        hunt "RSA private keys" '-----BEGIN[ A-Z0-9_-]*PRIVATE KEY-----' "rsa-keys.txt" | roller
        
        hunt "Database credentials in URIs" '((mongodb(\+srv)?|postgresql?|mysql|redis|amqps?|mssql)://[^\s\x22\x27@/]{1,64}:[^\s\x22\x27@]{1,128}@)' "db-creds.txt" | roller
        
        hunt "Azure storage keys" 'AccountKey=[A-Za-z0-9+/]{60,}={0,2}' "azure-keys.txt" | roller
        
        hunt "Google service accounts" '"type"\s*:\s*"service_account"' "service-accounts.txt" | roller
        
        hunt "OAuth & app IDs" '(?i)(client_id|client_secret|app_id|app_secret|tenant_id)[\x22\x27\s]*[:=][\x22\x27\s]*[a-zA-Z0-9\-_]{10,}|\d+[a-z0-9_-]*\.apps\.googleusercontent\.com' "oauth-configs.txt" '[:=][\x22\x27\s]*(undefined|null|true|false|function)$' | roller
        
        hunt "Presigned S3 URLs" '[?&]X-Amz-(Signature|Credential)=' "presigned-urls.txt" | roller
        
        hunt "S3 buckets" '\b[a-z0-9][a-z0-9.-]*\.s3([.-][a-z0-9-]+)?\.amazonaws\.com\b|s3://[a-zA-Z0-9.-]+' "s3-buckets.txt" | roller
        
        hunt "Firebase & Supabase & Appwrite" '[a-zA-Z0-9.-]+\.(firebaseio\.com|firebaseapp\.com|supabase\.co|appwrite\.io)' "baas-urls.txt" | roller
        hunt "Basic auth URLs" 'https?://[a-zA-Z0-9_-]+:[^\s\x22\x27@]{3,}@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "basic-auth.txt" | roller
        
        hunt "Source maps" 'sourceMappingURL\s*=\s*\K[^\s\x22\x27]+\.map' "source-maps.txt" | roller
        
        hunt "Hidden internal paths" '(?<=[\x22\x27])(/(api|admin|v[0-9]|internal|graphql|dev|staging|auth|login|users|config|payment|upload|download)[a-zA-Z0-9_/?=&.-]*)(?=[\x22\x27])' "hidden-paths.txt" | roller
        
        hunt "External URLs" 'https?://[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}[a-zA-Z0-9/=?&._~:%-]*' "js-external-urls.txt" '(w3\.org|react\.dev|nextjs\.org|schema\.org|localhost|github\.com|github\.io|npmjs\.com|mozilla\.org|example\.com|ckeditor\.com|formatjs\.io|strapi\.io|docs\.strapi\.io|analytics\.strapi\.io|strapi-ai\.apps\.strapi\.io|redux\.js\.org|redux-toolkit\.js\.org|react-dnd\.github\.io|docs\.sentry\.io|vercel\.com|va\.vercel-scripts\.com|clarity\.ms|bit\.ly|socket\.io|opensource\.org|stackoverflow\.com|lea\.verou\.me|reactjs\.org)' | roller
        
        hunt "Internal hostnames" '\b[a-z0-9][a-z0-9-]*\.(internal|corp|local|intranet|staging|uat)\b' "internal-hosts.txt" | roller
        
        hunt "Debug endpoints" '(/actuator/(env|heapdump|beans|configprops|mappings|threaddump)|/debug/pprof|/debug/vars|/_debug/vars)' "debug-endpoints.txt" | roller
        
        hunt "Debug flags enabled" '(?i)\bdebug\b\s*[:=]\s*[\x22\x27]?(true|1)' "debug-flags.txt" | roller
        
        hunt "DOM XSS sinks" '\b(innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval|Function|srcdoc)\b\s*\(|\bdocument\.cookie\b' "dom-sinks.txt" | roller
        
        hunt "GraphQL operations" '(query|mutation)\s+[a-zA-Z0-9_]+\s*\{' "graphql.txt" | roller
        
        hunt "Developer comments" '(?<=//|/\*)\s*(TODO|FIXME|HACK|BUG|XXX)[^\r\n]{0,120}' "dev-comments.txt" | roller
        
        hunt "Emails" '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "emails.txt" '(sentry\.io|example\.com)' | roller
        
        hunt "IP addresses" '\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b' "ip-addresses.txt" | roller
        
        hunt "WebSockets" 'wss?://[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}[a-zA-Z0-9/=?&._~:%-]*' "websockets.txt" | roller
        
        hunt "Generic secrets" '(?i)(api_key|apikey|secret|token|password|auth_token)[\x22\x27\s]*[:=][\x22\x27\s]*[a-zA-Z0-9\-_=]{8,}' "generic-secrets.txt" '[:=][\x22\x27\s]*(undefined|null|true|false|function|your[a-z0-9_-]*|changeme|placeholder|dummy|redacted|x{8,}|\*{8,}|123456789)$' | roller


        if [ -s js-findings/source-maps.txt ]; then
            echo -e "\n${color_cyan}Recovering source maps::${color_reset}"
            while IFS= read -r line; do
                jsname="${line#./}"
                jsname="${jsname%%:*}"
                mapref=$(echo "$line" | sed 's/^[^:]*:[0-9]*://')
                orig_url=$(grep -m1 "^${jsname}|" "$URL_MAP" | cut -d'|' -f2)
                [ -z "$orig_url" ] && continue
                case "$mapref" in
                    http*)  map_url="$mapref" ;;
                    //*)    map_url="https:$mapref" ;;
                    /*)     map_url="$(echo "$orig_url" | sed -E 's|^(https?://[^/]+).*|\1|')$mapref" ;;
                    *)      map_url="$(echo "$orig_url" | sed -E 's|[^/]*$||')$mapref" ;;
                esac
                mapname="${jsname%.js}-$(printf '%s' "$mapref" | md5sum | cut -c1-6).map"
                echo -e "${color_red}RUNNING::${color_reset}${color_cyan} curl '$map_url' → js-sourcemaps/$mapname${color_reset}"
                curl -s -k -L -m 20 -A "$FAKE_UA" "$map_url" -o "js-sourcemaps/$mapname" 2>/dev/null || true
                [ -s "js-sourcemaps/$mapname" ] || rm -f "js-sourcemaps/$mapname"
            done < js-findings/source-maps.txt
            echo -e "${color_green}Recovered maps: $(find js-sourcemaps -name '*.map' 2>/dev/null | wc -l)${color_reset}"
        fi
    fi
fi

#-----------------------------------------------------------------------------------
#	Summary table
#-----------------------------------------------------------------------------------

print_summary() {
    local tier_label="$1" tier_color="$2"
    shift 2
    echo -e "\n${tier_color} $tier_label${color_reset}"
    for entry in "$@"; do
        local label="${entry%%:*}" file="${entry#*:}" n=0 row_color
        [ -f "js-findings/$file" ] && n=$(wc -l < "js-findings/$file" | tr -d '[:space:]')
        row_color="${color_white}"
        [ "$n" -gt 0 ] && row_color="$tier_color"
        printf "   %-24s" "$label"
        printf '%b%6d%b\n' "$row_color" "$n" "$color_reset"
    done
}

if [ -d js-findings ]; then
    echo -e "\n${color_yellow}──────────────── JS Analysis Summary ────────────────${color_reset}"
    JS_TOTAL=$(find js-files -name '*.js' 2>/dev/null | wc -l | tr -d '[:space:]')
    PAGES_DONE=$(ls html-pages/*.html 2>/dev/null | wc -l | tr -d '[:space:]')
    DEOBF_DONE=$(find js-files -name 'deobf_*.js' 2>/dev/null | wc -l | tr -d '[:space:]')
    TH_DONE=$(wc -l < js-findings/trufflehog.txt 2>/dev/null | tr -d '[:space:]')
    echo -e "${color_cyan} coverage: JS files: $JS_TOTAL | pages: $PAGES_DONE | deobfuscated: $DEOBF_DONE | trufflehog: $TH_DONE${color_reset}"
    print_summary "Tier A :: confirmed secrets" "${color_red}" \
        "trufflehog:trufflehog.txt" \
        "cloud-tokens:cloud-tokens.txt" \
        "auth-tokens:auth-tokens.txt" \
        "rsa-keys:rsa-keys.txt" \
        "db-creds:db-creds.txt" \
        "azure-keys:azure-keys.txt" \
        "service-accounts:service-accounts.txt" \
        "oauth-configs:oauth-configs.txt" \
        "presigned-urls:presigned-urls.txt"
    print_summary "Tier B :: strong signal" "${color_yellow}" \
        "s3-buckets:s3-buckets.txt" \
        "baas-urls:baas-urls.txt" \
        "basic-auth:basic-auth.txt" \
        "source-maps:source-maps.txt"
    print_summary "Tier C :: recon intel" "${color_cyan}" \
        "hidden-paths:hidden-paths.txt" \
        "js-external-urls:js-external-urls.txt" \
        "internal-hosts:internal-hosts.txt" \
        "debug-endpoints:debug-endpoints.txt" \
        "debug-flags:debug-flags.txt" \
        "dom-sinks:dom-sinks.txt" \
        "graphql:graphql.txt" \
        "dev-comments:dev-comments.txt" \
        "emails:emails.txt" \
        "ip-addresses:ip-addresses.txt" \
        "websockets:websockets.txt" \
        "generic-secrets:generic-secrets.txt"
fi


#-----------------------------------------------------------------------------------
#	Report
#-----------------------------------------------------------------------------------

HTML_FILE="report.html"
URL_MAP="url-map.txt"
SECRETS_UNREDACTED="secrets-unredacted.txt"
[ "$REDACT" -eq 1 ] && : > "$SECRETS_UNREDACTED"

ta() {
    if [ -f "$1" ]; then
        sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$1"
    else
        echo "No data found."
    fi
}

fcount() {
    if [ -f "$1" ]; then wc -l < "$1" | tr -d '[:space:]'; else echo 0; fi
}


if [ -s js-findings/hidden-paths.txt ] && [ -s "$URL_MAP" ]; then
    awk -F: -v mapfile="$URL_MAP" '
    BEGIN { while ((getline l < mapfile) > 0) { split(l, p, "|"); um[p[1]] = p[2] } close(mapfile) }
    {
        full = $0
        sub(/^[^:]*:[0-9]*:/, "", full)
        path = full
        fname = $1
        u = (fname in um) ? um[fname] : ""
        if (u == "") next
        sub(/^https?:\/\//, "", u)
        sub(/\/.*/, "", u)
        print path "\t" u
    }' js-findings/hidden-paths.txt | sort -u > js-findings/.hp-pairs.txt
    awk -F'\t' '
    { if ($1 in seen) { if (index(hosts[$1], "\t" $2 "\t") == 0) hosts[$1] = hosts[$1] $2 "\t" }
      else { seen[$1] = 1; hosts[$1] = "\t" $2 "\t"; order[++c] = $1 } }
    END { for (i = 1; i <= c; i++) { gsub(/\t+/, ", ", hosts[order[i]]); print order[i] "\t" hosts[order[i]] } }
    ' js-findings/.hp-pairs.txt > js-findings/hidden-paths-mapped.txt
    rm -f js-findings/.hp-pairs.txt
fi

C_SUBS=$(fcount all-subs-final.txt)
C_LIVE=$(fcount live-urls.txt)
C_ARCHIVE=$(fcount archive-urls.txt)
C_PERMS=$(wc -l < perms-new.txt 2>/dev/null | tr -d '[:space:]')
[ -z "$C_PERMS" ] && C_PERMS=0
C_PARAMS=$(fcount urls-with-params.txt)
C_JSURLS=$(fcount js-urls.txt)
C_SENS=$(fcount sensitive-files.txt)
C_JSFILES=$(find js-files -name '*.js' 2>/dev/null | wc -l | tr -d '[:space:]')

TIER_A_TOTAL=0
for f in trufflehog.txt cloud-tokens.txt auth-tokens.txt rsa-keys.txt db-creds.txt azure-keys.txt service-accounts.txt oauth-configs.txt presigned-urls.txt; do
    TIER_A_TOTAL=$((TIER_A_TOTAL + $(fcount "js-findings/$f")))
done


JS_TABS=()
js_tab() {
    local id="$1" title="$2" tier="$3" desc="$4" action="$5"
    shift 5
    JS_TABS+=("$id|$title|$tier|$desc|$action|$*")
}

js_tab "tab-js-th" "Trufflehog" "a" "Secrets detected by trufflehog with provider verification — high-confidence findings requiring scope and authorization review." "The highest confidence findings in this report. Each key was tested against its provider and is ACTIVE. Handle with care, verify scope, report." "trufflehog.txt:Verified"
js_tab "tab-js-urls" "JS Ext URLs" "c" "Full external URLs embedded inside the JS bundles and inline scripts." "Check for subdomain takeovers, or probe them for SSRF vectors." "js-external-urls.txt:URL"
js_tab "tab-js-hosts" "Internal Hosts" "c" "Internal hostnames like *.internal, *.corp, *.staging found in the code — possible hidden infrastructure." "Check which ones resolve publicly, and use them to map the real internal network behind the target." "internal-hosts.txt:Host"
js_tab "tab-js-code" "Code Intel" "c" "GraphQL ops, dev comments, emails, IPs, WebSockets found in the code." "Read dev comments carefully, devs leak temporary creds and hidden backup names there." "graphql.txt:GraphQL dev-comments.txt:Comment emails.txt:Email ip-addresses.txt:IP websockets.txt:WebSocket"
js_tab "tab-js-generic" "Generic Secrets" "c" "Variables named password/secret/token with assigned values. Noisy by design." "Manually verify each one, these are leads not confirmations." "generic-secrets.txt:Secret"
js_tab "tab-js-maps" "SourceMaps" "b" "Exposed .map files, recovered into js-sourcemaps/ in your session folder." "Open the recovered sources to read the original unminified logic." "source-maps.txt:SourceMap"
js_tab "tab-js-baas" "BaaS URLs" "b" "Direct links to Firebase, Supabase or Appwrite instances." "Test for unauthenticated read/write access on the database." "baas-urls.txt:BaaS"
js_tab "tab-js-storage" "Cloud Storage" "b" "S3 buckets and presigned URLs found in JS." "Check bucket policies for unauthenticated List/Put/Delete, presigned URLs may still be live." "s3-buckets.txt:S3 presigned-urls.txt:Presigned"
js_tab "tab-js-oauth" "OAuth & IDs" "a" "Client IDs, tenant IDs or app secrets used for third-party integrations." "An exposed client_secret may increase token-forgery or account-compromise risk depending on provider configuration and scope." "oauth-configs.txt:OAuth-ID"
js_tab "tab-js-auth" "Auth & JWT" "a" "JWT and Bearer tokens hardcoded for API access, plus basic-auth URLs." "Decode the JWT, check the algorithm and expiry, then test its privileges." "auth-tokens.txt:JWT/Bearer basic-auth.txt:Basic-Auth"
js_tab "tab-js-keys" "Keys & Creds" "a" "Private keys, database URIs with credentials, Azure keys, service accounts." "These are direct credentials. Connect and verify scope before reporting." "rsa-keys.txt:Private-Key db-creds.txt:DB-Creds azure-keys.txt:Azure-Key service-accounts.txt:Svc-Account"
js_tab "tab-js-tokens" "Tokens" "a" "API keys for Stripe, Google, GitHub, Slack, Discord, Telegram, SendGrid, NPM and more." "Validate each key against its provider API to measure impact." "cloud-tokens.txt:Token"


JS_BUTTONS=""
for spec in "${JS_TABS[@]}"; do
    IFS='|' read -r id title tier desc action files <<< "$spec"
    local_total=0
    for entry in $files; do
        f="${entry%%:*}"
        local_total=$((local_total + $(fcount "js-findings/$f")))
    done
    case "$tier" in
        a) tcolor="#f85149" ;;
        b) tcolor="#d29922" ;;
        *) tcolor="#8b949e" ;;
    esac
    JS_BUTTONS+="          <button class=\"tablinks\" onclick=\"openTab(event, '$id')\" style=\"color:$tcolor;\">$title <span class=\"badge\">$local_total</span></button>"$'\n'
done

HP_COUNT=$(fcount js-findings/hidden-paths-mapped.txt)
DS_COUNT=$(fcount js-findings/dom-sinks.txt)
EXTRA_JS_BUTTONS=""
if [ -s js-findings/hidden-paths-mapped.txt ]; then
    EXTRA_JS_BUTTONS+="          <button class=\"tablinks active\" onclick=\"openTab(event, 'tab-js-paths')\" style=\"color:#8b949e;\">Hidden Paths <span class=\"badge\">$HP_COUNT</span></button>"$'\n'
fi
if [ -s js-findings/dom-sinks.txt ]; then
    EXTRA_JS_BUTTONS+="          <button class=\"tablinks\" onclick=\"openTab(event, 'tab-js-sinks')\" style=\"color:#8b949e;\">DOM Sinks <span class=\"badge\">$DS_COUNT</span></button>"$'\n'
fi

cat << EOF > "$HTML_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Reconly report</title>
  <style>
     body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #0d1117; color: #c9d1d9; margin: 0; padding: 3px; }
     .container { max-width: 1300px; margin: auto; }
     h1 { color: #58a6ff; text-align: center; border-bottom: 1px solid #30363d; padding-bottom: 3px; font-size: 2.5em; margin-top: 3px; }
     .timestamp { text-align: center; color: #8b949e; font-size: 16px; margin-bottom: 3px; }

     .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-bottom: 3px; }
     .card { background-color: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 5px; text-align: center; border-top: 3px solid #238636; }
     .card h3 { margin: 0 0 8px 0; color: #8b949e; font-size: 14px; text-transform: uppercase; }
     .card p { margin: 0; font-size: 24px; font-weight: bold; color: #ffffff; }
     .alert-card { border-top: 3px solid #f85149; }
     .alert-card p { color: #f85149; }
     .warn-card { border-top: 3px solid #d29922; }
     .warn-card p { color: #d29922; }

     .tabs { overflow: hidden; background-color: #161b22; border: 1px solid #30363d; border-radius: 8px 8px 0 0; display: flex; flex-wrap: wrap; }
     .tabs button { background-color: inherit; border: none; outline: none; cursor: pointer; padding: 10px 12px; transition: 0.3s; color: #8b949e; font-size: 12px; font-weight: bold; flex-grow: 1; }
     .tabs button:hover { background-color: #30363d; color: #c9d1d9; }
     .tabs button.active { background-color: #238636; color: #ffffff; }
     .badge { background-color: #30363d; color: #c9d1d9; padding: 2px 7px; border-radius: 10px; font-size: 11px; margin-left: 4px; }

     .tabcontent { display: none; padding: 20px; border: 1px solid #30363d; border-top: none; background-color: #0d1117; border-radius: 0 0 8px 8px; }
     .data-box { width: 100%; height: 500px; background-color: #010409; color: #39d353; border: 1px solid #30363d; padding: 15px; font-family: 'Courier New', Courier, monospace; font-size: 14px; resize: vertical; outline: none; box-sizing: border-box; }

     .intel-box { background-color: #1f2428; border-left: 4px solid #58a6ff; padding: 15px; margin-bottom: 15px; border-radius: 4px; }
     .intel-box h4 { margin: 0 0 8px 0; color: #58a6ff; font-size: 16px; }
     .intel-box p { margin: 0 0 5px 0; font-size: 14px; color: #c9d1d9; }
     .intel-box .action { font-weight: bold; color: #39d353; }

     .table-container { max-height: 600px; overflow-y: auto; border: 1px solid #30363d; border-radius: 4px; }
     .results-table { width: 100%; border-collapse: collapse; text-align: left; }
     .results-table th { background-color: #238636; color: white; padding: 12px; position: sticky; top: 0; z-index: 1; font-size: 14px; }
     .results-table td { padding: 10px 12px; border-bottom: 1px solid #21262d; font-size: 13.5px; }
     .results-table tr:nth-child(even) { background-color: #161b22; }
     .results-table tr:hover { background-color: #1f2428; }
     .col-file { width: 40%; word-break: break-all; }
     .col-file a { color: #58a6ff; text-decoration: none; font-size: 13px; }
     .col-file a:hover { text-decoration: underline; }
     .col-line { width: 8%; color: #d29922; text-align: center; font-weight: bold; }
     .col-type { width: 12%; color: #bc8cff; text-align: center; font-size: 12px; }
     .col-finding { width: 40%; word-break: break-all; }
     .col-finding code { background: #010409; padding: 3px 6px; border-radius: 4px; font-family: 'Courier New', Courier, monospace; color: #ff7b72; border: 1px solid #30363d; }

     ::-webkit-scrollbar { width: 8px; height: 8px; }
     ::-webkit-scrollbar-track { background: #0d1117; }
     ::-webkit-scrollbar-thumb { background: #30363d; border-radius: 4px; }
     ::-webkit-scrollbar-thumb:hover { background: #58a6ff; }

     .footer { margin-top: 3px; text-align: center; font-size: 13px; color: #8b949e; border-top: 1px solid #30363d; padding-top: 20px; }
     a { color: #58a6ff; text-decoration: none; }
     a:hover { text-decoration: underline; }
  </style>
  <script>
    function openTab(evt, tabName) {
        var i, tabcontent, tablinks;
        tabcontent = document.getElementsByClassName("tabcontent");
        for (i = 0; i < tabcontent.length; i++) { tabcontent[i].style.display = "none"; }
        tablinks = document.getElementsByClassName("tablinks");
        for (i = 0; i < tablinks.length; i++) { tablinks[i].className = tablinks[i].className.replace(" active", ""); }
        document.getElementById(tabName).style.display = "block";
        evt.currentTarget.className += " active";
    }
  </script>
</head>
<body>
   <div class="container">
       <div class="timestamp">Scan generated on: <strong>$TIMESTAMP</strong> | Directory: <code>$SESSION_DIR</code></div>
       <div class="grid">
          <div class="card"><h3>Subdomains</h3><p>$C_SUBS</p></div>
          <div class="card"><h3>Live</h3><p>$C_LIVE</p></div>
          <div class="card"><h3>Perms</h3><p>$C_PERMS</p></div>
          <div class="card"><h3>Archive</h3><p>$C_ARCHIVE</p></div>
          <div class="card"><h3>JS Files</h3><p>$C_JSFILES</p></div>
          <div class="card warn-card"><h3>Sensitive</h3><p>$C_SENS</p></div>
          <div class="card alert-card"><h3>Secrets</h3><p>$TIER_A_TOTAL</p></div>
       </div>

       <div class="tabs">
          <button class="tablinks" onclick="openTab(event, 'tab-allsubs')">All Subdomains</button>
          <button class="tablinks" onclick="openTab(event, 'tab-live')">Live URLs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-perms')">Permutations</button>
          <button class="tablinks" onclick="openTab(event, 'tab-archive')">Archive URLs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-urls')">All Crawled URLs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-params')">Params</button>
          <button class="tablinks" onclick="openTab(event, 'tab-jsurls')">JS URLs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-api')">APIs</button>
          <button class="tablinks" onclick="openTab(event, 'tab-sens')" style="color:#f85149;">Sensitive</button>
          <button class="tablinks" onclick="openTab(event, 'tab-subfinder')">Subfinder</button>
          <button class="tablinks" onclick="openTab(event, 'tab-assetfinder')">Assetfinder</button>
          <button class="tablinks" onclick="openTab(event, 'tab-findomain')">Findomain</button>
          <button class="tablinks" onclick="openTab(event, 'tab-katana')">Katana Actives</button>
          <button class="tablinks" onclick="openTab(event, 'tab-external')">External URLs</button>
$EXTRA_JS_BUTTONS$JS_BUTTONS       </div>
EOF


cat << EOF >> "$HTML_FILE"
       <div id="tab-allsubs" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta all-subs-final.txt)</textarea>
       </div>
       <div id="tab-live" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta live-urls.txt)</textarea>
       </div>
       <div id="tab-perms" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta perms-new.txt)</textarea>
       </div>
       <div id="tab-archive" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta archive-urls.txt)</textarea>
       </div>
       <div id="tab-urls" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta all-urls.txt)</textarea>
       </div>
       <div id="tab-params" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta urls-with-params.txt)</textarea>
       </div>
       <div id="tab-jsurls" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta js-urls.txt)</textarea>
       </div>
       <div id="tab-api" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta api-endpoints.txt)</textarea>
       </div>
       <div id="tab-sens" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta sensitive-files.txt)</textarea>
       </div>
       <div id="tab-subfinder" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta subfinder.txt)</textarea>
       </div>
       <div id="tab-assetfinder" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta assetfinder.txt)</textarea>
       </div>
       <div id="tab-findomain" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta findomain.txt)</textarea>
       </div>
       <div id="tab-katana" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta crawled-urls.txt)</textarea>
       </div>
       <div id="tab-external" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(ta external-urls.txt)</textarea>
       </div>
EOF


if [ -s js-findings/hidden-paths-mapped.txt ]; then
{
    cat << EOF
       <div id="tab-js-paths" class="tabcontent" style="display:block;">
          <div class="intel-box">
             <h4>Hidden API Paths — deduplicated &amp; mapped to hosts</h4>
             <p><strong>What is this?</strong> Every unique path found across all JS files and inline scripts, one row each, paired with the host(s) it appeared on. Build Burp requests directly: Host + Path.</p>
             <p><span class="action">Actionable impact:</span> Prefix each path with its host (or the API base like https://api.target.com/api/v1) and test for IDOR, Broken Access Control, and hidden admin functionality.</p>
          </div>
          <div class="table-container">
             <table class="results-table">
                <thead><tr><th style="width:45%;">Path</th><th style="width:55%;">Host(s) where found</th></tr></thead>
                <tbody>
 $(awk -F'\t' '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
    { printf "<tr><td class=\"col-finding\"><code>%s</code></td><td class=\"col-file\">%s</td></tr>\n", esc($1), esc($2) }
' js-findings/hidden-paths-mapped.txt)
                </tbody>
             </table>
          </div>
       </div>
EOF
} >> "$HTML_FILE"
fi


if [ -s js-findings/dom-sinks.txt ]; then
{
    cat << 'DOMEOF'
       <div id="tab-js-sinks" class="tabcontent">
          <div class="intel-box">
             <h4>DOM XSS Sinks — typed &amp; explained</h4>
             <p><strong>What is this?</strong> Places in the code where data gets written into the page or executed. A sink alone is NOT a vulnerability. It only becomes DOM XSS if attacker-controlled input (URL params, location.hash, postMessage, localStorage) flows into it without sanitization.</p>
             <p><strong>How to read each type:</strong><br>
             • innerHTML / outerHTML / insertAdjacentHTML → HTML injection → XSS if input is unsanitized.<br>
             • eval / Function → full code execution → Critical if any input reaches them.<br>
             • document.write → legacy injection → XSS via injected script tags.<br>
             • srcdoc → iframe HTML injection → check sandbox attributes.<br>
             • document.cookie → not a sink by itself; review what the code does with cookies.</p>
             <p><span class="action">Actionable impact:</span> Open the JS file at the exact line, trace where the value comes from. If a URL parameter or fragment reaches it → that is a DOM XSS finding.</p>
          </div>
          <div class="table-container">
             <table class="results-table">
                <thead><tr><th style="width:15%;">Sink Type</th><th style="width:45%;">Source JS (Original URL)</th><th style="width:8%;">Line</th><th style="width:32%;">Code</th></tr></thead>
                <tbody>
DOMEOF
    awk -v mapfile="$URL_MAP" '
    BEGIN { while ((getline l < mapfile) > 0) { split(l, p, "|"); um[p[1]] = p[2] } close(mapfile) }
    {
        full = $0
        sub(/^[^:]*:[0-9]*:/, "", full)
        t = full
        if (t ~ /^document\.cookie/) type = "document.cookie"
        else { split(t, a, /[^A-Za-z]/); type = a[1] }
        fname = $1
        rest = substr($0, length(fname) + 2)
        i3 = index(rest, ":")
        ln = (i3 > 0) ? substr(rest, 1, i3 - 1) : "-"
        url = (fname in um) ? um[fname] : fname
        gsub(/&/, "\\&amp;", url); gsub(/"/, "\\&quot;", url)
        gsub(/&/, "\\&amp;", full); gsub(/</, "\\&lt;", full); gsub(/>/, "\\&gt;", full)
        printf "<tr><td class=\"col-type\">%s</td><td class=\"col-file\"><a href=\"%s\" target=\"_blank\" rel=\"noopener\">%s</a></td><td class=\"col-line\">%s</td><td class=\"col-finding\"><code>%s</code></td></tr>\n", type, url, url, ln, full
    }' js-findings/dom-sinks.txt
    cat << 'DOMEOF2'
                </tbody>
             </table>
          </div>
       </div>
DOMEOF2
} >> "$HTML_FILE"
fi

emit_js_tab_content() {
    local id="$1" title="$2" tier="$3" desc="$4" action="$5" files="$6"
    {
        cat << EOF
       <div id="$id" class="tabcontent">
          <div class="intel-box">
             <h4>$title</h4>
             <p><strong>What is this?</strong> $desc</p>
             <p><span class="action">Actionable impact:</span> $action</p>
          </div>
          <div class="table-container">
             <table class="results-table">
                <thead>
                   <tr>
                      <th class="col-file">Source JS (Original URL)</th>
                      <th class="col-line">Line</th>
                      <th class="col-type">Type</th>
                      <th class="col-finding">Finding</th>
                   </tr>
                </thead>
                <tbody>
EOF
        for entry in $files; do
            f="${entry%%:*}"
            label="${entry#*:}"
            [ -f "js-findings/$f" ] || continue
            awk -v lbl="$label" -v mapfile="$URL_MAP" -v redact="$REDACT" -v tier="$tier" -v secfile="$SECRETS_UNREDACTED" '
            BEGIN {
                while ((getline line < mapfile) > 0) {
                    split(line, p, "|")
                    urlMap[p[1]] = p[2]
                }
                close(mapfile)
            }
            {
                i1 = index($0, ":")
                if (i1 == 0) next
                fname = substr($0, 1, i1-1)
                rest = substr($0, i1+1)
                i2 = index(rest, ":")
                if (i2 > 0) { ln = substr(rest, 1, i2-1); m = substr(rest, i2+1) }
                else { ln = "-"; m = rest }
                url = (fname in urlMap) ? urlMap[fname] : fname
                if (redact == 1 && (tier == "a" || tier == "b")) {
                    printf "%s|%s|%s\n", url, ln, m >> secfile
                    if (length(m) > 4) {
                        m = "****redacted****" substr(m, length(m) - 3)
                    }
                }
                gsub(/&/, "\\&amp;", m)
                gsub(/</, "\\&lt;", m)
                gsub(/>/, "\\&gt;", m)
                gsub(/&/, "\\&amp;", url)
                gsub(/"/, "\\&quot;", url)
                printf "<tr><td class=\"col-file\"><a href=\"%s\" target=\"_blank\" rel=\"noopener\">%s</a></td><td class=\"col-line\">%s</td><td class=\"col-type\">%s</td><td class=\"col-finding\"><code>%s</code></td></tr>\n", url, url, ln, lbl, m
            }' "js-findings/$f"
        done
        cat << EOF
                </tbody>
             </table>
          </div>
       </div>
EOF
    } >> "$HTML_FILE"
}

for spec in "${JS_TABS[@]}"; do
    IFS='|' read -r id title tier desc action files <<< "$spec"
    emit_js_tab_content "$id" "$title" "$tier" "$desc" "$action" "$files"
done

if [ "$REDACT" -eq 1 ] && [ -s "$SECRETS_UNREDACTED" ]; then
    chmod 600 "$SECRETS_UNREDACTED" 2>/dev/null || true
    echo -e "${color_yellow}Redacted mode: full secret values kept in $SECRETS_UNREDACTED (chmod 600)${color_reset}"
fi

cat << 'EOF' >> "$HTML_FILE"
   </div>
</body>
</html>
EOF


#-----------------------------------------------------------------------------------
#	AI EXPORT - Mirror every .txt as .md (split if oversized)
#-----------------------------------------------------------------------------------

ai_export() {
	local out_dir="$SESSION_DIR/ai-export"
	local max_bytes=120000    # ~30k tokens per part
	local split_lines=8000    # fallback split when one section is huge

	mkdir -p "$out_dir"

	cat > "$out_dir/00-PROMPT.md" <<'PROMPT_EOF'
# Prompt — Bug Bounty Recon Analysis

You are a senior offensive security engineer helping with an **authorized** bug bounty engagement.
All findings below come from in-scope assets collected during a sanctioned recon run.

Data sources: subfinder, assetfinder, findomain, alterx, dnsx, httpx, katana, gau,
waybackurls, trufflehog, and custom regex hunting on JS files.

**Severity tiers (by filename):**
- **Tier A** = secrets/creds: trufflehog, cloud-tokens, auth-tokens, rsa-keys, db-creds, azure-keys, service-accounts, oauth-configs, presigned-urls
- **Tier B** = strong signal: s3-buckets, baas-urls, basic-auth, source-maps
- **Tier C** = recon intel: hidden-paths-mapped, api-endpoints, internal-hosts, debug-endpoints, graphql, dom-sinks, dev-comments, emails, websockets, ip-addresses, generic-secrets, js-external-urls
- **Infra** = subdomains, live-urls, params, sensitive-files, etc.

I will paste report files one at a time. When I'm done, produce:

1. **Prioritized Triage** — table of top 10 items:
   | Rank | Finding | Exploitability | Test approach | Est. time |

2. **Test Plans for Top 5** — for each:
   - Vulnerability class (IDOR / auth bypass / SSRF / info disclosure / etc.)
   - Exact `curl` command(s) or Burp workflow
   - Expected: vulnerable vs safe response

3. **Likely False Positives** — which findings look like noise/placeholders? Why?

4. **Missing Angles** — undertested attack surfaces, additional recon to run

5. **Quick Wins** — findings verifiable in <5 min with highest payout chance

Be concise. Skip generic methodology. Prioritize real-world impact.
PROMPT_EOF


	_md_convert() {
		local src="$1" name base md part bytes n
		name=$(basename "$src")
		base="${name%.txt}"
		md="$out_dir/$base.md"

		{
			echo "# $name"
			echo ""
			echo "> Source: \`$name\` | Lines: $(wc -l < "$src" | tr -d '[:space:]') | Size: $(( $(wc -c < "$src") / 1024 ))KB"
			echo ""
			echo '```'
			cat "$src"
			echo '```'
		} > "$md"

		bytes=$(wc -c < "$md" | tr -d '[:space:]')
		if [ "$bytes" -gt "$max_bytes" ]; then
			split -l "$split_lines" -d --additional-suffix=".md" "$md" "$out_dir/${base}_part-"
			rm -f "$md"
			n=$(ls "$out_dir/${base}_part-"*.md 2>/dev/null | wc -l | tr -d '[:space:]')
			echo -e "  ${color_yellow}split:${color_reset} %-40s → %s parts" "$name" "$n"
		else
			echo -e "  ${color_green}ok:${color_reset}    %-40s %4sKB  %5s lines" \
				"$name" \
				"$(( bytes / 1024 ))" \
				"$(wc -l < "$md" | tr -d '[:space:]')"
		fi
	}

	echo -e "\n${color_yellow}──────────────── AI Export ────────────────${color_reset}"
	echo -e "${color_cyan}00-PROMPT.md${color_reset} written"


	for src in "$SESSION_DIR"/*.txt; do
		[ -f "$src" ] || continue
		[ "$(basename "$src")" = "url-map.txt" ] && continue
		_md_convert "$src"
	done


	if [ -d "$SESSION_DIR/js-findings" ]; then
		for src in "$SESSION_DIR/js-findings"/*.txt; do
			[ -f "$src" ] || continue
			_md_convert "$src"
		done
	fi

	echo ""
	echo -e "${color_green}AI export ready → $out_dir/${color_reset}"
	echo -e "${color_cyan}Total bundles:${color_reset} $(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d '[:space:]')"
	echo ""
	echo -e "${color_cyan}How to use:${color_reset}"
	echo -e "  1. Open chat with any LLM (DeepSeek, Qwen, GLM, Claude, GPT)"
	echo -e "  2. Paste ${color_yellow}00-PROMPT.md${color_reset} first"
	echo -e "  3. Then paste any report file(s) — order doesn't matter"
	echo -e "  4. Say: Analyze now"
}

ai_export


if command -v brave-browser &> /dev/null; then brave-browser --incognito "$HTML_FILE" &> /dev/null &
elif command -v brave &> /dev/null; then brave --incognito "$HTML_FILE" &> /dev/null &
elif command -v xdg-open &> /dev/null; then xdg-open "$HTML_FILE" &> /dev/null &
elif command -v open &> /dev/null; then open "$HTML_FILE" &> /dev/null &
else echo "No Browser found";
fi

