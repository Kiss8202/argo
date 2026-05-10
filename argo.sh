#!/bin/bash
# onekey suoha (optimized for Alpine & Debian, supports xray & sing-box, with Alpine process keepalive)
# 快捷命令: argo

# 强制使用 bash
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "错误：需要 bash 环境，请先安装 bash (debian: apt install bash / alpine: apk add bash)"
        exit 1
    fi
fi

# ---------- 系统检测与包管理适配 ----------
detected_os=$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}')
case "$detected_os" in
    Debian|Ubuntu)    pkg_update="apt update"; pkg_install="apt -y install" ;;
    CentOS|Fedora)    pkg_update="yum -y update"; pkg_install="yum -y install" ;;
    Alpine)           pkg_update="apk update"; pkg_install="apk add -f" ;;
    *)                echo "未适配系统，尝试使用 apt"; pkg_update="apt update"; pkg_install="apt -y install" ;;
esac

install_if_missing() {
    local cmd=$1 pkg=$2
    if ! command -v "$cmd" >/dev/null 2>&1; then
        $pkg_update
        $pkg_install "$pkg"
    fi
}

install_if_missing curl curl
install_if_missing unzip unzip
install_if_missing tar tar
# Alpine 不需要 systemctl
if [ "$detected_os" != "Alpine" ]; then
    install_if_missing systemctl systemd
fi

# ---------- 通用函数 ----------
cleanup_process() {
    local proc_name=$1
    if [ "$detected_os" = "Alpine" ]; then
        kill -9 $(ps -ef | grep "$proc_name" | grep -v grep | awk '{print $1}') 2>/dev/null
    else
        kill -9 $(ps -ef | grep "$proc_name" | grep -v grep | awk '{print $2}') 2>/dev/null
    fi
}

is_alpine() { [ "$detected_os" = "Alpine" ]; }

# base64 生成 vmess 链接（兼容 Alpine busybox）
gen_vmess_link() {
    local argo_host=$1 uuid=$2 urlpath=$3 isp=$4
    local node_name="${isp//_/ }"
    local tls_json="{\"add\":\"www.visa.com.sg\",\"aid\":\"0\",\"host\":\"$argo_host\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$urlpath\",\"port\":\"443\",\"ps\":\"${node_name}_tls\",\"tls\":\"tls\",\"type\":\"none\",\"v\":\"2\"}"
    local notls_json="{\"add\":\"www.visa.com.sg\",\"aid\":\"0\",\"host\":\"$argo_host\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$urlpath\",\"port\":\"80\",\"ps\":\"${node_name}\",\"tls\":\"\",\"type\":\"none\",\"v\":\"2\"}"

    if is_alpine; then
        echo "vmess://$(printf "%s" "$tls_json" | base64 | tr -d '\n' | awk '{ORS=(NR%76==0?RS:"");}1')"
        echo "vmess://$(printf "%s" "$notls_json" | base64 | tr -d '\n' | awk '{ORS=(NR%76==0?RS:"");}1')"
    else
        echo "vmess://$(printf "%s" "$tls_json" | base64 -w 0)"
        echo "vmess://$(printf "%s" "$notls_json" | base64 -w 0)"
    fi
}

# 下载并准备核心（根据 core_type 和架构，从官方 API 获取最新版本）
download_core() {
    local arch=$(uname -m)
    local download_dir="${1:-.}"
    mkdir -p "$download_dir"

    if [ "$core_type" = "xray" ]; then
        local core_path="$download_dir/xray"
        if [ -f "$core_path" ]; then
            echo "xray 已存在，跳过下载"
            return
        fi
        local latest_tag=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name"' | tr ',' '\n' | grep '"tag_name"' | sed 's/.*: "\(.*\)".*/\1/')
        if [ -z "$latest_tag" ]; then
            echo "无法获取 xray 最新版本，请检查网络"
            exit 1
        fi
        local arch_suffix
        case "$arch" in
            x86_64|amd64)    arch_suffix="64" ;;
            i386|i686)       arch_suffix="32" ;;
            armv8|arm64|aarch64) arch_suffix="arm64-v8a" ;;
            armv7l)          arch_suffix="arm32-v7a" ;;
            *)               echo "架构 $arch 不支持 xray"; exit 1 ;;
        esac
        local filename="Xray-linux-${arch_suffix}.zip"
        local url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/${filename}"
        curl -sL "$url" -o xray.zip
        unzip -d xray_tmp xray.zip
        mv xray_tmp/xray "$core_path"
        rm -rf xray.zip xray_tmp
        chmod +x "$core_path"
        echo "xray 下载完成"
    else  # sing-box
        local core_path="$download_dir/sing-box"
        if [ -f "$core_path" ]; then
            echo "sing-box 已存在，跳过下载"
            return
        fi
        local latest_tag=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | tr ',' '\n' | grep '"tag_name"' | sed 's/.*: "\(.*\)".*/\1/')
        if [ -z "$latest_tag" ]; then
            echo "无法获取 sing-box 最新版本，请检查网络"
            exit 1
        fi
        local version=${latest_tag#v}
        local arch_suffix
        case "$arch" in
            x86_64|amd64)    arch_suffix="amd64" ;;
            aarch64|arm64)   arch_suffix="arm64" ;;
            armv7l)          arch_suffix="armv7" ;;
            *)               echo "架构 $arch 不支持 sing-box"; exit 1 ;;
        esac
        local filename="sing-box-${version}-linux-${arch_suffix}.tar.gz"
        local url="https://github.com/SagerNet/sing-box/releases/download/${latest_tag}/${filename}"
        curl -sL "$url" -o sing-box.tar.gz
        tar -xzf sing-box.tar.gz
        mv sing-box-*/sing-box "$core_path" 2>/dev/null || mv sing-box "$core_path"
        rm -rf sing-box.tar.gz sing-box-*
        chmod +x "$core_path"
        echo "sing-box 下载完成"
    fi
}

# 生成核心配置文件（xray 或 sing-box）
gen_config() {
    local port=$1 uuid=$2 urlpath=$3
    if [ "$core_type" = "xray" ]; then
        if [ "$protocol" == "1" ]; then
            cat > xray_config.json <<EOF
{
    "inbounds": [{
        "port": $port,
        "listen": "localhost",
        "protocol": "vmess",
        "settings": {
            "clients": [{ "id": "$uuid", "alterId": 0 }]
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": { "path": "$urlpath" }
        }
    }],
    "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
        else
            cat > xray_config.json <<EOF
{
    "inbounds": [{
        "port": $port,
        "listen": "localhost",
        "protocol": "vless",
        "settings": {
            "decryption": "none",
            "clients": [{ "id": "$uuid" }]
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": { "path": "$urlpath" }
        }
    }],
    "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
        fi
    else  # sing-box
        if [ "$protocol" == "1" ]; then
            cat > sing-box_config.json <<EOF
{
    "inbounds": [{
        "type": "vmess",
        "tag": "vmess-in",
        "listen": "127.0.0.1",
        "listen_port": $port,
        "users": [{ "uuid": "$uuid", "alterId": 0 }],
        "transport": {
            "type": "ws",
            "path": "$urlpath"
        }
    }],
    "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
        else
            cat > sing-box_config.json <<EOF
{
    "inbounds": [{
        "type": "vless",
        "tag": "vless-in",
        "listen": "127.0.0.1",
        "listen_port": $port,
        "users": [{ "uuid": "$uuid" }],
        "transport": {
            "type": "ws",
            "path": "$urlpath"
        }
    }],
    "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
        fi
    fi
}

# 启动核心进程（安装模式用 /opt/argo 下的文件）
start_core() {
    if [ "$core_type" = "xray" ]; then
        /opt/argo/xray run -config /opt/argo/config.json >/dev/null 2>&1 &
    else
        /opt/argo/sing-box run -c /opt/argo/config.json >/dev/null 2>&1 &
    fi
}

# ---------- 梭哈模式 ----------
quicktunnel() {
    rm -rf xray cloudflared-linux xray.zip /tmp/sing-box 2>/dev/null
    if [ "$core_type" = "xray" ]; then
        rm -f xray xray.zip 2>/dev/null
    else
        rm -f sing-box sing-box.tar.gz 2>/dev/null
    fi
    download_core "./"

    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux ;;
        i386|i686)      curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o cloudflared-linux ;;
        arm64|aarch64)  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux ;;
        armv7l)         curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o cloudflared-linux ;;
        *)              echo "架构 $arch 无 cloudflared 支持"; exit 1 ;;
    esac
    chmod +x cloudflared-linux

    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local urlpath=$(echo "$uuid" | awk -F- '{print $1}')
    local port=$((RANDOM+10000))
    gen_config "$port" "$uuid" "$urlpath"

    if [ "$core_type" = "xray" ]; then
        ./xray run -config xray_config.json >/dev/null 2>&1 &
    else
        ./sing-box run -c sing-box_config.json >/dev/null 2>&1 &
    fi

    ./cloudflared-linux tunnel --url http://localhost:$port --no-autoupdate --edge-ip-version "$ips" --protocol http2 > argo.log 2>&1 &
    sleep 1

    local n=0 argo
    while true; do
        n=$((n+1))
        clear
        echo "等待 cloudflare argo 生成地址 已等待 $n 秒"
        argo=$(cat argo.log | grep trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
        if [ $n -ge 15 ]; then
            n=0
            cleanup_process cloudflared-linux
            rm -f argo.log
            clear
            echo "argo 获取超时，重试中"
            ./cloudflared-linux tunnel --url http://localhost:$port --no-autoupdate --edge-ip-version "$ips" --protocol http2 > argo.log 2>&1 &
            sleep 1
        elif [ -z "$argo" ]; then
            sleep 1
        else
            rm -f argo.log
            break
        fi
    done

    clear
    > v2ray.txt
    if [ "$protocol" == "1" ]; then
        echo -e "vmess 链接已生成, 可替换为CF优选IP\n" >> v2ray.txt
        gen_vmess_link "$argo" "$uuid" "$urlpath" "$isp" >> v2ray.txt
        echo -e "\n端口 443 可改为 2053 2083 2087 2096 8443\n" >> v2ray.txt
        echo -e "端口 80 可改为 8080 8880 2052 2082 2086 2095" >> v2ray.txt
    else
        echo -e "vless 链接已生成, 可替换为CF优选IP\n" > v2ray.txt
        echo "vless://$uuid@www.visa.com.sg:443?encryption=none&security=tls&type=ws&host=$argo&path=$urlpath#$(echo "$isp" | sed 's/_/%20/g; s/,/%2C/g')_tls" >> v2ray.txt
        echo -e "\n端口 443 可改为 2053 2083 2087 2096 8443\n" >> v2ray.txt
        echo "vless://$uuid@www.visa.com.sg:80?encryption=none&security=none&type=ws&host=$argo&path=$urlpath#$(echo "$isp" | sed 's/_/%20/g; s/,/%2C/g')" >> v2ray.txt
        echo -e "\n端口 80 可改为 8080 8880 2052 2082 2086 2095" >> v2ray.txt
    fi
    cat v2ray.txt
    echo -e "\n信息已保存 /root/v2ray.txt，重启失效！"
}

# ---------- 安装服务模式 ----------
installtunnel() {
    mkdir -p /opt/argo
    download_core "/opt/argo"
    if [ ! -f /opt/argo/cloudflared-linux ]; then
        local arch=$(uname -m)
        case "$arch" in
            x86_64|amd64)   curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /opt/argo/cloudflared-linux ;;
            i386|i686)      curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o /opt/argo/cloudflared-linux ;;
            arm64|aarch64)  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o /opt/argo/cloudflared-linux ;;
            armv7l)         curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o /opt/argo/cloudflared-linux ;;
            *)              echo "架构 $arch 无 cloudflared 支持"; exit 1 ;;
        esac
        chmod +x /opt/argo/cloudflared-linux
    fi

    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local urlpath=$(echo "$uuid" | awk -F- '{print $1}')
    local port=$((RANDOM+10000))
    gen_config "$port" "$uuid" "$urlpath"
    mv xray_config.json /opt/argo/config.json 2>/dev/null || mv sing-box_config.json /opt/argo/config.json

    echo "$core_type" > /opt/argo/core_type

    clear
    echo -e "\e[1;31m请用浏览器打开以下链接授权 CF 域名：如 example.com\e[0m"
    /opt/argo/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel login
    clear
    /opt/argo/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel list > argo.log 2>&1
    echo -e "已绑定隧道列表：\n"
    sed 1,2d argo.log | awk '{print $2}'
    echo -e "\n输入要使用的完整二级域名 (如 xxx.example.com)："
    read -p "域名: " domain
    if [ -z "$domain" ] || [ $(grep -o '\.' <<< "$domain" | wc -l) -eq 0 ]; then
        echo "域名格式错误"; exit 1
    fi
    local name=$(echo "$domain" | awk -F\. '{print $1}')

    if sed 1,2d argo.log | grep -qw "$name"; then
        echo "隧道 $name 已存在，尝试复用"
        local existing_id=$(sed 1,2d argo.log | awk -v n="$name" '$2==n {print $1}')
        if [ -f "/root/.cloudflared/${existing_id}.json" ]; then
            /opt/argo/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel cleanup "$name" >argo.log 2>&1
        else
            /opt/argo/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel delete "$name" >argo.log 2>&1
            /opt/argo/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel create "$name" >argo.log 2>&1
        fi
    else
        /opt/argo/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel create "$name" >argo.log 2>&1
    fi

    /opt/argo/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel list > argo.log 2>&1
    local tunneliud=$(sed 1,2d argo.log | awk -v n="$name" '$2==n {print $1}')
    if [ -z "$tunneliud" ]; then echo "无法获取隧道 UUID"; exit 1; fi

    echo "绑定域名 $domain"
    /opt/argo/cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel route dns --overwrite-dns "$name" "$domain" >argo.log 2>&1

    > /opt/argo/v2ray.txt
    local isp_escaped=$(echo "$isp" | sed 's/_/%20/g; s/,/%2C/g')
    if [ "$protocol" == "1" ]; then
        echo -e "vmess 链接已生成\n" >> /opt/argo/v2ray.txt
        gen_vmess_link "$domain" "$uuid" "$urlpath" "$isp" >> /opt/argo/v2ray.txt
        echo -e "\n端口 443 可改为 2053 2083 2087 2096 8443\n端口 80 可改为 8080 8880 2052 2082 2086 2095" >> /opt/argo/v2ray.txt
    else
        echo -e "vless 链接已生成\n" > /opt/argo/v2ray.txt
        echo "vless://$uuid@www.visa.com.sg:443?encryption=none&security=tls&type=ws&host=$domain&path=$urlpath#${isp_escaped}_tls" >> /opt/argo/v2ray.txt
        echo -e "\n端口 443 可改为 2053 2083 2087 2096 8443\n" >> /opt/argo/v2ray.txt
        echo "vless://$uuid@www.visa.com.sg:80?encryption=none&security=none&type=ws&host=$domain&path=$urlpath#${isp_escaped}" >> /opt/argo/v2ray.txt
        echo -e "\n端口 80 可改为 8080 8880 2052 2082 2086 2095" >> /opt/argo/v2ray.txt
    fi

    cat > /opt/argo/config.yaml <<EOF
tunnel: $tunneliud
credentials-file: /root/.cloudflared/${tunneliud}.json

ingress:
  - hostname: '*'
    service: http://localhost:$port
EOF

    # 自启服务 (Alpine 使用 supervise-daemon 守护，稳定可靠)
    if is_alpine; then
        # 确保 cgroups 服务已启用（supervise-daemon 依赖）
        rc-update add cgroups default >/dev/null 2>&1
        rc-service cgroups start >/dev/null 2>&1

        # 创建 cloudflared OpenRC 服务脚本
        cat > /etc/init.d/argo-cloudflared <<EOF
#!/sbin/openrc-run
name="argo-cloudflared"
description="Cloudflare Tunnel for argo"

command="/opt/argo/cloudflared-linux"
command_args="--edge-ip-version $ips --protocol http2 tunnel --config /opt/argo/config.yaml run $name"
pidfile="/run/\${name}.pid"
required_files="/opt/argo/config.yaml"
command_background=true

supervisor="supervise-daemon"
respawn_delay=10
respawn_max=0

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/argo-cloudflared

        # 创建核心 OpenRC 服务脚本
        cat > /etc/init.d/argo-core <<EOF
#!/sbin/openrc-run
name="argo-core"
description="${core_type} core for argo"

command="/opt/argo/$core_type"
$([ "$core_type" = "xray" ] && echo 'command_args="run -config /opt/argo/config.json"' || echo 'command_args="run -c /opt/argo/config.json"')
pidfile="/run/\${name}.pid"
required_files="/opt/argo/config.json"
command_background=true

supervisor="supervise-daemon"
respawn_delay=10
respawn_max=0

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/argo-core

        # 启用并启动服务（隐藏日志输出）
        rc-update add argo-cloudflared default
        rc-update add argo-core default
        rc-service argo-cloudflared start >/dev/null 2>&1
        rc-service argo-core start >/dev/null 2>&1

        # 删除旧版 local.d 脚本（如果存在）
        rm -f /etc/local.d/argo-cloudflared.start /etc/local.d/argo-core.start 2>/dev/null
    else
        # systemd 配置（已自带 Restart=on-failure 保活）
        cat > /etc/systemd/system/argo-cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel (argo)
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/argo/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --config /opt/argo/config.yaml run $name
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/systemd/system/argo-core.service <<EOF
[Unit]
Description=Core Service (argo)
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=$([ "$core_type" = "xray" ] && echo "/opt/argo/xray run -config /opt/argo/config.json" || echo "/opt/argo/sing-box run -c /opt/argo/config.json")
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable argo-cloudflared.service argo-core.service
        systemctl start argo-cloudflared.service argo-core.service
    fi

    # 管理脚本
    cat > /opt/argo/argo-manager.sh <<'MANAGER'
#!/bin/bash
CT=$(cat /opt/argo/core_type 2>/dev/null || echo "xray")
clear
while true; do
    if [ -f /etc/alpine-release ]; then
        cstat=$(rc-service argo-cloudflared status 2>/dev/null | grep -q "started" && echo "running" || echo "stop")
        xstat=$(rc-service argo-core status 2>/dev/null | grep -q "started" && echo "running" || echo "stop")
    else
        cstat=$(systemctl is-active argo-cloudflared.service)
        xstat=$(systemctl is-active argo-core.service)
    fi
    echo "cloudflared: $cstat   core($CT): $xstat"
    echo "1. 管理 TUNNEL"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 重启服务"
    echo "5. 卸载服务"
    echo "6. 查看 v2ray 链接"
    echo "0. 退出"
    read -p "选择: " menu
    menu=${menu:-0}
    case $menu in
        1)
            clear
            while true; do
                echo "ARGO TUNNEL 列表："
                /opt/argo/cloudflared-linux tunnel list 2>/dev/null | tail -n +3
                echo ""
                echo "1. 删除隧道  0. 返回"
                read -p "选择: " ta
                if [ "$ta" = "1" ]; then
                    read -p "隧道名: " tn
                    /opt/argo/cloudflared-linux tunnel cleanup "$tn" >/dev/null 2>&1
                    /opt/argo/cloudflared-linux tunnel delete "$tn" >/dev/null 2>&1
                    echo "已删除隧道 $tn"
                    sleep 1
                else
                    break
                fi
            done
            ;;
        2)
            if [ -f /etc/alpine-release ]; then
                rc-service argo-cloudflared start >/dev/null 2>&1
                rc-service argo-core start >/dev/null 2>&1
            else
                systemctl start argo-cloudflared.service argo-core.service
            fi
            clear
            ;;
        3)
            if [ -f /etc/alpine-release ]; then
                rc-service argo-cloudflared stop >/dev/null 2>&1
                rc-service argo-core stop >/dev/null 2>&1
            else
                systemctl stop argo-cloudflared.service argo-core.service
            fi
            clear
            ;;
        4)
            if [ -f /etc/alpine-release ]; then
                rc-service argo-cloudflared restart >/dev/null 2>&1
                rc-service argo-core restart >/dev/null 2>&1
            else
                systemctl restart argo-cloudflared.service argo-core.service
            fi
            clear
            ;;
        5)
            if [ -f /etc/alpine-release ]; then
                rc-service argo-cloudflared stop >/dev/null 2>&1
                rc-service argo-core stop >/dev/null 2>&1
                rc-update del argo-cloudflared default
                rc-update del argo-core default
                rm -f /etc/init.d/argo-cloudflared /etc/init.d/argo-core
            else
                systemctl stop argo-cloudflared.service argo-core.service
                systemctl disable argo-cloudflared.service argo-core.service
                rm -f /etc/systemd/system/argo-cloudflared.service /etc/systemd/system/argo-core.service
                systemctl daemon-reload
            fi
            rm -rf /opt/argo /usr/bin/argo ~/.cloudflared
            echo "卸载完成，API Token 请手动删除"
            exit 0
            ;;
        6)
            clear
            cat /opt/argo/v2ray.txt
            ;;
        0)
            echo "退出"
            exit 0
            ;;
    esac
done
MANAGER

    chmod +x /opt/argo/argo-manager.sh
    ln -sf /opt/argo/argo-manager.sh /usr/bin/argo

    clear
    cat /opt/argo/v2ray.txt
    echo -e "\n安装完成！管理命令: argo"
}

# ---------- 主菜单 ----------
while true; do
    clear
    echo "       _       _                              _                "
    echo "      | |     | |       ___   _   _    ___   | |__     ____       "
    echo "    __| |_____| |_     / __| | | | |  / _ \  | |_ \   / _  |   "
    echo "   |__   ______  _|    \__ \ | |_| | | (_) | | | | | | (_| | "
    echo "      | |_    | |_     |___/  \___/   \___/  |_| |_|  \____|"
    echo "       \__|    \__|"
    echo ""
    echo "欢迎使用 Agro 一键脚本"
    echo "-------------------------------------------"
    echo "1. 梭哈模式（无需域名，重启失效）"
    echo "2. 安装服务（需要 CF 域名，重启不失效）"
    echo "3. 卸载服务"
    echo "4. 管理服务"
    echo "5. 清空缓存"
    echo "0. 退出"
    read -p "选择 (默认1): " mode
    mode=${mode:-1}

    if [ "$mode" == "2" ]; then
        if [ -f /usr/bin/argo ]; then
            echo "服务已安装，跳转管理..."
            argo
            continue
        fi
    fi

    if [ "$mode" == "1" ] || [ "$mode" == "2" ]; then
        read -p "选择核心 (1.xray, 2.sing-box, 默认1): " core_choice
        core_choice=${core_choice:-1}
        if [ "$core_choice" == "1" ]; then
            core_type="xray"
        elif [ "$core_choice" == "2" ]; then
            core_type="sing-box"
        else
            echo "核心选择错误"
            read -p "按回车继续..." _
            continue
        fi

        read -p "协议 (1.vmess, 2.vless, 默认1): " protocol
        protocol=${protocol:-1}
        if [ "$protocol" != "1" ] && [ "$protocol" != "2" ]; then
            echo "协议错误"
            read -p "按回车继续..." _
            continue
        fi

        read -p "IP 版本 (4 或 6, 默认4): " ips
        ips=${ips:-4}
        if [ "$ips" != "4" ] && [ "$ips" != "6" ]; then
            echo "IP 版本错误"
            read -p "按回车继续..." _
            continue
        fi

        isp=$(curl -$ips -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18"-"$30}' | sed 's/ /_/g')
    fi

    case $mode in
        1)
            cleanup_process xray; cleanup_process sing-box; cleanup_process cloudflared-linux
            rm -rf xray cloudflared-linux v2ray.txt /tmp/sing-box 2>/dev/null
            quicktunnel
            ;;
        2)
            cleanup_process xray; cleanup_process sing-box; cleanup_process cloudflared-linux
            installtunnel
            ;;
        3)
            if is_alpine; then
                kill -9 $(ps -ef | grep -E "xray|sing-box|cloudflared" | grep -v grep | awk '{print $1}') 2>/dev/null
                pkill -f "argo-cloudflared.start" 2>/dev/null
                pkill -f "argo-core.start" 2>/dev/null
                rm -rf /opt/argo /usr/bin/argo /etc/local.d/argo-*
            else
                systemctl stop argo-cloudflared.service argo-core.service 2>/dev/null
                systemctl disable argo-cloudflared.service argo-core.service 2>/dev/null
                rm -rf /opt/argo /usr/bin/argo /etc/systemd/system/argo-* ~/.cloudflared
                systemctl daemon-reload
            fi
            echo "卸载完成"
            ;;
        4)
            if [ -f /usr/bin/argo ]; then
                argo
            else
                echo "请先安装服务 (模式2)"
            fi
            ;;
        5)
            cleanup_process xray; cleanup_process sing-box; cleanup_process cloudflared-linux
            rm -rf xray cloudflared-linux v2ray.txt
            echo "缓存已清空"
            ;;
        0)
            echo "退出"
            exit 0
            ;;
        *)
            echo "无效输入"
            ;;
    esac

    echo ""
    read -p "按回车返回主菜单..." _
done
