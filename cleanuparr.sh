#!/bin/bash
# Cleanuparr installer for Swizzin/HBD-style user systemd

user=$(whoami)

INSTALL_DIR="$HOME/.local/opt/cleanuparr"
CONFIG_DIR="$HOME/.config/cleanuparr"
TMP_DIR="$HOME/.tmp/cleanuparr"
LOCK_FILE="$HOME/.install/.cleanuparr.lock"
SERVICE_FILE="$HOME/.config/systemd/user/cleanuparr.service"
LOG_DIR="$HOME/.logs"
LOG_FILE="$LOG_DIR/cleanuparr.log"

mkdir -p "$LOG_DIR" "$HOME/.install"
touch "$LOG_FILE"

function port() {
    LOW_BOUND=$1
    UPPER_BOUND=$2

    comm -23 \
        <(seq "$LOW_BOUND" "$UPPER_BOUND" | sort) \
        <(ss -Htan | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u) \
        | shuf | head -n 1
}

function cleanup_tmp() {
    rm -rf "$TMP_DIR"
}

function cleanuparr_download_latest() {
    echo "Downloading Cleanuparr release archive"

    case "$(dpkg --print-architecture)" in
        "amd64") arch="amd64" ;;
        "arm64") arch="arm64" ;;
        *)
            echo "Arch not supported"
            exit 1
            ;;
    esac

    latest=$(
        curl -fsSL https://api.github.com/repos/Cleanuparr/Cleanuparr/releases/latest \
        | grep "linux-${arch}" \
        | grep "browser_download_url" \
        | cut -d '"' -f4 \
        | head -n 1
    )

    if [[ -z "$latest" ]]; then
        echo "Failed to find latest Cleanuparr linux-${arch} release"
        exit 1
    fi

    cleanup_tmp
    mkdir -p "$TMP_DIR"

    if ! curl -fL "$latest" -o "$TMP_DIR/cleanuparr.zip" >> "$LOG_FILE" 2>&1; then
        echo "Download failed"
        exit 1
    fi

    echo "Archive downloaded"
}

function cleanuparr_extract_to_tmp() {
    echo "Extracting archive"

    mkdir -p "$TMP_DIR/extracted"

    unzip -oq "$TMP_DIR/cleanuparr.zip" -d "$TMP_DIR/extracted" >> "$LOG_FILE" 2>&1 || {
        echo "Failed to extract archive"
        exit 1
    }

    extracted_root=$(find "$TMP_DIR/extracted" -mindepth 1 -maxdepth 1 -type d | head -n 1)

    if [[ -z "$extracted_root" ]]; then
        extracted_root="$TMP_DIR/extracted"
    fi

    if [[ ! -f "$extracted_root/Cleanuparr" ]]; then
        echo "Cleanuparr binary not found in archive"
        exit 1
    fi
}

function ensure_config_symlink() {
    mkdir -p "$CONFIG_DIR"

    rm -rf "$INSTALL_DIR/config"
    ln -sfn "$CONFIG_DIR" "$INSTALL_DIR/config"
}

function install_or_update_files() {
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    cp -a "$extracted_root"/. "$INSTALL_DIR"/

    ensure_config_symlink

    chmod +x "$INSTALL_DIR/Cleanuparr"
}

function write_lock_file() {
    local port="$1"

    cat > "$LOCK_FILE" << EOF
PORT=${port}
EOF
}

function load_lock_file() {
    if [[ ! -f "$LOCK_FILE" ]]; then
        echo "Cleanuparr not installed!"
        exit 1
    fi

    source "$LOCK_FILE"

    if [[ -z "$PORT" ]]; then
        echo "Lock file is missing PORT"
        exit 1
    fi
}

function _systemd() {
    local port="$1"
    local type=simple

    if [[ $(systemctl --version | awk 'NR==1 {print $2}') -ge 240 ]]; then
        type=exec
    fi

    echo "Installing systemd user service"

    mkdir -p "$HOME/.config/systemd/user"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Cleanuparr
After=network.target

[Service]
Type=${type}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/Cleanuparr
Restart=always
RestartSec=5
Environment=PORT=${port}
Environment=BIND_ADDRESS=0.0.0.0
Environment=BASE_PATH=

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload

    echo "Service installed"
}

function _install() {
    if [[ -f "$LOCK_FILE" ]]; then
        echo "Cleanuparr already installed. Use upgrade instead."
        exit 1
    fi

    PORT=$(port 11011 11211)

    cleanuparr_download_latest
    cleanuparr_extract_to_tmp
    install_or_update_files
    _systemd "$PORT"

    systemctl --user enable --now cleanuparr 2>&1 | tee -a "$LOG_FILE"

    write_lock_file "$PORT"
    cleanup_tmp

    echo "Cleanuparr installed and running at http://$(hostname -f):${PORT}/" | tee -a "$LOG_FILE"
}

function _upgrade() {
    load_lock_file

    systemctl --user stop cleanuparr

    cleanuparr_download_latest
    cleanuparr_extract_to_tmp
    install_or_update_files
    _systemd "$PORT"

    systemctl --user enable --now cleanuparr 2>&1 | tee -a "$LOG_FILE"

    cleanup_tmp

    echo "Cleanuparr upgraded and running at http://$(hostname -f):${PORT}/" | tee -a "$LOG_FILE"
}

function _remove() {
    if [[ ! -f "$LOCK_FILE" ]]; then
        echo "Cleanuparr not installed!"
        exit 1
    fi

    systemctl --user stop cleanuparr
    systemctl --user disable cleanuparr

    rm -f "$SERVICE_FILE"

    systemctl --user daemon-reload

    rm -rf "$INSTALL_DIR"
    rm -rf "$CONFIG_DIR"
    rm -rf "$TMP_DIR"
    rm -f "$LOCK_FILE"

    echo "Cleanuparr removed"
}

echo 'This is unsupported software. You will not get help with this, please answer `yes` if you understand and wish to proceed'

if [[ -z ${eula} ]]; then
    read -r eula
fi

if ! [[ $eula =~ yes ]]; then
    echo "You did not accept the above. Exiting..."
    exit 1
fi

echo "Proceeding..."
echo ""
echo "Welcome to the Cleanuparr installer..."
echo ""
echo "Logs are stored at ${LOG_FILE}"
echo "install = Install Cleanuparr"
echo "upgrade = Upgrade Cleanuparr to latest version"
echo "uninstall = Completely remove Cleanuparr"
echo "exit = Exit installer"

while true; do
    read -r -p "Enter it here: " choice

    case "$choice" in
        "install")
            _install
            break
            ;;
        "upgrade")
            _upgrade
            break
            ;;
        "uninstall")
            _remove
            break
            ;;
        "exit")
            break
            ;;
        *)
            echo "Unknown option."
            ;;
    esac
done

exit
