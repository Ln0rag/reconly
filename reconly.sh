#!/bin/bash

# color codes
color_reset="\e[0m"
color_bright_cyan="\e[36;1m"
color_bright_red="\e[31;1m"
color_bright_yellow="\e[33;1m"
color_bright_green="\e[32;1m"
color_bright_magenta="\e[35;1m"

# Variables
output_dir="$HOME/reconly"
domain=""
shodanAPI=""
wordlist=""
gowitness_output_dir="$output_dir/gowitness"
use_amass=""
use_shodan=""

# display help
display_help() {
    echo "Usage: $0 -d <domain> -k <shodan_api_key> -w <path_to_wordlist.txt>"
    echo "Options:"
    echo "  -d    Specify the domain (required)"
    echo "  -k    Provide your Shodan API key (optional, will prompt if not provided)"
    echo "  -w    Provide the path to your wordlist file for subdomain brute-forcing (optional, will prompt if not provided)"
    exit 0
}

# Greeting banner
echo -e "$color_bright_red
  ______ _______ _______  _____  __   _        __   __
 |_____/ |______ |       |     | | \  | |        \_/  
 |    \_ |______ |_____  |_____| |  \_| |_____    |   
$color_reset"

echo -e "$color_white                 github.com/Ln0rag$color_reset"
echo -e ""

# Creating output files directory if not exists
if [ ! -d "$output_dir" ]; then
    mkdir -p "$output_dir"
fi

# logging functionality
log_file="$output_dir/reconly.log"
exec &> >(tee -a "$log_file")

# Parse command line options
while getopts "d:k:w:h" opt; do
    case $opt in
        d)
            domain="$OPTARG"
            ;;
        k)
            shodanAPI="$OPTARG"
            ;;
        w)
            wordlist="$OPTARG"
            ;;
        h)
            display_help
            ;;
        \?)
            echo "Invalid option. Use -h for help."
            exit 1
            ;;
    esac
done

# domain format validation
if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Invalid domain format, Example: domain.com"
    exit 1
fi

# Check if domain is provided
if [ -z "$domain" ]; then
    echo "Domain is required. Example: domain.com"
    exit 1
fi

# Ask if the user wants to use Shodan
read -p "Do you want to search in Shodan? (y/n): " use_shodan
if [[ "$use_shodan" =~ ^[Yy]$ ]]; then
    read -p "Enter your Shodan API Key: " shodanAPI
fi

# Ask if the user wants to use subdomain enumeration
read -p "Do you want to use subdomain enumeration? (y/n): " use_amass
if [[ "$use_amass" =~ ^[Yy]$ ]]; then
    read -p "Enter the path to your wordlist file for subdomain brute-forcing: " wordlist
    wordlist="${wordlist/#\~/$HOME}"  # Expand ~ to $HOME
    
    # Validate wordlist file
    if [ ! -f "$wordlist" ]; then
        echo "Wordlist file not found at '$wordlist'."
        exit 1
    fi
fi


echo -e "$color_bright_cyan
Output files are stored in $output_dir$color_reset"

# Tools Arsenal
echo -e "$color_bright_cyan""Tools Arsenal:$color_reset"
echo -e "- subfinder:   Subdomain discovery from various public sources."
echo -e "- findomain:   The fastest and complete solution for domain recognition."
echo -e "- shosubgo:    Small tool to Grab subdomains using Shodan API (if selected)."
echo -e "- amass:       Comprehensive subdomain enumeration."
echo -e "- httprobe:    Check live subdomains responding to HTTP requests."
echo -e "- gowitness:   A golang, web screenshot utility using Chrome Headless"
echo -e "- gau:         (GetAllUrls) Extract URLs from web pages, including JS files."

# Check for required tools
for tool in subfinder findomain shosubgo amass httprobe gowitness gau ; do
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${color_bright_red}Error: $tool is not installed.${color_reset}"
        exit 1
    fi
done

# Function to handle command execution
run_command() {
    "$@"
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "${color_bright_red}Error: Command \"$@\" failed with exit code $exit_code.${color_reset}"
        exit $exit_code
    fi
}

# Running subfinder
echo -e "$color_bright_yellow
Running subfinder:$color_reset"
run_command subfinder -silent -d "$domain" -o "$output_dir/subfinder.txt" > /dev/null
echo -e "Subfinder found $(wc -l "$output_dir/subfinder.txt")"

# Running Findomain
echo -e "$color_bright_yellow
Running findomain:$color_reset"
run_command findomain -t "$domain" -u "$output_dir/findomain.txt" > /dev/null
echo -e "Findomain found $(wc -l "$output_dir/findomain.txt")"

# Running Shosubgo
echo -e "$color_bright_yellow
Running Shosubgo:$color_reset"
if [ -n "$shodanAPI" ]; then
    run_command shosubgo -d "$domain" -s "$shodanAPI" > "$output_dir/shosubgo.txt"
    echo -e "Shosubgo found $(wc -l "$output_dir/shosubgo.txt")"
fi

# Running Amass (Passive mode always, Active mode based on user input)
echo -e "$color_bright_yellow
Running Amass => Passive mode:$color_reset"
run_command amass enum --passive -silent -d "$domain" -o "$output_dir/amassPassive.txt"
echo -e "Amass found $(wc -l "$output_dir/amassPassive.txt")"

# Ask if the user wants to use Active mode (subdomain brute-forcing)
read -p "Do you want to use Amass Active mode (subdomain brute-forcing)? (y/n): " amass_active_choice
if [[ "$amass_active_choice" =~ ^[Yy]$ ]]; then
    echo -e "$color_bright_yellow
    Running Amass => Active mode:$color_reset"
    run_command amass enum -d "$domain" -brute -silent -w "$wordlist" -o "$output_dir/amassActive.txt"
    echo -e "Amass found $(wc -l "$output_dir/amassActive.txt")"
fi

# ALL IN ONE: Merge and sort subdomains, handling missing files
{
  [ -f "$output_dir/subfinder.txt" ] && cat "$output_dir/subfinder.txt"
  [ -f "$output_dir/findomain.txt" ] && cat "$output_dir/findomain.txt"
  [ -f "$output_dir/shosubgo.txt" ] && cat "$output_dir/shosubgo.txt"
  [ -f "$output_dir/amassPassive.txt "] && cat "$output_dir/amassPassive.txt"
  [ "$use_amass" = "yes" ] && [ -f "$output_dir/amassActive.txt" ] && cat "$output_dir/amassActive.txt"
} | sort -u > "$output_dir/AllSubs.txt"

echo -e "$color_bright_red
Merging & Sorting $(wc -l < "$output_dir/AllSubs.txt")$color_reset"

# Running httprobe
echo -e "$color_bright_cyan
Running httprobe:$color_reset"
run_command cat "$output_dir/AllSubs.txt" | httprobe -c 50 > "$output_dir/liveSubs.txt"
echo -e "Httprobe found $(wc -l < "$output_dir/liveSubs.txt")"

# Running Gowitness
echo -e "$color_bright_green
Running Gowitness to capture screenshots:$color_reset"
if [ ! -d "$gowitness_output_dir" ]; then
    mkdir -p "$gowitness_output_dir"
fi
run_command gowitness scan file -f "$output_dir/liveSubs.txt" --threads 50 --ports-small --write-screenshots --screenshot-path "$gowitness_output_dir"
echo -e "Gowitness has captured screenshots and saved the report in $gowitness_output_dir"

# Running gau
echo -e "$color_bright_magenta
Running gau(GetAllUrls)$color_reset"
echo -e "Hint:  png,jpg,gif,jpeg are blacklisted"
run_command cat "$output_dir/liveSubs.txt" | gau --threads 50 > "$output_dir/GetAllURLs.txt"
echo -e "gau found $(wc -l < "$output_dir/GetAllURLs.txt")"

echo -e "$color_bright_green
All tasks completed! Output is stored in $output_dir$color_reset"
