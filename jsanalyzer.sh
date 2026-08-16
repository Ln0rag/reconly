#!/usr/bin/env bash

export LC_ALL=C
set -uo pipefail

C_CYAN="\e[36;1m"
C_GREEN="\e[32;1m"
C_RED="\e[31;1m"
C_YELLOW="\e[33;1m"
C_RESET="\e[0m"

export FAKE_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
export C_GREEN C_RED C_RESET C_CYAN

check_dependencies() {
    local deps=("curl" "grep" "awk" "sed" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${C_RED}[!] Critical Error: Required dependency '$dep' is not installed.${C_RESET}"
            exit 1
        fi
    done
}

cleanup_and_exit() {
    echo -e "\n${C_RED}[!] Execution Interrupted!${C_RESET}"
    exit 130
}
trap cleanup_and_exit SIGINT SIGTERM

print_banner() {
    clear
    echo -e "${C_CYAN}====================================================${C_RESET}"
    echo -e "${C_GREEN}   		JS Recon Engine		           ${C_RESET}"
    echo -e "${C_CYAN}====================================================${C_RESET}\n"
}

setup_session() {
    if [ "$#" -eq 1 ]; then
        RAW_INPUT="$1"
    else
        echo -e "Enter the full path to your JS links file: \c"
        read -r RAW_INPUT < /dev/tty
    fi

    JS_FILE_PATH=$(echo "$RAW_INPUT" | tr -d '\r' | awk '{$1=$1};1')

    if [ -z "$JS_FILE_PATH" ] || [ ! -f "$JS_FILE_PATH" ] || [ ! -s "$JS_FILE_PATH" ]; then
        echo -e "${C_RED}[!] Error: Invalid or empty file provided!${C_RESET}"
        exit 1
    fi

    BASE_DIR=$(dirname "$(realpath "$JS_FILE_PATH")")
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    SESSION_DIR="$BASE_DIR/JS_Scan_$TIMESTAMP"
    
    OUTPUT_DIR="$SESSION_DIR/js_files"
    GREP_DIR="$SESSION_DIR/js_grep_results"
    MAPS_DIR="$SESSION_DIR/recovered_sources"
    REPORT_FILE="$SESSION_DIR/recon_report_$TIMESTAMP.html"
    URL_MAP_FILE="$SESSION_DIR/url_mapping.txt"
    
    export SESSION_DIR OUTPUT_DIR URL_MAP_FILE MAPS_DIR
    
    mkdir -p "$OUTPUT_DIR" "$GREP_DIR" "$MAPS_DIR"
    > "$URL_MAP_FILE"
    
    echo -e "${C_CYAN}[*] Session Initialized: ${C_YELLOW}$SESSION_DIR${C_RESET}"
}

fetch_url() {
    local url="$1"
    local output_dir="$2"
    local map_file="$3"
    
    local safe_name
    safe_name=$(echo "$url" | sed -e 's|^https*://||' -e 's/[^A-Za-z0-9.]/_/g' -e 's/__*/_/g')
    safe_name="${safe_name%.js}"
    local part_file="$output_dir/$safe_name.js"
    
    local js_content
    js_content=$(curl -s -f -L -m 15 -k --retry 3 --retry-delay 2 -A "$FAKE_UA" "$url" 2>/dev/null) || true
    
    if [ -n "$js_content" ]; then
        printf "%s\n" "$js_content" > "$part_file"
        echo "$safe_name.js|$url" >> "$map_file"
        echo -e "${C_GREEN}[+] Downloaded:${C_RESET} $url"
    else
        echo -e "${C_RED}[-] Failed/Empty:${C_RESET} $url"
    fi
}
export -f fetch_url

execute_downloads() {
    local total_urls
    total_urls=$(awk 'NF' "$JS_FILE_PATH" | wc -l)
    
    echo -e "\n${C_YELLOW}[*] Spawning 5 stealth threads to fetch $total_urls JS files safely...${C_RESET}"
    printf "${C_CYAN}    $ xargs -P 5 -I {} bash -c 'fetch_url' < urls.txt\n\n${C_RESET}"
    tr -d '\r' < "$JS_FILE_PATH" | awk 'NF' | xargs -P 5 -I {} bash -c 'fetch_url "{}" "$OUTPUT_DIR" "$URL_MAP_FILE"'
    echo -e "\n${C_CYAN}[*] Downloads complete. Proceeding to Elite Analysis...${C_RESET}"
}

recover_source_maps() {
    echo -e "\n${C_YELLOW}[>] Checking for exposed Source Maps (.js.map) & recovering source trees...${C_RESET}"
    local map_file="$GREP_DIR/source_maps.txt"
    if [ -f "$map_file" ]; then
        while IFS= read -r line; do
            # Extract URL/file reference
            local map_url
            map_url=$(echo "$line" | awk -F': ' '{print $2}')
            if [[ "$map_url" =~ ^https?:// ]]; then
                echo -e "${C_GREEN}[+] Recovering source map: $map_url${C_RESET}"
                (cd "$MAPS_DIR" && curl -s -k -L "$map_url" -o "$(basename "$map_url")" 2>/dev/null || true)
            fi
        done < "$map_file"
    fi
}

run_static_analysis() {
    echo -e "\n${C_CYAN}====================================================${C_RESET}"
    echo -e "${C_GREEN}[*] Phase 2: Regex Intelligence & Sinks 		      ${C_RESET}"
    echo -e "${C_CYAN}====================================================${C_RESET}\n"

    local O="$OUTPUT_DIR"
    local R="$GREP_DIR"

    safe_grep() {
        local msg="$1"
        local regex="$2"
        local outfile="$3"
        local exclude="${4:-}"
        
        echo -e "${C_YELLOW}[>] $msg...${C_RESET}"
        if [ -z "$exclude" ]; then
            printf "${C_CYAN}    $ grep -a -r -n -P -o -e '%s' .\n${C_RESET}" "$regex"
            (cd "$O" && grep -a -r -n -P -o -e "$regex" . | sed 's|^\./||' | sort -u > "$R/$outfile" || true)
        else
            printf "${C_CYAN}    $ grep -a -r -n -P -o -e '%s' . | grep -v -i -P -e '%s'\n${C_RESET}" "$regex" "$exclude"
            (cd "$O" && grep -a -r -n -P -o -e "$regex" . | grep -v -i -P -e "$exclude" | sed 's|^\./||' | sort -u > "$R/$outfile" || true)
        fi
    }

    safe_grep "Hunting for internal endpoints & paths" '(?<=[\x22\x27])(/(api|admin|v[0-9]|internal|graphql|dev|staging|auth|login|users|config|payment|upload|download)[a-zA-Z0-9_/?=&.-]*)(?=[\x22\x27])' "hidden_paths.txt"
    safe_grep "Hunting for External URLs (Filtered)" 'https?://[a-zA-Z0-9./?=_-]+' "all_urls.txt" '(w3\.org|react\.dev|nextjs\.org|schema\.org|localhost|github\.com|npmjs\.com|mozilla\.org)'
    safe_grep "Hunting for WebSockets" 'wss?://[a-zA-Z0-9./?=_-]+' "websockets.txt"
    safe_grep "Hunting for Firebase & Supabase" '[a-zA-Z0-9.-]+\.(firebaseio\.com|supabase\.co|appwrite\.io)' "baas_urls.txt"
    safe_grep "Hunting for Basic Auth URLs" 'https?://[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+@[a-zA-Z0-9.-]+' "basic_auth.txt"
    safe_grep "Hunting for IP Addresses (Clean)" '\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[1-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[1-9])\b' "ip_addresses.txt"
    safe_grep "Hunting for S3 Buckets" '([a-z0-9.-]+\.s3-[a-z0-9-]+\.amazonaws\.com|[a-z0-9.-]+\.s3\.amazonaws\.com|s3://[a-zA-Z0-9.-]+)' "s3_buckets.txt"
    safe_grep "Hunting for Emails" '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "emails.txt" '(sentry\.io)'
    safe_grep "Hunting for DOM XSS Sinks" '(innerHTML|outerHTML|document\.write|eval|setTimeout|setInterval)\s*[\(|=]' "dom_sinks.txt"
    safe_grep "Hunting for Developer Comments" '(?<=//|/\*)\s*(TODO|FIXME|HACK|BUG|XXX)[^\n\r]{0,100}' "dev_comments.txt"
    safe_grep "Hunting for UUIDs" '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b' "uuids.txt" '(00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)'
    safe_grep "Hunting for OAuth & App IDs" '(?i)(client_id|client_secret|app_id|app_secret|tenant_id)[\x22\x27\s]*[:=][\x22\x27\s]*[a-zA-Z0-9\-_]{10,}' "oauth_configs.txt" '(function|undefined|null|true|false)'
    safe_grep "Hunting for Cloud & SaaS Tokens" '(AKIA[0-9A-Z]{16}|sk_live_[0-9a-zA-Z]{24}|gh[pous]_[a-zA-Z0-9]{36}|AIza[0-9A-Za-z-_]{35}|xox[baprs]-[0-9a-zA-Z-]{10,})' "cloud_tokens.txt"
    safe_grep "Hunting for Auth, JWT & Bearer Tokens" '(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|Bearer\s+[A-Za-z0-9\-\._~+/]+)' "auth_tokens.txt"
    safe_grep "Hunting for RSA Private Keys" '-----BEGIN[ A-Z0-9_-]*PRIVATE KEY-----' "rsa_keys.txt"
    safe_grep "Hunting for generic secrets (Clean)" '(?i)(api_key|apikey|secret|token|password|auth_token)[\x22\x27\s]*[:=][\x22\x27\s]*[a-zA-Z0-9\-_=]{8,}' "generic_secrets.txt" '(function|undefined|null|true|false|password|token)'
    safe_grep "Hunting for GraphQL Queries" '(query|mutation)\s+[a-zA-Z0-9_]+\s*\{' "graphql.txt"
    safe_grep "Hunting for Source Maps" '(?<=//# sourceMappingURL=)[a-zA-Z0-9_.-]+\.map' "source_maps.txt"

    recover_source_maps
}

generate_report() {
    echo -e "\n${C_CYAN}[*] Phase 3: Building Elite Threat Dashboard...${C_RESET}"

    count_lines() {
        local file="$GREP_DIR/$1"
        [ -f "$file" ] && wc -l < "$file" || echo "0"
    }

    local C_JS=$(find "$OUTPUT_DIR" -name "*.js" 2>/dev/null | wc -l)
    local C_PATHS=$(count_lines "hidden_paths.txt")
    local C_IPS=$(count_lines "ip_addresses.txt")
    local C_S3=$(count_lines "s3_buckets.txt")
    local C_EMAILS=$(count_lines "emails.txt")
    local C_OAUTH=$(count_lines "oauth_configs.txt")
    local C_CLOUD=$(count_lines "cloud_tokens.txt")
    local C_AUTH=$(count_lines "auth_tokens.txt")
    local C_RSA=$(count_lines "rsa_keys.txt")
    local C_SECRETS=$(count_lines "generic_secrets.txt")
    local C_GQL=$(count_lines "graphql.txt")
    local C_SINKS=$(count_lines "dom_sinks.txt")
    local C_WS=$(count_lines "websockets.txt")
    local C_BAAS=$(count_lines "baas_urls.txt")
    local C_BAUTH=$(count_lines "basic_auth.txt")
    local C_DEV=$(count_lines "dev_comments.txt")
    local C_UUID=$(count_lines "uuids.txt")
    local C_URLS=$(count_lines "all_urls.txt")
    local C_MAPS=$(count_lines "source_maps.txt")
    
    local TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

    cat << "EOF" > "$REPORT_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>JS Elite Threat Intel Dashboard</title>
  <style>
     body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #0d1117; color: #c9d1d9; margin: 0; padding: 20px; }
     .container { max-width: 1450px; margin: auto; }
     .timestamp { text-align: center; color: #8b949e; font-size: 14px; margin-bottom: 25px; line-height: 1.6; }
     
     .tabs { overflow: hidden; background-color: #161b22; border: 1px solid #30363d; border-radius: 8px 8px 0 0; display: flex; flex-wrap: wrap; }
     .tabs button { background-color: inherit; border: none; outline: none; cursor: pointer; padding: 14px 16px; transition: 0.3s; color: #8b949e; font-size: 12px; font-weight: bold; flex-grow: 1; border-right: 1px solid #30363d; border-bottom: 1px solid #30363d; display: flex; align-items: center; justify-content: center; gap: 8px; }
     .tabs button:hover { background-color: #30363d; color: #c9d1d9; }
     .tabs button.active { background-color: #238636; color: #ffffff; border-bottom: none; }
     
     .badge { background-color: #30363d; color: #c9d1d9; padding: 3px 8px; border-radius: 12px; font-size: 11px; font-weight: bold; }
     .badge.blue { background-color: rgba(88,166,255,0.1); color: #58a6ff; border: 1px solid rgba(88,166,255,0.4); }
     .badge.yellow { background-color: rgba(210,153,34,0.1); color: #d29922; border: 1px solid rgba(210,153,34,0.4); }
     .badge.red { background-color: rgba(248,81,73,0.1); color: #f85149; border: 1px solid rgba(248,81,73,0.4); }
     .tabs button.active .badge { background-color: #ffffff; color: #238636; border: none; }

     .tabcontent { display: none; padding: 20px; border: 1px solid #30363d; border-top: none; background-color: #0d1117; border-radius: 0 0 8px 8px; }
     
     .intel-box { background-color: #1f2428; border-left: 4px solid #58a6ff; padding: 15px; margin-bottom: 15px; border-radius: 4px; }
     .intel-box h4 { margin: 0 0 8px 0; color: #58a6ff; font-size: 16px;}
     .intel-box p { margin: 0 0 5px 0; font-size: 14px; color: #c9d1d9; }
     .intel-box .action { font-weight: bold; color: #39d353; }
     
     .table-container { max-height: 600px; overflow-y: auto; border: 1px solid #30363d; border-radius: 4px; }
     .results-table { width: 100%; border-collapse: collapse; text-align: left; }
     .results-table th { background-color: #238636; color: white; padding: 12px; position: sticky; top: 0; z-index: 1; font-size: 14px; box-shadow: 0 2px 2px -1px rgba(0,0,0,0.4); }
     .results-table td { padding: 10px 12px; border-bottom: 1px solid #21262d; font-size: 13.5px; }
     .results-table tr:nth-child(even) { background-color: #161b22; }
     .results-table tr:hover { background-color: #1f2428; }
     
     .col-file { width: 40%; word-break: break-all; }
     .col-file a { color: #58a6ff; text-decoration: none; font-size: 13px; }
     .col-file a:hover { text-decoration: underline; color: #79c0ff; }
     .col-line { width: 10%; color: #d29922; text-align: center; font-weight: bold;}
     .col-finding { width: 50%; word-break: break-all; }
     .col-finding code { background: #010409; padding: 3px 6px; border-radius: 4px; font-family: 'Courier New', Courier, monospace; color: #ff7b72; border: 1px solid #30363d;}
     
     ::-webkit-scrollbar { width: 8px; height: 8px; }
     ::-webkit-scrollbar-track { background: #0d1117; }
     ::-webkit-scrollbar-thumb { background: #30363d; border-radius: 4px; }
     ::-webkit-scrollbar-thumb:hover { background: #58a6ff; }
  </style>
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
</head>
<body>
   <div class="container">
EOF

    cat << EOF >> "$REPORT_FILE"
       <div class="timestamp">
           Elite Scan Completed: <strong style="color: #c9d1d9;">$TIMESTAMP</strong> | Vault Location: <code>$SESSION_DIR</code> | Total JS Files: <strong style="color: #c9d1d9;">$C_JS</strong>
       </div>
       
       <div class="tabs">
          <button class="tablinks active" onclick="openTab(event, 'tab-paths')">Paths <span class="badge">$C_PATHS</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-urls')">Ext URLs <span class="badge">$C_URLS</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-ips')" style="color:#58a6ff;">IPs <span class="badge blue">$C_IPS</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-sinks')" style="color:#bc8cff;">DOM Sinks <span class="badge" style="color:#bc8cff;">$C_SINKS</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-maps')" style="color:#bc8cff;">SourceMaps <span class="badge" style="color:#bc8cff;">$C_MAPS</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-ws')" style="color:#d29922;">WebSockets <span class="badge yellow">$C_WS</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-gql')" style="color:#d29922;">GraphQL <span class="badge yellow">$C_GQL</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-dev')" style="color:#d29922;">Comments <span class="badge yellow">$C_DEV</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-baas')" style="color:#f85149;">DB URLs <span class="badge red">$C_BAAS</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-s3')" style="color:#f85149;">S3 Buckets <span class="badge red">$C_S3</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-oauth')" style="color:#f85149;">OAuth <span class="badge red">$C_OAUTH</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-cloud')" style="color:#f85149;">Cloud Tokens <span class="badge red">$C_CLOUD</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-auth')" style="color:#f85149;">Auth/JWT <span class="badge red">$C_AUTH</span></button>
          <button class="tablinks" onclick="openTab(event, 'tab-secrets')" style="color:#f85149;">Secrets <span class="badge red">$C_SECRETS</span></button>
       </div>
EOF

    append_tab() {
        local tab_id="$1"
        local file_name="$2"
        local intel_title="$3"
        local intel_desc="$4"
        local intel_action="$5"
        local is_active="${6:-}"
        
        local display_style="display:none;"
        [ "$is_active" == "true" ] && display_style="display:block;"
        
        cat << EOF >> "$REPORT_FILE"
       <div id="$tab_id" class="tabcontent" style="$display_style">
          <div class="intel-box">
             <h4>$intel_title</h4>
             <p><strong>What is this?</strong> $intel_desc</p>
             <p><span class="action">🔥 Actionable Impact:</span> $intel_action</p>
          </div>
          <div class="table-container">
             <table class="results-table">
                <thead>
                   <tr>
                      <th class="col-file">Source JS File (Original URL)</th>
                      <th class="col-line">Line #</th>
                      <th class="col-finding">Extracted Finding / Context</th>
                   </tr>
                </thead>
                <tbody>
EOF
        
        if [ -f "$GREP_DIR/$file_name" ]; then
            awk -v mapfile="$URL_MAP_FILE" '
            BEGIN {
                while ((getline line < mapfile) > 0) {
                    split(line, parts, "|");
                    if (length(parts) == 2) {
                        urlMap[parts[1]] = parts[2];
                    }
                }
                close(mapfile);
            }
            {
                idx1 = index($0, ":");
                if (idx1 > 0) {
                    file = substr($0, 1, idx1-1);
                    rest = substr($0, idx1+1);
                    idx2 = index(rest, ":");
                    if (idx2 > 0) {
                        line_num = substr(rest, 1, idx2-1);
                        match_str = substr(rest, idx2+1);
                    } else {
                        line_num = "-";
                        match_str = rest;
                    }
                    
                    original_url = file;
                    if (file in urlMap) {
                        original_url = urlMap[file];
                    }
                    
                    gsub(/&/, "\\&amp;", match_str);
                    gsub(/</, "\\&lt;", match_str);
                    gsub(/>/, "\\&gt;", match_str);
                    print "<tr><td class=\"col-file\"><a href=\"" original_url "\" target=\"_blank\">" original_url "</a></td><td class=\"col-line\">Line " line_num "</td><td class=\"col-finding\"><code>" match_str "</code></td></tr>"
                }
            }' "$GREP_DIR/$file_name" >> "$REPORT_FILE"
        fi

        cat << "EOF" >> "$REPORT_FILE"
                </tbody>
             </table>
          </div>
       </div>
EOF
    }

    append_tab "tab-paths" "hidden_paths.txt" "Hidden API Paths & Endpoints" "Relative paths indicating internal APIs, admin panels, or staging environments." "Append these paths to the target domain and fuzz them with Burp Intruder or ffuf to find IDORs or Broken Access Control." "true"
    append_tab "tab-urls" "all_urls.txt" "External URLs" "Full external URLs embedded within the JS files." "Check for Subdomain Takeovers on these domains, or use them to find SSRF (Server-Side Request Forgery) vectors."
    append_tab "tab-ips" "ip_addresses.txt" "Exposed IP Addresses" "IPv4 addresses hardcoded by developers." "Scan these IPs with Nmap/Shodan. They might belong to internal dev servers, leading to SSRF or direct unauthorized access."
    append_tab "tab-sinks" "dom_sinks.txt" "DOM XSS Sinks" "Potential dangerous JavaScript sinks like innerHTML or eval that handle untrusted inputs." "Inspect the data flow to check if user input reaches these sinks without sanitization."
    append_tab "tab-maps" "source_maps.txt" "Source Maps Leaks (.js.map)" "Exposed source map files automatically recovered into your session folder." "Examine the recovered source code in your session folder under recovered_sources to view original unminified logic."
    append_tab "tab-ws" "websockets.txt" "WebSockets Endpoints" "Endpoints starting with ws:// or wss:// used for real-time communication." "Connect to these endpoints using Postman or Burp Suite to intercept traffic and test for CSWSH."
    append_tab "tab-gql" "graphql.txt" "GraphQL Queries & Mutations" "Hardcoded GraphQL operations." "Test the GraphQL endpoint for Introspection, Query Batching attacks, or unauthorized data modification."
    append_tab "tab-dev" "dev_comments.txt" "Developer Comments" "Inline comments like //TODO, //FIXME, or //BUG." "Read them carefully! Developers often leak temporary passwords, logic flaws, or hidden backup file names here."
    append_tab "tab-baas" "baas_urls.txt" "BaaS & Database URLs" "Direct links to Firebase, Supabase, or Appwrite instances." "Check if the database allows unauthenticated read/write access."
    append_tab "tab-s3" "s3_buckets.txt" "AWS S3 Buckets" "Direct links to Amazon S3 storage buckets." "Use AWS CLI to check if the bucket policies allow unauthenticated List, Put, or Delete operations."
    append_tab "tab-oauth" "oauth_configs.txt" "OAuth & Tenant IDs" "Client IDs, tenant IDs, or App Secrets used for third-party integrations." "If the client_secret is exposed, you can forge OAuth tokens and takeover user accounts."
    append_tab "tab-cloud" "cloud_tokens.txt" "Cloud & SaaS Tokens" "API Keys for services like Stripe, Google Cloud, Slack, or GitHub." "Test the keys directly on the respective provider APIs to see if they hold high privileges."
    append_tab "tab-auth" "auth_tokens.txt" "JWT & Bearer Tokens" "Authentication tokens embedded for API access." "Decode the JWT at jwt.io, check the signature algorithm, and test if it has admin privileges or never expires."
    append_tab "tab-secrets" "generic_secrets.txt" "Generic Secrets & Passwords" "Variables named password, secret, or token." "Test these credentials against SSH, FTP, Database ports, or the main application login."

    cat << "EOF" >> "$REPORT_FILE"
   </div>
</body>
</html>
EOF

    echo -e "${C_GREEN}[+] Elite Architecture Compiled: Dashboard UI saved successfully!${C_RESET}"
    local ABSOLUTE_REPORT
    ABSOLUTE_REPORT=$(realpath "$REPORT_FILE")
    echo -e "${C_YELLOW}[🎯] Launching Elite Dashboard: $ABSOLUTE_REPORT${C_RESET}\n"

    xdg-open "$REPORT_FILE" 2>/dev/null || open "$REPORT_FILE" 2>/dev/null || true
}

main() {
    print_banner
    check_dependencies
    setup_session "$@"
    execute_downloads
    run_static_analysis
    generate_report
}

main "$@"
