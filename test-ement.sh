#!/usr/bin/env bash
# test-ement.sh — Launch Emacs with ement.el (enhancements branch) for testing
#
# Usage:
#   ./test-ement.sh                  # Interactive Emacs with ement loaded
#   ./test-ement.sh --batch-test     # Run ERT tests in batch mode
#   ./test-ement.sh --lint           # Byte-compile to check for warnings
#   ./test-ement.sh --connect        # Launch and auto-connect (prompts for creds)
#   ./test-ement.sh --clean          # Wipe sandbox and re-install deps
#
# The script uses an isolated sandbox directory so your regular Emacs
# config is untouched.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX="${SCRIPT_DIR}/.sandbox"
DEPS_DIR="${SANDBOX}/elpa"
LOG_DIR="${SANDBOX}/logs"
LOG_FILE="${LOG_DIR}/ement-$(date +%Y%m%d-%H%M%S).log"
EMACS="${EMACS:-emacs}"

# ── Colors ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }

# ── Preflight ──────────────────────────────────────────────────────────
check_emacs() {
    if ! command -v "$EMACS" &>/dev/null; then
        err "Emacs not found. Set EMACS= to override."
        exit 1
    fi
    local ver
    ver=$("$EMACS" --version | head -1)
    info "Using: $ver"
    info "Binary: $(command -v "$EMACS")"
}

# ── Sandbox / dependency installation ──────────────────────────────────
install_deps() {
    if [[ -d "$DEPS_DIR" ]] && [[ -z "${FORCE_CLEAN:-}" ]]; then
        info "Sandbox exists at $DEPS_DIR (use --clean to rebuild)"
        return
    fi

    info "Installing dependencies into sandbox..."
    mkdir -p "$DEPS_DIR" "$LOG_DIR"

    "$EMACS" --batch \
        --eval "(setq package-user-dir \"$DEPS_DIR\")" \
        --eval "(require 'package)" \
        --eval "(setq package-archives
                  '((\"gnu\"   . \"https://elpa.gnu.org/packages/\")
                    (\"nongnu\" . \"https://elpa.nongnu.org/nongnu/\")
                    (\"melpa\" . \"https://melpa.org/packages/\")))" \
        --eval "(package-initialize)" \
        --eval "(package-refresh-contents)" \
        --eval "(dolist (pkg '(plz taxy taxy-magit-section svg-lib transient persist map))
                  (unless (package-installed-p pkg)
                    (package-install pkg)))" \
        2>&1 | tee "${LOG_DIR}/install-deps.log"

    ok "Dependencies installed."
}

# ── Build the common --eval preamble shared by every invocation ────────
emacs_load_args() {
    cat <<'ELISP'
(progn
  ;; Isolate from user config.
  (setq user-emacs-directory "__SANDBOX__/")
  (setq package-user-dir    "__DEPS_DIR__/")

  ;; Package setup.
  (require 'package)
  (setq package-archives
        '(("gnu"   . "https://elpa.gnu.org/packages/")
          ("nongnu" . "https://elpa.nongnu.org/nongnu/")
          ("melpa"  . "https://melpa.org/packages/")))
  (package-initialize)

  ;; Load ement from the working tree (not from ELPA).
  (add-to-list 'load-path "__SCRIPT_DIR__/")

  ;; ─── Logging / monitoring ───────────────────────────────────────
  ;; 1. Redirect *Messages* to a file.
  (defvar ement-test--log-file "__LOG_FILE__")
  (defun ement-test--log-messages (&rest _)
    "Append latest message to log file."
    (when (get-buffer "*Messages*")
      (with-current-buffer "*Messages*"
        (let ((msg (buffer-substring-no-properties
                    (max (point-min) (- (point-max) 512))
                    (point-max))))
          (append-to-file msg nil ement-test--log-file)))))
  (run-with-idle-timer 2 t #'ement-test--log-messages)

  ;; 2. Set warning-minimum-log-level to :debug for ement.
  (setq warning-minimum-log-level :warning)

  ;; 3. Enable ement-debug messages in *Warnings*.
  ;; (setq warning-minimum-log-level :debug)  ;; uncomment for VERY verbose

  ;; 4. Log all network requests (plz).
  ;; (setq plz-log-level 'debug)  ;; uncomment if you need HTTP-level tracing

  ;; 5. Show a monitoring buffer with connection state.
  (defun ement-test--show-monitor ()
    "Open a side window with the *Warnings* buffer for monitoring."
    (when (get-buffer "*Warnings*")
      (display-buffer "*Warnings*"
                      '(display-buffer-in-side-window
                        (side . bottom)
                        (window-height . 10)))))

  ;; ─── Convenience keybindings for testing ────────────────────────
  (global-set-key (kbd "C-c e c") #'ement-connect)
  (global-set-key (kbd "C-c e d") #'ement-disconnect)
  (global-set-key (kbd "C-c e l") #'ement-room-list)
  (global-set-key (kbd "C-c e s") #'ement-room-list-side-window)
  (global-set-key (kbd "C-c e w") #'ement-test--show-monitor)

  ;; ─── Load ement ─────────────────────────────────────────────────
  (require 'ement)
  (require 'ement-room)
  (require 'ement-room-list)
  (require 'ement-notify)
  (require 'ement-tabulated-room-list)
  (require 'ement-space)
  (require 'ement-search)

  ;; ─── Enable new features by default for testing ─────────────────
  ;; tracking.el (if available)
  (when (require 'tracking nil t)
    (ement-notify-tracking-mode 1))

  ;; Show sidebar on connect.
  (setq ement-room-list-side-window-on-connect 'left)
  (add-hook 'ement-after-initial-sync-hook #'ement-room-list-side-window-on-connect)

  ;; Thread indicators enabled by default.
  (setq ement-room-show-thread-indicators t)

  ;; Use format spec with reply and thread indicators.
  (setq ement-room-message-format-spec "%S%L%y%B%T%r%R%t")

  (message "──────────────────────────────────────────────")
  (message "Ement.el test environment loaded!")
  (message "")
  (message "  C-c e c  →  Connect to Matrix")
  (message "  C-c e d  →  Disconnect")
  (message "  C-c e l  →  Room list")
  (message "  C-c e s  →  Room list sidebar")
  (message "  C-c e w  →  Show *Warnings* monitor")
  (message "")
  (message "  In room buffers:")
  (message "    T        →  View thread")
  (message "    s t      →  Thread reply")
  (message "    M-g M-r  →  Quick room switch (unread first)")
  (message "    M-g M-s  →  Toggle sidebar")
  (message "    M-s s    →  Search across rooms")
  (message "    S-RET    →  Reply")
  (message "    ?        →  Transient menu")
  (message "")
  (message "  New format specs: %%T (thread) %%P (presence)")
  (message "  Log file: %s" ement-test--log-file)
  (message "──────────────────────────────────────────────"))
ELISP
}

build_init() {
    local init
    init="$(emacs_load_args)"
    init="${init//__SANDBOX__/$SANDBOX}"
    init="${init//__DEPS_DIR__/$DEPS_DIR}"
    init="${init//__SCRIPT_DIR__/$SCRIPT_DIR}"
    init="${init//__LOG_FILE__/$LOG_FILE}"
    printf '%s' "$init"
}

# ── Subcommands ────────────────────────────────────────────────────────
cmd_interactive() {
    info "Launching Emacs (interactive)…"
    info "Log file: $LOG_FILE"
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"

    local init
    init="$(build_init)"

    "$EMACS" \
        -Q \
        --eval "$init" \
        "$@"

    ok "Emacs exited."
    info "Session log: $LOG_FILE"
}

cmd_connect() {
    info "Launching Emacs with auto-connect prompt…"
    info "Log file: $LOG_FILE"
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"

    local init
    init="$(build_init)"

    "$EMACS" \
        -Q \
        --eval "$init" \
        --eval "(call-interactively #'ement-connect)" \
        "$@"
}

cmd_batch_test() {
    info "Running ERT tests in batch mode…"
    mkdir -p "$LOG_DIR"

    local init
    init="$(build_init)"

    "$EMACS" --batch \
        --eval "$init" \
        -l "${SCRIPT_DIR}/tests/ement-tests.el" \
        --eval "(ert-run-tests-batch-and-exit)" \
        2>&1 | tee "${LOG_DIR}/test-$(date +%Y%m%d-%H%M%S).log"

    ok "Tests finished. See log above."
}

cmd_lint() {
    info "Byte-compiling all .el files to check for warnings…"
    mkdir -p "$LOG_DIR"

    local init
    init="$(build_init)"

    local exit_code=0
    for f in "${SCRIPT_DIR}"/*.el; do
        [[ "$(basename "$f")" == .* ]] && continue
        printf "  %-40s " "$(basename "$f")"
        if output=$("$EMACS" --batch \
            --eval "$init" \
            --eval "(setq byte-compile-error-on-warn nil)" \
            -f batch-byte-compile "$f" 2>&1); then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}WARNINGS${NC}"
            echo "$output" | grep -E "Warning|Error" | head -5
            exit_code=1
        fi
    done

    # Clean up .elc files — we only wanted warnings.
    rm -f "${SCRIPT_DIR}"/*.elc

    if [[ $exit_code -eq 0 ]]; then
        ok "All files compiled cleanly."
    else
        warn "Some files produced warnings (see above)."
    fi
    return $exit_code
}

cmd_clean() {
    info "Removing sandbox at $SANDBOX …"
    rm -rf "$SANDBOX"
    ok "Clean. Run the script again to re-install deps."
}

# ── Tail logs (handy in a second terminal) ─────────────────────────────
cmd_tail() {
    local latest
    latest=$(ls -t "$LOG_DIR"/ement-*.log 2>/dev/null | head -1)
    if [[ -z "$latest" ]]; then
        err "No log files found in $LOG_DIR"
        exit 1
    fi
    info "Tailing $latest  (Ctrl-C to stop)"
    tail -f "$latest"
}

# ── Main ───────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTION]

Options:
  (none)          Launch interactive Emacs with ement loaded
  --connect       Launch and immediately prompt to connect
  --batch-test    Run ERT tests in batch mode
  --lint          Byte-compile all .el files (check for warnings)
  --clean         Wipe sandbox and re-install dependencies
  --tail          Tail the latest log file (run in a second terminal)
  --help          Show this help

Environment:
  EMACS=path      Override the Emacs binary (default: emacs)
  FORCE_CLEAN=1   Force re-install of dependencies

Log files are written to: $LOG_DIR/
EOF
}

main() {
    check_emacs

    case "${1:-}" in
        --clean)
            cmd_clean
            ;;
        --batch-test)
            install_deps
            shift
            cmd_batch_test "$@"
            ;;
        --lint)
            install_deps
            shift
            cmd_lint "$@"
            ;;
        --connect)
            install_deps
            shift
            cmd_connect "$@"
            ;;
        --tail)
            cmd_tail
            ;;
        --help|-h)
            usage
            ;;
        "")
            install_deps
            cmd_interactive
            ;;
        *)
            err "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
