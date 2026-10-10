#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
umask 077
export LC_ALL=C
export PATH="$PATH:$HOME/go/bin"
export CODEQL_ALLOW_INSTALLATION_ANYWHERE=true

RECONLY_MAX_PAGES=5000
RECONLY_JS_THREADS=15
RECONLY_FETCH_THREADS=30
UA_POOL=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
if [ -n "${FAKE_UA:-}" ]; then
    UA_ROTATE=0
else
    UA_ROTATE=1
    FAKE_UA="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
fi
PRETTIER_MAX_MB=150
PRETTIER_BATCH=20
OBF_MAX_FILES=50
JS_MAX_ROUNDS=4
NAABU_PORTS="80,443,8080,8443,8000,8888,3000,4000,5000,7000,9000,9090,9999,8081,8181,4443,9443,10000,2375,2376,6443,10250,9200,5601,8500,8200,2379,15672,7474"
KATANA_RL="${KATANA_RL:-$((RANDOM % 11 + 30))}"
RECONLY_PAGE_THREADS="${RECONLY_PAGE_THREADS:-8}"
RECONLY_AUTO_INSTALL="${RECONLY_AUTO_INSTALL:-1}"
RECONLY_CHECK_UPDATES="${RECONLY_CHECK_UPDATES:-1}"
JITTER_MIN=100
JITTER_MAX=300
if [ -z "${PRETTIER_JOBS:-}" ]; then
    _cores=$(command -v nproc >/dev/null 2>&1 && nproc || echo 3)
    PRETTIER_JOBS=$(( _cores * 7 / 10 ))
    [ "$PRETTIER_JOBS" -lt 1 ] && PRETTIER_JOBS=1
fi
[ "$PRETTIER_JOBS" -lt 1 ] 2>/dev/null && PRETTIER_JOBS=1
[ "$PRETTIER_JOBS" -gt 8 ] 2>/dev/null && PRETTIER_JOBS=8

C_R="\033[0m"
C_K="\033[90m"
C_RED="\033[31;1m"
C_GRN="\033[32;1m"
C_Y="\033[33;1m"
C_BLU="\033[34;1m"
C_MAG="\033[35;1m"
C_CYN="\033[36;1m"
C_W="\033[37;1m"

out() {
    local msg="$1"
    if [ -t 6 ]; then
        printf '%b\n' "$msg"
    else
        local plain
        plain=$(printf '%b' "$msg" | sed -r 's/\x1b\[[0-9;]*m//g')
        printf '%s\n' "$plain"
    fi
}
die() {
    out "${C_RED}[FATAL] $*${C_R}"
    exit 1
}
warn_rc() {
    local name="$1" rc="$2"
    [ "${rc:-0}" -eq 0 ] && return 0
    out "${C_Y}[warn] $name exited rc=$rc, continuing${C_R}"
}
run_stage() {
    local name="$1"
    out ""
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_BLU} $name${C_R}"
    out ""
    shift
    local _before _after _new _f
    _before=$(find "$SESSION_DIR" -type f -printf '%T@ %p\n' 2>/dev/null | sort -k2,2 | cut -d' ' -f2-)
    "$@" || true
    find "$SESSION_DIR" -type f -name '*.txt' -empty -not -path '*/state/tmp/*' -delete 2>/dev/null || true
    _after=$(find "$SESSION_DIR" -type f -printf '%T@ %p\n' 2>/dev/null | sort -k2,2 | cut -d' ' -f2-)
    _new=$(comm -13 <(printf '%s\n' "$_before") <(printf '%s\n' "$_after") | grep -v '/state/tmp/')
    if [ -n "$_new" ]; then
        out "${C_GRN}OUTPUT:${C_R}"
        printf '%s\n' "$_new" | while IFS= read -r _f; do
            printf '%s\t%s\n' "$(stat -c %w "$_f" 2>/dev/null || stat -c %y "$_f" 2>/dev/null || echo 0)" "$_f"
        done | sort -k1,1 | cut -f2- | sed "s|^$SESSION_DIR/||" | awk '
            {   n=split($0,a,"/")
                if (n>1) { d=$0; sub("/[^/]*$","",d) } else d="."
                if (!(d in cnt)) ord[++oc]=d
                cnt[d]++
                if (cnt[d]==1) lin[d]="\t" $0; else lin[d]=lin[d] "\n\t" $0
            }
            END{ for(i=1;i<=oc;i++){ d=ord[i]; if(cnt[d]>10) printf "\t%s (%d)\n", d, cnt[d]; else printf "%s\n", lin[d] } }' \
        | while IFS= read -r _l; do out "${C_GRN}${_l}${C_R}"; done
    fi
    return 0
}
trap_ctrlc() {
    trap '' SIGINT SIGTERM SIGQUIT
    kill -INT -- -$$ 2>/dev/null || true
    pkill -INT -P $$ 2>/dev/null || true
    sleep 0.3 2>/dev/null || true
    [ -n "${SESSION_DIR:-}" ] && [ -d "$SESSION_DIR/state/tmp" ] && rm -rf "$SESSION_DIR/state/tmp" 2>/dev/null
    stty sane 2>/dev/null || true
    out "${C_RED}Scan halted — Cleanup complete${C_R}"
    kill -KILL -- -$$ 2>/dev/null || true
    exit 130
}
trap trap_ctrlc SIGINT
trap trap_ctrlc SIGTERM

ORIG_ARGS=("$@")

RAW_DOMAIN=""

while getopts "d:h" opt; do
    case $opt in
        d) RAW_DOMAIN="$OPTARG" ;;
        h)
            echo "Usage: reconly.sh -d domain.com"
            exit 0
            ;;
        \?) echo "Invalid option"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
if [ "$#" -gt 0 ]; then
    out "${C_Y}[warn] ignoring unexpected extra argument(s): $* -- if a path contains spaces, quote it${C_R}"
fi

[ -z "$RAW_DOMAIN" ] && die "Missing -d domain"


DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|^www\.||')
DOMAIN_ESCAPED="${DOMAIN//./\.}"
[[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || die "Invalid domain: $DOMAIN"

RESOLVERS_FILE="$HOME/github-tools/resolvers.txt"
if [ ! -s "$RESOLVERS_FILE" ]; then
    mkdir -p "$(dirname "$RESOLVERS_FILE")"
    if curl -sf -m 20 "https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt" -o "$RESOLVERS_FILE" 2>/dev/null \
       && grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$RESOLVERS_FILE"; then
        out "${C_W}resolvers.txt downloaded ($(wc -l < "$RESOLVERS_FILE" | tr -d ' ') entries) -> ~/github-tools/resolvers.txt${C_R}"
    else
        rm -f "$RESOLVERS_FILE"
        RESOLVERS_FILE=""
        out "${C_Y}resolvers list unavailable -- dnsx will fall back to 1.1.1.1/8.8.8.8/9.9.9.9${C_R}"
    fi
fi

if [ ! -s "$HOME/github-tools/hunt-custom.txt" ]; then
    mkdir -p "$HOME/github-tools"
    if curl -sf -m 20 "https://raw.githubusercontent.com/Ln0rag/reconly/main/hunt-custom.txt" -o "$HOME/github-tools/hunt-custom.txt" 2>/dev/null; then
        out "${C_W}hunt-custom.txt downloaded ($(wc -l < "$HOME/github-tools/hunt-custom.txt" | tr -d ' ') hunter patterns) -> ~/github-tools/hunt-custom.txt${C_R}"
    else
        out "${C_Y}[INFO] hunt-custom.txt not found -- get it: https://github.com/Ln0rag/reconly/blob/main/hunt-custom.txt -> save as ~/github-tools/hunt-custom.txt${C_R}"
    fi
fi

TOOL_LIST=(codeql subfinder httpx naabu katana semgrep syft grype noseyparker waymore gitleaks dnsx gau amass jsluice trufflehog jq retire)

declare -A TOOL_INSTALL=(
    [subfinder]='go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest'
    [amass]='go install -v github.com/owasp-amass/amass/v5/cmd/amass@main'
    [dnsx]='go install -v github.com/projectdiscovery/dnsx/cmd/dnsx@latest'
    [httpx]='go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest'
    [naabu]='go install -v github.com/projectdiscovery/naabu/v2/cmd/naabu@latest'
    [katana]='go install github.com/projectdiscovery/katana/cmd/katana@latest'
    [gau]='go install -v github.com/lc/gau/v2/cmd/gau@latest'
    [trufflehog]='ver=$(curl -s https://api.github.com/repos/trufflesecurity/trufflehog/releases/latest | jq -r .tag_name | sed "s/^v//") && seg_dl "https://github.com/trufflesecurity/trufflehog/releases/download/v${ver}/trufflehog_${ver}_linux_amd64.tar.gz" /tmp/trufflehog.tgz && tar -xzf /tmp/trufflehog.tgz -C "$HOME/github-tools" && rm -f /tmp/trufflehog.tgz && mkdir -p "$HOME/github-tools/.tool-versions" && printf "%s\n" "$ver" > "$HOME/github-tools/.tool-versions/trufflehog"'
    [jsluice]='go install -v github.com/BishopFox/jsluice/cmd/jsluice@latest'
    [gitleaks]='go install -v github.com/zricethezav/gitleaks/v8@latest'
    [noseyparker]='mkdir -p "$HOME/github-tools" "$HOME/.cache/np-install" && rm -rf "$HOME/.cache/np-install"/* && ver=$(curl -s https://api.github.com/repos/praetorian-inc/noseyparker/releases/latest | jq -r .tag_name | sed "s/^v//") && _u=$(curl -s https://api.github.com/repos/praetorian-inc/noseyparker/releases/latest | jq -r ".assets[] | select(.name | test(\"x86_64-unknown-linux-gnu.tar.gz$\")) | .browser_download_url" | head -1) && [ -n "$_u" ] && [ "$_u" != "null" ] && seg_dl "$_u" "$HOME/.cache/np-install/np.tgz" && tar -xzf "$HOME/.cache/np-install/np.tgz" -C "$HOME/.cache/np-install" && _b=$(find "$HOME/.cache/np-install" -type f -name noseyparker -perm -u+x | head -1) && [ -n "$_b" ] && cp -f "$_b" "$HOME/github-tools/noseyparker" && chmod +x "$HOME/github-tools/noseyparker" && rm -rf "$HOME/.cache/np-install" && mkdir -p "$HOME/github-tools/.tool-versions" && printf "%s\n" "$ver" > "$HOME/github-tools/.tool-versions/noseyparker"'
    [syft]='ver=$(curl -s https://api.github.com/repos/anchore/syft/releases/latest | jq -r .tag_name | sed "s/^v//") && seg_dl "https://github.com/anchore/syft/releases/download/v${ver}/syft_${ver}_linux_amd64.tar.gz" /tmp/syft.tgz && mkdir -p "$HOME/github-tools" && tar -xzf /tmp/syft.tgz -C "$HOME/github-tools" syft && chmod +x "$HOME/github-tools/syft" && rm -f /tmp/syft.tgz && mkdir -p "$HOME/github-tools/.tool-versions" && printf "%s\n" "$ver" > "$HOME/github-tools/.tool-versions/syft"'
    [grype]='ver=$(curl -s https://api.github.com/repos/anchore/grype/releases/latest | jq -r .tag_name | sed "s/^v//") && seg_dl "https://github.com/anchore/grype/releases/download/v${ver}/grype_${ver}_linux_amd64.tar.gz" /tmp/grype.tgz && mkdir -p "$HOME/github-tools" && tar -xzf /tmp/grype.tgz -C "$HOME/github-tools" grype && chmod +x "$HOME/github-tools/grype" && rm -f /tmp/grype.tgz && mkdir -p "$HOME/github-tools/.tool-versions" && printf "%s\n" "$ver" > "$HOME/github-tools/.tool-versions/grype"'
    [codeql]='{ command -v unzip >/dev/null || sudo apt install unzip -y; } && ARCH=$(uname -m) && { [ "$ARCH" = "x86_64" ] && B="codeql-linux64.zip" || B="codeql-linux-arm64.zip"; } && seg_dl "https://github.com/github/codeql-cli-binaries/releases/latest/download/$B" /tmp/codeql.zip 48 && mkdir -p "$HOME/github-tools" && unzip -oq /tmp/codeql.zip -d "$HOME/github-tools" && rm -f /tmp/codeql.zip'
    [semgrep]='pip_install_tool semgrep semgrep'
    [retire]='mkdir -p "$HOME/github-tools" && npm install -g --prefix "$HOME/github-tools/.npm" --no-fund --no-audit --loglevel=error retire && ln -sf "$HOME/github-tools/.npm/bin/retire" "$HOME/github-tools/retire"'
    [jq]='ver=$(curl -s https://api.github.com/repos/jqlang/jq/releases/latest | jq -r .tag_name | sed "s/^jq-//;s/^v//") && mkdir -p "$HOME/github-tools" && curl -sSfL https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64 -o "$HOME/github-tools/jq" && chmod +x "$HOME/github-tools/jq" && mkdir -p "$HOME/github-tools/.tool-versions" && printf "%s\n" "$ver" > "$HOME/github-tools/.tool-versions/jq"'
    [openssl]='sudo apt install openssl -y'
    [waymore]='pip_install_tool waymore git+https://github.com/xnl-h4ck3r/waymore.git'
)

maybe_fresh_restart() {
    [ "${INSTALLED_ANYTHING:-0}" = "1" ] || return 0
    out ""
    out "${C_Y}one or more tools were installed during this session${C_R}"
    out "${C_Y}press Enter to restart reconly in a clean environment (recommended)${C_R}"
    if ! { read -r _ < /dev/tty; } 2>/dev/null; then
        out "  ${C_W}no interactive terminal -- continuing in the current session${C_R}"
        return 0
    fi
    clear 2>/dev/null || true
    out "${C_W}re-running: $0 ${ORIG_ARGS[*]}${C_R}"
    cd "$BASE_DIR" 2>/dev/null || cd / 2>/dev/null || true
    flock -u 300 2>/dev/null || true
    rm -rf "$SESSION_DIR" 2>/dev/null || true
    exec "$0" "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
}

codeql_pack_use_downloads() {
    local _f _repo _tmp _suite _packs
    _repo="$HOME/github-tools/.codeql/codeql-src"
    for _f in "$HOME"/Downloads/github-codeql-*.tar.gz "$HOME"/Downloads/codeql-src*.tar.gz "$HOME"/Downloads/codeql*.tar.gz; do
        [ -f "$_f" ] || continue
        if ! gzip -t "$_f" 2>/dev/null; then
            out "  ${C_Y}[warn] ~/Downloads/$(basename "$_f"): CORRUPT or truncated archive -- re-download it${C_R}"
            continue
        fi
        _tmp=$(mktemp -d 2>/dev/null) || continue
        out "  ${C_W}inspecting ~/Downloads/$(basename "$_f") ...${C_R}"
        if ! tar -xzf "$_f" -C "$_tmp" --strip-components=1 2>/dev/null; then
            out "  ${C_Y}[warn] extraction failed: $(basename "$_f")${C_R}"
            rm -rf "$_tmp"
            continue
        fi
        _suite=$(find "$_tmp" -name 'javascript-security-extended.qls' 2>/dev/null | head -1)
        if [ -z "$_suite" ]; then
            out "  ${C_Y}[warn] $(basename "$_f"): suite javascript-security-extended.qls not found -- suites present: $(find "$_tmp" -path '*codeql-suites*' -name '*.qls' 2>/dev/null | head -3 | tr '\n' ' ')${C_R}"
            rm -rf "$_tmp"
            continue
        fi
        _packs=$(find "$_tmp/javascript" "$_tmp/shared" \( -name qlpack.yml -o -name codeql-pack.yml \) -printf '%h\n' 2>/dev/null | sort -u | tr '\n' ':')
        if [ -z "$_packs" ]; then
            out "  ${C_Y}[warn] $(basename "$_f"): no qlpack manifests found${C_R}"
            rm -rf "$_tmp"
            continue
        fi
        if codeql resolve qlpacks --additional-packs "$_packs" 2>/dev/null | grep -q "javascript-queries"; then
            rm -rf "$_repo"
            mkdir -p "$_repo"
            if cp -a "$_tmp"/. "$_repo"/ 2>/dev/null; then
                rm -rf "$_tmp"
                out "${C_GRN}  query packs installed from $(basename "$_f")${C_R}"
                return 0
            fi
            rm -rf "$_tmp" "$_repo"
            continue
        fi
        out "  ${C_Y}[warn] $(basename "$_f"): extracted but codeql could not resolve javascript-queries from it${C_R}"
        rm -rf "$_tmp"
    done
    return 1
}

export -f codeql_pack_use_downloads

codeql_cache_migrate() {
    [ -d "$HOME/.codeql/packages" ] || return 0
    [ -L "$HOME/.codeql" ] && return 0
    mkdir -p "$HOME/github-tools/.codeql/packages"
    local _scope _pk _dest
    for _scope in "$HOME/.codeql"/packages/*; do
        [ -d "$_scope" ] || continue
        _dest="$HOME/github-tools/.codeql/packages/$(basename "$_scope")"
        if [ ! -d "$_dest" ]; then
            mv "$_scope" "$_dest" 2>/dev/null && continue
        fi
        for _pk in "$_scope"/*; do
            [ -d "$_pk" ] || continue
            mv -n "$_pk" "$_dest/" 2>/dev/null
        done
    done
    rm -rf "$HOME/.codeql"
    out "  ${C_W}migrated codeql pack cache -> ~/github-tools/.codeql${C_R}"
}

ensure_runtime_deps() {
    codeql_cache_migrate
    mkdir -p "$HOME/github-tools/.codeql"
    if [ ! -e "$HOME/.codeql" ]; then
        ln -sfn "$HOME/github-tools/.codeql" "$HOME/.codeql"
        out "  ${C_W}~/.codeql -> ~/github-tools/.codeql (codeql default location now lives in github-tools)${C_R}"
    fi
    if command -v codeql &>/dev/null && ! ls "$HOME/github-tools/.codeql"/packages/codeql/javascript-queries/*/ &>/dev/null 2>&1 \
       && [ -z "$(find "$HOME/github-tools/.codeql/codeql-src" -path '*codeql-suites/javascript-security-extended.qls' 2>/dev/null | head -1)" ]; then
        out "${C_W}codeql/javascript-queries query pack -> $HOME/github-tools/.codeql/ (one-time, BEFORE scanning starts)${C_R}"
        if codeql_pack_use_downloads; then
            out "${C_GRN}query packs installed from your ~/Downloads copy${C_R}"
        elif ls "$HOME/github-tools/.codeql"/packages/codeql/javascript-queries/*/ &>/dev/null 2>&1; then
            out "${C_GRN}query pack already cached${C_R}"
        else
            out ""
            out "${C_Y}query packs are NOT installed -- one manual step, then rerun:${C_R}"
            out "  1) download ONE of these in your browser (phone hotspot = different ISP, no throttle):"
            out "       https://codeload.github.com/github/codeql/legacy.tar.gz/codeql-cli-2.27.1"
            out "       https://codeload.github.com/github/codeql/legacy.tar.gz/main"
            out "  2) leave the .tar.gz in ~/Downloads -- reconly installs it automatically on the next run."
            out "     (or extract manually: mkdir -p ~/github-tools/.codeql/codeql-src &&"
            out "      tar -xzf ~/Downloads/<file>.tar.gz -C ~/github-tools/.codeql/codeql-src --strip-components=1)"
            out "  3) verify: find ~/github-tools/.codeql/codeql-src -name javascript-security-extended.qls | head -1  (should print a path)"
            out "  4) rerun reconly"
            out ""
            out "${C_Y}stopped -- do the manual step above and rerun.${C_R}"
            exit 1
        fi
    fi
}

ensure_global_path() {
    mkdir -p "$HOME/github-tools" "$HOME/.local/bin" "$HOME/go/bin" 2>/dev/null || true
    case ":$PATH:" in *":$HOME/github-tools:"*) ;; *) export PATH="$PATH:$HOME/github-tools" ;; esac
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$PATH:$HOME/.local/bin" ;; esac
    case ":$PATH:" in *":$HOME/go/bin:"*) ;; *) export PATH="$PATH:$HOME/go/bin" ;; esac
    case ":$PATH:" in *":$HOME/go-sdk/bin:"*) ;; *) [ -d "$HOME/go-sdk/bin" ] && export PATH="$PATH:$HOME/go-sdk/bin" ;; esac
    case ":$PATH:" in *":$HOME/github-tools/codeql:"*) ;; *) [ -d "$HOME/github-tools/codeql" ] && export PATH="$PATH:$HOME/github-tools/codeql" ;; esac
    if command -v python3 >/dev/null 2>&1; then
        _ub=$(python3 -m site --user-base 2>/dev/null)
        if [ -n "$_ub" ] && [ -d "$_ub/bin" ]; then
            case ":$PATH:" in *":$_ub/bin:"*) ;; *) export PATH="$PATH:$_ub/bin" ;; esac
        fi
    fi
    local _line='export PATH="$HOME/github-tools:$HOME/github-tools/codeql:$HOME/.local/bin:$HOME/go/bin:$PATH"' _wrote=0 _rc
    for _rc in "$HOME/.profile" "$HOME/.bashrc"; do
        if [ -f "$_rc" ]; then
            grep -q 'github-tools' "$_rc" 2>/dev/null || { printf '\n%s\n' "$_line" >> "$_rc"; _wrote=1; }
        fi
    done
    if [ ! -f "$HOME/.profile" ] && [ ! -f "$HOME/.bashrc" ]; then
        printf '%s\n' "$_line" >> "$HOME/.profile"; _wrote=1
    fi
    if [ "$_wrote" -eq 1 ]; then out "  ${C_W}PATH persistence added (~/.profile + ~/.bashrc): ~/github-tools, ~/.local/bin, ~/go/bin${C_R}"; fi
    return 0
}

locate_tool() {
    local t="$1" pp="" _ub=""
    pp=$(command -v "$t" 2>/dev/null || true)
    if [ -z "$pp" ] && [ -x "$HOME/.local/bin/$t" ]; then pp="$HOME/.local/bin/$t"; fi
    if [ -z "$pp" ] && [ -x "$HOME/go/bin/$t" ]; then pp="$HOME/go/bin/$t"; fi
    if [ -z "$pp" ] && [ -x "/usr/local/bin/$t" ]; then pp="/usr/local/bin/$t"; fi
    if [ -z "$pp" ] && [ -x "$HOME/github-tools/$t" ]; then pp="$HOME/github-tools/$t"; fi
    if [ -z "$pp" ] && [ -x "$HOME/github-tools/$t/$t" ]; then pp="$HOME/github-tools/$t/$t"; fi
    if [ -z "$pp" ] && [ -x "$HOME/github-tools/bin/$t" ]; then pp="$HOME/github-tools/bin/$t"; fi
    if [ -z "$pp" ] && command -v python3 >/dev/null 2>&1; then
        _ub=$(python3 -m site --user-base 2>/dev/null)
        if [ -n "$_ub" ] && [ -x "$_ub/bin/$t" ]; then pp="$_ub/bin/$t"; fi
    fi
    if [ -n "$pp" ]; then printf '%s\n' "$pp"; fi
    return 0
}

ensure_go() {
    command -v go &>/dev/null && return 0
    out "  ${C_W}installing Go (required by many tools) ...${C_R}"
    mkdir -p "$HOME/.cache" 2>/dev/null || true
    local _gv _gt
    _gv=$(curl -s -m 20 'https://go.dev/dl/?mode=json' | jq -r '.[0].version' 2>/dev/null) || true
    if [ -z "$_gv" ]; then _gv="go1.22.5"; fi
    _gt="${_gv}.linux-amd64.tar.gz"
    if curl -sSfL "https://go.dev/dl/${_gt}" -o "$HOME/.cache/go.tgz" 2>/dev/null && [ -s "$HOME/.cache/go.tgz" ]; then
        mkdir -p "$HOME/go-sdk" && tar -xzf "$HOME/.cache/go.tgz" -C "$HOME/go-sdk" --strip-components=1 && rm -f "$HOME/.cache/go.tgz"
        export PATH="$HOME/go-sdk/bin:$PATH"
        local _gline='export PATH="$HOME/go-sdk/bin:$PATH"' _rc
        for _rc in "$HOME/.profile" "$HOME/.bashrc"; do
            [ -f "$_rc" ] && ! grep -q 'go-sdk/bin' "$_rc" 2>/dev/null && printf '\n%s\n' "$_gline" >> "$_rc"
        done
        out "${C_GRN}  Go installed -> $HOME/go-sdk/bin/go${C_R}"
    else
        out "  ${C_Y}[warn] Go download failed -- go-based installs will fail${C_R}"
    fi
    return 0
}

ensure_pip() {
    command -v python3 &>/dev/null || { out "  ${C_Y}[warn] python3 missing -- pip-based tools cannot install${C_R}"; return 0; }
    python3 -m pip --version &>/dev/null && return 0
    out "  ${C_W}bootstrapping pip ...${C_R}"
    python3 -m ensurepip --upgrade >/dev/null 2>&1 || out "  ${C_Y}[warn] ensurepip failed (try: sudo apt install python3-pip)${C_R}"
    return 0
}

seg_dl() {
    local _url="$1" _out="$2" _n="${3:-24}" _auth="${4:-}" _size _i _s _e _chunk _tmp _got _hdr=() _want
    [ -n "$_auth" ] && _hdr=(-H "$_auth")
    _tmp=$(mktemp -d 2>/dev/null) || return 1
    _size=$(curl -sIL -m 30 "${_hdr[@]+${_hdr[@]}}" "$_url" 2>/dev/null | tr -d '\r' | grep -i '^content-length:' | tail -1 | awk '{print $2}')
    if [ -z "$_size" ] || [ "$_size" -le 0 ] 2>/dev/null; then
        curl -sSfL -m 7200 "${_hdr[@]+${_hdr[@]}}" -o "$_out" "$_url" 2>/dev/null || { rm -rf "$_tmp"; return 1; }
        rm -rf "$_tmp"; return 0
    fi
    _want=$(( ( _size + 4194303 ) / 4194304 ))
    [ "$_want" -lt 8 ] && _want=8
    [ "$_want" -gt 64 ] && _want=64
    if [ "$_n" -gt "$_want" ]; then _want=$_n; fi
    [ "$_want" -gt 96 ] && _want=96
    out "  ${C_W}segmented download x$_want: $(basename "$_out") ($_size bytes)${C_R}"
    _chunk=$(( ( _size + _want - 1 ) / _want ))
    for _i in $(seq 0 $(( _want - 1 ))); do
        _s=$(( _i * _chunk )); [ "$_s" -ge "$_size" ] && break
        _e=$(( _s + _chunk - 1 )); [ "$_e" -ge "$_size" ] && _e=$(( _size - 1 ))
        (
            _p="$_tmp/$(printf 'p%03d' "$_i")"
            : > "$_p"
            for _att in 1 2 3; do
                _have=$(wc -c < "$_p" 2>/dev/null | tr -d ' '); _have=${_have:-0}
                _need=$(( _e - _s + 1 - _have ))
                [ "$_need" -le 0 ] && break
                _rs=$(( _s + _have ))
                curl -sSfL --speed-limit 20480 --speed-time 15 -m 180 "${_hdr[@]+${_hdr[@]}}" -r "$_rs-$_e" "$_url" >> "$_p" 2>/dev/null
            done
        ) &
    done
    wait
    cat "$_tmp"/p??? > "$_out" 2>/dev/null || true
    rm -rf "$_tmp"
    _got=$(wc -c < "$_out" 2>/dev/null | tr -d ' ')
    if [ "$_got" != "$_size" ]; then
        curl -sSfL --speed-limit 20480 --speed-time 15 -m 240 "${_hdr[@]+${_hdr[@]}}" -o "$_out" "$_url" 2>/dev/null
        _got=$(wc -c < "$_out" 2>/dev/null | tr -d ' ')
    fi
    [ "$_got" = "$_size" ]
}
export -f seg_dl

pip_pick_fast_index() {
    [ -n "$PIP_FAST_INDEX" ] && return 0
    if [ -n "${PIP_INDEX_URL:-}" ]; then
        PIP_FAST_INDEX="$PIP_INDEX_URL"
        return 0
    fi
    local _m _t0 _dt _best_t=999999 _best_m="" _tmp
    _tmp=$(mktemp -d 2>/dev/null) || { PIP_FAST_INDEX="https://pypi.org/simple"; return 0; }
    for _m in \
        https://pypi.org/simple \
        https://pypi.tuna.tsinghua.edu.cn/simple \
        https://mirrors.aliyun.com/pypi/simple/ \
        https://mirror.kakao.com/pypi/simple \
        https://mirrors.cloud.tencent.com/pypi/simple; do
        _t0=$(date +%s%N 2>/dev/null || date +%s)
        if timeout 20 pip download pillow --no-deps -d "$_tmp" -i "$_m" --no-cache-dir -q >/dev/null 2>&1; then
            _dt=$(( ( $(date +%s%N 2>/dev/null || date +%s) - _t0 ) / 1000000 ))
            if [ "$_dt" -lt "$_best_t" ]; then _best_t=$_dt; _best_m="$_m"; fi
        fi
    done
    rm -rf "$_tmp"
    PIP_FAST_INDEX="${_best_m:-https://pypi.org/simple}"
    out "  ${C_W}fastest PyPI mirror: $PIP_FAST_INDEX (probe: ${_best_t}ms)${C_R}"
}

pip_fetch_segmented() {
    local _pkg="$1" _idx _html _url _fname _size _n=24 _i _s _e _chunk _d _got
    _d=$(mktemp -d 2>/dev/null) || return 1
    _idx="${PIP_FAST_INDEX%/}/$_pkg/"
    _html=$(curl -sS -m 30 "$_idx" 2>/dev/null)
    _url=$(printf '%s' "$_html" | python3 -c 'import sys, re, urllib.parse
base, html = sys.argv[1], sys.stdin.read()
best = None
for href, name in re.findall(r"href=\"([^\"]+\.whl)#sha256=[0-9a-f]+\"[^>]*>([^<]+)</a>", html):
    if "x86_64" in name and ("manylinux" in name or "musllinux" in name):
        best = urllib.parse.urljoin(base, href)
print(best or "")' "$_idx" 2>/dev/null)
    if [ -z "$_url" ]; then rm -rf "$_d"; return 1; fi
    _fname="${_url##*/}"
    _size=$(curl -sIL -m 30 "$_url" 2>/dev/null | tr -d '\r' | grep -i '^content-length:' | tail -1 | awk '{print $2}')
    if [ -z "$_size" ] || [ "$_size" -le 0 ] 2>/dev/null; then rm -rf "$_d"; return 1; fi
    if [ "$_size" -lt 20000000 ]; then rm -rf "$_d"; return 1; fi
    out "  ${C_W}$_fname is $_size bytes -- segmented download (x$_n streams)${C_R}"
    _chunk=$(( ( _size + _n - 1 ) / _n ))
    for _i in $(seq 0 $(( _n - 1 ))); do
        _s=$(( _i * _chunk )); [ "$_s" -ge "$_size" ] && break
        _e=$(( _s + _chunk - 1 )); [ "$_e" -ge "$_size" ] && _e=$(( _size - 1 ))
        curl -sS --retry 3 --retry-delay 1 -m 1800 -r "$_s-$_e" -o "$_d/$(printf 'p%03d' "$_i")" "$_url" 2>/dev/null &
    done
    wait
    cat "$_d"/p??? > "$_d/$_fname" 2>/dev/null || true
    rm -f "$_d"/p???
    _got=$(wc -c < "$_d/$_fname" 2>/dev/null | tr -d ' ')
    if [ "$_got" != "$_size" ]; then rm -rf "$_d"; return 1; fi
    ( cd "$_d" && pip install ${PYBSP:-} -i "$PIP_FAST_INDEX" "$_fname" >/dev/null 2>&1 )
    rm -rf "$_d"
}
export -f pip_fetch_segmented

pip_install_tool() {
    local _t="$1" _spec="$2" _ub="" _s=""
    pip_pick_fast_index
    if [ "${_spec#git+}" = "$_spec" ]; then
        pip_fetch_segmented "$_spec" || true
    fi
    if ! command -v "$_t" >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/$_t" ] && [ ! -x "$HOME/github-tools/$_t" ]; then
        pip install ${PYBSP:-} -i "$PIP_FAST_INDEX" "$_spec" >/dev/null 2>&1
    fi
    if ! command -v "$_t" >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/$_t" ] && [ ! -x "$HOME/github-tools/$_t" ]; then
        if [ "$PIP_FAST_INDEX" != "https://pypi.org/simple" ]; then
            pip install ${PYBSP:-} -i https://pypi.org/simple "$_spec" >/dev/null 2>&1
        fi
    fi
    if ! command -v "$_t" >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/$_t" ] && [ ! -x "$HOME/github-tools/$_t" ]; then
        pip install ${PYBSP:-} -i "$PIP_FAST_INDEX" --force-reinstall --no-deps "$_spec" >/dev/null 2>&1
    fi
    _ub=$(python3 -m site --user-base 2>/dev/null)
    for _s in "$HOME/.local/bin/$_t" "$_ub/bin/$_t"; do
        if [ -f "$_s" ]; then
            if [ -e "$HOME/github-tools/$_t" ] || [ -L "$HOME/github-tools/$_t" ]; then
                rm -f "$_s"
            else
                mv -f "$_s" "$HOME/github-tools/$_t" 2>/dev/null || { cp -f "$_s" "$HOME/github-tools/$_t" 2>/dev/null && rm -f "$_s"; }
            fi
            break
        fi
    done
}
export -f pip_install_tool pip_pick_fast_index

smoke_test() {
    local t="$1" rc=127
    case "$t" in
        jsluice)   ( printf 'var u="/x";\n' | timeout 15 jsluice urls -j >/dev/null 2>&1 ) 2>/dev/null; rc=$? ;;
        gitleaks)  ( timeout 15 gitleaks version >/dev/null 2>&1 ) 2>/dev/null; rc=$? ;;
        *)         for _a in -version --version version -V -h --help; do
                       ( timeout 15 "$t" "$_a" >/dev/null 2>&1 ) 2>/dev/null && { rc=0; break; }
                   done ;;
    esac
    [ "${rc:-127}" -lt 126 ]
}

_ver_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        n=split(a,x,"."); m=split(b,y,".");
        for(i=1;i<=3;i++){ xi=(i<=n)?x[i]+0:0; yi=(i<=m)?y[i]+0:0;
            if(xi<yi){exit 0}
            if(xi>yi){exit 1}
        }
        exit 1
    }'
}

check_for_updates() {
    [ "${RECONLY_CHECK_UPDATES:-1}" = "1" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    local cache="$HOME/github-tools/.tool-versions/.updatable"
    mkdir -p "$HOME/github-tools/.tool-versions"
    local hb; hb=$(date +%Y%m%d%H)
    if [ -f "$cache" ] && head -1 "$cache" 2>/dev/null | grep -q "^#$hb$"        && [ "$(grep -vc '^#' "$cache" 2>/dev/null | tr -d ' ')" -gt 0 ]; then
        return 0
    fi
    local -A LATEST=(
        [subfinder]='go:github.com/projectdiscovery/subfinder/v2'
        [amass]='go:github.com/owasp-amass/amass/v5'
        [dnsx]='go:github.com/projectdiscovery/dnsx'
        [httpx]='go:github.com/projectdiscovery/httpx'
        [naabu]='go:github.com/projectdiscovery/naabu/v2'
        [katana]='go:github.com/projectdiscovery/katana'
        [gau]='go:github.com/lc/gau/v2'
        [jsluice]='go:github.com/BishopFox/jsluice'
        [gitleaks]='go:github.com/zricethezav/gitleaks/v8'
        [semgrep]='pypi:semgrep'
        [waymore]='pypi:waymore'
        [jq]='gh:jqlang/jq'
        [trufflehog]='gh:trufflesecurity/trufflehog'
        [noseyparker]='gh:praetorian-inc/noseyparker'
        [syft]='gh:anchore/syft'
        [grype]='gh:anchore/grype'
        [codeql]='gh:github/codeql-cli-binaries'
        [retire]='gh:RetireJS/retire.js'
    )
    local tmp; tmp=$(mktemp)
    printf '#%s\n' "$hb" > "$tmp"
    local t spec src ref latest
    for t in "${!LATEST[@]}"; do
        (
            spec="${LATEST[$t]}"
            src="${spec%%:*}"; ref="${spec#*:}"
            latest=""
            case "$src" in
                go)   latest=$(curl -s -m 5 "https://proxy.golang.org/${ref}/@latest" 2>/dev/null | jq -r '.Version // empty' 2>/dev/null) || true ;;
                pypi) latest=$(curl -s -m 5 "https://pypi.org/pypi/${ref}/json" 2>/dev/null | jq -r '.info.version // empty' 2>/dev/null) || true ;;
                gh)   latest=$(curl -s -m 5 "https://api.github.com/repos/${ref}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null) || true ;;
            esac
            latest=$(printf '%s' "$latest" | sed -e 's/^v//' -e 's/^jq-//' | grep -E '^[0-9]' || true)
            [ -n "$latest" ] && printf '%s=%s\n' "$t" "$latest" >> "$tmp"
        ) &
    done
    wait
    { printf '#%s\n' "$hb"; grep -v '^#' "$tmp" 2>/dev/null | sort -u || true; } > "$cache.$$" 2>/dev/null && mv -f "$cache.$$" "$cache"
    rm -f "$tmp"
    return 0
}

check_tools() {
    local _utils=(curl flock xargs md5sum perl openssl split)
    local _all=("${_utils[@]}" "${TOOL_LIST[@]}")

    ensure_global_path
    rm -rf "$HOME/github-tools/.versions" 2>/dev/null || true

    out "${C_K}____________________________________________________________________________________${C_R}"
    check_for_updates &
    local _updpid=$!
    _versions=$(printf '%s\n' "${_all[@]}" | xargs -d '\n' -P 8 -I {} bash -c '
        t="$1"
        _vc="$HOME/github-tools/.tool-versions/$t"
        _old=""
        if [ -f "$_vc" ]; then
            _old=$(cat "$_vc" 2>/dev/null)
            case "$_old" in *[!0-9A-Za-z.+-]*) _old="" ;; esac
        fi
        v=""
        case "$t" in
            waymore)
                v=$(python3 -c "import importlib.metadata as m; print(m.version(\"waymore\"))" 2>/dev/null)
                [ -z "$v" ] && v=$(pip show waymore 2>/dev/null | awk -F": " "/^Version:/{print \$2}") ;;
            noseyparker)
                v=$(timeout --foreground 5 noseyparker --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1) ;;
            *)
                _go=$(command -v go 2>/dev/null || true)
                [ -z "$_go" ] && [ -x "$HOME/go-sdk/bin/go" ] && _go="$HOME/go-sdk/bin/go"
                [ -z "$_go" ] && [ -x "$HOME/go/bin/go" ] && _go="$HOME/go/bin/go"
                if [ -n "$_go" ]; then
                    v=$("$_go" version -m "$(command -v "$t" 2>/dev/null)" 2>/dev/null | grep -m1 "mod" | tr -s " \t" " " | sed -e "s/^ *//" | cut -d" " -f3 | cut -c1-60)
                fi
                if [ -z "$v" ]; then
                    for _a in -version --version version -v -V; do
                        txt=$(timeout --foreground 5 "$t" "$_a" 2>&1) || true
                        v=$(printf "%s\n" "$txt" | grep -i "version" | grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | head -1)
                        [ -n "$v" ] && break
                        v=$(printf "%s\n" "$txt" | grep -viE "usage|flag|error|unknown|shorthand|option|invalid|unrecogni[sz]ed|no such|illegal|try |help|go1" | grep -vE "://|:[0-9]" | grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | head -1)
                        [ -n "$v" ] && break
                    done
                fi ;;
        esac
        if [ -z "$v" ]; then
            v="$_old"
        fi
        v="${v#v}"
        case "$v" in
            0.0.0-2[0-9][0-9][0-9]*) v=$(printf '%s' "$v" | sed -E 's/^0\.0\.0-[0-9]{14}-/dev-/' | cut -c1-12) ;;
        esac
        if [ -n "$v" ] && [ "$v" != "unknown" ]; then
            printf "%s=%s\n" "$t" "$v"
            mkdir -p "$HOME/github-tools/.tool-versions" 2>/dev/null
            printf '%s\n' "$v" > "$_vc" 2>/dev/null
        else
            printf "%s=unknown\n" "$t"
        fi
        exit 0
    ' _ {} || true) || true

    _globalpaths=$(env HOME="$HOME" TERM=dumb bash -ic 'for _t in "$@"; do _pp=$(command -v "$_t" 2>/dev/null || true); printf "G:%s=%s\n" "$_t" "${_pp:-MISSING}"; done' _ "${_all[@]}" 2>/dev/null || true)

    wait "$_updpid" 2>/dev/null || true

    local _missing="" _have=0 _nm=0 _t _x _p _v _g _gsfx MISSING=""
    local -a _g_sys=() _g_go=() _g_gt=() _g_miss=()
    local -a _disp=( "${_utils[@]}" jq codeql subfinder httpx naabu katana semgrep syft grype noseyparker waymore gitleaks dnsx gau amass jsluice trufflehog retire )
    for _t in "${_disp[@]}"; do
        _p=$(locate_tool "$_t")
        _v=$(printf '%s\n' "$_versions" | awk -F= -v k="$_t" '$1==k{print substr($0, index($0,"=")+1); exit}')
        _v=$(printf '%s' "${_v:-unknown}" | sed -e "s/^v//" | tr -d "\n" | cut -c1-44)
        case "$_v" in [0-9]*|dev-*) ;; *) _v="unknown" ;; esac
        _g=$(printf '%s\n' "$_globalpaths" | awk -v k="$_t" '{n=$0; sub(/^G:/,"",n); split(n,a,"="); if(a[1]==k){v=n; sub(/^[^=]*=/,"",v); print v; exit}}')
        _gsfx=""
        if [ -n "$_p" ]; then
            _have=$((_have+1))
            if [ -z "$_g" ] || [ "$_g" = "MISSING" ]; then
                _gsfx="  ${C_Y}[not on fresh-terminal PATH]${C_R}"
            fi
            local _tpad _vpad _vdisp
            printf -v _tpad '%*s' $(( 16 - ${#_t} )) ''
            case "$_v" in
                dev-*) _vdisp="------" ;;
                *)     _vdisp="$_v" ;;
            esac
            printf -v _vpad '%*s' $(( 10 - ${#_vdisp} )) ''
            local _up="" _latest
            _latest=$(awk -F= -v k="$_t" '$1==k{print $2; exit}' "$HOME/github-tools/.tool-versions/.updatable" 2>/dev/null || true)
            if [ -n "$_latest" ] && [ "$_v" != "unknown" ]; then
                case "$_v" in
                    dev-*) ;;
                    *) _ver_lt "$_v" "$_latest" && _up="  ${C_Y}[UP]${C_R}" ;;
                esac
            fi
            local _pdisp="${_p/#$HOME/\~}"
            local _line="${C_GRN}[installed]${C_R} ${C_W}$_t${_tpad}${C_R}${C_Y}v $_vdisp${_vpad}${C_R}dir ${C_MAG}$_pdisp${_gsfx}${C_R}$_up"
            case "$_p" in
                "$HOME"/go/bin/*)       _g_go+=("$_line") ;;
                "$HOME"/github-tools/*) _g_gt+=("$_line") ;;
                *)                      _g_sys+=("$_line") ;;
            esac
        else
            _missing="$_missing $_t"
            _g_miss+=("${C_RED}[missing]${C_R}   ${C_W}$_t${C_R}")
        fi
    done
    for _l in "${_g_sys[@]+"${_g_sys[@]}"}"; do out "$_l"; done
    for _l in "${_g_go[@]+"${_g_go[@]}"}";  do out "$_l"; done
    for _l in "${_g_gt[@]+"${_g_gt[@]}"}";  do out "$_l"; done
    for _l in "${_g_miss[@]+"${_g_miss[@]}"}"; do out "$_l"; done
    for _x in $_missing; do _nm=$((_nm+1)); done
    out "${C_K}_____________________________ $_have installed | $_nm missing _____________________________${C_R}"

    if [ -n "$_missing" ] && [ "$RECONLY_AUTO_INSTALL" != "0" ]; then
        PYBSP=""
        if command -v python3 >/dev/null 2>&1; then
            _sd=$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))' 2>/dev/null)
            [ -n "$_sd" ] && [ -f "$_sd/EXTERNALLY-MANAGED" ] && PYBSP="--break-system-packages"
        fi
        export PYBSP
        if [ -z "$(locate_tool jq)" ]; then
            out "  ${C_W}bootstrapping jq first -- other installers need it for GitHub API JSON${C_R}"
            mkdir -p "$HOME/github-tools"
            if curl -sSfL https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64 -o "$HOME/github-tools/jq" 2>/dev/null && chmod +x "$HOME/github-tools/jq"; then
                export PATH="$PATH:$HOME/github-tools"
                out "${C_GRN}  jq bootstrapped -> $HOME/github-tools/jq${C_R}"
            fi
        fi
        ensure_go
        ensure_pip
        out ""
        out "${C_W}installing $_nm missing tool(s) via official installers${C_R}"
        INSTALLED_ANYTHING=1
        out "  ${C_Y}note: go tools compile from source and downloads take time -- total ~10-20 min on a fresh machine. Do NOT interrupt.${C_R}"
        for _t in $_missing; do
            hint="${TOOL_INSTALL[$_t]:-}"
            if [ -z "$hint" ]; then
                out "  ${C_Y}[warn] no official installer known for $_t${C_R}"
                continue
            fi
            out "  ${C_W}installing $_t ...${C_R}"
            out "    ${C_MAG}cmd: $hint${C_R}"
            if ( timeout --foreground 900 bash -c "$hint" ); then
                export PATH="$PATH:$HOME/github-tools:$HOME/.local/bin:$HOME/go/bin:$HOME/github-tools/codeql"
                _p=$(locate_tool "$_t")
                if [ -n "$_p" ]; then
                    _v=$(timeout --foreground 5 "$_t" --version 2>&1 | grep -oiE '[0-9]+\.[0-9]+([.][0-9]+)?' | head -1 || true)
                    [ -z "$_v" ] && _v=$(timeout --foreground 5 "$_t" version 2>&1 | grep -oiE '[0-9]+\.[0-9]+([.][0-9]+)?' | head -1 || true)
                    out "${C_GRN}  $_t installed${_v:+ v$_v} -> $_p${C_R}"
                else
                    out "  ${C_Y}[warn] $_t installer ran but produced no binary (search ~/.local/bin, ~/go/bin)${C_R}"
                fi
            else
                out "  ${C_RED}[warn] $_t install failed -- REQUIRED${C_R}"
            fi
        done
        export PATH="$PATH:$HOME/github-tools:$HOME/.local/bin:$HOME/go/bin:$HOME/codeql"
        _globalpaths=$(env HOME="$HOME" TERM=dumb bash -ic 'for _t in "$@"; do _pp=$(command -v "$_t" 2>/dev/null || true); printf "G:%s=%s\n" "$_t" "${_pp:-MISSING}"; done' _ $_missing 2>/dev/null || true)
        for _t in $_missing; do
            _g=$(printf '%s\n' "$_globalpaths" | awk -v k="$_t" '{n=$0; sub(/^G:/,"",n); split(n,a,"="); if(a[1]==k){v=n; sub(/^[^=]*=/,"",v); print v; exit}}')
            _p=$(locate_tool "$_t")
            if [ -n "$_p" ] && { [ -z "$_g" ] || [ "$_g" = "MISSING" ]; }; then
                out "  ${C_Y}$_t works in this run but not in a fresh terminal yet — open a new terminal (or: source ~/.profile)${C_R}"
            fi
        done
    elif [ -n "$_missing" ]; then
        out "${C_Y}RECONLY_AUTO_INSTALL=0 -- skipping installs (missing:$_missing)${C_R}"
    fi

    local _rc
    for _rc in "$HOME/.bashrc" "$HOME/.profile"; do
        if [ -f "$_rc" ] && ! grep -q 'github-tools' "$_rc" 2>/dev/null; then
            printf '\n#github-tools\nexport PATH="$PATH:$HOME/github-tools:$HOME/github-tools/codeql:$HOME/go/bin"\n' >> "$_rc"
            out "  ${C_W}PATH persistence added to $_rc (github-tools + go/bin)${C_R}"
        fi
    done
    local _gtmoved=0
    for _t in "${TOOL_LIST[@]}"; do
        _p=$(locate_tool "$_t")
        [ -z "$_p" ] && continue
        case "$_p" in
            "$HOME"/github-tools/bin/*) ;;
            "$HOME"/go/bin/*|"$HOME"/github-tools/*|/usr/*) continue ;;
            *)  if [ -f "$_p" ]; then
                    if mv -f "$_p" "$HOME/github-tools/$_t" 2>/dev/null; then
                        _gtmoved=$((_gtmoved+1))
                    else
                        ln -sf "$_p" "$HOME/github-tools/$_t" 2>/dev/null && _gtmoved=$((_gtmoved+1))
                    fi
                fi ;;
        esac
    done
    if [ "$_gtmoved" -gt 0 ]; then
        out "  ${C_W}moved $_gtmoved tool(s) into ~/github-tools -- single inventory folder${C_R}"
    fi
    local _nested=0
    for _t in "${TOOL_LIST[@]}"; do
        [ -e "$HOME/github-tools/$_t" ] && continue
        _p=$(find "$HOME/github-tools" -mindepth 2 -maxdepth 3 -type f -name "$_t" -perm -u+x 2>/dev/null | head -1)
        if [ -n "$_p" ]; then
            ln -sf "$_p" "$HOME/github-tools/$_t" 2>/dev/null && _nested=$((_nested+1))
        fi
    done
    if [ "$_nested" -gt 0 ]; then
        out "  ${C_W}linked $_nested nested tool(s) into ~/github-tools root${C_R}"
    fi

    local _broken="" _okc=0 _totc=0
    for _t in "${TOOL_LIST[@]}"; do
        command -v "$_t" &>/dev/null || continue
        _totc=$((_totc+1))
        if smoke_test "$_t"; then
            _okc=$((_okc+1))
        else
            _broken="$_broken $_t"
        fi
    done
    if [ -n "$_broken" ]; then
        out ""
        out "${C_Y}installed but NOT functional:$_broken -- one reinstall attempt each${C_R}"
        INSTALLED_ANYTHING=1
        for _t in $_broken; do
            hint="${TOOL_INSTALL[$_t]:-}"
            if [ -z "$hint" ]; then MISSING="$MISSING $_t"; continue; fi
            out "  ${C_W}reinstalling $_t ...${C_R}"
            out "    ${C_MAG}cmd: $hint${C_R}"
            ( timeout --foreground 900 bash -c "$hint" ) || true
            export PATH="$PATH:$HOME/github-tools:$HOME/github-tools/codeql:$HOME/.local/bin:$HOME/go/bin"
            _p=$(locate_tool "$_t")
        done
        for _t in $_broken; do
            if command -v "$_t" &>/dev/null && smoke_test "$_t"; then
                out "${C_GRN}  $_t recovered -- ready${C_R}"
            else
                out "  ${C_RED}[FATAL] $_t still not functional after reinstall${C_R}"
                MISSING="$MISSING $_t"
            fi
        done
    fi

    for _t in "${TOOL_LIST[@]}" "${_utils[@]}"; do
        _p=$(locate_tool "$_t")
        [ -n "$_p" ] || MISSING="$MISSING $_t"
    done
    if [ -n "$MISSING" ]; then
        out ""
        for _t in $MISSING; do
            out "${C_RED}[FATAL] $_t still missing after install attempt${C_R}"
            hint="${TOOL_INSTALL[$_t]:-}"
            [ -n "$hint" ] && out "    Install manually: ${C_W}$hint${C_R}"
        done
        exit 1
    fi
}

BASE_DIR="$HOME/reconly/$DOMAIN"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
SESSION_DIR="$BASE_DIR/$TIMESTAMP"
mkdir -p "$SESSION_DIR"/{subdomains/raw,hosts,urls,js/{raw,formatted,mapsrc,deobf,sourcemaps,json,artifacts},findings/{secrets,analysis,probes,surface},state/tmp}
chmod 700 "$BASE_DIR" "$SESSION_DIR" 2>/dev/null || true
cd "$SESSION_DIR" || exit 1

export SESSION_DIR DOMAIN DOMAIN_ESCAPED FAKE_UA \
    RECONLY_JS_THREADS RECONLY_FETCH_THREADS RECONLY_PAGE_THREADS RECONLY_MAX_PAGES JS_MAX_ROUNDS KATANA_HEADLESS \
    PRETTIER_JOBS PRETTIER_BATCH PRETTIER_MAX_MB OBF_MAX_FILES JITTER_MIN JITTER_MAX

LOCK_FILE="$BASE_DIR/.lock"
exec 300>"$LOCK_FILE"
if ! flock -n 300; then
    die "Another reconly run is active on $DOMAIN (lock: $LOCK_FILE). Wait or rm it."
fi

exec 6>&1
exec > >(tee -a "$SESSION_DIR/reconly.log") 2>&1
out "${C_W}console mirror active -- full output (results, progress, everything) -> $SESSION_DIR/reconly.log${C_R}"

_jitter() { sleep "$(awk -v min="$JITTER_MIN" -v max="$JITTER_MAX" 'BEGIN{srand(); print (min+rand()*(max-min))/1000}')"; }
_rotate_ua() {
    [ "${UA_ROTATE:-1}" = "1" ] || return 0
    FAKE_UA="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
    export FAKE_UA
}
http_head() {
    local url="$1"
    _jitter
    curl -s -o /dev/null -D - -m 15 -A "$FAKE_UA" "$url" 2>/dev/null
}
_mpgrep() {
    local pf="$1" input="${2:-}"
    if command -v rg &>/dev/null; then
        if [ -n "$input" ]; then rg -a -o -P -f "$pf" "$input" 2>/dev/null; else rg -a -o -P -f "$pf" 2>/dev/null; fi
    else
        local i
        for i in $(seq 1 40 $(wc -l < "$pf" | tr -d ' ')); do
            local j=$((i + 39)) rx
            rx=$(sed -n "${i},${j}p" "$pf" | sed 's/.*/(?:&)/' | paste -sd'|' -)
            if [ -n "$input" ]; then grep -oP -- "$rx" "$input" 2>/dev/null; else grep -oP -- "$rx" 2>/dev/null; fi
        done
    fi
}
url_junk_filter() {
    grep -viE '%5c|%7B%7B|/undefined/|/http_|://[^/]+/(Bun|Deno|Trident|Edge|iPhone|Node\.js|Zone\.js|\.exec)/?$'
}

JS_MAP_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
export JS_MAP_TS


js_name_for_url() {
    local url="$1"
    local hash safe name
    hash=$(printf '%s' "$url" | md5sum | cut -c1-16)
    safe=$(echo "$url" | sed -e 's|^https*://||' -e 's/[^A-Za-z0-9.]/_/g' -e 's/__*/_/g')
    safe="${safe:0:60}"
    name="${safe}-${hash}.js"
    printf '%s\n' "$name"
}
record_js_map() {
    local local_name="$1" url="$2" kind="$3" parent_local="$4"
    local raw_file="$SESSION_DIR/js/raw/$local_name"
    [ -f "$raw_file" ] || return 0
    local safe_local safe_url safe_parent hash size ts
    safe_local="${local_name//|/%7C}"; safe_local="${safe_local//$'\n'/}"
    safe_url="${url//|/%7C}"; safe_url="${safe_url//$'\n'/}"
    safe_parent="${parent_local//|/%7C}"; safe_parent="${safe_parent//$'\n'/}"
    hash=$(sha256sum "$raw_file" 2>/dev/null | awk '{print $1}')
    [ -z "$hash" ] && return 1
    size=$(wc -c < "$raw_file" 2>/dev/null | tr -d '[:space:]')
    ts="${JS_MAP_TS:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
    (
        flock -w 10 200 || exit 1
        if awk -F'|' -v l="$safe_local" -v h="$hash" '$1==l && $5==h {found=1; exit} END{exit !found}' "$SESSION_DIR/state/js-map.txt" 2>/dev/null; then
            exit 0
        fi
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$safe_local" "$safe_url" "$kind" "$safe_parent" "$hash" "$ts" "$size" >> "$SESSION_DIR/state/js-map.txt"
    ) 200>"$SESSION_DIR/state/.jsmap.lock"
}
js_fetch() {
    local url="$1" kind="${2:-seed}"
    local name tmp jh canon ct curl_rc
    JS_LAST_CODE="-"
    name=$(js_name_for_url "$url")
    tmp="$SESSION_DIR/js/raw/.${name}.part.$$"

    if [ -s "$SESSION_DIR/js/raw/$name" ]; then
        ( flock -w 10 200 || exit 1
          if ! grep -Fqx "$name|$url" "$SESSION_DIR/state/url-map.txt" 2>/dev/null; then
              printf '%s|%s\n' "$name" "$url" >> "$SESSION_DIR/state/url-map.txt"
          fi
        ) 200>"$SESSION_DIR/state/.urlmap.lock"
        record_js_map "$name" "$url" "$kind" "-" 2>/dev/null || true
        return 0
    fi

    rm -f "$tmp" "$tmp.hdr"
    curl_rc=0
    JS_LAST_CODE="000"
    _jitter
    JS_LAST_CODE=$(curl -s -f -k -L --compressed -m 20 --connect-timeout 6 --max-filesize 52428800 -A "$FAKE_UA" -D "$tmp.hdr" "$url" -o "$tmp" -w "%{http_code}" 2>/dev/null) || curl_rc=$?
    [ -n "$JS_LAST_CODE" ] || JS_LAST_CODE="000"
    if [ "$curl_rc" -eq 0 ] && [ -s "$tmp" ]; then
        ct=$(grep -i '^content-type:' "$tmp.hdr" 2>/dev/null | tail -1 | tr -d '\r' | cut -d: -f2- | tr 'A-Z' 'a-z' | tr -d '[:space:]')
        rm -f "$tmp.hdr"
        case "$ct" in
            *text/html*|*application/json*) rm -f "$tmp"; return 1;;
        esac
        if head -c 300 "$tmp" | grep -qiE '^\s*<!doctype html|^\s*<html'; then
            rm -f "$tmp"; return 1
        fi
        mv -f -- "$tmp" "$SESSION_DIR/js/raw/$name"
        jh=$(sha256sum "$SESSION_DIR/js/raw/$name" 2>/dev/null | awk '{print $1}')
        if [ -n "$jh" ] && [ -s "$SESSION_DIR/state/js-content-hashes.txt" ]; then
            canon=$(awk -F'|' -v h="$jh" '$1==h {print $2; exit}' "$SESSION_DIR/state/js-content-hashes.txt" 2>/dev/null)
            if [ -n "$canon" ] && [ "$canon" != "$name" ]; then
                rm -f "$SESSION_DIR/js/raw/$name"
                ( flock -w 10 200 || exit 1
                  grep -Fqx "$canon|$url" "$SESSION_DIR/state/url-map.txt" 2>/dev/null || printf '%s|%s\n' "$canon" "$url" >> "$SESSION_DIR/state/url-map.txt"
                ) 200>"$SESSION_DIR/state/.urlmap.lock"
                return 0
            fi
        fi
        ( flock -w 10 200 || exit 1
          grep -Fqx "$name|$url" "$SESSION_DIR/state/url-map.txt" 2>/dev/null || printf '%s|%s\n' "$name" "$url" >> "$SESSION_DIR/state/url-map.txt"
        ) 200>"$SESSION_DIR/state/.urlmap.lock"
        record_js_map "$name" "$url" "$kind" "-" 2>/dev/null || true
        if [ -n "$jh" ]; then
            (
                flock -w 10 200 || exit 0
                printf '%s|%s\n' "$jh" "$name" >> "$SESSION_DIR/state/js-content-hashes.txt"
            ) 200>"$SESSION_DIR/state/.urlmap.lock"
        fi
        return 0
    else
        rm -f "$tmp" "$tmp.hdr"
        return 1
    fi
}
js_progress() {
    local st="$1" url="$2" code="${3:--}" n total
    (
        flock -w 5 201 2>/dev/null || exit 0
        printf '%s:%s|%s\n' "$st" "$code" "$url" >> "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null || exit 0
    ) 201>"$SESSION_DIR/state/.jsprog.lock"
}
page_fetch() {
    local page="$1"
    local phash psafe pfile ptmp inline_file inline_content inline_bytes
    PAGE_LAST_CODE="-"
    phash=$(printf '%s' "$page" | md5sum | cut -c1-16)
    psafe=$(echo "$page" | sed -e 's|^https*://||' -e 's/[^A-Za-z0-9.]/_/g' -e 's/__*/_/g')
    psafe="${psafe:0:60}"
    pfile="$SESSION_DIR/js/raw/page_${psafe}-${phash}.html"
    ptmp="${pfile}.part.$$"
    inline_file="$SESSION_DIR/js/raw/page_${psafe}-${phash}.js"

    if [ ! -s "$pfile" ] && [ -s "$SESSION_DIR/state/tmp/.s200-sigs.tsv" ]; then
        _pp="$page"; _ps="${_pp%%://*}"
        _pr="${_pp#*://}"; _ph="${_pr%%/*}"; _ph="${_ph%%\?*}"
        case "$_ph" in
            *:*) : ;;
            *) if [ "$_ps" = "https" ]; then _ph="$_ph:443"; else _ph="$_ph:80"; fi ;;
        esac
        _sig=$(awk -F'\t' -v k="$_ph" '$1==k {print $2; exit}' "$SESSION_DIR/state/tmp/.s200-sigs.tsv" 2>/dev/null)
        case "$_sig" in
            h:*)
                _ssz="${_sig##*:}"
                _jitter
                _hdr=$(curl -s -I -L -m 8 -A "$FAKE_UA" "$page" 2>/dev/null | tr -d '\r')
                _cl=$(printf '%s\n' "$_hdr" | awk 'BEGIN{IGNORECASE=1} /^Content-Length:/{print $2; exit}')
                if [ -n "$_cl" ] && [ "$_cl" = "$_ssz" ]; then
                    PAGE_LAST_CODE="soft404"
                    return 1
                fi
                ;;
        esac
    fi

    [ -s "$pfile" ] || {
        PAGE_LAST_CODE="000"
        _jitter
        PAGE_LAST_CODE=$(curl -s -f -k -L --compressed -m 20 --connect-timeout 6 -A "$FAKE_UA" "$page" -o "$ptmp" -w "%{http_code}" 2>/dev/null)
        [ -n "$PAGE_LAST_CODE" ] || PAGE_LAST_CODE="000"
        if [ "$PAGE_LAST_CODE" != "000" ] && [ -s "$ptmp" ]; then
            mv -f -- "$ptmp" "$pfile"
        else
            rm -f "$ptmp"; return 1
        fi
    }

    if [ -s "$SESSION_DIR/state/tmp/.s200-sigs.tsv" ]; then
        _pp="$page"; _ps="${_pp%%://*}"
        _pr="${_pp#*://}"; _ph="${_pr%%/*}"; _ph="${_ph%%\?*}"
        case "$_ph" in
            *:*) : ;;
            *) if [ "$_ps" = "https" ]; then _ph="$_ph:443"; else _ph="$_ph:80"; fi ;;
        esac
        _sig=$(awk -F'\t' -v k="$_ph" '$1==k {print $2; exit}' "$SESSION_DIR/state/tmp/.s200-sigs.tsv" 2>/dev/null)
        case "$_sig" in
            h:*)
                _phash=$(sha256sum "$pfile" 2>/dev/null | awk '{print substr($1,1,12)}')
                _psz=$(wc -c < "$pfile" 2>/dev/null | tr -d ' ')
                _ssz="${_sig##*:}"
                if [ "$_phash" = "$(printf '%s' "$_sig" | cut -d: -f2)" ] || { [ -n "$_ssz" ] && [ "$_psz" = "$_ssz" ]; }; then
                    rm -f "$pfile"
                    PAGE_LAST_CODE="soft404"
                    return 1
                fi
                ;;
        esac
    fi

    ph=$(sha256sum "$pfile" 2>/dev/null | awk '{print $1}')
    if [ -n "$ph" ] && [ -s "$SESSION_DIR/state/page-hashes.txt" ] && grep -Fqx "$ph" "$SESSION_DIR/state/page-hashes.txt" 2>/dev/null; then
        return 0
    fi
    if [ -n "$ph" ]; then
        (
            flock -w 10 200 || exit 0
            printf '%s\n' "$ph" >> "$SESSION_DIR/state/page-hashes.txt"
        ) 200>"$SESSION_DIR/state/.urlmap.lock"
    fi

    [ -s "$inline_file" ] && return 0
    inline_content=$(perl -0777 -ne 'while (/<script(?![^>]*\bsrc=)[^>]*>(.*?)<\/script>/gis) { print "$1\n" }' "$pfile" 2>/dev/null)
    if [ -n "$inline_content" ]; then
        inline_bytes=$(printf '%s' "$inline_content" | wc -c)
        if [ "$inline_bytes" -ge 20 ]; then
            ih=$(printf '%s' "$inline_content" | sha256sum 2>/dev/null | awk '{print $1}')
            if [ -n "$ih" ] && ! grep -Fqx "$ih" "$SESSION_DIR/state/page-hashes.txt" 2>/dev/null; then
                (
                    flock -w 10 200 || exit 0
                    printf '%s\n' "$ih" >> "$SESSION_DIR/state/page-hashes.txt"
                ) 200>"$SESSION_DIR/state/.urlmap.lock"
                printf '%s' "$inline_content" > "$inline_file"
                ( flock -w 10 200 || exit 1
                  grep -Fqx "page_${psafe}-${phash}.js|$page" "$SESSION_DIR/state/url-map.txt" 2>/dev/null || printf '%s|%s\n' "page_${psafe}-${phash}.js" "$page" >> "$SESSION_DIR/state/url-map.txt"
                ) 200>"$SESSION_DIR/state/.urlmap.lock"
                record_js_map "page_${psafe}-${phash}.js" "$page" "inline" "-" 2>/dev/null || true
            fi
        fi
    fi

    local json_file json_content json_bytes
    json_file="$SESSION_DIR/js/json/page_${psafe}-${phash}.json"
    [ -s "$json_file" ] && return 0
    json_content=$(perl -0777 -ne 'while (/<script[^>]*type=["'"'"']application\/json["'"'"'][^>]*>(.*?)<\/script>/gis) { print "$1\n" }' "$pfile" 2>/dev/null)
    if [ -n "$json_content" ]; then
        json_bytes=$(printf '%s' "$json_content" | wc -c)
        if [ "$json_bytes" -ge 20 ]; then
            printf '%s' "$json_content" > "$json_file"
            ( flock -w 10 200 || exit 1
              grep -Fqx "page_${psafe}-${phash}.json|$page" "$SESSION_DIR/state/url-map.txt" 2>/dev/null || printf '%s|%s\n' "page_${psafe}-${phash}.json" "$page" >> "$SESSION_DIR/state/url-map.txt"
            ) 200>"$SESSION_DIR/state/.urlmap.lock"
        fi
    fi
}
resolve_url() {
    local base="$1" rel="$2" url prev scheme_host base_dir
    case "$rel" in
        http://*|https://*) url="$rel" ;;
        //*) url="https:${rel}" ;;
        /*) scheme_host=$(printf '%s' "$base" | sed -E 's|^(https?://[^/]+).*|\1|')
            url="${scheme_host}${rel}" ;;
        *)  scheme_host=$(printf '%s' "$base" | sed -E 's|^(https?://[^/]+).*|\1|')
            base_dir=$(printf '%s' "$base" | sed -E 's|^https?://[^/]+||; s|/[^/]*$||')
            url="${scheme_host}${base_dir}/${rel}" ;;
    esac
    while :; do
        prev="$url"
        url=$(printf '%s' "$url" | sed -E 's|/[^/]+/\.\./|/|g; s|/\./|/|g')
        [ "$url" = "$prev" ] && break
    done
    printf '%s\n' "$url"
}
recover_one_sourcemap() {
    local line="$1" jsname mapref orig_url map_url mapname
    jsname="${line%%:*}"
    mapref=$(printf '%s' "$line" | sed 's/^[^:]*:[0-9]*://' | sed 's/^sourceMappingURL\s*=\s*//')
    orig_url=$(awk -F'|' -v f="$jsname" '$1==f{print $2; exit}' "$SESSION_DIR/state/url-map.txt" 2>/dev/null)
    [ -z "$orig_url" ] && return 0
    map_url=$(resolve_url "$orig_url" "$mapref")
    mapname="${jsname%.js}-$(printf '%s' "$mapref" | md5sum | cut -c1-6).map"

    [ -s "$SESSION_DIR/js/sourcemaps/$mapname" ] || {
        if curl -s -f -k -L --compressed -m 20 -A "$FAKE_UA" "$map_url" -o "$SESSION_DIR/js/sourcemaps/.${mapname}.part.$$" 2>/dev/null && [ -s "$SESSION_DIR/js/sourcemaps/.${mapname}.part.$$" ]; then
            mv -f "$SESSION_DIR/js/sourcemaps/.${mapname}.part.$$" "$SESSION_DIR/js/sourcemaps/$mapname"
        else
            rm -f "$SESSION_DIR/js/sourcemaps/.${mapname}.part.$$"; return 0
        fi
    }

    command -v jq &>/dev/null || return 0
    jq -e . "$SESSION_DIR/js/sourcemaps/$mapname" >/dev/null 2>&1 || { rm -f "$SESSION_DIR/js/sourcemaps/$mapname"; return 0; }

    local sc_count mapbase mh
    sc_count=$(jq -r '.sourcesContent | length' "$SESSION_DIR/js/sourcemaps/$mapname" 2>/dev/null)
    mapbase=$(basename "$mapname" .map)
    if [ -n "$sc_count" ] && [ "$sc_count" != "null" ] && [ "$sc_count" -gt 0 ] 2>/dev/null; then
        mh=$(md5sum "$SESSION_DIR/js/sourcemaps/$mapname" 2>/dev/null | awk '{print $1}')
        [ -n "$mh" ] && [ -s "$SESSION_DIR/state/map-hashes.txt" ] && grep -Fqx "$mh" "$SESSION_DIR/state/map-hashes.txt" && return 0
        extract_map_sources "$SESSION_DIR/js/sourcemaps/$mapname" "$mapbase" "$orig_url"
        [ -n "$mh" ] && printf '%s\n' "$mh" >> "$SESSION_DIR/state/map-hashes.txt"
        return 0
    fi

    local src_count i rel_src resolved fname
    src_count=$(jq -r '.sources | length' "$SESSION_DIR/js/sourcemaps/$mapname" 2>/dev/null)
    [ -z "$src_count" ] || [ "$src_count" = "null" ] || [ "$src_count" -le 0 ] 2>/dev/null && return 0
    i=0
    while [ "$i" -lt "$src_count" ]; do
        rel_src=$(jq -r --argjson i "$i" '.sources[$i] // empty' "$SESSION_DIR/js/sourcemaps/$mapname" 2>/dev/null)
        i=$((i + 1))
        [ -z "$rel_src" ] && continue
        case "$rel_src" in webpack://*|ng://*|*://*) continue ;; esac
        resolved=$(resolve_url "$map_url" "$rel_src")
        case "$rel_src" in *.ts|*.tsx|*.jsx|*.mjs|*.cjs) _ext="${rel_src##*.}" ;; *) _ext="js" ;; esac
        fname="mapsrc_${mapbase}_$(printf '%s' "$rel_src" | md5sum | cut -c1-8).${_ext}"
        [ -s "$SESSION_DIR/js/mapsrc/$fname" ] && continue
        if curl -s -f -k -L --compressed -m 20 -A "$FAKE_UA" "$resolved" -o "$SESSION_DIR/js/mapsrc/.${fname}.part.$$" 2>/dev/null && [ -s "$SESSION_DIR/js/mapsrc/.${fname}.part.$$" ]; then
            mv -f "$SESSION_DIR/js/mapsrc/.${fname}.part.$$" "$SESSION_DIR/js/mapsrc/$fname"
            ( flock -w 10 200 || exit 1
              grep -Fqx "$fname|$resolved|map source" "$SESSION_DIR/state/url-map.txt" 2>/dev/null || printf '%s|%s|%s\n' "$fname" "$resolved" "map source" >> "$SESSION_DIR/state/url-map.txt"
            ) 200>"$SESSION_DIR/state/.urlmap.lock"
        else
            rm -f "$SESSION_DIR/js/mapsrc/.${fname}.part.$$"
        fi
    done
}
extract_map_sources() {
    local mapfile="$1" mapbase="$2" orig="$3"
    [ -f "$mapfile" ] || return 1
    jq -e . "$mapfile" >/dev/null 2>&1 || return 1
    local srcname ext
    jq -j '.sources as $s | .sourcesContent | to_entries[] | select(.value != null and .value != "") | "\(.key)\u0000\($s[.key] // "x.js")\u0000\(.value)\u0000"' "$mapfile" 2>/dev/null \
    | while IFS= read -r -d '' idx && IFS= read -r -d '' srcpath && IFS= read -r -d '' content; do
        case "$srcpath" in
            *.ts|*.tsx|*.jsx|*.mjs|*.cjs) ext="${srcpath##*.}" ;;
            *) ext="js" ;;
        esac
        srcname="mapsrc_${mapbase}_${idx}.${ext}"
        printf '%s' "$content" > "$SESSION_DIR/js/mapsrc/$srcname"
        [ -s "$SESSION_DIR/js/mapsrc/$srcname" ] || continue
        ( flock -w 10 200 || exit 1
          grep -Fqx "$srcname|$orig|map source" "$SESSION_DIR/state/url-map.txt" 2>/dev/null || printf '%s|%s|%s\n' "$srcname" "$orig" "map source" >> "$SESSION_DIR/state/url-map.txt"
        ) 200>"$SESSION_DIR/state/.urlmap.lock"
    done
}

export C_R C_K C_RED C_GRN C_Y C_BLU C_MAG C_CYN C_W
export -f out _mpgrep
export -f _jitter http_head url_junk_filter js_name_for_url record_js_map js_fetch js_progress page_fetch resolve_url recover_one_sourcemap extract_map_sources

adapt_threads() {
    local _log="$SESSION_DIR/state/tmp/.js-progress.log"
    [ -s "$_log" ] || return 0
    local _tot _429n _errn
    _tot=$(wc -l < "$_log" 2>/dev/null | tr -d ' '); _tot=${_tot:-0}
    _429n=$(awk -F'[:|]' '$1=="FAIL" && $2=="429"{c++} END{print c+0}' "$_log" 2>/dev/null); _429n=${_429n:-0}
    _errn=$(awk -F'[:|]' '$1=="FAIL" && ($2=="502" || $2=="503" || $2=="000"){c++} END{print c+0}' "$_log" 2>/dev/null); _errn=${_errn:-0}
    if [ "$_tot" -gt 0 ] && [ "$((_429n * 10))" -gt "$_tot" ]; then
        RECONLY_FETCH_THREADS=$(( RECONLY_FETCH_THREADS / 2 ))
        [ "$RECONLY_FETCH_THREADS" -lt 5 ] && RECONLY_FETCH_THREADS=5
        export RECONLY_FETCH_THREADS
        KATANA_RL=$(( KATANA_RL / 2 ))
        [ "$KATANA_RL" -lt 10 ] && KATANA_RL=10
        out "${C_Y}[stealth] 429s = $((_429n * 100 / _tot))% of the wave -- rate down to $KATANA_RL/s${C_R}"
    elif [ "$_tot" -ge 40 ] && [ "$((_errn * 5))" -gt "$_tot" ]; then
        RECONLY_FETCH_THREADS=$(( RECONLY_FETCH_THREADS * 2 / 3 ))
        [ "$RECONLY_FETCH_THREADS" -lt 5 ] && RECONLY_FETCH_THREADS=5
        export RECONLY_FETCH_THREADS
        KATANA_RL=$(( KATANA_RL * 2 / 3 ))
        [ "$KATANA_RL" -lt 10 ] && KATANA_RL=10
        out "${C_Y}[stealth] server stress ($_errn x 502/000 = $((_errn * 100 / _tot))%) -- rate down to $KATANA_RL/s${C_R}"
    fi
    return 0
}

_blind_map_probe() {
    {
        [ -s "$SESSION_DIR/state/tmp/.js-round-fetched.txt" ] && cat "$SESSION_DIR/state/tmp/.js-round-fetched.txt"
        [ -s "$SESSION_DIR/urls/urls-js.txt" ] && cat "$SESSION_DIR/urls/urls-js.txt"
    } | sort -u | tr -d '\r' | awk 'NF' > "$SESSION_DIR/state/tmp/.blind-all.txt"
    comm -23 "$SESSION_DIR/state/tmp/.blind-all.txt" <(sort -u "$SESSION_DIR/state/blind-probed.txt" 2>/dev/null) > "$SESSION_DIR/state/tmp/.blind-targets.txt"
    rm -f "$SESSION_DIR/state/tmp/.blind-all.txt"
    local targets
    targets=$(wc -l < "$SESSION_DIR/state/tmp/.blind-targets.txt" | tr -d ' ')
    [ "$targets" -eq 0 ] && { rm -f "$SESSION_DIR/state/tmp/.blind-targets.txt"; return; }

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} -s -o /dev/null -w %{http_code} -m 10 {base}.map + {base}.js.map   (blind probe, 50/chunk, $targets URLs)"
    split -l 50 "$SESSION_DIR/state/tmp/.blind-targets.txt" "$SESSION_DIR/state/tmp/.blind-chunk-"
    for chunk in "$SESSION_DIR/state/tmp/.blind-chunk-"*; do
        [ -e "$chunk" ] || continue
        cat "$chunk" | xargs -d '\n' -P "$RECONLY_JS_THREADS" -I {} bash -c '
            js="$1"; base="${js%%\?*}"; case "$base" in *.js) ;; *) exit 0 ;; esac
            for m in "${base}.map" "$(printf "%s" "$base" | sed "s/\.js$/.js.map/")"; do
                [ "$m" = "$base" ] && continue
                code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" "$m" 2>/dev/null)
                [ "$code" = "200" ] && { printf "%s\n" "$m" >> "'"$SESSION_DIR/state/tmp/.blind-found.txt"'"; break; }
            done
        ' _ {}
        rm -f "$chunk"
    done
    [ -s "$SESSION_DIR/state/tmp/.blind-found.txt" ] && cat "$SESSION_DIR/state/tmp/.blind-found.txt" | sort -u > "$SESSION_DIR/state/blind-maps-found.txt"
    cat "$SESSION_DIR/state/tmp/.blind-targets.txt" > "$SESSION_DIR/state/blind-probed.txt"
    sort -u "$SESSION_DIR/state/blind-probed.txt" -o "$SESSION_DIR/state/blind-probed.txt"
    sort -u "$SESSION_DIR/state/blind-maps-found.txt" -o "$SESSION_DIR/state/blind-maps-found.txt"
    rm -f "$SESSION_DIR/state/tmp/.blind-targets.txt" "$SESSION_DIR/state/tmp/.blind-found.txt"

    if [ -s "$SESSION_DIR/state/blind-maps-found.txt" ]; then
        out "${C_W}Downloading blind maps${C_R}"
        cat "$SESSION_DIR/state/blind-maps-found.txt" | xargs -d '\n' -P "$RECONLY_JS_THREADS" -I {} bash -c '
            m="$1"; mapname="blind_$(printf "%s" "$m" | md5sum | cut -c1-8).map"
            [ -s "'"$SESSION_DIR/js/sourcemaps"'/$mapname" ] && exit 0
            grep -Fqx "$mapname" '"$SESSION_DIR/state/blind-failed.txt"' 2>/dev/null && exit 0
            tmp="'"$SESSION_DIR/js/sourcemaps"'/.${mapname}.part.$$"
            if curl -s -m 30 -A "$FAKE_UA" "$m" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
                mv -f "$tmp" "'"$SESSION_DIR/js/sourcemaps"'/$mapname"
            else
                rm -f "$tmp"; printf "%s\n" "$mapname" >> '"$SESSION_DIR/state/blind-failed.txt"'
            fi
        ' _ {}
    fi

    if [ -s "$SESSION_DIR/state/blind-maps-found.txt" ]; then
        local extracted=0 skipped=0
        while read -r m; do
            local mapname mh mapbase
            mapname="blind_$(printf '%s' "$m" | md5sum | cut -c1-8).map"
            grep -Fqx "$mapname" "$SESSION_DIR/state/maps-extracted.txt" 2>/dev/null && continue
            [ -s "$SESSION_DIR/js/sourcemaps/$mapname" ] || { printf '%s\n' "$mapname" >> "$SESSION_DIR/state/maps-extracted.txt"; continue; }
            mh=$(md5sum "$SESSION_DIR/js/sourcemaps/$mapname" 2>/dev/null | awk '{print $1}')
            if [ -n "$mh" ] && [ -s "$SESSION_DIR/state/map-hashes.txt" ] && grep -Fqx "$mh" "$SESSION_DIR/state/map-hashes.txt"; then
                skipped=$((skipped+1))
            else
                mapbase=$(basename "$mapname" .map)
                if extract_map_sources "$SESSION_DIR/js/sourcemaps/$mapname" "$mapbase" "$m"; then
                    [ -n "$mh" ] && printf '%s\n' "$mh" >> "$SESSION_DIR/state/map-hashes.txt"
                else
                    rm -f "$SESSION_DIR/js/sourcemaps/$mapname"
                fi
            fi
            printf '%s\n' "$mapname" >> "$SESSION_DIR/state/maps-extracted.txt"
            extracted=$((extracted+1))
        done < "$SESSION_DIR/state/blind-maps-found.txt"
    fi
}
json_fetch() {
    local url="$1"
    local name tmp ct
    JSON_LAST_CODE="-"
    name=$(js_name_for_url "$url"); name="${name%.js}.json"
    tmp="$SESSION_DIR/js/json/.${name}.part.$$"
    if [ -f "$SESSION_DIR/js/json/$name" ]; then
        JSON_LAST_CODE="cached"
        ( flock -w 10 200 || exit 1
          grep -Fqx "$name|$url" "$SESSION_DIR/state/url-map.txt" 2>/dev/null || printf '%s|%s\n' "$name" "$url" >> "$SESSION_DIR/state/url-map.txt"
        ) 200>"$SESSION_DIR/state/.urlmap.lock"
        return 0
    fi
    rm -f "$tmp" "$tmp.hdr"
    JSON_LAST_CODE="000"
    _jitter
    JSON_LAST_CODE=$(curl -s -f -k -L --compressed -m 20 --connect-timeout 6 --max-filesize 52428800 -A "$FAKE_UA" -D "$tmp.hdr" "$url" -o "$tmp" -w "%{http_code}" 2>/dev/null)
    [ -n "$JSON_LAST_CODE" ] || JSON_LAST_CODE="000"
    if [ "$JSON_LAST_CODE" = "200" ] && [ -s "$tmp" ]; then
        ct=$(grep -i '^content-type:' "$tmp.hdr" 2>/dev/null | tail -1 | tr 'A-Z' 'a-z' | tr -d '\r')
        rm -f "$tmp.hdr"
        case "$ct" in
            *text/html*) rm -f "$tmp"; return 1;;
        esac
        if head -c 300 "$tmp" | grep -qiE '^\s*<!doctype html|^\s*<html'; then
            rm -f "$tmp"; return 1
        fi
        if ! head -c 1 "$tmp" | grep -qE '\{|\['; then
            rm -f "$tmp"; return 1
        fi
        if command -v jq &>/dev/null; then
            jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
        fi
        mv -f -- "$tmp" "$SESSION_DIR/js/json/$name"
        ( flock -w 10 200 || exit 1
          grep -Fqx "$name|$url" "$SESSION_DIR/state/url-map.txt" 2>/dev/null || printf '%s|%s\n' "$name" "$url" >> "$SESSION_DIR/state/url-map.txt"
        ) 200>"$SESSION_DIR/state/.urlmap.lock"
        return 0
    else
        rm -f "$tmp" "$tmp.hdr"
        return 1
    fi
}
export -f json_fetch

artifact_fetch() {
    local url="$1"
    local name tmp
    ART_LAST_CODE="-"
    name=$(js_name_for_url "$url")
    tmp="$SESSION_DIR/js/artifacts/.${name}.part.$$"
    if [ -s "$SESSION_DIR/js/artifacts/$name" ]; then ART_LAST_CODE="cached"; return 0; fi
    rm -f "$tmp"
    ART_LAST_CODE="000"
    _jitter
    ART_LAST_CODE=$(curl -s -f -k -L --compressed -m 20 --connect-timeout 6 --max-filesize 52428800 -A "$FAKE_UA" "$url" -o "$tmp" -w "%{http_code}" 2>/dev/null)
    [ -n "$ART_LAST_CODE" ] || ART_LAST_CODE="000"
    if [ "$ART_LAST_CODE" = "200" ] && [ -s "$tmp" ]; then
        if head -c 300 "$tmp" | grep -qiE '^\s*<!doctype html|^\s*<html'; then
            rm -f "$tmp"; return 1
        fi
        mv -f -- "$tmp" "$SESSION_DIR/js/artifacts/$name"
        return 0
    else
        rm -f "$tmp"
        return 1
    fi
}
export -f artifact_fetch

_store_norm() {
    if [ "$(od -An -tx1 -N2 "$1" 2>/dev/null | tr -d '[:space:]')" = "1f8b" ]; then
        gzip -dc "$1" > "$2" 2>/dev/null || cp -- "$1" "$2"
    else
        cp -- "$1" "$2"
    fi
}

_httpx_wave() {
    local _list="$1" _kind="$2"
    local _jd="$SESSION_DIR/state/tmp/httpx-$_kind"
    local _threads=12
    [ "$_kind" = "art" ] && _threads=8
    rm -rf "$_jd"; mkdir -p "$_jd"
    nice -n 10 httpx -silent -l "$_list" -sr -srd "$_jd" -json -no-color \
        -H "User-Agent: $FAKE_UA" -timeout 15 -rl "$KATANA_RL" -t "$_threads" 2>/dev/null \
      | jq -r 'if type == "array" then .[] else . end | [.url, (.path // ""), (.status_code | tostring)] | @tsv' > "$_jd.tsv" 2>/dev/null
    : > "$_jd.ok"
    while IFS=$'\t' read -r _ru _rp _rc; do
        [ -n "$_ru" ] || continue
        case "$_rc" in
            2*) : ;;
            *) printf 'FAIL:%s|%s\n' "${_rc:-000}" "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"
               case "$_rc" in 429|502|503|504|000) [ "$_kind" = "js" ] && printf '%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-failed.txt" ;; esac
               continue ;;
        esac
        [ -f "$_rp" ] || _rp="$_jd/$(printf '%s' "$_ru" | md5sum | awk '{print $1}').txt"
        if [ ! -f "$_rp" ]; then printf 'FAIL:000|%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"; [ "$_kind" = "js" ] && printf '%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-failed.txt"; continue; fi
        _rsz=$(wc -c < "$_rp" 2>/dev/null | tr -d ' '); _rsz=${_rsz:-0}
        if [ "$_rsz" -le 0 ] || [ "$_rsz" -gt 52428800 ]; then
            if [ "$_kind" = "js" ] && [ "$_rsz" -gt 52428800 ]; then
                _jitter
                curl -s --compressed -r 0-1048575 -m 30 -A "$FAKE_UA" "$_ru" -o "$_rp.part" 2>/dev/null
                if [ -s "$_rp.part" ] && ! head -c 300 "$_rp.part" 2>/dev/null | grep -qiE '^\s*<!doctype html|^\s*<html'; then
                    mv -f "$_rp.part" "$_rp"
                    _rsz=$(wc -c < "$_rp" 2>/dev/null | tr -d ' '); _rsz=${_rsz:-0}
                else
                    rm -f "$_rp.part"
                fi
            fi
            if [ "$_rsz" -le 0 ] || [ "$_rsz" -gt 52428800 ]; then
                rm -f "$_rp"
                printf 'FAIL:000|%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"
                [ "$_kind" = "js" ] && printf '%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-failed.txt"
                continue
            fi
        fi
        _rn=$(js_name_for_url "$_ru")
        _dest=""
        case "$_kind" in
            js)   _dest="$SESSION_DIR/js/raw/$_rn" ;;
            json) _rn="${_rn%.js}.json"; _dest="$SESSION_DIR/js/json/$_rn" ;;
            art)  _dest="$SESSION_DIR/js/artifacts/$_rn" ;;
            pages) _ph16=$(printf '%s' "$_ru" | md5sum | cut -c1-16)
                   _ps2=$(printf '%s' "$_ru" | sed -e 's|^https*://||' -e 's/[^A-Za-z0-9.]/_/g' -e 's/__*/_/g')
                   _ps2="${_ps2:0:60}"
                   _rn="page_${_ps2}-${_ph16}.html"
                   _dest="$SESSION_DIR/js/raw/$_rn" ;;
        esac
        _stg="$_jd/.${_rn}.stg.$$"
        _store_norm "$_rp" "$_stg"
        rm -f "$_rp"
        case "$_kind" in
            js)
                if head -c 300 "$_stg" 2>/dev/null | grep -qiE '^\s*<!doctype html|^\s*<html'; then rm -f "$_stg"; printf 'FAIL:200|%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"; continue; fi
                _rjh=$(sha256sum "$_stg" 2>/dev/null | awk '{print $1}')
                if [ -n "$_rjh" ] && [ -s "$SESSION_DIR/state/js-content-hashes.txt" ]; then
                    _rcan=$(awk -F'|' -v h="$_rjh" '$1==h {print $2; exit}' "$SESSION_DIR/state/js-content-hashes.txt" 2>/dev/null)
                    if [ -n "$_rcan" ] && [ "$_rcan" != "$_rn" ]; then
                        ( flock -w 10 200 || exit 1
                          grep -Fqx "$_rcan|$_ru" "$SESSION_DIR/state/url-map.txt" 2>/dev/null || printf '%s|%s\n' "$_rcan" "$_ru" >> "$SESSION_DIR/state/url-map.txt"
                        ) 200>"$SESSION_DIR/state/.urlmap.lock"
                        rm -f "$_stg"
                        printf 'OK:200|%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"
                        printf '%s\n' "$_ru" >> "$_jd.ok"
                        continue
                    fi
                fi
                ;;
            json)
                if head -c 300 "$_stg" 2>/dev/null | grep -qiE '^\s*<!doctype html|^\s*<html'; then rm -f "$_stg"; printf 'FAIL:200|%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"; continue; fi
                if ! head -c 1 "$_stg" | grep -qE '\{|\['; then rm -f "$_stg"; printf 'FAIL:200|%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"; continue; fi
                if command -v jq &>/dev/null; then jq -e . "$_stg" >/dev/null 2>&1 || { rm -f "$_stg"; printf 'FAIL:200|%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"; continue; }; fi
                ;;
            art)
                if head -c 300 "$_stg" 2>/dev/null | grep -qiE '^\s*<!doctype html|^\s*<html'; then rm -f "$_stg"; printf 'FAIL:200|%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"; continue; fi
                ;;
            pages)
                if [ -s "$SESSION_DIR/state/tmp/.s200-sigs.tsv" ]; then
                    _pp="$_ru"; _ps="${_pp%%://*}"
                    _pr2="${_pp#*://}"; _ph="${_pr2%%/*}"; _ph="${_ph%%\?*}"
                    case "$_ph" in
                        *:*) : ;;
                        *) if [ "$_ps" = "https" ]; then _ph="$_ph:443"; else _ph="$_ph:80"; fi ;;
                    esac
                    _sig2=$(awk -F'\t' -v k="$_ph" '$1==k {print $2; exit}' "$SESSION_DIR/state/tmp/.s200-sigs.tsv" 2>/dev/null)
                    case "$_sig2" in
                        h:*)
                            _ssz2="${_sig2##*:}"
                            _ph2=$(sha256sum "$_stg" 2>/dev/null | awk '{print substr($1,1,12)}')
                            _psz=$(wc -c < "$_stg" 2>/dev/null | tr -d ' ')
                            if [ "$_ph2" = "$(printf '%s' "$_sig2" | cut -d: -f2)" ] || { [ -n "$_ssz2" ] && [ "$_psz" = "$_ssz2" ]; }; then
                                rm -f "$_stg"; printf 'FAIL:200|%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"; continue
                            fi
                            ;;
                    esac
                fi
                ;;
        esac
        mv -f -- "$_stg" "$_dest" 2>/dev/null
        if [ -s "$_dest" ]; then
            case "$_kind" in
                js)   [ -n "$_rjh" ] && ( flock -w 10 200 || exit 0
                          printf '%s|%s\n' "$_rjh" "$_rn" >> "$SESSION_DIR/state/js-content-hashes.txt"
                      ) 200>"$SESSION_DIR/state/.urlmap.lock"
                      js_fetch "$_ru" >/dev/null 2>&1 ;;
                json) json_fetch "$_ru" >/dev/null 2>&1 ;;
                pages) page_fetch "$_ru" >/dev/null 2>&1 ;;
            esac
            printf 'OK:200|%s\n' "$_ru" >> "$SESSION_DIR/state/tmp/.js-progress.log"
            printf '%s\n' "$_ru" >> "$_jd.ok"
        fi
    done < "$_jd.tsv"
    rm -rf "$_jd" "$_jd.tsv"
}

st_subdomains() {
    local out="$SESSION_DIR/subdomains/raw"
    mkdir -p "$out"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ subfinder${C_R} -d '$DOMAIN' -all -recursive -rl 50 -t 100 -silent | sort -u > subdomains/raw/subfinder.txt"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ amass${C_R} enum -d '$DOMAIN' -timeout 5 && amass subs -names -d '$DOMAIN' > subdomains/raw/amass.txt   (v5: OAM database flow)"
    timeout --foreground 900 subfinder -d "$DOMAIN" -all -recursive -rl 50 -t 100 -silent 2>"$SESSION_DIR/state/tmp/subfinder.err" | sort -u > "$out/subfinder.txt" || true &
    local _spid=$!
    if ! pgrep -f "amass engine" >/dev/null 2>&1; then
        (amass engine >/dev/null 2>&1 &)
        sleep 3
    fi
    timeout --foreground 600 amass enum -d "$DOMAIN" -timeout 5 -oA "$SESSION_DIR/state/tmp/amass_out" >/dev/null 2>"$SESSION_DIR/state/tmp/amass.err" || true &
    local _apid=$!
    wait "$_spid" "$_apid" 2>/dev/null || true
    amass subs -names -d "$DOMAIN" 2>/dev/null | sed 's/^\*\.//' | grep -E "(^|\.)${DOMAIN_ESCAPED}$" | sort -u > "$out/amass.txt"
    if [ ! -s "$out/amass.txt" ] && [ -f "$SESSION_DIR/state/tmp/amass_out.txt" ]; then
        sed 's/^\*\.//' "$SESSION_DIR/state/tmp/amass_out.txt" | grep -E "(^|\.)${DOMAIN_ESCAPED}$" | sort -u > "$out/amass.txt"
    fi
    rm -f "$SESSION_DIR/state/tmp/amass_out".*
    rm -f "$SESSION_DIR/state/tmp/amass.err" "$SESSION_DIR/state/tmp/subfinder.err"
    {
        [ -f "$out/subfinder.txt" ] && cat "$out/subfinder.txt"
        [ -f "$out/amass.txt" ] && cat "$out/amass.txt"
    } | grep -viE '(transferprohibited|updateprohibited|deleteprohibited|renewprohibited|pending|redemptionperiod|clienthold|serverhold)' | sort -u > "$SESSION_DIR/subdomains/subdomains-final.txt"

    local _subcount
    _subcount=$(wc -l < "$SESSION_DIR/subdomains/subdomains-final.txt" | tr -d ' ')
    if [ "${_subcount:-0}" -gt 5000 ]; then
        out "${C_Y}subs >5000, skipping permutations (smart mode targets small scopes)${C_R}"
    elif [ "${_subcount:-0}" -gt 0 ]; then
        out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ permutations${C_R} env-wordlist x $_subcount labels | dnsx resolve -a -t 2000 + resolvers   (smart mode, seconds)"
        PERM_WORDS="dev staging test uat demo admin panel api v2 old new backup internal qa pre prod mobile web"
        : > "$SESSION_DIR/state/tmp/.perms.txt"
        while IFS= read -r _sub; do
            [ -z "$_sub" ] && continue
            _lbl="${_sub%.$DOMAIN}"
            [ "$_lbl" = "$_sub" ] && continue
            for _w in $PERM_WORDS; do
                printf '%s-%s.%s\n' "$_w" "$_lbl" "$DOMAIN"
                printf '%s-%s.%s\n' "$_lbl" "$_w" "$DOMAIN"
            done
            printf '%s2.%s\n' "$_lbl" "$DOMAIN"
        done < "$SESSION_DIR/subdomains/subdomains-final.txt" >> "$SESSION_DIR/state/tmp/.perms.txt"
        for _w in $PERM_WORDS; do printf '%s.%s\n' "$_w" "$DOMAIN"; done >> "$SESSION_DIR/state/tmp/.perms.txt"
        sort -u "$SESSION_DIR/state/tmp/.perms.txt" -o "$SESSION_DIR/state/tmp/.perms.txt"
        comm -23 "$SESSION_DIR/state/tmp/.perms.txt" <(sort -u "$SESSION_DIR/subdomains/subdomains-final.txt") > "$SESSION_DIR/state/tmp/.perms-new.txt"
        if [ -s "$SESSION_DIR/state/tmp/.perms-new.txt" ]; then
            dnsx -silent -l "$SESSION_DIR/state/tmp/.perms-new.txt" -a -resp -retry 1 -timeout 3 -t 2000 -r "${RESOLVERS_FILE:-1.1.1.1,8.8.8.8,9.9.9.9}" -wd "$DOMAIN" 2>/dev/null | awk '{gsub(/\.$/,"",$1); print $1}' | grep -E "(^|\.)${DOMAIN_ESCAPED}$" | sort -u > "$SESSION_DIR/subdomains/subdomains-permutations.txt" || true
            if [ -s "$SESSION_DIR/subdomains/subdomains-permutations.txt" ]; then
                cat "$SESSION_DIR/subdomains/subdomains-final.txt" "$SESSION_DIR/subdomains/subdomains-permutations.txt" | sort -u > "$SESSION_DIR/state/tmp/.final2.txt" && mv "$SESSION_DIR/state/tmp/.final2.txt" "$SESSION_DIR/subdomains/subdomains-final.txt"
            fi
        fi
        rm -f "$SESSION_DIR/state/tmp/.perms.txt" "$SESSION_DIR/state/tmp/.perms-new.txt"
    fi

    out ""

    return 0
}
st_hosts_lite() {
    mkdir -p "$SESSION_DIR/hosts" 2>/dev/null || true
    [ -s "$SESSION_DIR/subdomains/subdomains-final.txt" ] || { out "${C_Y}No subs, skipping hosts${C_R}"; return; }
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ naabu${C_R} -l subdomains-final.txt -port \$NAABU_PORTS -rate 1000 -c 50 -silent -no-color   (no-sudo connect scan -> hosts/open-ports.txt for manual nmap)"
    timeout --foreground 600 naabu -silent -no-color -l "$SESSION_DIR/subdomains/subdomains-final.txt" -port "$NAABU_PORTS" -rate 1000 -c 50 -o "$SESSION_DIR/hosts/open-ports.txt" >/dev/null 2>"$SESSION_DIR/state/tmp/naabu.err" || true
    rm -f "$SESSION_DIR/state/tmp/naabu.err"
    [ -s "$SESSION_DIR/hosts/open-ports.txt" ] || { out "${C_Y}No open ports, skipping httpx${C_R}"; return; }
    out "${C_Y}  [INFO] nmap follow-up: nmap -sV -sC -p \$(grep $DOMAIN hosts/open-ports.txt | cut -d: -f2 | sort -un | paste -sd,) $DOMAIN${C_R}"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -l hosts/open-ports.txt -threads 200 -timeout 8 -status-code -tech-detect -title -location -ip -cname -tls-grab -websocket -favicon   (metadata on open ports only)"
    timeout --foreground 900 httpx -silent -no-color -l "$SESSION_DIR/hosts/open-ports.txt" -threads 200 -timeout 8 -status-code -tech-detect -title -location -ip -cname -tls-grab -websocket -favicon 2>/dev/null | awk '!seen[$0]++' > "$SESSION_DIR/hosts/httpx-raw.txt" || true
    grep -E '^https?://' "$SESSION_DIR/hosts/httpx-raw.txt" | awk '{print $1}' | sort -u | awk '{rest=substr($0, index($0,"//")+2); if(!(rest in out) || $0 ~ /^https:/){out[rest]=$0}} END{for(k in out) print out[k]}' | sort > "$SESSION_DIR/hosts/hosts-live.txt"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -u '$DOMAIN' -status-code -tech-detect -title -location -ip -cname   (apex spot-check)"
    if ! grep -qE "^https?://${DOMAIN_ESCAPED}$" "$SESSION_DIR/hosts/hosts-live.txt" 2>/dev/null; then
        timeout --foreground 300 httpx -silent -no-color -u "$DOMAIN" -status-code -tech-detect -title -location -ip -cname 2>/dev/null > "$SESSION_DIR/state/tmp/.apex.txt" || true
        grep -E '^https?://' "$SESSION_DIR/state/tmp/.apex.txt" 2>/dev/null | awk '{print $1}' >> "$SESSION_DIR/hosts/hosts-live.txt"
        sort -u "$SESSION_DIR/hosts/hosts-live.txt" -o "$SESSION_DIR/hosts/hosts-live.txt"
        rm -f "$SESSION_DIR/state/tmp/.apex.txt"
    fi
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ openssl${C_R} s_client -connect <host>:443 -servername <host> | openssl x509 -noout -text   (TLS SAN mining, all live hosts)"
    cat "$SESSION_DIR/hosts/hosts-live.txt" | xargs -d '\n' -P 10 -I {} bash -c '
        turl="$1"
        thost=$(printf "%s" "$turl" | sed -E "s|^https?://([^:/]+).*|\1|")
        tport=$(printf "%s" "$turl" | sed -nE "s|^https?://[^:/]+:([0-9]+).*|\1|p")
        [ -n "$tport" ] || tport=443
        [ -n "$thost" ] || exit 0
        timeout --foreground 10 openssl s_client -connect "${thost}:${tport}" -servername "$thost" </dev/null 2>/dev/null \
          | openssl x509 -noout -text 2>/dev/null \
          | grep -A1 "Subject Alternative Name" | grep -oE "DNS:[a-zA-Z0-9._*-]+" | cut -d: -f2 | sed 's/^\*\.//' >> "$SESSION_DIR/state/tmp/.tls-sans.txt" 2>/dev/null
    ' _ {}
    if [ -s "$SESSION_DIR/state/tmp/.tls-sans.txt" ]; then
        grep -E "(^|\.)${DOMAIN_ESCAPED}$" "$SESSION_DIR/state/tmp/.tls-sans.txt" | sort -u > "$SESSION_DIR/state/tmp/.san-scoped.txt" 2>/dev/null
        comm -23 "$SESSION_DIR/state/tmp/.san-scoped.txt" <(sort -u "$SESSION_DIR/subdomains/subdomains-final.txt") > "$SESSION_DIR/state/tmp/.san-new.txt" 2>/dev/null
        local new_san
        new_san=$(wc -l < "$SESSION_DIR/state/tmp/.san-new.txt" 2>/dev/null | tr -d ' '); new_san=${new_san:-0}
        [ "$new_san" -gt 0 ] && out "${C_Y}$new_san new hostnames from TLS SANs${C_R}"
        if [ "$new_san" -gt 0 ]; then
            cat "$SESSION_DIR/subdomains/subdomains-final.txt" "$SESSION_DIR/state/tmp/.san-new.txt" 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.san-final.txt" && mv "$SESSION_DIR/state/tmp/.san-final.txt" "$SESSION_DIR/subdomains/subdomains-final.txt"
            timeout --foreground 300 naabu -silent -no-color -l "$SESSION_DIR/state/tmp/.san-new.txt" -port "$NAABU_PORTS" -rate 500 -c 25 -o "$SESSION_DIR/state/tmp/.san-open.txt" 2>/dev/null || true
            [ -s "$SESSION_DIR/state/tmp/.san-open.txt" ] && timeout --foreground 600 httpx -silent -no-color -l "$SESSION_DIR/state/tmp/.san-open.txt" -threads 100 -timeout 8 -status-code -cname 2>/dev/null | tee -a "$SESSION_DIR/hosts/httpx-raw.txt" | awk '{print $1}' >> "$SESSION_DIR/hosts/hosts-live.txt"
            sort -u "$SESSION_DIR/hosts/hosts-live.txt" -o "$SESSION_DIR/hosts/hosts-live.txt"
        fi
        rm -f "$SESSION_DIR/state/tmp/.san-scoped.txt" "$SESSION_DIR/state/tmp/.san-new.txt" "$SESSION_DIR/state/tmp/.san-open.txt"
    fi
    rm -f "$SESSION_DIR/state/tmp/.tls-sans.txt"
}
st_archive() {
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ waymore${C_R} -i '$DOMAIN' -mode U -oU urls/archive-waymore.txt  (1 try x300s, CDX fallback if weak)"
    timeout --foreground 300 waymore -i "$DOMAIN" -mode U -oU "$SESSION_DIR/urls/archive-waymore.txt" >"$SESSION_DIR/state/tmp/waymore.out" 2>"$SESSION_DIR/state/tmp/waymore.err" || true
    if [ ! -s "$SESSION_DIR/urls/archive-waymore.txt" ] || [ "$(wc -l < "$SESSION_DIR/urls/archive-waymore.txt" | tr -d ' ')" -lt 10 ]; then
        sleep 5
        out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} web.archive.org/cdx/search/cdx?url='$DOMAIN'&matchType=domain&fl=original&collapse=urlkey"
        curl -s -m 180 "https://web.archive.org/cdx/search/cdx?url=${DOMAIN}&matchType=domain&fl=original&collapse=urlkey&limit=100000" 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > "$SESSION_DIR/urls/archive-cdx.txt" || true
        [ -s "$SESSION_DIR/urls/archive-cdx.txt" ] && out "  wayback CDX fallback: $(wc -l < "$SESSION_DIR/urls/archive-cdx.txt" | tr -d ' ') urls"
    fi
    rm -f "$SESSION_DIR/state/tmp/waymore.err" "$SESSION_DIR/state/tmp/waymore.out"

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ gau${C_R} --subs --threads 20 '$DOMAIN' | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > urls/archive-gau.txt || true"
    timeout --foreground 300 gau --subs --threads 20 "$DOMAIN" 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > "$SESSION_DIR/urls/archive-gau.txt" || true

    {
        [ -f "$SESSION_DIR/urls/archive-waymore.txt" ] && cat "$SESSION_DIR/urls/archive-waymore.txt"
        [ -f "$SESSION_DIR/urls/archive-cdx.txt" ] && cat "$SESSION_DIR/urls/archive-cdx.txt"
        [ -f "$SESSION_DIR/urls/archive-gau.txt" ] && cat "$SESSION_DIR/urls/archive-gau.txt"
    } | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > "$SESSION_DIR/urls/urls-archive.txt"
}
st_crawl() {
    [ -s "$SESSION_DIR/hosts/hosts-live.txt" ] || { out "${C_Y}No live hosts, skipping crawl${C_R}"; return; }
    local katana_ef="css,png,jpg,jpeg,gif,svg,ico,webp,avif,bmp,tiff,woff,woff2,ttf,otf,eot,pdf,zip,tar,tgz,gz,bz2,xz,7z,rar,mp3,wav,ogg,m4a,mp4,webm,avi,mov,mkv"

    : > "$SESSION_DIR/urls/hosts-katana.txt"
    : > "$SESSION_DIR/findings/probes/soft-200-hosts.txt"
    while IFS= read -r _kh; do
        [ -n "$_kh" ] || continue
        _kp1="/reconly-probe-$RANDOM$RANDOM"; _kp2="/reconly-probe-$RANDOM$RANDOM"
        _kt1="$SESSION_DIR/state/tmp/.s200p-$$-1"; _kt2="$SESSION_DIR/state/tmp/.s200p-$$-2"
        _jitter
        _kc1=$(curl -s --compressed -o "$_kt1" -w "%{http_code}" -m 8 -A "$FAKE_UA" "${_kh}${_kp1}" 2>/dev/null)
        _jitter
        _kc2=$(curl -s --compressed -o "$_kt2" -w "%{http_code}" -m 8 -A "$FAKE_UA" "${_kh}${_kp2}" 2>/dev/null)
        _sig=""
        if [ "$_kc1" = "200" ] && [ "$_kc2" = "200" ]; then
            _kh1=$(sha256sum "$_kt1" 2>/dev/null | awk '{print $1}')
            _kh2=$(sha256sum "$_kt2" 2>/dev/null | awk '{print $1}')
            _ks1=$(wc -c < "$_kt1" 2>/dev/null | tr -d ' '); _ks1=${_ks1:-0}
            _ks2=$(wc -c < "$_kt2" 2>/dev/null | tr -d ' '); _ks2=${_ks2:-0}
            if [ -n "$_kh1" ] && [ "$_kh1" = "$_kh2" ] && [ "$_ks1" -gt 0 ]; then
                _sig="h:${_kh1:0:12}:$_ks1"
            fi
        fi
        rm -f "$_kt1" "$_kt2"
        if [ -n "$_sig" ]; then
            printf '%s\n' "${_kh} ($_sig)" >> "$SESSION_DIR/findings/probes/soft-200-hosts.txt"
        else
            printf '%s\n' "$_kh" >> "$SESSION_DIR/urls/hosts-katana.txt"
        fi
    done < "$SESSION_DIR/hosts/hosts-live.txt"
    _s200n=$(wc -l < "$SESSION_DIR/findings/probes/soft-200-hosts.txt" 2>/dev/null | tr -d ' '); _s200n=${_s200n:-0}
    [ "$_s200n" -gt 0 ] && out "${C_Y}  soft-200 catch-all detected on ${_s200n} hosts (identical bodies) >> findings/probes/soft-200-hosts.txt${C_R}"

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ katana${C_R} -d 5 -c 20 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl -jsluice -known-files all -fs rdn -H 'User-Agent: ***' -ef '$katana_ef' < urls/hosts-katana.txt | awk '!seen[\$0]++' >> urls/crawl-katana.txt (chunked) || true"
    : > "$SESSION_DIR/urls/crawl-katana.txt"
    if [ -s "$SESSION_DIR/urls/hosts-katana.txt" ]; then
        split -l 10 "$SESSION_DIR/urls/hosts-katana.txt" "$SESSION_DIR/state/tmp/.hostchunk-"
        for _hc in "$SESSION_DIR/state/tmp/.hostchunk-"*; do
            [ -e "$_hc" ] || continue
            GOMEMLIMIT=2GiB nice -n 5 bash -c 'ulimit -v 4194304 2>/dev/null || true; exec "$@"' _ katana -d 5 -c 20 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl -jsluice -known-files all -fs rdn -H "User-Agent: $FAKE_UA" -ef "$katana_ef" 2>/dev/null < "$_hc" | awk '!seen[$0]++' >> "$SESSION_DIR/urls/crawl-katana.txt" || true
            rm -f "$_hc"
        done
    fi
    comm -23 <(grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/urls/urls-archive.txt" | sort -u) <(sort -u "$SESSION_DIR/urls/crawl-katana.txt") | url_junk_filter | sort -u > "$SESSION_DIR/state/tmp/.archive-seeds-full.txt"
    cp "$SESSION_DIR/state/tmp/.archive-seeds-full.txt" "$SESSION_DIR/state/tmp/.archive-seeds.txt"
    if [ -s "$SESSION_DIR/state/tmp/.archive-seeds.txt" ]; then
        out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ katana${C_R} -u .archive-seeds.txt -d 3 -c 20 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl -H 'User-Agent: ***' | awk '!seen[\$0]++' > urls/crawl-archive.txt || true"
        : > "$SESSION_DIR/urls/crawl-archive.txt"
        split -l 200 "$SESSION_DIR/state/tmp/.archive-seeds.txt" "$SESSION_DIR/state/tmp/.seedchunk-"
        for _sc in "$SESSION_DIR/state/tmp/.seedchunk-"*; do
            [ -e "$_sc" ] || continue
            GOMEMLIMIT=2GiB nice -n 5 bash -c 'ulimit -v 4194304 2>/dev/null || true; exec "$@"' _ katana -u "$_sc" -d 3 -c 20 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl -H "User-Agent: $FAKE_UA" 2>/dev/null | awk '!seen[$0]++' >> "$SESSION_DIR/urls/crawl-archive.txt" || true
            rm -f "$_sc"
        done
        sort -u "$SESSION_DIR/urls/crawl-archive.txt" -o "$SESSION_DIR/urls/crawl-archive.txt"
        comm -23 <(grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/urls/crawl-archive.txt" 2>/dev/null | sort -u) <(grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/urls/crawl-katana.txt" 2>/dev/null | sort -u) | url_junk_filter > "$SESSION_DIR/urls/urls-revived.txt"
    fi
    rm -f "$SESSION_DIR/state/tmp/.archive-seeds.txt" "$SESSION_DIR/state/tmp/.archive-seeds-full.txt"

}
st_classify_js() {
    {
        [ -f "$SESSION_DIR/hosts/hosts-live.txt" ] && cat "$SESSION_DIR/hosts/hosts-live.txt"
        [ -f "$SESSION_DIR/urls/crawl-katana.txt" ] && cat "$SESSION_DIR/urls/crawl-katana.txt"
        [ -f "$SESSION_DIR/urls/crawl-archive.txt" ] && cat "$SESSION_DIR/urls/crawl-archive.txt"
        [ -f "$SESSION_DIR/urls/urls-archive.txt" ] && cat "$SESSION_DIR/urls/urls-archive.txt"
    } | url_junk_filter | sort -u > "$SESSION_DIR/state/tmp/.all-urls-raw.txt"
    if [ -s "$SESSION_DIR/state/tmp/.all-urls-raw.txt" ]; then
        awk '{
            sub(/^[[:space:]]+/,"")
            if (tolower($0) !~ /^https?:\/\//) next
            scheme = tolower(substr($0,1,index($0,":")))
            rest = substr($0, index($0,"//")+2)
            if (index(rest,"/")==0) { host=rest; path="/" } else { host=substr(rest,1,index(rest,"/")-1); path=substr(rest,index(rest,"/")) }
            host = tolower(host)
            if (index(path,"?")>0) {
                q = substr(path, index(path,"?")+1); path = substr(path,1,index(path,"?")-1)
                n = split(q, p, "&"); keep = ""
                for (i=1; i<=n; i++) { if (p[i] !~ /^(utm_[a-z]*|fbclid|gclid|dclid|msclkid|mc_cid|mc_eid|igshid|spm|ref_|srsltid)($|=)/) keep = (keep=="") ? p[i] : keep "&" p[i] }
                path = (keep=="") ? path : path "?" keep
            }
            print scheme "//" host "" path
        }' "$SESSION_DIR/state/tmp/.all-urls-raw.txt" | sort -u > "$SESSION_DIR/urls/urls-all.txt"
    else
        : > "$SESSION_DIR/urls/urls-all.txt"
    fi
    rm -f "$SESSION_DIR/state/tmp/.all-urls-raw.txt"
    grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/urls/urls-all.txt" | sort -u > "$SESSION_DIR/urls/urls-inscope.txt"
    comm -23 "$SESSION_DIR/urls/urls-all.txt" "$SESSION_DIR/urls/urls-inscope.txt" > "$SESSION_DIR/findings/surface/urls-outofscope.txt"
    grep -E '\.(js|mjs)(\?|$)' "$SESSION_DIR/urls/urls-inscope.txt" | sort -u > "$SESSION_DIR/urls/urls-js.txt"
    grep -E '\.json(\?|$)' "$SESSION_DIR/urls/urls-inscope.txt" | sort -u > "$SESSION_DIR/urls/urls-json.txt"
    grep -E '(\.(env|pem|key|p12|pfx|bak|backup|old|sql|sqlite|sqlite3|db|dump|log|config|cfg|ini|yaml|yml|xml|conf|git|gitignore|zip|tar|gz|tgz|7z|rar|swp|swo|crt|csr|htpasswd|npmrc|dockercfg|ps1|sh|htaccess|txt|ds_store|tfstate|tfvars|svn|hg|bzr|idea|vscode|vagrant|ovpn|ppk|kdbx)(\?|$))|(apple-app-site-association|openid-configuration|security\.txt|crossdomain\.xml|clientaccesspolicy\.xml)' "$SESSION_DIR/urls/urls-inscope.txt" | sort -u > "$SESSION_DIR/urls/urls-artifacts.txt"
    grep -E '\.(css|wasm)(\?|$)' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | sort -u >> "$SESSION_DIR/urls/urls-artifacts.txt"
    awk '{
        n = split($0, a, "?")
        path = tolower(a[1])
        if (path ~ /\.(css|png|jpe?g|gif|svg|ico|webp|avif|bmp|tiff?|woff2?|ttf|otf|eot|pdf|zip|tar|tgz|gz|bz2|xz|7z|rar|mp3|wav|ogg|m4a|mp4|webm|avi|mov|mkv|json|xml|csv|doc|docx|xls|xlsx|ppt|pptx|txt|md|log)$/) next
        if (path ~ /\/$/) next
        lastseg = path
        sub(/.*\//, "", lastseg)
        if (lastseg ~ /\./ && lastseg !~ /\.(js|mjs|map)$/) next
        if (path !~ /\.(js|mjs|map)($|\?)/ && path !~ /\/(assets|static|build|dist|chunks?)\// && lastseg !~ /[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/ && lastseg !~ /^(main|runtime|polyfills|scripts|styles|vendor|chunk|app|index|bundle|sw|worker|common|shared)([._-]|$)/) next
        print $0
    }' "$SESSION_DIR/urls/urls-inscope.txt" | sort -u > "$SESSION_DIR/urls/urls-js-candidates.txt"
    grep -E '\b(api|v[0-9]+|graphql|rest|endpoint|ajax)\b' "$SESSION_DIR/urls/urls-inscope.txt" | grep -E -v '\.(css|js|png|jpe?g|gif|svg|ico|webp|woff2?|ttf|map|xml|pdf|zip)(\?|$)' | sort -u > "$SESSION_DIR/urls/urls-api.txt"
    grep -oP '[?&]\K[^=&]+' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | sort | uniq -c | sort -rn > "$SESSION_DIR/urls/urls-params.txt"
    grep '?' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | grep -vE '\.(js|css|png|jpe?g|gif|svg|ico|woff2?|ttf|map|webp|mp4|mp3|pdf|zip)(\?|$)' | awk -F'?' '{n=gsub(/&/,"&",$2)+1; print n"\t"$0}' | sort -rn | cut -f2- | head -150 > "$SESSION_DIR/urls/urls-reflection-candidates.txt"
    awk '{u=$0; sub(/\?.*/,"",u); n=split(u,a,"/"); seg=a[n]; if (seg ~ /\./) {sub(/^.*\./,"",seg); print tolower(seg)}}' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | sort | uniq -c | sort -rn > "$SESSION_DIR/urls/urls-extensions.txt"
    out "${C_W}inscope: $(wc -l < "$SESSION_DIR/urls/urls-inscope.txt" | tr -d ' ') | js: $(wc -l < "$SESSION_DIR/urls/urls-js.txt" | tr -d ' ') | json: $(wc -l < "$SESSION_DIR/urls/urls-json.txt" | tr -d ' ') | artifacts: $(wc -l < "$SESSION_DIR/urls/urls-artifacts.txt" | tr -d ' ') | candidates: $(wc -l < "$SESSION_DIR/urls/urls-js-candidates.txt" | tr -d ' ')${C_R}"
}
_webpack_scan() {
    local _f _url _dir _id _h _base
    find "$SESSION_DIR/js/raw" -maxdepth 1 -type f -name '*.js' -newer "$SESSION_DIR/state/tmp/.disc-marker" -size -2097152c -print0 2>/dev/null | while IFS= read -r -d '' _f; do
        grep -qE '(__webpack_require__|\.u[[:space:]]*=|webpackChunk)' "$_f" 2>/dev/null || continue
        _base=$(basename "$_f")
        case "$_base" in *runtime*|*main*) : ;; *) continue ;; esac
        _url=$(awk -F'|' -v f="$_base" '$1==f{print $2; exit}' "$SESSION_DIR/state/url-map.txt" 2>/dev/null)
        [ -z "$_url" ] && continue
        _dir=${_url%/*}/
        [ "$_dir" = "$_url" ] && continue
        grep -oE '[{,][[:space:]]*"?[0-9]{1,4}"?[[:space:]]*:[[:space:]]*"[0-9a-f]{8,}"' "$_f" 2>/dev/null \
        | sed -E 's/^[{},][[:space:]]*"?([0-9]+)"?[[:space:]]*:[[:space:]]*"([0-9a-f]{8,})"[[:space:]]*$/\1 \2/' \
        | while IFS=' ' read -r _id _h; do
            [ -n "$_id" ] && [ -n "$_h" ] || continue
            printf '%s%s.%s.js\n%s%s.%s.chunk.js\n' "$_dir" "$_id" "$_h" "$_dir" "$_id" "$_h"
        done
    done | grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)"
}

st_js_pipeline() {
    mkdir -p "$SESSION_DIR/js/raw" "$SESSION_DIR/js/formatted" "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/deobf" "$SESSION_DIR/js/sourcemaps"
    touch "$SESSION_DIR/state/tmp/.disc-marker"
    touch "$SESSION_DIR/state/url-map.txt" "$SESSION_DIR/state/js-map.txt" \
        "$SESSION_DIR/state/js-content-hashes.txt" "$SESSION_DIR/state/map-hashes.txt" \
        "$SESSION_DIR/state/blind-probed.txt" "$SESSION_DIR/state/blind-maps-found.txt" \
        "$SESSION_DIR/state/blind-failed.txt" "$SESSION_DIR/state/maps-extracted.txt" \
        "$SESSION_DIR/state/sm-done.txt" "$SESSION_DIR/state/obf-done.txt" "$SESSION_DIR/state/obf-hits.txt" \
        "$SESSION_DIR/state/pretty-done.txt" "$SESSION_DIR/state/pretty-hashes.txt" "$SESSION_DIR/state/page-hashes.txt"

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} -s -f -m 10 \$origin/{/sw.js,/service-worker.js,/worker.js,/precache-manifest.js}   (first-30 live origins) >> findings/surface/service-worker-urls.txt"
    : > "$SESSION_DIR/findings/surface/service-worker-urls.txt"
    _swpats="$SESSION_DIR/state/tmp/.sw-patterns.txt"
    if [ -s "$HOME/github-tools/hunt-custom.txt" ]; then
        grep -v '^#' "$HOME/github-tools/hunt-custom.txt" | awk -F'|' '{ if (NF >= 3) { r = $0; sub(/^[^|]*\|/, "", r); sub(/\|[^|]*$/, "", r); if (r != "") print r } }' > "$_swpats" 2>/dev/null
    fi
    head -30 "$SESSION_DIR/hosts/hosts-live.txt" 2>/dev/null | awk -F/ '{print $1"//"$3}' | sort -u | while read -r origin; do
            for sw in /sw.js /service-worker.js /worker.js /precache-manifest.js; do
            local body
            body=$(curl -s -f -m 10 -A "$FAKE_UA" "$origin$sw" 2>/dev/null)
            [ -z "$body" ] && continue
            if [ -s "$SESSION_DIR/state/tmp/.sw-patterns.txt" ]; then
                _swh=$(printf '%s' "$body" | _mpgrep "$SESSION_DIR/state/tmp/.sw-patterns.txt" | sort -u | head -5)
                if [ -n "$_swh" ]; then
                    { echo "== $origin$sw"; echo "$_swh"; } >> "$SESSION_DIR/findings/probes/body-secrets.txt"
                fi
            fi
            printf '%s\n' "$body" | grep -oE "['\"][^'\"]+\.(js|html|css)['\"]" | sed -e 's/^.//' -e 's/.$//' | while read -r a; do
                case "$a" in http*) printf '%s\n' "$a" ;; /*) printf '%s\n' "$origin$a" ;; *) printf '%s\n' "$origin/$a" ;; esac
            done >> "$SESSION_DIR/findings/surface/service-worker-urls.txt"
        done
    done
    sort -u "$SESSION_DIR/findings/surface/service-worker-urls.txt" -o "$SESSION_DIR/findings/surface/service-worker-urls.txt"
    rm -f "$SESSION_DIR/state/tmp/.sw-patterns.txt"
    if [ -s "$SESSION_DIR/findings/surface/service-worker-urls.txt" ]; then
        grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/findings/surface/service-worker-urls.txt" | sort -u >> "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null
        sort -u "$SESSION_DIR/urls/urls-inscope.txt" -o "$SESSION_DIR/urls/urls-inscope.txt"
        grep -E '\.(js|mjs)(\?|$)' "$SESSION_DIR/findings/surface/service-worker-urls.txt" | sort -u >> "$SESSION_DIR/urls/urls-js.txt" 2>/dev/null
        sort -u "$SESSION_DIR/urls/urls-js.txt" -o "$SESSION_DIR/urls/urls-js.txt" 2>/dev/null
    fi

    local round=0
    while [ "$round" -lt "$JS_MAX_ROUNDS" ]; do
        round=$((round + 1))
        _rotate_ua

        if [ "$round" -eq 1 ]; then
            {
                cat "$SESSION_DIR/urls/urls-js.txt" 2>/dev/null
                cat "$SESSION_DIR/urls/urls-js-candidates.txt" 2>/dev/null
            } | sort -u | tr -d '\r' | awk 'NF' > "$SESSION_DIR/state/tmp/.js-round-seeds.txt"
        else
            cat "$SESSION_DIR/state/tmp/.js-discovered.txt" "$SESSION_DIR/state/tmp/.js-failed.txt" 2>/dev/null | sort -u | tr -d '\r' | awk 'NF' > "$SESSION_DIR/state/tmp/.js-round-seeds.txt"
        fi

        : > "$SESSION_DIR/state/tmp/.js-done-urls.txt"
        if [ -s "$SESSION_DIR/state/url-map.txt" ]; then
            while IFS='|' read -r mapped_file mapped_url; do
                [ -n "$mapped_file" ] || continue
                [ -s "$SESSION_DIR/js/raw/$mapped_file" ] || continue
                printf '%s\n' "$mapped_url"
            done < "$SESSION_DIR/state/url-map.txt" | sort -u > "$SESSION_DIR/state/tmp/.js-done-urls.txt"
        fi
        comm -23 <(sort -u "$SESSION_DIR/state/tmp/.js-round-seeds.txt") "$SESSION_DIR/state/tmp/.js-done-urls.txt" > "$SESSION_DIR/state/tmp/.js-pending.txt"
        local pending
        pending=$(wc -l < "$SESSION_DIR/state/tmp/.js-pending.txt" | tr -d ' ')

        if [ "$pending" -gt 0 ]; then
            out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -l .js-pending.txt -sr -srd tmp/httpx-js -json -rl $KATANA_RL   (primary JS fetch: $pending files, Go TLS fingerprint)"
            awk '{n=$0; sub(/\?.*/,"",n); sub(/.*\//,"",n); if (n ~ /[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/) { if(!seen[n]++) print } else print }' "$SESSION_DIR/state/tmp/.js-pending.txt" > "$SESSION_DIR/state/tmp/.js-pending-dedup.txt" 2>/dev/null || cp "$SESSION_DIR/state/tmp/.js-pending.txt" "$SESSION_DIR/state/tmp/.js-pending-dedup.txt"
            _pd=$(wc -l < "$SESSION_DIR/state/tmp/.js-pending-dedup.txt" | tr -d ' ')
            [ "${_pd:-0}" -gt 0 ] && [ "$_pd" -lt "$pending" ] && { out "${C_W}basename dedup: $pending -> $_pd unique chunks${C_R}"; }
            cp "$SESSION_DIR/state/tmp/.js-pending-dedup.txt" "$SESSION_DIR/state/tmp/.js-pending.txt"
            rm -f "$SESSION_DIR/state/tmp/.js-pending-dedup.txt"
            : > "$SESSION_DIR/state/tmp/.js-progress.log"
            _httpx_wave "$SESSION_DIR/state/tmp/.js-pending.txt" js
            comm -23 <(sort -u "$SESSION_DIR/state/tmp/.js-pending.txt") <(sort -u "$SESSION_DIR/state/tmp/httpx-js.ok") > "$SESSION_DIR/state/tmp/.js-curl-retry.txt"
            if [ -s "$SESSION_DIR/state/tmp/.js-curl-retry.txt" ]; then
                cat "$SESSION_DIR/state/tmp/.js-curl-retry.txt" | xargs -d '\n' -P "$RECONLY_FETCH_THREADS" -n 1 bash -c '
                    for u in "$@"; do
                        if js_fetch "$u"; then js_progress OK "$u" "$JS_LAST_CODE"; else js_progress FAIL "$u" "$JS_LAST_CODE"; fi
                    done
                ' _
            fi
            grep '^FAIL:429\|^FAIL:502\|^FAIL:503\|^FAIL:504\|^FAIL:000' "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null | cut -d'|' -f2- >> "$SESSION_DIR/state/tmp/.js-failed.txt"
            rm -f "$SESSION_DIR/state/tmp/.js-curl-retry.txt" "$SESSION_DIR/state/tmp/httpx-js.ok"
            adapt_threads
            cp "$SESSION_DIR/state/tmp/.js-pending.txt" "$SESSION_DIR/state/tmp/.js-round-fetched.txt"
        else
            : > "$SESSION_DIR/state/tmp/.js-round-fetched.txt"
            out "${C_W}No pending JS this round${C_R}"
        fi

        if [ "$round" -eq 1 ]; then
            : > "$SESSION_DIR/state/tmp/.json-seeds.txt"
            [ -s "$SESSION_DIR/urls/urls-json.txt" ] && cat "$SESSION_DIR/urls/urls-json.txt" >> "$SESSION_DIR/state/tmp/.json-seeds.txt"
            [ -s "$SESSION_DIR/urls/urls-api.txt" ] && head -50 "$SESSION_DIR/urls/urls-api.txt" >> "$SESSION_DIR/state/tmp/.json-seeds.txt"
            [ -s "$SESSION_DIR/urls/urls-api.txt" ] && head -50 "$SESSION_DIR/urls/urls-api.txt" > "$SESSION_DIR/state/api-sampled.txt"
            if [ -s "$SESSION_DIR/hosts/hosts-live.txt" ]; then
                while read -r _jh; do
                    [ -z "$_jh" ] && continue
                    for _jp in /swagger.json /openapi.json /v3/api-docs /api-docs /swagger/v1/swagger.json; do
                        printf '%s%s\n' "$_jh" "$_jp" >> "$SESSION_DIR/state/tmp/.json-seeds.txt"
                    done
                done < "$SESSION_DIR/hosts/hosts-live.txt"
            fi
            sort -u "$SESSION_DIR/state/tmp/.json-seeds.txt" | tr -d '\r' | awk 'NF' > "$SESSION_DIR/state/tmp/.json-s.txt" && mv "$SESSION_DIR/state/tmp/.json-s.txt" "$SESSION_DIR/state/tmp/.json-seeds.txt"
            awk -F'|' '{print $2}' "$SESSION_DIR/state/url-map.txt" 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.json-done.txt"
            comm -23 "$SESSION_DIR/state/tmp/.json-seeds.txt" "$SESSION_DIR/state/tmp/.json-done.txt" > "$SESSION_DIR/state/tmp/.json-pending.txt"
            local _json_pending
            _json_pending=$(wc -l < "$SESSION_DIR/state/tmp/.json-pending.txt" | tr -d ' ')
            if [ "${_json_pending:-0}" -gt 0 ]; then
                out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -l .json-pending.txt -sr -srd tmp/httpx-json -json -rl $KATANA_RL   (JSON fetch: $_json_pending files, Go TLS)"
                : > "$SESSION_DIR/state/tmp/.js-progress.log"
                _httpx_wave "$SESSION_DIR/state/tmp/.json-pending.txt" json
                comm -23 <(sort -u "$SESSION_DIR/state/tmp/.json-pending.txt") <(sort -u "$SESSION_DIR/state/tmp/httpx-json.ok") > "$SESSION_DIR/state/tmp/.json-curl-retry.txt"
                if [ -s "$SESSION_DIR/state/tmp/.json-curl-retry.txt" ]; then
                    cat "$SESSION_DIR/state/tmp/.json-curl-retry.txt" | xargs -d '\n' -P "$RECONLY_FETCH_THREADS" -n 1 bash -c '
                        for j in "$@"; do
                            if json_fetch "$j"; then js_progress OK "$j" "$JSON_LAST_CODE"; else js_progress FAIL "$j" "$JSON_LAST_CODE"; fi
                        done
                    ' _
                fi
                rm -f "$SESSION_DIR/state/tmp/.json-curl-retry.txt" "$SESSION_DIR/state/tmp/httpx-json.ok"
                adapt_threads
            fi
            rm -f "$SESSION_DIR/state/tmp/.json-seeds.txt" "$SESSION_DIR/state/tmp/.json-done.txt" "$SESSION_DIR/state/tmp/.json-pending.txt"
        fi
        if [ "$round" -eq 1 ] && [ -s "$SESSION_DIR/urls/urls-artifacts.txt" ]; then
            head -100 "$SESSION_DIR/urls/urls-artifacts.txt" > "$SESSION_DIR/state/tmp/.art-pending.txt"
            local _art_pending
            _art_pending=$(wc -l < "$SESSION_DIR/state/tmp/.art-pending.txt" | tr -d ' ')
            if [ "${_art_pending:-0}" -gt 0 ]; then
                out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -l .art-pending.txt -sr -srd tmp/httpx-art -json -rl $KATANA_RL   (artifacts fetch: $_art_pending files, Go TLS)"
                : > "$SESSION_DIR/state/tmp/.js-progress.log"
                _httpx_wave "$SESSION_DIR/state/tmp/.art-pending.txt" art
                comm -23 <(sort -u "$SESSION_DIR/state/tmp/.art-pending.txt") <(sort -u "$SESSION_DIR/state/tmp/httpx-art.ok") > "$SESSION_DIR/state/tmp/.art-curl-retry.txt"
                if [ -s "$SESSION_DIR/state/tmp/.art-curl-retry.txt" ]; then
                    cat "$SESSION_DIR/state/tmp/.art-curl-retry.txt" | xargs -d '\n' -P 10 -n 1 bash -c '
                        for a in "$@"; do
                            if artifact_fetch "$a"; then js_progress OK "$a" "$ART_LAST_CODE"; else js_progress FAIL "$a" "$ART_LAST_CODE"; fi
                        done
                    ' _
                fi
                rm -f "$SESSION_DIR/state/tmp/.art-curl-retry.txt" "$SESSION_DIR/state/tmp/httpx-art.ok"
            fi
            rm -f "$SESSION_DIR/state/tmp/.art-pending.txt"
        fi

        if [ "$round" -eq 1 ] && [ -s "$SESSION_DIR/urls/urls-inscope.txt" ]; then
            _rotate_ua
            [ -s "$SESSION_DIR/findings/probes/soft-200-hosts.txt" ] && awk '{ line=$0; sub(/^https?:\/\//,"",line); scheme=($0 ~ /^https:/)?"443":"80"; if (match(line, / \([^)]+\)$/)) { hp=substr(line,1,RSTART-1); sz=line; sub(/.*\(/,"",sz); sub(/\)$/,"",sz); if (hp !~ /:[0-9]+$/) hp=hp":"scheme; print hp "\t" sz } }' "$SESSION_DIR/findings/probes/soft-200-hosts.txt" > "$SESSION_DIR/state/tmp/.s200-sigs.tsv"
            cat "$SESSION_DIR/urls/urls-revived.txt" 2>/dev/null | url_junk_filter | awk '!seen[$0]++' > "$SESSION_DIR/state/tmp/.pages-priority.txt"
            awk 'NR==FNR { prio[$0]=1; next } !($0 in prio)' "$SESSION_DIR/state/tmp/.pages-priority.txt" "$SESSION_DIR/urls/urls-inscope.txt" \
              | grep -vE '\.(js|css|png|jpe?g|gif|svg|ico|woff2?|ttf|map|json|xml|pdf|zip|mp4|mp3|avi|mov|webp)(\?|$)' \
              | { if [ -s "$SESSION_DIR/state/api-sampled.txt" ]; then grep -vxF -f "$SESSION_DIR/state/api-sampled.txt"; else cat; fi; } \
              | awk '!seen[$0]++' > "$SESSION_DIR/state/tmp/.pages-rest.txt"
            {
                cat "$SESSION_DIR/state/tmp/.pages-priority.txt"
                awk -F/ '{depth=NF; hasq=($0 ~ /\?/) ? 1000 : 0; print (hasq+depth)"\t"$0}' "$SESSION_DIR/state/tmp/.pages-rest.txt" | sort -k1,1rn -k2 | cut -f2-
            } | awk '{ u=$0; sub(/\?.*/,"",u); if(!(u in seen)){seen[u]=1; print} }' > "$SESSION_DIR/state/tmp/.pages-all-ranked.txt"
            head -n "$RECONLY_MAX_PAGES" "$SESSION_DIR/state/tmp/.pages-all-ranked.txt" > "$SESSION_DIR/state/tmp/.pages-temp.txt"
            _pgcap=$(wc -l < "$SESSION_DIR/state/tmp/.pages-all-ranked.txt" | tr -d ' ')
            [ "${_pgcap:-0}" -gt "$RECONLY_MAX_PAGES" ] && out "  pages capped: $RECONLY_MAX_PAGES of $_pgcap ranked (raise RECONLY_MAX_PAGES for more inline-JS surface)"
            rm -f "$SESSION_DIR/state/tmp/.pages-all-ranked.txt" "$SESSION_DIR/state/tmp/.pages-priority.txt" "$SESSION_DIR/state/tmp/.pages-rest.txt"
            if [ -s "$SESSION_DIR/state/tmp/.s200-sigs.tsv" ]; then
                _pgbefore=$(wc -l < "$SESSION_DIR/state/tmp/.pages-temp.txt" | tr -d ' ')
                awk -v tsv="$SESSION_DIR/state/tmp/.s200-sigs.tsv" '
                    BEGIN { while ((getline l < tsv) > 0) { split(l, a, "\t"); bad[a[1]]=1 } }
                    {   u=$0; s=u; sub(/:.*/,"",s)
                        p=u; sub(/^.*:\/\//,"",p); sub(/[\/?#].*/,"",p)
                        if (p !~ /:[0-9]+$/) p = p ":" (s=="https" ? "443" : "80")
                        if (p in bad) next
                        print
                    }' "$SESSION_DIR/state/tmp/.pages-temp.txt" > "$SESSION_DIR/state/tmp/.pages-temp2.txt" && mv "$SESSION_DIR/state/tmp/.pages-temp2.txt" "$SESSION_DIR/state/tmp/.pages-temp.txt"
                _pgafter=$(wc -l < "$SESSION_DIR/state/tmp/.pages-temp.txt" | tr -d ' ')
                [ "${_pgbefore:-0}" -gt "${_pgafter:-0}" ] && out "  soft-200 hosts: $((_pgbefore - _pgafter)) catch-all pages skipped pre-download"
            fi
            local page_count
            page_count=$(wc -l < "$SESSION_DIR/state/tmp/.pages-temp.txt" | tr -d ' ')
            if [ "$page_count" -gt 0 ]; then
                out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -l .pages-temp.txt -sr -srd tmp/httpx-pages -json -rl $KATANA_RL   (pages fetch: $page_count pages, Go TLS)"
                : > "$SESSION_DIR/state/tmp/.js-progress.log"
                _jd="$SESSION_DIR/state/tmp/httpx-pages"
                : > "$SESSION_DIR/state/tmp/.pg-httpx-ok.txt"
                split -l 250 "$SESSION_DIR/state/tmp/.pages-temp.txt" "$SESSION_DIR/state/tmp/.pgchunk-"
                for _pc in "$SESSION_DIR/state/tmp/.pgchunk-"*; do
                    [ -e "$_pc" ] || continue
                    : > "$SESSION_DIR/state/tmp/.js-progress.log"
                    _httpx_wave "$_pc" pages
                    adapt_threads
                    rm -f "$_pc"
                done
                comm -23 <(sort -u "$SESSION_DIR/state/tmp/.pages-temp.txt") <(sort -u "$SESSION_DIR/state/tmp/httpx-pages.ok") > "$SESSION_DIR/state/tmp/.pg-curl-retry.txt"
                if [ -s "$SESSION_DIR/state/tmp/.pg-curl-retry.txt" ]; then
                    cat "$SESSION_DIR/state/tmp/.pg-curl-retry.txt" | xargs -d '\n' -P "$RECONLY_PAGE_THREADS" -n 1 bash -c '
                        for p in "$@"; do
                            if page_fetch "$p"; then js_progress OK "$p" "$PAGE_LAST_CODE"; else js_progress FAIL "$p" "$PAGE_LAST_CODE"; fi
                        done
                    ' _
                fi
                rm -f "$SESSION_DIR/state/tmp/.pg-curl-retry.txt" "$SESSION_DIR/state/tmp/httpx-pages.ok"
                adapt_threads
                local inline_count
                inline_count=$(find "$SESSION_DIR/js/raw" -name 'page_*.js' 2>/dev/null | wc -l | tr -d ' ')
                out "  pages: $page_count | inline scripts: $inline_count"
            fi
            rm -f "$SESSION_DIR/state/tmp/.pages-temp.txt"
        fi

        find "$SESSION_DIR/js/raw" -maxdepth 1 -type f -name '*.js' -printf '%f\n' 2>/dev/null | sort > "$SESSION_DIR/state/tmp/.sm-all.txt"
        comm -23 "$SESSION_DIR/state/tmp/.sm-all.txt" <(sort -u "$SESSION_DIR/state/sm-done.txt" 2>/dev/null) > "$SESSION_DIR/state/tmp/.sm-new.txt"
        if [ -s "$SESSION_DIR/state/tmp/.sm-new.txt" ]; then
            out "${C_GRN}Sourcemap mining ($(wc -l < "$SESSION_DIR/state/tmp/.sm-new.txt" | tr -d ' ') new)${C_R}"
            cat "$SESSION_DIR/state/tmp/.sm-new.txt" | while IFS= read -r fn; do
                [ -f "$SESSION_DIR/js/raw/$fn" ] || continue
                local raw
                if command -v rg &>/dev/null; then
                    raw=$(rg --no-ignore -a -n -P -o -e 'sourceMappingURL\s*=\s*[^\s"'"'"']+\.map' "$SESSION_DIR/js/raw/$fn" 2>/dev/null | sed "s|^${SESSION_DIR}/js/raw/||")
                else
                    raw=$(grep -a -n -P -o -e 'sourceMappingURL\s*=\s*[^\s"'"'"']+\.map' "$SESSION_DIR/js/raw/$fn" 2>/dev/null | sed "s|^${SESSION_DIR}/js/raw/||")
                fi
                [ -n "$raw" ] && printf '%s\n' "$raw"
            done | awk 'NF' | sort -u > "$SESSION_DIR/state/tmp/.sm-refs.txt"
            if [ -s "$SESSION_DIR/state/tmp/.sm-refs.txt" ]; then
                out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ recover_one_sourcemap${C_R}: cat .sm-refs.txt | xargs -P $RECONLY_JS_THREADS -I {} bash -c 'recover_one_sourcemap "\$1"' _ {}"
                cat "$SESSION_DIR/state/tmp/.sm-refs.txt" | xargs -d '\n' -P "$RECONLY_JS_THREADS" -I {} bash -c 'recover_one_sourcemap "$1"' _ {}
            fi
            rm -f "$SESSION_DIR/state/tmp/.sm-refs.txt"

            _blind_map_probe

            find "$SESSION_DIR/js/mapsrc" \( -name '*.js' -o -name '*.ts' \) -type f -print0 2>/dev/null | xargs -0 md5sum 2>/dev/null | sort -k1,1 | awk 'seen[$1]++ {print $2}' > "$SESSION_DIR/state/tmp/.mapsrc-dups.txt"
            [ -s "$SESSION_DIR/state/tmp/.mapsrc-dups.txt" ] && xargs -r rm -f < "$SESSION_DIR/state/tmp/.mapsrc-dups.txt"
            rm -f "$SESSION_DIR/state/tmp/.mapsrc-dups.txt"
        fi
        cat "$SESSION_DIR/state/sm-done.txt" "$SESSION_DIR/state/tmp/.sm-new.txt" 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.sm-final.txt" && mv "$SESSION_DIR/state/tmp/.sm-final.txt" "$SESSION_DIR/state/sm-done.txt"

        find "$SESSION_DIR/js/raw" -maxdepth 1 -type f -name '*.js' -printf '%f\n' 2>/dev/null | sort > "$SESSION_DIR/state/tmp/.obf-all.txt"
        comm -23 "$SESSION_DIR/state/tmp/.obf-all.txt" <(sort -u "$SESSION_DIR/state/obf-done.txt" 2>/dev/null) > "$SESSION_DIR/state/tmp/.obf-new.txt"
        if [ -s "$SESSION_DIR/state/tmp/.obf-new.txt" ]; then
            : > "$SESSION_DIR/state/tmp/.obf-hits-round.txt"
            while IFS= read -r fn; do
                if command -v rg &>/dev/null; then
                    rg -q -a -P -e '(_0x[a-f0-9]{4,}.*_0x[a-f0-9]{4,}|eval\(function\(p,a,c,k|eval\(atob\()' "$SESSION_DIR/js/raw/$fn" 2>/dev/null && printf '%s\n' "$fn" >> "$SESSION_DIR/state/tmp/.obf-hits-round.txt"
                else
                    grep -qP '(_0x[a-f0-9]{4,}.*_0x[a-f0-9]{4,}|eval\(function\(p,a,c,k|eval\(atob\()' "$SESSION_DIR/js/raw/$fn" 2>/dev/null && printf '%s\n' "$fn" >> "$SESSION_DIR/state/tmp/.obf-hits-round.txt"
                fi
            done < "$SESSION_DIR/state/tmp/.obf-new.txt"
            cat "$SESSION_DIR/state/obf-done.txt" "$SESSION_DIR/state/tmp/.obf-new.txt" 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.obf-final.txt" && mv "$SESSION_DIR/state/tmp/.obf-final.txt" "$SESSION_DIR/state/obf-done.txt"
            local obf_budget
            obf_budget=$((OBF_MAX_FILES - $(wc -l < "$SESSION_DIR/state/obf-hits.txt" 2>/dev/null | tr -d ' ')))
            if [ -s "$SESSION_DIR/state/tmp/.obf-hits-round.txt" ] && [ "$obf_budget" -gt 0 ] && command -v npx &>/dev/null; then
                out "${C_W}Deobfuscating (budget: $obf_budget)${C_R}"
                head -n "$obf_budget" "$SESSION_DIR/state/tmp/.obf-hits-round.txt" | while IFS= read -r fn; do
                    printf '%s\n' "$fn" >> "$SESSION_DIR/state/obf-hits.txt"
                    local bname="${fn%.js}"
                    nice -n 15 timeout --foreground 120 npx webcrack "$SESSION_DIR/js/raw/$fn" -o "$SESSION_DIR/state/tmp/deobf/$bname" >/dev/null 2>&1 || true
                    if [ ! -d "$SESSION_DIR/state/tmp/deobf/$bname" ]; then
                        nice -n 15 timeout --foreground 180 npx -y synchrony@latest deobfuscate "$SESSION_DIR/js/raw/$fn" --output "$SESSION_DIR/state/tmp/deobf/${bname}-sync.js" >/dev/null 2>&1 || true
                        if [ -s "$SESSION_DIR/state/tmp/deobf/${bname}-sync.js" ]; then
                            mkdir -p "$SESSION_DIR/state/tmp/deobf/$bname"
                            mv "$SESSION_DIR/state/tmp/deobf/${bname}-sync.js" "$SESSION_DIR/state/tmp/deobf/$bname/$fn"
                        fi
                    fi
                    if [ -d "$SESSION_DIR/state/tmp/deobf/$bname" ]; then
                        local orig_url
                        orig_url=$(awk -F'|' -v f="$fn" '$1==f{print $2; exit}' "$SESSION_DIR/state/url-map.txt" 2>/dev/null)
                        [ -z "$orig_url" ] && orig_url="unknown-source:${fn}"
                        find "$SESSION_DIR/state/tmp/deobf/$bname" -name '*.js' | while IFS= read -r df; do
                            local dn="deobf_${bname}_$(basename "$df" .js | tr -cd 'a-zA-Z0-9' | cut -c1-24).js"
                            cp "$df" "$SESSION_DIR/js/deobf/$dn"
                            ( flock -w 10 200 || exit 1
                              echo "$dn|${orig_url}|deobfuscated" >> "$SESSION_DIR/state/url-map.txt"
                            ) 200>"$SESSION_DIR/state/.urlmap.lock"
                        done
                    fi
                done
            fi
            rm -f "$SESSION_DIR/state/tmp/.obf-hits-round.txt"
        fi

        if command -v npx &>/dev/null; then
            find "$SESSION_DIR/js/raw" -name '*.js' -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
                local base dest
                base=$(basename "$f")
                dest="$SESSION_DIR/js/formatted/$base"
                [ -e "$dest" ] || cp -- "$f" "$dest" 2>/dev/null
            done
            find "$SESSION_DIR/js/formatted" -name '*.js' -type f -printf '%f\n' 2>/dev/null | sort > "$SESSION_DIR/state/tmp/.pretty-all.txt"
            comm -23 "$SESSION_DIR/state/tmp/.pretty-all.txt" <(sort -u "$SESSION_DIR/state/pretty-done.txt" 2>/dev/null) > "$SESSION_DIR/state/tmp/.pretty-new.txt"
            : > "$SESSION_DIR/state/tmp/.pretty-list"
            while IFS= read -r fb; do
                [ -s "$SESSION_DIR/state/obf-hits.txt" ] && grep -Fqx "$fb" "$SESSION_DIR/state/obf-hits.txt" 2>/dev/null && continue
                local fsize ph
                fsize=$(wc -c < "$SESSION_DIR/js/formatted/$fb" 2>/dev/null | tr -d ' ')
                [ -z "$fsize" ] && continue
                ph=$(sha256sum "$SESSION_DIR/js/formatted/$fb" 2>/dev/null | awk '{print $1}')
                [ -n "$ph" ] && [ -s "$SESSION_DIR/state/pretty-hashes.txt" ] && grep -Fqx "$ph" "$SESSION_DIR/state/pretty-hashes.txt" 2>/dev/null && continue
                [ -n "$ph" ] && printf '%s\n' "$ph" >> "$SESSION_DIR/state/pretty-hashes.txt"
                if [ "$fsize" -le $((PRETTIER_MAX_MB * 1024 * 1024)) ]; then
                    printf '%s\0' "$SESSION_DIR/js/formatted/$fb" >> "$SESSION_DIR/state/tmp/.pretty-list"
                fi
            done < "$SESSION_DIR/state/tmp/.pretty-new.txt"
            cat "$SESSION_DIR/state/pretty-done.txt" "$SESSION_DIR/state/tmp/.pretty-new.txt" 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.pretty-final.txt" && mv "$SESSION_DIR/state/tmp/.pretty-final.txt" "$SESSION_DIR/state/pretty-done.txt"
            local p_eligible
            p_eligible=$(tr -dc '\0' < "$SESSION_DIR/state/tmp/.pretty-list" | wc -c | tr -d ' ')
            if [ "$p_eligible" -gt 0 ]; then
                out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ prettier${C_R} --parser babel --write <files>   (xargs -0 -n $PRETTIER_BATCH -P $PRETTIER_JOBS, $p_eligible files)"
                xargs -0 -n "$PRETTIER_BATCH" -P "$PRETTIER_JOBS" bash -c 'nice -n 15 ionice -c2 -n7 timeout --foreground 120 npx prettier --parser babel --write "$@" >/dev/null 2>&1' _ < "$SESSION_DIR/state/tmp/.pretty-list" || true
            fi
            rm -f "$SESSION_DIR/state/tmp/.pretty-list"
        else
            find "$SESSION_DIR/js/raw" -name '*.js' -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
                local base dest
                base=$(basename "$f")
                dest="$SESSION_DIR/js/formatted/$base"
                [ -e "$dest" ] || cp -- "$f" "$dest" 2>/dev/null
            done
        fi

        _discf=$(find "$SESSION_DIR/js/raw" "$SESSION_DIR/js/deobf" "$SESSION_DIR/js/formatted" -type f -newer "$SESSION_DIR/state/tmp/.disc-marker" -print0 2>/dev/null)
        {
            if command -v rg &>/dev/null; then
                printf '%s' "$_discf" | xargs -0 -r rg --no-ignore --hidden -a -o -n -P -e 'https?://[^\s\x22\x27`<>()]+\.(js|mjs)(\?[^\s\x22\x27`<>()]*)?' -e '(?<![a-zA-Z0-9:])//[a-zA-Z0-9.-]+/[a-zA-Z0-9_/.-]+\.(js|mjs)(\?[^\s\x22\x27`<>()]*)?' -e 'import\(\s*[\x22\x27`]\K[^\x22\x27`]+?\.(?:js|mjs)(?=[\x22\x27`]\s*\))' 2>/dev/null | awk '{sub(/^[^:]+:[0-9]+:/, ""); print}' | sed 's|^//|https://|' | grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)"
            else
                printf '%s' "$_discf" | xargs -0 -r grep -a -h -o -P 'https?://[^\s\x22\x27`<>()]+\.(js|mjs)(\?[^\s\x22\x27`<>()]*)?' 2>/dev/null
                printf '%s' "$_discf" | xargs -0 -r grep -a -h -o -P '(?<![a-zA-Z0-9:])//[a-zA-Z0-9.-]+/[a-zA-Z0-9_/.-]+\.(js|mjs)(\?[^\s\x22\x27`<>()]*)?' 2>/dev/null | sed 's|^//|https://|'
            fi
        } | grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" | sort -u > "$SESSION_DIR/state/tmp/.rec-new.txt"
        _wsc=$( _webpack_scan 2>/dev/null || true )
        if [ -n "$_wsc" ]; then
            { cat "$SESSION_DIR/state/tmp/.rec-new.txt"; printf '%s\n' "$_wsc"; } | sort -u > "$SESSION_DIR/state/tmp/.rec-new.2.txt" && mv "$SESSION_DIR/state/tmp/.rec-new.2.txt" "$SESSION_DIR/state/tmp/.rec-new.txt"
        fi
        awk -F'|' '{print $2}' "$SESSION_DIR/state/url-map.txt" 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.rec-fetched.txt"
        sort -u "$SESSION_DIR/state/tmp/.js-discovered.txt" 2>/dev/null > "$SESSION_DIR/state/tmp/.rec-known.txt" || true
        comm -23 "$SESSION_DIR/state/tmp/.rec-new.txt" "$SESSION_DIR/state/tmp/.rec-fetched.txt" | comm -23 - "$SESSION_DIR/state/tmp/.rec-known.txt" > "$SESSION_DIR/state/tmp/.rec-pending.txt"
        local pending_disc
        pending_disc=$(wc -l < "$SESSION_DIR/state/tmp/.rec-pending.txt" | tr -d ' ')
        rm -f "$SESSION_DIR/state/tmp/.rec-new.txt" "$SESSION_DIR/state/tmp/.rec-fetched.txt" "$SESSION_DIR/state/tmp/.rec-known.txt"
        if [ "$pending_disc" -eq 0 ]; then
            rm -f "$SESSION_DIR/state/tmp/.rec-pending.txt"
            out "${C_W}Fixpoint reached — no new JS${C_R}"
            break
        fi
        out "${C_Y}$pending_disc new JS chunks queued for next round${C_R}"
        cat "$SESSION_DIR/state/tmp/.rec-pending.txt" >> "$SESSION_DIR/state/tmp/.js-discovered.txt"
        rm -f "$SESSION_DIR/state/tmp/.rec-pending.txt"
        touch "$SESSION_DIR/state/tmp/.disc-marker"
    done

    [ -s "$SESSION_DIR/state/tmp/.js-failed.txt" ] && comm -23 <(sort -u "$SESSION_DIR/state/tmp/.js-failed.txt") <(awk -F'|' '{print $2}' "$SESSION_DIR/state/url-map.txt" 2>/dev/null | sort -u) > "$SESSION_DIR/findings/probes/urls-failed.txt"
    rm -f "$SESSION_DIR/state/tmp/.js-failed.txt"
    rm -f "$SESSION_DIR/state/tmp/.js-round-seeds.txt" "$SESSION_DIR/state/tmp/.js-pending.txt" "$SESSION_DIR/state/tmp/.js-done-urls.txt" "$SESSION_DIR/state/tmp/.js-round-fetched.txt" "$SESSION_DIR/state/tmp/.js-discovered.txt" "$SESSION_DIR/state/tmp/.sm-all.txt" "$SESSION_DIR/state/tmp/.sm-new.txt" "$SESSION_DIR/state/tmp/.obf-all.txt" "$SESSION_DIR/state/tmp/.obf-new.txt" "$SESSION_DIR/state/tmp/.pretty-all.txt" "$SESSION_DIR/state/tmp/.pretty-new.txt" "$SESSION_DIR/state/api-sampled.txt"


}
st_analysis_local() {
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ jsluice${C_R} secrets + urls: find js/{raw,deobf,mapsrc,json} -type f -size -20M \( -name '*.js' -o -name '*.json' \) | xargs -0 -P $PRETTIER_JOBS -n 1 bash -c 'jsluice secrets + jsluice urls' _"
    mkdir -p "$SESSION_DIR/state/tmp/jsluice-out"
    : > "$SESSION_DIR/state/tmp/jsluice-failed.txt"
    : > "$SESSION_DIR/findings/secrets/jsluice-secrets.txt"
    : > "$SESSION_DIR/findings/surface/jsluice-endpoints.txt"
    find "$SESSION_DIR/js/raw" "$SESSION_DIR/js/deobf" "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/json" -type f -size -55M \( -name '*.js' -o -name '*.json' \) -print0 2>/dev/null | xargs -0 -r -P "$PRETTIER_JOBS" -n 1 bash -c '
        f="$1"; d="'"$SESSION_DIR/state/tmp/jsluice-out"'/$(printf "%s" "$f" | md5sum | cut -c1-12)"
        mkdir -p "$d"
        nice -n 15 jsluice secrets "$f" > "$d/secrets.jsonl" 2> "$d/secrets.err" || printf "%s\n" "$f" >> "'"$SESSION_DIR/state/tmp"'/jsluice-failed.txt"
        _org=$(awk -F"|" -v ff="$(basename "$f")" "\$1==ff{print \$2; exit}" "'"$SESSION_DIR"'/state/url-map.txt" 2>/dev/null)
        if [ -n "$_org" ]; then
            nice -n 15 jsluice urls -R "$_org" "$f" > "$d/urls.jsonl" 2> "$d/urls.err" || true
        else
            nice -n 15 jsluice urls "$f" > "$d/urls.jsonl" 2> "$d/urls.err" || true
        fi
    ' _
    find "$SESSION_DIR/state/tmp/jsluice-out" -name secrets.jsonl -exec cat {} + 2>/dev/null | jq -r 'select(.kind != null) | "\(.filename // .file // "?") :: \(.kind) :: \(.data | tostring | .[0:120])"' 2>/dev/null | awk -F' :: ' -v sidecar="$SESSION_DIR/state/value-locations.tsv" '{if(NF>=3){k=$2" :: "$3; if(k in seen){if($1!="")printf "%s\t%s\n",k,$1 >> sidecar;next} seen[k]=1} print}' | sort -u > "$SESSION_DIR/findings/secrets/jsluice-secrets.txt"
    find "$SESSION_DIR/state/tmp/jsluice-out" -name urls.jsonl -exec cat {} + 2>/dev/null | jq -r '.url? // empty' 2>/dev/null | sed -E 's|^https?://[^/]+||' | grep -E '^/' | sort -u > "$SESSION_DIR/findings/surface/jsluice-endpoints.txt"
    local _jsfail_count _jsraw_count
    _jsfail_count=$(wc -l < "$SESSION_DIR/state/tmp/jsluice-failed.txt" 2>/dev/null | tr -d ' '); _jsfail_count=${_jsfail_count:-0}
    [ "$_jsfail_count" -gt 0 ] && warn_rc "jsluice ($_jsfail_count files failed)" 1
    _jsraw_count=$(find "$SESSION_DIR/js/raw" "$SESSION_DIR/js/mapsrc" -name '*.js' -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "${_jsraw_count:-0}" -gt 50 ] && [ ! -s "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" ]; then
        out "${C_Y}[warn] jsluice produced 0 endpoints from $_jsraw_count files -- invocation may have changed${C_R}"
    fi
    rm -rf "$SESSION_DIR/state/tmp/jsluice-out" "$SESSION_DIR/state/tmp/jsluice-failed.txt"
    local _jsec _jep
    _jsec=$(wc -l < "$SESSION_DIR/findings/secrets/jsluice-secrets.txt" 2>/dev/null | tr -d ' '); _jsec=${_jsec:-0}
    _jep=$(wc -l < "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" 2>/dev/null | tr -d ' '); _jep=${_jep:-0}

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ trufflehog${C_R} filesystem js/raw js/mapsrc js/deobf --json | jq -r '[file, match, detector] | join(::) > trufflehog.txt || true"
    nice -n 15 timeout --foreground 1200 trufflehog filesystem "$SESSION_DIR/js/raw" "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/deobf" "$SESSION_DIR/js/json" "$SESSION_DIR/js/artifacts" --json 2>/dev/null \
      | jq -r '[.SourceMetadata.Data.Filesystem.file // "unknown", (.Redacted // .Raw // "" | gsub("\n";" ") | .[0:160]), .DetectorName, (if .Verified == true then "VERIFIED" else "-" end)] | join("::")' 2>/dev/null \
      | sed -e 's|js/raw/||' -e 's|js/mapsrc/||' -e 's|js/deobf/||' -e 's|js/json/||' -e 's|js/artifacts/||' \
      | awk -F'::' -v sidecar="$SESSION_DIR/state/value-locations.tsv" '{k=($2==""?$0:$2); if(k in seen){if($1!="")printf "%s\t%s\n",k,$1 >> sidecar;next} seen[k]=1; print}' | sort -u > "$SESSION_DIR/findings/secrets/trufflehog.txt" || warn_rc "trufflehog" 1
    local th_count
    th_count=$(wc -l < "$SESSION_DIR/findings/secrets/trufflehog.txt" 2>/dev/null | tr -d ' '); th_count=${th_count:-0}

    if command -v gitleaks &>/dev/null; then
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ gitleaks${C_R} detect --source js/ --no-git --report-format json"
        nice -n 15 timeout --foreground 1800 gitleaks detect --source "$SESSION_DIR/js" --no-git --report-format json --report-path "$SESSION_DIR/state/tmp/gitleaks.json" >/dev/null 2>&1 || { _grc=$?; [ "$_grc" -gt 1 ] && warn_rc "gitleaks" "$_grc"; }
        jq -r '.[] | "\(.File // "?")::\(.RuleID // .Description // "?")::\((.Match // .Secret // "") | .[0:120])"' "$SESSION_DIR/state/tmp/gitleaks.json" 2>/dev/null | sort -u > "$SESSION_DIR/findings/secrets/gitleaks.txt"
        rm -f "$SESSION_DIR/state/tmp/gitleaks.json"
    else
        out "${C_Y}[warn] gitleaks not installed -- skipping${C_R}"
    fi


    if command -v noseyparker &>/dev/null; then
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ noseyparker${C_R} scan --datastore np-data js/ && noseyparker report"
        rm -rf "$SESSION_DIR/state/tmp/np-data"
        nice -n 15 timeout --foreground 900 noseyparker scan --datastore "$SESSION_DIR/state/tmp/np-data" "$SESSION_DIR/js" >/dev/null 2>"$SESSION_DIR/state/tmp/np.err" || warn_rc "noseyparker" "$?"
        if [ ! -d "$SESSION_DIR/state/tmp/np-data" ]; then
            out "${C_Y}[warn] noseyparker produced no datastore -- stderr: $(tail -2 "$SESSION_DIR/state/tmp/np.err" 2>/dev/null | tr '\n' ' | ' | cut -c1-160)${C_R}"
        fi
        nice -n 15 timeout --foreground 300 noseyparker report --datastore "$SESSION_DIR/state/tmp/np-data" > "$SESSION_DIR/findings/secrets/noseyparker.txt" 2>/dev/null || true
        rm -rf "$SESSION_DIR/state/tmp/np-data" "$SESSION_DIR/state/tmp/np.err"
    else
        out "${C_Y}[warn] noseyparker not installed -- skipping${C_R}"
    fi


    if command -v syft &>/dev/null && command -v grype &>/dev/null; then
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ syft${C_R} dir:<manifest-dir> -o json > sbom.json && grype sbom sbom.json   (when a package manifest leaks into the corpus)"
        _syft_root=""
        _syft_manifest=$(find "$SESSION_DIR/js" -maxdepth 4 \( -name package.json -o -name package-lock.json -o -name yarn.lock -o -name pnpm-lock.yaml \) -print -quit 2>/dev/null | head -1)
        [ -n "$_syft_manifest" ] && _syft_root=$(dirname "$_syft_manifest")
        if [ -n "$_syft_root" ]; then
            nice -n 15 timeout --foreground 600 syft dir:"$_syft_root" -o json > "$SESSION_DIR/state/tmp/sbom.json" 2>/dev/null || warn_rc "syft" 1
            nice -n 15 timeout --foreground 600 grype sbom:"$SESSION_DIR/state/tmp/sbom.json" -o json > "$SESSION_DIR/state/tmp/grype.json" 2>/dev/null || warn_rc "grype" 1
        else
            out "${C_W}syft/grype skipped -- no package manifests anywhere in the corpus (retire covers bundled-lib CVEs)${C_R}"
        fi
        jq -r '.matches[]? | "vuln|\(.artifact.name)@\(.artifact.version)|\(.vulnerability.id)|\(.vulnerability.severity)"' "$SESSION_DIR/state/tmp/grype.json" 2>/dev/null | sort -u > "$SESSION_DIR/findings/analysis/grype.txt"
        rm -f "$SESSION_DIR/state/tmp/sbom.json" "$SESSION_DIR/state/tmp/grype.json"
        local _gc
        _gc=$(wc -l < "$SESSION_DIR/findings/analysis/grype.txt" 2>/dev/null | tr -d ' '); _gc=${_gc:-0}
    else
        out "${C_Y}[warn] syft/grype not installed -- skipping${C_R}"
    fi

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ rg${C_R}/grep -P -o '<55+ secret/sink patterns>' over js/{formatted,mapsrc,deobf,json,artifacts} + entropy filter + cross-file value dedup"
    : > "$SESSION_DIR/findings/type-map.txt"
    mkdir -p "$SESSION_DIR/findings/secrets"

    hunt() {
        local msg="$1" regex="$2" outfile="$3" exclude="${4:-}" severity="${5:-MEDIUM}" minent="${6:-0}" subdir="${7:-secrets}"
        printf '%s|%s|%s\n' "$outfile" "$msg" "$severity" >> "$SESSION_DIR/findings/type-map.txt"
        local raw=""
        for rep in formatted mapsrc deobf json artifacts sourcemaps; do
            [ -d "$SESSION_DIR/js/$rep" ] || continue
            local chunk
            if command -v rg &>/dev/null; then
                chunk=$(cd "$SESSION_DIR/js/$rep" && rg --no-ignore --hidden -a -n -P -o -e "$regex" . 2>/dev/null | sed 's|^\./||')
            else
                chunk=$(cd "$SESSION_DIR/js/$rep" && grep -a -r -n -P -o -e "$regex" . 2>/dev/null | sed 's|^\./||')
            fi
            [ -n "$chunk" ] && raw="$raw"$'\n'"$chunk"
        done
        if [ -n "$exclude" ] && [ -n "$raw" ]; then
            raw=$(printf '%s\n' "$raw" | HUNT_EXCLUDE="$exclude" awk 'BEGIN{pat=tolower(ENVIRON["HUNT_EXCLUDE"])}{val=$0; sub(/^[^:]*:[0-9]*:/, "", val); if(tolower(val) !~ pat) print}')
        fi
        if [ "$minent" != "0" ] && [ -n "$raw" ]; then
            raw=$(printf '%s\n' "$raw" | awk -F: -v me="$minent" '{m="";for(i=3;i<=NF;i++)m=m $i (i<NF?":":"");s=m;n=length(s);if(n<16)next;delete c;for(i=1;i<=n;i++)c[substr(s,i,1)]++;e=0;for(k in c){p=c[k]/n;e-=p*log(p)};e=e/log(2);if(e+0>=me+0)print}')
        fi
        printf '%s\n' "$raw" | awk 'NF' | sort -u > "$SESSION_DIR/findings/$subdir/$outfile"
    }

    hunt "Cloud & SaaS tokens" '\b(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[a-zA-Z0-9]{36}|github_pat_[a-zA-Z0-9_]{22,}|ghs_[a-zA-Z0-9]{36}|ghr_[a-zA-Z0-9]{36}|AIza[0-9A-Za-z\-_]{35}|xox[baprs]-[0-9a-zA-Z-]{10,}|xapp-1-[0-9a-zA-Z-]{10,}|SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}|glpat-[0-9A-Za-z_-]{20,}|glrt-[0-9A-Za-z_-]{20,}|npm_[A-Za-z0-9]{36}|pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{40,}|hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+|discord(app)?\.com/api/webhooks/[0-9]{15,}/[A-Za-z0-9_-]{50,}|[0-9]{8,10}:AA[A-Za-z0-9_-]{33}|sk_live_[0-9a-zA-Z]{24}|rk_live_[0-9a-zA-Z]{24}|whsec_[A-Za-z0-9]{20,}|rzp_(?:live|test)_[A-Za-z0-9]{14,}|EAAA[0-9A-Za-z_-]{60}|shp(?:at|ss|ca|pa)_[a-fA-F0-9]{32}|hvs\.[A-Za-z0-9_-]{80,}|[0-9A-Za-z]{14}\.atlasv1\.[0-9A-Za-z_-]{60,}|squ_[0-9a-f]{40}|11[0-9a-f]{32}|dop_v1_[a-f0-9]{64}|SK[0-9a-f]{32}|(?:FQoGZXIvYXdz|FwoGZXIvYXdz|IQoJb3JpZ2luX2Vj)[A-Za-z0-9/+=]+|sk-(?!(?:live|test)_)[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{60,}|sk-ant-[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{30,}|gsk_[A-Za-z0-9]{30,}|r8_[A-Za-z0-9]{30,}|sk-or-[A-Za-z0-9_-]{20,}|1//[0-9A-Za-z_-]{40,}|ya29\.[0-9A-Za-z_-]+|EAAB[0-9A-Za-z]+|sl\.[A-Za-z0-9_-]{100,})\b' "cloud-tokens.txt" '(EXAMPLE|YOUR_API_KEY|XXXX|SAMPLE|dummy|placeholder)' "CRITICAL" "3.0"
    hunt "Private keys" '-----BEGIN[A-Z ]*(?:PRIVATE KEY|SECRET KEY)[A-Z ]*-----' "private-keys.txt" "" "CRITICAL"
    hunt "DB credentials in URIs" '((?:mongodb(?:\+srv)?|postgres(?:ql)?|mysql|redis|rediss|amqps?|mssql|neo4j|couchbase|cassandra|cql|influxdb|clickhouse|tidb|scylla)://[^\s\x22\x27@/]{1,64}:[^\s\x22\x27@]{1,128}@)' "db-creds.txt" "" "CRITICAL"
    hunt "Basic auth URLs" 'https?://[a-zA-Z0-9_-]+:[^\s\x22\x27@]{3,}@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "basic-auth.txt" "" "CRITICAL"
    hunt "Signing secrets" '(?i)(jwt[_-]?secret|session[_-]?secret|cookie[_-]?secret|csrf[_-]?secret|hmac[_-]?secret|webhook[_-]?secret|encryption[_-]?key|aes[_-]?key|signing[_-]?key|secret[_-]?key)[\x22\x27\s]*[:=][\x22\x27\s]*[\x22\x27]?[A-Za-z0-9/_+=.-]{16,}[\x22\x27]?' "signing-secrets.txt" '(undefined|null|true|false|process\.env|example|changeme|your[_-]|placeholder)' "CRITICAL" "3.2"
    hunt "URL secrets" 'https?://[^\s\x22\x27<>]+\?(?:[a-z_]*(?:token|key|secret|password|auth)[a-z_]*)=[^\s&\x22\x27<>]{8,}' "url-secrets.txt" '(example|placeholder|your[_-]|test|demo)' "HIGH" "3.0"
    hunt "OAuth client secrets" '(?i)client_secret[\x22\x27\s]*[:=][\x22\x27\s]*[A-Za-z0-9\-_]{10,}' "oauth-secrets.txt" '(undefined|null|example|your[_-]|placeholder)' "HIGH" "3.0"
    hunt "JWT & Bearer" '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?![A-Za-z0-9_-])|(?<![A-Za-z0-9])Bearer\s+[A-Za-z0-9\-\._~+/]{20,}' "auth-tokens.txt" "" "HIGH"
    hunt "Azure keys" 'AccountKey=[A-Za-z0-9+/]{60,}={0,2}' "azure-keys.txt" "" "HIGH"
    hunt "Google service accounts" '"type"\s*:\s*"service_account"|"private_key_id"\s*:\s*"[0-9a-f]{16,}"|[a-z0-9._-]+@[a-z0-9.-]+\.iam\.gserviceaccount\.com' "service-accounts.txt" "" "HIGH"
    hunt "Payment tokens" '\b(sk_live_[0-9a-zA-Z]{24}|rk_live_[0-9a-zA-Z]{24}|whsec_[A-Za-z0-9]{20,}|rzp_(?:live|test)_[A-Za-z0-9]{14,}|EAAA[0-9A-Za-z_-]{60}|shp(?:at|ss|ca|pa)_[a-fA-F0-9]{32})\b' "payment-webhooks.txt" '(test|example)' "HIGH" "3.0"
    hunt "AI/LLM keys" '\b(sk-(?!(?:live|test)_)[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{60,}|sk-ant-[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{30,}|gsk_[A-Za-z0-9]{30,}|r8_[A-Za-z0-9]{30,}|sk-or-[A-Za-z0-9_-]{20,})\b' "ai-keys.txt" '(example|test|placeholder)' "HIGH" "3.0"
    hunt "DevOps tokens" '\b(ghs_[a-zA-Z0-9]{36}|ghr_[a-zA-Z0-9]{36}|hvs\.[A-Za-z0-9_-]{80,}|[0-9A-Za-z]{14}\.atlasv1\.[0-9A-Za-z_-]{60,}|squ_[0-9a-f]{40}|11[0-9a-f]{32}|glrt-[0-9A-Za-z_-]{20,}|pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{40,}|dop_v1_[a-f0-9]{64})\b' "devops-tokens.txt" '(example|test)' "HIGH" "3.0"
    hunt "SaaS tokens" '\b(secret_[A-Za-z0-9]{40,}|dapi[0-9a-f]{32}|AKC[A-Z0-9]{10,}|AP6[A-Z0-9]{10,}|AP7[A-Z0-9]{10,}|nvapi-[A-Za-z0-9_-]{40,})\b' "saas-tokens.txt" '(example|test)' "HIGH" "3.0"
    hunt "Third-party webhooks" '(webhook\.office\.com/webhookb2/[A-Za-z0-9_-]+@[A-Za-z0-9_-]+/IncomingWebhook/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+|chat\.googleapis\.com/v1/spaces/[A-Za-z0-9_-]+/messages\?key=[A-Za-z0-9_-]+&token=[A-Za-z0-9_-]+|hooks\.zapier\.com/hooks/catch/[0-9]+/[A-Za-z0-9_-]+|maker\.ifttt\.com/trigger/[A-Za-z0-9_-]+/with/key/[A-Za-z0-9_-]+)' "tp-webhooks.txt" "" "HIGH"
    hunt "Hardcoded bearer" '[\x22\x27]Bearer\s+[A-Za-z0-9\-\._~+/=-]{20,}[\x22\x27]' "hardcoded-bearer.txt" '(example|test)' "HIGH" "3.0"
    hunt "Presigned S3" 'https?://[^"'"'"'\s]+[?&]X-Amz-Signature=[^"'"'"'\s]+' "presigned-urls.txt" "" "HIGH"
    hunt "SMTP creds" '(?i)(?:smtp|mail)[_-]?(?:user(?:name)?|pass(?:word)?|host)[\x22\x27\s]*[:=][\x22\x27\s]*[\x22\x27]?[^\s\x22\x27]{6,}[\x22\x27]?' "smtp-creds.txt" '(example|test|your|localhost|smtp\.gmail)' "MEDIUM" "2.8"
    hunt "Algolia/Pusher" '(?i)(?:algolia|pusher)[\w\s]{0,30}(?:app[_-]?id|api[_-]?key|secret|key)[\x22\x27\s]*[:=][\x22\x27\s]*[A-Za-z0-9]{10,}' "baas-pairs.txt" "(example|test)" "MEDIUM" "3.0"
    hunt "Sentry/Cloudinary/Mapbox" '(https://[0-9a-f]{32}@[a-z0-9.-]*sentry\.io/[0-9]+|cloudinary://[0-9]+:[A-Za-z0-9_-]+@[A-Za-z0-9_-]+|(?:pk|sk)\.eyJ1Ijo[A-Za-z0-9_.-]{50,})' "sdk-configs.txt" "" "MEDIUM"
    hunt "Cognito Pool IDs" '[a-z]{2}(?:-gov)?-[a-z]+-[0-9]{1,2}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "cognito-pools.txt" "" "MEDIUM"
    hunt "S3 buckets" '\b[a-z0-9][a-z0-9.-]*\.s3([.-][a-z0-9-]+)?\.amazonaws\.com\b|s3://[a-zA-Z0-9.-]+' "s3-buckets.txt" "(example|amazonaws\.com/s3|aws-sdk)" "MEDIUM"
    hunt "Firebase/Supabase/Appwrite" '[a-zA-Z0-9.-]+\.(firebaseio\.com|firebaseapp\.com|supabase\.co|appwrite\.io)' "baas-urls.txt" "" "MEDIUM"
    hunt "Internal hostnames" '(?<![\w.])([a-z0-9][a-z0-9-]{2,62}\.(?:internal|corp|local|intranet)(?=[/:?#\x22\x27)\],]|$))' "internal-hosts.txt" "" "MEDIUM"
    hunt "Debug endpoints" '(/actuator/(?:env|heapdump|beans|configprops|mappings|threaddump)|/debug/pprof|/debug/vars|/_debug/vars)' "debug-endpoints.txt" "" "MEDIUM"
    hunt "Source maps" 'sourceMappingURL\s*=\s*\K[^\s\x22\x27]+\.map' "source-maps.txt" "" "MEDIUM"
    hunt "DOM XSS sinks" '(?<![A-Za-z0-9_$])(?:[A-Za-z_$][\w$]*\.(?:innerHTML|outerHTML|srcdoc)\s*=|[A-Za-z_$][\w$]*\.insertAdjacentHTML\s*\(|document\.write(?:ln)?\s*\(|\beval\s*\(|new\s+Function\s*\(|\$\([^)]*\)\.html\s*\(|(?:location(?:\.href)?|window\.location)\s*=(?!=)|location\.(?:replace|assign)\s*\(|window\.open\s*\(|document\.domain\s*=|(?:setTimeout|setInterval)\s*\(\s*["'"'"'`]|execScript\s*\()' "dom-sinks.txt" "" "MEDIUM"
    hunt "Framework sinks" 'dangerouslySetInnerHTML\s*=|\bv-html\s*=|bypassSecurityTrust(?:Html|Style|Script|Url|ResourceUrl)\s*\(' "framework-sinks.txt" "" "HIGH"
    hunt "postMessage listeners" 'addEventListener\s*\(\s*[\x22\x27`]message[\x22\x27`]|\.onmessage\s*=' "postmessage-listeners.txt" "" "MEDIUM"
    hunt "Hidden paths" '(?<=[\x22\x27\`])(/(?:api|admin|v[0-9]|internal|graphql|dev|staging|auth|login|users|config|payment|upload|download)[a-zA-Z0-9_/?=&.-]*)(?=[\x22\x27\`])' "hidden-paths.txt" "" "MEDIUM"
    hunt "OAuth client IDs" '(?i)client_id[\x22\x27\s]*[:=][\x22\x27\s]*[A-Za-z0-9\-_]{10,}|\d+[a-z0-9_-]*\.apps\.googleusercontent\.com' "oauth-ids.txt" '(undefined|null|example)' "INFO"
    hunt "GraphQL ops" '(query|mutation)\s+[a-zA-Z0-9_]+\s*\{' "graphql.txt" "" "INFO"
    hunt "Dev comments" '(?<=//|/\*)\s*(TODO|FIXME|HACK|BUG|XXX)[^\r\n]{0,120}' "dev-comments.txt" "" "INFO"
    hunt "WebSockets" 'wss?://[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}[a-zA-Z0-9/=?&._~:%-]*' "websockets.txt" '(localhost|example)' "INFO"
    hunt "Emails" '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "emails.txt" '(sentry\.io|example\.|w3\.org|@2x|@3x|aa@yy\.xyz|somethingdoug|shtylman|onur\.cakmak|^user@site)' "INFO"
    hunt "IPs" '\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b' "ip-addresses.txt" '(0\.0\.0\.0|127\.0\.0\.1|192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.|255\.255)' "INFO"
    hunt "Debug flags" '(?i)\bdebug\b\s*[:=]\s*[\x22\x27]?(true|1)' "debug-flags.txt" '(example)' "INFO"
    hunt "External URLs" 'https?://[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}[a-zA-Z0-9/=?&._~:%-]*' "js-external-urls.txt" '(w3\.org|react\.dev|localhost|github\.com|github\.io|npmjs\.com|mozilla\.org|example\.com|stackoverflow\.com|googleapis\.com|gstatic\.com|cloudflare\.com|jsdelivr\.net|unpkg\.com|google-analytics\.com|googletagmanager\.com|facebook\.net|facebook\.com|twitter\.com|x\.com|wikimedia\.org|wikipedia\.org|flagcdn\.com|whatwg\.org|rfc-editor\.org|iana\.org|ecma-international\.org|unicode\.org|crisp\.chat|sentry-cdn|sentry\.io|nextjs\.org|redux(-toolkit)?\.js\.org|ckeditor\.com|formatjs\.io|json-schema\.org|socket\.io|caniuse\.com|bugs\.(chromium|webkit)\.org|csrc\.nist\.gov|opensource\.org|aomedia\.org|w3ctech\.com|evilmartians\.com|npms\.io|lodash\.com|underscorejs\.org|date-fns|react-dnd\.github\.io|base-ui\.com|litix\.io|fengyuanchen\.github\.io|docs\.strapi\.io|strapi\.io|developer\.chrome\.com|developers\.google\.com|firebase\.google\.com|web\.dev|schema\.org|play\.google\.com|apps\.apple\.com|youtube\.com|facebook\.com|instagram\.com|tiktok\.com|linkedin\.com|wa\.me|spotify\.com|vimeo\.com|dailymotion\.com|\.png|\.jpe?g|\.gif|\.svg|\.webp|\.avif|\.ico|\.woff2?|\.ttf|\.css)(\?|$)' "INFO"
    hunt "Generic secrets" '(?i)(api[_-]?key|apikey|secret|token|password|auth[_-]?token)[\x22\x27\s]*[:=][\x22\x27\s]*[A-Za-z0-9\-_=]{16,}' "generic-secrets.txt" '(undefined|null|true|false|function|your[a-z0-9_-]*|changeme|placeholder|dummy|redacted|x{8,}|\*{8,}|123456789|example|[:=][[:space:]]*[\x22\x27]?[_$][a-zA-Z0-9_$]+[\x22\x27]?$)' "MEDIUM" "3.4"
    hunt "Cloud keys II" '\b(oci1\.[a-z0-9]{15,}|LTAI[A-Za-z0-9]{12,}|cf_[a-zA-Z0-9_]{30,}|dckr_pat_[A-Za-z0-9_-]{20,}|fo1_[A-Za-z0-9_]{30,}|scw_[a-f0-9]{30,}|hcloud_[A-Za-z0-9]{30,}|do_pat_[A-Za-z0-9_-]{40,}|vultr_[a-f0-9]{30,})\b' "cloud-keys-2.txt" '(example|test)' "CRITICAL" "3.0"
    hunt "Comms API keys" '\b(key-[0-9a-f]{32}|AC[0-9a-f]{32}:[0-9a-f]{32}|pm_[a-zA-Z0-9]{20,}|mg\.[A-Za-z0-9]{20,}|mc\.[a-f0-9]{32}|plivo_[a-zA-Z0-9]{30,}|vonage[-_][a-z0-9]{20,}|ably-[a-zA-Z0-9_-]{30,}|pub-[a-f0-9]{32}|sub-[a-f0-9]{32}|bird_[a-zA-Z0-9]{20,})\b' "comms-keys.txt" '(test|example)' "CRITICAL" "3.0"
    hunt "Auth provider tokens" '\b(00[A-Za-z0-9_-]{40}|ssws [A-Za-z0-9=_-]{20,}|eyJhbGciOiJSUzI1NiIsImtpZCI6[A-Za-z0-9_-]{10,})\b' "auth-provider.txt" "(test)" "CRITICAL" "3.2"
    hunt "Payments & crypto" '\b(sq0atp-[0-9A-Za-z_-]{22,}|sq0csp-[0-9A-Za-z_-]{43,}|A21AA[A-Za-z0-9_-]{20,}|sk\.live\.[A-Za-z0-9]{20,}|0x[a-fA-F0-9]{64}|cb_[a-z0-9]{20,})\b' "payments-crypto.txt" '(test|example)' "CRITICAL" "3.0"
    hunt "AI/LLM keys II" '\b(pplx-[A-Za-z0-9]{20,}|co_[A-Za-z0-9]{20,}|tvly-[A-Za-z0-9]{20,}|jina_[A-Za-z0-9]{20,}|fw_[A-Za-z0-9]{20,}|lsv2_[A-Za-z0-9_]{20,}|pk-lf-[a-f0-9]{20,}|sk-lf-[a-f0-9]{20,}|xi-[a-zA-Z0-9]{20,}|sk-or-[A-Za-z0-9_-]{20,})\b' "ai-keys-2.txt" '(example|test)' "CRITICAL" "3.0"
    hunt "Registry & CI keys" '\b(dckr_pat_[A-Za-z0-9_-]{20,}|gho_[A-Za-z0-9]{36}|ghu_[A-Za-z0-9]{36}|ATAT[A-Za-z0-9_-]{20,}|ATBB[A-Za-z0-9_-]{20,}|snyk_[A-Za-z0-9]{20,}|rubygems_[A-Za-z0-9]{20,}|cirlce[_-]?token)\b' "registry-ci.txt" '(test|example)' "HIGH" "3.0"
    hunt "Signed cloud URLs II" 'https?://storage\.googleapis\.com/[^\s"'"'"'<>]+\?[^\s"'"'"'<>]*signature=[^\s"'"'"'<>]+|https?://[^\s"'"'"'<>]*\.windows\.net[^\s"'"'"'<>]*sig=[A-Za-z0-9%]{20,}' "signed-urls-2.txt" "" "HIGH"
    hunt "Private key blocks II" '-----BEGIN (EC|OPENSSH|DSA|PGP PRIVATE|ENCRYPTED PRIVATE|SSH2 ENCRYPTED)[ A-Z]*-----|"kty"\s*:\s*"(RSA|EC|oct)"' "private-keys-2.txt" "" "CRITICAL"
    hunt "Age keys" '\bAGE-SECRET-KEY-1[0-9A-Z]{58}\b' "age-keys.txt" "" "CRITICAL"
    hunt "Config file secrets" '(_authToken\s*=\s*[A-Za-z0-9_-]{20,}|aws_access_key_id\s*=\s*AKIA[0-9A-Z]{16}|client-key-data:\s*[A-Za-z0-9+/=]{100,}|Authorization:\s*Basic [A-Za-z0-9+/=]{20,})' "config-file-secrets.txt" '(test|example)' "CRITICAL" "3.0"
    hunt "Observability keys" '\b(NRAK-[A-Za-z0-9]{20,}|glsa_[A-Za-z0-9]{20,}|splunk[_-]?token|DD[_-]?API[_-]?KEY["'"'"' ]*[:=]["'"'"' ]*[a-f0-9]{32})\b' "observability.txt" '(test|example)' "HIGH" "3.0"
    hunt "Product/SaaS keys" '\b(pat-na1-[0-9a-f]{40}|pat-eu1-[0-9a-f]{40}|lin_api_[A-Za-z0-9]{20,}|secret_[A-Za-z0-9]{43}|notion[_-]?secret[_-]?[A-Za-z0-9]{20,}|seg[0-9a-f]{32})\b' "saas-keys.txt" '(test|example)' "MEDIUM" "3.0"
    hunt "Captcha keys" '\b(6L[0-9A-Za-z_-]{38}|10000000-ffff-ffff-ffff-000000000001|0x4AAAA[0-9A-Za-z]{20,}|es_[0-9a-f]{32})\b' "captcha-keys.txt" "" "MEDIUM"
    hunt "WebPush/VAPID" '("privateKey"\s*:\s*"[A-Za-z0-9_-]{40,}"|vapid[_-]?(private|public)[_-]?key)' "webpush.txt" '(test)' "MEDIUM" "3.0"
    hunt "Weak passwords" '(?i)(password|passwd|pwd|passcode)[\x22\x27\s]*[:=][\x22\x27\s]*[\x22\x27][A-Za-z0-9!@#$%^&*._-]{6,15}[\x22\x27]' "weak-passwords.txt" '(undefined|null|example|changeme|your[_-]|placeholder|password["'"'"' ]*[:=]["'"'"' ]*["'"'"']?(password|123456)|\*\*\*)' "MEDIUM" "0"

    if [ -s "$HOME/github-tools/hunt-custom.txt" ]; then
        while IFS= read -r _cl; do
            [ -n "$_cl" ] || continue
            case "$_cl" in \#*) continue ;; esac
            _cn="${_cl%%|*}"
            _cs="${_cl##*|}"
            _cr="${_cl#*|}"; _cr="${_cr%|*}"
            [ -n "$_cn" ] && [ -n "$_cr" ] || continue
            case "$_cl" in *'|'*) : ;; *) continue ;; esac
            _csd="secrets"
            case "$_cn" in "[SURFACE] "*) _csd="surface"; _cn="${_cn#\[SURFACE] }" ;; esac
            _cf=$(printf '%s' "$_cn" | tr -cd 'a-zA-Z0-9_' | tr 'A-Z' 'a-z' | cut -c1-40)
            [ -n "$_cf" ] || continue
            hunt "$_cn (custom)" "$_cr" "custom-$_cf.txt" '' "$_cs" "0" "$_csd"
        done < "$HOME/github-tools/hunt-custom.txt"
    fi

    local seenfile="$SESSION_DIR/state/tmp/.seen-values"
    : > "$seenfile"
    : > "$SESSION_DIR/findings/secrets/UNIQUE-SECRETS.tsv"
    local _dedup_order="cloud-tokens.txt private-keys.txt private-keys-2.txt db-creds.txt basic-auth.txt signing-secrets.txt config-file-secrets.txt comms-keys.txt auth-provider.txt payments-crypto.txt cloud-keys-2.txt ai-keys.txt ai-keys-2.txt payment-webhooks.txt devops-tokens.txt registry-ci.txt observability.txt auth-tokens.txt oauth-secrets.txt url-secrets.txt saas-tokens.txt saas-keys.txt tp-webhooks.txt hardcoded-bearer.txt presigned-urls.txt presigned-urls-2.txt azure-keys.txt service-accounts.txt smtp-creds.txt baas-pairs.txt generic-secrets.txt"
    for f in $_dedup_order $(ls "$SESSION_DIR/findings/secrets/"*.txt 2>/dev/null | xargs -r -n1 basename | grep -vxF -f <(printf '%s\n' $_dedup_order) | sort); do
        [ -s "$SESSION_DIR/findings/secrets/$f" ] || continue
        awk -F: -v seenfile="$seenfile" -v sidecar="$SESSION_DIR/state/value-locations.tsv" -v agg="$SESSION_DIR/findings/secrets/UNIQUE-SECRETS.tsv" 'BEGIN{while((getline l<seenfile)>0)seen[l]=1}{key="";for(i=3;i<=NF;i++)key=key $i (i<NF?":":"");if(key in seen){if($1!="")printf "%s\t%s\n",key,$1 >> sidecar;next}print;seen[key]=1;printf "%s\t%s\t%s\n", key, f, $1 >> agg}' "$SESSION_DIR/findings/secrets/$f" > "$SESSION_DIR/state/tmp/.tmp.$f"
        awk -F: '{key="";for(i=3;i<=NF;i++)key=key $i (i<NF?":":"");print key}' "$SESSION_DIR/state/tmp/.tmp.$f" >> "$seenfile"
        mv "$SESSION_DIR/state/tmp/.tmp.$f" "$SESSION_DIR/findings/secrets/$f"
    done
    rm -f "$seenfile"

    if [ -s "$SESSION_DIR/state/value-locations.tsv" ]; then
        find "$SESSION_DIR/js" -type f -printf '%f\t%P\n' 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.np.tsv"
        local npf="$SESSION_DIR/state/tmp/.np.tsv" um="$SESSION_DIR/state/url-map.txt" side="$SESSION_DIR/state/value-locations.tsv"
        local _ef
        for _ef in "$SESSION_DIR/findings"/secrets/*.txt "$SESSION_DIR/findings"/surface/custom-*.txt; do
            [ -f "$_ef" ] || continue
            awk -v npf="$SESSION_DIR/state/tmp/.np.tsv" -v um="$SESSION_DIR/state/url-map.txt" -v side="$SESSION_DIR/state/value-locations.tsv" '
                FILENAME==npf { p[$1]=$2; next }
                FILENAME==um { split($0,u,"|"); m[$1]=u[2]; next }
                FILENAME==side { if($2!=""){ if(loc[$1]=="") loc[$1]=$2; else if(index("," loc[$1] ",", "," $2 ",")==0) loc[$1]=loc[$1] "," $2 } next }
                {   line=$0; key="";
                    if (match(line,/^[^:]+:[0-9]+:/)) key=substr(line,RSTART+RLENGTH);
                    else if (index(line," :: ")>0) { n=split(line,a," :: "); if(n>=3) key=a[2]" :: "a[3]; }
                    else if (index(line,"::")>0) { n=split(line,b,"::"); if(n>=2) key=b[2]; }
                    if (key!="" && key in loc) {
                        nn=split(loc[key],c,","); added=0;
                        for (i2=1; i2<=nn && added<4; i2++) { f=c[i2];
                            if (f in p) { line=line "  |  FILE: js/" p[f]; added++ }
                            else if (f in m) { line=line "  |  URL: " m[f]; added++ }
                        }
                    }
                    print line }' "$npf" "$um" "$side" "$_ef" > "$_ef.tmp" 2>/dev/null && mv "$_ef.tmp" "$_ef"
        done
        rm -f "$SESSION_DIR/state/tmp/.np.tsv"
    fi

    if [ -s "$SESSION_DIR/state/url-map.txt" ] && [ -d "$SESSION_DIR/js" ]; then
        find "$SESSION_DIR/js" -type f -printf '%f\t%P\n' 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.name-path.tsv"
        local np="$SESSION_DIR/state/tmp/.name-path.tsv" um="$SESSION_DIR/state/url-map.txt"
        local _ef
        for _ef in "$SESSION_DIR/findings"/secrets/*.txt "$SESSION_DIR/findings"/surface/custom-*.txt; do
            [ -f "$_ef" ] || continue
            awk -v np="$SESSION_DIR/state/tmp/.name-path.tsv" -v um="$SESSION_DIR/state/url-map.txt" -F'\t' '
                FILENAME==np { p[$1]=$2; next }
                FILENAME==um { split($0,u,"|"); m[$1]=u[2]; next }
                { fn=$0; sub(/:.*/,"",fn); gsub(/^[[:space:]]+|[[:space:]]+$/,"",fn); outl=$0;
                  if ((fn in m) && index(outl,"  |  URL: " m[fn])==0) outl=outl "  |  URL: " m[fn];
                  if ((fn in p) && index(outl,"  |  FILE: js/" p[fn])==0) outl=outl "  |  FILE: js/" p[fn];
                  print outl }' "$np" "$um" "$_ef" > "$_ef.tmp" 2>/dev/null && mv "$_ef.tmp" "$_ef"
        done
        rm -f "$SESSION_DIR/state/tmp/.name-path.tsv"
    fi

    : > "$SESSION_DIR/findings/INDEX.tsv"
    while IFS='|' read -r _tf _msg _sev; do
        for _dir in secrets surface; do
            _hf="$SESSION_DIR/findings/$_dir/$_tf"
            [ -s "$_hf" ] || continue
            _hn=$(wc -l < "$_hf" | tr -d ' ')
            printf '%s\t%s\t%s\t%s\t%s\n' "$_sev" "$_dir" "$_tf" "$_hn" "$_msg" >> "$SESSION_DIR/findings/INDEX.tsv"
        done
    done < "$SESSION_DIR/findings/type-map.txt"
    [ -s "$SESSION_DIR/findings/INDEX.tsv" ] && sort -k1,1 -k4,4rn "$SESSION_DIR/findings/INDEX.tsv" -o "$SESSION_DIR/findings/INDEX.tsv"


    out "${C_W}GraphQL APQ probing${C_R}"
    local apq_hashes
    apq_hashes=$(grep -rhoE 'sha256Hash.{0,5}"[0-9a-f]{64}"' "$SESSION_DIR/js/raw" "$SESSION_DIR/js/formatted" "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/deobf" 2>/dev/null | grep -oE '[0-9a-f]{64}' | sort -u | head -5)
    : > "$SESSION_DIR/findings/analysis/graphql-persisted-queries.txt"
    if [ -n "$apq_hashes" ]; then
        printf '%s\n' "$apq_hashes" | while read -r h; do echo "hash: $h" >> "$SESSION_DIR/findings/analysis/graphql-persisted-queries.txt"; done
        head -3 "$SESSION_DIR/hosts/hosts-live.txt" | awk -F/ '{print $1"//"$3}' | sort -u | while read -r origin; do
            for gp in /graphql /api/graphql /query; do
                printf '%s\n' "$apq_hashes" | while read -r h; do
                    local resp
                    resp=$(curl -s -m 8 -X POST -H 'Content-Type: application/json' "$origin$gp" -d "{\"operationName\":null,\"variables\":{},\"extensions\":{\"persistedQuery\":{\"version\":1,\"sha256Hash\":\"$h\"}}}" 2>/dev/null)
                    if printf '%s' "$resp" | grep -qE '"data"|"errors"'; then
                        echo "$origin$gp -> hash $h: RESPONDS" >> "$SESSION_DIR/findings/analysis/graphql-persisted-queries.txt"
                    fi
                done
            done
        done
    fi

    out "${C_W}postMessage handler analysis${C_R}"
    : > "$SESSION_DIR/findings/analysis/postmessage-verdicts.txt"
    if [ -s "$SESSION_DIR/findings/secrets/postmessage-listeners.txt" ]; then
        local line fn ln srcf window verdict
        while IFS= read -r line; do
            fn="${line%%:*}"
            ln=$(printf '%s' "$line" | sed 's/^[^:]*:\([0-9]*\):.*/\1/')
            [ -n "$ln" ] || continue
            srcf=""
            for rep in mapsrc formatted deobf raw; do
                [ -f "$SESSION_DIR/js/$rep/$fn" ] && { srcf="$SESSION_DIR/js/$rep/$fn"; break; }
            done
            [ -n "$srcf" ] || continue
            window=$(awk -v n="$ln" 'NR>=n && NR<=n+30' "$srcf" 2>/dev/null)
            if ! printf '%s' "$window" | grep -q '\.data'; then
                verdict="INFO listener without data use"
            elif printf '%s' "$window" | grep -q '\.origin'; then
                if printf '%s' "$window" | grep -qE 'origin[^=]*(===|==|includes\(|indexOf)'; then
                    verdict="MEDIUM origin checked — verify allowlist strictness"
                else
                    verdict="MEDIUM origin referenced but not obviously compared"
                fi
            else
                verdict="HIGH no origin validation within 30 lines of listener"
            fi
            printf '%s|%s|%s\n' "$fn" "$ln" "$verdict" >> "$SESSION_DIR/findings/analysis/postmessage-verdicts.txt"
        done < "$SESSION_DIR/findings/secrets/postmessage-listeners.txt"
        sort -u "$SESSION_DIR/findings/analysis/postmessage-verdicts.txt" -o "$SESSION_DIR/findings/analysis/postmessage-verdicts.txt"
    fi

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} web.archive.org/cdx/search/cdx?url=<js> + /web/<ts>id_/<js>   (150 JS URLs x historical snapshots)"
    : > "$SESSION_DIR/findings/secrets/wayback-secrets.txt"
    {
        [ -s "$SESSION_DIR/state/js-map.txt" ] && cut -d'|' -f2 "$SESSION_DIR/state/js-map.txt"
        cat "$SESSION_DIR/urls/urls-js.txt" 2>/dev/null
    } | sort -u | head -150 > "$SESSION_DIR/state/tmp/.wb-js.txt"
    _wbpats="$SESSION_DIR/state/tmp/.wb-patterns.txt"
    if [ -s "$HOME/github-tools/hunt-custom.txt" ]; then
        grep -v '^#' "$HOME/github-tools/hunt-custom.txt" | awk -F'|' '{ if (NF >= 3) { r = $0; sub(/^[^|]*\|/, "", r); sub(/\|[^|]*$/, "", r); if (r != "") print r } }' > "$_wbpats" 2>/dev/null
    fi
    if [ ! -s "$_wbpats" ]; then
        printf '%s\n' 'AKIA[0-9A-Z]{16}|gh[pousr]_[a-zA-Z0-9]{36}|sk_live_[0-9a-zA-Z]{24}|xox[baprs]-[0-9a-zA-Z-]{10,}|SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}|glpat-[0-9A-Za-z_-]{20,}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|-----BEGIN[A-Z ]*PRIVATE KEY-----|api[_-]?key["'"'"']? *[:=] *["'"'"'][A-Za-z0-9_-]{16,}' > "$_wbpats"
    fi
    if [ -s "$SESSION_DIR/state/tmp/.wb-js.txt" ]; then
        mkdir -p "$SESSION_DIR/state/tmp/wayback-js"
        while read -r jsurl; do
            [ -z "$jsurl" ] && continue
            local enc_jsurl cdx
            enc_jsurl=$(printf '%s' "$jsurl" | jq -sRr @uri 2>/dev/null) || enc_jsurl="$jsurl"
            cdx=$(curl -s -m 15 "https://web.archive.org/cdx/search/cdx?url=${enc_jsurl}&output=text&fl=timestamp,digest&collapse=digest&limit=10" 2>/dev/null)
            [ -z "$cdx" ] && continue
            echo "$cdx" | awk 'NR < n {print $1}' n=$(echo "$cdx" | wc -l) | head -3 | while read -r ts; do
                local wf hits
                wf="$SESSION_DIR/state/tmp/wayback-js/${ts}_$(printf '%s' "${jsurl%%\?*}" | md5sum | cut -c1-8)_$(basename "${jsurl%%\?*}")"
                [ -s "$wf" ] && continue
                curl -s -m 20 "https://web.archive.org/web/${ts}id_/${jsurl}" -o "$wf" 2>/dev/null
                [ -s "$wf" ] || continue
                hits=$(_mpgrep "$_wbpats" "$wf" | sort -u)
                [ -n "$hits" ] && { echo "$jsurl @ $ts:" >> "$SESSION_DIR/findings/secrets/wayback-secrets.txt"; echo "$hits" | sed 's/^/    /' >> "$SESSION_DIR/findings/secrets/wayback-secrets.txt"; }
            done
        done < "$SESSION_DIR/state/tmp/.wb-js.txt"
    fi
    rm -rf "$SESSION_DIR/state/tmp/wayback-js" "$SESSION_DIR/state/tmp/.wb-js.txt" "$SESSION_DIR/state/tmp/.wb-patterns.txt"

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ semgrep${C_R} scan --config=reconly-custom.yml --config=p/{javascript,secrets,react,vue,angular,jwt} --json js/mapsrc js/formatted js/deobf | jq -r 'path:line:check_id: message' || true"
    if [ -d "$SESSION_DIR/js/mapsrc" ] || [ -d "$SESSION_DIR/js/formatted" ]; then
        cat > "$SESSION_DIR/state/reconly-custom.yml" << 'YAMLEOF'
rules:
  - id: postmessage-no-origin-check
    languages: [javascript]
    message: "postMessage handler WITHOUT origin validation"
    severity: ERROR
    patterns:
      - pattern: window.addEventListener("message", function($E) { ... }, ...)
      - pattern-not: window.addEventListener("message", function($E) { if ($E.origin === ...) { ... } }, ...)
  - id: prototype-pollution-unsafe-merge
    languages: [javascript]
    message: "Deep merge WITHOUT __proto__/constructor guard"
    severity: ERROR
    pattern-either:
      - patterns:
          - pattern: for (var $KEY in $SRC) { ... $DST[$KEY] = ...; ... }
          - pattern-not-inside: if ($KEY === "__proto__" || ...) { ... }
      - patterns:
          - pattern: Object.assign($DST, $SRC)
  - id: taint-location-to-dom-sink
    mode: taint
    languages: [javascript]
    message: "Attacker-controlled input reaches DOM sink"
    severity: ERROR
    pattern-sources:
      - pattern: location.hash
      - pattern: location.search
      - pattern: new URLSearchParams(...)
      - pattern: $E.data
      - pattern: location.href
    pattern-sinks:
      - patterns:
          - pattern-either:
              - pattern: $X.innerHTML = ...
              - pattern: $X.outerHTML = ...
              - pattern: document.write(...)
              - pattern: eval(...)
              - pattern: new Function(...)
              - pattern: $X.insertAdjacentHTML(...)
  - id: direct-eval-usage
    languages: [javascript]
    message: "eval() usage -- verify input safety"
    severity: WARNING
    pattern: eval(...)
  - id: innerhtml-assignment
    languages: [javascript]
    message: "innerHTML assignment -- potential DOM XSS"
    severity: WARNING
    pattern: $X.innerHTML = ...
  - id: token-in-localstorage
    languages: [javascript]
    message: "token/session material stored in localStorage (XSS-accessible)"
    severity: WARNING
    pattern-either:
      - pattern: localStorage.setItem("token", ...)
      - pattern: localStorage.setItem("jwt", ...)
      - pattern: localStorage.setItem("session", ...)
      - pattern: localStorage["token"] = ...
      - pattern: localStorage.token = ...
  - id: hardcoded-credential-literal
    languages: [javascript]
    message: "possible hardcoded credential literal"
    severity: WARNING
    pattern-regex: "(?i)(password|passwd|pwd|secret|api[_-]?key|token)[\"'']?\\s*[:=]\\s*[\"''][A-Za-z0-9_\\-]{8,}[\"'']"
  - id: open-redirect-location-assign
    languages: [javascript]
    message: "location assignment from variable -- possible open redirect"
    severity: WARNING
    pattern-either:
      - pattern: location.href = $X
      - pattern: window.location = $X
      - pattern: location.assign($X)
      - pattern: location.replace($X)
  - id: websocket-variable-url
    languages: [javascript]
    message: "WebSocket opened with variable URL"
    severity: INFO
    pattern: new WebSocket($X)
YAMLEOF
        local _sg_rc=0
        nice -n 15 timeout --foreground 1800 semgrep scan --jobs "$PRETTIER_JOBS" --config="$SESSION_DIR/state/reconly-custom.yml" --config=p/javascript --config=p/secrets --config=p/react --config=p/vue --config=p/angular --config=p/jwt --json --metrics=off \
            "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/formatted" "$SESSION_DIR/js/deobf" 2>"$SESSION_DIR/state/tmp/semgrep.err" \
          | jq -r '.results[] | "\(.path):\(.start.line):\(.check_id): \(.extra.message)"' > "$SESSION_DIR/findings/analysis/semgrep-findings.txt" 2>/dev/null || _sg_rc=1
        if [ "$_sg_rc" -ne 0 ]; then
            warn_rc "semgrep (registry)" "$_sg_rc"
            out "${C_Y}[warn] semgrep registry unreachable -- falling back to local rules only${C_R}"
            local _sgl_rc=0
            nice -n 15 timeout --foreground 900 semgrep scan --jobs "$PRETTIER_JOBS" --config="$SESSION_DIR/state/reconly-custom.yml" --json --metrics=off \
                "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/formatted" "$SESSION_DIR/js/deobf" 2>>"$SESSION_DIR/state/tmp/semgrep.err" \
              | jq -r '.results[] | "\(.path):\(.start.line):\(.check_id): \(.extra.message)"' > "$SESSION_DIR/findings/analysis/semgrep-findings.txt" 2>/dev/null || _sgl_rc=1
            [ "$_sgl_rc" -ne 0 ] && warn_rc "semgrep (local)" "$_sgl_rc"
        fi
        if [ -s "$SESSION_DIR/findings/analysis/semgrep-findings.txt" ]; then
            sort -u "$SESSION_DIR/findings/analysis/semgrep-findings.txt" -o "$SESSION_DIR/findings/analysis/semgrep-findings.txt"
            sed -i "s|^$SESSION_DIR/||" "$SESSION_DIR/findings/analysis/semgrep-findings.txt" 2>/dev/null || true
        fi
    fi

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ codeql${C_R} database create .codeql-db --language=javascript --source-root=.codeql-src && codeql database analyze .codeql-db javascript-security-extended.qls --format=sarif-latest"
    if command -v codeql &>/dev/null; then
        _cq_suite="javascript-security-extended.qls"
        _cq_extra=()
        if ! ls "$HOME/github-tools/.codeql"/packages/codeql/javascript-queries/*/ &>/dev/null 2>&1; then
            _cq_found=$(find "$HOME/github-tools/.codeql/codeql-src" -path '*codeql-suites/javascript-security-extended.qls' 2>/dev/null | head -1)
            if [ -n "$_cq_found" ]; then
                _cq_suite="$_cq_found"
                _cq_packs=$(find "$HOME/github-tools/.codeql/codeql-src/javascript" "$HOME/github-tools/.codeql/codeql-src/shared" -maxdepth 6 \( -name qlpack.yml -o -name codeql-pack.yml \) -printf '%h\n' 2>/dev/null | sort -u | tr '\n' ':')
                [ -n "$_cq_packs" ] && _cq_extra=(--additional-packs "$_cq_packs")
            fi
        fi
        if ls "$HOME/github-tools/.codeql"/packages/codeql/javascript-queries/*/ &>/dev/null 2>&1 || [ -n "${_cq_extra[0]:-}" ]; then
        mkdir -p "$SESSION_DIR/state/tmp/.codeql-src/raw"
        cp -r "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/deobf" "$SESSION_DIR/state/tmp/.codeql-src/" 2>/dev/null || true
        find "$SESSION_DIR/js/raw" -maxdepth 1 -type f -name '*.js' -printf '%f\n' 2>/dev/null | while IFS= read -r fn; do
            [ -s "$SESSION_DIR/state/tmp/.codeql-src/raw/$fn" ] && continue
            grep -Fqx "$fn" "$SESSION_DIR/state/obf-hits.txt" 2>/dev/null && continue
            cp -- "$SESSION_DIR/js/raw/$fn" "$SESSION_DIR/state/tmp/.codeql-src/raw/$fn" 2>/dev/null || true
        done
        find "$SESSION_DIR/state/tmp/.codeql-src" -type f \( -name '*.js' -o -name '*.ts' \) -print0 2>/dev/null | xargs -0 md5sum 2>/dev/null | sort -k1,1 | awk 'seen[$1]++ {print $2}' > "$SESSION_DIR/state/tmp/.cq-dups"
        [ -s "$SESSION_DIR/state/tmp/.cq-dups" ] && xargs -r rm -f < "$SESSION_DIR/state/tmp/.cq-dups"
        rm -f "$SESSION_DIR/state/tmp/.cq-dups"
        if [ -n "$(find "$SESSION_DIR/state/tmp/.codeql-src" -type f -print -quit 2>/dev/null)" ]; then
            if nice -n 15 timeout --foreground 900 codeql database create "$SESSION_DIR/state/tmp/.codeql-db" --language=javascript --source-root="$SESSION_DIR/state/tmp/.codeql-src" --overwrite --threads="$PRETTIER_JOBS" >/dev/null 2>>"$SESSION_DIR/reconly.log"; then
                local _cq_rc=0
                local -a _cq_cache=()
                mkdir -p "$HOME/github-tools/.codeql/compilation-cache" 2>/dev/null || true
                codeql database analyze --help 2>/dev/null | grep -q -- '--compilation-cache' && _cq_cache=(--compilation-cache "$HOME/github-tools/.codeql/compilation-cache")
                nice -n 15 timeout --foreground 1800 codeql database analyze "$SESSION_DIR/state/tmp/.codeql-db" "$_cq_suite" "${_cq_extra[@]+${_cq_extra[@]}}" "${_cq_cache[@]+${_cq_cache[@]}}" --format=sarif-latest --output="$SESSION_DIR/state/tmp/.codeql.sarif" --threads="$PRETTIER_JOBS" --ram=4096 >/dev/null 2>>"$SESSION_DIR/reconly.log" || _cq_rc=$?
                [ "$_cq_rc" -ne 0 ] && warn_rc "codeql analyze" "$_cq_rc"
                jq -r '.runs[].results[]? | .ruleId' "$SESSION_DIR/state/tmp/.codeql.sarif" 2>/dev/null | sort | uniq -c | sort -rn | head -100 | awk '{printf "%6d x %s\n", $1, substr($0, index($0,$2))}' > "$SESSION_DIR/findings/analysis/codeql-findings.txt"
                jq -r '.runs[] as $r | .results[]? | "\(.ruleId) :: \(.locations[0].physicalLocation.artifactLocation.uri // "?"):\(.locations[0].physicalLocation.region.startLine // 0)"' "$SESSION_DIR/state/tmp/.codeql.sarif" 2>/dev/null | sort -u | head -200 > "$SESSION_DIR/findings/analysis/codeql-locations.txt"
            else
                warn_rc "codeql database create" 1
            fi
        fi
        else
            out "${C_Y}[warn] codeql pack unavailable -- skipping codeql analysis this run${C_R}"
        fi
    fi

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ retire${C_R} --path js --outputformat json | jq -r 'component@version -- vuln' >> vulnerable-libs.txt || true"
    : > "$SESSION_DIR/findings/analysis/vulnerable-libs.txt"
    timeout --foreground 600 retire --path "$SESSION_DIR/js" --outputformat json 2>/dev/null \
      | jq -r 'if type=="array" then .[] else . end | (.results // empty)[] | "\(.component)@\(.version) -- \(.vulnerabilities[0].identifiers.summary // "vuln")"' >> "$SESSION_DIR/findings/analysis/vulnerable-libs.txt" || true
    sort -u "$SESSION_DIR/findings/analysis/vulnerable-libs.txt" -o "$SESSION_DIR/findings/analysis/vulnerable-libs.txt" 2>/dev/null || true

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ npm${C_R} audit --json   (per package-lock.json found under tmp/deobf, critical+high only)"
    : > "$SESSION_DIR/findings/analysis/npm-audit.txt"
    find "$SESSION_DIR/state/tmp/deobf" -maxdepth 3 -name package-lock.json 2>/dev/null | while read -r lk; do
        local d
        d=$(dirname "$lk")
        ( cd "$d" && npm audit --json 2>/dev/null | jq -r '.vulnerabilities | to_entries[] | select(.value.severity=="critical" or .value.severity=="high") | "\(.key): \(.value.severity) \(.value.via[0].title // "")"' 2>/dev/null | sed "s|^|$d: |" ) >> "$SESSION_DIR/findings/analysis/npm-audit.txt" || true
    done

}
st_app_surface() {
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ rg${C_R} -oP 'path:|fetch(|axios.|url:|WebSocket(|localStorage.|api_url|baseurl|server_url' js/mapsrc js/formatted"
    local ms="$SESSION_DIR/js/mapsrc" fd="$SESSION_DIR/js/formatted" db="$SESSION_DIR/js/deobf"
    local have_grep=0
    if command -v rg &>/dev/null && printf 'x1' | rg -qP '\d' 2>/dev/null; then have_grep=1; fi
    [ "$have_grep" -eq 1 ] || { out "${C_Y}No rg, skipping app surface mapping${C_R}"; return; }

    rg -oP "path:\s*['\"][^'\"]+['\"]" "$ms" "$fd" "$db" 2>/dev/null       | sed -E "s/.*path:\s*['\"]([^'\"]+)['\"].*/\1/"       | awk 'length($0)>1 && $0 !~ /\$\{|:|^https?:/' | sort -u > "$SESSION_DIR/findings/surface/app-routes.txt"

    {
        rg -oP "fetch\s*\(\s*['\"\`][^'\"\`]+['\"\`]" "$ms" "$fd" "$db" 2>/dev/null | sed -E "s/.*fetch\s*\(\s*['\"\`]([^'\"\`]+)['\"\`].*/GET \1/"
        rg -oP "axios\.(get|post|put|delete|patch)\s*\(\s*['\"\`][^'\"\`]+['\"\`]" "$ms" "$fd" "$db" 2>/dev/null | sed -E "s/.*axios\.(get|post|put|delete|patch)\s*\(\s*['\"\`]([^'\"\`]+)['\"\`].*/\U\1 \2/"
        rg -oP "url:\s*['\"][^'\"]+['\"]" "$ms" "$fd" "$db" 2>/dev/null | sed -E "s/.*url:\s*['\"]([^'\"]+)['\"].*/GET \1/"
        rg -oP "new\s+WebSocket\s*\(\s*['\"][^'\"]+['\"]" "$ms" "$fd" "$db" 2>/dev/null | sed -E "s/.*WebSocket\s*\(\s*['\"]([^'\"]+)['\"].*/WS \1/"
    } | awk 'NF>=2 && $2 !~ /\$\{|\+/ && $2 !~ /\/$/ && $2 ~ /^(\/|wss?:\/\/)/' | sort -u > "$SESSION_DIR/findings/surface/app-api-calls.txt"
    if [ -s "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" ]; then
        awk '{print "GET " $0}' "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" >> "$SESSION_DIR/findings/surface/app-api-calls.txt"
        sort -u "$SESSION_DIR/findings/surface/app-api-calls.txt" -o "$SESSION_DIR/findings/surface/app-api-calls.txt"
    fi

    rg -oP "(localStorage|sessionStorage)\.(get|set|remove)Item\(\s*['\"][^'\"]+['\"]" "$ms" "$fd" "$db" 2>/dev/null       | sed -E "s/.*Item\(\s*['\"]([^'\"]+)['\"].*/\1/"       | awk 'length($0)>2 && $0 !~ /\$\{/' | sort -u > "$SESSION_DIR/findings/surface/app-storage-keys.txt"

    rg -oP -i "(api[_-]?url|baseurl|api[_-]?base|server[_-]?url|endpoint)\s*[:=]\s*['\"][^'\"]+['\"]" "$ms" "$fd" "$db" 2>/dev/null       | grep -viE "(localhost|example|placeholder|your[_-]|test)" | sort -u > "$SESSION_DIR/findings/surface/app-environments.txt"

    rg -oP "(?:process\.env|import\.meta\.env)\.(?:REACT_APP|NEXT_PUBLIC|VITE|NUXT_PUBLIC|PUBLIC_)[A-Z0-9_]+" "$ms" "$fd" "$db" 2>/dev/null | sort -u > "$SESSION_DIR/findings/surface/app-env-vars.txt"

    if [ -d "$SESSION_DIR/js/sourcemaps" ]; then
        find "$SESSION_DIR/js/sourcemaps" -name '*.map' -maxdepth 1 -print0 2>/dev/null           | xargs -0 -I{} jq -r '.sources[]? // empty' {} 2>/dev/null           | sort -u > "$SESSION_DIR/findings/surface/app-repo-structure.txt"
    fi
    if [ -s "$SESSION_DIR/urls/urls-inscope.txt" ]; then
        awk '{
            u=$0; sub(/^https?:\/\//, "", u)
            n=split(u, a, "/")
            host=a[1]
            if (host != prev) { if (NR > 1) print ""; print host; prev=host }
            prefix=""
            for (i=2; i<=n; i++) {
                seg=a[i]; gsub(/\?.*/, "", seg)
                if (seg == "") continue
                prefix = prefix "/" seg
                key = host prefix
                if (!(key in seen)) {
                    seen[key]=1
                    ind=""
                    for (j=2; j<i; j++) ind=ind "  "
                    print ind "|_ " seg
                }
            }
        }' <(sed 's|^https\?://||' "$SESSION_DIR/urls/urls-inscope.txt" | sort -u) > "$SESSION_DIR/findings/surface/site-tree.txt" 2>/dev/null
    fi
}
st_context() {
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ rg${C_R} -a -C 2 -F '<first match of each HIGH+ type>' js/mapsrc js/formatted   (ctx-<file>.txt)"
    local ctx_dir="$SESSION_DIR/findings/analysis/ctx"
    mkdir -p "$ctx_dir"
    while IFS='|' read -r tf msg sev; do
        [ "$sev" = "CRITICAL" ] || [ "$sev" = "HIGH" ] || continue
        [ -f "$SESSION_DIR/findings/secrets/$tf" ] || continue
        : > "$ctx_dir/$tf"
        head -3 "$SESSION_DIR/findings/secrets/$tf" | while IFS= read -r ctxline; do
            local firstmatch
            firstmatch=$(printf '%s' "$ctxline" | sed 's/^[^:]*:[0-9]*://' | sed 's/  |  \(FILE\|URL\):.*$//')
            [ -n "$firstmatch" ] || continue
            for rep in mapsrc formatted; do
                [ -d "$SESSION_DIR/js/$rep" ] || continue
                ( cd "$SESSION_DIR/js/$rep" 2>/dev/null && rg --no-ignore -a -C 2 -F -e "$firstmatch" . 2>/dev/null ) | head -40 >> "$ctx_dir/$tf"
                [ -s "$ctx_dir/$tf" ] && break
            done
        done
    done < "$SESSION_DIR/findings/type-map.txt"
    local _cf _cn=0
    for _cf in "$SESSION_DIR/findings/analysis/ctx"/*.txt; do
        [ -s "$_cf" ] || continue
        _cn=$((_cn+1))
    done
}

st_quick_probes() {
    local hl="$SESSION_DIR/hosts/hosts-live.txt"
    [ -s "$hl" ] || { out "${C_Y}No live hosts, skipping quick probes${C_R}"; return; }
    mkdir -p "$SESSION_DIR/findings/probes"
    awk -F/ '{print $1"//"$3}' "$hl" | grep -vE ':[0-9]+$' | sort -u | head -40 > "$SESSION_DIR/state/tmp/.qp-origins.txt"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} -s -o /dev/null -D - <origin>   (top-40 live origins: headers + cookie flags + CORS reflection)"
    : > "$SESSION_DIR/findings/probes/cookie-flags.txt"
    : > "$SESSION_DIR/findings/probes/cors-misconfig.txt"
    run_qp_origin() {
        local o="$1" hdr h ck flags cor acao acac
        hdr=$(curl -s -o /dev/null -D - -m 12 -A "$FAKE_UA" "$o" 2>/dev/null)
        [ -z "$hdr" ] && return 0
        for h in content-security-policy strict-transport-security x-frame-options x-content-type-options referrer-policy permissions-policy; do
            printf '%s' "$hdr" | grep -qi "^$h:" || echo "$o missing $h" >> "$SESSION_DIR/findings/probes/security-headers.txt"
        done
        printf '%s' "$hdr" | grep -i '^set-cookie:' | while IFS= read -r ck; do
            flags=""
            printf '%s' "$ck" | grep -qi 'secure' || flags="$flags no-Secure"
            printf '%s' "$ck" | grep -qi 'httponly' || flags="$flags no-HttpOnly"
            printf '%s' "$ck" | grep -qi 'samesite' || flags="$flags no-SameSite"
            [ -n "$flags" ] && echo "$o cookie:${ck#*:}$flags" >> "$SESSION_DIR/findings/probes/cookie-flags.txt"
        done
        cor=$(curl -s -o /dev/null -D - -m 12 -A "$FAKE_UA" -H 'Origin: https://evil.example' "$o" 2>/dev/null)
        acao=$(printf '%s' "$cor" | grep -i '^access-control-allow-origin:' | tr -d '\r' | cut -d' ' -f2-)
        acac=$(printf '%s' "$cor" | grep -i '^access-control-allow-credentials:' | tr -d '\r' | cut -d' ' -f2-)
        if printf '%s' "$acao" | grep -qi 'evil\.example'; then
            if printf '%s' "$acac" | grep -qi 'true'; then
                echo "$o reflects arbitrary Origin WITH credentials (ACAO: $acao ACAC: true)" >> "$SESSION_DIR/findings/probes/cors-misconfig.txt"
            else
                echo "$o reflects arbitrary Origin (ACAO: $acao)" >> "$SESSION_DIR/findings/probes/cors-misconfig.txt"
            fi
        elif printf '%s' "$acao" | grep -q '^\*$'; then
            echo "$o allows Origin * (ACAO: $acao)" >> "$SESSION_DIR/findings/probes/cors-misconfig.txt"
        elif printf '%s' "$acao" | grep -qi '^null'; then
            echo "$o allows Origin null (ACAO: $acao)" >> "$SESSION_DIR/findings/probes/cors-misconfig.txt"
        fi
        return 0
    }
    export -f run_qp_origin
    cat "$SESSION_DIR/state/tmp/.qp-origins.txt" | xargs -d '\n' -P 15 -I {} bash -c 'run_qp_origin "$1"' _ {}

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} --max-redirs 0 -w '%{http_code} %{redirect_url}' <redirect-param URLs>   (40 URLs, value -> evil.example)"
    : > "$SESSION_DIR/findings/probes/open-redirect-confirmed.txt"
    grep -E '[?&](redirect|redirect_uri|redirect_url|return|return_url|returnto|return_to|next|continue|url|dest|destination|target|out|forward|go)=[^&]*' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | head -40 \
    | xargs -d '\n' -P 15 -I {} bash -c '
        u="$1"
        pu=$(printf "%s" "$u" | sed -E "s~([?&](redirect(_uri|_url)?|return(_url)?|returnto|return_to|next|continue|url|dest|destination|target|out|forward|go)=)[^&]*~\1https://evil.example~g")
        res=$(curl -s -o /dev/null -m 10 -A "$FAKE_UA" --max-redirs 0 -w "%{http_code} %{redirect_url}" "$pu" 2>/dev/null)
        case "$res" in 3*"evil.example"*) echo "$u -> $res" >> "'"$SESSION_DIR"'/findings/probes/open-redirect-confirmed.txt" ;; esac
    ' _ {}

    _qppats="$SESSION_DIR/state/tmp/.qp-patterns.txt"
    if [ -s "$HOME/github-tools/hunt-custom.txt" ]; then
        grep -v '^#' "$HOME/github-tools/hunt-custom.txt" | awk -F'|' '{ if (NF >= 3) { r = $0; sub(/^[^|]*\|/, "", r); sub(/\|[^|]*$/, "", r); if (r != "") print r } }' > "$_qppats" 2>/dev/null
    fi
    if [ ! -s "$_qppats" ]; then
        printf '%s\n' 'AKIA[0-9A-Z]{16}|gh[pousr]_[a-zA-Z0-9]{36}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|-----BEGIN[A-Z ]*PRIVATE KEY-----' > "$_qppats"
    fi
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} '<url + zzcanary123>'   (60 URLs reflection probe + body secret-scan)"
    : > "$SESSION_DIR/findings/probes/reflected-params.txt"
    { [ -s "$SESSION_DIR/urls/urls-reflection-candidates.txt" ] && head -60 "$SESSION_DIR/urls/urls-reflection-candidates.txt"; } \
    | xargs -d '\n' -P 15 -I {} bash -c '
        u="$1"; sep="?"; case "$u" in *\?*) sep="&" ;; esac
        hit=""
        body=$(curl -s -m 12 -A "$FAKE_UA" "$u${sep}zzrc$RANDOM=zzcanary123" 2>/dev/null)
        printf "%s" "$body" | grep -q "zzcanary123" && hit="new-param"
        if [ -z "$hit" ]; then
            u2=$(printf "%s" "$u" | sed -E "s/([?&][^=]+)=[^&]*/\1=zzcanary456/")
            body2=$(curl -s -m 12 -A "$FAKE_UA" "$u2" 2>/dev/null)
            printf "%s" "$body2" | grep -q "zzcanary456" && hit="existing-param"
        fi
        if [ -s "'"$SESSION_DIR"'/state/tmp/.qp-patterns.txt" ] && [ -n "$body" ]; then
            _bh=$(printf '%s' "$body" | _mpgrep "'"$SESSION_DIR"'/state/tmp/.qp-patterns.txt" | sort -u | head -5)
            if [ -n "$_bh" ]; then
                { echo "== $u"; echo "$_bh"; } >> "'"$SESSION_DIR"'/findings/probes/body-secrets.txt"
            fi
        fi
        [ -n "$hit" ] && echo "$u reflects ($hit)" >> "'"$SESSION_DIR"'/findings/probes/reflected-params.txt"
    ' _ {}

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} <host> -w %{http_code}   (gated-host + sensitive-file + hidden-endpoint probes, parallel)"
    : > "$SESSION_DIR/findings/probes/hosts-auth-required.txt"
    cat "$hl" | xargs -d '\n' -P 20 -n 1 bash -c '
        c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" "$1" 2>/dev/null)
        case "$c" in
            401|403) echo "$1 -> $c" >> "$SESSION_DIR/findings/probes/hosts-auth-required.txt" ;;
        esac
    ' _
    : > "$SESSION_DIR/findings/probes/sensitive-files-live.txt"
    [ -s "$SESSION_DIR/urls/urls-artifacts.txt" ] && grep -viE '\.(css|wasm)(\?|$)' "$SESSION_DIR/urls/urls-artifacts.txt" | head -40 | xargs -d '\n' -P 15 -I {} bash -c '
        c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" "$1" 2>/dev/null)
        [ "$c" = "200" ] && echo "$1 -> 200" >> "'"$SESSION_DIR"'/findings/probes/sensitive-files-live.txt"
    ' _ {}
    : > "$SESSION_DIR/findings/probes/hidden-endpoints.txt"
    {
        sed -E 's/^[^:]*:[0-9]*://' "$SESSION_DIR/findings/secrets/hidden-paths.txt" 2>/dev/null
        cat "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" 2>/dev/null
    } | sort -u | head -100 > "$SESSION_DIR/state/tmp/.qp-he.txt"
    if [ -s "$SESSION_DIR/state/tmp/.qp-he.txt" ]; then
        _qp_base=$(head -1 "$SESSION_DIR/state/tmp/.qp-origins.txt")
        export _qp_base
        cat "$SESSION_DIR/state/tmp/.qp-he.txt" | xargs -d '\n' -P 15 -n 1 bash -c '
            c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" "$_qp_base$1" 2>/dev/null)
            if [ "$c" = "200" ]; then
                echo "$_qp_base$1 -> 200" >> "$SESSION_DIR/findings/probes/hidden-endpoints.txt"
                _hb=$(curl -s -m 10 -A "$FAKE_UA" "$_qp_base$1" 2>/dev/null | _mpgrep "$SESSION_DIR/state/tmp/.qp-patterns.txt" | sort -u | head -5)
                if [ -n "$_hb" ]; then
                    { echo "== $_qp_base$1"; echo "$_hb"; } >> "$SESSION_DIR/findings/probes/body-secrets.txt"
                fi
            fi
        ' _
    fi
    rm -f "$SESSION_DIR/state/tmp/.qp-he.txt"

    if [ -s "$SESSION_DIR/findings/secrets/baas-urls.txt" ]; then
        out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} <project>.firebaseio.com/.json + /.settings/rules.json   (firebase open-DB probe)"
        : > "$SESSION_DIR/findings/probes/cloud-misconfig.txt"
        grep -oE '[a-z0-9][a-z0-9.-]+\.firebaseio\.com' "$SESSION_DIR/findings/secrets/baas-urls.txt" 2>/dev/null | sort -u | head -10 | while read -r _fb; do
            _code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://$_fb/.json" 2>/dev/null)
            [ "$_code" = "200" ] && echo "[CRITICAL] Firebase DB OPEN: https://$_fb/.json returns 200" >> "$SESSION_DIR/findings/probes/cloud-misconfig.txt"
            _rules=$(curl -s -m 8 "https://$_fb/.settings/rules.json" 2>/dev/null)
            printf '%s' "$_rules" | grep -q '"rules"' && echo "[HIGH] Firebase RULES exposed: https://$_fb/.settings/rules.json" >> "$SESSION_DIR/findings/probes/cloud-misconfig.txt"
        done
    fi
    if [ -s "$SESSION_DIR/findings/secrets/s3-buckets.txt" ]; then
        grep -oP '[a-z0-9][a-z0-9.-]{1,61}(?=\.s3[.-][a-z0-9-]*\.amazonaws\.com)' "$SESSION_DIR/findings/secrets/s3-buckets.txt" 2>/dev/null | sort -u | head -10 | while read -r _b; do
            _code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://$_b.s3.amazonaws.com/?list-type=2" 2>/dev/null)
            [ "$_code" = "200" ] && echo "[CRITICAL] S3 bucket LISTABLE: $_b" >> "$SESSION_DIR/findings/probes/cloud-misconfig.txt"
            [ "$_code" = "403" ] && echo "[INFO] S3 bucket exists (denied): $_b" >> "$SESSION_DIR/findings/probes/cloud-misconfig.txt"
        done
    fi
    {
        grep -rhoE 'storage\.googleapis\.com/[a-z0-9._-]{3,63}|https?://[a-z0-9._-]{3,63}\.storage\.googleapis\.com|https?://storage\.googleapis\.com/[a-z0-9._-]{3,63}' "$SESSION_DIR/findings" "$SESSION_DIR/urls" 2>/dev/null           | sed -E 's|^https?://([a-z0-9._-]+)\.storage\.googleapis\.com.*$|\1|; s|^storage\.googleapis\.com/([a-z0-9._-]+).*$|\1|; s|^https?://storage\.googleapis\.com/([a-z0-9._-]+).*$|\1|'           | grep -E '^[a-z0-9][a-z0-9._-]{2,62}$' | sort -u | head -10
    } | while read -r _gb; do
        _code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://storage.googleapis.com/$_gb" 2>/dev/null)
        [ "$_code" = "200" ] && echo "[CRITICAL] GCP bucket PUBLIC: https://storage.googleapis.com/$_gb" >> "$SESSION_DIR/findings/probes/cloud-misconfig.txt"
    done
    {
        grep -rhoE 'https?://[a-z0-9]{3,24}\.blob\.core\.windows\.net(/[a-z0-9.-]{1,64})?' "$SESSION_DIR/findings" "$SESSION_DIR/urls" 2>/dev/null | sort -u | head -10
    } | while read -r _az; do
        _acct=$(printf '%s' "$_az" | sed -E 's|^https?://([a-z0-9]{3,24})\..*$|\1|')
        _cont=$(printf '%s' "$_az" | sed -E 's|^https?://[a-z0-9]{3,24}\.blob\.core\.windows\.net/([a-z0-9.-]{1,64}).*$|\1|')
        if [ -n "$_cont" ] && [ "$_cont" != "$_az" ]; then
            _code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "$_az?restype=container&comp=list" 2>/dev/null)
            [ "$_code" = "200" ] && echo "[CRITICAL] Azure container LISTABLE: $_az" >> "$SESSION_DIR/findings/probes/cloud-misconfig.txt"
        else
            _code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://$_acct.blob.core.windows.net?comp=list" 2>/dev/null)
            [ "$_code" = "200" ] && echo "[CRITICAL] Azure storage account LISTABLE: $_acct" >> "$SESSION_DIR/findings/probes/cloud-misconfig.txt"
        fi
    done
    grep -vE ':[0-9]+$' "$SESSION_DIR/hosts/hosts-live.txt" 2>/dev/null | head -3 | awk -F/ '{print $1"//"$3}' | sort -u | while read -r _go; do
        for _gp in /graphql /api/graphql /query /gql; do
            _gq=$(curl -s -m 8 -X POST -H 'Content-Type: application/json' "$_go$_gp" -d '{"query":"{__schema{queryType{name}}}"}' 2>/dev/null)
            printf '%s' "$_gq" | grep -q '__schema' && echo "[HIGH] GraphQL introspection ENABLED: $_go$_gp" >> "$SESSION_DIR/findings/probes/cloud-misconfig.txt"
        done
    done
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ dnsx${C_R} -l dead-hosts -cname + httpx CNAME grep   (takeover fingerprints + passive graphql/ws lists)"
    : > "$SESSION_DIR/findings/probes/takeover.txt"
    [ -s "$SESSION_DIR/hosts/httpx-raw.txt" ] && grep -iE 'cname.*(s3[.-]amazonaws|s3-website|azurewebsites|azureedge|cloudapp|github\.io|herokuapp|herokussl|fastly\.net|fastlylb|myshopify|shopify|unbouncepages|webflow|netlify|surge\.sh|pantheon|tumblr|wpengine|kinsta|fly\.dev|onrender|digitaloceanspaces|blob\.core\.windows)' "$SESSION_DIR/hosts/httpx-raw.txt" 2>/dev/null | head -20 >> "$SESSION_DIR/findings/probes/takeover.txt"
    awk -F/ '{print $3}' "$hl" | sed 's/:.*//' | sort -u > "$SESSION_DIR/state/tmp/.qp-live-hosts.txt"
    comm -23 <(sort -u "$SESSION_DIR/subdomains/subdomains-final.txt") "$SESSION_DIR/state/tmp/.qp-live-hosts.txt" > "$SESSION_DIR/state/tmp/.qp-dead.txt"
    if [ -s "$SESSION_DIR/state/tmp/.qp-dead.txt" ] && command -v dnsx &>/dev/null; then
        dnsx -silent -l "$SESSION_DIR/state/tmp/.qp-dead.txt" -cname -retry 1 -timeout 5 2>/dev/null > "$SESSION_DIR/state/tmp/.qp-cnames.txt"
        [ -s "$SESSION_DIR/state/tmp/.qp-cnames.txt" ] && grep -iE '\[(s3[.-]amazonaws|s3-website|azurewebsites|azureedge|cloudapp|github\.io|herokuapp|herokussl|fastly|myshopify|shopify|unbouncepages|webflow|netlify|surge|pantheon|tumblr|wpengine|kinsta|fly\.dev|onrender|digitaloceanspaces|blob\.core\.windows)' "$SESSION_DIR/state/tmp/.qp-cnames.txt" >> "$SESSION_DIR/findings/probes/takeover.txt"
    fi
    rm -f "$SESSION_DIR/state/tmp/.qp-live-hosts.txt" "$SESSION_DIR/state/tmp/.qp-dead.txt" "$SESSION_DIR/state/tmp/.qp-cnames.txt"
    cp "$SESSION_DIR/findings/secrets/websockets.txt" "$SESSION_DIR/findings/probes/ws-probes.txt" 2>/dev/null || :
    cp "$SESSION_DIR/findings/secrets/graphql.txt" "$SESSION_DIR/findings/probes/graphql-mutations.txt" 2>/dev/null || :
    grep -Ei '\b(create|update|delete|submit|register|upload|checkout)\b' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | grep -vE '\.(js|css|png|svg|woff)(\?|$)' | head -40 > "$SESSION_DIR/findings/probes/post-probe.txt"
    grep -F ' -> 200' "$SESSION_DIR/findings/probes/hidden-endpoints.txt" 2>/dev/null | grep -iE '/(admin|config|backup|internal|debug|dashboard|manage|private|secret)' | grep -viE '/(login|auth)(/|$)' > "$SESSION_DIR/findings/probes/auth-bypass.txt" || :
    : > "$SESSION_DIR/findings/probes/csp-deep.txt"
    grep -vE '^https?://[^/]+:[0-9]+(/|$)' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | head -20 | while IFS= read -r _cu; do
        [ -z "$_cu" ] && continue
        _csp=$(http_head "$_cu" 2>/dev/null | grep -i '^content-security-policy:' | tr -d '\r' | cut -d: -f2- | sed 's/^ *//')
        if [ -z "$_csp" ]; then
            echo "$_cu no CSP header" >> "$SESSION_DIR/findings/probes/csp-deep.txt"
            continue
        fi
        printf '%s' "$_csp" | grep -qi 'unsafe-inline' && echo "$_cu CSP allows unsafe-inline" >> "$SESSION_DIR/findings/probes/csp-deep.txt"
        printf '%s' "$_csp" | grep -qi 'unsafe-eval'  && echo "$_cu CSP allows unsafe-eval" >> "$SESSION_DIR/findings/probes/csp-deep.txt"
        printf '%s' "$_csp" | grep -qE '(^|;) *(default-src|script-src) [^;]*( \*| \*\.|[.]\* )' && echo "$_cu CSP has wildcard source" >> "$SESSION_DIR/findings/probes/csp-deep.txt"
        printf '%s' "$_csp" | grep -qi 'data:' && echo "$_cu CSP allows data: URIs" >> "$SESSION_DIR/findings/probes/csp-deep.txt"
    done
    : > "$SESSION_DIR/findings/probes/surface-matrix.txt"
    head -30 "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | xargs -d '\n' -P 15 -I {} bash -c '
        c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" "$1" 2>/dev/null)
        echo "$c $1" >> "'"$SESSION_DIR"'/findings/probes/surface-matrix.txt"
    ' _ {}
    sort -o "$SESSION_DIR/findings/probes/surface-matrix.txt" "$SESSION_DIR/findings/probes/surface-matrix.txt" 2>/dev/null || true
    : > "$SESSION_DIR/findings/probes/method-anomalies.txt"
    head -10 "$SESSION_DIR/urls/urls-api.txt" 2>/dev/null | while IFS= read -r u; do
        [ -z "$u" ] && continue
        for m in TRACE PUT DELETE PATCH; do
            c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" -X "$m" "$u" 2>/dev/null)
            case "$c" in 2*|401) echo "$m $u -> $c" >> "$SESSION_DIR/findings/probes/method-anomalies.txt" ;; esac
        done
    done
    if [ -s "$SESSION_DIR/urls/urls-reflection-candidates.txt" ]; then
        head -30 "$SESSION_DIR/urls/urls-reflection-candidates.txt" | xargs -d '\n' -P 10 -I {} bash -c '
            u="$1"; sep="?"; case "$u" in *\?*) sep="&" ;; esac
            b1=$(curl -s -m 10 -A "$FAKE_UA" "$u${sep}ssti=zz\${711*711}zz" 2>/dev/null)
            printf "%s" "$b1" | grep -q "505521" && echo "[HIGH] SSTI dollar-brace evaluates: $u" >> "'"$SESSION_DIR"'/findings/probes/bounty-extras.txt"
            b2=$(curl -s -m 10 -A "$FAKE_UA" "$u${sep}ssti=zz{{711*711}}zz" 2>/dev/null)
            printf "%s" "$b2" | grep -q "505521" && echo "[HIGH] SSTI double-brace evaluates: $u" >> "'"$SESSION_DIR"'/findings/probes/bounty-extras.txt"
        ' _ {}
    fi
    if [ -s "$SESSION_DIR/findings/secrets/auth-tokens.txt" ]; then
        grep -oP 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' "$SESSION_DIR/findings/secrets/auth-tokens.txt" 2>/dev/null | sort -u | head -5 | while read -r _jw; do
            _p64=$(printf '%s' "$_jw" | cut -d. -f2)
            _pad=$(( (4 - ${#_p64} % 4) % 4 )); [ "$_pad" -gt 0 ] && _p64="${_p64}$(printf '=%.0s' $(seq 1 "$_pad"))"
            _pl=$(printf '%s' "$_p64" | tr '_-' '/+' | base64 -d 2>/dev/null)
            _exp=$(printf '%s' "$_pl" | grep -oP '"exp":\s*\K[0-9]+' | head -1)
            if [ -n "$_exp" ] && [ "$_exp" -gt "$(date +%s)" ]; then
                echo "[HIGH] JWT VALID (exp $_exp): ${_jw:0:24}... iss=$(printf '%s' "$_pl" | grep -oP '\"iss\":\s*\"[^\"]+' | head -1 | cut -c9-40)" >> "$SESSION_DIR/findings/probes/bounty-extras.txt"
            fi
            _none="eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.$(printf '%s' "$_jw" | cut -d. -f2)."
            _ep=$(head -1 "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" 2>/dev/null); [ -z "$_ep" ] && _ep="/"
            grep -vE ':[0-9]+$' "$SESSION_DIR/hosts/hosts-live.txt" 2>/dev/null | head -2 | while read -r _h; do
                _ho=$(printf '%s' "$_h" | awk -F/ '{print $1"//"$3}')
                _c=$(curl -s -o /dev/null -w "%{http_code}" -m 8 -A "$FAKE_UA" -H "Authorization: Bearer $_none" "$_ho$_ep" 2>/dev/null)
                [ "$_c" = "200" ] && echo "[CRITICAL] JWT alg:none ACCEPTED at $_ho$_ep" >> "$SESSION_DIR/findings/probes/bounty-extras.txt"
            done
        done
    fi
    head -10 "$SESSION_DIR/state/tmp/.qp-origins.txt" 2>/dev/null | while read -r _ho; do
        _hb=$(curl -s -m 10 -A "$FAKE_UA" -H "X-Forwarded-Host: evil.example" -H "X-Forwarded-For: 127.0.0.1" "$_ho" 2>/dev/null)
        printf '%s' "$_hb" | grep -q "evil.example" && echo "[MEDIUM] Host-header reflected (reset-poisoning candidate): $_ho" >> "$SESSION_DIR/findings/probes/bounty-extras.txt"
    done
    rm -f "$SESSION_DIR/state/tmp/.qp-origins.txt" "$SESSION_DIR/state/tmp/.qp-patterns.txt"
    local _pf
    for _pf in "$SESSION_DIR/findings/probes"/*.txt; do
        [ -s "$_pf" ] || continue
    done
}
cleanup() {
    rm -rf "$SESSION_DIR/state/tmp" 2>/dev/null || true
    out "${C_W}Session state preserved at $SESSION_DIR/state${C_R}"
}
main() {
    [ -t 6 ] && clear
    out "${C_K}____________________________________________________________________________________${C_R}"
    out "${C_K}_____________________________ github.com/Ln0rag/reconly ____________________________${C_R}"
    out "${C_K}____________________________________________________________________________________${C_R}"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ R E C O N L Y${C_R} -d ${C_GRN}$DOMAIN${C_R}"
    check_tools
    ensure_runtime_deps
    maybe_fresh_restart "$@"

    run_stage "Subdomains" st_subdomains || true
    run_stage "Hosts" st_hosts_lite || true
    run_stage "Archive" st_archive || true
    run_stage "Crawl" st_crawl || true
    run_stage "Classify" st_classify_js || true
    run_stage "js-pipeline" st_js_pipeline || true
    run_stage "Local analysis" st_analysis_local || true
    run_stage "App surface" st_app_surface || true
    run_stage "Context" st_context || true
    run_stage "Quick-probes" st_quick_probes || true

    cleanup

    out ""
    out "${C_W}Session: $SESSION_DIR${C_R}"
    
    { { command -v notify-send >/dev/null && timeout 5 notify-send "Reconly" "Finished" || command -v kdialog >/dev/null && timeout 5 kdialog --passivepopup "Reconly: Finished" 5 || command -v zenity >/dev/null && timeout 5 zenity --notification --text="Reconly: Finished"; } & f=/usr/share/sounds/freedesktop/stereo/complete.oga; { [ -f "$f" ] && { timeout 5 pw-play "$f" || timeout 5 paplay "$f" || timeout 5 ogg123 -q "$f" || timeout 5 mpv --no-video --really-quiet "$f"; } || timeout 5 canberra-gtk-play -i complete || printf ''; }; wait; } 2>/dev/null

}
main "$@"
