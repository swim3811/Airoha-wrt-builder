#!/bin/sh
# 仅首次运行 Wrt 时执行以下脚本，重启后消失

LOGFILE="/tmp/uci-defaults-log.txt"

echo "========================================" >> "$LOGFILE"
echo "Starting 99-custom.sh at $(date)" >> "$LOGFILE"
echo "========================================" >> "$LOGFILE"

# =========================================================
# 基础设置
# =========================================================

uci -q set system.@system[0].hostname='WRTVERSIONINFO'
uci -q set system.@system[0].timezone='CST-8'
uci -q set system.@system[0].zonename='Asia/Taipei'
uci -q set luci.main.lang='zh_cn'

# =========================================================
# 检测 Ethernet 用户端口
# =========================================================

ifnames=""

for iface in /sys/class/net/*; do
    [ -e "$iface" ] || continue
    iface_name="${iface##*/}"

    case "$iface_name" in
        lo|br-*|wlan*|wl*|phy*)
            continue
            ;;
    esac

    [ -d "$iface/wireless" ] && continue
    [ -d "$iface/phy80211" ] && continue

    [ -e "$iface/device" ] || continue
    dev_target=$(readlink -f "$iface/device" 2>/dev/null)
    [ -n "$dev_target" ] || continue

    echo "$dev_target" | grep -q '/virtual/' && continue

    link_info=$(ip -d link show "$iface_name" 2>/dev/null)

    is_dsa_port=0
    if echo "$link_info" | grep -q 'portname '; then
        is_dsa_port=1
    fi

    if [ "$is_dsa_port" -eq 0 ]; then
        dsa_conduit=0
        for other_iface in /sys/class/net/*; do
            [ -e "$other_iface" ] || continue
            other_name="${other_iface##*/}"
            [ "$other_name" = "$iface_name" ] && continue

            case "$other_name" in
                lo|br-*|wlan*|wl*|phy*)
                    continue
                    ;;
            esac

            other_info=$(ip -d link show "$other_name" 2>/dev/null)
            if echo "$other_info" | grep -q "dsa conduit $iface_name"; then
                dsa_conduit=1
                break
            fi
        done

        if [ "$dsa_conduit" -eq 1 ]; then
            echo "Excluded DSA conduit: $iface_name" >> "$LOGFILE"
            continue
        fi
    fi

    ifnames="${ifnames:+$ifnames }$iface_name"
done

set -- $ifnames
count=$#

echo "Detected Ethernet user ports: $ifnames" >> "$LOGFILE"
echo "Ethernet user port count: $count" >> "$LOGFILE"

# =========================================================
# 网络设置
# =========================================================

if [ "$count" -eq 0 ]; then
    echo "ERROR: No Ethernet user port detected!" >> "$LOGFILE"
elif [ "$count" -eq 1 ]; then
    only_port="$1"
    echo "Single Ethernet user port detected: $only_port" >> "$LOGFILE"
    echo "Configuring LAN as DHCP." >> "$LOGFILE"

    uci -q set network.lan.proto='dhcp'
    uci -q delete network.lan.ipaddr
    uci -q delete network.lan.netmask
    uci -q delete network.lan.gateway
    uci -q delete network.lan.dns
else
    echo "Multiple Ethernet user ports detected." >> "$LOGFILE"
    wan_ifname=""

    configured_wan=$(uci -q get network.wan.device 2>/dev/null)
    if [ -n "$configured_wan" ]; then
        for port in $ifnames; do
            if [ "$port" = "$configured_wan" ]; then
                wan_ifname="$port"
                break
            fi
        done
        [ -n "$wan_ifname" ] && echo "Using existing configured WAN device: $wan_ifname" >> "$LOGFILE"
    fi

    if [ -z "$wan_ifname" ]; then
        for port in $ifnames; do
            if [ "$port" = "wan" ]; then
                wan_ifname="$port"
                echo "Detected standard WAN interface: $wan_ifname" >> "$LOGFILE"
                break
            fi
        done
    fi

    if [ -z "$wan_ifname" ]; then
        wan_ifname="$1"
        echo "WARNING: Cannot determine WAN automatically." >> "$LOGFILE"
        echo "Fallback WAN interface: $wan_ifname" >> "$LOGFILE"
    fi

    lan_ifnames=""
    for port in $ifnames; do
        [ "$port" = "$wan_ifname" ] && continue
        lan_ifnames="${lan_ifnames:+$lan_ifnames }$port"
    done

    echo "WAN interface: $wan_ifname" >> "$LOGFILE"
    echo "LAN interfaces: $lan_ifnames" >> "$LOGFILE"

    uci -q set network.wan=interface
    uci -q set network.wan.device="$wan_ifname"
    uci -q set network.wan.proto='dhcp'
    uci -q set network.wan6=interface
    uci -q set network.wan6.device="$wan_ifname"
    uci -q set network.wan6.proto='dhcpv6'

    section=$(uci show network 2>/dev/null |
        awk -F '[.=]' '/^network\.[^.]+\.name=['"'"'"]br-lan['"'"'"]$/ {print $2; exit}')

    if [ -n "$section" ]; then
        echo "Found br-lan device section: $section" >> "$LOGFILE"
        uci -q delete "network.$section.ports"
        for port in $lan_ifnames; do
            uci -q add_list "network.$section.ports=$port"
        done
        echo "br-lan ports updated: $lan_ifnames" >> "$LOGFILE"
    else
        first_lan_port=$(echo "$lan_ifnames" | awk '{print $1}')
        if [ -n "$first_lan_port" ]; then
            uci -q set network.lan.device="$first_lan_port"
            echo "WARNING: Cannot find br-lan device." >> "$LOGFILE"
            echo "Fallback LAN device: $first_lan_port" >> "$LOGFILE"
        else
            echo "ERROR: No LAN port available!" >> "$LOGFILE"
        fi
    fi

    # LAN 静态 IP (恢复直接写入占位符)
    uci -q set network.lan.proto='static'
    uci -q set network.lan.ipaddr='__IPADDR__'
    uci -q set network.lan.netmask='255.255.255.0'
    echo "LAN IP set to: __IPADDR__/24" >> "$LOGFILE"
fi

uci commit system
uci commit luci
uci commit firewall
uci commit dhcp
uci commit network

if [ -f /etc/banner1/banner ]; then
    cp -f /etc/banner1/banner /etc/
fi
[ -d /etc/banner1 ] && rm -rf /etc/banner1

FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="WRTVERSIONINFO VERXXXX"
if [ -f "$FILE_PATH" ]; then
    sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"
fi

echo "========================================" >> "$LOGFILE"
echo "Final Ethernet ports: $ifnames" >> "$LOGFILE"
echo "Final Ethernet port count: $count" >> "$LOGFILE"
if [ "$count" -gt 1 ]; then
    echo "Final WAN: $wan_ifname" >> "$LOGFILE"
    echo "Final LAN: $lan_ifnames" >> "$LOGFILE"
fi
echo "99-custom.sh completed at $(date)" >> "$LOGFILE"
echo "========================================" >> "$LOGFILE"

uci set network.wan.proto='pppoe'
uci set network.wan.username='77433450@ip.hinet.net'
uci set network.wan.password='myepuhlq'

# ==========================================
# 1. 系統基礎設定 (密碼、語言、時區)
# ==========================================

# --- 設定管理員登入密碼 ---
root_password="gg123456"
(echo "$root_password"; sleep 1; echo "$root_password") | passwd > /dev/null


# 設定系統時區與 NTP 伺服器
uci del system.ntp.enabled
uci del system.ntp.enable_server
uci set system.cfg01e48a.log_proto='udp'
uci set system.cfg01e48a.conloglevel='8'

# ==========================================
# 2. 基礎服務設定 (KMS)
# ==========================================

# VLMCSD (KMS 激活服務)
uci set vlmcsd.config.enabled='1'
uci set vlmcsd.config.auto_activate='1'
uci del vlmcsd.config.internet_access

# Openlist (網盤服務)
uci del openlist.config.site_tls_insecure
uci del openlist.config.log_enable
uci set openlist.config.enabled='1'


# ==========================================
# 3. 基礎網路與 DNS 設定 (包含 IPv6 清理)
# ==========================================

# 防火牆基礎清理與 FullCone 設定
uci del firewall.cfg01e63d.syn_flood
uci set firewall.cfg01e63d.synflood_protect='1'
uci set firewall.cfg01e63d.fullcone6='1'

# 網路介面優化 (WAN/LAN/Docker)
uci del network.wan6
uci del network.wan.auto
uci set network.wan.ipv6='0'
uci set network.wan.sourcefilter='0'
uci set network.wan.delegate='0'

# 設定 WAN6 (IPv6)
uci set network.wan6=interface
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.device='@wan'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
uci set network.wan6.norelease='1'

# 設定 LAN IPv6 分配
uci set network.lan.delegate='0'
uci set network.lan.ip6assign='64'
uci set network.lan.ip6ifaceid='eui64'

# 手動指定 DNS (Cloudflare)
uci del network.wan.dns
uci set network.wan.peerdns='0'
uci add_list network.wan.dns='8.8.8.8'
uci add_list network.wan.dns='8.8.4.4'

uci del network.wan6.dns
uci set network.wan6.peerdns='0'
uci add_list network.wan6.dns='2001:4860:4860::8888'
uci add_list network.wan6.dns='2001:4860:4860::8844'

# ==========================================
# 4. WireGuard VPN 配置
# ==========================================

# 建立 wg0 介面
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key='uFaJylwL7gJ34K1QaUMDhQmXBDBnk7mSinxSLdWUTGg='
uci set network.wg0.listen_port='51820'
uci set network.wg0.mtu='1412'
uci del network.wg0.addresses
uci add_list network.wg0.addresses='10.8.0.1/24'

# 建立 Peer (Hank-Home)
uci -q delete network.wireguard_wg0
uci add network wireguard_wg0
uci set network.@wireguard_wg0[-1].description='Yi-Home'
uci set network.@wireguard_wg0[-1].public_key='+s/Dm1ZgEYBg54wMijVlj01sPGAXNqEoRyAFFDreons='
uci set network.@wireguard_wg0[-1].private_key='qNQwcM0U4jl+fj9JmknaSlCx+YheczkBxx2id9TFE18='
uci set network.@wireguard_wg0[-1].preshared_key='6EYeH3DwN5ucrg9jeXz1LyWdLrB8UWU+XT6c9mwYwvE='
uci add_list network.@wireguard_wg0[-1].allowed_ips='10.8.0.2/24'
uci set network.@wireguard_wg0[-1].route_allowed_ips='1'
uci set network.@wireguard_wg0[-1].persistent_keepalive='25'

# 防火牆：將 wg0 加入 LAN 區域
uci del firewall.cfg02dc81.network
uci add_list firewall.cfg02dc81.network='lan'
uci add_list firewall.cfg02dc81.network='wg0'

# 防火牆：開啟 51820 埠位 (Wan 存取)
uci -q delete firewall.WireGuard
uci set firewall.WireGuard='rule'
uci set firewall.WireGuard.name='Allow-WireGuard'
uci set firewall.WireGuard.proto='udp'
uci set firewall.WireGuard.src='wan'
uci set firewall.WireGuard.dest_port='51820'
uci set firewall.WireGuard.target='ACCEPT'

uci set firewall.cfg0592bd.enabled='1'
uci set firewall.cfg0692bd.enabled='1'
uci set firewall.cfg0792bd.enabled='1'
uci set firewall.cfg0892bd.enabled='1'
uci set firewall.cfg0992bd.enabled='1'
uci set firewall.cfg0a92bd.enabled='1'
uci set firewall.cfg0b92bd.enabled='1'
uci set firewall.cfg0c92bd.enabled='1'
uci set firewall.cfg0d92bd.enabled='1'
uci set firewall.WireGuard.enabled='1'

uci del network.wan6.reqaddress
uci del network.wan6.reqprefix

uci del dhcp.lan.leasetime
uci del dhcp.lan.start
uci del dhcp.lan.limit
uci del dhcp.lan.ra_slaac
uci del dhcp.lan.dhcpv6

uci del dhcp.odhcpd.maindhcp

uci del dhcp.cfg01411c.nonwildcard
uci del dhcp.cfg01411c.boguspriv
uci del dhcp.cfg01411c.filterwin2k
uci del dhcp.cfg01411c.filter_aaaa
uci del dhcp.cfg01411c.filter_a

# ==========================================
# 5. 遠端管理設定 (安全性強化：僅限 wg0 存取)
# ==========================================

# 設定主 Dropbear (SSH)
uci del dropbear.main.enable
uci del dropbear.main.RootPasswordAuth
uci del dropbear.main.DirectInterface
uci del dropbear.main._direct
uci set dropbear.main.Interface='lan'

# 新增 VPN 專用 SSH
uci add dropbear dropbear # =cfg024dd4
uci set dropbear.@dropbear[-1].Interface='wg0'
uci set dropbear.@dropbear[-1].PasswordAuth='on'

# 移除 ttyd 終端機綁定接口
uci del ttyd.cfg01a8ea.interface

# ==========================================
# 6. DDNS 設定 (Cloudflare)
# ==========================================
uci del ddns.myddns_ipv4
uci del ddns.global.upd_privateip
uci del ddns.global.ddns_dateformat
uci del ddns.global.ddns_loglines
uci set ddns.myddns_ipv6.enabled='0'
uci del ddns.myddns_ipv6

# Cloudflare IPv4 設定
uci set ddns.Cloudflare_IPv4=service
uci set ddns.Cloudflare_IPv4.service_name='cloudflare.com-v4'
uci set ddns.Cloudflare_IPv4.use_ipv6='0'
uci set ddns.Cloudflare_IPv4.enabled='1'
uci set ddns.Cloudflare_IPv4.lookup_host='h.yiqq.eu.org'
uci set ddns.Cloudflare_IPv4.domain='h@yiqq.eu.org'
uci set ddns.Cloudflare_IPv4.username='swim3811@gmail.com'
uci set ddns.Cloudflare_IPv4.password='84ec25ca271a1cbc4044ebdfd1a8106e81b71'
uci set ddns.Cloudflare_IPv4.ip_source='interface'
uci set ddns.Cloudflare_IPv4.interface='wan'

# Cloudflare IPv6 設定
uci set ddns.Cloudflare_IPv6=service
uci set ddns.Cloudflare_IPv6.service_name='cloudflare.com-v4'
uci set ddns.Cloudflare_IPv6.use_ipv6='1'
uci set ddns.Cloudflare_IPv6.enabled='1'
uci set ddns.Cloudflare_IPv6.lookup_host='h.yiqq.eu.org'
uci set ddns.Cloudflare_IPv6.domain='h@yiqq.eu.org'
uci set ddns.Cloudflare_IPv6.username='swim3811@gmail.com'
uci set ddns.Cloudflare_IPv6.password='84ec25ca271a1cbc4044ebdfd1a8106e81b71'
uci set ddns.Cloudflare_IPv6.ip_source='interface'
uci set ddns.Cloudflare_IPv6.interface='wan'

# ==========================================
# 7. 設定 DHCP 固定 IP (Static Leases)
# ==========================================

uci add dhcp host
uci set dhcp.@host[-1].name='H50G-YI'
uci set dhcp.@host[-1].mac='C0:25:2F:9A:6E:CC'
uci set dhcp.@host[-1].ip='192.168.5.71'
uci set dhcp.@host[-1].leasetime='12h'

uci add dhcp host
uci set dhcp.@host[-1].name='H50G-Living'
uci set dhcp.@host[-1].mac='C0:25:2F:9A:6E:90'
uci set dhcp.@host[-1].ip='192.168.5.72'
uci set dhcp.@host[-1].leasetime='12h'

uci add dhcp host
uci set dhcp.@host[-1].name='H50G-Mater'
uci set dhcp.@host[-1].mac='C0:25:2F:9A:6E:64'
uci set dhcp.@host[-1].ip='192.168.5.73'
uci set dhcp.@host[-1].leasetime='12h'

uci add dhcp host
uci set dhcp.@host[-1].name='YiSmall-PC'
uci set dhcp.@host[-1].mac='4C:03:4F:BB:1F:70'
uci set dhcp.@host[-1].ip='192.168.5.61'
uci set dhcp.@host[-1].leasetime='12h'

# ==========================================
# 7. 提交變更並重啟
# ==========================================

uci commit luci
uci commit system
uci commit network
uci commit dhcp
uci commit firewall
uci commit dropbear
uci commit ttyd
uci commit vlmcsd
uci commit openlist
uci commit ddns
/etc/init.d/ddns restart

exit 0
