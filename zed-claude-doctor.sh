#!/usr/bin/env bash
# zed-claude-doctor.sh
# Diagnose (and optionally fix) Zed's Claude Code / claude-agent-sdk setup on Linux.
#
# Usage:
#   ./zed-claude-doctor.sh              # run checks, report only
#   ./zed-claude-doctor.sh --fix        # run checks and apply fixes
#   ./zed-claude-doctor.sh --fix --yes  # apply fixes without confirmation prompts
#   ./zed-claude-doctor.sh --verbose    # show extra detail

set -u  # treat unset variables as errors; do NOT set -e, we want to keep going on check failures

# ------------------------------------------------------------------ options --
FIX=0
ASSUME_YES=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --fix) FIX=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --verbose|-v) VERBOSE=1 ;;
        --help|-h)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------- ui ----
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_DIM=''; C_BLD=''; C_RST=''
fi

pass()  { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
warn()  { printf '  %s!%s %s\n' "$C_YLW" "$C_RST" "$*"; WARN_COUNT=$((WARN_COUNT+1)); }
fail()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
info()  { printf '  %s•%s %s\n' "$C_BLU" "$C_RST" "$*"; }
note()  { (( VERBOSE )) && printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RST"; }
hdr()   { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_RST"; }

PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0
declare -a FIX_ACTIONS=()   # human descriptions
declare -a FIX_COMMANDS=()  # commands to run, 1:1 with FIX_ACTIONS

queue_fix() {
    local desc="$1"; shift
    local cmd="$*"
    FIX_ACTIONS+=("$desc")
    FIX_COMMANDS+=("$cmd")
}

confirm() {
    (( ASSUME_YES )) && return 0
    local prompt="${1:-Proceed?} [y/N] "
    read -r -p "$prompt" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------- discovery --
ZED_DATA="$HOME/.local/share/zed"
ZED_CONFIG="$HOME/.config/zed"
ZED_SETTINGS="$ZED_CONFIG/settings.json"

# Find Zed's bundled node (newest version wins if multiple)
ZED_NODE_DIR=""
ZED_NPM=""
ZED_NODE_BIN=""
if [[ -d "$ZED_DATA/node" ]]; then
    ZED_NODE_DIR=$(find "$ZED_DATA/node" -maxdepth 1 -type d -name 'node-v*-linux-x64' 2>/dev/null \
        | sort -V | tail -n 1)
    if [[ -n "$ZED_NODE_DIR" ]]; then
        ZED_NODE_BIN="$ZED_NODE_DIR/bin/node"
        ZED_NPM="$ZED_NODE_DIR/bin/npm"
    fi
fi

# -------------------------------------------------------------- checks ------
hdr "Environment"

ARCH=$(uname -m)
OS=$(uname -s)
info "Host: $OS $ARCH"
if [[ "$OS" != "Linux" ]]; then
    warn "This script targets Linux; some checks may not apply on $OS."
fi
if [[ "$ARCH" != "x86_64" ]]; then
    warn "Architecture is $ARCH; this script patches the linux-x64 native binary."
fi

hdr "Zed installation"

ZED_BIN=$(command -v zed 2>/dev/null || true)
if [[ -n "$ZED_BIN" ]]; then
    pass "Zed CLI found: $ZED_BIN"
    note "$("$ZED_BIN" --version 2>/dev/null || echo 'version unknown')"
else
    warn "'zed' not in PATH (Zed may still be installed as a .desktop app or flatpak)"
fi

if [[ -d "$ZED_DATA" ]]; then
    pass "Zed data directory exists: $ZED_DATA"
else
    fail "Zed data directory missing: $ZED_DATA"
    echo
    echo "Install Zed first: https://zed.dev/download"
    exit 1
fi

if [[ -d "$ZED_CONFIG" ]]; then
    pass "Zed config directory exists: $ZED_CONFIG"
else
    warn "Zed config directory missing: $ZED_CONFIG (will be created on first launch)"
fi

hdr "Zed bundled Node.js"

if [[ -n "$ZED_NODE_DIR" && -x "$ZED_NODE_BIN" && -x "$ZED_NPM" ]]; then
    pass "Zed Node: $ZED_NODE_DIR"
    note "node: $("$ZED_NODE_BIN" --version)"
    note "npm:  $("$ZED_NPM" --version)"
else
    fail "Zed's bundled Node.js not found under $ZED_DATA/node/"
    echo
    echo "Launch Zed once so it provisions its Node, then rerun this script."
    exit 1
fi

# Check npm config for --omit=optional (root cause of the whole mess)
hdr "npm configuration (Zed's npm)"
NPM_OMIT=$("$ZED_NPM" config get omit 2>/dev/null || echo "")
if [[ -z "$NPM_OMIT" || "$NPM_OMIT" == "undefined" || "$NPM_OMIT" == "null" ]]; then
    pass "npm 'omit' is not set"
elif [[ "$NPM_OMIT" == *optional* ]]; then
    fail "npm is configured with omit=optional — this strips native binaries"
    queue_fix \
        "Unset npm 'omit=optional' for Zed's npm" \
        "\"$ZED_NPM\" config delete omit"
else
    pass "npm 'omit' = $NPM_OMIT (not optional)"
fi

hdr "Zed settings.json"

if [[ -f "$ZED_SETTINGS" ]]; then
    pass "Settings file exists"
    # Cheap sanity: strip // line comments and try to parse with node (available via Zed Node)
    if "$ZED_NODE_BIN" -e "
        const fs=require('fs');
        let s=fs.readFileSync('$ZED_SETTINGS','utf8');
        s=s.replace(/^\s*\/\/.*$/gm,'');
        try { JSON.parse(s); process.exit(0); }
        catch(e){ console.error(e.message); process.exit(1); }
    " 2>/dev/null; then
        pass "Settings JSON is parseable"
    else
        warn "Settings JSON could not be parsed (may use JSONC; Zed tolerates comments)"
    fi

    # Look for a plaintext GitHub token — common foot-gun
    if grep -qE '"ghp_[A-Za-z0-9]{30,}"|"github_pat_[A-Za-z0-9_]{40,}"' "$ZED_SETTINGS" 2>/dev/null; then
        fail "A GitHub personal access token appears to be stored IN PLAINTEXT in settings.json"
        echo "    Revoke it now: https://github.com/settings/tokens"
        echo "    Then use an environment variable or a credential helper instead."
    fi
else
    warn "No settings.json yet (Zed hasn't been configured)"
fi

# Look for the claude-acp agent config block
if [[ -f "$ZED_SETTINGS" ]] && grep -q '"claude-acp"' "$ZED_SETTINGS"; then
    pass "Zed 'claude-acp' agent is configured"
else
    info "No 'claude-acp' agent block found in settings.json (optional)"
fi

hdr "Claude Code CLI (@anthropic-ai/claude-code)"

CC_DIR="$ZED_NODE_DIR/lib/node_modules/@anthropic-ai/claude-code"
CC_BIN="$ZED_NODE_DIR/bin/claude"

if [[ -d "$CC_DIR" ]]; then
    pass "claude-code package installed at: $CC_DIR"
    if [[ -x "$CC_BIN" ]]; then
        CC_VERSION=$("$CC_BIN" --version 2>/dev/null || echo "unknown")
        pass "claude CLI runs: $CC_VERSION"
    else
        warn "claude-code installed but no 'claude' binary at $CC_BIN"
    fi
else
    warn "@anthropic-ai/claude-code not installed in Zed's Node"
    queue_fix \
        "Install @anthropic-ai/claude-code globally into Zed's Node" \
        "\"$ZED_NPM\" install -g @anthropic-ai/claude-code --include=optional"
fi

# ------------------------------------------------------------ SDK scan ------
hdr "Scanning every @anthropic-ai/claude-agent-sdk install"

# Find every claude-agent-sdk directory under Zed, and for each, confirm that
# a sibling claude-agent-sdk-linux-x64 exists in the SAME @anthropic-ai folder.
# Prune big, irrelevant subtrees up front to keep the scan quick. NOTE: do NOT
# prune node/cache/_npx — that's exactly where Zed's registry agent runs from,
# so those installs MUST be checked and patched.
mapfile -t SDK_DIRS < <(find "$ZED_DATA" \
    \( -type d \( \
        -path "$ZED_DATA/logs" -o \
        -path "$ZED_DATA/languages" -o \
        -path "$ZED_DATA/extensions/work" -o \
        -name '.git' \
    \) -prune \) -o \
    -type d -name 'claude-agent-sdk' -print 2>/dev/null)

if (( ${#SDK_DIRS[@]} == 0 )); then
    info "No claude-agent-sdk installs found — nothing to patch here"
else
    echo "  Found ${#SDK_DIRS[@]} install(s):"
    for sdk in "${SDK_DIRS[@]}"; do
        parent=$(dirname "$sdk")  # this is the @anthropic-ai dir
        pkg_root=$(dirname "$(dirname "$parent")")  # the package that owns this node_modules

        if [[ -d "$parent/claude-agent-sdk-linux-x64" ]]; then
            pass "OK  $sdk"
        else
            fail "MISSING linux-x64 sibling next to: $sdk"
            queue_fix \
                "Install missing native binary into $pkg_root" \
                "cd \"$pkg_root\" && \"$ZED_NPM\" install @anthropic-ai/claude-agent-sdk-linux-x64 --no-save"
        fi
    done
fi

# ---------------------------------------------------------- external_agents --
hdr "Zed external_agents/"

EXT_DIR="$ZED_DATA/external_agents"
if [[ -d "$EXT_DIR" ]]; then
    mapfile -t EXT_SUBDIRS < <(find "$EXT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    if (( ${#EXT_SUBDIRS[@]} == 0 )); then
        info "external_agents/ exists but is empty"
    else
        for d in "${EXT_SUBDIRS[@]}"; do
            info "agent: $(basename "$d")"
        done
    fi

    # Heads-up if Zed is using the registry/npx pattern — this re-breaks on version bumps
    if [[ -d "$EXT_DIR/registry/npx/claude-acp" ]]; then
        warn "Zed is running the Claude agent via npx from a cache dir."
        echo "    This means every version bump will create a new broken install."
        echo "    For a durable fix, install @agentclientprotocol/claude-agent-acp globally"
        echo "    into Zed's Node and point settings.json at it directly:"
        echo
        echo "      \"agent_servers\": {"
        echo "        \"claude-acp\": {"
        echo "          \"command\": \"$ZED_NODE_DIR/bin/claude-agent-acp\","
        echo "          \"args\": []"
        echo "        }"
        echo "      }"
    fi
else
    info "No external_agents directory yet"
fi

# -------------------------------------------------------------- summary ----
hdr "Summary"
printf "  %s%d passed%s    %s%d warnings%s    %s%d failed%s\n" \
    "$C_GRN" "$PASS_COUNT" "$C_RST" \
    "$C_YLW" "$WARN_COUNT" "$C_RST" \
    "$C_RED" "$FAIL_COUNT" "$C_RST"

if (( ${#FIX_ACTIONS[@]} == 0 )); then
    echo
    echo "${C_GRN}Nothing to fix. If Zed still errors, restart it fully and retry.${C_RST}"
    exit 0
fi

echo
echo "${C_BLD}Proposed fixes:${C_RST}"
for i in "${!FIX_ACTIONS[@]}"; do
    printf "  %2d. %s\n" "$((i+1))" "${FIX_ACTIONS[$i]}"
    printf "      %s\$%s %s\n" "$C_DIM" "$C_RST" "${FIX_COMMANDS[$i]}"
done

if (( ! FIX )); then
    echo
    echo "Re-run with ${C_BLD}--fix${C_RST} to apply these (add ${C_BLD}--yes${C_RST} to skip prompts)."
    exit 1
fi

# --------------------------------------------------------------- apply ------
hdr "Applying fixes"

applied=0; failed=0
for i in "${!FIX_ACTIONS[@]}"; do
    desc="${FIX_ACTIONS[$i]}"
    cmd="${FIX_COMMANDS[$i]}"
    echo
    echo "${C_BLD}[$((i+1))/${#FIX_ACTIONS[@]}] $desc${C_RST}"
    echo "    ${C_DIM}\$ $cmd${C_RST}"
    if confirm "    Run this?"; then
        if bash -c "$cmd"; then
            pass "done"
            applied=$((applied+1))
        else
            fail "command exited non-zero"
            failed=$((failed+1))
        fi
    else
        info "skipped"
    fi
done

echo
echo "Applied: $applied    Failed: $failed    Skipped: $(( ${#FIX_ACTIONS[@]} - applied - failed ))"
echo
echo "Restart Zed and retry the agent. If the error returns, re-run this script —"
echo "Zed occasionally re-syncs agents and re-introduces the broken install."
