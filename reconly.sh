#!/bin/bash                               

# Define different color codes
color_reset="\e[0m"
color_bright_cyan="\e[36;1m"
color_bright_red="\e[31;1m"
color_bright_yellow="\e[33;1m"
color_bright_green="\e[32;1m"
color_bright_magenta="\e[35;1m"

# Variables
output_dir="$HOME/Desktop"
domain=""
shodanAPI=""
wordlist=""
gowitness_output_dir="$output_dir/7_gowitness"
use_amass=""

# Function to display help
display_help() {
    echo "Usage: $0 -d <domain> -k <shodan_api_key> -w <path_to_wordlist>"
    echo "Options:"
    echo "  -d    Specify the domain (required)"
    echo "  -k    Provide your Shodan API key (optional, will prompt if not provided)"
    echo "  -w    Provide the path to your wordlist file for subdomain brute-forcing (optional, will prompt if not provided)"
    exit 0
}

# Greeting banner
echo -e "$color_bright_cyan
      ██████╗  ███████╗  ██████╗  ██████╗  ███╗   ██╗ ██╗   ██╗   ██╗
      ██╔══██╗ ██╔════╝ ██╔════╝ ██╔═══██╗ ████╗  ██║ ██║   ╚██╗ ██╔╝
      ██████╔╝ █████╗   ██║      ██║   ██║ ██╔██╗ ██║ ██║    ╚████╔╝
      ██╔══██╗ ██╔══╝   ██║      ██║   ██║ ██║╚██╗██║ ██║     ╚██╔╝
      ██║  ██║ ███████╗ ╚██████╗ ╚██████╔╝ ██║ ╚████║ ███████╗ ██║
      ╚═╝  ╚═╝ ╚══════╝  ╚═════╝  ╚═════╝  ╚═╝  ╚═══╝ ╚══════╝ ╚═╝
$color_reset"

echo -e "$color_white                                   github.com/Ln0rag$color_reset"
echo -e ""

# Add to the beginning of your script to set the output directory from an env variable or default
output_dir="${OUTPUT_DIR:-$HOME/Desktop}"

# Add logging functionality
log_file="$output_dir/0script.log"
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

# Validate domain format
if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Error: Invalid domain format. Example: domain.com"
    exit 1
fi

# Check if domain is provided
if [ -z "$domain" ]; then
    echo "Domain is required. Example: domain.com"
    exit 1
fi

# Check if API key is provided
if [ -z "$shodanAPI" ]; then
    read -p "Enter your Shodan API Key: " shodanAPI
fi

# Check if wordlist is provided
if [ -z "$wordlist" ]; then
    read -p "Enter the path to your wordlist file for subdomain brute-forcing: " wordlist
    wordlist="${wordlist/#\~/$HOME}"  # Expand ~ to $HOME
fi

# Validate wordlist file
if [ ! -f "$wordlist" ]; then
    echo "Error: Wordlist file not found at '$wordlist'."
    exit 1
fi

# Creating output files directory if not exists
if [ ! -d "$output_dir" ]; then
    mkdir "$output_dir"
fi

echo -e "$color_bright_cyan
Output files are stored in $output_dir$color_reset"

# Ask if the user wants to use Amass
read -p "Do you want to use Amass for subdomain enumeration? (y/n): " amass_choice
if [[ "$amass_choice" =~ ^[Yy]$ ]]; then
    use_amass="yes"
else
    use_amass="no"
fi

# Tools Arsenal
echo -e "$color_bright_cyan""Tools Arsenal:$color_reset"
echo -e "- subfinder:   Subdomain discovery from various public sources."
echo -e "- findomain:   The fastest and complete solution for domain recognition."
echo -e "- shosubgo:    Small tool to Grab subdomains using Shodan API."
echo -e "- amass:       Comprehensive subdomain enumeration (if selected)."
echo -e "- httprobe:    Check live subdomains responding to HTTP requests."
echo -e "- gowitness: 	a golang, web screenshot utility using Chrome Headless"
echo -e "- gau:         (GetAllUrls) Extract URLs from web pages, including JS files."

# Check for required tools
for tool in subfinder findomain shosubgo httprobe gowitness gau ; do
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
run_command subfinder -silent -d "$domain" -o "$output_dir/1_subfinder.txt" > /dev/null
echo -e "Subfinder found $(wc -l "$output_dir/1_subfinder.txt")"

# Running Findomain
echo -e "$color_bright_yellow
Running findomain:$color_reset"
run_command findomain -t "$domain" -u "$output_dir/2_findomain.txt" > /dev/null
echo -e "Findomain found $(wc -l "$output_dir/2_findomain.txt")"

# Running Shosubgo
echo -e "$color_bright_yellow
Running Shosubgo:$color_reset"
run_command shosubgo -d "$domain" -s "$shodanAPI" > "$output_dir/3_shosubgo.txt"
echo -e "Shosubgo found $(wc -l "$output_dir/3_shosubgo.txt")"

# Running Amass (only if chosen by the user)
if [ "$use_amass" = "yes" ]; then
    echo -e "$color_bright_yellow
    Running Amass => Passive mode:$color_reset"
    run_command amass enum --passive -silent -d "$domain" -o "$output_dir/4.1_amassPassive.txt"
    echo -e "Amass found $(wc -l "$output_dir/4.1_amassPassive.txt")"

    echo -e "$color_bright_yellow
    Running Amass => Active mode:$color_reset"
    run_command amass enum -d "$domain" -brute -silent -w "$wordlist" -o "$output_dir/4.2_amassActive.txt"
    echo -e "Amass found $(wc -l "$output_dir/4.2_amassActive.txt")"
fi

# ALL IN ONE: Merge and sort subdomains, handling missing files
{
  [ -f "$output_dir/1_subfinder.txt" ] && cat "$output_dir/1_subfinder.txt"
  [ -f "$output_dir/2_findomain.txt" ] && cat "$output_dir/2_findomain.txt"
  [ -f "$output_dir/3_shosubgo.txt" ] && cat "$output_dir/3_shosubgo.txt"
  [ "$use_amass" = "yes" ] && [ -f "$output_dir/4.1_amassPassive.txt" ] && cat "$output_dir/4.1_amassPassive.txt"
  [ "$use_amass" = "yes" ] && [ -f "$output_dir/4.2_amassActive.txt" ] && cat "$output_dir/4.2_amassActive.txt"
} | sort -u > "$output_dir/5_ALLSUBs.txt"

echo -e "$color_bright_red
Merging & Sorting $(wc -l < "$output_dir/5_ALLSUBs.txt")$color_reset"

# Running httprobe
echo -e "$color_bright_cyan
Running httprobe:$color_reset"
run_command cat "$output_dir/5_ALLSUBs.txt"  | httprobe -c 50 > "$output_dir/6_liveSubdomains.txt"
echo -e "Httprobe found $(wc -l "$output_dir/6_liveSubdomains.txt")"

# Running Gowitness
echo -e "$color_bright_green
Running Gowitness to capture screenshots:$color_reset"
if [ ! -d "$gowitness_output_dir" ]; then
    mkdir "$gowitness_output_dir"
fi
run_command gowitness scan file -f "$output_dir/6_liveSubdomains.txt" --threads 50 --ports-small --write-screenshots --screenshot-path "$gowitness_output_dir"
echo -e "Gowitness has captured screenshots and saved the report in $gowitness_output_dir"

# Running gau
echo -e "$color_bright_magenta
Running gau(GetAllUrls)$color_reset"
echo -e "Hint:  png,jpg,gif,jpeg are blacklisted"
run_command cat "$output_dir/6_liveSubdomains.txt" | gau --threads 5 --blacklist png,jpg,gif,jpeg > "$output_dir/8_getallurls.txt"
echo -e "Output in $output_dir/8_getallurls.txt"

##########################################################################################################################
# FINISHED
echo -e "$color_bright_cyan\nSummary of Results:$color_reset"
echo -e "Subdomains found in subfinder: $(wc -l < "$output_dir/1_subfinder.txt")"
echo -e "Subdomains found in findomain: $(wc -l < "$output_dir/2_findomain.txt")"
echo -e "Subdomains found in shosubgo: $(wc -l < "$output_dir/3_shosubgo.txt")"

if [ "$use_amass" = "yes" ]; then
    echo -e "Subdomains found in Amass (Passive): $(wc -l < "$output_dir/4.1_amassPassive.txt")"
    echo -e "Subdomains found in Amass (Active): $(wc -l < "$output_dir/4.2_amassActive.txt")"
fi

echo -e "Live subdomains found: $(wc -l < "$output_dir/6_liveSubdomains.txt")"
echo -e "Total unique subdomains found: $(wc -l < "$output_dir/5_ALLSUBs.txt")"
echo -e "gowitness output in: $gowitness_output_dir"
echo -e "gau found: $(wc -l < "$output_dir/8_getallurls.txt") URLs"
echo -e "$color_bright_green\nAll tasks completed successfully!${color_reset}"
