#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
umask 077
export LC_ALL=C
export PATH="$PATH:$HOME/go/bin"
export CODEQL_ALLOW_INSTALLATION_ANYWHERE=true

RECONLY_MAX_PAGES=2500
RECONLY_JS_THREADS=15
RECONLY_FETCH_THREADS=30
FAKE_UA="${FAKE_UA:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36}"
RESOLVERS="${RESOLVERS:-$HOME/github-tools/resolvers.txt}"
PRETTIER_MAX_MB=150
PRETTIER_BATCH=20
OBF_MAX_FILES=50
JS_MAX_ROUNDS=4
JS_PORTS="22 80 443 3000 4000 5000 6000 7000 8000 8080 8443 9000 8888 9999"
KATANA_RL="${KATANA_RL:-40}"
RECONLY_AUTO_INSTALL="${RECONLY_AUTO_INSTALL:-1}"
RECONLY_CHECK_UPDATES="${RECONLY_CHECK_UPDATES:-1}"
TOOLS_HOME="${TOOLS_HOME:-$HOME/github-tools}"
JITTER_MIN=100
JITTER_MAX=300
PRETTIER_JOBS=$(command -v nproc >/dev/null 2>&1 && nproc || echo 3)
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
    local t0 t1 stat rc
    t0=$(date +%s)
    export CURRENT_STAGE="$name"
    : > "$SESSION_DIR/state/tmp/stage-notes-$name.txt" 2>/dev/null || true
    out ""
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_BLU} $name${C_R}"
    out ""
    shift
    if "$@"; then rc=0; else rc=$?; fi
    t1=$(date +%s)
    stat=$(tr -d '\n' < "$SESSION_DIR/state/tmp/stage-notes-$name.txt" 2>/dev/null); stat="${stat%; }"
    [ -z "$stat" ] && stat="-"
    printf '%s\t%s\t%s\t%s\n' "$name" "$rc" "-" "$stat" >> "$STAGE_LOG"
    return 0
}
stage_note() {
    [ -n "${SESSION_DIR:-}" ] && printf '%s; ' "$1" >> "$SESSION_DIR/state/tmp/stage-notes-${CURRENT_STAGE:-misc}.txt" 2>/dev/null
    return 0
}
trap_ctrlc() {
    trap '' SIGINT SIGTERM SIGQUIT
    kill -TERM -- -$$ 2>/dev/null || true
    pkill -TERM -P $$ 2>/dev/null || true
    sleep 1 2>/dev/null || true
    [ -n "${SESSION_DIR:-}" ] && [ -d "$SESSION_DIR/state/tmp" ] && rm -rf "$SESSION_DIR/state/tmp" 2>/dev/null
    stty sane 2>/dev/null || true
    out "${C_RED}Scan halted — Cleanup complete${C_R}"
    kill -KILL -- -$$ 2>/dev/null || true
    exit 130
}
trap trap_ctrlc SIGINT
trap trap_ctrlc SIGTERM

VERIFY_TOKENS=0
_args=()
for _a in "$@"; do
    case "$_a" in
        --verify-tokens) VERIFY_TOKENS=1 ;;
        *) _args+=("$_a") ;;
    esac
done
set -- "${_args[@]+"${_args[@]}"}"

RAW_DOMAIN=""
AUTH_COOKIE=""
CK_ARG=""
EXTRA_HEADERS=()

while getopts "d:c:H:h" opt; do
    case $opt in
        d) RAW_DOMAIN="$OPTARG" ;;
        c) AUTH_COOKIE="$OPTARG"; CK_ARG="$OPTARG" ;;
        H) EXTRA_HEADERS+=("$OPTARG") ;;
        h)
            echo "Usage: reconly.sh -d domain.com [-c cookie_file] [-H 'Header: value'] [--verify-tokens]"
            exit 0
            ;;
        \?) echo "Invalid option"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
if [ "$#" -gt 0 ] && [ -n "$CK_ARG" ] && [ -f "$CK_ARG $1" ]; then
    out "${C_Y}[warn] -c path was split by an unquoted space -- auto-joined: "$CK_ARG $1" (quote paths with spaces next time)${C_R}"
    AUTH_COOKIE="$CK_ARG $1"
    CK_ARG="$AUTH_COOKIE"
    shift
fi
if [ "$#" -gt 0 ]; then
    out "${C_Y}[warn] ignoring unexpected extra argument(s): $* -- if a path contains spaces, quote it${C_R}"
fi

[ -z "$RAW_DOMAIN" ] && die "Missing -d domain"

if [ -n "$AUTH_COOKIE" ] && [ -f "$AUTH_COOKIE" ]; then
    CK_FILE="$AUTH_COOKIE"
    _ck_flatten() { awk '!/^#/ && NF>=7 {printf "%s=%s; ", $6, $7}' "$1" | sed 's/; $//'; }
    if head -1 "$CK_FILE" 2>/dev/null | grep -qi 'Netscape HTTP Cookie File'; then
        out "${C_Y}Netscape cookie jar detected, flattening${C_R}"
        AUTH_COOKIE=$(_ck_flatten "$CK_FILE")
    elif grep -qE '^[^#[:space:]]+[[:space:]]+(TRUE|FALSE)[[:space:]]+' "$CK_FILE" 2>/dev/null; then
        out "${C_Y}Netscape-style cookie jar detected, flattening${C_R}"
        AUTH_COOKIE=$(_ck_flatten "$CK_FILE")
    else
        AUTH_COOKIE=$(tr -d '\r\n' < "$CK_FILE")
    fi
    unset -f _ck_flatten 2>/dev/null || true
fi
if [ -n "$CK_ARG" ] && [ ! -f "$CK_ARG" ]; then
    case "$AUTH_COOKIE" in
        *=*) : ;;
        *) die "-c cookie file not found: '$CK_ARG' -- quote paths containing spaces" ;;
    esac
fi
if [ -n "$CK_ARG" ] && [ -f "$CK_ARG" ]; then
    case "$AUTH_COOKIE" in
        *=*) : ;;
        *) die "-c file '$CK_ARG' does not look like a cookie (no name=value pairs, no Netscape header)" ;;
    esac
fi

DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|^www\.||')
DOMAIN_ESCAPED="${DOMAIN//./\.}"
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die "Invalid domain: $DOMAIN"

if [ ! -f "$RESOLVERS" ]; then
    mkdir -p "$(dirname "$RESOLVERS")"
    if curl -sf -m 20 "https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt" -o "$RESOLVERS" 2>/dev/null \
       && grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$RESOLVERS"; then
        out "${C_W}resolvers.txt downloaded ($(wc -l < "$RESOLVERS" | tr -d ' ') entries)${C_R}"
    else
        out "${C_Y}resolvers.txt unavailable, using dnsx defaults${C_R}"
        rm -f "$RESOLVERS"
    fi
fi

TOOL_LIST=(codeql subfinder httpx katana semgrep trivy syft grype noseyparker waymore gitleaks alterx dnsx gau gospider assetfinder jsluice findomain trufflehog jq detect-secrets retire)

declare -A TOOL_INSTALL=(
    [subfinder]='go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest'
    [assetfinder]='go install github.com/tomnomnom/assetfinder@latest'
    [findomain]='ver=$(curl -s https://api.github.com/repos/Findomain/Findomain/releases/latest | jq -r .tag_name | sed "s/^v//") && cd "$HOME/github-tools" && wget -q https://github.com/Findomain/Findomain/releases/latest/download/findomain-linux.zip -O findomain.zip && unzip -o findomain.zip && chmod +x findomain && rm -f findomain.zip && mkdir -p "$HOME/github-tools/.tool-versions" && printf "%s\n" "$ver" > "$HOME/github-tools/.tool-versions/findomain"'
    [alterx]='go install -v github.com/projectdiscovery/alterx/cmd/alterx@latest'
    [dnsx]='go install -v github.com/projectdiscovery/dnsx/cmd/dnsx@latest'
    [httpx]='go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest'
    [katana]='go install github.com/projectdiscovery/katana/cmd/katana@latest'
    [gau]='go install -v github.com/lc/gau/v2/cmd/gau@latest'
    [gospider]='go install -v github.com/jaeles-project/gospider@latest'
    [trufflehog]='ver=$(curl -s https://api.github.com/repos/trufflesecurity/trufflehog/releases/latest | jq -r .tag_name | sed "s/^v//") && seg_dl "https://github.com/trufflesecurity/trufflehog/releases/download/v${ver}/trufflehog_${ver}_linux_amd64.tar.gz" /tmp/trufflehog.tgz && tar -xzf /tmp/trufflehog.tgz -C "$HOME/github-tools" && rm -f /tmp/trufflehog.tgz && mkdir -p "$HOME/github-tools/.tool-versions" && printf "%s\n" "$ver" > "$HOME/github-tools/.tool-versions/trufflehog"'
    [jsluice]='go install -v github.com/BishopFox/jsluice/cmd/jsluice@latest'
    [gitleaks]='go install -v github.com/zricethezav/gitleaks/v8@latest'
    [detect-secrets]='pip_install_tool detect-secrets detect-secrets'
    [noseyparker]='mkdir -p "$HOME/github-tools" "$HOME/.cache/np-install" && rm -rf "$HOME/.cache/np-install"/* && ver=$(curl -s https://api.github.com/repos/praetorian-inc/noseyparker/releases/latest | jq -r .tag_name | sed "s/^v//") && _u=$(curl -s https://api.github.com/repos/praetorian-inc/noseyparker/releases/latest | jq -r ".assets[] | select(.name | test(\"x86_64-unknown-linux-gnu.tar.gz$\")) | .browser_download_url" | head -1) && [ -n "$_u" ] && [ "$_u" != "null" ] && seg_dl "$_u" "$HOME/.cache/np-install/np.tgz" && tar -xzf "$HOME/.cache/np-install/np.tgz" -C "$HOME/.cache/np-install" && _b=$(find "$HOME/.cache/np-install" -type f -name noseyparker -perm -u+x | head -1) && [ -n "$_b" ] && cp -f "$_b" "$HOME/github-tools/noseyparker" && chmod +x "$HOME/github-tools/noseyparker" && rm -rf "$HOME/.cache/np-install" && mkdir -p "$HOME/github-tools/.tool-versions" && printf "%s\n" "$ver" > "$HOME/github-tools/.tool-versions/noseyparker"'
    [trivy]='ver=$(curl -s https://api.github.com/repos/aquasecurity/trivy/releases/latest | jq -r .tag_name | sed "s/^v//") && seg_dl "https://github.com/aquasecurity/trivy/releases/download/v${ver}/trivy_${ver}_Linux-64bit.tar.gz" /tmp/trivy.tgz && mkdir -p "$HOME/github-tools" && tar -xzf /tmp/trivy.tgz -C "$HOME/github-tools" trivy && chmod +x "$HOME/github-tools/trivy" && rm -f /tmp/trivy.tgz && mkdir -p "$HOME/github-tools/.tool-versions" && printf "%s\n" "$ver" > "$HOME/github-tools/.tool-versions/trivy"'
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
    out "${C_W}re-running: $0 $*${C_R}"
    rm -rf "$SESSION_DIR" 2>/dev/null || true
    exec "$0" "$@"
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
    cat "$_tmp"/p??? > "$_out" 2>/dev/null
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
    _url=$(printf '%s' "$_html" | python3 - "$_idx" 2>/dev/null <<'PYEOF'
import sys, re, urllib.parse
base, html = sys.argv[1], sys.stdin.read()
best = None
for href, name in re.findall(r'href="([^"]+\.whl)#sha256=[0-9a-f]+"[^>]*>([^<]+)</a>', html):
    if 'x86_64' in name and ('manylinux' in name or 'musllinux' in name):
        best = urllib.parse.urljoin(base, href)
print(best or '')
PYEOF
    )
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
    cat "$_d"/p??? > "$_d/$_fname" 2>/dev/null
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
        assetfinder) ( printf '' | timeout 15 assetfinder --subs-only >/dev/null 2>&1 ) 2>/dev/null; rc=$? ;;
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
        [assetfinder]='go:github.com/tomnomnom/assetfinder'
        [alterx]='go:github.com/projectdiscovery/alterx'
        [dnsx]='go:github.com/projectdiscovery/dnsx'
        [httpx]='go:github.com/projectdiscovery/httpx'
        [katana]='go:github.com/projectdiscovery/katana'
        [gau]='go:github.com/lc/gau/v2'
        [gospider]='go:github.com/jaeles-project/gospider'
        [jsluice]='go:github.com/BishopFox/jsluice'
        [gitleaks]='go:github.com/zricethezav/gitleaks/v8'
        [semgrep]='pypi:semgrep'
        [waymore]='pypi:waymore'
        [detect-secrets]='pypi:detect-secrets'
        [jq]='gh:jqlang/jq'
        [findomain]='gh:Findomain/Findomain'
        [trufflehog]='gh:trufflesecurity/trufflehog'
        [noseyparker]='gh:praetorian-inc/noseyparker'
        [trivy]='gh:aquasecurity/trivy'
        [syft]='gh:anchore/syft'
        [grype]='gh:anchore/grype'
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
                go)   latest=$(curl -s -m 5 "https://proxy.golang.org/${ref}/@latest" 2>/dev/null | jq -r '.Version // empty' 2>/dev/null) ;;
                pypi) latest=$(curl -s -m 5 "https://pypi.org/pypi/${ref}/json" 2>/dev/null | jq -r '.info.version // empty' 2>/dev/null) ;;
                gh)   latest=$(curl -s -m 5 "https://api.github.com/repos/${ref}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null) ;;
            esac
            latest=$(printf '%s' "$latest" | sed -e 's/^v//' -e 's/^jq-//' | grep -E '^[0-9]' || true)
            [ -n "$latest" ] && printf '%s=%s\n' "$t" "$latest" >> "$tmp"
        ) &
    done
    wait
    { printf '#%s\n' "$hb"; grep -v '^#' "$tmp" 2>/dev/null | sort -u; } > "$cache.$$" 2>/dev/null && mv -f "$cache.$$" "$cache"
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
            trivy)
                v=$(timeout --foreground 5 trivy --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1) ;;
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
    local -a _disp=( "${_utils[@]}" jq codeql subfinder httpx katana semgrep trivy syft grype noseyparker waymore gitleaks alterx dnsx gau gospider assetfinder jsluice findomain trufflehog detect-secrets retire )
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
            _latest=$(awk -F= -v k="$_t" '$1==k{print $2; exit}' "$HOME/github-tools/.tool-versions/.updatable" 2>/dev/null)
            if [ -n "$_latest" ] && [ "$_v" != "unknown" ]; then
                case "$_v" in
                    dev-*) ;;
                    *) _ver_lt "$_v" "$_latest" && _up="  ${C_Y}[UP]${C_R}" ;;
                esac
            fi
            local _line="${C_GRN}[installed]${C_R} ${C_W}$_t${_tpad}${C_R}${C_Y}v $_vdisp${_vpad}${C_R}dir ${C_MAG}$_p${_gsfx}${C_R}$_up"
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

export SESSION_DIR DOMAIN DOMAIN_ESCAPED FAKE_UA RESOLVERS \
    RECONLY_JS_THREADS RECONLY_FETCH_THREADS RECONLY_MAX_PAGES JS_MAX_ROUNDS KATANA_HEADLESS \
    PRETTIER_JOBS PRETTIER_BATCH PRETTIER_MAX_MB OBF_MAX_FILES JITTER_MIN JITTER_MAX

STAGE_LOG="$SESSION_DIR/state/stage-log.tsv"
: > "$STAGE_LOG"

LOCK_FILE="$BASE_DIR/.lock"
exec 300>"$LOCK_FILE"
if ! flock -n 300; then
    die "Another reconly run is active on $DOMAIN (lock: $LOCK_FILE). Wait or rm it."
fi

: > state/headers.txt
if [ -n "$AUTH_COOKIE" ]; then
    printf 'Cookie: %s\n' "$AUTH_COOKIE" >> state/headers.txt
fi
for _eh in "${EXTRA_HEADERS[@]+${EXTRA_HEADERS[@]}}"; do
    printf '%s\n' "$_eh" >> state/headers.txt
done

exec 6>&1
exec > >(tee -a "$SESSION_DIR/reconly.log") 2>&1
out "${C_W}console mirror active -- full output (results, progress, everything) -> $SESSION_DIR/reconly.log${C_R}"

_jitter() { sleep "$(awk -v min="$JITTER_MIN" -v max="$JITTER_MAX" 'BEGIN{srand(); print (min+rand()*(max-min))/1000}')"; }
build_c_hdr() {
    c_hdr=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && c_hdr+=(-H "$line")
    done < "$SESSION_DIR/state/headers.txt"
}
http_get() {
    local url="$1" out="$2"
    local c_hdr=(); build_c_hdr
    _jitter
    curl -s -f -k -L --compressed -m 20 -A "$FAKE_UA" "${c_hdr[@]+${c_hdr[@]}}" "$url" -o "$out" 2>/dev/null
}
http_code() {
    local url="$1"
    local c_hdr=(); build_c_hdr
    _jitter
    curl -s -o /dev/null -w "%{http_code}" -m 15 -A "$FAKE_UA" "${c_hdr[@]+${c_hdr[@]}}" "$url" 2>/dev/null
}
http_head() {
    local url="$1"
    local c_hdr=(); build_c_hdr
    _jitter
    curl -s -o /dev/null -D - -m 15 -A "$FAKE_UA" "${c_hdr[@]+${c_hdr[@]}}" "$url" 2>/dev/null
}
http_post_json() {
    local url="$1" data="$2"
    local c_hdr=(); build_c_hdr
    _jitter
    curl -s -m 15 -X POST -H "Content-Type: application/json" -A "$FAKE_UA" "${c_hdr[@]+${c_hdr[@]}}" -d "$data" "$url" 2>/dev/null
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
    local c_hdr=(); build_c_hdr
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
    JS_LAST_CODE=$(curl -s -f -k -L --compressed -m 20 --connect-timeout 6 --max-filesize 52428800 -A "$FAKE_UA" -D "$tmp.hdr" "${c_hdr[@]+${c_hdr[@]}}" "$url" -o "$tmp" -w "%{http_code}" 2>/dev/null) || curl_rc=$?
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
        [ -n "$jh" ] && printf '%s|%s\n' "$jh" "$name" >> "$SESSION_DIR/state/js-content-hashes.txt"
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
        n=$(wc -l < "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null | tr -d '[:space:]')
        total=$(cat "$SESSION_DIR/state/tmp/.js-total" 2>/dev/null)
        if [ $(( ${n:-0} % 25 )) -eq 0 ] || [ "${n:-?}" = "${total:-?}" ]; then
            printf '[%s/%s] %s:%s: %s\n' "${n:-?}" "${total:-?}" "$st" "$code" "$url"
        fi
    ) 201>"$SESSION_DIR/state/.jsprog.lock"
}
page_fetch() {
    local page="$1"
    local phash psafe pfile ptmp inline_file inline_content inline_bytes
    PAGE_LAST_CODE="-"
    local c_hdr=(); build_c_hdr
    phash=$(printf '%s' "$page" | md5sum | cut -c1-16)
    psafe=$(echo "$page" | sed -e 's|^https*://||' -e 's/[^A-Za-z0-9.]/_/g' -e 's/__*/_/g')
    psafe="${psafe:0:60}"
    pfile="$SESSION_DIR/js/raw/page_${psafe}-${phash}.html"
    ptmp="${pfile}.part.$$"
    inline_file="$SESSION_DIR/js/raw/page_${psafe}-${phash}.js"

    [ -s "$pfile" ] || {
        PAGE_LAST_CODE="000"
        _jitter
        PAGE_LAST_CODE=$(curl -s -f -k -L --compressed -m 20 --connect-timeout 6 -A "$FAKE_UA" "${c_hdr[@]+${c_hdr[@]}}" "$page" -o "$ptmp" -w "%{http_code}" 2>/dev/null)
        [ -n "$PAGE_LAST_CODE" ] || PAGE_LAST_CODE="000"
        if [ "$PAGE_LAST_CODE" != "000" ] && [ -s "$ptmp" ]; then
            mv -f -- "$ptmp" "$pfile"
        else
            rm -f "$ptmp"; return 1
        fi
    }

    ph=$(sha256sum "$pfile" 2>/dev/null | awk '{print $1}')
    if [ -n "$ph" ] && [ -s "$SESSION_DIR/state/page-hashes.txt" ] && grep -Fqx "$ph" "$SESSION_DIR/state/page-hashes.txt" 2>/dev/null; then
        return 0
    fi
    [ -n "$ph" ] && printf '%s\n' "$ph" >> "$SESSION_DIR/state/page-hashes.txt"

    [ -s "$inline_file" ] && return 0
    inline_content=$(perl -0777 -ne 'while (/<script(?![^>]*\bsrc=)[^>]*>(.*?)<\/script>/gis) { print "$1\n" }' "$pfile" 2>/dev/null)
    if [ -n "$inline_content" ]; then
        inline_bytes=$(printf '%s' "$inline_content" | wc -c)
        if [ "$inline_bytes" -ge 20 ]; then
            ih=$(printf '%s' "$inline_content" | sha256sum 2>/dev/null | awk '{print $1}')
            if [ -n "$ih" ] && ! grep -Fqx "$ih" "$SESSION_DIR/state/page-hashes.txt" 2>/dev/null; then
                printf '%s\n' "$ih" >> "$SESSION_DIR/state/page-hashes.txt"
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
            [ -n "$base_dir" ] || base_dir="/"
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
    local c_hdr=(); build_c_hdr
    jsname="${line%%:*}"
    mapref=$(printf '%s' "$line" | sed 's/^[^:]*:[0-9]*://' | sed 's/^sourceMappingURL\s*=\s*//')
    orig_url=$(awk -F'|' -v f="$jsname" '$1==f{print $2; exit}' "$SESSION_DIR/state/url-map.txt" 2>/dev/null)
    [ -z "$orig_url" ] && return 0
    map_url=$(resolve_url "$orig_url" "$mapref")
    mapname="${jsname%.js}-$(printf '%s' "$mapref" | md5sum | cut -c1-6).map"

    [ -s "$SESSION_DIR/js/sourcemaps/$mapname" ] || {
        if curl -s -f -k -L --compressed -m 20 -A "$FAKE_UA" "${c_hdr[@]+${c_hdr[@]}}" "$map_url" -o "$SESSION_DIR/js/sourcemaps/.${mapname}.part.$$" 2>/dev/null && [ -s "$SESSION_DIR/js/sourcemaps/.${mapname}.part.$$" ]; then
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
        if curl -s -f -k -L --compressed -m 20 -A "$FAKE_UA" "${c_hdr[@]+${c_hdr[@]}}" "$resolved" -o "$SESSION_DIR/js/mapsrc/.${fname}.part.$$" 2>/dev/null && [ -s "$SESSION_DIR/js/mapsrc/.${fname}.part.$$" ]; then
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
export -f out
export -f _jitter build_c_hdr http_get http_code http_head http_post_json url_junk_filter js_name_for_url record_js_map js_fetch js_progress page_fetch resolve_url recover_one_sourcemap extract_map_sources

adapt_threads() {
    local _log="$SESSION_DIR/state/tmp/.js-progress.log"
    [ -s "$_log" ] || return 0
    local _tot _429n
    _tot=$(wc -l < "$_log" 2>/dev/null | tr -d ' '); _tot=${_tot:-0}
    _429n=$(awk -F'[:|]' '$1=="FAIL" && $2=="429"{c++} END{print c+0}' "$_log" 2>/dev/null); _429n=${_429n:-0}
    _errn=$(awk -F'[:|]' '$1=="FAIL" && ($2=="502" || $2=="503" || $2=="000"){c++} END{print c+0}' "$_log" 2>/dev/null); _errn=${_errn:-0}
    if [ "$_tot" -gt 0 ] && [ "$((_429n * 10))" -gt "$_tot" ]; then
        RECONLY_FETCH_THREADS=$(( RECONLY_FETCH_THREADS / 2 ))
        [ "$RECONLY_FETCH_THREADS" -lt 5 ] && RECONLY_FETCH_THREADS=5
        export RECONLY_FETCH_THREADS
        out "${C_Y}[stealth] 429s = $((_429n * 100 / _tot))% of the wave -- concurrency down to $RECONLY_FETCH_THREADS${C_R}"
        stage_note "throttled=429:$RECONLY_FETCH_THREADS"
    elif [ "$_tot" -ge 40 ] && [ "$((_errn * 5))" -gt "$_tot" ]; then
        RECONLY_FETCH_THREADS=$(( RECONLY_FETCH_THREADS * 2 / 3 ))
        [ "$RECONLY_FETCH_THREADS" -lt 5 ] && RECONLY_FETCH_THREADS=5
        export RECONLY_FETCH_THREADS
        out "${C_Y}[stealth] server stress ($_errn x 502/000 = $((_errn * 100 / _tot))%) -- concurrency down to $RECONLY_FETCH_THREADS${C_R}"
        stage_note "throttled=stress:$RECONLY_FETCH_THREADS"
    fi
    return 0
}

_blind_map_probe() {
    {
        [ -s "$SESSION_DIR/state/tmp/.js-round-fetched.txt" ] && cat "$SESSION_DIR/state/tmp/.js-round-fetched.txt"
        [ -s "$SESSION_DIR/urls/urls-js.txt" ] && cat "$SESSION_DIR/urls/urls-js.txt"
    } | sort -u | tr -d '\r' | awk 'NF' > "$SESSION_DIR/state/tmp/.blind-all.txt"
    comm -23 "$SESSION_DIR/state/tmp/.blind-all.txt" <(sort -u "$SESSION_DIR/state/blind-probed.txt") > "$SESSION_DIR/state/tmp/.blind-targets.txt"
    rm -f "$SESSION_DIR/state/tmp/.blind-all.txt"
    local targets
    targets=$(wc -l < "$SESSION_DIR/state/tmp/.blind-targets.txt" | tr -d ' ')
    [ "$targets" -eq 0 ] && { rm -f "$SESSION_DIR/state/tmp/.blind-targets.txt"; return; }

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} -s -o /dev/null -w %{http_code} -m 10 {base}.map + {base}.js.map   (blind probe, 50/chunk, $targets URLs)"
    : > "$SESSION_DIR/state/tmp/.blind-found.txt"
    split -l 50 "$SESSION_DIR/state/tmp/.blind-targets.txt" "$SESSION_DIR/state/tmp/.blind-chunk-"
    for chunk in "$SESSION_DIR/state/tmp/.blind-chunk-"*; do
        [ -e "$chunk" ] || continue
        cat "$chunk" | xargs -d '\n' -P "$RECONLY_JS_THREADS" -I {} bash -c '
            js="$1"; base="${js%%\?*}"; case "$base" in *.js) ;; *) exit 0 ;; esac
            c_hdr=(); build_c_hdr
            for m in "${base}.map" "$(printf "%s" "$base" | sed "s/\.js$/.js.map/")"; do
                [ "$m" = "$base" ] && continue
                code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "${c_hdr[@]+${c_hdr[@]}}" -A "$FAKE_UA" "$m" 2>/dev/null)
                [ "$code" = "200" ] && { printf "%s\n" "$m" >> "'"$SESSION_DIR/state/tmp/.blind-found.txt"'"; break; }
            done
        ' _ {}
        rm -f "$chunk"
    done
    [ -s "$SESSION_DIR/state/tmp/.blind-found.txt" ] && cat "$SESSION_DIR/state/tmp/.blind-found.txt" | sort -u >> "$SESSION_DIR/state/blind-maps-found.txt"
    cat "$SESSION_DIR/state/tmp/.blind-targets.txt" >> "$SESSION_DIR/state/blind-probed.txt"
    sort -u "$SESSION_DIR/state/blind-probed.txt" -o "$SESSION_DIR/state/blind-probed.txt"
    sort -u "$SESSION_DIR/state/blind-maps-found.txt" -o "$SESSION_DIR/state/blind-maps-found.txt"
    rm -f "$SESSION_DIR/state/tmp/.blind-targets.txt" "$SESSION_DIR/state/tmp/.blind-found.txt"

    if [ -s "$SESSION_DIR/state/blind-maps-found.txt" ]; then
        out "${C_W}Downloading blind maps${C_R}"
        cat "$SESSION_DIR/state/blind-maps-found.txt" | xargs -d '\n' -P "$RECONLY_JS_THREADS" -I {} bash -c '
            m="$1"; mapname="blind_$(printf "%s" "$m" | md5sum | cut -c1-8).map"
            [ -s "'"$SESSION_DIR/js/sourcemaps"'/$mapname" ] && exit 0
            grep -Fqx "$mapname" '"$SESSION_DIR/state/blind-failed.txt"' 2>/dev/null && exit 0
            c_hdr=(); build_c_hdr
            tmp="'"$SESSION_DIR/js/sourcemaps"'/.${mapname}.part.$$"
            if curl -s -m 30 "${c_hdr[@]+${c_hdr[@]}}" -A "$FAKE_UA" "$m" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
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
        out "${C_GRN}Blind maps extracted: $extracted | dup skipped: $skipped${C_R}"
        [ -s "$SESSION_DIR/state/blind-maps-found.txt" ] && { out "${C_W}Blind maps found:${C_R}"; cat "$SESSION_DIR/state/blind-maps-found.txt"; }
    fi
}
json_fetch() {
    local url="$1"
    local name tmp ct
    JSON_LAST_CODE="-"
    local c_hdr=(); build_c_hdr
    name=$(js_name_for_url "$url"); name="${name%.js}.json"
    tmp="$SESSION_DIR/js/json/.${name}.part.$$"
    if [ -s "$SESSION_DIR/js/json/$name" ]; then
        JSON_LAST_CODE="cached"
        ( flock -w 10 200 || exit 1
          grep -Fqx "$name|$url" "$SESSION_DIR/state/url-map.txt" 2>/dev/null || printf '%s|%s\n' "$name" "$url" >> "$SESSION_DIR/state/url-map.txt"
        ) 200>"$SESSION_DIR/state/.urlmap.lock"
        return 0
    fi
    rm -f "$tmp" "$tmp.hdr"
    JSON_LAST_CODE="000"
    _jitter
    JSON_LAST_CODE=$(curl -s -f -k -L --compressed -m 20 --connect-timeout 6 --max-filesize 52428800 -A "$FAKE_UA" -D "$tmp.hdr" "${c_hdr[@]+${c_hdr[@]}}" "$url" -o "$tmp" -w "%{http_code}" 2>/dev/null)
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
    local c_hdr=(); build_c_hdr
    name=$(js_name_for_url "$url")
    tmp="$SESSION_DIR/js/artifacts/.${name}.part.$$"
    if [ -s "$SESSION_DIR/js/artifacts/$name" ]; then ART_LAST_CODE="cached"; return 0; fi
    rm -f "$tmp"
    ART_LAST_CODE="000"
    _jitter
    ART_LAST_CODE=$(curl -s -f -k -L --compressed -m 20 --connect-timeout 6 --max-filesize 52428800 -A "$FAKE_UA" "${c_hdr[@]+${c_hdr[@]}}" "$url" -o "$tmp" -w "%{http_code}" 2>/dev/null)
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

st_subdomains() {
    local out="$SESSION_DIR/subdomains/raw"
    mkdir -p "$out"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ subfinder${C_R} -d '$DOMAIN' -all -recursive -rl 50 -t 100 -silent | sort -u | tee subdomains/raw/subfinder.txt || true"
    timeout --foreground 900 subfinder -d "$DOMAIN" -all -recursive -rl 50 -t 100 -silent | sort -u | tee "$out/subfinder.txt" || true
    out ""
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ assetfinder${C_R} --subs-only '$DOMAIN' | grep '\.$DOMAIN_ESCAPED$' | sort -u | tee subdomains/raw/assetfinder.txt || true"
    timeout --foreground 300 assetfinder --subs-only "$DOMAIN" 2>"$SESSION_DIR/state/tmp/assetfinder.err" | grep -E "(^|\.)${DOMAIN_ESCAPED}$" | sort -u | tee "$out/assetfinder.txt" || true
    if [ ! -s "$out/assetfinder.txt" ]; then
        out "${C_Y}[warn] assetfinder returned 0 subs (limited passive sources -- normal on some targets) -- stderr: $(tail -2 "$SESSION_DIR/state/tmp/assetfinder.err" 2>/dev/null | tr '\n' ' | ' | cut -c1-160)${C_R}"
    fi
    rm -f "$SESSION_DIR/state/tmp/assetfinder.err"
    out ""
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ findomain${C_R} -t '$DOMAIN' -q | sed 's/^\*\.//' | grep -E \"(^|\.)${DOMAIN_ESCAPED}$\" | sort -u | tee subdomains/raw/findomain.txt || true"
    timeout --foreground 300 findomain -t "$DOMAIN" -q | sed 's/^\*\.//' | grep -E "(^|\.)${DOMAIN_ESCAPED}$" | sort -u | tee "$out/findomain.txt" || true
    {
        [ -f "$out/subfinder.txt" ] && cat "$out/subfinder.txt"
        [ -f "$out/assetfinder.txt" ] && cat "$out/assetfinder.txt"
        [ -f "$out/findomain.txt" ] && cat "$out/findomain.txt"
    } | grep -viE '(transferprohibited|updateprohibited|deleteprohibited|renewprohibited|pending|redemptionperiod|clienthold|serverhold)' | sort -u > "$SESSION_DIR/subdomains/subdomains-all.txt"

    local total
    total=$(wc -l < "$SESSION_DIR/subdomains/subdomains-all.txt" | tr -d ' ')
    stage_note "subs=$total"
    out ""
    out "${C_GRN}Passive subdomains: $total${C_R}"
    cat "$SESSION_DIR/subdomains/subdomains-all.txt" 
    out ""

    local wip=""
    for i in 1 2 3; do
        local rnd="wchk${i}-$(date +%s)-${RANDOM}${RANDOM}"
        if [ -f "$RESOLVERS" ]; then
            wip=$(echo "$rnd.$DOMAIN" | dnsx -silent -r "$RESOLVERS" -a -resp 2>/dev/null | awk '{print $NF}' | head -1)
        else
            wip=$(echo "$rnd.$DOMAIN" | dnsx -silent -a -resp 2>/dev/null | awk '{print $NF}' | head -1)
        fi
        [ -n "$wip" ] && break
    done

    if [ -n "$wip" ]; then
        out "${C_Y}Wildcard DNS detected (*.$DOMAIN -> $wip), skipping permutations${C_R}"
        cp "$SESSION_DIR/subdomains/subdomains-all.txt" "$SESSION_DIR/subdomains/subdomains-final.txt"
    else
        local subcount
        subcount=$(wc -l < "$SESSION_DIR/subdomains/subdomains-all.txt" | tr -d ' ')
        if [ "$subcount" -gt 20000 ]; then
            out "${C_Y}Subs >20k, skipping alterx permutations${C_R}"
            cp "$SESSION_DIR/subdomains/subdomains-all.txt" "$SESSION_DIR/subdomains/subdomains-final.txt"
        else
            out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ cat${C_R} subdomains-all.txt | ${C_RED}alterx${C_R} -silent | sort -u > .perms.txt && ${C_RED}dnsx${C_R} -silent -l .perms.txt -a -resp -retry 1 -timeout 5 -t 250 | awk '{print \$1}' | sort -u > .perms-live.txt || true"
            cat "$SESSION_DIR/subdomains/subdomains-all.txt" | alterx -silent 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.perms.txt" || true
            if [ -s "$SESSION_DIR/state/tmp/.perms.txt" ]; then
                if [ -f "$RESOLVERS" ]; then
                    dnsx -silent -l "$SESSION_DIR/state/tmp/.perms.txt" -r "$RESOLVERS" -a -resp -retry 1 -timeout 5 -t 250 2>/dev/null | awk '{gsub(/\.$/,"",$1); print $1}' | sort -u > "$SESSION_DIR/state/tmp/.perms-live.txt" || true
                else
                    dnsx -silent -l "$SESSION_DIR/state/tmp/.perms.txt" -a -resp -retry 1 -timeout 5 -t 250 2>/dev/null | awk '{gsub(/\.$/,"",$1); print $1}' | sort -u > "$SESSION_DIR/state/tmp/.perms-live.txt" || true
                fi
                grep -E "(^|\.)${DOMAIN_ESCAPED}$" "$SESSION_DIR/state/tmp/.perms-live.txt" | sort -u > "$SESSION_DIR/state/tmp/.perms-live.txt.tmp" && mv "$SESSION_DIR/state/tmp/.perms-live.txt.tmp" "$SESSION_DIR/state/tmp/.perms-live.txt"
                comm -23 <(sort -u "$SESSION_DIR/state/tmp/.perms-live.txt") <(sort -u "$SESSION_DIR/subdomains/subdomains-all.txt") > "$SESSION_DIR/subdomains/subdomains-new.txt"
                cat "$SESSION_DIR/subdomains/subdomains-all.txt" "$SESSION_DIR/subdomains/subdomains-new.txt" 2>/dev/null | sort -u > "$SESSION_DIR/subdomains/subdomains-final.txt"
                local newc
                newc=$(wc -l < "$SESSION_DIR/subdomains/subdomains-new.txt" 2>/dev/null | tr -d ' '); newc=${newc:-0}
                stage_note "perms=$newc"
                out ""
                out "${C_GRN}Permutation subs: $newc${C_R}"
                cat "$SESSION_DIR/subdomains/subdomains-new.txt" 
                out ""
            else
                cp "$SESSION_DIR/subdomains/subdomains-all.txt" "$SESSION_DIR/subdomains/subdomains-final.txt"
            fi
        fi
    fi
    rm -f "$SESSION_DIR/state/tmp/.perms.txt" "$SESSION_DIR/state/tmp/.perms-live.txt"

    local prev=""
    prev=$(ls -td "$BASE_DIR"/*/ 2>/dev/null | head -2 | tail -1 | sed 's:/$::')
    if [ -n "$prev" ] && [ "$prev" != "$SESSION_DIR" ]; then
        local prev_subs=""
        [ -f "$prev/subdomains/subdomains-final.txt" ] && prev_subs="$prev/subdomains/subdomains-final.txt"
        [ -z "$prev_subs" ] && [ -f "$prev/all-subs-final.txt" ] && prev_subs="$prev/all-subs-final.txt"
        if [ -n "$prev_subs" ]; then
            comm -13 <(sort -u "$prev_subs") <(sort -u "$SESSION_DIR/subdomains/subdomains-final.txt") > "$SESSION_DIR/subdomains/subdomains-new-since-last.txt"
            local new_subs
            new_subs=$(wc -l < "$SESSION_DIR/subdomains/subdomains-new-since-last.txt" 2>/dev/null | tr -d ' '); new_subs=${new_subs:-0}
            [ "$new_subs" -gt 0 ] && { out "${C_GRN}$new_subs NEW since last scan:"; cat "$SESSION_DIR/subdomains/subdomains-new-since-last.txt"; }
        fi
    fi
}
st_hosts_lite() {
    mkdir -p "$SESSION_DIR/hosts" 2>/dev/null || true
    [ -s "$SESSION_DIR/subdomains/subdomains-final.txt" ] || { out "${C_Y}No subs, skipping hosts${C_R}"; return; }
    : > "$SESSION_DIR/subdomains/csp-domains.txt"
    while read -r _h; do
        [ -z "$_h" ] && continue
        for _p in $JS_PORTS; do printf '%s:%s\n' "$_h" "$_p"; done
    done < "$SESSION_DIR/subdomains/subdomains-final.txt" | sort -u > "$SESSION_DIR/hosts/ports.txt"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -l hosts/ports.txt -threads 200 -timeout 8 -status-code -tech-detect -title -location -ip -cname -tls-grab -websocket -favicon   (web ports only, no naabu)"
    timeout --foreground 900 httpx -silent -l "$SESSION_DIR/hosts/ports.txt" -threads 200 -timeout 8 -status-code -tech-detect -title -location -ip -cname -tls-grab -websocket -favicon 2>/dev/null | awk '!seen[$0]++' | tee "$SESSION_DIR/hosts/httpx-raw.txt" || true
    grep -E '^https?://' "$SESSION_DIR/hosts/httpx-raw.txt" | awk '{print $1}' | sort -u | awk '{rest=substr($0, index($0,"//")+2); if(!(rest in out) || $0 ~ /^https:/){out[rest]=$0}} END{for(k in out) print out[k]}' | sort > "$SESSION_DIR/hosts/hosts-live.txt"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -u '$DOMAIN' -status-code -tech-detect -title -location -ip -cname   (apex spot-check)"
    if ! grep -qE "^https?://${DOMAIN_ESCAPED}$" "$SESSION_DIR/hosts/hosts-live.txt" 2>/dev/null; then
        timeout --foreground 300 httpx -silent -u "$DOMAIN" -status-code -tech-detect -title -location -ip -cname 2>/dev/null | tee "$SESSION_DIR/state/tmp/.apex.txt" || true
        grep -E '^https?://' "$SESSION_DIR/state/tmp/.apex.txt" 2>/dev/null | awk '{print $1}' >> "$SESSION_DIR/hosts/hosts-live.txt"
        sort -u "$SESSION_DIR/hosts/hosts-live.txt" -o "$SESSION_DIR/hosts/hosts-live.txt"
        rm -f "$SESSION_DIR/state/tmp/.apex.txt"
    fi
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ openssl${C_R} s_client -connect <host>:443 -servername <host> | openssl x509 -noout -text   (TLS SAN mining, all live hosts)"
    : > "$SESSION_DIR/state/tmp/.tls-sans.txt"
    cat "$SESSION_DIR/hosts/hosts-live.txt" | xargs -d '\n' -P 10 -I {} bash -c '
        thost=$(printf "%s" "$1" | sed -E "s|^https?://([^:/]+).*|\1|")
        [ -n "$thost" ] || exit 0
        timeout --foreground 10 openssl s_client -connect "${thost}:443" -servername "$thost" </dev/null 2>/dev/null \
          | openssl x509 -noout -text 2>/dev/null \
          | grep -A1 "Subject Alternative Name" | grep -oE "DNS:[a-zA-Z0-9.-]+" | cut -d: -f2 >> "$SESSION_DIR/state/tmp/.tls-sans.txt" 2>/dev/null
    ' _ {}
    if [ -s "$SESSION_DIR/state/tmp/.tls-sans.txt" ]; then
        grep -E "(^|\.)${DOMAIN_ESCAPED}$" "$SESSION_DIR/state/tmp/.tls-sans.txt" | sort -u >> "$SESSION_DIR/subdomains/csp-domains.txt" 2>/dev/null
        sort -u "$SESSION_DIR/subdomains/csp-domains.txt" -o "$SESSION_DIR/subdomains/csp-domains.txt" 2>/dev/null
        local new_san
        new_san=$(comm -23 "$SESSION_DIR/subdomains/csp-domains.txt" <(sort -u "$SESSION_DIR/subdomains/subdomains-final.txt") | wc -l | tr -d ' ')
        [ "$new_san" -gt 0 ] && out "${C_Y}$new_san new hostnames from TLS SANs${C_R}"
        if [ "$new_san" -gt 0 ]; then
            comm -23 "$SESSION_DIR/subdomains/csp-domains.txt" <(sort -u "$SESSION_DIR/subdomains/subdomains-final.txt") > "$SESSION_DIR/state/tmp/.san-new.txt"
            cat "$SESSION_DIR/subdomains/subdomains-final.txt" "$SESSION_DIR/state/tmp/.san-new.txt" 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.san-final.txt" && mv "$SESSION_DIR/state/tmp/.san-final.txt" "$SESSION_DIR/subdomains/subdomains-final.txt"
            while read -r _h; do [ -z "$_h" ] && continue; for _p in $JS_PORTS; do printf '%s:%s\n' "$_h" "$_p"; done; done < "$SESSION_DIR/state/tmp/.san-new.txt" | sort -u > "$SESSION_DIR/state/tmp/.san-ports.txt"
            timeout --foreground 600 httpx -silent -l "$SESSION_DIR/state/tmp/.san-ports.txt" -threads 100 -timeout 8 -status-code 2>/dev/null | awk '{print $1}' >> "$SESSION_DIR/hosts/hosts-live.txt"
            sort -u "$SESSION_DIR/hosts/hosts-live.txt" -o "$SESSION_DIR/hosts/hosts-live.txt"
            stage_note "san-live=$(wc -l < "$SESSION_DIR/hosts/hosts-live.txt" | tr -d ' ')"
            rm -f "$SESSION_DIR/state/tmp/.san-new.txt" "$SESSION_DIR/state/tmp/.san-ports.txt"
        fi
    fi
    rm -f "$SESSION_DIR/state/tmp/.tls-sans.txt"
    stage_note "live=$(wc -l < "$SESSION_DIR/hosts/hosts-live.txt" | tr -d ' ')"
}
st_auth_lite() {
    [ -n "$AUTH_COOKIE" ] || { out "${C_Y}No cookie, skipping auth stage${C_R}"; return; }
    [ -s "$SESSION_DIR/hosts/hosts-live.txt" ] || { out "${C_Y}No live hosts, skipping auth${C_R}"; return; }
    local _bd=0 _bt=0 _ba _bb _bu
    local c_hdr=(); build_c_hdr
    : > "$SESSION_DIR/state/tmp/.auth-evidence"
    {
        head -3 "$SESSION_DIR/hosts/hosts-live.txt"
        grep ':3000' "$SESSION_DIR/hosts/hosts-live.txt" 2>/dev/null | head -1
    } | awk '!seen[$0]++' | { while read -r _bu; do
        [ -z "$_bu" ] && continue
        _ba=$(curl -s -k -L --compressed -m 10 --connect-timeout 6 -A "$FAKE_UA" "$_bu" 2>/dev/null | wc -c)
        _bb=$(curl -s -k -L --compressed -m 10 --connect-timeout 6 -A "$FAKE_UA" "${c_hdr[@]+${c_hdr[@]}}" "$_bu" 2>/dev/null | wc -c)
        _bt=$((_bt+1))
        if [ "$_ba" -eq 0 ]; then
            printf '  %-45s anon=unreachable auth=%sB\n' "$_bu" "$_bb" >> "$SESSION_DIR/state/tmp/.auth-evidence"
        elif [ "$_ba" != "$_bb" ]; then
            _bd=$((_bd+1))
            printf '  %-45s anon=%sB auth=%sB DIFFERENT (cookie changes response)\n' "$_bu" "$_ba" "$_bb" >> "$SESSION_DIR/state/tmp/.auth-evidence"
        else
            printf '  %-45s anon=%sB auth=%sB identical\n' "$_bu" "$_ba" "$_bb" >> "$SESSION_DIR/state/tmp/.auth-evidence"
        fi
        [ "$_bt" -ge 4 ] && break
    done; echo "$_bd $_bt" > "$SESSION_DIR/state/tmp/.auth-count"; }
    read -r _bd _bt < "$SESSION_DIR/state/tmp/.auth-count" 2>/dev/null || { _bd=0; _bt=0; }
    rm -f "$SESSION_DIR/state/tmp/.auth-count"
    [ -s "$SESSION_DIR/state/tmp/.auth-evidence" ] && { out "${C_W}auth body-diff evidence:${C_R}"; cat "$SESSION_DIR/state/tmp/.auth-evidence" ; }
    rm -f "$SESSION_DIR/state/tmp/.auth-evidence"
    if [ "$_bd" -gt 0 ]; then
        out "${C_GRN}AUTH cookie ACTIVE ($_bd/$_bt hosts return different content with cookie)${C_R}"
        stage_note "cookie=body-diff"
    else
        out "${C_Y}AUTH cookie INERT or unverifiable ($_bt hosts identical), keeping it for fetch stages${C_R}"
        [ -n "$CK_ARG" ] && out "${C_Y}[hint] a wrong cookie file also shows INERT -- if the -c path contains spaces it must be quoted; check the file is the real Netscape jar${C_R}"
    fi
}
st_archive() {
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ waymore${C_R} -i '$DOMAIN' -mode U -oU urls/archive-waymore.txt  (x2 tries)"
    local wm_rc=1
    for _wm_try in 1 2; do
        timeout --foreground 3000 waymore -i "$DOMAIN" -mode U -oU "$SESSION_DIR/urls/archive-waymore.txt" 2>"$SESSION_DIR/state/tmp/waymore.err" | grep -E 'Total unique links' || true
        wm_rc="${PIPESTATUS[0]}"
        [ -s "$SESSION_DIR/urls/archive-waymore.txt" ] && [ "$(wc -l < "$SESSION_DIR/urls/archive-waymore.txt" | tr -d ' ')" -ge 10 ] && break
        [ "$_wm_try" = "1" ] && sleep 10
    done
    if [ ! -s "$SESSION_DIR/urls/archive-waymore.txt" ]; then
        local latest
        latest=$(ls -t waymore/* waymore/results/* 2>/dev/null | head -1)
        [ -n "$latest" ] && [ -f "$latest" ] && cp "$latest" "$SESSION_DIR/urls/archive-waymore.txt"
    fi
    if [ ! -s "$SESSION_DIR/urls/archive-waymore.txt" ]; then
        out "${C_Y}[warn] waymore produced no output (check waymore config / network)${C_R}"
        stage_note "waymore-empty"
    fi
    rm -f "$SESSION_DIR/state/tmp/waymore.err"

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ gau${C_R} --subs --threads 20 '$DOMAIN' | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > urls/archive-gau.txt || true"
    gau --subs --threads 20 "$DOMAIN" 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > "$SESSION_DIR/urls/archive-gau.txt" || true
    [ -s "$SESSION_DIR/urls/archive-gau.txt" ] || out "${C_Y}[warn] gau produced no output (network/config?)${C_R}"

    {
        [ -f "$SESSION_DIR/urls/archive-waymore.txt" ] && cat "$SESSION_DIR/urls/archive-waymore.txt"
        [ -f "$SESSION_DIR/urls/archive-gau.txt" ] && cat "$SESSION_DIR/urls/archive-gau.txt"
    } | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > "$SESSION_DIR/urls/urls-archive.txt"
    local arc_count
    arc_count=$(wc -l < "$SESSION_DIR/urls/urls-archive.txt" | tr -d ' ')
    stage_note "archive=$arc_count"
    out "${C_GRN}Archive URLs: $arc_count${C_R}"
    cat "$SESSION_DIR/urls/urls-archive.txt" 
}
st_crawl() {
    [ -s "$SESSION_DIR/hosts/hosts-live.txt" ] || { out "${C_Y}No live hosts, skipping crawl${C_R}"; return; }
    local katana_h=()
    [ -n "$AUTH_COOKIE" ] && katana_h=(-H "Cookie: $AUTH_COOKIE")
    for _eh in "${EXTRA_HEADERS[@]+${EXTRA_HEADERS[@]}}"; do katana_h+=(-H "$_eh"); done
    local katana_ef="css,png,jpg,jpeg,gif,svg,ico,webp,avif,bmp,tiff,woff,woff2,ttf,otf,eot,pdf,zip,tar,tgz,gz,bz2,xz,7z,rar,mp3,wav,ogg,m4a,mp4,webm,avi,mov,mkv"

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ katana${C_R} -d 5 -c 50 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl -jsluice -known-files all -aff -fs rdn -ef '$katana_ef' < hosts-live.txt | awk '!seen[\$0]++' > urls/crawl-katana.txt || true"
    timeout --foreground 3000 katana -d 5 -c 50 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl -jsluice -known-files all -aff -fs rdn -ef "$katana_ef" "${katana_h[@]+${katana_h[@]}}" 2>/dev/null < "$SESSION_DIR/hosts/hosts-live.txt" | awk '!seen[$0]++' > "$SESSION_DIR/urls/crawl-katana.txt" || true
    out "${C_W}katana: $(wc -l < "$SESSION_DIR/urls/crawl-katana.txt" 2>/dev/null | tr -d ' ') URLs${C_R}"
    cat "$SESSION_DIR/urls/crawl-katana.txt" 

    if [ -n "$AUTH_COOKIE" ]; then
        out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ katana${C_R} -d 3 -c 50 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl -jsluice -known-files all -aff -fs rdn -ef '$katana_ef' -H 'Cookie: ***' < hosts-live.txt | awk '!seen[\$0]++' > urls/crawl-auth.txt || true"
        timeout --foreground 3000 katana -d 3 -c 50 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl -jsluice -known-files all -aff -fs rdn -ef "$katana_ef" "${katana_h[@]+${katana_h[@]}}" 2>/dev/null < "$SESSION_DIR/hosts/hosts-live.txt" | awk '!seen[$0]++' > "$SESSION_DIR/urls/crawl-auth.txt" || true
        out "${C_W}katana+auth: $(wc -l < "$SESSION_DIR/urls/crawl-auth.txt" 2>/dev/null | tr -d ' ') URLs${C_R}"
        cat "$SESSION_DIR/urls/crawl-auth.txt" 
        comm -23 <(sort -u "$SESSION_DIR/urls/crawl-auth.txt") <(sort -u "$SESSION_DIR/urls/crawl-katana.txt") > "$SESSION_DIR/urls/urls-auth-only.txt"
        : > "$SESSION_DIR/state/tmp/.avo.txt"
        head -80 "$SESSION_DIR/urls/urls-auth-only.txt" | xargs -d '\n' -P 15 -I {} bash -c '
            c=$(curl -s -o /dev/null -w "%{http_code}" -m 8 -A "$FAKE_UA" "$1" 2>/dev/null)
            case "$c" in 401|403|404) printf "%s\n" "$1" >> "'"$SESSION_DIR/state/tmp/.avo.txt"'" ;; esac
        ' _ {}
        sort -u "$SESSION_DIR/state/tmp/.avo.txt" > "$SESSION_DIR/state/tmp/.avo.sorted" && mv "$SESSION_DIR/state/tmp/.avo.sorted" "$SESSION_DIR/urls/urls-auth-only.txt"
        rm -f "$SESSION_DIR/state/tmp/.avo.txt"
        local auth_count
        auth_count=$(wc -l < "$SESSION_DIR/urls/urls-auth-only.txt" 2>/dev/null | tr -d ' '); auth_count=${auth_count:-0}
        [ "$auth_count" -gt 0 ] && { out "${C_Y}$auth_count URLs reachable ONLY with auth${C_R}"; cat "$SESSION_DIR/urls/urls-auth-only.txt"; }
    fi

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ gospider${C_R} -S hosts-live.txt -d 3 -c 5 -t 30 --js --sitemap -a '$FAKE_UA' -s 5 -k 2 [-C ***] | grep -oaE 'https?://[^''<>() ]+' | sed 's/[.,;)]$//' | sort -u > urls/crawl-gospider.txt || true"
    local katana_count
    katana_count=$(wc -l < "$SESSION_DIR/urls/crawl-katana.txt" 2>/dev/null | tr -d ' '); katana_count=${katana_count:-0}
    if [ "$katana_count" -lt 100 ]; then
        local gospider_args=(-S "$SESSION_DIR/hosts/hosts-live.txt" -d 3 -c 5 -t 30 --js --sitemap -a "$FAKE_UA" -s 5 -k 2)
        [ -n "$AUTH_COOKIE" ] && gospider_args+=(-C "$AUTH_COOKIE")
        timeout --foreground 1200 gospider "${gospider_args[@]}" 2>"$SESSION_DIR/state/tmp/gospider.err" | grep -oaE "https?://[^\"'<>() ]+" | sed 's/[.,;)]$//' | sort -u > "$SESSION_DIR/urls/crawl-gospider.txt" || true
        if [ ! -s "$SESSION_DIR/urls/crawl-gospider.txt" ]; then
            out "${C_Y}[warn] gospider produced 0 URLs -- stderr: $(tail -3 "$SESSION_DIR/state/tmp/gospider.err" 2>/dev/null | tr '\n' ' | ' | cut -c1-200)${C_R}"
            stage_note "gospider-empty"
        fi
        out "${C_W}gospider: $(wc -l < "$SESSION_DIR/urls/crawl-gospider.txt" 2>/dev/null | tr -d ' ') URLs${C_R}"
        cat "$SESSION_DIR/urls/crawl-gospider.txt" 
    else
        out "${C_Y}katana already found $katana_count URLs -- skipping gospider (would be redundant)${C_R}"
        : > "$SESSION_DIR/urls/crawl-gospider.txt"
    fi

    comm -23 <(grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/urls/urls-archive.txt" | sort -u) <(sort -u "$SESSION_DIR/urls/crawl-katana.txt") | url_junk_filter | sort -u > "$SESSION_DIR/state/tmp/.archive-seeds-full.txt"
    _seed_total=$(wc -l < "$SESSION_DIR/state/tmp/.archive-seeds-full.txt" | tr -d ' '); _seed_total=${_seed_total:-0}
    _seed_off=$(tr -d '[:space:]' < "$BASE_DIR/.seed-offset" 2>/dev/null); _seed_off=${_seed_off:-0}
    if [ "${_seed_total:-0}" -le 500 ]; then
        cp "$SESSION_DIR/state/tmp/.archive-seeds-full.txt" "$SESSION_DIR/state/tmp/.archive-seeds.txt"
    else
        tail -n +$(( _seed_off + 1 )) "$SESSION_DIR/state/tmp/.archive-seeds-full.txt" | head -500 > "$SESSION_DIR/state/tmp/.archive-seeds.txt"
        _got=$(wc -l < "$SESSION_DIR/state/tmp/.archive-seeds.txt" | tr -d ' ')
        if [ "${_got:-0}" -lt 500 ]; then
            head -n $(( 500 - _got )) "$SESSION_DIR/state/tmp/.archive-seeds-full.txt" >> "$SESSION_DIR/state/tmp/.archive-seeds.txt"
        fi
        _seed_off=$(( ( _seed_off + 500 ) % _seed_total ))
        printf '%s\n' "$_seed_off" > "$BASE_DIR/.seed-offset" 2>/dev/null || true
        out "${C_W}archive seeds window: $(( (_seed_off + 500 - 1) % _seed_total + 1 ))-range of $_seed_total (rotates each run)${C_R}"
        stage_note "seeds=$_seed_total/rot"
    fi
    if [ -s "$SESSION_DIR/state/tmp/.archive-seeds.txt" ] && [ -s "$SESSION_DIR/urls/crawl-katana.txt" ]; then
        local seed_count full_seed_count
        full_seed_count=$_seed_total
        seed_count=$(wc -l < "$SESSION_DIR/state/tmp/.archive-seeds.txt" | tr -d ' ')
        out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ katana${C_R} -u .archive-seeds.txt -d 3 -c 50 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl [-H Cookie: ***] | awk '!seen[\$0]++' > urls/crawl-archive.txt || true"
        timeout --foreground 1800 katana -u "$SESSION_DIR/state/tmp/.archive-seeds.txt" -d 3 -c 50 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl "${katana_h[@]+${katana_h[@]}}" 2>/dev/null | awk '!seen[$0]++' > "$SESSION_DIR/urls/crawl-archive.txt" || true
        cat "$SESSION_DIR/urls/crawl-archive.txt" 
        comm -23 <(grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/urls/crawl-archive.txt" 2>/dev/null | sort -u) <(grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/urls/crawl-katana.txt" 2>/dev/null | sort -u) | url_junk_filter > "$SESSION_DIR/urls/urls-revived.txt"
        local rev_count
        rev_count=$(wc -l < "$SESSION_DIR/urls/urls-revived.txt" 2>/dev/null | tr -d ' '); rev_count=${rev_count:-0}
        [ "$rev_count" -gt 0 ] && { out "${C_Y}$rev_count endpoints revived from archive seeds${C_R}"; cat "$SESSION_DIR/urls/urls-revived.txt"; }
    fi
    rm -f "$SESSION_DIR/state/tmp/.archive-seeds.txt" "$SESSION_DIR/state/tmp/.archive-seeds-full.txt"

    stage_note "katana=$(wc -l < "$SESSION_DIR/urls/crawl-katana.txt" 2>/dev/null | tr -d ' ') gospider=$(wc -l < "$SESSION_DIR/urls/crawl-gospider.txt" 2>/dev/null | tr -d ' ')"
}
st_classify_js() {
    {
        [ -f "$SESSION_DIR/hosts/hosts-live.txt" ] && cat "$SESSION_DIR/hosts/hosts-live.txt"
        [ -f "$SESSION_DIR/urls/crawl-katana.txt" ] && cat "$SESSION_DIR/urls/crawl-katana.txt"
        [ -f "$SESSION_DIR/urls/crawl-archive.txt" ] && cat "$SESSION_DIR/urls/crawl-archive.txt"
        [ -f "$SESSION_DIR/urls/crawl-auth.txt" ] && cat "$SESSION_DIR/urls/crawl-auth.txt"
        [ -f "$SESSION_DIR/urls/crawl-gospider.txt" ] && cat "$SESSION_DIR/urls/crawl-gospider.txt"
        [ -f "$SESSION_DIR/urls/urls-archive.txt" ] && cat "$SESSION_DIR/urls/urls-archive.txt"
    } | url_junk_filter | sort -u > "$SESSION_DIR/state/tmp/.all-urls-raw.txt"
    if [ -s "$SESSION_DIR/state/tmp/.all-urls-raw.txt" ]; then
        awk '{
            sub(/^[[:space:]]+/,"")
            if ($0 !~ /^https?:\/\//) next
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
    grep -E '\.(js|mjs)(\?|$)' "$SESSION_DIR/urls/urls-inscope.txt" | sort -u > "$SESSION_DIR/urls/urls-js.txt"
    grep -E '\.json(\?|$)' "$SESSION_DIR/urls/urls-inscope.txt" | sort -u > "$SESSION_DIR/urls/urls-json.txt"
    grep -E '(\.(env|pem|key|p12|pfx|bak|backup|old|sql|sqlite|sqlite3|db|dump|log|config|cfg|ini|yaml|yml|xml|conf|git|gitignore|zip|tar|gz|tgz|7z|rar|swp|swo|crt|csr|htpasswd|npmrc|dockercfg|ps1|sh|htaccess|txt|ds_store)(\?|$))|(apple-app-site-association|openid-configuration|security\.txt|crossdomain\.xml|clientaccesspolicy\.xml)' "$SESSION_DIR/urls/urls-inscope.txt" | sort -u > "$SESSION_DIR/urls/urls-artifacts.txt"
    awk '{
        n = split($0, a, "?")
        path = tolower(a[1])
        if (path ~ /\.(css|png|jpe?g|gif|svg|ico|webp|avif|bmp|tiff?|woff2?|ttf|otf|eot|pdf|zip|tar|tgz|gz|bz2|xz|7z|rar|mp3|wav|ogg|m4a|mp4|webm|avi|mov|mkv|json|xml|csv|doc|docx|xls|xlsx|ppt|pptx|txt|md|log)$/) next
        if (path ~ /\/$/) next
        lastseg = path
        sub(/.*\//, "", lastseg)
        if (lastseg ~ /\./ && lastseg !~ /\.(js|mjs|map)$/) next
        if (path !~ /\.(js|mjs|map)($|\?)/ && lastseg !~ /[0-9a-f]{8,}/ && lastseg !~ /^(main|runtime|polyfills|scripts|styles|vendor|chunk|app|index|bundle|sw|worker|common|shared)([._-]|$)/) next
        print $0
    }' "$SESSION_DIR/urls/urls-inscope.txt" | sort -u > "$SESSION_DIR/urls/urls-js-candidates.txt"
    grep -E '\b(api|v[0-9]+|graphql|rest|endpoint|ajax)\b' "$SESSION_DIR/urls/urls-inscope.txt" | grep -E -v '\.(css|js|png|jpe?g|gif|svg|ico|webp|woff2?|ttf|map|xml|pdf|zip)(\?|$)' | sort -u > "$SESSION_DIR/urls/urls-api.txt"
    out "${C_W}inscope: $(wc -l < "$SESSION_DIR/urls/urls-inscope.txt" | tr -d ' ') | js: $(wc -l < "$SESSION_DIR/urls/urls-js.txt" | tr -d ' ') | json: $(wc -l < "$SESSION_DIR/urls/urls-json.txt" | tr -d ' ') | artifacts: $(wc -l < "$SESSION_DIR/urls/urls-artifacts.txt" | tr -d ' ') | candidates: $(wc -l < "$SESSION_DIR/urls/urls-js-candidates.txt" | tr -d ' ')${C_R}"
    stage_note "js=$(wc -l < "$SESSION_DIR/urls/urls-js.txt" | tr -d ' ') json=$(wc -l < "$SESSION_DIR/urls/urls-json.txt" | tr -d ' ') art=$(wc -l < "$SESSION_DIR/urls/urls-artifacts.txt" | tr -d ' ')"
}
st_js_pipeline() {
    mkdir -p "$SESSION_DIR/js/raw" "$SESSION_DIR/js/formatted" "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/deobf" "$SESSION_DIR/js/sourcemaps"
    : > "$SESSION_DIR/state/url-map.txt"
    : > "$SESSION_DIR/state/js-map.txt"
    : > "$SESSION_DIR/state/js-content-hashes.txt"
    : > "$SESSION_DIR/state/map-hashes.txt"
    : > "$SESSION_DIR/state/blind-probed.txt"
    : > "$SESSION_DIR/state/blind-maps-found.txt"
    : > "$SESSION_DIR/state/blind-failed.txt"
    : > "$SESSION_DIR/state/maps-extracted.txt"
    : > "$SESSION_DIR/state/sm-done.txt"
    : > "$SESSION_DIR/state/obf-done.txt"
    : > "$SESSION_DIR/state/obf-hits.txt"
    : > "$SESSION_DIR/state/pretty-done.txt"
    : > "$SESSION_DIR/state/pretty-hashes.txt"
    : > "$SESSION_DIR/state/page-hashes.txt"
    : > "$SESSION_DIR/state/tmp/.js-discovered.txt"

    local round=0
    while [ "$round" -lt "$JS_MAX_ROUNDS" ]; do
        round=$((round + 1))
        out "${C_Y}JS ROUND $round/$JS_MAX_ROUNDS${C_R}"

        if [ "$round" -eq 1 ]; then
            {
                grep -E '\.(js|map)(\?|$)' "$SESSION_DIR/urls/crawl-auth.txt" 2>/dev/null
                cat "$SESSION_DIR/urls/urls-js.txt" 2>/dev/null
                cat "$SESSION_DIR/urls/urls-js-candidates.txt" 2>/dev/null
            } | sort -u | tr -d '\r' | awk 'NF' > "$SESSION_DIR/state/tmp/.js-round-seeds.txt"
        else
            sort -u "$SESSION_DIR/state/tmp/.js-discovered.txt" | tr -d '\r' | awk 'NF' > "$SESSION_DIR/state/tmp/.js-round-seeds.txt"
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
            out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ js_fetch${C_R} wave: cat .js-pending.txt | xargs -d '\n' -P $RECONLY_FETCH_THREADS -n 1 bash -c 'for u in '\$@'; do js_fetch '\$u' || true; done' _   ($pending files)"
            awk -F/ '{n=$NF; sub(/\?.*/,"",n); k=$3"|"n; if(!seen[k]++){print}}' "$SESSION_DIR/state/tmp/.js-pending.txt" > "$SESSION_DIR/state/tmp/.js-pending-dedup.txt" 2>/dev/null || cp "$SESSION_DIR/state/tmp/.js-pending.txt" "$SESSION_DIR/state/tmp/.js-pending-dedup.txt"
            _pd=$(wc -l < "$SESSION_DIR/state/tmp/.js-pending-dedup.txt" | tr -d ' ')
            [ "${_pd:-0}" -gt 0 ] && [ "$_pd" -lt "$pending" ] && { out "${C_W}basename dedup: $pending -> $_pd unique chunks${C_R}"; stage_note "jsdedup=$pending/$_pd"; }
            cp "$SESSION_DIR/state/tmp/.js-pending-dedup.txt" "$SESSION_DIR/state/tmp/.js-pending.txt"
            rm -f "$SESSION_DIR/state/tmp/.js-pending-dedup.txt"
            printf '%s\n' "$pending" > "$SESSION_DIR/state/tmp/.js-total"
            : > "$SESSION_DIR/state/tmp/.js-progress.log"
            cat "$SESSION_DIR/state/tmp/.js-pending.txt" | xargs -d '\n' -P "$RECONLY_FETCH_THREADS" -n 1 bash -c '
                for u in "$@"; do
                    if js_fetch "$u"; then js_progress OK "$u" "$JS_LAST_CODE"; else js_progress FAIL "$u" "$JS_LAST_CODE"; fi
                done
            ' _
            _jsok=$(grep -c "^OK:" "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null || true)
            _jsfl=$(grep -c "^FAIL:" "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null || true)
            local _jsdist
            _jsdist=$(awk -F'[:|]' '{c[$1":"$2]++} END{for(k in c) printf "%s=%d ",k,c[k]}' "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null)
            out "${C_GRN}JS wave done: ${_jsok:-0}/$pending fetched, ${_jsfl:-0} failed (${_jsdist:-no data})${C_R}"
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
                out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ json_fetch${C_R} wave (.json + swagger/api-docs)   ($_json_pending files)"
                printf '%s\n' "$_json_pending" > "$SESSION_DIR/state/tmp/.js-total"
                : > "$SESSION_DIR/state/tmp/.js-progress.log"
                cat "$SESSION_DIR/state/tmp/.json-pending.txt" | xargs -d '\n' -P "$RECONLY_FETCH_THREADS" -n 1 bash -c '
                    for j in "$@"; do
                        if json_fetch "$j"; then js_progress OK "$j" "$JSON_LAST_CODE"; else js_progress FAIL "$j" "$JSON_LAST_CODE"; fi
                    done
                ' _
                local _jok _jfl _jdist
                _jok=$(grep -c "^OK:" "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null || true)
                _jfl=$(grep -c "^FAIL:" "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null || true)
                _jdist=$(awk -F'[:|]' '{c[$1":"$2]++} END{for(k in c) printf "%s=%d ",k,c[k]}' "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null)
                out "${C_GRN}JSON wave done: ${_jok:-0}/$_json_pending fetched, ${_jfl:-0} failed (${_jdist:-no data})${C_R}"
                adapt_threads
            fi
            rm -f "$SESSION_DIR/state/tmp/.json-seeds.txt" "$SESSION_DIR/state/tmp/.json-done.txt" "$SESSION_DIR/state/tmp/.json-pending.txt"
        fi
        if [ "$round" -eq 1 ] && [ -s "$SESSION_DIR/urls/urls-artifacts.txt" ]; then
            head -100 "$SESSION_DIR/urls/urls-artifacts.txt" > "$SESSION_DIR/state/tmp/.art-pending.txt"
            local _art_pending
            _art_pending=$(wc -l < "$SESSION_DIR/state/tmp/.art-pending.txt" | tr -d ' ')
            if [ "${_art_pending:-0}" -gt 0 ]; then
                out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ artifact_fetch${C_R} wave (exposed .env/.pem/.sql/.bak...)   ($_art_pending files)"
                printf '%s\n' "$_art_pending" > "$SESSION_DIR/state/tmp/.js-total"
                : > "$SESSION_DIR/state/tmp/.js-progress.log"
                cat "$SESSION_DIR/state/tmp/.art-pending.txt" | xargs -d '\n' -P 10 -n 1 bash -c '
                    for a in "$@"; do
                        if artifact_fetch "$a"; then js_progress OK "$a" "$ART_LAST_CODE"; else js_progress FAIL "$a" "$ART_LAST_CODE"; fi
                    done
                ' _
                local _aok _afl
                _aok=$(grep -c "^OK:" "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null || true)
                _afl=$(grep -c "^FAIL:" "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null || true)
                out "${C_GRN}Artifacts wave done: ${_aok:-0}/$_art_pending fetched, ${_afl:-0} failed${C_R}"
            fi
            rm -f "$SESSION_DIR/state/tmp/.art-pending.txt"
        fi

        if [ "$round" -eq 1 ] && [ -s "$SESSION_DIR/urls/urls-inscope.txt" ]; then
            {
                cat "$SESSION_DIR/urls/urls-auth-only.txt" 2>/dev/null
                cat "$SESSION_DIR/urls/urls-revived.txt" 2>/dev/null
            } | url_junk_filter | awk '!seen[$0]++' > "$SESSION_DIR/state/tmp/.pages-priority.txt"
            awk 'NR==FNR { prio[$0]=1; next } !($0 in prio)' "$SESSION_DIR/state/tmp/.pages-priority.txt" "$SESSION_DIR/urls/urls-inscope.txt" \
              | grep -vE '\.(js|css|png|jpe?g|gif|svg|ico|woff2?|ttf|map|json|xml|pdf|zip|mp4|mp3|avi|mov|webp)(\?|$)' \
              | { if [ -s "$SESSION_DIR/state/api-sampled.txt" ]; then grep -vxF -f "$SESSION_DIR/state/api-sampled.txt"; else cat; fi; } \
              | awk '!seen[$0]++' > "$SESSION_DIR/state/tmp/.pages-rest.txt"
            {
                cat "$SESSION_DIR/state/tmp/.pages-priority.txt"
                awk -F/ '{depth=NF; hasq=($0 ~ /\?/) ? 1000 : 0; print (hasq+depth)"\t"$0}' "$SESSION_DIR/state/tmp/.pages-rest.txt" | sort -k1,1rn -k2 | cut -f2-
            } | awk '{ u=$0; sub(/\?.*/,"",u); if(!(u in seen)){seen[u]=1; print} }' > "$SESSION_DIR/state/tmp/.pages-all-ranked.txt"
            head -n "$RECONLY_MAX_PAGES" "$SESSION_DIR/state/tmp/.pages-all-ranked.txt" > "$SESSION_DIR/state/tmp/.pages-temp.txt"
            local _pages_ranked
            _pages_ranked=$(wc -l < "$SESSION_DIR/state/tmp/.pages-all-ranked.txt" | tr -d ' ')
            if [ "${_pages_ranked:-0}" -gt "$RECONLY_MAX_PAGES" ]; then
                tail -n +$((RECONLY_MAX_PAGES + 1)) "$SESSION_DIR/state/tmp/.pages-all-ranked.txt" > "$SESSION_DIR/state/skipped-pages.txt"
                stage_note "pages-capped=$_pages_ranked/$RECONLY_MAX_PAGES"
            fi
            rm -f "$SESSION_DIR/state/tmp/.pages-all-ranked.txt" "$SESSION_DIR/state/tmp/.pages-priority.txt" "$SESSION_DIR/state/tmp/.pages-rest.txt"
            local page_count
            page_count=$(wc -l < "$SESSION_DIR/state/tmp/.pages-temp.txt" | tr -d ' ')
            if [ "$page_count" -gt 0 ]; then
                out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ page_fetch${C_R} wave: cat .pages-temp.txt | xargs -d '\n' -P $RECONLY_FETCH_THREADS -n 1 bash -c 'for p in '\$@'; do page_fetch '\$p' || true; done' _   ($page_count pages)"
                printf '%s\n' "$page_count" > "$SESSION_DIR/state/tmp/.js-total"
                : > "$SESSION_DIR/state/tmp/.js-progress.log"
                cat "$SESSION_DIR/state/tmp/.pages-temp.txt" | xargs -d '\n' -P "$RECONLY_FETCH_THREADS" -n 1 bash -c '
                    for p in "$@"; do
                        if page_fetch "$p"; then js_progress OK "$p" "$PAGE_LAST_CODE"; else js_progress FAIL "$p" "$PAGE_LAST_CODE"; fi
                    done
                ' _
                _pgok=$(grep -c "^OK:" "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null || true)
                _pgfl=$(grep -c "^FAIL:" "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null || true)
                local _pgdist
                _pgdist=$(awk -F'[:|]' '{c[$1":"$2]++} END{for(k in c) printf "%s=%d ",k,c[k]}' "$SESSION_DIR/state/tmp/.js-progress.log" 2>/dev/null)
                out "${C_GRN}Pages wave done: ${_pgok:-0}/$page_count fetched, ${_pgfl:-0} failed (${_pgdist:-no data})${C_R}"
                adapt_threads
                local inline_count
                inline_count=$(find "$SESSION_DIR/js/raw" -name 'page_*.js' 2>/dev/null | wc -l | tr -d ' ')
                out "${C_W}Pages: $page_count | Inline scripts: $inline_count${C_R}"
            fi
            rm -f "$SESSION_DIR/state/tmp/.pages-temp.txt"
        fi

        find "$SESSION_DIR/js/raw" -maxdepth 1 -type f -name '*.js' -printf '%f\n' 2>/dev/null | sort > "$SESSION_DIR/state/tmp/.sm-all.txt"
        comm -23 "$SESSION_DIR/state/tmp/.sm-all.txt" <(sort -u "$SESSION_DIR/state/sm-done.txt") > "$SESSION_DIR/state/tmp/.sm-new.txt"
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
                out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ recover_one_sourcemap${C_R}: cat .sm-refs.txt | xargs -d '\n' -P $RECONLY_JS_THREADS -I {} bash -c 'recover_one_sourcemap "\$1"' _ {}"
                cat "$SESSION_DIR/state/tmp/.sm-refs.txt" | xargs -d '\n' -P "$RECONLY_JS_THREADS" -I {} bash -c 'recover_one_sourcemap "$1"' _ {}
            fi
            rm -f "$SESSION_DIR/state/tmp/.sm-refs.txt"

            _blind_map_probe

            find "$SESSION_DIR/js/mapsrc" \( -name '*.js' -o -name '*.ts' \) -type f -print0 2>/dev/null | xargs -0 md5sum 2>/dev/null | sort -k1,1 | awk 'seen[$1]++ {print $2}' > "$SESSION_DIR/state/tmp/.mapsrc-dups.txt"
            [ -s "$SESSION_DIR/state/tmp/.mapsrc-dups.txt" ] && xargs -r rm -f < "$SESSION_DIR/state/tmp/.mapsrc-dups.txt"
            rm -f "$SESSION_DIR/state/tmp/.mapsrc-dups.txt"
        fi
        cat "$SESSION_DIR/state/tmp/.sm-new.txt" >> "$SESSION_DIR/state/sm-done.txt" 2>/dev/null || true

        find "$SESSION_DIR/js/raw" -maxdepth 1 -type f -name '*.js' -printf '%f\n' 2>/dev/null | sort > "$SESSION_DIR/state/tmp/.obf-all.txt"
        comm -23 "$SESSION_DIR/state/tmp/.obf-all.txt" <(sort -u "$SESSION_DIR/state/obf-done.txt") > "$SESSION_DIR/state/tmp/.obf-new.txt"
        if [ -s "$SESSION_DIR/state/tmp/.obf-new.txt" ]; then
            : > "$SESSION_DIR/state/tmp/.obf-hits-round.txt"
            while IFS= read -r fn; do
                if command -v rg &>/dev/null; then
                    rg -q -a -P -e '(_0x[a-f0-9]{4,}.*_0x[a-f0-9]{4,}|eval\(function\(p,a,c,k|eval\(atob\()' "$SESSION_DIR/js/raw/$fn" 2>/dev/null && printf '%s\n' "$fn" >> "$SESSION_DIR/state/tmp/.obf-hits-round.txt"
                else
                    grep -qP '(_0x[a-f0-9]{4,}.*_0x[a-f0-9]{4,}|eval\(function\(p,a,c,k|eval\(atob\()' "$SESSION_DIR/js/raw/$fn" 2>/dev/null && printf '%s\n' "$fn" >> "$SESSION_DIR/state/tmp/.obf-hits-round.txt"
                fi
            done < "$SESSION_DIR/state/tmp/.obf-new.txt"
            cat "$SESSION_DIR/state/tmp/.obf-new.txt" >> "$SESSION_DIR/state/obf-done.txt"
            local obf_budget
            obf_budget=$((OBF_MAX_FILES - $(wc -l < "$SESSION_DIR/state/obf-hits.txt" 2>/dev/null | tr -d ' ')))
            if [ -s "$SESSION_DIR/state/tmp/.obf-hits-round.txt" ] && [ "$obf_budget" -gt 0 ] && command -v npx &>/dev/null; then
                out "${C_W}Deobfuscating (budget: $obf_budget)${C_R}"
                head -n "$obf_budget" "$SESSION_DIR/state/tmp/.obf-hits-round.txt" | while IFS= read -r fn; do
                    printf '%s\n' "$fn" >> "$SESSION_DIR/state/obf-hits.txt"
                    local bname="${fn%.js}"
                    timeout --foreground 120 npx webcrack "$SESSION_DIR/js/raw/$fn" -o "$SESSION_DIR/state/tmp/deobf/$bname" >/dev/null 2>&1 || true
                    if [ ! -d "$SESSION_DIR/state/tmp/deobf/$bname" ]; then
                        timeout --foreground 180 npx -y synchrony@latest deobfuscate "$SESSION_DIR/js/raw/$fn" --output "$SESSION_DIR/state/tmp/deobf/${bname}-sync.js" >/dev/null 2>&1 || true
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
                local deobf_count
                deobf_count=$(find "$SESSION_DIR/js/deobf" -name '*.js' 2>/dev/null | wc -l | tr -d ' ')
                out "${C_GRN}Deobfuscated files: $deobf_count${C_R}"
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
            comm -23 "$SESSION_DIR/state/tmp/.pretty-all.txt" <(sort -u "$SESSION_DIR/state/pretty-done.txt") > "$SESSION_DIR/state/tmp/.pretty-new.txt"
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
            cat "$SESSION_DIR/state/tmp/.pretty-new.txt" >> "$SESSION_DIR/state/pretty-done.txt"
            local p_eligible
            p_eligible=$(tr -dc '\0' < "$SESSION_DIR/state/tmp/.pretty-list" | wc -c | tr -d ' ')
            if [ "$p_eligible" -gt 0 ]; then
                out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ prettier${C_R} --parser babel --write <files>   (xargs -0 -n $PRETTIER_BATCH -P $PRETTIER_JOBS, $p_eligible files)"
                xargs -0 -n "$PRETTIER_BATCH" -P "$PRETTIER_JOBS" bash -c 'timeout --foreground 120 npx prettier --parser babel --write "$@" >/dev/null 2>&1' _ < "$SESSION_DIR/state/tmp/.pretty-list" || true
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

        {
            if command -v rg &>/dev/null; then
                rg --no-ignore --hidden -a -o -N -P -e 'https?://[^\s\x22\x27`<>()]+\.(js|mjs)(\?[^\s\x22\x27`<>()]*)?' -e '(?<![a-zA-Z0-9:])//[a-zA-Z0-9.-]+/[a-zA-Z0-9_/.-]+\.(js|mjs)(\?[^\s\x22\x27`<>()]*)?' -e 'import\(\s*[\x22\x27`][^\x22\x27`]+?\.(?:js|mjs)[\x22\x27`]\s*\)' "$SESSION_DIR/js/raw/" "$SESSION_DIR/js/deobf/" "$SESSION_DIR/js/formatted/" 2>/dev/null | awk '{sub(/^[^:]+:[0-9]+:/, ""); print}' | sed 's|^//|https://|' | grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)"
            else
                grep -rhoP 'https?://[^\s\x22\x27`<>()]+\.(js|mjs)(\?[^\s\x22\x27`<>()]*)?' "$SESSION_DIR/js/raw/" "$SESSION_DIR/js/deobf/" "$SESSION_DIR/js/formatted/" 2>/dev/null
                grep -rhoP '(?<![a-zA-Z0-9:])//[a-zA-Z0-9.-]+/[a-zA-Z0-9_/.-]+\.(js|mjs)(\?[^\s\x22\x27`<>()]*)?' "$SESSION_DIR/js/raw/" "$SESSION_DIR/js/deobf/" "$SESSION_DIR/js/formatted/" 2>/dev/null | sed 's|^//|https://|'
            fi
        } | sort -u > "$SESSION_DIR/state/tmp/.rec-new.txt"
        awk -F'|' '{print $2}' "$SESSION_DIR/state/url-map.txt" 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.rec-fetched.txt"
        sort -u "$SESSION_DIR/state/tmp/.js-discovered.txt" > "$SESSION_DIR/state/tmp/.rec-known.txt"
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
    done

    rm -f "$SESSION_DIR/state/tmp/.js-round-seeds.txt" "$SESSION_DIR/state/tmp/.js-pending.txt" "$SESSION_DIR/state/tmp/.js-done-urls.txt" "$SESSION_DIR/state/tmp/.js-round-fetched.txt" "$SESSION_DIR/state/tmp/.js-discovered.txt" "$SESSION_DIR/state/tmp/.sm-all.txt" "$SESSION_DIR/state/tmp/.sm-new.txt" "$SESSION_DIR/state/tmp/.obf-all.txt" "$SESSION_DIR/state/tmp/.obf-new.txt" "$SESSION_DIR/state/tmp/.pretty-all.txt" "$SESSION_DIR/state/tmp/.pretty-new.txt" "$SESSION_DIR/state/api-sampled.txt"

    local js_total mapsrc_total deobf_total
    js_total=$(find "$SESSION_DIR/js/raw" -name '*.js' 2>/dev/null | wc -l | tr -d ' ')
    mapsrc_total=$(find "$SESSION_DIR/js/mapsrc" \( -name '*.js' -o -name '*.ts' \) 2>/dev/null | wc -l | tr -d ' ')
    deobf_total=$(find "$SESSION_DIR/js/deobf" -name '*.js' 2>/dev/null | wc -l | tr -d ' ')
    stage_note "js=$js_total mapsrc=$mapsrc_total deobf=$deobf_total"
    out "${C_GRN}JS complete: $js_total files | mapsrc: $mapsrc_total | deobf: $deobf_total${C_R}"

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} -s -f -m 10 \$origin/{/sw.js,/service-worker.js,/worker.js,/precache-manifest.js}   (first-30 live origins)"
    : > "$SESSION_DIR/findings/surface/service-worker-urls.txt"
    head -30 "$SESSION_DIR/hosts/hosts-live.txt" 2>/dev/null | awk -F/ '{print $1"//"$3}' | sort -u | while read -r origin; do
        local c_hdr=(); build_c_hdr
        for sw in /sw.js /service-worker.js /worker.js /precache-manifest.js; do
            local body
            body=$(curl -s -f -m 10 -A "$FAKE_UA" "${c_hdr[@]+${c_hdr[@]}}" "$origin$sw" 2>/dev/null)
            [ -z "$body" ] && continue
            printf '%s\n' "$body" | grep -oE "['\"][^'\"]+\.(js|html|css)['\"]" | sed -e 's/^.//' -e 's/.$//' | while read -r a; do
                case "$a" in http*) printf '%s\n' "$a" ;; /*) printf '%s\n' "$origin$a" ;; *) printf '%s\n' "$origin/$a" ;; esac
            done >> "$SESSION_DIR/findings/surface/service-worker-urls.txt"
        done
    done
    sort -u "$SESSION_DIR/findings/surface/service-worker-urls.txt" -o "$SESSION_DIR/findings/surface/service-worker-urls.txt"
    if [ -s "$SESSION_DIR/findings/surface/service-worker-urls.txt" ]; then
        cat "$SESSION_DIR/findings/surface/service-worker-urls.txt" 
        grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/findings/surface/service-worker-urls.txt" | sort -u >> "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null
        sort -u "$SESSION_DIR/urls/urls-inscope.txt" -o "$SESSION_DIR/urls/urls-inscope.txt"
    fi
}
st_analysis_local() {
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ jsluice${C_R} secrets + urls: find js/raw js/deobf js/mapsrc -name '*.js' -size -20M | xargs -0 -P $PRETTIER_JOBS -I {} bash -c 'jsluice secrets + jsluice urls' _"
    mkdir -p "$SESSION_DIR/state/tmp/jsluice-out"
    : > "$SESSION_DIR/state/tmp/jsluice-failed.txt"
    : > "$SESSION_DIR/findings/secrets/jsluice-secrets.txt"
    : > "$SESSION_DIR/findings/surface/jsluice-endpoints.txt"
    find "$SESSION_DIR/js/raw" "$SESSION_DIR/js/deobf" "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/json" -type f -size -20M \( -name '*.js' -o -name '*.json' \) -print0 2>/dev/null | xargs -0 -P "$PRETTIER_JOBS" -I {} bash -c '
        f="$1"; d="'"$SESSION_DIR/state/tmp/jsluice-out"'/$(printf "%s" "$f" | md5sum | cut -c1-12)"
        mkdir -p "$d"
        jsluice secrets "$f" > "$d/secrets.jsonl" 2> "$d/secrets.err" || printf "%s\n" "$f" >> "'"$SESSION_DIR/state/tmp"'/jsluice-failed.txt"
        _org=$(awk -F'|' -v ff="$(basename "$f")" '$1==ff{print $2; exit}' "'"$SESSION_DIR"'/state/url-map.txt" 2>/dev/null)
        if [ -n "$_org" ]; then
            jsluice urls -R "$_org" "$f" > "$d/urls.jsonl" 2> "$d/urls.err" || true
        else
            jsluice urls "$f" > "$d/urls.jsonl" 2> "$d/urls.err" || true
        fi
    ' _ {}
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
    [ -s "$SESSION_DIR/findings/secrets/jsluice-secrets.txt" ] && cat "$SESSION_DIR/findings/secrets/jsluice-secrets.txt"
    [ -s "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" ] && cat "$SESSION_DIR/findings/surface/jsluice-endpoints.txt"
    local _jsec _jep
    _jsec=$(wc -l < "$SESSION_DIR/findings/secrets/jsluice-secrets.txt" 2>/dev/null | tr -d ' '); _jsec=${_jsec:-0}
    _jep=$(wc -l < "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" 2>/dev/null | tr -d ' '); _jep=${_jep:-0}
    out "${C_W}jsluice: $_jsec secrets, $_jep endpoints${C_R}"

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ trufflehog${C_R} filesystem js/raw js/mapsrc js/deobf --json | jq -r '[file, match, detector] | join(::) > trufflehog.txt || true"
    timeout --foreground 1200 trufflehog filesystem "$SESSION_DIR/js/raw" "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/deobf" --json 2>/dev/null \
      | jq -r '[.SourceMetadata.Data.Filesystem.file // "unknown", (.Redacted // .Raw // "" | gsub("\n";" ") | .[0:160]), .DetectorName] | join("::")' 2>/dev/null \
      | sed -e 's|js/raw/||' -e 's|js/mapsrc/||' -e 's|js/deobf/||' \
      | awk -F'::' -v sidecar="$SESSION_DIR/state/value-locations.tsv" '{k=($2==""?$0:$2); if(k in seen){if($1!="")printf "%s\t%s\n",k,$1 >> sidecar;next} seen[k]=1; print}' | sort -u > "$SESSION_DIR/findings/secrets/trufflehog.txt" || warn_rc "trufflehog" 1
    local th_count
    th_count=$(wc -l < "$SESSION_DIR/findings/secrets/trufflehog.txt" 2>/dev/null | tr -d ' '); th_count=${th_count:-0}
    out "${C_W}Trufflehog findings: $th_count${C_R}"
    [ "$th_count" -gt 0 ] && cat "$SESSION_DIR/findings/secrets/trufflehog.txt" 

    if command -v gitleaks &>/dev/null; then
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ gitleaks${C_R} detect --source js/ --no-git --report-format json"
        timeout --foreground 600 gitleaks detect --source "$SESSION_DIR/js" --no-git --report-format json --report-path "$SESSION_DIR/state/tmp/gitleaks.json" >/dev/null 2>&1 || warn_rc "gitleaks" 1
        jq -r '.[] | "\(.File // "?")::\(.RuleID // .Description // "?")::\((.Match // .Secret // "") | .[0:120])"' "$SESSION_DIR/state/tmp/gitleaks.json" 2>/dev/null | sort -u > "$SESSION_DIR/findings/secrets/gitleaks.txt"
        rm -f "$SESSION_DIR/state/tmp/gitleaks.json"
        [ -s "$SESSION_DIR/findings/secrets/gitleaks.txt" ] && cat "$SESSION_DIR/findings/secrets/gitleaks.txt"
    else
        out "${C_Y}[warn] gitleaks not installed -- skipping${C_R}"
    fi

    if command -v detect-secrets &>/dev/null; then
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ detect-secrets${C_R} scan js/"
        timeout --foreground 600 detect-secrets scan "$SESSION_DIR/js" > "$SESSION_DIR/state/tmp/ds.json" 2>/dev/null || warn_rc "detect-secrets" 1
        jq -r '.results | to_entries[] | .key as $f | .value[] | "\($f | sub("^.*/js/";"")):\(.line_number) :: \(.type)"' "$SESSION_DIR/state/tmp/ds.json" 2>/dev/null | sort -u > "$SESSION_DIR/findings/secrets/detect-secrets.txt"
        rm -f "$SESSION_DIR/state/tmp/ds.json"
        [ -s "$SESSION_DIR/findings/secrets/detect-secrets.txt" ] && cat "$SESSION_DIR/findings/secrets/detect-secrets.txt"
    else
        out "${C_Y}[warn] detect-secrets not installed -- skipping${C_R}"
    fi

    if command -v noseyparker &>/dev/null; then
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ noseyparker${C_R} scan --datastore np-data js/ && noseyparker report"
        rm -rf "$SESSION_DIR/state/tmp/np-data"
        timeout --foreground 900 noseyparker scan --datastore "$SESSION_DIR/state/tmp/np-data" "$SESSION_DIR/js" >/dev/null 2>&1 || warn_rc "noseyparker" 1
        timeout --foreground 300 noseyparker report --datastore "$SESSION_DIR/state/tmp/np-data" > "$SESSION_DIR/findings/secrets/noseyparker.txt" 2>/dev/null || true
        rm -rf "$SESSION_DIR/state/tmp/np-data"
        local _npc
        _npc=$(wc -l < "$SESSION_DIR/findings/secrets/noseyparker.txt" 2>/dev/null | tr -d ' '); _npc=${_npc:-0}
        out "${C_W}noseyparker findings: $_npc${C_R}"
        [ "$_npc" -gt 0 ] && cat "$SESSION_DIR/findings/secrets/noseyparker.txt" 
    else
        out "${C_Y}[warn] noseyparker not installed -- skipping${C_R}"
    fi

    if command -v trivy &>/dev/null; then
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ trivy${C_R} fs --scanners secret,vuln,config --format json js/"
        timeout --foreground 900 trivy fs --scanners secret,config --format json --quiet "$SESSION_DIR/js" > "$SESSION_DIR/state/tmp/trivy.json" 2>/dev/null || warn_rc "trivy" 1
        jq -r '.Results[]? | .Type as $t | ((.Secrets // [])[] | "secret|\($t)|\(.RuleID)|\(.Title)|line \(.StartLine)"), ((.Misconfigurations // [])[] | "config|\($t)|\(.ID // .AVDID)|\(.Title)|line \(.CauseMetadata.StartLine // 0)"), ((.Vulnerabilities // [])[] | "vuln|\(.PkgName)@\(.InstalledVersion)|\(.VulnerabilityID)|\(.Severity)")' "$SESSION_DIR/state/tmp/trivy.json" 2>/dev/null | sort -u > "$SESSION_DIR/findings/analysis/trivy.txt"
        rm -f "$SESSION_DIR/state/tmp/trivy.json"
        local _tc
        _tc=$(wc -l < "$SESSION_DIR/findings/analysis/trivy.txt" 2>/dev/null | tr -d ' '); _tc=${_tc:-0}
        out "${C_W}trivy findings: $_tc (secret+config+vuln)${C_R}"
        [ "$_tc" -gt 0 ] && cat "$SESSION_DIR/findings/analysis/trivy.txt" 
    else
        out "${C_Y}[warn] trivy not installed -- skipping${C_R}"
    fi

    if command -v syft &>/dev/null && command -v grype &>/dev/null; then
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ syft${C_R} dir:js/ -o json | ${C_RED}grype${C_R} sbom scan"
        _syft_root=""
        if [ -d "$SESSION_DIR/state/tmp/deobf" ] && find "$SESSION_DIR/state/tmp/deobf" -maxdepth 3 \( -name package.json -o -name package-lock.json \) -print -quit 2>/dev/null | grep -q .; then
            _syft_root="$SESSION_DIR/state/tmp/deobf"
        fi
        if [ -n "$_syft_root" ]; then
            timeout --foreground 600 syft dir:"$_syft_root" -o json > "$SESSION_DIR/state/tmp/sbom.json" 2>/dev/null || warn_rc "syft" 1
            timeout --foreground 600 grype sbom:"$SESSION_DIR/state/tmp/sbom.json" -o json > "$SESSION_DIR/state/tmp/grype.json" 2>/dev/null || warn_rc "grype" 1
        else
            out "${C_W}syft/grype skipped -- no package manifests in this corpus (npm-audit covers deobf lockfiles when present)${C_R}"
            stage_note "syft-nomanifest"
        fi
        jq -r '.matches[]? | "vuln|\(.artifact.name)@\(.artifact.version)|\(.vulnerability.id)|\(.vulnerability.severity)"' "$SESSION_DIR/state/tmp/grype.json" 2>/dev/null | sort -u > "$SESSION_DIR/findings/analysis/grype.txt"
        rm -f "$SESSION_DIR/state/tmp/sbom.json" "$SESSION_DIR/state/tmp/grype.json"
        local _gc
        _gc=$(wc -l < "$SESSION_DIR/findings/analysis/grype.txt" 2>/dev/null | tr -d ' '); _gc=${_gc:-0}
        out "${C_W}grype CVEs: $_gc${C_R}"
        [ "$_gc" -gt 0 ] && cat "$SESSION_DIR/findings/analysis/grype.txt" 
    else
        out "${C_Y}[warn] syft/grype not installed -- skipping${C_R}"
    fi

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ rg${C_R}/grep -P -o '<55+ secret/sink patterns>' over js/{formatted,mapsrc,deobf,json,artifacts} + entropy filter + cross-file value dedup"
    : > "$SESSION_DIR/findings/type-map.txt"
    mkdir -p "$SESSION_DIR/findings/secrets"

    hunt() {
        local msg="$1" regex="$2" outfile="$3" exclude="${4:-}" severity="${5:-MEDIUM}" minent="${6:-0}"
        printf '%s|%s|%s\n' "$outfile" "$msg" "$severity" >> "$SESSION_DIR/findings/type-map.txt"
        local raw=""
        for rep in formatted mapsrc deobf json artifacts; do
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
            raw=$(printf '%s\n' "$raw" | awk -v pat="$exclude" 'BEGIN{pat=tolower(pat)}{val=$0; sub(/^[^:]*:[0-9]*:/, "", val); if(tolower(val) !~ pat) print}')
        fi
        if [ "$minent" != "0" ] && [ -n "$raw" ]; then
            raw=$(printf '%s\n' "$raw" | awk -F: -v me="$minent" '{m="";for(i=3;i<=NF;i++)m=m $i (i<NF?":":"");s=m;n=length(s);if(n<16)next;delete c;for(i=1;i<=n;i++)c[substr(s,i,1)]++;e=0;for(k in c){p=c[k]/n;e-=p*log(p)};e=e/log(2);if(e+0>=me+0)print}')
        fi
        printf '%s\n' "$raw" | awk 'NF' | sort -u > "$SESSION_DIR/findings/secrets/$outfile"
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
    hunt "Internal hostnames" '\b[a-z0-9][a-z0-9-]*\.(internal|corp|local|intranet|staging|uat)\b' "internal-hosts.txt" "" "MEDIUM"
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
    hunt "Emails" '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "emails.txt" '(sentry\.io|example\.com|w3\.org|@2x|@3x)' "INFO"
    hunt "IPs" '\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b' "ip-addresses.txt" '(0\.0\.0\.0|127\.0\.0\.1|192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.|255\.255)' "INFO"
    hunt "Debug flags" '(?i)\bdebug\b\s*[:=]\s*[\x22\x27]?(true|1)' "debug-flags.txt" '(example)' "INFO"
    hunt "External URLs" 'https?://[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}[a-zA-Z0-9/=?&._~:%-]*' "js-external-urls.txt" '(w3\.org|react\.dev|localhost|github\.com|github\.io|npmjs\.com|mozilla\.org|example\.com|stackoverflow\.com|googleapis\.com|gstatic\.com|cloudflare\.com|jsdelivr\.net|unpkg\.com|google-analytics\.com|googletagmanager\.com|facebook\.net|facebook\.com|twitter\.com|x\.com|wikimedia\.org|wikipedia\.org|flagcdn\.com|whatwg\.org|rfc-editor\.org|iana\.org|ecma-international\.org|unicode\.org|crisp\.chat|sentry-cdn|sentry\.io|\.png|\.jpe?g|\.gif|\.svg|\.webp|\.avif|\.ico|\.woff2?|\.ttf|\.css)(\?|$)' "INFO"
    hunt "Generic secrets" '(?i)(api[_-]?key|apikey|secret|token|password|auth[_-]?token)[\x22\x27\s]*[:=][\x22\x27\s]*[A-Za-z0-9\-_=]{16,}' "generic-secrets.txt" '(undefined|null|true|false|function|your[a-z0-9_-]*|changeme|placeholder|dummy|redacted|x{8,}|\*{8,}|123456789|example)' "MEDIUM" "3.4"
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

    local seenfile="$SESSION_DIR/state/tmp/.seen-values"
    : > "$seenfile"
    : > "$SESSION_DIR/state/value-locations.tsv"
    for f in cloud-tokens.txt private-keys.txt private-keys-2.txt db-creds.txt basic-auth.txt signing-secrets.txt url-secrets.txt oauth-secrets.txt auth-tokens.txt azure-keys.txt service-accounts.txt payment-webhooks.txt ai-keys.txt ai-keys-2.txt devops-tokens.txt saas-tokens.txt saas-keys.txt tp-webhooks.txt hardcoded-bearer.txt presigned-urls.txt presigned-urls-2.txt smtp-creds.txt baas-pairs.txt generic-secrets.txt cloud-keys-2.txt comms-keys.txt auth-provider.txt payments-crypto.txt registry-ci.txt observability.txt config-file-secrets.txt; do
        [ -s "$SESSION_DIR/findings/secrets/$f" ] || continue
        awk -F: -v seenfile="$seenfile" -v sidecar="$SESSION_DIR/state/value-locations.tsv" 'BEGIN{while((getline l<seenfile)>0)seen[l]=1}{key="";for(i=3;i<=NF;i++)key=key $i (i<NF?":":"");if(key in seen){if($1!="")printf "%s\t%s\n",key,$1 >> sidecar;next}print;seen[key]=1}' "$SESSION_DIR/findings/secrets/$f" > "$SESSION_DIR/state/tmp/.tmp.$f"
        awk -F: '{key="";for(i=3;i<=NF;i++)key=key $i (i<NF?":":"");print key}' "$SESSION_DIR/state/tmp/.tmp.$f" >> "$seenfile"
        mv "$SESSION_DIR/state/tmp/.tmp.$f" "$SESSION_DIR/findings/secrets/$f"
    done
    rm -f "$seenfile"

    if [ -s "$SESSION_DIR/state/value-locations.tsv" ]; then
        find "$SESSION_DIR/js" -type f -printf '%f\t%P\n' 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.np.tsv"
        local npf="$SESSION_DIR/state/tmp/.np.tsv" um="$SESSION_DIR/state/url-map.txt" side="$SESSION_DIR/state/value-locations.tsv"
        local _ef
        for _ef in "$SESSION_DIR/findings"/secrets/*.txt; do
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
                        for (i2=1; i2<=nn && added<6; i2++) { f=c[i2];
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
        for _ef in "$SESSION_DIR/findings"/secrets/*.txt; do
            [ -f "$_ef" ] || continue
            awk -v np="$SESSION_DIR/state/tmp/.name-path.tsv" -v um="$SESSION_DIR/state/url-map.txt" -F'\t' '
                FILENAME==np { p[$1]=$2; next }
                FILENAME==um { split($0,u,"|"); m[$1]=u[2]; next }
                { fn=$0; sub(/:.*/,"",fn); outl=$0;
                  if (fn in m) outl=outl "  |  URL: " m[fn];
                  if (fn in p) outl=outl "  |  FILE: js/" p[fn];
                  print outl }' "$np" "$um" "$_ef" > "$_ef.tmp" 2>/dev/null && mv "$_ef.tmp" "$_ef"
        done
        rm -f "$SESSION_DIR/state/tmp/.name-path.tsv"
    fi

    out "${C_W}Regex engine results - all hunt files${C_R}"
    local _hf _hn
    while IFS='|' read -r _tf _msg _sev; do
        _hf="$SESSION_DIR/findings/secrets/$_tf"
        [ -s "$_hf" ] || continue
        _hn=$(wc -l < "$_hf" | tr -d ' ')
        out "${C_CYN}  $_tf ($_hn) - $_msg [$_sev]${C_R}"
        cat "$_hf" 
    done < "$SESSION_DIR/findings/type-map.txt"

    : > "$SESSION_DIR/findings/findings.jsonl"
    while IFS='|' read -r tf msg sev; do
        [ -f "$SESSION_DIR/findings/secrets/$tf" ] || continue
        awk -v type="$msg" -v sev="$sev" '
        function esc(s){gsub(/\\/,"\\\\",s);gsub(/"/,"\\\"",s);gsub(/\t/,"\\t",s);gsub(/\r/,"\\r",s);gsub(/\n/,"\\n",s);return s}
        {i1=index($0,":");if(i1==0){file=$0;line="-";m=""}else{file=substr($0,1,i1-1);rest=substr($0,i1+1);i2=index(rest,":");if(i2>0){line=substr(rest,1,i2-1);m=substr(rest,i2+1)}else{line="-";m=rest}}
        printf "{\"file\":\"%s\",\"line\":\"%s\",\"type\":\"%s\",\"severity\":\"%s\",\"confidence\":\"Pattern\",\"match\":\"%s\"}\n",esc(file),esc(line),esc(type),sev,esc(m)}' "$SESSION_DIR/findings/secrets/$tf" >> "$SESSION_DIR/findings/findings.jsonl"
    done < "$SESSION_DIR/findings/type-map.txt"

    if [ -s "$SESSION_DIR/urls/urls-inscope.txt" ]; then
        grep -oP '[?&](?:redirect|redirect_uri|redirect_url|return|return_url|returnto|return_to|next|continue|url|dest|destination|target|out|forward|go)=[^&\s]+' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null \
          | grep -viE '(example\.com|localhost)' | sort -u > "$SESSION_DIR/findings/probes/open-redirect-params.txt"
    fi

    out "${C_W}GraphQL APQ probing${C_R}"
    local apq_hashes
    apq_hashes=$(grep -rhoE 'sha256Hash.{0,5}"[0-9a-f]{64}"' "$SESSION_DIR/js/raw" "$SESSION_DIR/js/formatted" "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/deobf" 2>/dev/null | grep -oE '[0-9a-f]{64}' | sort -u | head -10)
    : > "$SESSION_DIR/findings/probes/graphql-persisted-queries.txt"
    if [ -n "$apq_hashes" ]; then
        printf '%s\n' "$apq_hashes" | while read -r h; do echo "hash: $h" >> "$SESSION_DIR/findings/probes/graphql-persisted-queries.txt"; done
        head -5 "$SESSION_DIR/hosts/hosts-live.txt" | awk -F/ '{print $1"//"$3}' | sort -u | while read -r origin; do
            for gp in /graphql /api/graphql /query; do
                printf '%s\n' "$apq_hashes" | while read -r h; do
                    local resp
                    resp=$(curl -s -m 10 -X POST -H 'Content-Type: application/json' "$origin$gp" -d "{\"operationName\":null,\"variables\":{},\"extensions\":{\"persistedQuery\":{\"version\":1,\"sha256Hash\":\"$h\"}}}" 2>/dev/null)
                    if printf '%s' "$resp" | grep -qE '"data"|"errors"'; then
                        echo "$origin$gp -> hash $h: RESPONDS" >> "$SESSION_DIR/findings/probes/graphql-persisted-queries.txt"
                    fi
                done
            done
        done
    fi
    [ -s "$SESSION_DIR/findings/probes/graphql-persisted-queries.txt" ] && cat "$SESSION_DIR/findings/probes/graphql-persisted-queries.txt"

    out "${C_W}postMessage handler analysis${C_R}"
    : > "$SESSION_DIR/findings/probes/postmessage-verdicts.txt"
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
            printf '%s|%s|%s\n' "$fn" "$ln" "$verdict" >> "$SESSION_DIR/findings/probes/postmessage-verdicts.txt"
        done < "$SESSION_DIR/findings/secrets/postmessage-listeners.txt"
        sort -u "$SESSION_DIR/findings/probes/postmessage-verdicts.txt" -o "$SESSION_DIR/findings/probes/postmessage-verdicts.txt"
        grep '|HIGH' "$SESSION_DIR/findings/probes/postmessage-verdicts.txt" 2>/dev/null | head -20
    fi

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} web.archive.org/cdx/search/cdx?url=<js> + /web/<ts>id_/<js>   (150 JS URLs x historical snapshots)"
    : > "$SESSION_DIR/findings/secrets/wayback-secrets.txt"
    {
        [ -s "$SESSION_DIR/state/js-map.txt" ] && cut -d'|' -f2 "$SESSION_DIR/state/js-map.txt"
        cat "$SESSION_DIR/urls/urls-js.txt" 2>/dev/null
    } | sort -u | head -150 > "$SESSION_DIR/state/tmp/.wb-js.txt"
    if [ -s "$SESSION_DIR/state/tmp/.wb-js.txt" ]; then
        mkdir -p "$SESSION_DIR/state/tmp/wayback-js"
        while read -r jsurl; do
            [ -z "$jsurl" ] && continue
            local enc_jsurl cdx
            enc_jsurl=$(printf '%s' "$jsurl" | jq -sRr @uri 2>/dev/null) || enc_jsurl="$jsurl"
            cdx=$(curl -s -m 15 "https://web.archive.org/cdx/search/cdx?url=${enc_jsurl}&output=text&fl=timestamp,digest&collapse=digest&limit=10" 2>/dev/null)
            [ -z "$cdx" ] && continue
            echo "$cdx" | awk 'NR < n {print $1}' n=$(echo "$cdx" | wc -l) | while read -r ts; do
                local wf hits
                wf="$SESSION_DIR/state/tmp/wayback-js/${ts}_$(printf '%s' "${jsurl%%\?*}" | md5sum | cut -c1-8)_$(basename "${jsurl%%\?*}")"
                [ -s "$wf" ] && continue
                curl -s -m 20 "https://web.archive.org/web/${ts}id_/${jsurl}" -o "$wf" 2>/dev/null
                [ -s "$wf" ] || continue
                hits=$(grep -oE 'AKIA[0-9A-Z]{16}|gh[pousr]_[a-zA-Z0-9]{36}|sk_live_[0-9a-zA-Z]{24}|xox[baprs]-[0-9a-zA-Z-]{10,}|SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}|glpat-[0-9A-Za-z_-]{20,}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|-----BEGIN[A-Z ]*PRIVATE KEY-----|api[_-]?key["'"'"']? *[:=] *["'"'"'][A-Za-z0-9_-]{16,}' "$wf" 2>/dev/null | sort -u)
                [ -n "$hits" ] && { echo "$jsurl @ $ts:" >> "$SESSION_DIR/findings/secrets/wayback-secrets.txt"; echo "$hits" | sed 's/^/    /' >> "$SESSION_DIR/findings/secrets/wayback-secrets.txt"; }
            done
        done < "$SESSION_DIR/state/tmp/.wb-js.txt"
    fi
    [ -s "$SESSION_DIR/findings/secrets/wayback-secrets.txt" ] && cat "$SESSION_DIR/findings/secrets/wayback-secrets.txt"
    rm -rf "$SESSION_DIR/state/tmp/wayback-js" "$SESSION_DIR/state/tmp/.wb-js.txt"

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ semgrep${C_R} scan --config=reconly-custom.yml --config=p/{javascript,secrets,react,vue,angular,jwt} --json js/mapsrc js/formatted js/deobf | jq -r 'path:line:check_id: message' || true"
    if [ -d "$SESSION_DIR/js/mapsrc" ] || [ -d "$SESSION_DIR/js/formatted" ]; then
        cat > "$SESSION_DIR/reconly-custom.yml" << 'YAMLEOF'
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
        timeout --foreground 1800 semgrep scan --config="$SESSION_DIR/reconly-custom.yml" --config=p/javascript --config=p/secrets --config=p/react --config=p/vue --config=p/angular --config=p/jwt --json --metrics=off \
            "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/formatted" "$SESSION_DIR/js/deobf" 2>"$SESSION_DIR/state/tmp/semgrep.err" \
          | jq -r '.results[] | "\(.path):\(.start.line):\(.check_id): \(.extra.message)"' > "$SESSION_DIR/findings/analysis/semgrep-findings.txt" 2>/dev/null || _sg_rc=1
        if [ "$_sg_rc" -ne 0 ]; then
            warn_rc "semgrep (registry)" "$_sg_rc"
            out "${C_Y}[warn] semgrep registry unreachable -- falling back to local rules only${C_R}"
            stage_note "semgrep-local"
            local _sgl_rc=0
            timeout --foreground 900 semgrep scan --config="$SESSION_DIR/reconly-custom.yml" --json --metrics=off \
                "$SESSION_DIR/js/mapsrc" "$SESSION_DIR/js/formatted" "$SESSION_DIR/js/deobf" 2>>"$SESSION_DIR/state/tmp/semgrep.err" \
              | jq -r '.results[] | "\(.path):\(.start.line):\(.check_id): \(.extra.message)"' > "$SESSION_DIR/findings/analysis/semgrep-findings.txt" 2>/dev/null || _sgl_rc=1
            [ "$_sgl_rc" -ne 0 ] && warn_rc "semgrep (local)" "$_sgl_rc"
        fi
        if [ -s "$SESSION_DIR/findings/analysis/semgrep-findings.txt" ]; then
            sort -u "$SESSION_DIR/findings/analysis/semgrep-findings.txt" -o "$SESSION_DIR/findings/analysis/semgrep-findings.txt"
            sed -i "s|^$SESSION_DIR/||" "$SESSION_DIR/findings/analysis/semgrep-findings.txt" 2>/dev/null || true
        fi
        [ -s "$SESSION_DIR/findings/analysis/semgrep-findings.txt" ] && cat "$SESSION_DIR/findings/analysis/semgrep-findings.txt"
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
            if codeql database create "$SESSION_DIR/state/tmp/.codeql-db" --language=javascript --source-root="$SESSION_DIR/state/tmp/.codeql-src" --overwrite >/dev/null; then
                local _cq_rc=0
                local -a _cq_cache=()
                mkdir -p "$HOME/github-tools/.codeql/compilation-cache" 2>/dev/null || true
                codeql database analyze --help 2>/dev/null | grep -q -- '--compilation-cache' && _cq_cache=(--compilation-cache "$HOME/github-tools/.codeql/compilation-cache")
                codeql database analyze "$SESSION_DIR/state/tmp/.codeql-db" "$_cq_suite" "${_cq_extra[@]+${_cq_extra[@]}}" "${_cq_cache[@]+${_cq_cache[@]}}" --format=sarif-latest --output="$SESSION_DIR/state/tmp/.codeql.sarif" --threads=0 >/dev/null || _cq_rc=$?
                [ "$_cq_rc" -ne 0 ] && warn_rc "codeql analyze" "$_cq_rc"
                jq -r '.runs[].results[]? | .ruleId' "$SESSION_DIR/state/tmp/.codeql.sarif" 2>/dev/null | sort | uniq -c | sort -rn | head -100 | awk '{printf "%6d x %s\n", $1, substr($0, index($0,$2))}' > "$SESSION_DIR/findings/analysis/codeql-findings.txt"
                [ -s "$SESSION_DIR/findings/analysis/codeql-findings.txt" ] && cat "$SESSION_DIR/findings/analysis/codeql-findings.txt"
                jq -r '.runs[] as $r | .results[]? | "\(.ruleId) :: \(.locations[0].physicalLocation.artifactLocation.uri // "?"):\(.locations[0].physicalLocation.region.startLine // 0)"' "$SESSION_DIR/state/tmp/.codeql.sarif" 2>/dev/null | sort -u | head -200 > "$SESSION_DIR/findings/analysis/codeql-locations.txt"
                [ -s "$SESSION_DIR/findings/analysis/codeql-locations.txt" ] && { out "${C_W}codeql locations (rule :: file:line):${C_R}"; cat "$SESSION_DIR/findings/analysis/codeql-locations.txt" ; }
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
    [ -s "$SESSION_DIR/findings/analysis/vulnerable-libs.txt" ] && cat "$SESSION_DIR/findings/analysis/vulnerable-libs.txt"

out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ npm${C_R} audit --json   (per package-lock.json found under tmp/deobf, critical+high only)"
    : > "$SESSION_DIR/findings/analysis/npm-audit.txt"
    find "$SESSION_DIR/state/tmp/deobf" -maxdepth 3 -name package-lock.json 2>/dev/null | while read -r lk; do
        local d
        d=$(dirname "$lk")
        ( cd "$d" && npm audit --json 2>/dev/null | jq -r '.vulnerabilities | to_entries[] | select(.value.severity=="critical" or .value.severity=="high") | "\(.key): \(.value.severity) \(.value.via[0].title // "")"' 2>/dev/null | sed "s|^|$d: |" ) >> "$SESSION_DIR/findings/analysis/npm-audit.txt" || true
    done
    [ -s "$SESSION_DIR/findings/analysis/npm-audit.txt" ] && cat "$SESSION_DIR/findings/analysis/npm-audit.txt"

    stage_note "secrets=$(wc -l < "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null | tr -d ' ')"
}
st_app_surface() {
out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ rg${C_R} -oP 'path:|fetch(|axios.|url:|WebSocket(|localStorage.|api_url|baseurl|server_url' js/mapsrc js/formatted"
    local ms="$SESSION_DIR/js/mapsrc" fd="$SESSION_DIR/js/formatted"
    local have_grep=0
    if command -v rg &>/dev/null && printf 'x1' | rg -qP '\d' 2>/dev/null; then have_grep=1; fi
    [ "$have_grep" -eq 1 ] || { out "${C_Y}No rg, skipping app surface mapping${C_R}"; return; }

    rg -oP "path:\s*['\"][^'\"]+['\"]" "$ms" "$fd" 2>/dev/null       | sed -E "s/.*path:\s*['\"]([^'\"]+)['\"].*/\1/"       | awk 'length($0)>1 && $0 !~ /\$\{|:|^https?:/' | sort -u > "$SESSION_DIR/findings/surface/app-routes.txt"
    stage_note "routes=$(wc -l < "$SESSION_DIR/findings/surface/app-routes.txt" 2>/dev/null | tr -d ' ')"
    cat "$SESSION_DIR/findings/surface/app-routes.txt" 

    {
        rg -oP "fetch\s*\(\s*['\"\`][^'\"\`]+['\"\`]" "$ms" "$fd" 2>/dev/null | sed -E "s/.*fetch\s*\(\s*['\"\`]([^'\"\`]+)['\"\`].*/GET \1/"
        rg -oP "axios\.(get|post|put|delete|patch)\s*\(\s*['\"\`][^'\"\`]+['\"\`]" "$ms" "$fd" 2>/dev/null | sed -E "s/.*axios\.(get|post|put|delete|patch)\s*\(\s*['\"\`]([^'\"\`]+)['\"\`].*/\U\1 \2/"
        rg -oP "url:\s*['\"][^'\"]+['\"]" "$ms" "$fd" 2>/dev/null | sed -E "s/.*url:\s*['\"]([^'\"]+)['\"].*/GET \1/"
        rg -oP "new\s+WebSocket\s*\(\s*['\"][^'\"]+['\"]" "$ms" "$fd" 2>/dev/null | sed -E "s/.*WebSocket\s*\(\s*['\"]([^'\"]+)['\"].*/WS \1/"
    } | awk 'NF>=2 && $2 !~ /\$\{|\+/ && $2 !~ /\/$/ && $2 ~ /^(\/|wss?:\/\/)/' | sort -u > "$SESSION_DIR/findings/surface/app-api-calls.txt"
    if [ -s "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" ]; then
        awk '{print "GET " $0}' "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" >> "$SESSION_DIR/findings/surface/app-api-calls.txt"
        sort -u "$SESSION_DIR/findings/surface/app-api-calls.txt" -o "$SESSION_DIR/findings/surface/app-api-calls.txt"
    fi
    cat "$SESSION_DIR/findings/surface/app-api-calls.txt" 

    rg -oP "(localStorage|sessionStorage)\.(get|set|remove)Item\(\s*['\"][^'\"]+['\"]" "$ms" "$fd" 2>/dev/null       | sed -E "s/.*Item\(\s*['\"]([^'\"]+)['\"].*/\1/"       | awk 'length($0)>2 && $0 !~ /\$\{/' | sort -u > "$SESSION_DIR/findings/surface/app-storage-keys.txt"
    cat "$SESSION_DIR/findings/surface/app-storage-keys.txt" 

    rg -oP -i "(api[_-]?url|baseurl|api[_-]?base|server[_-]?url|endpoint)\s*[:=]\s*['\"][^'\"]+['\"]" "$ms" "$fd" 2>/dev/null       | grep -viE "(localhost|example|placeholder|your[_-]|test)" | sort -u > "$SESSION_DIR/findings/surface/app-environments.txt"
    cat "$SESSION_DIR/findings/surface/app-environments.txt" 

    if [ -d "$SESSION_DIR/js/sourcemaps" ]; then
        find "$SESSION_DIR/js/sourcemaps" -name '*.map' -maxdepth 1 -print0 2>/dev/null           | xargs -0 -I{} jq -r '.sources[]? // empty' {} 2>/dev/null           | sort -u > "$SESSION_DIR/findings/surface/app-repo-structure.txt"
        cat "$SESSION_DIR/findings/surface/app-repo-structure.txt" 
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
            firstmatch=$(printf '%s' "$ctxline" | sed 's/^[^:]*:[0-9]*://')
            [ -n "$firstmatch" ] || continue
            for rep in mapsrc formatted; do
                [ -d "$SESSION_DIR/js/$rep" ] || continue
                ( cd "$SESSION_DIR/js/$rep" 2>/dev/null && rg --no-ignore -a -C 2 -F -e "$firstmatch" . 2>/dev/null ) | head -40 >> "$ctx_dir/$tf"
                [ -s "$ctx_dir/$tf" ] && break
            done
        done
    done < "$SESSION_DIR/findings/type-map.txt"
    local _cf
    for _cf in "$SESSION_DIR/findings/analysis/ctx"/*.txt; do
        [ -s "$_cf" ] || continue
        out "${C_CYN}$(basename "$_cf")${C_R}"
        cat "$_cf" 
    done
}
st_token_verify() {
    out "${C_Y}OPSEC: token verification sends detected tokens to EXTERNAL provider APIs${C_R}"
    : > "$SESSION_DIR/findings/probes/confirmed.txt"
    local CONF=0
    if [ -s "$SESSION_DIR/findings/secrets/cloud-tokens.txt" ]; then
        local tok code
        for tok in $(grep -oP 'gh[pousr]_[A-Za-z0-9]{36}' "$SESSION_DIR/findings/secrets/cloud-tokens.txt" | sort -u | head -5); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "Authorization: Bearer $tok" https://api.github.com/user 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] GitHub token ACTIVE: ${tok:0:10}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oE '(sk|rk)_live_[0-9a-zA-Z]{24}' "$SESSION_DIR/findings/secrets/cloud-tokens.txt" | sort -u | head -3); do
            curl -s -m 10 -u "$tok:" https://api.stripe.com/v1/balance 2>/dev/null | grep -q '"available"' && { echo "[CRITICAL] Stripe key ACTIVE: ${tok:0:8}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oE 'xox[baprs]-[0-9a-zA-Z-]{10,}' "$SESSION_DIR/findings/secrets/cloud-tokens.txt" | sort -u | head -3); do
            curl -s -m 10 -X POST -H "Authorization: Bearer $tok" https://slack.com/api/auth.test 2>/dev/null | grep -q '"ok":true' && { echo "[CRITICAL] Slack token ACTIVE: ${tok:0:8}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oE '[0-9]{8,10}:AA[A-Za-z0-9_-]{33}' "$SESSION_DIR/findings/secrets/cloud-tokens.txt" | sort -u | head -3); do
            curl -s -m 10 "https://api.telegram.org/bot${tok}/getMe" 2>/dev/null | grep -q '"ok":true' && { echo "[CRITICAL] Telegram bot ACTIVE: ${tok%%:*}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oE 'AIza[0-9A-Za-z\-_]{35}' "$SESSION_DIR/findings/secrets/cloud-tokens.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "https://generativelanguage.googleapis.com/v1/models?key=$tok" 2>/dev/null)
            [ "$code" = "200" ] && { echo "[HIGH] Google API key ACTIVE: ${tok:0:10}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oP 'glpat-[0-9A-Za-z_-]{20,}' "$SESSION_DIR/findings/secrets/cloud-tokens.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "PRIVATE-TOKEN: $tok" https://gitlab.com/api/v4/user 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] GitLab token ACTIVE: ${tok:0:10}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oE 'npm_[A-Za-z0-9]{36}' "$SESSION_DIR/findings/secrets/cloud-tokens.txt" | sort -u | head -3); do
            curl -s -m 10 -H "Authorization: Bearer $tok" https://registry.npmjs.org/-/whoami 2>/dev/null | grep -q '"username"' && { echo "[CRITICAL] NPM token ACTIVE: ${tok:0:8}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oE 'SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}' "$SESSION_DIR/findings/secrets/cloud-tokens.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "Authorization: Bearer $tok" https://api.sendgrid.com/v3/scopes 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] SendGrid key ACTIVE: ${tok:0:8}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
    fi
    cat "$SESSION_DIR/findings/secrets/cloud-tokens.txt" "$SESSION_DIR/findings/secrets/ai-keys.txt" "$SESSION_DIR/findings/secrets/ai-keys-2.txt" "$SESSION_DIR/findings/secrets/comms-keys.txt" "$SESSION_DIR/findings/secrets/devops-tokens.txt" "$SESSION_DIR/findings/secrets/registry-ci.txt" 2>/dev/null > "$SESSION_DIR/state/tmp/.toks-all.txt"
    if [ -s "$SESSION_DIR/state/tmp/.toks-all.txt" ]; then
        for tok in $(grep -oP 'sk-(?:proj-|ant-api03-)?[A-Za-z0-9_-]{20,}' "$SESSION_DIR/state/tmp/.toks-all.txt" | grep -vE 'sk-(live|test)_' | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "Authorization: Bearer $tok" https://api.openai.com/v1/models 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] OpenAI key ACTIVE: ${tok:0:8}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oP 'sk-ant-api03-[A-Za-z0-9_-]{20,}' "$SESSION_DIR/state/tmp/.toks-all.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "x-api-key: $tok" -H "anthropic-version: 2023-06-01" https://api.anthropic.com/v1/models 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] Anthropic key ACTIVE: ${tok:0:10}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oP 'gsk_[A-Za-z0-9]{20,}' "$SESSION_DIR/state/tmp/.toks-all.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "Authorization: Bearer $tok" https://api.groq.com/openai/v1/models 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] Groq key ACTIVE: ${tok:0:8}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oP 'hf_[A-Za-z0-9]{30,}' "$SESSION_DIR/state/tmp/.toks-all.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "Authorization: Bearer $tok" https://huggingface.co/api/whoami-v2 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] HuggingFace token ACTIVE: ${tok:0:8}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oP 'sk-or-[A-Za-z0-9_-]{20,}' "$SESSION_DIR/state/tmp/.toks-all.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "Authorization: Bearer $tok" https://openrouter.ai/api/v1/models 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] OpenRouter key ACTIVE: ${tok:0:8}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oP 'AC[0-9a-f]{32}:[0-9a-f]{32}' "$SESSION_DIR/state/tmp/.toks-all.txt" | sort -u | head -3); do
            curl -s -m 10 -u "$tok" https://api.twilio.com/2010-04-01/Accounts.json 2>/dev/null | grep -q '"sid"' && { echo "[CRITICAL] Twilio credentials ACTIVE: ${tok%%:*}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oP '\bkey-[0-9a-f]{32}\b' "$SESSION_DIR/state/tmp/.toks-all.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -u "api:$tok" https://api.mailgun.net/v3/domains 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] Mailgun key ACTIVE: ${tok:0:8}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oP 'dop_v1_[a-f0-9]{64}' "$SESSION_DIR/state/tmp/.toks-all.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "Authorization: Bearer $tok" https://api.digitalocean.com/v2/account 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] DigitalOcean token ACTIVE: ${tok:0:8}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oP '(?i)DD[_-]?API[_-]?KEY["'"'"' ]*[:=]["'"'"' ]*\K[a-f0-9]{32}' "$SESSION_DIR/state/tmp/.toks-all.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "DD-API-KEY: $tok" -H "Content-Type: application/json" https://api.datadoghq.com/api/v1/validate 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] Datadog API key ACTIVE: ${tok:0:6}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
        for tok in $(grep -oP 'sl\.[A-Za-z0-9_-]{20,}' "$SESSION_DIR/state/tmp/.toks-all.txt" | sort -u | head -3); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -X POST -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -d 'null' https://api.dropboxapi.com/2/users/get_current_account 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] Dropbox token ACTIVE: ${tok:0:6}..." >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
    fi
    rm -f "$SESSION_DIR/state/tmp/.toks-all.txt"

    if [ -s "$SESSION_DIR/findings/secrets/auth-tokens.txt" ]; then
        while read -r line; do
            local tok payload exp
            tok=$(printf '%s' "$line" | grep -oP 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' | head -1)
            [ -z "$tok" ] && continue
            local pb64 _pad
            pb64=$(printf '%s' "$tok" | cut -d. -f2)
            _pad=$(( (4 - ${#pb64} % 4) % 4 ))
            [ "$_pad" -gt 0 ] && pb64="${pb64}$(printf '=%.0s' $(seq 1 "$_pad"))"
            payload=$(printf '%s' "$pb64" | tr '_-' '/+' | base64 -d 2>/dev/null)
            exp=$(printf '%s' "$payload" | grep -oP '"exp":\s*\K[0-9]+' | head -1)
            [ -n "$exp" ] && [ "$exp" -gt "$(date +%s)" ] && { echo "[HIGH] JWT STILL VALID: ${tok:0:20}... (exp $exp)" >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done < <(head -20 "$SESSION_DIR/findings/secrets/auth-tokens.txt")
        local tok1 jhost jpath jcode forged payload
        tok1=$(grep -oP 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' "$SESSION_DIR/findings/secrets/auth-tokens.txt" | head -1)
        local _jwt_i=0 _jh_i=0 jhost
        while [ "$_jwt_i" -lt 3 ] && read -r tok1; do
            _jwt_i=$((_jwt_i+1))
            [ -s "$SESSION_DIR/hosts/hosts-live.txt" ] || continue
            payload=$(printf '%s' "$tok1" | cut -d. -f2)
            forged="eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.$payload."
            jpath=$(awk '{print $NF}' "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" 2>/dev/null | sort -u | head -1)
            [ -z "$jpath" ] && jpath="/"
            _jh_i=0
            while [ "$_jh_i" -lt 2 ] && read -r jhost; do
                _jh_i=$((_jh_i+1))
                jhost=$(printf '%s' "$jhost" | awk -F/ '{print $1"//"$3}')
                [ -n "$jhost" ] || continue
                jcode=$(curl -s -o /dev/null -w "%{http_code}" -m 8 -A "$FAKE_UA" -H "Authorization: Bearer $forged" "$jhost$jpath" 2>/dev/null)
                [ "$jcode" = "200" ] && { echo "[CRITICAL] JWT alg:none ACCEPTED at $jhost$jpath" >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
            done < <(head -2 "$SESSION_DIR/hosts/hosts-live.txt")
        done < <(grep -oP 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' "$SESSION_DIR/findings/secrets/auth-tokens.txt" | head -3)
    fi
    if [ -s "$SESSION_DIR/findings/secrets/baas-urls.txt" ]; then
        local db code
        for db in $(grep -oE '[a-z0-9][a-z0-9.-]*\.firebaseio\.com' "$SESSION_DIR/findings/secrets/baas-urls.txt" | sort -u | head -10); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://$db/.json" 2>/dev/null)
            [ "$code" = "200" ] && { echo "[CRITICAL] Firebase DB EXPOSED: $db/.json -> 200" >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
            curl -s -m 8 "https://$db/.settings/rules.json" 2>/dev/null | grep -q '"rules"' && { echo "[HIGH] Firebase RULES exposed: $db" >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
    fi
    if [ -s "$SESSION_DIR/findings/secrets/s3-buckets.txt" ]; then
        local b code
        for b in $(grep -oP '[a-z0-9][a-z0-9.-]{1,61}(?=\.s3[.-][a-z0-9-]*\.amazonaws\.com)' "$SESSION_DIR/findings/secrets/s3-buckets.txt" | sort -u | head -10); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://$b.s3.amazonaws.com/" 2>/dev/null)
            [ "$code" = "200" ] && { echo "[HIGH] S3 bucket LISTABLE: $b" >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
            [ "$code" = "403" ] && { echo "[MEDIUM] S3 bucket EXISTS (403): $b" >> "$SESSION_DIR/findings/probes/confirmed.txt"; CONF=$((CONF+1)); }
        done
    fi
    stage_note "confirmed=$CONF"
    out "${C_GRN}Confirmed findings: $CONF${C_R}"
    [ "$CONF" -gt 0 ] && cat "$SESSION_DIR/findings/probes/confirmed.txt" 
}

st_quick_probes() {
    local hl="$SESSION_DIR/hosts/hosts-live.txt"
    [ -s "$hl" ] || { out "${C_Y}No live hosts, skipping quick probes${C_R}"; return; }
    mkdir -p "$SESSION_DIR/findings/probes"
    awk -F/ '{print $1"//"$3}' "$hl" | sort -u | head -40 > "$SESSION_DIR/state/tmp/.qp-origins.txt"
    local ckcfg=""
    if [ -n "$AUTH_COOKIE" ]; then
        ckcfg="$SESSION_DIR/state/tmp/.qp-cookie.cfg"
        printf 'header = "Cookie: %s"\n' "$AUTH_COOKIE" > "$ckcfg"
    fi

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} -s -o /dev/null -D - <origin>   (top-40 live origins: headers + cookie flags + CORS reflection)"
    : > "$SESSION_DIR/findings/probes/security-headers.txt"
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
        pu=$(printf "%s" "$u" | sed -E "s~([?&](redirect(_uri|_url)?|return(_url)?|returnto|return_to|next|continue|url|dest|destination|target|out|forward|go)=)[^&]*~\1https://evil.example~")
        res=$(curl -s -o /dev/null -m 10 -A "$FAKE_UA" --max-redirs 0 -w "%{http_code} %{redirect_url}" "$pu" 2>/dev/null)
        case "$res" in 3*"evil.example"*) echo "$u -> $res" >> "'"$SESSION_DIR"'/findings/probes/open-redirect-confirmed.txt" ;; esac
    ' _ {}

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} '<url + zzcanary123>'   (60 URLs reflection probe)"
    : > "$SESSION_DIR/findings/probes/reflected-params.txt"
    grep '?' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | grep -vE '\.(js|css|png|jpe?g|gif|svg|woff2?|ttf|ico|map)(\?|$)' | head -60 \
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
        [ -n "$hit" ] && echo "$u reflects ($hit)" >> "'"$SESSION_DIR"'/findings/probes/reflected-params.txt"
    ' _ {}

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} <host> -w %{http_code}   (gated-host + sensitive-file + hidden-endpoint probes, parallel)"
    : > "$SESSION_DIR/findings/probes/hosts-auth-required.txt"
    cat "$hl" | xargs -d '\n' -P 20 -I {} bash -c '
        c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" "$1" 2>/dev/null)
        case "$c" in
            401|403)
                if [ -n "'"$ckcfg"'" ]; then
                    c2=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" -K "'"$ckcfg"'" "$1" 2>/dev/null)
                    echo "$1 -> $c anon / $c2 with cookie" >> "'"$SESSION_DIR"'/findings/probes/hosts-auth-required.txt"
                else
                    echo "$1 -> $c" >> "'"$SESSION_DIR"'/findings/probes/hosts-auth-required.txt"
                fi
                ;;
        esac
    ' _ {}
    : > "$SESSION_DIR/findings/probes/sensitive-files-live.txt"
    [ -s "$SESSION_DIR/urls/urls-artifacts.txt" ] && head -40 "$SESSION_DIR/urls/urls-artifacts.txt" | xargs -d '\n' -P 15 -I {} bash -c '
        c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" "$1" 2>/dev/null)
        [ "$c" = "200" ] && echo "$1 -> 200" >> "'"$SESSION_DIR"'/findings/probes/sensitive-files-live.txt"
    ' _ {}
    : > "$SESSION_DIR/findings/probes/hidden-endpoints.txt"
    {
        sed -E 's/^[^:]*:[0-9]*://' "$SESSION_DIR/findings/secrets/hidden-paths.txt" 2>/dev/null
        cat "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" 2>/dev/null
    } | sort -u | head -100 > "$SESSION_DIR/state/tmp/.qp-he.txt"
    if [ -s "$SESSION_DIR/state/tmp/.qp-he.txt" ]; then
        base=$(head -1 "$SESSION_DIR/state/tmp/.qp-origins.txt")
        cat "$SESSION_DIR/state/tmp/.qp-he.txt" | xargs -d '\n' -P 15 -I {} bash -c '
            c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" "'"$base"'"$1" 2>/dev/null)
            if [ "$c" = "200" ]; then
                echo "'"$base"'"$1" -> 200" >> "'"$SESSION_DIR"'/findings/probes/hidden-endpoints.txt"
            elif { [ "$c" = "401" ] || [ "$c" = "403" ]; } && [ -n "'"$ckcfg"'" ]; then
                c2=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -A "$FAKE_UA" -K "'"$ckcfg"'" "'"$base"'"$1" 2>/dev/null)
                case "$c2" in
                    2*) echo "'"$base"'"$1" -> $c anon / $c2 with cookie (session-gated)" >> "'"$SESSION_DIR"'/findings/probes/hidden-endpoints.txt"
                        echo "'"$base"'"$1" -> $c anon / $c2 with cookie (session-gated)" >> "'"$SESSION_DIR"'/findings/probes/auth-surface-map.txt" ;;
                esac
            fi
        ' _ {}
    fi
    rm -f "$SESSION_DIR/state/tmp/.qp-he.txt"

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ dnsx${C_R} -l dead-hosts -cname + httpx CNAME grep   (takeover fingerprints + passive IDOR/graphql/ws lists)"
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
    grep -oE 'https?://[^ ]*/[a-z0-9_-]+/[0-9]+([/?#][^ ]*)?' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | sort -u | head -50 > "$SESSION_DIR/findings/probes/idor-candidates.txt"
    grep -Ei '\b(create|update|delete|submit|register|upload|checkout)\b' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | grep -vE '\.(js|css|png|svg|woff)(\?|$)' | head -40 > "$SESSION_DIR/findings/probes/post-probe.txt"
    {
        cat "$SESSION_DIR/urls/urls-auth-only.txt" 2>/dev/null
        cat "$SESSION_DIR/findings/probes/hosts-auth-required.txt" 2>/dev/null
    } | sort -u > "$SESSION_DIR/state/tmp/.qp-asm.txt"
    cat "$SESSION_DIR/findings/probes/auth-surface-map.txt" "$SESSION_DIR/state/tmp/.qp-asm.txt" 2>/dev/null | sort -u > "$SESSION_DIR/state/tmp/.qp-asm2.txt" && mv "$SESSION_DIR/state/tmp/.qp-asm2.txt" "$SESSION_DIR/findings/probes/auth-surface-map.txt"
    rm -f "$SESSION_DIR/state/tmp/.qp-asm.txt"
    grep -F ' -> 200' "$SESSION_DIR/findings/probes/hidden-endpoints.txt" 2>/dev/null | grep -iE '/(admin|config|backup|internal|debug|dashboard|manage|private|secret)' | grep -viE '/(login|auth)(/|$)' > "$SESSION_DIR/findings/probes/auth-bypass.txt" || :
    : > "$SESSION_DIR/findings/probes/csp-deep.txt"
    head -20 "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null | while IFS= read -r _cu; do
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
    rm -f "$SESSION_DIR/state/tmp/.qp-origins.txt" "$SESSION_DIR/state/tmp/.qp-cookie.cfg"
    local _pf
    for _pf in "$SESSION_DIR/findings/probes"/*.txt; do
        [ -s "$_pf" ] || continue
        out "${C_CYN}$(basename "$_pf") ($(wc -l < "$_pf" | tr -d ' '))${C_R}"
        cat "$_pf" 
    done
    stage_note "headers=$(wc -l < "$SESSION_DIR/findings/probes/security-headers.txt" | tr -d ' ') or=$(wc -l < "$SESSION_DIR/findings/probes/open-redirect-confirmed.txt" | tr -d ' ') refl=$(wc -l < "$SESSION_DIR/findings/probes/reflected-params.txt" | tr -d ' ') takeover=$(wc -l < "$SESSION_DIR/findings/probes/takeover.txt" | tr -d ' ')"
}
st_triage() {
    out "${C_W}Triage scoring & export${C_R}"
    local outf="$SESSION_DIR/findings/triage.txt"
    : > "$outf"
    for f in "$SESSION_DIR/findings"/secrets/*.txt "$SESSION_DIR/findings"/probes/*.txt "$SESSION_DIR/findings"/analysis/*.txt "$SESSION_DIR/findings"/surface/*.txt; do
        [ -f "$f" ] || continue
        local base score=0 n
        base=$(basename "$f")
        case "$base" in
            confirmed.txt) score=60 ;;
            takeover.txt|ns-takeover.txt|services-exposed.txt|exposed-services.txt) score=55 ;;
            auth-bypass.txt) score=50 ;;
            sensitive-files-live.txt) score=45 ;;
            open-redirect-confirmed.txt) score=40 ;;
            reflected-params.txt) score=35 ;;
            postmessage-verdicts.txt) score=30 ;;
            hidden-endpoints.txt) score=48 ;;
            auth-surface-map.txt) score=40 ;;
            idor-candidates.txt) score=38 ;;
            revived-endpoints.txt) score=38 ;;
            urls-auth-only.txt) score=40 ;;
            jsluice-secrets.txt|trufflehog.txt|gitleaks.txt|detect-secrets.txt) score=45 ;;
            codeql-findings.txt) score=40 ;;
            semgrep-findings.txt) score=40 ;;
            grype.txt) score=35 ;;
            trivy.txt|noseyparker.txt) score=45 ;;
            npm-audit.txt) score=25 ;;
            framework-sinks.txt) score=32 ;;
            cors-misconfig.txt|security-headers.txt) score=30 ;;
            csp-deep.txt) score=28 ;;
            cookie-flags.txt) score=20 ;;
            hosts-auth-required.txt) score=25 ;;
            method-anomalies.txt) score=30 ;;
            *) score=10 ;;
        esac
        n=$(wc -l < "$f" 2>/dev/null | tr -d ' '); n=${n:-0}
        [ "$n" -gt 0 ] && printf "%3d pts | %-32s | %s findings\n" "$score" "$base" "$n" >> "$outf"
    done
    sort -rn "$outf" -o "$outf"
    cat "$outf" 

    if command -v jq &>/dev/null; then
        {
            jq -c '.' "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null
            if [ -s "$SESSION_DIR/findings/probes/confirmed.txt" ]; then
                while read -r _cl; do
                    printf '%s\n' "$_cl" | jq -Rc '{file:"confirmed.txt",line:"-",type:"Confirmed finding",severity:((match("\[(CRITICAL|HIGH|MEDIUM|LOW)\]").captures[0].string) // "MEDIUM"),confidence:"Active",match:.}' 2>/dev/null
                done < "$SESSION_DIR/findings/probes/confirmed.txt"
            fi
        } | jq -s 'unique | sort_by(.severity | if . == "CRITICAL" then 0 elif . == "HIGH" then 1 elif . == "MEDIUM" then 2 elif . == "LOW" then 3 else 4 end)' > "$SESSION_DIR/findings/export.json" 2>/dev/null || true
    fi

    {
        echo "next manual testing steps (generated from THIS scan)"
        echo "======================================================"
        if [ -s "$SESSION_DIR/findings/probes/confirmed.txt" ]; then
            echo ""; echo "== 0. CONFIRMED findings — validate first =="
            head -25 "$SESSION_DIR/findings/probes/confirmed.txt"
        fi
        if [ -s "$SESSION_DIR/findings/secrets/cloud-tokens.txt" ] || [ -s "$SESSION_DIR/findings/secrets/ai-keys.txt" ]; then
            echo ""; echo "== 1. tokens: verify & report as exposed-credentials =="
            echo "   curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer <token>\" https://api.github.com/user"
        fi
        if [ -s "$SESSION_DIR/findings/secrets/auth-tokens.txt" ]; then
            echo ""; echo "== 2. JWTs: decode / alg:none / weak secret =="
            echo "   decode: echo '<jwt>' | cut -d. -f2 | base64 -d"
            echo "   brute:  hashcat -m 16500 jwt.txt /usr/share/wordlists/jwt.secrets.list"
        fi
        if [ -s "$SESSION_DIR/findings/probes/auth-surface-map.txt" ]; then
            echo ""; echo "== 3. hidden endpoints: authz test =="
            echo "   replay with session, swap object IDs, verb tamper"
        fi
        if [ -s "$SESSION_DIR/findings/probes/idor-candidates.txt" ]; then
            echo ""; echo "== 4. IDOR: confirm cross-account =="
            echo "   same swapped-ID URL as user A and B -> B sees A data = confirmed"
        fi
        if [ -s "$SESSION_DIR/findings/probes/reflected-params.txt" ]; then
            echo ""; echo "== 5. reflected params: context-aware XSS =="
            echo "   sq: '><svg onload=alert(1)> | ctx-script: </script><script>alert(1)</script>"
        fi
        if [ -s "$SESSION_DIR/findings/probes/open-redirect-confirmed.txt" ]; then
            echo ""; echo "== 6. open redirect -> token theft via redirect_uri =="
        fi
        if grep -q '|HIGH' "$SESSION_DIR/findings/probes/postmessage-verdicts.txt" 2>/dev/null; then
            echo ""; echo "== 7. postMessage w/o origin check: PoC =="
            echo "   iframe: postMessage({html:'<img src=x onerror=alert(1)>'},'*')"
        fi
        if [ -s "$SESSION_DIR/findings/secrets/s3-buckets.txt" ]; then
            echo ""; echo "== 8. S3 buckets: enumerate read-only =="
            echo "   aws s3 ls s3://<bucket> --no-sign-request"
        fi
        if [ -s "$SESSION_DIR/findings/secrets/baas-urls.txt" ]; then
            echo ""; echo "== 9. Firebase: read DB + rules =="
            echo "   curl https://<project>.firebaseio.com/.json"
        fi
        if [ -s "$SESSION_DIR/findings/probes/cors-misconfig.txt" ]; then
            echo ""; echo "== 10. CORS PoC: fetch(target,{credentials:'include'}) from attacker origin =="
        fi
        if [ -s "$SESSION_DIR/findings/surface/app-api-calls.txt" ]; then
            echo ""; echo "== 11. API surface: per path GET/POST anon vs session vs second-user =="
        fi
    } > "$SESSION_DIR/findings/next-steps.txt"
    cat "$SESSION_DIR/findings/next-steps.txt" 

    {
        echo "reconly v2 — final summary"
        echo "============================"
        echo "domain:   $DOMAIN"
        echo "session:  $SESSION_DIR"
        echo ""
        echo "subdomains: $(wc -l < "$SESSION_DIR/subdomains/subdomains-final.txt" 2>/dev/null || echo 0)"
        echo "live hosts: $(wc -l < "$SESSION_DIR/hosts/hosts-live.txt" 2>/dev/null || echo 0)"
        echo "urls:       $(wc -l < "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null || echo 0)"
        echo "js files:   $(find "$SESSION_DIR/js/raw" -name '*.js' 2>/dev/null | wc -l | tr -d ' ')"
        echo "mapsrc:     $(find "$SESSION_DIR/js/mapsrc" \( -name '*.js' -o -name '*.ts' \) 2>/dev/null | wc -l | tr -d ' ')"
        echo "confirmed:  $(wc -l < "$SESSION_DIR/findings/probes/confirmed.txt" 2>/dev/null || echo 0)"
        echo ""
        echo "== confirmed by severity =="
        grep -oE '^\[(CRITICAL|HIGH|MEDIUM|LOW|INFO)\]' "$SESSION_DIR/findings/probes/confirmed.txt" 2>/dev/null | sort | uniq -c | sort -rn
        echo ""
        echo "== findings by severity (pattern) =="
        printf "CRITICAL: %s | HIGH: %s | MEDIUM: %s | LOW: %s | INFO: %s\n" \
            "$(grep -c '"severity":"CRITICAL"' "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null || true)" \
            "$(grep -c '"severity":"HIGH"' "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null || true)" \
            "$(grep -c '"severity":"MEDIUM"' "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null || true)" \
            "$(grep -c '"severity":"LOW"' "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null || true)" \
            "$(grep -c '"severity":"INFO"' "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null || true)"
        echo ""
        echo "== top triage =="
        head -10 "$SESSION_DIR/findings/triage.txt" 2>/dev/null
    } > "$SESSION_DIR/findings/summary.txt"
    cat "$SESSION_DIR/findings/summary.txt" 
}
st_report() {
    out "${C_W}Building mission-control report${C_R}"
    local html="$SESSION_DIR/report.html"
    local esc_domain esc_session
    esc_domain=$(printf '%s' "$DOMAIN" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    esc_session=$(printf '%s' "$SESSION_DIR" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

    local timeline_html=""
    while IFS=$'\t' read -r name rc dur stat; do
        local icon color
        if [ "$rc" = "0" ]; then icon="ok"; color="#3fb950"; else icon="FAIL"; color="#f85149"; fi
        timeline_html+="            <div class=\"tl-row\"><span class=\"tl-icon\" style=\"color:${color}\">${icon}</span><span class=\"tl-name\">${name}</span><span class=\"tl-dur\">${dur}</span><span class=\"tl-stat\">${stat}</span></div>"$'\n'
    done < "$STAGE_LOG"
    timeline_html+="            <div class=\"tl-row\"><span class=\"tl-icon\" style=\"color:#3fb950\">ok</span><span class=\"tl-name\">report</span><span class=\"tl-dur\">-</span><span class=\"tl-stat\">this file</span></div>"$'\n'

    local queue_html=""
    for sf in cloud-tokens.txt private-keys.txt private-keys-2.txt db-creds.txt config-file-secrets.txt signing-secrets.txt auth-provider.txt comms-keys.txt payments-crypto.txt ai-keys.txt ai-keys-2.txt; do
        local sfp="$SESSION_DIR/findings/secrets/$sf"
        [ -s "$sfp" ] || continue
        local sline esc_s
        while IFS= read -r sline; do
            [ -z "$sline" ] && continue
            esc_s=$(printf '%s' "$sline" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | cut -c1-220)
            queue_html+="            <div class=\"q-row\"><span class=\"q-badge\" style=\"background:#f85149\">CRITICAL</span><span class=\"q-text\">${esc_s}</span></div>"$'\n'
        done < <(head -3 "$sfp")
    done
    for f in confirmed.txt takeover.txt hidden-endpoints.txt auth-bypass.txt open-redirect-confirmed.txt reflected-params.txt postmessage-verdicts.txt idor-candidates.txt auth-surface-map.txt; do
        local fp="$SESSION_DIR/findings/probes/$f"
        [ -s "$fp" ] || continue
        local sev color
        case "$f" in
            confirmed.txt) sev="CRITICAL"; color="#f85149" ;;
            takeover.txt|hidden-endpoints.txt|auth-bypass.txt|idor-candidates.txt) sev="HIGH"; color="#db6d28" ;;
            *) sev="MEDIUM"; color="#d29922" ;;
        esac
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local lsev="$sev" lcolor="$color" esc_line
            if [ "$f" = "postmessage-verdicts.txt" ]; then
                local _vrest _vfile _vln _vverd
                _vfile="${line%%|*}"; _vrest="${line#*|}"
                _vln="${_vrest%%|*}"; _vverd="${_vrest##*|}"
                esc_line="${_vfile}:${_vln} -- ${_vverd}"
                case "$_vverd" in
                    HIGH*) lsev="HIGH"; lcolor="#db6d28" ;;
                    INFO*) lsev="INFO"; lcolor="#8b949e" ;;
                    *) lsev="MEDIUM"; lcolor="#d29922" ;;
                esac
            else
                if printf '%s' "$line" | grep -q '^\[CRITICAL\]'; then lsev="CRITICAL"; lcolor="#f85149"
                elif printf '%s' "$line" | grep -q '^\[HIGH\]'; then lsev="HIGH"; lcolor="#db6d28"
                elif printf '%s' "$line" | grep -q '^\[MEDIUM\]'; then lsev="MEDIUM"; lcolor="#d29922"
                elif printf '%s' "$line" | grep -q '^\[LOW\]'; then lsev="LOW"; lcolor="#8b949e"
                fi
                esc_line=$(printf '%s' "$line" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
            fi
            queue_html+="            <div class=\"q-row\"><span class=\"q-badge\" style=\"background:${lcolor}\">${lsev}</span><span class=\"q-text\">${esc_line}</span></div>"$'\n'
        done < <(head -30 "$fp")
    done

    if [ -s "$SESSION_DIR/findings/findings.jsonl" ]; then
        jq -r '"\(.severity)|\(.confidence)|\(.type)|\(.file)|\(.line)|\(.match)"' "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null | awk -F'|' '{r=(($1=="CRITICAL")?0:($1=="HIGH")?1:($1=="MEDIUM")?2:($1=="LOW")?3:4); print r "|" $0}' | sort -t'|' -k1,1n | cut -d'|' -f2- | awk -F'|' '{printf "[%-8s] [%s] %s :: %s:%s :: %.160s\n",$1,$2,$3,$4,$5,$6}' > "$SESSION_DIR/findings/all-findings.txt" 2>/dev/null || true
    fi
    : > "$SESSION_DIR/findings/by-type.txt"
    while IFS='|' read -r _tf _msg _sev; do
        [ -f "$SESSION_DIR/findings/secrets/$_tf" ] || continue
        local _n
        _n=$(wc -l < "$SESSION_DIR/findings/secrets/$_tf" 2>/dev/null | tr -d ' '); _n=${_n:-0}
        [ "$_n" -gt 0 ] && printf "[%s] %5d x %s\n" "$_sev" "$_n" "$_msg" >> "$SESSION_DIR/findings/by-type.txt"
    done < "$SESSION_DIR/findings/type-map.txt"
    sort -o "$SESSION_DIR/findings/by-type.txt" "$SESSION_DIR/findings/by-type.txt" 2>/dev/null || true

    local c_crit c_high c_med c_urls c_js c_subs c_live f_crit f_high f_med f_total c_all c_mapsrc
    c_crit=$(grep -c '^\[CRITICAL\]' "$SESSION_DIR/findings/probes/confirmed.txt" 2>/dev/null || true); c_crit=${c_crit:-0}
    c_high=$(grep -c '^\[HIGH\]' "$SESSION_DIR/findings/probes/confirmed.txt" 2>/dev/null || true); c_high=${c_high:-0}
    c_med=$(grep -c '^\[MEDIUM\]' "$SESSION_DIR/findings/probes/confirmed.txt" 2>/dev/null || true); c_med=${c_med:-0}
    c_subs=$(wc -l < "$SESSION_DIR/subdomains/subdomains-final.txt" 2>/dev/null || echo 0)
    c_live=$(wc -l < "$SESSION_DIR/hosts/hosts-live.txt" 2>/dev/null || echo 0)
    c_urls=$(wc -l < "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null || echo 0)
    c_js=$(find "$SESSION_DIR/js/raw" -name '*.js' 2>/dev/null | wc -l | tr -d ' ')
    f_crit=$(grep -c '"severity":"CRITICAL"' "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null || true); f_crit=${f_crit:-0}
    f_high=$(grep -c '"severity":"HIGH"' "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null || true); f_high=${f_high:-0}
    f_med=$(grep -c '"severity":"MEDIUM"' "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null || true); f_med=${f_med:-0}
    f_total=$(wc -l < "$SESSION_DIR/findings/findings.jsonl" 2>/dev/null | tr -d ' '); f_total=${f_total:-0}
    c_all=$(wc -l < "$SESSION_DIR/findings/probes/confirmed.txt" 2>/dev/null | tr -d ' '); c_all=${c_all:-0}
    c_mapsrc=$(find "$SESSION_DIR/js/mapsrc" \( -name '*.js' -o -name '*.ts' \) 2>/dev/null | wc -l | tr -d ' ')

    out "${C_W}Building findings explanations${C_R}"
    {
        echo "E X P L A N A T I O N S -- what each finding means and how to benefit"
        echo "==============================================================="
        echo "Cards top-right = pattern counts. ACTIVE (verified) = triage first."
        echo ""
    } > "$SESSION_DIR/findings/explanations.txt"
    _exp_what() {
        case "$1" in
            cloud-tokens.txt) echo "Hardcoded cloud/SaaS API keys (AWS/GitHub/Slack/Stripe/Telegram...) shipped to the browser." ;;
            private-keys.txt|private-keys-2.txt) echo "Private key material (PEM/OPENSSH/AGE/JWK) embedded in client-side code." ;;
            db-creds.txt) echo "Database connection strings with username:password reachable from the JS." ;;
            basic-auth.txt) echo "URLs with embedded user:password credentials." ;;
            signing-secrets.txt) echo "JWT/session/HMAC/encryption secrets hardcoded -- forge sessions or sign arbitrary tokens." ;;
            url-secrets.txt) echo "Secrets living in URL query parameters (logged by proxies, browser history, analytics)." ;;
            oauth-secrets.txt|oauth-ids.txt) echo "OAuth client secrets/IDs -- may allow token issuance if the provider config is weak." ;;
            auth-tokens.txt) echo "JWTs or Bearer tokens in the code. Decode the payload; check exp; try alg:none and weak-secret brute (hashcat -m 16500)." ;;
            azure-keys.txt) echo "Azure Storage account keys -- full storage account control." ;;
            service-accounts.txt) echo "Google service-account metadata/keys." ;;
            payment-webhooks.txt|payments-crypto.txt) echo "Payment processor secret keys or webhook signing secrets -- refund/fraud impact." ;;
            ai-keys.txt|ai-keys-2.txt) echo "LLM provider keys (OpenAI/Anthropic/Groq...) -- billable, often with org access." ;;
            devops-tokens.txt|registry-ci.txt) echo "CI/CD or registry tokens (GitHub Actions, NPM, Docker...) -- pivot to supply chain." ;;
            saas-tokens.txt|saas-keys.txt) echo "SaaS platform tokens (Notion/Segment/HubSpot...)." ;;
            tp-webhooks.txt) echo "Third-party webhook URLs (Slack/Teams/Zapier) -- can be abused to post/spam if secret leaks." ;;
            hardcoded-bearer.txt) echo "Hardcoded Bearer token string literals." ;;
            presigned-urls.txt|signed-urls-2.txt) echo "Pre-signed cloud URLs (S3/GCS/Azure) -- grant time-limited access; check expiry." ;;
            smtp-creds.txt) echo "Mail server credentials -- phishing infrastructure." ;;
            baas-pairs.txt) echo "Algolia/Pusher app-id + api-key pairs." ;;
            sdk-configs.txt) echo "Sentry/Cloudinary/Mapbox SDK configs -- often over-privileged." ;;
            cognito-pools.txt) echo "AWS Cognito identity pool IDs -- check for unauthenticated IAM roles." ;;
            s3-buckets.txt) echo "S3 bucket references -- test list/read permissions (aws s3 ls --no-sign-request)." ;;
            baas-urls.txt) echo "Firebase/Supabase/Appwrite project URLs -- test .json read and rules exposure." ;;
            internal-hosts.txt) echo "Internal/development hostnames revealed in client code." ;;
            debug-endpoints.txt) echo "Debug/actuator endpoints referenced (/actuator/env, /debug/pprof...)." ;;
            source-maps.txt) echo "Sourcemap references -- fetch them to recover original source (this pipeline already does)." ;;
            dom-sinks.txt) echo "DOM XSS sinks (innerHTML/eval/document.write...) -- trace whether attacker input reaches them." ;;
            framework-sinks.txt) echo "Framework-specific dangerous sinks (dangerouslySetInnerHTML, v-html, bypassSecurityTrust...)." ;;
            postmessage-listeners.txt|postmessage-verdicts.txt) echo "postMessage handlers -- verdict shows if origin is validated; unvalidated = cross-origin DOM XSS." ;;
            hidden-paths.txt) echo "Paths found in JS strings (/admin, /internal, /api...)." ;;
            websockets.txt|ws-probes.txt) echo "WebSocket endpoints -- test for missing auth and cross-site WebSocket hijacking." ;;
            graphql.txt|graphql-mutations.txt) echo "GraphQL operations/mutations discovered -- enumerate schema, test authz per field." ;;
            graphql-persisted-queries.txt) echo "Persisted Query hashes -- replay them to extract hidden operations." ;;
            dev-comments.txt) echo "TODO/FIXME/HACK comments -- reveal internals, credentials hints, unfinished features." ;;
            debug-flags.txt) echo "Debug flags enabled in production code." ;;
            emails.txt) echo "Email addresses -- reporting contacts, phishing targets." ;;
            ip-addresses.txt) echo "Hardcoded IPs -- direct targets bypassing CDN/WAF." ;;
            js-external-urls.txt) echo "External URLs called by the app -- third-party trust boundaries." ;;
            generic-secrets.txt) echo "Generic key=high-entropy-value assignments -- manually review." ;;
            cloud-keys-2.txt) echo "Second-tier cloud keys (Oracle/Alibaba/DigitalOcean/Hetzner/Vultr...)." ;;
            comms-keys.txt) echo "Messaging API keys (Twilio/Mailgun/Plivo...) -- SMS/email abuse + cost." ;;
            auth-provider.txt) echo "Auth-provider tokens (Okta/AWS SSO/Auth0-style)." ;;
            observability.txt) echo "Monitoring keys (New Relic/Grafana/Datadog/Splunk)." ;;
            captcha-keys.txt) echo "Captcha site/secret keys -- secret keys should never ship client-side." ;;
            webpush.txt) echo "WebPush VAPID keys." ;;
            config-file-secrets.txt) echo "Secrets inside config-file syntax (_authToken, client-key-data...)." ;;
            jsluice-secrets.txt) echo "Secrets extracted by jsluice (URLs, keys, creds parsed from JS structure)." ;;
            trufflehog.txt|gitleaks.txt|detect-secrets.txt|noseyparker.txt) echo "Third-party secret-scanner hits -- corroboration for the regex findings; triage together." ;;
            trivy.txt) echo "Trivy secret/config findings." ;;
            grype.txt|vulnerable-libs.txt|npm-audit.txt) echo "Known-vulnerable JS libraries with CVEs -- map CVE to exploit; check reachable code paths." ;;
            codeql-findings.txt) echo "CodeQL rule histogram -- deep semantic analysis counts by vulnerability class." ;;
            codeql-locations.txt) echo "CodeQL findings with file:line -- jump to the vulnerable code directly." ;;
            semgrep-findings.txt) echo "Semgrep rule hits (taint + custom rules) with file:line and message." ;;
            confirmed.txt) echo "VERIFIED ACTIVE findings (token validated against provider, exposed DB, alg:none accepted...). Highest priority." ;;
            takeover.txt) echo "Subdomain takeover fingerprints -- dangling CNAMEs to unclaimed cloud resources. Claim and report." ;;
            hidden-endpoints.txt) echo "Endpoints probed live: 200 anon = directly reachable; 401/403 with-cookie = session-gated surface." ;;
            auth-bypass.txt) echo "Sensitive paths (admin/config/backup...) returning 200 WITHOUT auth." ;;
            open-redirect-confirmed.txt|open-redirect-params.txt) echo "Confirmed open redirects -- chain into OAuth token theft or phishing." ;;
            reflected-params.txt) echo "Parameters reflected in responses -- test context-aware XSS payloads." ;;
            idor-candidates.txt) echo "URLs with numeric object IDs -- swap IDs across accounts to test authorization." ;;
            auth-surface-map.txt) echo "Map of what the session unlocks -- replay these with a second user to find authz gaps." ;;
            cors-misconfig.txt) echo "CORS misconfigurations -- arbitrary origin reflection enables cross-origin data theft with credentials." ;;
            security-headers.txt) echo "Missing security headers (CSP/HSTS/X-Frame-Options...) -- weakens browser-side defenses." ;;
            csp-deep.txt) echo "CSP weaknesses: unsafe-inline/eval, wildcards, data: URIs." ;;
            cookie-flags.txt) echo "Cookies missing Secure/HttpOnly/SameSite -- enables theft via XSS or MITM." ;;
            sensitive-files-live.txt) echo "Artifact URLs (.env/.sql/.bak...) returning 200 -- download and inspect." ;;
            surface-matrix.txt) echo "HTTP status map of top in-scope URLs." ;;
            method-anomalies.txt) echo "Endpoints accepting unusual HTTP methods (TRACE/PUT/DELETE) -- verb tampering." ;;
            hosts-auth-required.txt) echo "Hosts gated with 401/403 -- compare anon vs cookie status." ;;
            app-routes.txt) echo "Client-side routes discovered -- map the application's navigation surface." ;;
            app-api-calls.txt) echo "API endpoints called by the frontend -- test each anon vs session vs second user." ;;
            app-storage-keys.txt) echo "localStorage/sessionStorage keys -- sensitive data stored client-side is XSS-readable." ;;
            app-environments.txt) echo "Backend URLs/environment configs hardcoded in the app." ;;
            app-repo-structure.txt) echo "Original repo layout from sourcemaps -- reveals internal naming and structure." ;;
            jsluice-endpoints.txt) echo "Endpoints extracted from JS by jsluice." ;;
            service-worker-urls.txt) echo "URLs referenced by service workers -- cached app surface." ;;
            wayback-secrets.txt) echo "Secrets found in HISTORICAL JS snapshots -- old builds often leak more." ;;
            *) echo "Raw pattern findings -- review lines manually; severity label is above each block." ;;
        esac
    }
    _exp_benefit() {
        case "$1" in
            confirmed.txt) echo "Validate each line read-only, then report immediately -- these are provable." ;;
            cloud-tokens.txt|ai-keys.txt|ai-keys-2.txt|devops-tokens.txt|registry-ci.txt|comms-keys.txt|payment-webhooks.txt|payments-crypto.txt|auth-provider.txt|observability.txt) echo "Verify active (or use --verify-tokens), then report as exposed credentials; do not access data beyond identity/scope checks." ;;
            takeover.txt) echo "Confirm the CNAME dangles (nxdomain at provider), claim the resource with your account, screenshot, report, release." ;;
            auth-bypass.txt|hidden-endpoints.txt) echo "Replay with the session, then swap object IDs and verbs; a 200-anon admin path is a critical finding." ;;
            open-redirect-confirmed.txt) echo "Chain: redirect_uri / oauth callback / password-reset poisoning." ;;
            reflected-params.txt) echo "Escalate: context-aware XSS (svg onload, script-context breakout)." ;;
            postmessage-verdicts.txt) echo "HIGH verdict = build a PoC iframe posting attacker data with '*'; check what the listener does with .data." ;;
            idor-candidates.txt) echo "Two-account test: A fetches B's object ID. Data exposure = confirmed IDOR." ;;
            cors-misconfig.txt) echo "PoC page: fetch(target, {credentials:'include'}) from attacker origin, exfiltrate response." ;;
            grype.txt|vulnerable-libs.txt) echo "Match CVE -> exploit PoC; confirm the vulnerable function is reachable in the recovered sources." ;;
            codeql-locations.txt|semgrep-findings.txt) echo "Open the file:line in js/mapsrc or js/deobf; trace the source -> sink path manually." ;;
            *) echo "Cross-reference with the same file's report tab; severity-ranked export lives in all-findings.txt." ;;
        esac
    }
    for _ef in "$SESSION_DIR/findings"/secrets/*.txt "$SESSION_DIR/findings"/probes/*.txt "$SESSION_DIR/findings"/analysis/*.txt; do
        [ -s "$_ef" ] || continue
        _eb=$(basename "$_ef")
        _sev=$(awk -F'|' -v f="$_eb" '$1==f{print $3; exit}' "$SESSION_DIR/findings/type-map.txt" 2>/dev/null)
        {
            echo "### $_eb${_sev:+ [$_sev]}"
            echo "WHAT:   $(_exp_what "$_eb")"
            echo "BENEFIT: $(_exp_benefit "$_eb")"
            echo "EVIDENCE (first 2):"
            head -2 "$_ef" | sed 's/^/    /'
            echo ""
        } >> "$SESSION_DIR/findings/explanations.txt"
    done

    local tabs_def=""
    local content_html=""
    local first=1
    _add_tab() {
        local file="$1" label="$2" color="$3"
        [ -f "$file" ] || return 0
        local id count data
        id=$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '-')
        count=$(wc -l < "$file" 2>/dev/null | tr -d ' '); count=${count:-0}
        local active=""
        [ "$first" -eq 1 ] && { active=" active"; first=0; }
        local _disp="none"
        [ -n "$active" ] && _disp="block"
        tabs_def+="        <button class=\"tablinks${active}\" onclick=\"openTab(event,'${id}')\" style=\"color:${color}\">${label}<span class=\"badge\">${count}</span></button>"$'\n'
        data=$(head -n 5000 "$file" 2>/dev/null | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
        local _total_lines _shown_lines
        _total_lines=$(wc -l < "$file" 2>/dev/null | tr -d ' '); _total_lines=${_total_lines:-0}
        _shown_lines=$_total_lines
        [ "$_total_lines" -gt 5000 ] && _shown_lines=5000
        content_html+="    <div id=\"${id}\" class=\"tabcontent\" style=\"display:${_disp};\">
      <div class=\"tab-header\"><span style=\"color:${color};font-weight:bold\">${label}</span><span style=\"color:var(--fg2);font-size:11px;margin-left:8px\">showing ${_shown_lines} of ${_total_lines} lines</span><button class=\"copy-btn\" onclick=\"copyData(this)\">Copy</button></div>
      <textarea class=\"data-box\" readonly spellcheck=\"false\">${data}</textarea>
    </div>"$'\n'
    }

    _add_tab "$SESSION_DIR/findings/summary.txt" "summary" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/explanations.txt" "explanations" "#3fb950"
    _add_tab "$SESSION_DIR/findings/next-steps.txt" "next-steps" "#3fb950"
    _add_tab "$SESSION_DIR/findings/probes/confirmed.txt" "confirmed" "#f85149"
    _add_tab "$SESSION_DIR/findings/triage.txt" "triage" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/all-findings.txt" "all-findings" "#f85149"
    _add_tab "$SESSION_DIR/findings/by-type.txt" "by-type" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/probes/hidden-endpoints.txt" "hidden-endpoints" "#db6d28"
    _add_tab "$SESSION_DIR/findings/probes/auth-bypass.txt" "auth-bypass" "#db6d28"
    _add_tab "$SESSION_DIR/findings/probes/open-redirect-confirmed.txt" "open-redirect" "#d29922"
    _add_tab "$SESSION_DIR/findings/probes/reflected-params.txt" "reflected" "#d29922"
    _add_tab "$SESSION_DIR/findings/probes/postmessage-verdicts.txt" "postmessage" "#d29922"
    _add_tab "$SESSION_DIR/findings/probes/idor-candidates.txt" "idor" "#db6d28"
    _add_tab "$SESSION_DIR/findings/probes/auth-surface-map.txt" "auth-surface" "#db6d28"
    _add_tab "$SESSION_DIR/findings/probes/cors-misconfig.txt" "cors" "#d29922"
    _add_tab "$SESSION_DIR/findings/probes/security-headers.txt" "headers" "#d29922"
    _add_tab "$SESSION_DIR/findings/probes/csp-deep.txt" "csp-deep" "#d29922"
    _add_tab "$SESSION_DIR/findings/probes/cookie-flags.txt" "cookies" "#8b949e"
    _add_tab "$SESSION_DIR/findings/probes/ws-probes.txt" "websockets" "#8b949e"
    _add_tab "$SESSION_DIR/findings/probes/takeover.txt" "takeover" "#f85149"
    _add_tab "$SESSION_DIR/findings/probes/graphql-mutations.txt" "graphql-muts" "#8b949e"
    _add_tab "$SESSION_DIR/findings/probes/graphql-persisted-queries.txt" "graphql-apq" "#8b949e"
    _add_tab "$SESSION_DIR/findings/probes/sensitive-files-live.txt" "sensitive-files" "#db6d28"
    _add_tab "$SESSION_DIR/findings/probes/surface-matrix.txt" "surface-matrix" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/probes/method-anomalies.txt" "method-anomalies" "#d29922"
    _add_tab "$SESSION_DIR/findings/probes/post-probe.txt" "post-probe" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/cloud-tokens.txt" "cloud-tokens" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/private-keys.txt" "private-keys" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/db-creds.txt" "db-creds" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/signing-secrets.txt" "signing-secrets" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/auth-tokens.txt" "auth-tokens" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/oauth-secrets.txt" "oauth-secrets" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/ai-keys.txt" "ai-keys" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/devops-tokens.txt" "devops-tokens" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/payment-webhooks.txt" "payment" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/saas-tokens.txt" "saas-tokens" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/hardcoded-bearer.txt" "bearer" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/presigned-urls.txt" "presigned" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/smtp-creds.txt" "smtp" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/generic-secrets.txt" "generic-secrets" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/cloud-keys-2.txt" "cloud-keys-2" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/comms-keys.txt" "comms-keys" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/auth-provider.txt" "auth-provider" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/payments-crypto.txt" "payments-crypto" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/ai-keys-2.txt" "ai-keys-2" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/registry-ci.txt" "registry-ci" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/observability.txt" "observability" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/saas-keys.txt" "saas-keys" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/config-file-secrets.txt" "config-secrets" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/noseyparker.txt" "noseyparker" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/azure-keys.txt" "azure" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/service-accounts.txt" "svc-accounts" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/trufflehog.txt" "trufflehog" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/gitleaks.txt" "gitleaks" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/detect-secrets.txt" "detect-secrets" "#db6d28"
    _add_tab "$SESSION_DIR/findings/analysis/trivy.txt" "trivy" "#db6d28"
    _add_tab "$SESSION_DIR/findings/analysis/grype.txt" "grype" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/jsluice-secrets.txt" "jsluice-secrets" "#f85149"
    _add_tab "$SESSION_DIR/findings/secrets/wayback-secrets.txt" "wayback-secrets" "#d29922"
    _add_tab "$SESSION_DIR/findings/analysis/semgrep-findings.txt" "semgrep" "#f85149"
    _add_tab "$SESSION_DIR/findings/analysis/codeql-findings.txt" "codeql" "#f85149"
    _add_tab "$SESSION_DIR/findings/analysis/vulnerable-libs.txt" "vuln-libs" "#d29922"
    _add_tab "$SESSION_DIR/findings/analysis/npm-audit.txt" "npm-audit" "#d29922"
    _add_tab "$SESSION_DIR/findings/surface/app-routes.txt" "app-routes" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/surface/app-api-calls.txt" "app-api-calls" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/surface/app-storage-keys.txt" "storage-keys" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/surface/app-environments.txt" "environments" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/surface/app-repo-structure.txt" "repo-structure" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/surface/jsluice-endpoints.txt" "jsluice-endpoints" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/surface/service-worker-urls.txt" "sw-urls" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/secrets/hidden-paths.txt" "hidden-paths" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/debug-endpoints.txt" "debug-endpoints" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/graphql.txt" "graphql" "#8b949e"
    _add_tab "$SESSION_DIR/findings/secrets/websockets.txt" "websockets-src" "#8b949e"
    _add_tab "$SESSION_DIR/findings/secrets/dom-sinks.txt" "dom-sinks" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/framework-sinks.txt" "framework-sinks" "#db6d28"
    _add_tab "$SESSION_DIR/findings/secrets/postmessage-listeners.txt" "pm-listeners" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/internal-hosts.txt" "internal-hosts" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/s3-buckets.txt" "s3" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/baas-urls.txt" "baas" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/cognito-pools.txt" "cognito" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/source-maps.txt" "source-maps" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/oauth-ids.txt" "oauth-ids" "#8b949e"
    _add_tab "$SESSION_DIR/findings/secrets/sdk-configs.txt" "sdk-configs" "#d29922"
    _add_tab "$SESSION_DIR/findings/secrets/emails.txt" "emails" "#8b949e"
    _add_tab "$SESSION_DIR/findings/secrets/ip-addresses.txt" "ips" "#8b949e"
    _add_tab "$SESSION_DIR/findings/secrets/dev-comments.txt" "dev-comments" "#8b949e"
    _add_tab "$SESSION_DIR/findings/secrets/debug-flags.txt" "debug-flags" "#8b949e"
    _add_tab "$SESSION_DIR/findings/secrets/js-external-urls.txt" "external-urls" "#8b949e"
    _add_tab "$SESSION_DIR/urls/urls-inscope.txt" "urls-inscope" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/urls-all.txt" "urls-all" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/archive-waymore.txt" "archive-waymore" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/archive-gau.txt" "archive-gau" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/crawl-katana.txt" "crawl-katana" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/crawl-auth.txt" "crawl-auth" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/crawl-archive.txt" "crawl-archive" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/crawl-gospider.txt" "crawl-gospider" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/urls-json.txt" "urls-json" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/urls-artifacts.txt" "urls-artifacts" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/urls-js-candidates.txt" "js-candidates" "#58a6ff"
    _add_tab "$SESSION_DIR/hosts/httpx-raw.txt" "httpx-raw" "#58a6ff"
    _add_tab "$SESSION_DIR/subdomains/raw/subfinder.txt" "subfinder-raw" "#58a6ff"
    _add_tab "$SESSION_DIR/subdomains/raw/assetfinder.txt" "assetfinder-raw" "#58a6ff"
    _add_tab "$SESSION_DIR/subdomains/raw/findomain.txt" "findomain-raw" "#58a6ff"
    _add_tab "$SESSION_DIR/state/blind-maps-found.txt" "blind-maps" "#58a6ff"
    _add_tab "$SESSION_DIR/state/stage-log.tsv" "stage-log" "#8b949e"
    _add_tab "$SESSION_DIR/findings/probes/open-redirect-params.txt" "open-redirect-params" "#d29922"
    _add_tab "$SESSION_DIR/urls/urls-api.txt" "urls-api" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/urls-js.txt" "urls-js" "#58a6ff"
    _add_tab "$SESSION_DIR/urls/urls-auth-only.txt" "urls-auth-only" "#db6d28"
    _add_tab "$SESSION_DIR/urls/urls-revived.txt" "urls-revived" "#db6d28"
    _add_tab "$SESSION_DIR/hosts/hosts-live.txt" "hosts-live" "#58a6ff"
    _add_tab "$SESSION_DIR/findings/probes/hosts-auth-required.txt" "hosts-gated" "#d29922"
    _add_tab "$SESSION_DIR/subdomains/subdomains-final.txt" "subdomains" "#58a6ff"
    _add_tab "$SESSION_DIR/subdomains/subdomains-new-since-last.txt" "subs-new" "#d29922"
    _add_tab "$SESSION_DIR/subdomains/csp-domains.txt" "csp-domains" "#d29922"
    if [ -d "$SESSION_DIR/findings/analysis/ctx" ]; then
        : > "$SESSION_DIR/findings/analysis/context-all.txt"
        for _cf in "$SESSION_DIR/findings/analysis/ctx"/*.txt; do
            [ -s "$_cf" ] || continue
            { echo "===== $(basename "$_cf") ====="; cat "$_cf"; echo ""; } >> "$SESSION_DIR/findings/analysis/context-all.txt"
        done
    fi
    _add_tab "$SESSION_DIR/findings/analysis/context-all.txt" "context" "#f85149"
    _add_tab "$SESSION_DIR/findings/export.json" "export-json" "#58a6ff"
    local log_data=""
    [ -f "$SESSION_DIR/reconly.log" ] && log_data=$(tail -n 5000 "$SESSION_DIR/reconly.log" 2>/dev/null | sed -r 's/\x1b\[[0-9;]*m//g' | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    local log_id="console-log"
    tabs_def+="        <button class=\"tablinks\" onclick=\"openTab(event,'${log_id}')\" style=\"color:#8b949e\">console-log<span class=\"badge\">log</span></button>"$'\n'
    content_html+="    <div id=\"${log_id}\" class=\"tabcontent\" style=\"display:none;\">
      <div class=\"tab-header\"><span style=\"color:#8b949e;font-weight:bold\">console-log</span><button class=\"copy-btn\" onclick=\"copyData(this)\">Copy</button></div>
      <textarea class=\"data-box\" readonly spellcheck=\"false\">${log_data}</textarea>
    </div>"$'\n'

    cat > "$html" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>reconly v2 — $esc_domain</title>
<style>
:root{--bg:#0d1117;--bg2:#161b22;--bg3:#21262d;--fg:#c9d1d9;--fg2:#8b949e;--border:#30363d;--green:#3fb950;--red:#f85149;--orange:#db6d28;--yellow:#d29922;--blue:#58a6ff;--purple:#bc8cff}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background:var(--bg);color:var(--fg);min-height:100vh}
.header{background:var(--bg2);border-bottom:1px solid var(--border);padding:16px 24px;display:flex;justify-content:space-between;align-items:center}
.header h1{font-size:20px;font-weight:700}
.header .meta{color:var(--fg2);font-size:13px;margin-top:4px}
.header .theme-btn{background:var(--bg3);border:1px solid var(--border);color:var(--fg);padding:6px 12px;border-radius:6px;cursor:pointer;font-size:12px}
.strip{display:flex;gap:16px;padding:16px 24px;background:var(--bg2);border-bottom:1px solid var(--border);flex-wrap:wrap}
.card{background:var(--bg3);border:1px solid var(--border);border-radius:8px;padding:12px 16px;min-width:120px}
.card .num{font-size:24px;font-weight:700}
.card .lbl{font-size:11px;color:var(--fg2);text-transform:uppercase;margin-top:2px}
.card.crit .num{color:var(--red)}.card.high .num{color:var(--orange)}.card.med .num{color:var(--yellow)}.card.info .num{color:var(--blue)}
.main{display:flex;min-height:calc(100vh - 200px)}
.sidebar{width:220px;background:var(--bg2);border-right:1px solid var(--border);overflow-y:auto;padding:8px 0;flex-shrink:0}
.sidebar button{display:block;width:100%;text-align:left;background:none;border:none;border-left:3px solid transparent;color:var(--fg2);padding:8px 12px;font-size:11px;font-weight:700;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sidebar button:hover{background:var(--bg3);color:var(--fg)}
.sidebar button.active{background:var(--bg3);border-left-color:var(--green);color:#fff}
.badge{background:var(--bg3);color:var(--fg2);padding:1px 6px;border-radius:10px;font-size:10px;margin-left:4px;float:right}
.content{flex:1;padding:20px;overflow-y:auto}
.tabcontent{display:none}
.tabcontent:first-of-type{display:block}
.tab-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px}
.copy-btn{background:var(--green);color:#fff;border:none;padding:5px 12px;border-radius:4px;cursor:pointer;font-size:12px;font-weight:700}
.copy-btn:hover{opacity:.9}
.data-box{width:100%;height:calc(100vh - 320px);min-height:300px;background:#010409;color:var(--green);border:1px solid var(--border);padding:15px;font-family:'Courier New',Courier,monospace;font-size:13px;resize:vertical;outline:none;border-radius:6px}
.timeline{background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:12px;margin-bottom:16px}
.timeline h3{font-size:13px;color:var(--fg2);margin-bottom:10px;text-transform:uppercase;letter-spacing:.5px}
.tl-row{display:flex;gap:12px;padding:5px 0;border-bottom:1px solid var(--border);font-size:12px;align-items:center}
.tl-row:last-child{border-bottom:none}
.tl-icon{width:16px;flex-shrink:0}
.tl-name{width:120px;font-weight:700;flex-shrink:0}
.tl-dur{width:60px;color:var(--fg2);flex-shrink:0}
.tl-stat{flex:1;color:var(--fg2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.queue{background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:12px;margin-bottom:16px}
.queue h3{font-size:13px;color:var(--fg2);margin-bottom:10px;text-transform:uppercase;letter-spacing:.5px}
.q-row{display:flex;gap:10px;padding:6px 0;border-bottom:1px solid var(--border);font-size:12px;align-items:flex-start}
.q-row:last-child{border-bottom:none}
.q-badge{padding:2px 8px;border-radius:4px;font-size:10px;font-weight:700;color:#fff;flex-shrink:0;margin-top:1px}
.q-text{flex:1;word-break:break-all}
.search-box{width:100%;padding:10px 14px;background:var(--bg3);border:1px solid var(--border);border-radius:6px;color:var(--fg);font-size:13px;margin-bottom:12px;outline:none}
.search-box:focus{border-color:var(--blue)}
::-webkit-scrollbar{width:8px;height:8px}
::-webkit-scrollbar-track{background:var(--bg)}
::-webkit-scrollbar-thumb{background:var(--border);border-radius:4px}
body.light{--bg:#ffffff;--bg2:#f6f8fa;--bg3:#eaeef2;--fg:#1f2328;--fg2:#656d76;--border:#d1d9e0;--green:#1a7f37;--red:#d1242f;--orange:#bf6300;--yellow:#9a6700;--blue:#0969da;--purple:#8250df}
body.light .data-box{background:#f6f8fa;color:var(--fg)}
body.light .card .num{color:var(--fg)}
</style>
</head>
<body>
<div class="header">
  <div>
    <h1>reconly v2 — $esc_domain</h1>
    <div class="meta">$TIMESTAMP | $esc_session</div>
  </div>
  <button class="theme-btn" onclick="toggleTheme()">Toggle theme</button>
</div>
<div class="strip">
  <div class="card crit"><div class="num">$f_crit</div><div class="lbl">CRITICAL (pattern)</div></div>
  <div class="card high"><div class="num">$f_high</div><div class="lbl">HIGH (pattern)</div></div>
  <div class="card med"><div class="num">$f_med</div><div class="lbl">MEDIUM (pattern)</div></div>
  <div class="card crit"><div class="num">$c_all</div><div class="lbl">ACTIVE (verified)</div></div>
  <div class="card info"><div class="num">$f_total</div><div class="lbl">Findings</div></div>
  <div class="card info"><div class="num">$c_subs</div><div class="lbl">Subdomains</div></div>
  <div class="card info"><div class="num">$c_live</div><div class="lbl">Live hosts</div></div>
  <div class="card info"><div class="num">$c_urls</div><div class="lbl">URLs</div></div>
  <div class="card info"><div class="num">$c_js</div><div class="lbl">JS files</div></div>
  <div class="card info"><div class="num">$c_mapsrc</div><div class="lbl">Source files</div></div>
</div>
<div style="padding:0 24px 16px">
  <input type="text" class="search-box" id="searchBox" placeholder="Search all tabs (endpoint, filename, any string)..." onkeyup="filterTabs()">
</div>
<div class="main">
  <div class="sidebar" id="sidebar">
$tabs_def  </div>
  <div class="content">
    <div class="timeline">
      <h3>stage timeline</h3>
$timeline_html    </div>
    <div class="queue">
      <h3>attack queue</h3>
$queue_html    </div>
$content_html  </div>
</div>
<script>
function openTab(evt,id){
  window._openTab=id;
  document.querySelectorAll('.tabcontent').forEach(t=>t.style.display='none');
  document.querySelectorAll('.tablinks').forEach(t=>t.classList.remove('active'));
  document.getElementById(id).style.display='block';
  evt.currentTarget.classList.add('active');
}
function copyData(btn){
  var ta=btn.parentElement.nextElementSibling;
  ta.focus();ta.select();ta.setSelectionRange(0,99999);
  function done(){var o=btn.innerText;btn.innerText='Copied!';setTimeout(()=>btn.innerText=o,2000)}
  if(navigator.clipboard&&location.protocol!=='file:'){navigator.clipboard.writeText(ta.value).then(done).catch(()=>{try{document.execCommand('copy')}catch(e){};done()})}
  else{try{document.execCommand('copy')}catch(e){};done()}
}
function filterTabs(){
  var q=document.getElementById('searchBox').value.toLowerCase();
  document.querySelectorAll('.tabcontent').forEach(function(t){
    if(q===''){t.dataset.filtered='';t.style.display=(t.id===window._openTab)?'block':'none';var b0=t.querySelector('.data-box');if(b0&&b0.dataset.orig){b0.value=b0.dataset.orig}return}
    var txt=(t.innerText||'').toLowerCase();
    t.dataset.filtered=txt.includes(q)?'yes':'no';
    t.style.display=txt.includes(q)?'block':'none';
    if(txt.includes(q)){
      // highlight matching lines
      var box=t.querySelector('.data-box');
      if(box){
        var lines=box.value.split('\n');
        var matched=lines.filter(l=>l.toLowerCase().includes(q));
        if(matched.length>0&&matched.length<lines.length){box.value=matched.join('\n');box.dataset.orig=box.dataset.orig||lines.join('\n')}
        else if(box.dataset.orig){box.value=box.dataset.orig}
      }
    }else{
      var box2=t.querySelector('.data-box');
      if(box2&&box2.dataset.orig){box2.value=box2.dataset.orig}
    }
  });
  document.querySelectorAll('.tablinks').forEach(function(b){
    var id=b.getAttribute('onclick').match(/'([^']+)'/)[1];
    var t=document.getElementById(id);
    if(!t)return;
    if(q===''){b.style.display=''}
    else{b.style.display=t.dataset.filtered==='yes'?'':'none'}
  });
}
function toggleTheme(){document.body.classList.toggle('light')}
var _ft=document.querySelector('.tabcontent');if(_ft){window._openTab=_ft.id}
</script>
</body>
</html>
HTMLEOF
    chmod 600 "$html" 2>/dev/null || true
    stage_note "report=$html"
}
cleanup() {
    rm -rf "$SESSION_DIR/state/tmp" 2>/dev/null || true
    out "${C_W}Session state preserved at $SESSION_DIR/state${C_R}"
}
main() {
    [ -t 6 ] && clear
    local runck=""
    if [ -n "$CK_ARG" ]; then
        if [ -f "$CK_ARG" ]; then runck=" -c \"$CK_ARG\""; else runck=" -c ***"; fi
    fi

    out "${C_K}____________________________________________________________________________________${C_R}"
    out "${C_K}_____________________________ github.com/Ln0rag/reconly ____________________________${C_R}"
    out "${C_K}____________________________________________________________________________________${C_R}"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ R E C O N L Y${C_R} -d ${C_GRN}$DOMAIN${C_R}$runck"
    check_tools
    ensure_runtime_deps
    maybe_fresh_restart "$@"

    run_stage "Subdomains" st_subdomains || true
    run_stage "Archive" st_archive || true
    run_stage "Hosts" st_hosts_lite || true
    run_stage "Auth" st_auth_lite || true
    run_stage "Crawl" st_crawl || true
    run_stage "Classify" st_classify_js || true
    run_stage "js-pipeline" st_js_pipeline || true
    run_stage "Local analysis" st_analysis_local || true
    run_stage "App surface" st_app_surface || true
    run_stage "Context" st_context || true
    run_stage "Quick-probes" st_quick_probes || true
    if [ "$VERIFY_TOKENS" = "1" ]; then run_stage "Probes" st_token_verify || true; fi
    run_stage "Triage" st_triage || true
    run_stage "Report" st_report || true

    cleanup

    if [ "${NOOPEN:-0}" = "1" ]; then
        out "${C_W}Report: $SESSION_DIR/report.html${C_R}"
    elif command -v brave-browser &>/dev/null; then brave-browser --incognito "$SESSION_DIR/report.html" &>/dev/null &
    elif command -v brave &>/dev/null; then brave --incognito "$SESSION_DIR/report.html" &>/dev/null &
    elif command -v xdg-open &>/dev/null; then xdg-open "$SESSION_DIR/report.html" &>/dev/null &
    elif command -v open &>/dev/null; then open "$SESSION_DIR/report.html" &>/dev/null &
    else out "${C_Y}Report: $SESSION_DIR/report.html${C_R}"; fi

    out ""
    out "${C_GRN}reconly complete — $DOMAIN${C_R}"
    out "${C_W}Session: $SESSION_DIR${C_R}"
}

main "$@"

