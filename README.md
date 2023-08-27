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
## Dependencies
- Go language:
  `sudo apt-get remove -y golang-go`
  `sudo apt autoremove -y`
  `sudo rm -rf /usr/bin/go`
  `sudo rm -rf /usr/local/go`
  `sudo rm -rf ~/go`
  `wget https://go.dev/dl/go1.21.0.linux-amd64.tar.gz`
  `tar -xzf go1.21.0.linux-amd64.tar.gz`
  `sudo rm -rf go1.21.0.linux-amd64.tar.gz`
  `sudo cp -r $HOME/go /usr/local`
  `echo -e 'export GOPATH=$HOME/go\nexport PATH=$PATH:/usr/local/go/bin\nexport PATH=$PATH:$GOPATH/bin' >> $HOME/.profile`
  `source ~/.profile` 
- Put Go in `/usr/local/bin`:
  `sudo cp $HOME/go/bin/gau /usr/local/bin`

## Features

- Subdomain discovery using multiple tools:
  - [subfinder](https://github.com/projectdiscovery/subfinder): Discover subdomains from various public sources.
  - [assetfinder](https://github.com/tomnomnom/assetfinder): Find subdomains using external data sources.
  - [amass](https://github.com/owasp-amass/amass): Comprehensive subdomain enumeration (passive & active modes).
- Live subdomain validation using [httprobe](https://github.com/tomnomnom/httprobe).
- Extracting URLs from web pages using [gau](https://github.com/lc/gau) (GetAllUrls).
- Organized output files in the `output` directory.

## Usage

1. Clone or download this repository.
     `git clone https://AbdelzaherKH/reconly.git`
2. Make sure you have the required dependencies installed (e.g., subfinder, assetfinder, amass, httprobe, gau).
3. Run the script using:
     `cd reconly`
     `chmod +x reconly.sh`
     `./reconly.sh -d <target_domain>`

## Contributing

Contributions are welcome! If you have ideas for improvements, new features, or bug fixes, feel free to open an issue or submit a pull request.


**Disclaimer:** This script is intended for educational and ethical purposes only. Ensure you have the necessary permissions before using this tool on any target.

For inquiries, contact: [Telegram](https://t.me/AbdelzaherKH)
