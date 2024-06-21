#!/bin/bash                               

#Define different color codes
color_reset="\e[0m"
color_bright_cyan="\e[36;1m"
color_bright_red="\e[31;1m"
color_bright_yellow="\e[33;1m"
color_bright_green="\e[32;1m"
color_bright_magenta="\e[35;1m"

#Variables
output_dir="$HOME/reconly/output"
domain=""


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

#Parse command line options
while getopts "d:" opt; do
    case $opt in
        d)
            domain="$OPTARG"
            ;;
        \?)
            echo "Usage: $0 -d <domain>"
            exit 1
            ;;
    esac
done

#Check if domain is provided
if [ -z "$domain" ]; then
    echo "Domain is required."
    exit 1
fi


#Creating output files directory if not exists
if [ ! -d "$output_dir" ]; then
    mkdir "$output_dir"
fi

echo -e "$color_bright_cyan
Output files are stored in $output_dir$color_reset"

#Tools Arsenal
echo -e "$color_bright_cyan""Tools Arsenal:$color_reset"

#Tool Descriptions
echo -e "- subfinder:   Subdomain discovery from various public sources."
echo -e "- assetfinder: Find subdomains using external data sources."
#echo -e "- amass:       Comprehensive subdomain enumeration (passive & active)."
echo -e "- httprobe:    Check live subdomains responding to HTTP requests."
echo -e "- gau:         (GetAllUrls) Extract URLs from web pages, including JS files."

# Function to handle command execution
run_command() {
    "$@"
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "${color_bright_red}Error: Command \"$@\" failed with exit code $exit_code.${color_reset}"
        exit $exit_code
    fi
}

#Running subfinder
echo -e "$color_bright_green
Running subfinder:$color_reset"
run_command subfinder -silent -d $domain -o "$output_dir/subfinder.txt" > /dev/null
echo -e "Subfinder found $(wc -l "$output_dir/subfinder.txt")"

#Running Assetfinder
echo -e "$color_bright_magenta
Running Assetfinder:$color_reset"
run_command assetfinder --subs-only $domain > "$output_dir/assetfinder.txt"
echo -e "Assetfinder found $(wc -l "$output_dir/assetfinder.txt")"

#Running Amass => Passive mode
#echo -e "$color_bright_yellow
#Running Amass => Passive mode:$color_reset"
#run_command amass enum --passive -silent -d $domain -o "$output_dir/amassPassive.txt"
#echo -e "Amass found $(wc -l "$output_dir/amassPassive.txt")"

#ALL IN ONE:
run_command cat "$output_dir/subfinder.txt" "$output_dir/assetfinder.txt" | sort -u > "$output_dir/subdomains.txt"
echo -e "$color_bright_red
Merging & Sorting $(wc -l "$output_dir/subdomains.txt")$color_reset"

#Running httprobe
echo -e "$color_bright_cyan
Running httprobe:$color_reset"
run_command cat "$output_dir/subdomains.txt"  | httprobe -c 50 > "$output_dir/liveSubdomains.txt"
echo -e "Httprobe found $(wc -l "$output_dir/liveSubdomains.txt")"

#Running gau
echo -e "$color_bright_magenta
Running gau(GetAllUrls)$color_reset"
echo -e "Hint:  png,jpg,gif,jpeg are blacklisted"
run_command cat "$output_dir/liveSubdomains.txt" | gau --threads 5 --blacklist png,jpg,gif,jpeg > "$output_dir/getallurls.txt"
echo -e "output in $output_dir/getallurls.txt"
echo -e "gau has finished"
