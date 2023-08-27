# reconly
Bash script that automate some parts of Reconnaissance process :)

**Note:** This script is currently under development and is uploaded to reserve the name "reconly" While the script is functional, it is being improved and expanded. Your feedback and contributions are welcome!

![GitHub repo size](https://img.shields.io/github/repo-size/AbdelzaherKH/reconly)
![GitHub](https://img.shields.io/github/license/AbdelzaherKH/reconly)

## Description

The Reconly script is a versatile subdomain reconnaissance tool that leverages various subdomain discovery techniques to help gather information about a target domain. This script is designed to automate the process of subdomain enumeration and analysis, making it easier for security professionals and penetration testers to gather valuable information about their targets.

## Features

- Subdomain discovery using multiple tools:
  - subfinder: Discover subdomains from various public sources.
  - assetfinder: Find subdomains using external data sources.
  - amass: Comprehensive subdomain enumeration (passive & active modes).
- Live subdomain validation using httprobe.
- Extracting URLs from web pages using gau (GetAllUrls).
- Organized output files in the `output` directory.

## Usage

1. Clone or download this repository.
2. Make sure you have the required dependencies installed (e.g., subfinder, assetfinder, amass, httprobe, gau).
3. Run the script using:
4. `cd reconly`
5. `chmod +x reconly.sh`
6. `./reconly.sh -d <target_domain>`

## Contributing

Contributions are welcome! If you have ideas for improvements, new features, or bug fixes, feel free to open an issue or submit a pull request.

## License

This project is open-source and available under the [MIT License](LICENSE).

---

**Disclaimer:** This script is intended for educational and ethical purposes only. Ensure you have the necessary permissions before using this tool on any target.

For inquiries, contact: [Telegram](https://t.me/AbdelzaherKH)
