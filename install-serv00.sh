#!/usr/bin/env bash
set -e
set -u
set -o pipefail

# ------------share--------------
invocation='echo "" && say_verbose "Calling: ${yellow:-}${FUNCNAME[0]} ${green:-}$*${normal:-}"'
exec 3>&1
if [ -t 1 ] && command -v tput >/dev/null; then
    ncolors=$(tput colors || echo 0)
    if [ -n "$ncolors" ] && [ $ncolors -ge 8 ]; then
        bold="$(tput bold || echo)"
        normal="$(tput sgr0 || echo)"
        black="$(tput setaf 0 || echo)"
        red="$(tput setaf 1 || echo)"
        green="$(tput setaf 2 || echo)"
        yellow="$(tput setaf 3 || echo)"
        blue="$(tput setaf 4 || echo)"
        magenta="$(tput setaf 5 || echo)"
        cyan="$(tput setaf 6 || echo)"
        white="$(tput setaf 7 || echo)"
    fi
fi

print_prefix="ray_sbox_install"

warning() {
    printf "%b\n" "${yellow:-}$1${normal:-}" >&3
}
say_warning() {
    printf "%b\n" "${yellow:-}$print_prefix: Warning: $1${normal:-}" >&3
}

err() {
    printf "%b\n" "${red:-}$1${normal:-}" >&2
}
say_err() {
    printf "%b\n" "${red:-}$print_prefix: Error: $1${normal:-}" >&2
}

say() {
    # using stream 3 (defined in the beginning) to not interfere with stdout of functions
    # which may be used as return value
    printf "%b\n" "${cyan:-}$print_prefix:${normal:-} $1" >&3
}

say_verbose() {
    if [ "$verbose" = true ]; then
        say "$1"
    fi
}

machine_has() {
    eval $invocation

    command -v "$1" >/dev/null 2>&1
    return $?
}

# args:
# remote_path - $1
get_http_header_curl() {
    eval $invocation

    local remote_path="$1"

    curl_options="-I -sSL --retry 5 --retry-delay 2 --connect-timeout 15 "
    curl $curl_options "$remote_path" 2>&1 || return 1
    return 0
}

# args:
# remote_path - $1
get_http_header_wget() {
    eval $invocation

    local remote_path="$1"
    local wget_options="-q -S --spider --tries 5 "
    # Store options that aren't supported on all wget implementations separately.
    local wget_options_extra="--waitretry 2 --connect-timeout 15 "
    local wget_result=''

    wget $wget_options $wget_options_extra "$remote_path" 2>&1
    wget_result=$?

    if [[ $wget_result = 2 ]]; then
        # Parsing of the command has failed. Exclude potentially unrecognized options and retry.
        wget $wget_options "$remote_path" 2>&1
        return $?
    fi

    return $wget_result
}

# Updates global variables $http_code and $download_error_msg
downloadcurl() {
    eval $invocation

    unset http_code
    unset download_error_msg
    local remote_path="$1"
    local out_path="${2:-}"
    local remote_path_with_credential="${remote_path}"
    local curl_options="--retry 20 --retry-delay 2 --connect-timeout 15 -sSL -f --create-dirs "
    local failed=false
    if [ -z "$out_path" ]; then
        curl $curl_options "$remote_path_with_credential" 2>&1 || failed=true
    else
        curl $curl_options -o "$out_path" "$remote_path_with_credential" 2>&1 || failed=true
    fi
    if [ "$failed" = true ]; then
        local response=$(get_http_header_curl $remote_path)
        http_code=$(echo "$response" | awk '/^HTTP/{print $2}' | tail -1)
        download_error_msg="Unable to download $remote_path."
        if [[ $http_code != 2* ]]; then
            download_error_msg+=" Returned HTTP status code: $http_code."
        fi
        say_verbose "$download_error_msg"
        return 1
    fi
    return 0
}

# Updates global variables $http_code and $download_error_msg
downloadwget() {
    eval $invocation

    unset http_code
    unset download_error_msg
    local remote_path="$1"
    local out_path="${2:-}"
    local remote_path_with_credential="${remote_path}"
    local wget_options="--tries 20 "
    # Store options that aren't supported on all wget implementations separately.
    local wget_options_extra="--waitretry 2 --connect-timeout 15 "
    local wget_result=''

    if [ -z "$out_path" ]; then
        wget -q $wget_options $wget_options_extra -O - "$remote_path_with_credential" 2>&1
        wget_result=$?
    else
        wget $wget_options $wget_options_extra -O "$out_path" "$remote_path_with_credential" 2>&1
        wget_result=$?
    fi

    if [[ $wget_result = 2 ]]; then
        # Parsing of the command has failed. Exclude potentially unrecognized options and retry.
        if [ -z "$out_path" ]; then
            wget -q $wget_options -O - "$remote_path_with_credential" 2>&1
            wget_result=$?
        else
            wget $wget_options -O "$out_path" "$remote_path_with_credential" 2>&1
            wget_result=$?
        fi
    fi

    if [[ $wget_result != 0 ]]; then
        local disable_feed_credential=false
        local response=$(get_http_header_wget $remote_path $disable_feed_credential)
        http_code=$(echo "$response" | awk '/^  HTTP/{print $2}' | tail -1)
        download_error_msg="Unable to download $remote_path."
        if [[ $http_code != 2* ]]; then
            download_error_msg+=" Returned HTTP status code: $http_code."
        fi
        say_verbose "$download_error_msg"
        return 1
    fi

    return 0
}

# args:
# remote_path - $1
# [out_path] - $2 - stdout if not provided
download() {
    eval $invocation

    local remote_path="$1"
    local out_path="${2:-}"

    if [[ "$remote_path" != "http"* ]]; then
        cp "$remote_path" "$out_path"
        return $?
    fi

    local failed=false
    local attempts=0
    while [ $attempts -lt 3 ]; do
        attempts=$((attempts + 1))
        failed=false
        if machine_has "curl"; then
            downloadcurl "$remote_path" "$out_path" || failed=true
        elif machine_has "wget"; then
            downloadwget "$remote_path" "$out_path" || failed=true
        else
            say_err "Missing dependency: neither curl nor wget was found."
            exit 1
        fi

        if [ "$failed" = false ] || [ $attempts -ge 3 ] || { [ ! -z $http_code ] && [ $http_code = "404" ]; }; then
            break
        fi

        say "Download attempt #$attempts has failed: $http_code $download_error_msg"
        say "Attempt #$((attempts + 1)) will start in $((attempts * 10)) seconds."
        sleep $((attempts * 10))
    done

    if [ "$failed" = true ]; then
        say_verbose "Download failed: $remote_path"
        return 1
    fi
    return 0
}
# ---------------------------------

echo '  ____               ____  _              '
echo ' |  _ \ __ _ _   _  / ___|(_)_ __   __ _  '
echo ' | |_) / _` | | | | \___ \| |  _ \ / _  | '
echo ' |  _ < (_| | |_| |  ___) | | | | | (_| | '
echo ' |_| \_\__,_|\__, | |____/|_|_| |_|\__, | '
echo '             |___/                 |___/  '

# ------------vars-----------
WORK_DIR="$PWD" # ~/sing-box

gitRowUrl="https://raw.githubusercontent.com/RayWangQvQ/sing-box-installer/main"

sbox_pkg_url="https://pkg.freebsd.org/FreeBSD:14:amd64/latest/All/sing-box-1.9.3.pkg" # https://pkgs.org/download/sing-box
sbox_pkg_fileName="sing-box-1.9.3.pkg"
sbox_bin_url="https://raw.githubusercontent.com/k0baya/sb-for-serv00/main/sing-box"
status_sbox=0 # 0.未下载；1.已安装未运行；2.运行
SING_BOX_PID=""
log_file="$WORK_DIR/data/sing-box.log"

proxy_uuid=""
proxy_uuid_file="$WORK_DIR/data/uuid.txt"
proxy_name="ray"
proxy_pwd="ray1qaz@WSX"

domain=""
domain_file="$WORK_DIR/data/domain.txt"
domain_name="rayexample.com"
proxy_node_path=""

is_docker=false

if [ -f "$WORK_DIR/data/proxy_node_path.txt" ]; then
    proxy_node_path=$(cat "$WORK_DIR/data/proxy_node_path.txt")
fi

if [ -f "$WORK_DIR/data/domain.txt" ]; then
    domain=$(cat "$WORK_DIR/data/domain.txt")
fi

if [ -f "$WORK_DIR/data/uuid.txt" ]; then
    proxy_uuid=$(cat "$WORK_DIR/data/uuid.txt")
fi

# ------------main------------

main() {
    echo "This script installs and manages Sing-box. Please make sure to run it as root or with sudo."

    if [ -d "$WORK_DIR" ]; then
        echo "Working directory: $WORK_DIR"
    else
        echo "Creating working directory: $WORK_DIR"
        mkdir -p "$WORK_DIR"
    fi

    if [ -f "$log_file" ]; then
        echo "Log file found at: $log_file"
    else
        echo "Creating log file at: $log_file"
        touch "$log_file"
    fi

    if [ -z "$proxy_uuid" ]; then
        echo "No UUID found. Generating a new one."
        proxy_uuid=$(uuidgen)
        echo "$proxy_uuid" > "$proxy_uuid_file"
    fi

    if [ -z "$domain" ]; then
        echo "No domain found. Setting default domain."
        domain="$domain_name"
        echo "$domain" > "$domain_file"
    fi

    echo "Proxy UUID: $proxy_uuid"
    echo "Domain: $domain"

    if [ "$status_sbox" -eq 0 ]; then
        echo "Sing-box is not installed. Downloading and installing..."
        download "$sbox_pkg_url" "$WORK_DIR/$sbox_pkg_fileName"
        if [ $? -eq 0 ]; then
            echo "Installation package downloaded successfully."
            echo "Installing Sing-box..."
            # Example installation command; adapt as needed
            pkg add "$WORK_DIR/$sbox_pkg_fileName" >> "$log_file" 2>&1
            status_sbox=1
        else
            echo "Failed to download Sing-box package."
        fi
    fi

    if [ "$status_sbox" -eq 1 ]; then
        echo "Sing-box is installed but not running."
        echo "Starting Sing-box..."
        # Example start command; adapt as needed
        sing-box start >> "$log_file" 2>&1
        status_sbox=2
    fi

    if [ "$status_sbox" -eq 2 ]; then
        echo "Sing-box is running."
        echo "Checking status..."
        # Example status check command; adapt as needed
        sing-box status >> "$log_file" 2>&1
    fi

    echo "Script completed."
}

main

