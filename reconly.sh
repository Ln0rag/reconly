#!/usr/bin/env bash

#	Colors
color_reset="\e[0m"
color_cyan="\e[36;1m"
color_red="\e[31;1m"
color_yellow="\e[33;1m"
color_green="\e[32;1m"
color_magenta="\e[35;1m"
color_white="\e[97;1m"

#	Ctrl + c
trap_ctrlc() {
    echo -e "\n${color_red}Aborting scan${color_reset}"
    echo -e "${color_yellow}Cleaning up temporary files::${color_reset}"
    if [[ -n "$SESSION_DIR" && -d "$SESSION_DIR" ]]; then
        cd "$SESSION_DIR" || exit
        rm -f all-URLs-temp.txt 2>/dev/null
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
echo -e "                                  github.com/Ln0rag\n"

echo -e "${color_cyan}+-------------------+-----------------------------+----------------------------------+${color_reset}"
echo -e "${color_cyan}| ${color_yellow}Tool${color_cyan}              | ${color_yellow}GitHub Repo${color_cyan}                 | ${color_yellow}Role in Reconly${color_cyan}                  |${color_reset}"
echo -e "${color_cyan}+-------------------+-----------------------------+----------------------------------+${color_reset}"
echo -e "${color_cyan}| ${color_white}subfinder${color_cyan}         | ${color_magenta}projectdiscovery/subfinder${color_cyan}  | ${color_green}Passive Subdomain Enumeration${color_cyan}    |${color_reset}"
echo -e "${color_cyan}| ${color_white}assetfinder${color_cyan}       | ${color_magenta}tomnomnom/assetfinder${color_cyan}       | ${color_green}Passive Subdomain Enumeration${color_cyan}    |${color_reset}"
echo -e "${color_cyan}| ${color_white}findomain${color_cyan}         | ${color_magenta}findomain/findomain${color_cyan}         | ${color_green}Passive Subdomain Enumeration${color_cyan}    |${color_reset}"
echo -e "${color_cyan}| ${color_white}httpx${color_cyan}             | ${color_magenta}projectdiscovery/httpx${color_cyan}      | ${color_green}Live Host Probing & Tech Detect${color_cyan}  |${color_reset}"
echo -e "${color_cyan}| ${color_white}katana${color_cyan}            | ${color_magenta}projectdiscovery/katana${color_cyan}     | ${color_green}Active Web Crawling${color_cyan}              |${color_reset}"
echo -e "${color_cyan}+-------------------+-----------------------------+----------------------------------+${color_reset}\n"

#-----------------------------------------------------------------------------------
#	validations
#-----------------------------------------------------------------------------------

RAW_DOMAIN=""
while getopts "d:h" opt; do
    case $opt in
        d) RAW_DOMAIN="$OPTARG" ;;
        h) echo "Usage: reconly.sh -d domain.com"; exit 0 ;;
        \?) echo -e "${color_red}Invalid option, Use -h for help${color_reset}"; exit 1 ;;
    esac
done

if [ -z "$RAW_DOMAIN" ]; then
    echo -e "${color_red}Usage: reconly.sh -d domain.com${color_reset}"
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
    ["httpx"]="go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest"
    ["katana"]="go install github.com/projectdiscovery/katana/cmd/katana@latest"
)

for tool in "${!tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${color_red}$tool is not installed.${color_reset}"
        echo -e "    Run: ${color_cyan}${tools[$tool]}${color_reset}"
        exit 1
    fi
done


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
    echo "  [3] Resume: Crawling (katana)"
    echo "  [4] Resume: Filters"
    read -p "Select a starting point [1-4] (Default 1): " choice
    if [[ "$choice" =~ ^[1-4]$ ]]; then
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

cd "$SESSION_DIR" || exit

#-----------------------------------------------------------------------------------
#	PHASE_1: Passive Subdomain Enumeration
#-----------------------------------------------------------------------------------

if [ "$START_PHASE" -le 1 ]; then
#	PHASE Identification
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    echo -e "\n${color_yellow}PHASE_1: Passive Subdomain Enumeration${color_reset}"
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
#	subfinder
    echo -e "${color_red}RUNNING::${color_reset}${color_cyan} subfinder -d $DOMAIN -all -recursive -rl 30 -t 10 -silent | sort -u | tee subfinder.txt${color_reset}"
    subfinder -d "$DOMAIN" -all -recursive -rl 30 -t 10 -silent | sort -u | tee subfinder.txt
    echo -e ""
#	assetfinder
    echo -e "${color_red}RUNNING::${color_reset}${color_cyan} assetfinder --subs-only $DOMAIN | grep \"\.$DOMAIN_ESCAPED$\" | sort -u | tee assetfinder.txt${color_reset}"
    assetfinder --subs-only "$DOMAIN" | grep "\.$DOMAIN_ESCAPED$" | sort -u | tee assetfinder.txt
    echo -e ""
#	findomain
    echo -e "${color_red}RUNNING::${color_reset}${color_cyan} findomain -t $DOMAIN -q | grep \"$DOMAIN_ESCAPED$\" | sort -u | tee findomain.txt${color_reset}"
    findomain -t "$DOMAIN" -q | grep "$DOMAIN_ESCAPED$" | sort -u | tee findomain.txt
    echo -e ""
fi

#	Merging all discovered subdomains...
    {
        [ -f subfinder.txt ] && cat subfinder.txt
        [ -f assetfinder.txt ] && cat assetfinder.txt
        [ -f findomain.txt ] && cat findomain.txt
    } | sort -u > all-subs.txt
    echo -e "${color_green}Total unique subdomains: $(wc -l < all-subs.txt 2>/dev/null || echo 0) ${color_reset}"
    cat all-subs.txt
    
#-----------------------------------------------------------------------------------
#	PHASE_2: Live probing by httpx
#-----------------------------------------------------------------------------------

if [ "$START_PHASE" -le 2 ]; then
#	PHASE Identification
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    echo -e "\n${color_yellow}PHASE_2: Live Probing by httpx${color_reset}"
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    if [ -s all-subs.txt ]; then
#	httpx
        echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat all-subs.txt | httpx -silent -threads 200 -status-code -tech-detect -title -location${color_reset}"
        cat all-subs.txt | ~/go/bin/httpx -silent -threads 200 -status-code -tech-detect -title -location | tee >(awk '{print $1}' > live-URLs.txt)
    else
        echo -e "${color_red}all-subs.txt is empty, Skipping httpx${color_reset}"
        > live-URLs.txt
    fi
fi

#-----------------------------------------------------------------------------------
#	PHASE_3: Crawling by katana
#-----------------------------------------------------------------------------------

if [ "$START_PHASE" -le 3 ]; then
#	PHASE Identification
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    echo -e "\n${color_yellow}PHASE_3: Crawling by katana${color_reset}"
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
#	katana
    if [ -s live-URLs.txt ]; then
	echo -e "${color_red}RUNNING::${color_reset}${color_cyan} cat live-URLs.txt | katana -d 2 -rl 10 -c 5 -silent | tee katanaURLs_active.txt${color_reset}"
	 cat live-URLs.txt | katana -d 2 -rl 10 -c 5 -silent | tee katanaURLs_active.txt | awk '
	{
	    lines[NR % 10] = $0
	    if (NR <= 10) {
		print
	    } else {
		printf "\033[10A"
		for (i = 1; i <= 10; i++) {
		    printf "\033[2K%s\n", lines[(NR - 10 + i) % 10]
		}
	    }
	    fflush()
	}'
    else
        echo -e "${color_red}live-URLs.txt Not Found${color_reset}"
    fi
fi

#-----------------------------------------------------------------------------------
#	PHASE_4: Filters
#-----------------------------------------------------------------------------------
if [ "$START_PHASE" -le 4 ]; then
#	PHASE Identification
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    echo -e "\n${color_yellow}PHASE_4: Filters${color_reset}"
    echo -e "\n${color_yellow}#-----------------------------------------------------------------------------------${color_reset}"
    {
        [ -f katanaURLs_active.txt ] && cat katanaURLs_active.txt
    } | sort -u > all-URLs-temp.txt
    
    if [ -s all-URLs-temp.txt ]; then
        echo -e "${color_cyan}Extracting In-Scope URLs::${color_reset}"
        cat all-URLs-temp.txt | grep "$DOMAIN_ESCAPED" | sort -u > all-URLs.txt
        cat all-URLs-temp.txt | grep -v "$DOMAIN_ESCAPED" | sort -u > external-URLs.txt
        rm -f all-URLs-temp.txt

        echo -e "${color_cyan}Extracting Parameters, JS, APIs, and Sensitive Files::${color_reset}"
        cat all-URLs.txt | grep '=' | sort -u > URLs_with_params.txt
        cat all-URLs.txt | grep -E "\.js(\?|$)" | sort -u > js_files.txt
        cat all-URLs.txt | grep -E "\.(xls|xml|xlsx|json|pdf|sql|doc|docx|pptx|txt|zip|tar\.gz|tgz|bak|7z|rar|log|cache|secret|db|backup|yml|gz|config|csv|yaml|md|md5|tar|xz|7zip|p12|pem|key|crt|csr|sh|pl|py|java|class|jar|war|ear|sqlitedb|sqlite3|dbf|db3|accdb|mdb|sqlcipher|gitignore|env|ini|conf|properties|plist|cfg)(\?|$)" | sort -u > sensitiveFiles.txt
        cat all-URLs.txt | grep -E "\b(api|v[0-9]+|graphql|rest|endpoint|ajax)\b" | grep -E -v "\.(css|js)(\?|$)" | sort -u > api_endpoints.txt
    else
        echo -e "${color_red}No URLs found to filter.${color_reset}"
        > all-URLs.txt; > URLs_with_params.txt; > js_files.txt; > sensitiveFiles.txt; > api_endpoints.txt
    fi
fi

#-----------------------------------------------------------------------------------
#	Report
#-----------------------------------------------------------------------------------

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
     
     .footer { margin-top: 3px; text-align: center; font-size: 13px; color: #8b949e; border-top: 1px solid #30363d; padding-top: 20px; }
     a { color: #58a6ff; text-decoration: none; }
     a:hover { text-decoration: underline; }
  </style>
</head>
<body>
   <div class="container">
       <!-- <h1>Reconly Report: $DOMAIN</h1> -->
       <div class="timestamp">Scan generated on: <strong>$TIMESTAMP</strong> | Directory: <code>$SESSION_DIR</code></div>
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
          <button class="tablinks" onclick="openTab(event, 'tab-katana')">Katana Actives</button>
          <button class="tablinks" onclick="openTab(event, 'tab-external')">External URLs</button>
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
       <div id="tab-katana" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat katanaURLs_active.txt 2>/dev/null || echo "No data found.")</textarea>
       </div>
       <div id="tab-external" class="tabcontent">
          <textarea class="data-box" readonly spellcheck="false">$(cat external-URLs.txt 2>/dev/null || echo "No data found.")</textarea>
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

if command -v brave-browser &> /dev/null; then brave-browser --incognito "$HTML_FILE" &> /dev/null &
elif command -v brave &> /dev/null; then brave --incognito "$HTML_FILE" &> /dev/null &
elif command -v xdg-open &> /dev/null; then xdg-open "$HTML_FILE" &> /dev/null &
elif command -v open &> /dev/null; then open "$HTML_FILE" &> /dev/null &
else echo "No Browser found";
fi
