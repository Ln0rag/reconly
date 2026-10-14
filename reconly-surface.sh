#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
umask 077
export LC_ALL=C
export PATH="$PATH:$HOME/go/bin"

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
KATANA_RL="${KATANA_RL:-$((RANDOM % 8 + 3))}"
RECONLY_AUTO_INSTALL="${RECONLY_AUTO_INSTALL:-1}"
RECONLY_CHECK_UPDATES="${RECONLY_CHECK_UPDATES:-1}"
JITTER_MIN=100
JITTER_MAX=300

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
    local msg="$1" plain
    plain=$(printf '%b' "$msg" | sed -r 's/\x1b\[[0-9;]*m//g')
    if [ -t 6 ]; then
        printf '%b\n' "$msg" >&6
        printf '%b\n' "$msg" >&7 2>/dev/null || true
        printf '%s\n' "$plain"
    else
        printf '%s\n' "$plain"
        { printf '%s\n' "$plain"; } 2>/dev/null >&6 || true
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
    out "${C_RED}Scan halted${C_R}"
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
            echo "Usage: reconly-surface.sh -d domain.com"
            exit 0
            ;;
        \?) echo "Invalid option"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
if [ "$#" -gt 0 ]; then
    out "${C_Y}[warn] ignoring unexpected extra argument(s): $*${C_R}"
fi

[ -z "$RAW_DOMAIN" ] && die "Missing -d domain"


DOMAIN=$(echo "$RAW_DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|^www\.||' | tr '[:upper:]' '[:lower:]')
DOMAIN_ESCAPED="${DOMAIN//./\\.}"
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
        out "${C_Y}resolvers list unavailable, dnsx will fall back to 1.1.1.1/8.8.8.8/9.9.9.9${C_R}"
    fi
fi

TOOL_LIST=(subfinder httpx katana dnsx gau amass jsluice)

declare -A TOOL_INSTALL=(
    [subfinder]='go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest'
    [amass]='go install -v github.com/owasp-amass/amass/v5/cmd/amass@main'
    [dnsx]='go install -v github.com/projectdiscovery/dnsx/cmd/dnsx@latest'
    [httpx]='go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest'
    [katana]='go install github.com/projectdiscovery/katana/cmd/katana@latest'
    [gau]='go install -v github.com/lc/gau/v2/cmd/gau@latest'
    [jsluice]='go install -v github.com/BishopFox/jsluice/cmd/jsluice@latest'
)

maybe_fresh_restart() {
    [ "${INSTALLED_ANYTHING:-0}" = "1" ] || return 0
    out ""
    out "${C_Y}one or more tools were installed during this session${C_R}"
    out "${C_Y}press Enter to restart reconly in a clean environment (recommended)${C_R}"
    if ! { read -r _ < /dev/tty; } 2>/dev/null; then
        out "  ${C_W}No interactive terminal, continuing in the current session${C_R}"
        return 0
    fi
    clear 2>/dev/null || true
    out "${C_W}re-running: $0 ${ORIG_ARGS[*]}${C_R}"
    cd "$BASE_DIR" 2>/dev/null || cd / 2>/dev/null || true
    flock -u 300 2>/dev/null || true
    rm -rf "$SESSION_DIR" 2>/dev/null || true
    exec "$0" "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
}

ensure_global_path() {
    mkdir -p "$HOME/github-tools" "$HOME/.local/bin" "$HOME/go/bin" 2>/dev/null || true
    case ":$PATH:" in *":$HOME/github-tools:"*) ;; *) export PATH="$PATH:$HOME/github-tools" ;; esac
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$PATH:$HOME/.local/bin" ;; esac
    case ":$PATH:" in *":$HOME/go/bin:"*) ;; *) export PATH="$PATH:$HOME/go/bin" ;; esac
    case ":$PATH:" in *":/usr/local/go/bin:"*) ;; *) [ -x /usr/local/go/bin/go ] && export PATH="$PATH:/usr/local/go/bin" ;; esac
    if command -v python3 >/dev/null 2>&1; then
        _ub=$(python3 -m site --user-base 2>/dev/null)
        if [ -n "$_ub" ] && [ -d "$_ub/bin" ]; then
            case ":$PATH:" in *":$_ub/bin:"*) ;; *) export PATH="$PATH:$_ub/bin" ;; esac
        fi
    fi
    local _line='export PATH="$HOME/github-tools:$HOME/.local/bin:$HOME/go/bin:$PATH"' _wrote=0 _rc
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
    if [ -z "$pp" ] && command -v python3 >/dev/null 2>&1; then
        _ub=$(python3 -m site --user-base 2>/dev/null)
        if [ -n "$_ub" ] && [ -x "$_ub/bin/$t" ]; then pp="$_ub/bin/$t"; fi
    fi
    if [ -n "$pp" ]; then printf '%s\n' "$pp"; fi
    return 0
}

ensure_go() {
    if command -v go &>/dev/null && [ -x /usr/local/go/bin/go ]; then return 0; fi
    out "  ${C_W}installing Go ...${C_R}"
    mkdir -p "$HOME/.cache" 2>/dev/null || true
    local _gv _gt _arch _cfg
    _gv=$(curl -fsSL -m 20 'https://go.dev/VERSION?m=text' 2>/dev/null | head -n1) || true
    if [ -z "$_gv" ]; then _gv="go1.22.5"; fi
    case "$(uname -m)" in
        x86_64)        _arch=amd64 ;;
        aarch64|arm64) _arch=arm64 ;;
        armv6l|armv7l) _arch=armv6l ;;
        i386|i686)     _arch=386 ;;
        *) out "  ${C_Y}[warn] unsupported arch: $(uname -m) -- go-based installs will fail${C_R}"; return 0 ;;
    esac
    _gt="${_gv}.linux-${_arch}.tar.gz"
    if curl -fsSL -m 7200 "https://go.dev/dl/${_gt}" -o "$HOME/.cache/go.tgz" 2>/dev/null \
       && [ -s "$HOME/.cache/go.tgz" ] && tar -tzf "$HOME/.cache/go.tgz" >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get remove -y golang-go 'golang-*-go' >/dev/null 2>&1 || true
        fi
        if sudo rm -rf /usr/local/go 2>/dev/null && sudo tar -C /usr/local -xzf "$HOME/.cache/go.tgz" 2>/dev/null; then
            rm -f "$HOME/.cache/go.tgz"
            export GOPATH="$HOME/go"
            export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"
            hash -r 2>/dev/null || true
            case "$(basename "$SHELL")" in
                bash) _cfg="$HOME/.bashrc" ;;
                zsh)  _cfg="$HOME/.zshrc" ;;
                *)    _cfg="$HOME/.profile" ;;
            esac
            touch "$_cfg" 2>/dev/null || true
            grep -qxF 'export GOPATH=$HOME/go' "$_cfg" 2>/dev/null || printf '%s\n' 'export GOPATH=$HOME/go' >> "$_cfg" 2>/dev/null || true
            grep -qxF 'export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"' "$_cfg" 2>/dev/null || printf '%s\n' 'export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"' >> "$_cfg" 2>/dev/null || true
            if [ "$_cfg" != "$HOME/.profile" ] && [ -f "$HOME/.profile" ]; then
                grep -qxF 'export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"' "$HOME/.profile" 2>/dev/null || printf '%s\n' 'export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"' >> "$HOME/.profile" 2>/dev/null || true
            fi
            if command -v go >/dev/null 2>&1; then
                out "${C_GRN}  Go installed -> /usr/local/go/bin/go ($(go version 2>/dev/null | awk '{print $3}'))${C_R}"
            else
                out "  ${C_Y}[warn] Go extracted but not on PATH this session${C_R}"
            fi
        else
            rm -f "$HOME/.cache/go.tgz"
            out "  ${C_Y}[warn] Go install to /usr/local failed (sudo?), go-based installs will fail${C_R}"
        fi
    else
        rm -f "$HOME/.cache/go.tgz"
        out "  ${C_Y}[warn] Go download failed, go-based installs will fail${C_R}"
    fi
    return 0
}


smoke_test() {
    local t="$1" rc=127
    for _a in -version --version version -V -h --help; do
        ( timeout 15 "$t" "$_a" >/dev/null 2>&1 ) 2>/dev/null && { rc=0; break; }
    done
    [ "${rc:-127}" -lt 126 ]
}


check_tools() {
    local _utils=(curl flock xargs openssl timeout comm split sha256sum md5sum stat)
    local _all=("${_utils[@]}" "${TOOL_LIST[@]}")

    ensure_global_path
    rm -rf "$HOME/github-tools/.versions" 2>/dev/null || true

    out ""
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
            *)
                _go=$(command -v go 2>/dev/null || true)
                [ -z "$_go" ] && [ -x /usr/local/go/bin/go ] && _go="/usr/local/go/bin/go"
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

    local _missing="" _have=0 _nm=0 _t _x _p _v _g _gsfx MISSING=""
    local -a _g_sys=() _g_go=() _g_gt=() _g_miss=()
    local -a _disp=( "${_utils[@]}" subfinder httpx katana dnsx gau amass jsluice )
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
            local _pdisp="${_p/#$HOME/\~}"
            local _line="${C_GRN}$_t${_tpad}${C_R}${C_W}$_vdisp${_vpad}${C_R}$_pdisp${_gsfx}"
            case "$_p" in
                "$HOME"/go/bin/*)       _g_go+=("$_line") ;;
                "$HOME"/github-tools/*) _g_gt+=("$_line") ;;
                *)                      _g_sys+=("$_line") ;;
            esac
        else
            _missing="$_missing $_t"
            _g_miss+=("${C_RED}$_t${C_R}")
        fi
    done
    for _l in "${_g_sys[@]+"${_g_sys[@]}"}"; do out "$_l"; done
    for _l in "${_g_go[@]+"${_g_go[@]}"}";  do out "$_l"; done
    for _l in "${_g_gt[@]+"${_g_gt[@]}"}";  do out "$_l"; done
    for _l in "${_g_miss[@]+"${_g_miss[@]}"}"; do out "$_l"; done
    for _x in $_missing; do _nm=$((_nm+1)); done

    if [ -n "$_missing" ] && [ "$RECONLY_AUTO_INSTALL" != "0" ]; then
        ensure_go
        out ""
        out "${C_W}installing $_nm missing tool(s) via official installers${C_R}"
        INSTALLED_ANYTHING=1
        out "  ${C_Y}note: go tools compile from source and downloads take time, total ~10-40 min on a fresh machine. Do NOT interrupt.${C_R}"
        for _t in $_missing; do
            hint="${TOOL_INSTALL[$_t]:-}"
            if [ -z "$hint" ]; then
                out "  ${C_Y}[warn] no official installer known for $_t${C_R}"
                continue
            fi
            out "  ${C_W}installing $_t ...${C_R}"
            out "    ${C_MAG}cmd: $hint${C_R}"
            if ( bash -c "$hint" ); then
                export PATH="$PATH:$HOME/github-tools:$HOME/.local/bin:$HOME/go/bin"
                _p=$(locate_tool "$_t")
                if [ -n "$_p" ]; then
                    _v=$(timeout --foreground 5 "$_t" --version 2>&1 | grep -oiE '[0-9]+\.[0-9]+([.][0-9]+)?' | head -1 || true)
                    [ -z "$_v" ] && _v=$(timeout --foreground 5 "$_t" version 2>&1 | grep -oiE '[0-9]+\.[0-9]+([.][0-9]+)?' | head -1 || true)
                    out "${C_GRN}  $_t installed${_v:+ v$_v} -> $_p${C_R}"
                else
                    out "  ${C_Y}[warn] $_t installer ran but produced no binary (search ~/.local/bin, ~/go/bin)${C_R}"
                fi
            else
                out "  ${C_RED}[warn] $_t install failed, REQUIRED${C_R}"
            fi
        done
        export PATH="$PATH:$HOME/github-tools:$HOME/.local/bin:$HOME/go/bin"
        _globalpaths=$(env HOME="$HOME" TERM=dumb bash -ic 'for _t in "$@"; do _pp=$(command -v "$_t" 2>/dev/null || true); printf "G:%s=%s\n" "$_t" "${_pp:-MISSING}"; done' _ $_missing 2>/dev/null || true)
        for _t in $_missing; do
            _g=$(printf '%s\n' "$_globalpaths" | awk -v k="$_t" '{n=$0; sub(/^G:/,"",n); split(n,a,"="); if(a[1]==k){v=n; sub(/^[^=]*=/,"",v); print v; exit}}')
            _p=$(locate_tool "$_t")
            if [ -n "$_p" ] && { [ -z "$_g" ] || [ "$_g" = "MISSING" ]; }; then
                out "  ${C_Y}$_t works in this run but not in a fresh terminal yet — open a new terminal (or: source ~/.profile)${C_R}"
            fi
        done
    elif [ -n "$_missing" ]; then
        out "${C_Y}RECONLY_AUTO_INSTALL=0, skipping installs (missing:$_missing)${C_R}"
    fi

    local _rc
    for _rc in "$HOME/.bashrc" "$HOME/.profile"; do
        if [ -f "$_rc" ] && ! grep -q 'github-tools' "$_rc" 2>/dev/null; then
            printf '\n#github-tools\nexport PATH="$PATH:$HOME/github-tools:$HOME/go/bin"\n' >> "$_rc"
            out "  ${C_W}PATH persistence added to $_rc (github-tools + go/bin)${C_R}"
        fi
    done
    local _gtmoved=0
    for _t in "${TOOL_LIST[@]}"; do
        _p=$(locate_tool "$_t")
        [ -z "$_p" ] && continue
        case "$_p" in
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
        out "  ${C_W}moved $_gtmoved tool(s) into ~/github-tools, single inventory folder${C_R}"
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
        out "${C_Y}installed but NOT functional:$_broken, one reinstall attempt each${C_R}"
        INSTALLED_ANYTHING=1
        for _t in $_broken; do
            hint="${TOOL_INSTALL[$_t]:-}"
            if [ -z "$hint" ]; then MISSING="$MISSING $_t"; continue; fi
            out "  ${C_W}reinstalling $_t ...${C_R}"
            out "    ${C_MAG}cmd: $hint${C_R}"
            ( bash -c "$hint" ) || true
            export PATH="$PATH:$HOME/github-tools:$HOME/.local/bin:$HOME/go/bin"
            _p=$(locate_tool "$_t")
        done
        for _t in $_broken; do
            if command -v "$_t" &>/dev/null && smoke_test "$_t"; then
                out "${C_GRN}  $_t recovered, ready${C_R}"
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
            if [ -n "$hint" ]; then
                hint=$(printf '%s' "$hint")
                out "    Install manually: ${C_W}$hint${C_R}"
            fi
        done
        exit 1
    fi
}

BASE_DIR="$HOME/reconly-surface/$DOMAIN"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
SESSION_DIR="$BASE_DIR/$TIMESTAMP"
mkdir -p "$SESSION_DIR"/{subdomains/raw,hosts,urls,findings/probes,state/tmp}
chmod 700 "$BASE_DIR" "$SESSION_DIR" 2>/dev/null || true
cd "$SESSION_DIR" || exit 1

export SESSION_DIR DOMAIN DOMAIN_ESCAPED FAKE_UA KATANA_RL JITTER_MIN JITTER_MAX

exec 6>&1

LOCK_FILE="$BASE_DIR/.lock"
exec 300>"$LOCK_FILE"
if ! flock -n 300; then
    die "Another reconly-lite run is active on $DOMAIN (lock: $LOCK_FILE). Wait or rm it."
fi

exec > >(tee -a "$SESSION_DIR/reconly.log" >/dev/null) 2>&1
exec 7>>"$SESSION_DIR/state/reconly.ansi.log"
out "${C_W}console mirror active, full output (results, progress, everything) -> $SESSION_DIR/reconly.log${C_R}"

_jitter() { sleep "$(awk -v min="$JITTER_MIN" -v max="$JITTER_MAX" 'BEGIN{srand(); print (min+rand()*(max-min))/1000}')"; }
_rotate_ua() {
    [ "${UA_ROTATE:-1}" = "1" ] || return 0
    FAKE_UA="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
    export FAKE_UA
}
url_junk_filter() {
    grep -viE '%5c|%7B%7B|/undefined/|/http_|://[^/]+/(Bun|Deno|Trident|Edge|iPhone|Node\.js|Zone\.js|\.exec)/?$'
}

export C_R C_K C_RED C_GRN C_Y C_BLU C_MAG C_CYN C_W
export -f out _jitter url_junk_filter

st_subdomains() {
    local out="$SESSION_DIR/subdomains/raw"
    mkdir -p "$out"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ subfinder${C_R} -d '$DOMAIN' -all -recursive -rl 50 -t 100 -silent | sort -u"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ amass${C_R} enum -d '$DOMAIN' -timeout 5 && ${C_RED}amass${C_R} subs -names -d '$DOMAIN'"
    timeout --foreground 900 subfinder -d "$DOMAIN" -all -recursive -rl 50 -t 100 -silent 2>"$SESSION_DIR/state/tmp/subfinder.err" | sort -u > "$out/subfinder.txt" || true &
    local _spid=$!
    if ! pgrep -f "amass engine" >/dev/null 2>&1; then
        (amass engine >/dev/null 2>&1 &)
        sleep 3
    fi
    timeout --foreground 900 amass enum -d "$DOMAIN" -timeout 5 -oA "$SESSION_DIR/state/tmp/amass_out" >/dev/null 2>"$SESSION_DIR/state/tmp/amass.err" || true &
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
        out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ permutations${C_R} env-wordlist x $_subcount labels | dnsx resolve -a -t 2000 + resolvers"
        PERM_WORDS="dev development staging stage test testing qa uat demo prod production pre preprod preview sandbox alpha beta gamma canary nightly rc live v1 v2 v3 v4 v5 old new legacy backup bak archive temp tmp migrate admin administrator panel dashboard manage management console portal cp api apis gateway service services microservice backend backoffice frontend web mobile app apps m secure ssl auth login sso oauth id account accounts user users internal external intranet corp staff employee employees partner partners client clients customer vendor reseller affiliate eu us uk ae sa eg global int mail email ftp sftp ssh vpn remote git ci cd jenkins gitlab jira confluence wiki docs help support status monitor monitoring grafana kibana logs log analytics metrics metrics2 cache cdn assets static media files download downloads upload img images video db database mysql postgres redis elastic search solr queue broker kafka rabbit nats ws websocket realtime chat bot crawler cron scheduler worker workers job jobs batch"
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
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -l subdomains-final.txt -p 80,443,8080,8443,8000,8888 -threads 200 -timeout 8 -status-code -tech-detect -title -location -ip -cname -tls-grab -websocket -favicon"
    timeout --foreground 900 httpx -silent -no-color -l "$SESSION_DIR/subdomains/subdomains-final.txt" -p 80,443,8080,8443,8000,8888 -threads 200 -timeout 8 -status-code -tech-detect -title -location -ip -cname -tls-grab -websocket -favicon 2>/dev/null | awk '!seen[$0]++' > "$SESSION_DIR/hosts/httpx-raw.txt" || true
    grep -E '^https?://' "$SESSION_DIR/hosts/httpx-raw.txt" | awk '{print $1}' | sort -u | awk '{rest=substr($0, index($0,"//")+2); if(!(rest in out) || $0 ~ /^https:/){out[rest]=$0}} END{for(k in out) print out[k]}' | sort > "$SESSION_DIR/hosts/hosts-live.txt"
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -u '$DOMAIN' -status-code -tech-detect -title -location -ip -cname"
    if ! grep -qE "^https?://${DOMAIN_ESCAPED}$" "$SESSION_DIR/hosts/hosts-live.txt" 2>/dev/null; then
        timeout --foreground 300 httpx -silent -no-color -u "$DOMAIN" -p 80,443,8080,8443,8000,8888 -status-code -tech-detect -title -location -ip -cname 2>/dev/null > "$SESSION_DIR/state/tmp/.apex.txt" || true
        grep -E '^https?://' "$SESSION_DIR/state/tmp/.apex.txt" 2>/dev/null | awk '{print $1}' >> "$SESSION_DIR/hosts/hosts-live.txt"
        sort -u "$SESSION_DIR/hosts/hosts-live.txt" -o "$SESSION_DIR/hosts/hosts-live.txt"
        rm -f "$SESSION_DIR/state/tmp/.apex.txt"
    fi
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ openssl${C_R} s_client -connect <host>:443 -servername <host> | openssl x509 -noout -text"
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
            timeout --foreground 600 httpx -silent -no-color -l "$SESSION_DIR/state/tmp/.san-new.txt" -p 80,443,8080,8443,8000,8888 -threads 200 -timeout 8 -status-code -cname 2>/dev/null | tee -a "$SESSION_DIR/hosts/httpx-raw.txt" | awk '{print $1}' >> "$SESSION_DIR/hosts/hosts-live.txt"
            sort -u "$SESSION_DIR/hosts/hosts-live.txt" -o "$SESSION_DIR/hosts/hosts-live.txt"
        fi
        rm -f "$SESSION_DIR/state/tmp/.san-scoped.txt" "$SESSION_DIR/state/tmp/.san-new.txt"
    fi
    rm -f "$SESSION_DIR/state/tmp/.tls-sans.txt"
}
st_archive() {
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} web.archive.org/cdx/search/cdx?url='$DOMAIN'&matchType=domain&fl=original&collapse=urlkey"
    curl -s -m 120 "https://web.archive.org/cdx/search/cdx?url=${DOMAIN}&matchType=domain&fl=original&collapse=urlkey&limit=100000" 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > "$SESSION_DIR/urls/archive-cdx.txt" || true
    [ -s "$SESSION_DIR/urls/archive-cdx.txt" ] && out "  wayback CDX: $(wc -l < "$SESSION_DIR/urls/archive-cdx.txt" | tr -d ' ') urls"

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ gau${C_R} --subs --threads 30 '$DOMAIN'   (capped at 180s, errors surfaced)"
    timeout --foreground 180 gau --subs --threads 30 "$DOMAIN" 2>"$SESSION_DIR/state/tmp/gau.err" | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > "$SESSION_DIR/urls/archive-gau.txt" || true
    if [ -s "$SESSION_DIR/urls/archive-gau.txt" ]; then
        out "  gau: $(wc -l < "$SESSION_DIR/urls/archive-gau.txt" | tr -d ' ') urls"
    else
        : > "$SESSION_DIR/urls/archive-gau.txt"
        out "${C_Y}[warn] gau returned 0 urls in 180s — stderr: $(tail -3 "$SESSION_DIR/state/tmp/gau.err" 2>/dev/null | tr '\n' ' | ' | cut -c1-200)${C_R}"
    fi
    rm -f "$SESSION_DIR/state/tmp/gau.err"

    {
        [ -f "$SESSION_DIR/urls/archive-cdx.txt" ] && cat "$SESSION_DIR/urls/archive-cdx.txt"
        [ -f "$SESSION_DIR/urls/archive-gau.txt" ] && cat "$SESSION_DIR/urls/archive-gau.txt"
    } | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u > "$SESSION_DIR/urls/urls-archive.txt"
}
st_crawl() {
    [ -s "$SESSION_DIR/hosts/hosts-live.txt" ] || { out "${C_Y}No live hosts, skipping crawl${C_R}"; return; }
    local katana_ef="css,png,jpg,jpeg,gif,svg,ico,webp,avif,bmp,tiff,woff,woff2,ttf,otf,eot,pdf,zip,tar,tgz,gz,bz2,xz,7z,rar,mp3,wav,ogg,m4a,mp4,webm,avi,mov,mkv"

    s200_probe() {
        local kh="$1" _d="$SESSION_DIR/state/tmp"
        local _p1="/reconly-probe-$RANDOM$RANDOM" _p2="/reconly-probe-$RANDOM$RANDOM"
        local _t1="$_d/.s2-$RANDOM-1" _t2="$_d/.s2-$RANDOM-2" _t0="$_d/.s2-$RANDOM-0"
        local _c1 _c2 _h1 _h2 _h0 _sz
        _jitter
        _c1=$(curl -s --compressed -o "$_t1" -w "%{http_code}" -m 8 -A "$FAKE_UA" "${kh}${_p1}" 2>/dev/null)
        _jitter
        _c2=$(curl -s --compressed -o "$_t2" -w "%{http_code}" -m 8 -A "$FAKE_UA" "${kh}${_p2}" 2>/dev/null)
        if [ "$_c1" = "200" ] && [ "$_c2" = "200" ]; then
            _h1=$(sha256sum "$_t1" 2>/dev/null | awk '{print $1}')
            _h2=$(sha256sum "$_t2" 2>/dev/null | awk '{print $1}')
            _sz=$(wc -c < "$_t1" 2>/dev/null | tr -d ' '); _sz=${_sz:-0}
            if [ -n "$_h1" ] && [ "$_h1" = "$_h2" ] && [ "$_sz" -gt 0 ]; then
                printf 'SOFT\t%s\th:%s:%s\n' "$kh" "${_h1:0:12}" "$_sz"
                rm -f "$_t1" "$_t2" "$_t0"
                return 0
            fi
            _jitter
            curl -s --compressed -o "$_t0" -m 8 -A "$FAKE_UA" "${kh}/" 2>/dev/null
            _h0=$(sha256sum "$_t0" 2>/dev/null | awk '{print $1}')
            if [ -n "$_h0" ] && [ "$_sz" -gt 0 ] && { [ "$_h0" = "$_h1" ] || [ "$_h0" = "$_h2" ]; }; then
                printf 'SOFT\t%s\th:%s:%s\n' "$kh" "${_h0:0:12}" "$_sz"
            else
                printf 'OK\t%s\n' "$kh"
            fi
        else
            printf 'OK\t%s\n' "$kh"
        fi
        rm -f "$_t1" "$_t2" "$_t0"
    }
    export -f s200_probe

    : > "$SESSION_DIR/urls/hosts-katana.txt"
    : > "$SESSION_DIR/findings/probes/soft-200-hosts.txt"
    cat "$SESSION_DIR/hosts/hosts-live.txt" | xargs -d '\n' -P 15 -n 1 bash -c 's200_probe "$1"' _ > "$SESSION_DIR/state/tmp/.s200-results.txt" 2>/dev/null
    while IFS=$'\t' read -r _st _host _sig; do
        [ -n "$_host" ] || continue
        if [ "$_st" = "SOFT" ]; then
            printf '%s (%s)\n' "$_host" "$_sig" >> "$SESSION_DIR/findings/probes/soft-200-hosts.txt"
        else
            printf '%s\n' "$_host" >> "$SESSION_DIR/urls/hosts-katana.txt"
        fi
    done < "$SESSION_DIR/state/tmp/.s200-results.txt"
    rm -f "$SESSION_DIR/state/tmp/.s200-results.txt"
    _s200n=$(wc -l < "$SESSION_DIR/findings/probes/soft-200-hosts.txt" 2>/dev/null | tr -d ' '); _s200n=${_s200n:-0}
    [ "$_s200n" -gt 0 ] && out "${C_Y}soft-200 catch-all detected on ${_s200n} hosts (identical random-path bodies, or 404 page identical to homepage) >> findings/probes/soft-200-hosts.txt${C_R}"

    grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/urls/urls-archive.txt" 2>/dev/null | url_junk_filter | sort -u | awk '{
        host = $0; sub(/^https?:\/\//, "", host); sub(/[\/?#].*/, "", host)
        cnt[host]++
        if (cnt[host] > 30) next
        depth = gsub(/\//, "/")
        kw = ($0 ~ /\/(api|auth|admin|account|v[0-9]+|graphql|rest|checkout|payment|users?|login|dashboard|config)/) ? 0 : 1
        printf "%d\t%s\n", (kw * 1000 + depth), $0
    }' | sort -k1,1n -k2,2 | cut -f2- > "$SESSION_DIR/state/tmp/.seeds-archive.txt"

    : > "$SESSION_DIR/state/tmp/.seeds-all.txt"
    local _hcount=0
    while IFS= read -r _kh; do
        [ -n "$_kh" ] || continue
        printf '%s/\n' "$_kh" >> "$SESSION_DIR/state/tmp/.seeds-all.txt"
        _hcount=$((_hcount+1))
    done < "$SESSION_DIR/urls/hosts-katana.txt"
    local _acap=$(( 1000 - _hcount ))
    [ "$_acap" -lt 0 ] && _acap=0
    local _afull
    _afull=$(wc -l < "$SESSION_DIR/state/tmp/.seeds-archive.txt" | tr -d ' '); _afull=${_afull:-0}
    if [ "$_afull" -gt "$_acap" ]; then
        out "  unified crawl capped: $_acap of $_afull archive seed URLs (live hosts prioritized)"
    fi
    head -n "$_acap" "$SESSION_DIR/state/tmp/.seeds-archive.txt" >> "$SESSION_DIR/state/tmp/.seeds-all.txt"

    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ katana${C_R} -u .seeds-all.txt -d 3 -c 10 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl -known-files all -fs rdn -H 'User-Agent: ***' -ef '$katana_ef'   (unified live+archive crawl, chunked) || true"
    : > "$SESSION_DIR/urls/crawl-katana.txt"
    if [ -s "$SESSION_DIR/state/tmp/.seeds-all.txt" ]; then
        split -l 200 "$SESSION_DIR/state/tmp/.seeds-all.txt" "$SESSION_DIR/state/tmp/.seedchunk-"
        local _scn=0
        for _sc in "$SESSION_DIR/state/tmp/.seedchunk-"*; do
            [ -e "$_sc" ] || continue
            _scn=$((_scn+1))
            if [ "$_scn" -gt 10 ]; then
                out "  crawl capped at 2000 seeds"
                rm -f "$SESSION_DIR/state/tmp/.seedchunk-"*
                break
            fi
            GOMEMLIMIT=2GiB nice -n 5 timeout --foreground 900 bash -c 'ulimit -v 4194304 2>/dev/null || true; exec "$@"' _ katana -u "$_sc" -d 3 -c 10 -rl "$KATANA_RL" -silent -iqp ${KATANA_HEADLESS:+--headless} -js-crawl -known-files all -fs rdn -H "User-Agent: $FAKE_UA" -ef "$katana_ef" 2>/dev/null | awk '!seen[$0]++' >> "$SESSION_DIR/urls/crawl-katana.txt" || true
            rm -f "$_sc"
        done
    fi
    rm -f "$SESSION_DIR/state/tmp/.seeds-archive.txt" "$SESSION_DIR/state/tmp/.seeds-all.txt"

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
    comm -23 "$SESSION_DIR/urls/urls-all.txt" "$SESSION_DIR/urls/urls-inscope.txt" > "$SESSION_DIR/findings/probes/urls-outofscope.txt"
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

st_jsendpoints() {
    local _jslist="$SESSION_DIR/urls/urls-js.txt"
    [ -s "$_jslist" ] || { out "${C_Y}No JS URLs discovered, skipping JS endpoint mining${C_R}"; return; }
    command -v jsluice >/dev/null 2>&1 || { out "${C_Y}[warn] jsluice not found, skipping JS endpoint mining${C_R}"; return; }
    local _jdir="$SESSION_DIR/js"
    mkdir -p "$_jdir"
    : > "$SESSION_DIR/state/tmp/.jsmap"
    local _n
    _n=$(wc -l < "$_jslist" | tr -d ' '); _n=${_n:-0}
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ curl${C_R} -s -A '***' <js urls> + ${C_RED}prettier${C_R} --parser babel --write + ${C_RED}jsluice${C_R} urls -R <base>   ($_n JS urls, xargs -P 3, 2MB cap, content-filtered, cleaned copy kept in js/) || true"
    cat "$_jslist" | xargs -d '\n' -P 3 -n 1 bash -c '
        u="$1"; d="'"$SESSION_DIR"'"
        h=$(printf "%s" "$u" | md5sum | cut -c1-16)
        safe=$(printf "%s" "$u" | sed -e "s|^https*://||" -e "s/[^A-Za-z0-9.]/_/g" -e "s/__*/_/g" | cut -c1-50)
        printf "%s|%s\n" "$h" "$u" >> "$d/state/tmp/.jsmap"
        f="$d/js/${safe}-${h}.js"
        [ -s "$f" ] && exit 0
        _jitter
        curl -s -f -k -L --compressed -m 20 --connect-timeout 6 --max-filesize 2097152 -A "$FAKE_UA" "$u" -o "$f" 2>/dev/null || rm -f "$f"
    ' _

    find "$_jdir" -name '*.js' -type f -size -100c -delete 2>/dev/null || true
    for _vf in "$_jdir"/*.js; do
        [ -e "$_vf" ] || continue
        if head -c 300 "$_vf" 2>/dev/null | grep -qiE '^\s*<!doctype html|^\s*<html'; then
            rm -f "$_vf"
        fi
    done

    find "$_jdir" -name '*.js' -type f -print0 2>/dev/null | xargs -0 md5sum 2>/dev/null | sort -k1,1 | awk 'seen[$1]++ {print $2}' | while IFS= read -r _df; do rm -f "$_df"; done

    local _pj
    _pj=$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)
    _pj=$(( _pj * 7 / 10 )); [ "$_pj" -lt 1 ] && _pj=1; [ "$_pj" -gt 8 ] && _pj=8
    if command -v npx >/dev/null 2>&1; then
        out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ prettier${C_R} --parser babel --write js/*.js   (in-place clean, xargs -P $_pj, files >= 2KB only)"
        find "$_jdir" -name '*.js' -type f -size +2048c -print0 2>/dev/null | xargs -0 -r -n 5 -P "$_pj" nice -n 15 timeout 90 npx prettier --parser babel --write >/dev/null 2>&1 || true
    fi

    : > "$SESSION_DIR/state/tmp/.js-ep.txt"
    local _f _base
    for _f in "$_jdir"/*.js; do
        [ -e "$_f" ] || continue
        _base=$(awk -F'|' -v h="$(basename "$_f" | sed 's/.*-\([0-9a-f]\{16\}\)\.js$/\1/')" '$1==h{print $2; exit}' "$SESSION_DIR/state/tmp/.jsmap" 2>/dev/null)
        [ -z "$_base" ] && _base="https://$DOMAIN/"
        jsluice urls -R "$_base" "$_f" 2>/dev/null | sed -n 's/.*"url"[ ]*:[ ]*"\([^"]*\)".*/\1/p'
    done | tr -d '\r' | awk 'NF' | sort -u | url_junk_filter | grep -E '^https?://' > "$SESSION_DIR/state/tmp/.js-ep.txt" || true

    grep -E "^https?://([a-zA-Z0-9_-]+\.)*${DOMAIN_ESCAPED}(:[0-9]+)?(/|$)" "$SESSION_DIR/state/tmp/.js-ep.txt" | sort -u > "$SESSION_DIR/urls/js-endpoints.txt"
    rm -f "$SESSION_DIR/state/tmp/.js-ep.txt" "$SESSION_DIR/state/tmp/.jsmap"

    local _new _nf _mb
    _new=$(wc -l < "$SESSION_DIR/urls/js-endpoints.txt" | tr -d ' '); _new=${_new:-0}
    _nf=$(find "$_jdir" -name '*.js' -type f 2>/dev/null | wc -l | tr -d ' '); _nf=${_nf:-0}
    _mb=$(find "$_jdir" -name '*.js' -type f -exec wc -c {} + 2>/dev/null | awk 'END{printf "%.1f", $1/1048576}')
    out "${C_W}JS mining: $_new endpoints from $_nf cleaned files (${_mb:-0} MB kept in js/) -> urls/js-endpoints.txt${C_R}"
    if [ "$_new" -gt 0 ]; then
        cat "$SESSION_DIR/urls/urls-inscope.txt" "$SESSION_DIR/urls/js-endpoints.txt" | sort -u > "$SESSION_DIR/state/tmp/.inscope2.txt" && mv "$SESSION_DIR/state/tmp/.inscope2.txt" "$SESSION_DIR/urls/urls-inscope.txt"
        cat "$SESSION_DIR/urls/urls-api.txt" "$SESSION_DIR/urls/js-endpoints.txt" 2>/dev/null | grep -E '\b(api|v[0-9]+|graphql|rest|endpoint|ajax)\b' | grep -E -v '\.(css|js|png|jpe?g|gif|svg|ico|webp|woff2?|ttf|map|xml|pdf|zip)(\?|$)' | sort -u > "$SESSION_DIR/state/tmp/.api2.txt" && mv "$SESSION_DIR/state/tmp/.api2.txt" "$SESSION_DIR/urls/urls-api.txt"
    fi
}

st_export() {
    [ -s "$SESSION_DIR/urls/urls-inscope.txt" ] || { out "${C_Y}No in-scope URLs, nothing to export${C_R}"; return; }
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ awk${C_R} 'split urls-inscope.txt by host' > urls/endpoints-for-burp.txt + endpoints/by-host/*.txt"
    cp "$SESSION_DIR/urls/urls-inscope.txt" "$SESSION_DIR/urls/endpoints-for-burp.txt"
    mkdir -p "$SESSION_DIR/endpoints/by-host"
    awk -v dir="$SESSION_DIR/endpoints/by-host" '{
        u=$0
        host=u; sub(/^https?:\/\//,"",host); sub(/[\/?#].*/,"",host); gsub(/:[0-9]+$/,"",host)
        fn=host; gsub(/[^A-Za-z0-9.-]/,"_",fn)
        if (fn == "") fn = "unknown"
        if (fn != prev && prev != "") close(dir "/" prev ".txt")
        print u >> (dir "/" fn ".txt")
        prev=fn
    } END { if (prev != "") close(dir "/" prev ".txt") }' "$SESSION_DIR/urls/urls-inscope.txt"
    local _nh _nu
    _nh=$(find "$SESSION_DIR/endpoints/by-host" -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
    _nu=$(wc -l < "$SESSION_DIR/urls/endpoints-for-burp.txt" | tr -d ' ')
    out "${C_W}export: endpoints-for-burp.txt ($_nu urls) + by-host/ (${_nh:-0} host files)${C_R}"
}

st_enrich() {
    local _in="$SESSION_DIR/urls/urls-inscope.txt"
    [ -s "$_in" ] || { out "${C_Y}No in-scope URLs, skipping enrichment${C_R}"; return; }
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ httpx${C_R} -l urls-inscope.txt -json -threads 200 -timeout 10 -rl 50 -fr -status-code -title -tech-detect -content-type -content-length -location -web-server >> urls/endpoints.jsonl"
    : > "$SESSION_DIR/urls/endpoints.jsonl"
    timeout --foreground 1800 httpx -silent -no-color -l "$_in" -threads 200 -timeout 10 -rl 50 -json -fr -status-code -title -tech-detect -content-type -content-length -location -web-server 2>/dev/null | awk 'NF' >> "$SESSION_DIR/urls/endpoints.jsonl" || true
    local _n
    _n=$(wc -l < "$SESSION_DIR/urls/endpoints.jsonl" | tr -d ' '); _n=${_n:-0}
    out "${C_W}endpoints enriched: $_n -> urls/endpoints.jsonl${C_R}"
}

generate_report() {
    local _jsonl="$SESSION_DIR/urls/endpoints.jsonl"
    [ -s "$_jsonl" ] || return 1
    local _tsv
    _tsv=$(mktemp) || return 1
    awk '
      function getstr(line, key,   re, st, e, c) {
          re = "\"" key "\"[ ]*:[ ]*\""
          if (match(line, re)) {
              st = RSTART + RLENGTH; e = st
              while (e <= length(line)) {
                  c = substr(line, e, 1)
                  if (c == "\\") { e += 2; continue }
                  if (c == "\"") break
                  e++
              }
              return substr(line, st, e - st)
          }
          return ""
      }
      function getnum(line, key,   t) {
          if (match(line, "\"" key "\"[ ]*:[ ]*[0-9]+")) {
              t = substr(line, RSTART, RLENGTH)
              match(t, /[0-9]+/)
              return substr(t, RSTART, RLENGTH)
          }
          return ""
      }
      function getarr(line, key,   rest, outv, mm, rb) {
          outv = ""
          if (match(line, "\"" key "\"[ ]*:[ ]*\\[")) {
              rest = substr(line, RSTART + RLENGTH)
              rb = index(rest, "]")
              if (rb > 0) rest = substr(rest, 1, rb - 1)
              while (match(rest, /"[^"]*"/)) {
                  mm = substr(rest, RSTART + 1, RLENGTH - 2)
                  outv = (outv == "") ? mm : outv ", " mm
                  rest = substr(rest, RSTART + RLENGTH)
              }
          }
          return outv
      }
      function esc(v) { gsub(/&/, "\\&amp;", v); gsub(/</, "\\&lt;", v); gsub(/>/, "\\&gt;", v); return v }
      NF {
          u = getstr($0, "url")
          if (u == "") next
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", getnum($0, "status_code"), esc(u), esc(getstr($0, "title")), esc(getarr($0, "tech")), esc(getstr($0, "content_type")), getnum($0, "content_length"), esc(getstr($0, "webserver"))
      }
    ' "$_jsonl" | sort -k1,1n -k2,2 > "$_tsv" 2>/dev/null
    [ -s "$_tsv" ] || { rm -f "$_tsv"; return 1; }
    local _total
    _total=$(wc -l < "$_tsv" | tr -d ' ')
    {
        awk -v domain="$DOMAIN" -v runpath="$SESSION_DIR" -v gen="$(date +"%Y-%m-%d %H:%M:%S")" -v total="$_total" '
          BEGIN {
              print "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\">"
              print "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
              print "<title>reconly-surface :: " domain "</title><style>"
              print "body{background:#1f1f1f;color:#f2f2f2;font-family:\"JetBrains Mono\",monospace;font-size:13px;margin:0;padding:28px;}"
              print "h1{font-size:18px;color:#ff4552;margin:0 0 4px;letter-spacing:.5px;}"
              print "h2{font-size:14px;color:#ff4552;margin:22px 0 8px;letter-spacing:.5px;}"
              print ".meta{color:#9c9c9c;font-size:11.5px;margin-bottom:12px;}"
              print "details{margin:4px 0;}"
              print "summary{cursor:pointer;color:#f2f2f2;padding:4px 8px;background:#272727;border:1px solid #3a3a3a;border-radius:6px;}"
              print "summary b{color:#e3b341;}"
              print "pre{margin:6px 0 12px 14px;padding:10px;background:#232323;border:1px solid #2e2e2e;border-radius:6px;overflow-x:auto;color:#9c9c9c;font-size:12px;line-height:1.5;}"
              print "table{width:100%;border-collapse:collapse;}"
              print "th{position:sticky;top:0;background:#272727;color:#ff4552;text-align:left;padding:8px 10px;border-bottom:2px solid #3a3a3a;font-size:11.5px;letter-spacing:.5px;}"
              print "td{padding:6px 10px;border-bottom:1px solid #2e2e2e;vertical-align:top;word-break:break-all;}"
              print "tr:hover td{background:#272727;}"
              print "a{color:#4e9bff;text-decoration:none;}"
              print ".s2{color:#56d364}.s3{color:#e3b341}.s4{color:#e3b341}.s5{color:#ff5f6d}.s0{color:#9c9c9c}"
              print ".dim{color:#9c9c9c;font-size:11.5px;}"
              print "</style></head><body>"
              print "<h1>reconly-surface :: " domain "</h1>"
              print "<div class=\"meta\">" total " endpoints &nbsp;|&nbsp; " runpath " &nbsp;|&nbsp; " gen "</div>"
              print "<div class=\"meta\">Burp: Target &rarr; Import URLs &rarr; <code>urls/endpoints-for-burp.txt</code> &nbsp;|&nbsp; terminal: <code>endpoints/by-host/&lt;host&gt;.txt</code></div>"
              print "<h2>domain hierarchy</h2>"
          }' /dev/null
        awk '
          function esc(v){gsub(/&/,"\\&amp;",v); gsub(/</,"\\&lt;",v); gsub(/>/,"\\&gt;",v); return v}
          {
              u=$0
              host=u; sub(/^https?:\/\//,"",host); sub(/[\/?#].*/,"",host); gsub(/:[0-9]+$/,"",host)
              rest=u; sub(/^https?:\/\/[^\/]+/,"",rest); if(rest=="")rest="/"
              n=split(rest,P,"/"); ind=""
              for(i=2;i<=n;i++){ if(P[i]=="")continue; ind=ind "  " }
              H[host]=H[host] ind esc(rest) "\n"
              C[host]++
              if(!(host in S)){S[host]=1; O[++nh]=host}
          }
          END{
              for(i=1;i<=nh;i++){ h=O[i]
                  printf "<details><summary><b>%s</b> (%d urls)</summary><pre>%s</pre></details>\n", esc(h), C[h], H[h]
              }
          }' "$SESSION_DIR/urls/urls-inscope.txt" 2>/dev/null
        awk 'BEGIN{print "<h2>endpoints</h2>"; print "<table><thead><tr><th>status</th><th>url</th><th>title</th><th>tech</th><th>content-type</th><th>size</th></tr></thead><tbody>"}' /dev/null
        awk '
          BEGIN { FS = "\t" }
          {
              cls = "s0"
              if ($1 ~ /^2/) cls = "s2"
              else if ($1 ~ /^3/) cls = "s3"
              else if ($1 ~ /^4/) cls = "s4"
              else if ($1 ~ /^5/) cls = "s5"
              printf "<tr><td class=\"%s\">%s</td><td><a href=\"%s\" target=\"_blank\" rel=\"noopener\">%s</a></td><td>%s</td><td class=\"dim\">%s</td><td class=\"dim\">%s</td><td class=\"dim\">%s</td></tr>\n", cls, $1, $2, $2, $3, $4, $5, $6
          }' "$_tsv"
        awk 'END{print "</tbody></table></body></html>"}' /dev/null
    } > "$SESSION_DIR/report.html" 2>/dev/null || { rm -f "$_tsv"; return 1; }
    rm -f "$_tsv"
}
cleanup()
 {
    rm -rf "$SESSION_DIR/state/tmp" 2>/dev/null || true
    out "${C_W}Session state preserved at $SESSION_DIR/state${C_R}"
}
main() {
    if [ -t 6 ]; then
        clear >&6 2>/dev/null || true
    fi
    out "${C_MAG}[ $(date +"%I:%M:%S %p") ]${C_R}${C_RED} [~]$ R E C O N L Y - S U R F A C E${C_R} -d ${C_GRN}$DOMAIN${C_R}"
    out ""
    out "Session: $SESSION_DIR"
    check_tools
    maybe_fresh_restart "$@"

    run_stage "Subdomains" st_subdomains || true
    run_stage "Hosts & Port scanning" st_hosts_lite || true
    run_stage "Archive" st_archive || true
    run_stage "Crawl" st_crawl || true
    run_stage "Classify" st_classify_js || true
    run_stage "JS-endpoints" st_jsendpoints || true
    run_stage "Export" st_export || true
    run_stage "Enrich" st_enrich || true

    cleanup

    out ""
    out "${C_W}$SESSION_DIR/${C_R}"
    (
        cd "$SESSION_DIR" 2>/dev/null || exit 0
        find . -type d 2>/dev/null | LC_ALL=C sort | while IFS= read -r _td; do
            [ "$_td" = "." ] && continue
            _tf=$(find "$_td" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
            _ti=$(awk -v p="${_td#./}" 'BEGIN{n=split(p,a,"/"); for(i=2;i<=n;i++) printf "  "; printf "|_ "}')
            out "${_ti}${C_W}${_td##*/}/${C_R} ${C_K}(${_tf} files)${C_R}"
        done
    ) || true
    if generate_report; then
        out "${C_CYN}Report: $SESSION_DIR/report.html${C_R}"
    else
        out "${C_Y}[warn] report generation failed${C_R}"
    fi
    out "${C_GRN}reconly-surface done${C_R}"

}
main "$@"
exit 0
