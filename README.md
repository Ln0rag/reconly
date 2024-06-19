# reconly


                    ██████╗ ███████╗ ██████╗ ██████╗ ███╗   ██╗██╗  ██╗   ██╗
                    ██╔══██╗██╔════╝██╔════╝██╔═══██╗████╗  ██║██║  ╚██╗ ██╔╝
                    ██████╔╝█████╗  ██║     ██║   ██║██╔██╗ ██║██║   ╚████╔╝ 
                    ██╔══██╗██╔══╝  ██║     ██║   ██║██║╚██╗██║██║    ╚██╔╝  
                    ██║  ██║███████╗╚██████╗╚██████╔╝██║ ╚████║███████╗██║   
                    ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝ v1


**Note:** This script is currently under development and is uploaded to reserve the name "reconly" While the script is functional, it is being improved and expanded. Your feedback and contributions are welcome!

## Description

The Reconly script is a versatile subdomain reconnaissance tool that leverages various subdomain discovery techniques to help gather information about a target domain. This script is designed to automate the process of subdomain enumeration and analysis, making it easier for security professionals and penetration testers to gather valuable information about their targets.

## Features

- Subdomain discovery using multiple tools:
  - [subfinder](https://github.com/projectdiscovery/subfinder): Discover subdomains from various public sources.
  - [assetfinder](https://github.com/tomnomnom/assetfinder): Find subdomains using external data sources.
- Live subdomain validation using [httprobe](https://github.com/tomnomnom/httprobe).
- Extracting URLs from web pages using [gau](https://github.com/lc/gau) (GetAllUrls).
- Organized output files in the `output` directory.

## Usage

1. Clone or download this repository.
  ```
     git clone https://github.com/Ln0rag/reconly.git
  ```
3. Make sure you have the required dependencies installed (e.g., subfinder, assetfinder, httprobe, gau).
4. Run the script using:
   ```
      cd reconly
      chmod +x reconly.sh
      ./reconly.sh -d <target_domain>
   ```

## Contributing

Contributions are welcome! If you have ideas for improvements, new features, or bug fixes, feel free to open an issue or submit a pull request.


**Disclaimer:** This script is intended for educational and ethical purposes only. Ensure you have the necessary permissions before using this tool on any target.

For inquiries, contact: [Telegram](https://t.me/Ln0rag)
