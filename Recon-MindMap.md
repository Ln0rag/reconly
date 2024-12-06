# ***Information Gathering:***
## SCOPE
#### IN-SCOPE:

#### OUT-OF-SCOPE:

## Acquisitions
**[Crunch Base](https://www.crunchbase.com)**
	ABOUT company:
	

## ASNs
**[bgp](https://bgp.he.net)**
ASNs is a reference number for all of the company IPs.
If the company have an `older name` search with the older name.
```bash
amass intel -asn [*****]
```

## WHOIS
**[whoxy](https://www.whoxy.com/)**

___
___
___
# ***Automation:***
## Install `reconly.sh` script
```bash
git clone https://github.com/Ln0rag/reconly.git
cd reconly
chmod +x reconly.sh
sudo mv reconly.sh /opt/bin/reconly.sh
reconly.sh -d <target-domain>
```

## Subdomain Enumeration
```bash
subfinder -d example.com -o $HOME/ntfsdrive/Obsidian/Targets/[Target-Folder-Name]

findomain -t example.com

shosubgo -d example.com -s <Shodan-API-KEY>

amass enum --passive -silent -d example.com //use amass old version
```

## Subdomain Bruting
```bash
amass enum -d example.com -brute -w <Wordlist_Path.txt>  //use amass old version
```

## AllSubs.txt
```bash
cat "subfinder.txt" "findomain.txt" "shosubgo.txt" "amassPassive.txt" "amassActive.txt" | sort -u > "AllSubs.txt"
```

## LiveSubs.txt
```bash
cat "AllSubs.txt" | httprobe -c 50 > "liveSubs.txt"
```

## Subdomain Screenshots
```bash
gowitness scan file -f "liveSubs.txt" --threads 50 --ports-large --write-screenshots --screenshot-path "gowitness"
```

## URLs
```bash
cat "liveSubs.txt" | gau --threads 5 --blacklist png,jpg,gif,jpeg > "GetAllUrls.txt"
```

> These are the core of the `reconly.sh` script and implemented in a better way.

___
___
___
# ***Dorking:***
## KeyWords
`.js, admin, api, atlassian, backup, billing, cache, cgi-bin, chat, config, confluence, corp, cp, create, dash, database, db, debug, delete, dev, doc, edit, email, exe, file, ftp, gateway, git, gql, graph, import, internal, jenkins, jira, log, login, logon, mail, okta, panel, payment, portal, proxy, rar, redirect, register, registration, robots.txt, setting, signin, signup, sql, stage, stg, swagger, tar.gz, temp, test, trace, uat, upload, wsdl, zi, zip, token`

## AlienVault-URL
[https://otx.alienvault.com/api/v1/indicators/***TYPE***/***DOMAIN***/url_list?limit=500](https://otx.alienvault.com/api/v1/indicators/domain/example.com/url_list?limit=500)
```json
TYPE   >> domain | hostname | ipv4 | ipv6
DOMAIN >> "example.com"
```

## Shodan-URL
[https://www.shodan.io/search?query=***DOMAIN***](https://www.shodan.io/search?query=example.com)
	
	ssl:"[COMPANY SSLCERTIFICATE NAME]"
	ssl.cert.subject.CN:"DOMAIN"
```json
DOMAIN >> "example.com"
```

## VirusTotal-URL
[https://www.virustotal.com/vtapi/v2/domain/report?apikey=***APIKEY***&domain=***DOMAIN***](https://www.virustotal.com/vtapi/v2/domain/report?apikey=APIKEY&domain=example.com)

```json
APIKEY >> "FBARBnrbrndbaBNGBNANanrj2rvwfs"
DOMAIN >> "example.com"
```

## URLScan-URL
[https://urlscan.io/api/v1/search/?q=domain:***DOMAIN***&size=10000](https://urlscan.io/api/v1/search/?q=domain:example.com&size=10000)

[https://urlscan.io/search/#example.\*](https://urlscan.io/search/#example.*)

```json
DOMAIN >> "example.com"
```

## WayBack-URL
[https://web.archive.org/cdx/search/cdx?url=***DOMAIN***&fl=timestamp,original,mimetype,statuscode,digest&collapse=urlk](https://web.archive.org/cdx/search/cdx?url=example.com&fl=timestamp,original,mimetype,statuscode,digest&collapse=urlk)

```json
DOMAIN >> "example.com"
```

## GitHub-URL
[https://github.com/search?q=%22***DOMAIN***%22+***KEYWORDS***&type=code&s=updated&o=asc](https://github.com/search?q=%22example.com%22+password&type=code&s=updated&o=asc)
```json
//Replace KEYWORDS with:
dockercfg, pee private, id_rsa, s3cfg, htpasswd, git-credentials, bashrc password, sshd_config, xoxp OR xoxb OR xoxa, SECRET_KEY, client_secret, sshd_config, github_token, api_key, FTP, app_secret, passwd, s3.yml, .exs, beanstalkd.yml, deploy.rake, mysql, credentials, PWD, .bash_history, .sls, secrets, composer.json
```
```json
DOMAIN >> "example.com"
```
_NOTE_
_Check the company GitHub account & contributed developers_
_***DOMAIN***+password+NOT+***www.DOMAIN about.DOMAIN***
// will reduce the results_

___
___
___
# ***Directory Fuzzing:***
_Most Important Note is make a useful wordlist_

## ffuf
```bash

ffuf -w <wordlist> -u http://example.com/api/FUZZ/ -o <output.txt> -replay-proxy http://example.com -b "laravel_session=<cookie>"


ffuf -w <wordlist> -u http://example.com/api/users/ -o <output.txt> -replay-proxy http://example.com -H "user-agent:FUZZ"


ffuf -w <wordlist> -u http://example.com/api/FUZZ/ -o <output.txt> -replay-proxy http://example.com -p 1 -t 3
#you can reduce the seconds between requests with -p
#you can reduce number of threads with -t


ffuf -w <wordlist> -u http://example.com/api/FUZZ/ -o <output.txt> -replay-proxy http://example.com -rate 3
#this will send 3 requests per second


ffuf -w wordlist.txt:FUZZ -w wordlist_2.txt:FUZ2 -u http://example.com/api/FUZZ/FUZ2 -o <output.txt> -replay-proxy http://example.com -mode clusterbomb
#you can switch mode between clusterbomb || pitchfork with -mode


-mc 200,204,301,302,307,401,403
OR
-fc 404
-fw 1 #this filters responces with 1 word
-fr "not found"


ffuf -w wordlist.txt -X POST -d "email=user@gmail.com&issue=test&FUZZ=test" -u http://example.com/api -o <output.txt> -replay-proxy http://example.com -b "laravel_session=<cookie>"


ffuf -w <wordlist> -u "http://example.com/api/submit?FUZZ=test&issue=df" -o <output.txt> -replay-proxy http://example.com


ffuf -H "User-Agent: PENTEST" -c -w <wordlist> -maxtime-job 60 -recursion -recursion-depth 2 -u $URL/FUZZ

```
OR you can use burp intruder. 
___
___
___
# ***Port Scanning:*** ==suspended==

___
___
___
