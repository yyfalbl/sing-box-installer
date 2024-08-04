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
    eval $invocation

    echo ""
    echo "==============================================="
    echo "Congratulations! 恭喜！"
    echo "创建并运行sing-box服务成功。"
    echo ""
    echo "请使用客户端尝试连接你的节点进行测试"

    local JSON=$(cat $WORK_DIR/data/config.json)
    echo ""
    echo ""
    echo ""
    echo "==============================================="
    err "【vmess节点】如下："
    port_vmess=$(jq -r '.inbounds[0].listen_port' <<< "$JSON")
    proxy_uuid=$(jq -r '.inbounds[0].users[0].uuid' <<< "$JSON")
    domain=$(cat $domain_file)
    sub_vmess="vmess://$(echo "{\"add\":\"$domain\",\"aid\":\"0\",\"host\":\"download.windowsupdate.com\",\"id\":\"$proxy_uuid\",\"net\":\"ws\",\"path\":\"/download\",\"port\":\"$port_vmess\",\"ps\":\"serv00-vmess\",\"scy\":\"auto\",\"sni\":\"\",\"tls\":\"\",\"type\":\"\",\"v\":\"2\"}" | base64 -w0 )"
    echo "订阅：$sub_vmess"
    echo "服务器：$domain"
    echo "端口：$port_vmess"
    echo "UUID：$proxy_uuid"
    echo "Alter Id：0"
    echo "传输：ws"
    echo "Path：/download"
    echo "Host：download.windowsupdate.com"
    echo ""
    echo ""
    echo ""
    echo "==============================================="
    err "【vless节点】如下："
    port_vless=$(jq -r '.inbounds[1].listen_port' <<< "$JSON")
    proxy_uuid=$(jq -r '.inbounds[1].users[0].uuid' <<< "$JSON")
    domain=$(cat $domain_file)
    sub_vless="vless://$proxy_uuid@$domain:$port_vless?security=none&type=ws&host=$domain&path=/vless#serv00-vless"
    echo "订阅：$sub_vless"
    echo "服务器：$domain"
    echo "端口：$port_vless"
    echo "UUID：$proxy_uuid"
    echo "传输：ws"
    echo "Path：/vless"
    echo "Host：$domain"
    echo "==============================================="
}

uninstall(){
    eval $invocation

    rm -rf $WORK_DIR/*
    say_warning "完成"
}

stop_sbox(){
    eval $invocation

    kill -9 $SING_BOX_PID
    say "已关闭"
}

menu_setting() {
  eval $invocation
  
  check_status

  if [[ -n "$SING_BOX_PID" ]]; then
    OPTION[1]="1 .  查看sing-box运行状态"
    OPTION[2]="2 .  查看订阅"
    OPTION[3]="3 .  查看sing-box日志"
    OPTION[4]="4 .  关闭sing-box"
    OPTION[5]="5 .  卸载"

    ACTION[1]() { check_status; exit 0; }
    ACTION[2]() { get_sub; exit 0; }
    ACTION[3]() { tail -f $log_file; exit 0; }
    ACTION[4]() { stop_sbox; exit 0; }
    ACTION[5]() { uninstall; exit; }
  else
    OPTION[1]="1.  安装sing-box"
    OPTION[2]="2.  启动sing-box"
    OPTION[3]="3.  卸载"

    ACTION[1]() { init; exit; }
    ACTION[2]() { run_sbox; check_status; exit; }
    ACTION[3]() { uninstall; exit; }
  fi

  [ "${#OPTION[@]}" -ge '10' ] && OPTION[0]="0 .  Exit" || OPTION[0]="0.  Exit"
  ACTION[0]() { exit; }
}

menu() {
  eval $invocation

  say "==============================================="
  for ((b=1;b<=${#OPTION[*]};b++)); 
  do [ "$b" = "${#OPTION[*]}" ] && warning " ${OPTION[0]} " || warning " ${OPTION[b]} "; 
  done
  read -rp "Choose: " CHOOSE

  # 输入必须是数字且少于等于最大可选项
  if grep -qE "^[0-9]{1,2}$" <<< "$CHOOSE" && [ "$CHOOSE" -lt "${#OPTION[*]}" ]; then
    ACTION[$CHOOSE]
  else
    warning " Please enter the correct number [0-$((${#OPTION[*]}-1))] " && sleep 1 && menu
  fi
}

init(){
    #install_sbox_binary
    install_sbox_bin

    read_var_from_user

    download_data_files
    replace_configs

    run_sbox

    check_status
    get_sub
}

main() {
    menu_setting
    menu
}

main
