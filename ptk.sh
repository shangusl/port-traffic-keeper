#!/bin/bash
# ==============================================================
# 端口流量管家 (Port Traffic Keeper) v1.3.9
# 独立的 Linux 端口流量监控/管理脚本（参考"端口流量狗"，重写数据层）
#
# 核心设计：磁盘 JSON 是数据本体，nftables 计数器只是增量采集器
#   - 每分钟 cron 采集增量并原子落盘，重启/断电最多丢 1 分钟数据
#   - 计数器被清零(重启/flush)时增量逻辑自动兼容，规则自动重建
#   - 配额判断直接对比"落盘总账 vs 限额"：调低限额立即生效阻断
#     (修复原版 nft quota 对象换新后从 0 重计、超限却不封的问题)
#
# 功能：端口/端口段监控 | 单双向统计 | 月度配额+超限阻断+自动重置
#       tc 带宽限速(出站) | 备注增改删 | Telegram + 企业微信通知
#       导出/导入 | 从"端口流量狗"一键迁移 | 重置历史 | 开机自愈 | 一键更新
#
# 快捷命令: ptk        定时入口: ptk --tick (自动配置)
# ==============================================================

set -u

readonly VERSION="1.3.9"
readonly INSTALL_PATH="/usr/local/bin/port-traffic-keeper.sh"
readonly SHORTCUT="ptk"
readonly CONF_DIR="/etc/port-traffic-keeper"
readonly CONF="$CONF_DIR/config.json"
readonly STATE="$CONF_DIR/state.json"
readonly HIST="$CONF_DIR/history.log"
readonly NLOG="$CONF_DIR/notify.log"
readonly LOCK="/var/run/ptk.lock"
readonly TBL="ptk"                     # nftables 表名 (inet family)
readonly SYSTEMD_UNIT="/etc/systemd/system/ptk-save.service"
readonly DOG_CONF="/etc/port-traffic-dog/config.json"
readonly DOG_DATA="/etc/port-traffic-dog/traffic_data.json"

readonly RED='\033[0;31m'; readonly YEL='\033[0;33m'
readonly BLU='\033[0;34m'; readonly GRN='\033[0;32m'; readonly NC='\033[0m'

# ---------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------
bj_date() { TZ='Asia/Shanghai' date "$@"; }

fmt_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if(b>=1099511627776) printf "%.2fTB", b/1099511627776;
        else if(b>=1073741824) printf "%.2fGB", b/1073741824;
        else if(b>=1048576)    printf "%.2fMB", b/1048576;
        else if(b>=1024)       printf "%.2fKB", b/1024;
        else                   printf "%dB", b }'
}

# 100.00GB -> 100GB, 1.50GB -> 1.5GB (用于配额标签的简洁显示)
fmt_bytes_short() {
    fmt_bytes "$1" | sed -E 's/\.00([KMGT]?B)$/\1/; s/([0-9]\.[0-9])0([KMGT]?B)$/\1\2/'
}

# 分钟数 -> 1m/15m/1h/24h 风格
fmt_interval() {
    local m=${1:-60}
    if [ $((m % 1440)) -eq 0 ]; then echo "$((m/1440))d"
    elif [ $((m % 60)) -eq 0 ]; then echo "$((m/60))h"
    else echo "${m}m"; fi
}

notify_log() { echo "$(bj_date '+%F %T') $*" >> "$NLOG"; }

# Telegram legacy Markdown 特殊字符转义 (用于代码块之外的动态内容)
md_escape() { sed -e 's/[_*`[]/\\&/g' <<< "$1"; }

# "100GB"/"1TB"/"500MB"/"2T" -> 字节数; 非法返回 0
parse_size() {
    awk -v s="${1:-}" 'BEGIN{
        s=toupper(s); n=s+0;
        if(n<=0){print 0; exit}
        if(s ~ /[0-9](TB|T)$/)      m=1099511627776;
        else if(s ~ /[0-9](GB|G)$/) m=1073741824;
        else if(s ~ /[0-9](MB|M)$/) m=1048576;
        else {print 0; exit}
        printf "%.0f", n*m }'
}

# "10Mbps"/"500Kbps"/"1Gbps" -> Kbps 整数; 非法返回 0
parse_rate_kbps() {
    awk -v s="${1:-}" 'BEGIN{
        s=toupper(s); n=s+0;
        if(n<=0){print 0; exit}
        if(s ~ /[0-9]KBPS$/)      m=1;
        else if(s ~ /[0-9]MBPS$/) m=1000;
        else if(s ~ /[0-9]GBPS$/) m=1000000;
        else {print 0; exit}
        printf "%.0f", n*m }'
}

fmt_rate() {
    awk -v k="${1:-0}" 'BEGIN{
        if(k>=1000000 && k%1000000==0) printf "%dGbps", k/1000000;
        else if(k>=1000 && k%1000==0)  printf "%dMbps", k/1000;
        else printf "%dKbps", k }'
}

# burst = 速率的 50ms 缓冲, 最小 2×MTU (与原版算法一致)
calc_burst() {
    local k=$1
    local b=$(( k * 1000 / 8 / 20 ))
    [ "$b" -lt 3000 ] && b=3000
    echo "$b"
}

is_range() { [[ "$1" =~ ^[0-9]+-[0-9]+$ ]]; }
safe_name() { echo "${1//-/_}"; }

valid_port_token() {
    local t="$1" a b
    if is_range "$t"; then
        a=${t%-*}; b=${t#*-}
        [ "$a" -ge 1 ] && [ "$a" -le 65535 ] && [ "$b" -ge 1 ] && [ "$b" -le 65535 ] && [ "$a" -lt "$b" ]
    else
        [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le 65535 ]
    fi
}

# 原子写 json:  jset <文件> <jq参数...>
jset() {
    local f="$1"; shift
    (
        flock -w 60 9 || exit 1
        if ! jq -e . "$f" >/dev/null 2>&1; then
            [ -s "$f" ] && cat "$f" > "${f}.corrupt.$(date +%s)" 2>/dev/null
            echo '{}' > "$f"
        fi
        jq "$@" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
    ) 9>>"${LOCK}.json"
}

pause() { echo; read -rp "按回车继续..." _; }

pick_indices() {  # 解析 "1,3,5" 或 all -> 输出选中的端口(每行一个)
    local input="$1" n arr=()
    if [ "$input" = "all" ]; then
        printf '%s\n' "${PORT_LIST[@]}"
        return
    fi
    IFS=',' read -ra arr <<< "$input"
    for n in "${arr[@]}"; do
        n=$(echo "$n" | tr -d ' ')
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#PORT_LIST[@]} ] \
            && echo "${PORT_LIST[$((n-1))]}"
    done
}

# ---------------------------------------------------------------
# 依赖与安装
# ---------------------------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：需要 root 权限运行${NC}"; exit 1
    fi
}

check_deps() {
    local need=() t
    for t in nft tc jq curl crontab; do
        command -v "$t" >/dev/null 2>&1 || need+=("$t")
    done
    [ ${#need[@]} -eq 0 ] && return 0
    echo -e "${YEL}正在安装缺少的依赖: ${need[*]}${NC}"
    local pkg="apt-get"; command -v apt >/dev/null 2>&1 && pkg="apt"
    $pkg update -qq >/dev/null 2>&1 || true
    for t in "${need[@]}"; do
        case "$t" in
            nft)     $pkg install -y nftables >/dev/null 2>&1 ;;
            tc)      $pkg install -y iproute2 >/dev/null 2>&1 ;;
            crontab) $pkg install -y cron >/dev/null 2>&1
                     systemctl enable --now cron >/dev/null 2>&1 || true ;;
            *)       $pkg install -y "$t" >/dev/null 2>&1 ;;
        esac
    done
    for t in nft tc jq curl crontab; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo -e "${RED}依赖 $t 安装失败，请手动安装后重试${NC}"; exit 1
        fi
    done
}

install_self() {
    [ "${PTK_NO_INSTALL:-}" = "1" ] && return 0
    local me; me="$(realpath "$0" 2>/dev/null || echo "$0")"
    if [ "$me" != "$INSTALL_PATH" ] && [ -f "$me" ]; then
        cp -f "$me" "$INSTALL_PATH" && chmod +x "$INSTALL_PATH"
    fi
    if [ ! -f "/usr/local/bin/$SHORTCUT" ]; then
        printf '#!/bin/bash\nexec %s "$@"\n' "$INSTALL_PATH" > "/usr/local/bin/$SHORTCUT"
        chmod +x "/usr/local/bin/$SHORTCUT"
    fi

    # cron: 每分钟采集 + 开机自愈 (幂等) + 自动清理残留的"端口流量狗"任务
    local cur; cur=$(crontab -l 2>/dev/null || true)
    if ! echo "$cur" | grep -qF "$INSTALL_PATH --tick" || echo "$cur" | grep -q 'port-traffic-dog.sh'; then
        {
            echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            echo "$cur" | grep -v '^PATH=' | grep -vF "$INSTALL_PATH" | grep -v 'port-traffic-dog.sh' || true
            echo "* * * * * $INSTALL_PATH --tick >/dev/null 2>&1"
            echo "@reboot sleep 15 && $INSTALL_PATH --tick >/dev/null 2>&1"
        } | grep -v '^$' | crontab - 2>/dev/null || true
    fi

    # systemd: 开机自愈 + 关机前最后保存一次 (幂等)
    if [ ! -f "$SYSTEMD_UNIT" ]; then
        cat > "$SYSTEMD_UNIT" << EOF
[Unit]
Description=Port Traffic Keeper (restore on boot, final save on shutdown)
After=network.target nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH --tick
ExecStop=$INSTALL_PATH --tick
TimeoutStartSec=60
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now ptk-save.service >/dev/null 2>&1 || true
    fi
}

init_files() {
    mkdir -p "$CONF_DIR"
    if [ ! -f "$CONF" ]; then
        cat > "$CONF" << 'EOF'
{
  "ports": {},
  "tc_iface": "",
  "tg":    { "enabled": false, "bot_token": "", "chat_id": "", "server_name": "", "interval_min": 60 },
  "wecom": { "enabled": false, "webhook_url": "", "server_name": "", "interval_min": 60 }
}
EOF
    fi
    [ -f "$STATE" ] || echo '{}' > "$STATE"
    touch "$HIST" "$NLOG"
}

ensure_state() {
    if [ ! -s "$STATE" ] || ! jq -e . "$STATE" >/dev/null 2>&1; then
        [ -s "$STATE" ] && cp -f "$STATE" "${STATE}.corrupt.$(date +%s)" 2>/dev/null || true
        echo '{}' > "$STATE"
    fi
}

# ---------------------------------------------------------------
# nftables 层
# ---------------------------------------------------------------
nft_ensure_base() {
    if ! nft list table inet $TBL >/dev/null 2>&1; then
        nft add table inet $TBL
        nft add chain inet $TBL input  '{ type filter hook input  priority 0 ; policy accept ; }'
        nft add chain inet $TBL output '{ type filter hook output priority 0 ; policy accept ; }'
        nft add chain inet $TBL block_in  '{ type filter hook input  priority -10 ; policy accept ; }'
        nft add chain inet $TBL block_out '{ type filter hook output priority -10 ; policy accept ; }'
    fi
}

nft_ensure_port() {
    local p="$1" s; s=$(safe_name "$p")
    nft list counter inet $TBL "c_${s}_in"  >/dev/null 2>&1 || nft add counter inet $TBL "c_${s}_in"
    nft list counter inet $TBL "c_${s}_out" >/dev/null 2>&1 || nft add counter inet $TBL "c_${s}_out"
    if ! nft list chain inet $TBL input 2>/dev/null | grep -q "\"c_${s}_in\""; then
        nft add rule inet $TBL input tcp dport "$p" counter name "c_${s}_in"  2>/dev/null || true
        nft add rule inet $TBL input udp dport "$p" counter name "c_${s}_in"  2>/dev/null || true
    fi
    if ! nft list chain inet $TBL output 2>/dev/null | grep -q "\"c_${s}_out\""; then
        nft add rule inet $TBL output tcp sport "$p" counter name "c_${s}_out" 2>/dev/null || true
        nft add rule inet $TBL output udp sport "$p" counter name "c_${s}_out" 2>/dev/null || true
    fi
}

nft_read_counter() {  # -> "in out"
    local s cin cout; s=$(safe_name "$1")
    local raw_in raw_out
    raw_in=$(nft list counter inet $TBL "c_${s}_in" 2>/dev/null) || { echo "0 0"; return; }
    cin=$(echo "$raw_in" | grep -oE 'bytes [0-9]+' | awk '{print $2}')
    raw_out=$(nft list counter inet $TBL "c_${s}_out" 2>/dev/null) || { echo "0 0"; return; }
    cout=$(echo "$raw_out" | grep -oE 'bytes [0-9]+' | awk '{print $2}')
    echo "${cin:-0} ${cout:-0}"
}

nft_delete_port() {
    local p="$1" s chain h; s=$(safe_name "$p")
    for chain in input output; do
        while read -r h; do
            [ -n "$h" ] && nft delete rule inet $TBL "$chain" handle "$h" 2>/dev/null || true
        done < <(nft -a list chain inet $TBL "$chain" 2>/dev/null \
                 | grep -E "\"c_${s}_(in|out)\"|ptk_mark_${s}\"" \
                 | grep -oE 'handle [0-9]+' | awk '{print $2}')
    done
    nft delete counter inet $TBL "c_${s}_in"  2>/dev/null || true
    nft delete counter inet $TBL "c_${s}_out" 2>/dev/null || true
}

# 按 state 中的 blocked 标记重建阻断链（幂等）
# 注意：必须以 CONF 的端口列表为准逐个查询,不能对 STATE 做 to_entries 遍历——
# STATE 中存在 tg_last_sent 等数字类型的键,jq 对数字取 .blocked 会中途报错终止,
# 导致排在其后的端口永远加不上 drop 规则(显示已阻断但实际可用)
nft_rebuild_blocks() {
    nft flush chain inet $TBL block_in  2>/dev/null || true
    nft flush chain inet $TBL block_out 2>/dev/null || true
    local p
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        nft add rule inet $TBL block_in  tcp dport "$p" drop 2>/dev/null || true
        nft add rule inet $TBL block_in  udp dport "$p" drop 2>/dev/null || true
        nft add rule inet $TBL block_out tcp sport "$p" drop 2>/dev/null || true
        nft add rule inet $TBL block_out udp sport "$p" drop 2>/dev/null || true
    done < <(jq -r --slurpfile conf "$CONF" '
        $conf[0].ports as $ports |
        to_entries[] | select((.value | type == "object") and .value.blocked == true and ($ports[.key] != null)) | .key
    ' "$STATE" 2>/dev/null)
}

# ---------------------------------------------------------------
# tc 带宽限速层 (出站方向, 与原版一致)
# ---------------------------------------------------------------
get_iface() {
    local i; i=$(jq -r '.tc_iface // ""' "$CONF" 2>/dev/null)
    if [ -n "$i" ]; then echo "$i"; return; fi
    ip route 2>/dev/null | awk '/^default/ {print $5; exit}'
}

alloc_tc_id() {  # 为端口分配唯一 tc id (同时用作 fwmark), 持久保存
    local p="$1" id
    id=$(jq -r --arg p "$p" '.ports[$p].tc_id // 0' "$CONF")
    if ! [ "$id" -gt 0 ] 2>/dev/null; then
        id=$(jq -r '([.ports[].tc_id // 0] | max // 9) + 1' "$CONF")
        [ "$id" -lt 10 ] 2>/dev/null && id=10
        jset "$CONF" --arg p "$p" --argjson i "$id" '.ports[$p].tc_id = $i'
    fi
    echo "$id"
}

tc_remove_port() {
    local p="$1" iface id hexid s h
    iface=$(get_iface); [ -n "$iface" ] || return 0
    id=$(jq -r --arg p "$p" '.ports[$p].tc_id // 0' "$CONF")
    s=$(safe_name "$p")
    if [ "$id" -gt 0 ] 2>/dev/null; then
        hexid=$(printf '%x' "$id")
        tc filter del dev "$iface" parent 1: protocol ip   prio 1 handle "$id" fw 2>/dev/null || true
        tc filter del dev "$iface" parent 1: protocol ipv6 prio 2 handle "$id" fw 2>/dev/null || true
        tc class  del dev "$iface" classid "1:$hexid" 2>/dev/null || true
    fi
    while read -r h; do
        [ -n "$h" ] && nft delete rule inet $TBL output handle "$h" 2>/dev/null || true
    done < <(nft -a list chain inet $TBL output 2>/dev/null | grep "ptk_mark_${s}\"" \
             | grep -oE 'handle [0-9]+' | awk '{print $2}')
}

# 确保所有限速配置生效（幂等自愈, tick 内调用可应对重启后 tc 丢失）
tc_ensure_all() {
    local iface; iface=$(get_iface); [ -n "$iface" ] || return 0
    local rate_data
    rate_data=$(jq -r '.ports | to_entries | map(select((.value.rate_kbps // 0) > 0 and (.value.tc_id // 0) > 0) | "\(.key) \(.value.rate_kbps) \(.value.tc_id)") | .[]' "$CONF" 2>/dev/null)
    
    if [ -z "$rate_data" ]; then
        if grep -q '"tc_root_owned": true' "$STATE" 2>/dev/null && \
           tc qdisc show dev "$iface" 2>/dev/null | grep -q "htb 1:"; then
            tc qdisc del dev "$iface" root 2>/dev/null || true
            jset "$STATE" '.tc_root_owned = false'
        fi
        return 0
    fi
    
    if ! tc qdisc show dev "$iface" 2>/dev/null | grep -q "htb 1:"; then
        tc qdisc replace dev "$iface" root handle 1: htb 2>/dev/null || true
        jset "$STATE" '.tc_root_owned = true'
    fi

    local filters out_rules p kbps id hexid burst s
    filters=$(tc filter show dev "$iface" 2>/dev/null || true)
    out_rules=$(nft list chain inet $TBL output 2>/dev/null || true)
    
    while IFS=' ' read -r p kbps id; do
        [ -n "$p" ] || continue
        hexid=$(printf '%x' "$id")
        burst=$(calc_burst "$kbps")
        tc class replace dev "$iface" parent 1: classid "1:$hexid" htb \
            rate "${kbps}kbit" ceil "${kbps}kbit" burst "${burst}b" 2>/dev/null || true
        if ! echo "$filters" | grep -qE "handle 0x0*${hexid}[^0-9a-f]"; then
            tc filter add dev "$iface" parent 1: protocol ip   prio 1 handle "$id" fw classid "1:$hexid" 2>/dev/null || true
            tc filter add dev "$iface" parent 1: protocol ipv6 prio 2 handle "$id" fw classid "1:$hexid" 2>/dev/null || true
        fi
        s=$(safe_name "$p")
        if ! echo "$out_rules" | grep -q "ptk_mark_${s}\""; then
            nft add rule inet $TBL output tcp sport "$p" meta mark set "$id" comment "ptk_mark_${s}" 2>/dev/null || true
            nft add rule inet $TBL output udp sport "$p" meta mark set "$id" comment "ptk_mark_${s}" 2>/dev/null || true
        fi
    done <<< "$rate_data"
}

# ---------------------------------------------------------------
# 数据核心：增量采集 (tick)
# ---------------------------------------------------------------
port_total() {  # 按计费模式计算某端口应计流量
    local p="$1" ti to mode
    ensure_state
    ti=$(jq -r --arg p "$p" '.[$p].total_in  // 0' "$STATE" 2>/dev/null)
    to=$(jq -r --arg p "$p" '.[$p].total_out // 0' "$STATE" 2>/dev/null)
    ti=${ti:-0}; to=${to:-0}
    mode=$(jq -r --arg p "$p" '.ports[$p].billing // "double"' "$CONF" 2>/dev/null)
    if [ "$mode" = "double" ]; then echo $(( (ti + to) * 2 )); else echo "$to"; fi
}

_tick_body() {
    [ -f "$CONF" ] || return 0
    ensure_state
    nft_ensure_base

    local ports=() p
    while IFS= read -r p; do [ -n "$p" ] && ports+=("$p"); done \
        < <(jq -r '.ports | keys[]' "$CONF" 2>/dev/null)
        
    [ ${#ports[@]} -eq 0 ] && return 0

    local now_ym now_day last_dom date_info prev_ym
    date_info=$(bj_date +'%Y-%m %-d')
    now_ym=${date_info% *}
    now_day=${date_info#* }
    last_dom=$(TZ='Asia/Shanghai' date -d "$(bj_date +%Y-%m-01) +1 month -1 day" +%-d)
    prev_ym=$(TZ='Asia/Shanghai' date -d "$(bj_date +%Y-%m-15) -1 month" +%Y-%m)

    local awk_script='
        BEGIN { printf "{" }
        /counter c_/ {
            name = $2; sub(/^c_/, "", name); sub(/\{$/, "", name);
            bytes = "";
            for(i=1;i<=NF;i++) if($i == "bytes") bytes = $(i+1);
            while (bytes == "") {
                if (getline <= 0) break;
                for(i=1;i<=NF;i++) if($i == "bytes") bytes = $(i+1);
                if (/{/ || /}/) break;
            }
            sub(/[^0-9]+/, "", bytes);
            if (bytes != "") {
                if (started) printf ",\n";
                printf "\"%s\": %s", name, bytes;
                started = 1;
            }
        }
        END { printf "}" }
    '

    local counters_json
    counters_json=$(nft list table inet $TBL 2>/dev/null | awk "$awk_script")
    [ -z "$counters_json" ] && counters_json="{}"

    local missing_ports=false
    for p in "${ports[@]}"; do
        local s; s=$(safe_name "$p")
        if [[ ! "$counters_json" =~ \"${s}_in\" ]]; then
            nft_ensure_port "$p"
            missing_ports=true
        fi
    done

    if [ "$missing_ports" = "true" ]; then
        counters_json=$(nft list table inet $TBL 2>/dev/null | awk "$awk_script")
        [ -z "$counters_json" ] && counters_json="{}"
    fi

    local state_old
    state_old=$(cat "$STATE" 2>/dev/null || echo "{}")

    jset "$STATE" --argjson counters "$counters_json" \
       --slurpfile conf "$CONF" \
       --arg now_ym "$now_ym" \
       --arg prev_ym "$prev_ym" \
       --argjson now_day "$now_day" \
       --argjson last_dom "$last_dom" '
      . as $state |
      $conf[0].ports as $ports |
      reduce ($ports | keys[]) as $p (
        $state;
        ($counters[$p + "_in"] // 0) as $ci |
        ($counters[$p + "_out"] // 0) as $co |
        if .[$p] == null then
          .[$p] = {total_in:0, total_out:0, last_in:$ci, last_out:$co, blocked:false, last_reset_ym:""}
        else . end |
        (.[$p].last_in) as $li |
        (.[$p].last_out) as $lo |
        (if $ci >= $li then $ci - $li else $ci end) as $di |
        (if $co >= $lo then $co - $lo else $co end) as $do |
        
        .[$p].total_in += $di |
        .[$p].total_out += $do |
        .[$p].last_in = $ci |
        .[$p].last_out = $co |
        
        ($ports[$p].reset_day // 0) as $rd |
        (if $rd >= 1 then
           (if $rd > $last_dom then $last_dom else $rd end) as $eff |
           if (.[$p].last_reset_ym != $now_ym) and 
              ( ($now_day >= $eff) or (.[$p].last_reset_ym != $prev_ym and .[$p].last_reset_ym != "") ) then
             .[$p].total_in = 0 |
             .[$p].total_out = 0 |
             .[$p].last_reset_ym = $now_ym
           else . end
         else . end) |
         
        ($ports[$p].quota_bytes // 0) as $quota |
        ($ports[$p].billing // "double") as $mode |
        (if $mode == "double" then (.[$p].total_in + .[$p].total_out) * 2 else .[$p].total_out end) as $used |
        
        if $quota > 0 then
           if $used >= $quota then .[$p].blocked = true else .[$p].blocked = false end
        else
           .[$p].blocked = false
        end
      )
    '

    local state_new
    state_new=$(cat "$STATE" 2>/dev/null || echo "{}")

    # Batched diff checking
    local diffs
    diffs=$(jq -n -r --argjson old "$state_old" --argjson new "$state_new" --arg ym "$now_ym" '
        ($new | to_entries | map(select(.value | type == "object") | .key as $p | if (.value.last_reset_ym == $ym) and ($old[$p].last_reset_ym != $ym) and ($old[$p].last_reset_ym != null) then $p else empty end) | join(" ")) as $reset |
        ($new | to_entries | map(select(.value | type == "object") | .key as $p | if (.value.blocked != $old[$p].blocked) and ($old[$p].blocked != null) then $p else empty end) | join(" ")) as $changed |
        ([ $new | to_entries[] | select((.value | type == "object") and .value.blocked == true) | .key | tostring ] | sort | join(" ")) as $expected |
        "\($reset)|\($changed)|\($expected)"
    ')
    local reset_ports changed_blocks expected_blocks
    IFS='|' read -r reset_ports changed_blocks expected_blocks <<< "$diffs"

    for p in $reset_ports; do
        echo "$(bj_date '+%F %T') 端口 $p 月度自动重置" >> "$HIST"
    done

    for p in $changed_blocks; do
        if [[ " $expected_blocks " =~ " $p " ]]; then
            echo "$(bj_date '+%F %T') 端口 $p 流量超限已阻断" >> "$HIST"
        else
            echo "$(bj_date '+%F %T') 端口 $p 用量低于配额，解除阻断" >> "$HIST"
        fi
    done

    # Only check real blocks if there are expected blocks OR if there are changed blocks
    if [ -n "$expected_blocks" ] || [ -n "$changed_blocks" ]; then
        local real_blocks
        real_blocks=$(nft list chain inet $TBL block_in 2>/dev/null | grep -oE 'dport [0-9]+' | awk '{print $2}' | sort -n | tr '\n' ' ')
        if [ "$real_blocks" != "$expected_blocks" ]; then
            nft_rebuild_blocks
        fi
    fi

    tc_ensure_all

    # 日志轮转
    local lf
    for lf in "$HIST" "$NLOG"; do
        if [ -f "$lf" ]; then
            local lines
            lines=$(wc -l < "$lf" 2>/dev/null || echo 0)
            if [ "$lines" -gt 1000 ]; then
                tail -500 "$lf" > "$lf.tmp" && mv "$lf.tmp" "$lf"
            fi
        fi
    done

    # Batch notification checks
    local notif_conf tg_on tg_itv wecom_on wecom_itv
    notif_conf=$(jq -r '.tg.enabled, (.tg.interval_min // 60), .wecom.enabled, (.wecom.interval_min // 60)' "$CONF" 2>/dev/null)
    { read -r tg_on; read -r tg_itv; read -r wecom_on; read -r wecom_itv; } <<< "$notif_conf"
    
    local now
    now=$(date +%s)
    
    if [ "$tg_on" = "true" ]; then
        local tg_last
        tg_last=$(jq -r '.tg_last_sent // 0' "$STATE" 2>/dev/null)
        if [ $(( now / 60 - tg_last / 60 )) -ge "$tg_itv" ]; then
            if tg_send "$(build_status_message tg)"; then
                jset "$STATE" --argjson t "$now" '.tg_last_sent = $t'
            fi
        fi
    fi

    if [ "$wecom_on" = "true" ]; then
        local wecom_last
        wecom_last=$(jq -r '.wecom_last_sent // 0' "$STATE" 2>/dev/null)
        if [ $(( now / 60 - wecom_last / 60 )) -ge "$wecom_itv" ]; then
            if wecom_send "$(build_status_message wecom)"; then
                jset "$STATE" --argjson t "$now" '.wecom_last_sent = $t'
            fi
        fi
    fi
}

# do_tick = 带锁的采集入口：子shell内短暂持锁，执行完即释放。
# 菜单/状态查询都经由此函数，不再出现"菜单开着就长期占锁、cron全被跳过"的问题
do_tick() {
    ( flock -w 60 8 || exit 0; _tick_body ) 8>>"$LOCK"
}

# 重置某端口：写历史 + 清零累计 + 基线校准 + 解除阻断（纯软重置，不动内核计数器）
archive_and_zero() {
    local p="$1" reason="$2" ti to total
    ti=$(jq -r --arg p "$p" '.[$p].total_in  // 0' "$STATE")
    to=$(jq -r --arg p "$p" '.[$p].total_out // 0' "$STATE")
    total=$(port_total "$p")
    echo "$(bj_date '+%F %T') 端口 $p $reason | 周期流量 $(fmt_bytes "$total") (入 $(fmt_bytes "$ti") / 出 $(fmt_bytes "$to"))" >> "$HIST"
    local cur ci co
    cur=$(nft_read_counter "$p"); ci=${cur% *}; co=${cur#* }
    jset "$STATE" --arg p "$p" --argjson ci "$ci" --argjson co "$co" \
        '.[$p].total_in = 0 | .[$p].total_out = 0 | .[$p].last_in = $ci | .[$p].last_out = $co | .[$p].blocked = false'
}

# ---------------------------------------------------------------
# 通知层 (Telegram + 企业微信, 独立开关与间隔)
# ---------------------------------------------------------------
tg_send() {
    local msg="$1" label="${2:-状态通知}" token chat resp
    token=$(jq -r '.tg.bot_token // ""' "$CONF")
    chat=$(jq -r '.tg.chat_id // ""' "$CONF")
    [ -n "$token" ] && [ -n "$chat" ] || return 1
    resp=$(curl -s --connect-timeout 5 --max-time 10 \
        "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat}" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "text=${msg}" 2>/dev/null)
    if echo "$resp" | grep -q '"ok":true'; then
        notify_log "[Telegram] 发送成功: $label"
        return 0
    fi
    # Markdown 解析失败(如内容含特殊字符)时降级为纯文本重发，通知绝不静默丢失
    resp=$(curl -s --connect-timeout 5 --max-time 10 \
        "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat}" \
        --data-urlencode "text=${msg}" 2>/dev/null)
    if echo "$resp" | grep -q '"ok":true'; then
        notify_log "[Telegram] 发送成功(纯文本降级): $label"
        return 0
    else
        notify_log "[Telegram] 发送失败: $label ${resp:0:120}"
        return 1
    fi
}

wecom_send() {
    local msg="$1" label="${2:-状态通知}" url payload resp
    url=$(jq -r '.wecom.webhook_url // ""' "$CONF")
    [ -n "$url" ] || return 1
    payload=$(jq -n --arg m "$msg" '{msgtype:"text", text:{content:$m}}')
    resp=$(curl -s --connect-timeout 5 --max-time 10 \
        -H 'Content-Type: application/json' -d "$payload" "$url" 2>/dev/null)
    if echo "$resp" | grep -q '"errcode":0'; then
        notify_log "[企业微信] 发送成功: $label"
        return 0
    else
        notify_log "[企业微信] 发送失败: $label ${resp:0:120}"
        return 1
    fi
}



build_status_message() {
    local ch="${1:-tg}" name total_all=0 pc=0 p line=""
    local now_day now_month
    now_day=$(bj_date +%-d); now_month=$(bj_date +%-m)
    name=$(jq -r ".${ch}.server_name // \"\"" "$CONF")
    [ -n "$name" ] || name=$(hostname)
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        pc=$((pc + 1))
        local ti to tt remark quota rate mode tag=""
        ti=$(jq -r --arg p "$p" '.[$p].total_in  // 0' "$STATE")
        to=$(jq -r --arg p "$p" '.[$p].total_out // 0' "$STATE")
        tt=$(port_total "$p")
        total_all=$((total_all + tt))
        mode=$(jq -r --arg p "$p" '.ports[$p].billing // "double"' "$CONF")
        if [ "$mode" = "double" ]; then ti=$((ti*2)); to=$((to*2)); fi
        remark=$(jq -r --arg p "$p" '.ports[$p].remark // ""' "$CONF")
        quota=$(jq -r --arg p "$p" '.ports[$p].quota_bytes // 0' "$CONF")
        rate=$(jq -r --arg p "$p" '.ports[$p].rate_kbps // 0' "$CONF")
        local mode_cn="双向"; [ "$mode" = "single" ] && mode_cn="单向"
        [ -n "$remark" ] && tag="${tag}[备注:$remark]"
        if [ "$quota" -gt 0 ] 2>/dev/null; then
            local pct rd
            pct=$((tt * 100 / quota))
            rd=$(jq -r --arg p "$p" '.ports[$p].reset_day // 0' "$CONF")
            tag="${tag}[${mode_cn}$(fmt_bytes_short "$quota") 已用${pct}%]"
            if [ "$rd" -ge 1 ] 2>/dev/null; then
                local nm=$now_month
                if [ "$now_day" -ge "$rd" ]; then
                    nm=$((now_month + 1)); [ $nm -gt 12 ] && nm=1
                fi
                tag="${tag}[${nm}月${rd}日重置]"
            fi
            [ "$pct" -ge 100 ] && tag="${tag}[已超限]"
            [ "$(jq -r --arg p "$p" '.[$p].blocked // false' "$STATE")" = "true" ] && tag="${tag}[已阻断]"
        else
            tag="${tag}[${mode_cn}无限制]"
        fi
        [ "$rate" -gt 0 ] 2>/dev/null && tag="${tag}[限制带宽$(fmt_rate "$rate")]"
        line="${line}端口:${p} | 总流量:$(fmt_bytes "$tt") | 上行(入站): $(fmt_bytes "$ti") | 下行(出站):$(fmt_bytes "$to") | ${tag}
"
    done < <(jq -r '.ports | keys[]' "$CONF" 2>/dev/null | sort -n)
    if [ "$ch" = "tg" ]; then
        # Telegram: 排版与原版对齐——状态行下细分隔线、代码块内先空一行再列端口、块后分隔线
        printf '🐾 端口流量管家 v%s | ⏰ %s
每一字节都记在账上 | 快捷命令: %s
---
状态: 监控中 | 守护端口: %d个 | 端口总流量: %s
──────────────────────────
```

%s```
──────────────────────────
🔗 服务器: %s' \
            "$VERSION" "$(bj_date '+%F %T')" "$SHORTCUT" \
            "$pc" "$(fmt_bytes "$total_all")" "$line" "$(md_escape "$name")"
    else
        printf '🐾 端口流量管家 v%s | ⏰ %s
每一字节都记在账上 | 快捷命令: %s
---
状态: 监控中 | 守护端口: %d个 | 端口总流量: %s
──────────────────────────

%s──────────────────────────
🔗 服务器: %s' \
            "$VERSION" "$(bj_date '+%F %T')" "$SHORTCUT" \
            "$pc" "$(fmt_bytes "$total_all")" "$line" "$name"
    fi
}

# ---------------------------------------------------------------
# 界面
# ---------------------------------------------------------------
list_ports() {  # 打印端口列表, 填充全局数组 PORT_LIST
    PORT_LIST=()
    local p i=1
    local now_day now_month
    now_day=$(bj_date +%-d); now_month=$(bj_date +%-m)
    
    local port_info
    port_info=$(jq -r --slurpfile state "$STATE" '
        .ports | to_entries | sort_by(.key | tonumber) | .[] | 
        .key as $p |
        ($state[0][$p] // {}) as $s |
        (.value.billing // "double") as $mode |
        ($s.total_in // 0) as $ti |
        ($s.total_out // 0) as $to |
        (if $mode == "double" then ($ti + $to) * 2 else $to end) as $tt |
        "\($p)|\($ti)|\($to)|\($tt)|\(.value.remark // "")|\(.value.quota_bytes // 0)|\(.value.rate_kbps // 0)|\(.value.reset_day // 0)|\($s.blocked // false)|\($mode)"
    ' "$CONF" 2>/dev/null)

    while IFS='|' read -r p ti to tt remark quota rate rd blocked mode; do
        [ -n "$p" ] || continue
        PORT_LIST+=("$p")
        local tags=""
        if [ "$mode" = "double" ]; then ti=$((ti*2)); to=$((to*2)); fi
        [ -n "$remark" ] && tags="${tags}[备注:$remark]"
        local mode_cn="双向"; [ "$mode" = "single" ] && mode_cn="单向"
        if [ "$quota" -gt 0 ] 2>/dev/null; then
            local pct
            pct=$((tt * 100 / quota))
            tags="${tags}[${mode_cn}$(fmt_bytes_short "$quota")]"
            if [ "$rd" -ge 1 ] 2>/dev/null; then
                local nm=$now_month
                if [ "$now_day" -ge "$rd" ]; then
                    nm=$((now_month + 1)); [ $nm -gt 12 ] && nm=1
                fi
                tags="${tags}[${nm}月${rd}日重置]"
            fi
            [ "$pct" -ge 100 ] && tags="${tags}[已超限]"
            [ "$blocked" = "true" ] && tags="${tags}${RED}[已阻断]${NC}${YEL}"
        else
            tags="${tags}[${mode_cn}无限制]"
        fi
        [ "$rate" -gt 0 ] 2>/dev/null && tags="${tags}[限制带宽$(fmt_rate "$rate")]"
        echo -e "$i. 端口:${GRN}$p${NC} | 总流量:${GRN}$(fmt_bytes "$tt")${NC} | 上行(入站): ${GRN}$(fmt_bytes "$ti")${NC} | 下行(出站):${GRN}$(fmt_bytes "$to")${NC} | ${YEL}$tags${NC}"
        i=$((i+1))
    done <<< "$port_info"
    [ ${#PORT_LIST[@]} -gt 0 ]
}

pick_port() {
    local n
    read -rp "请选择端口序号: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#PORT_LIST[@]} ]; then
        echo "${PORT_LIST[$((n-1))]}"
    fi
}

menu_add_ports() {
    echo -e "${BLU}=== 添加端口监控 ===${NC}"
    echo "当前监听端口概览:"
    ss -tulnp 2>/dev/null | awk 'NR>1 {split($5,a,":"); prog=$7; gsub(/.*"/,"",prog); gsub(/".*/,"",prog); if(a[length(a)]!="") print a[length(a)], prog}' \
        | sort -un | head -20 | awk '{printf "  %-8s %s\n", $1, $2}' || true
    echo
    read -rp "输入端口(逗号分隔, 端口段用 - 如 100-200): " input
    local tokens=() t
    IFS=',' read -ra tokens <<< "$input"
    local added=()
    for t in "${tokens[@]}"; do
        t=$(echo "$t" | tr -d ' ')
        [ -z "$t" ] && continue
        if ! valid_port_token "$t"; then
            echo -e "${RED}无效端口: $t (跳过)${NC}"; continue
        fi
        if jq -e --arg p "$t" '.ports[$p]' "$CONF" >/dev/null 2>&1; then
            echo -e "${YEL}端口 $t 已在监控中 (跳过)${NC}"; continue
        fi
        added+=("$t")
    done
    [ ${#added[@]} -eq 0 ] && { echo "没有可添加的端口"; pause; return; }

    echo; echo "统计模式: 1.双向 总流量=(入+出)×2 (与原版一致,匹配中转机账单)  2.单向 仅统计出站"
    read -rp "选择(回车默认1): " m
    local billing="double"; [ "$m" = "2" ] && billing="single"

    read -rp "月度流量配额(如 100GB/1TB, 0=不限, 回车默认0): " q
    local qb=0
    if [ -n "$q" ] && [ "$q" != "0" ]; then
        qb=$(parse_size "$q")
        [ "$qb" -eq 0 ] && echo -e "${YEL}配额格式无效，按不限处理${NC}"
    fi
    local rd=0
    if [ "$qb" -gt 0 ]; then
        read -rp "每月自动重置日(1-31, 回车默认1, 0=不自动重置): " rd
        rd=${rd:-1}
        [[ "$rd" =~ ^[0-9]+$ ]] && [ "$rd" -le 31 ] || rd=1
    fi
    read -rp "带宽限速(如 10Mbps/500Kbps, 0=不限, 回车默认0): " rt
    local kbps=0
    if [ -n "$rt" ] && [ "$rt" != "0" ]; then
        kbps=$(parse_rate_kbps "$rt")
        [ "$kbps" -eq 0 ] && echo -e "${YEL}限速格式无效，按不限处理${NC}"
    fi
    read -rp "备注(可留空, 稍后可改): " remark

    local now_ym now_day
    now_ym=$(bj_date +%Y-%m); now_day=$(bj_date +%-d)
    ( flock -w 60 8 || exit 1
    for t in "${added[@]}"; do
        jset "$CONF" --arg p "$t" --arg b "$billing" --argjson q "$qb" --argjson r "$rd"              --argjson k "$kbps" --arg rm "$remark"             '.ports[$p] = {billing:$b, quota_bytes:$q, reset_day:$r, rate_kbps:$k, remark:$rm}'
        
        local init_ym="$now_ym"
        if [ "$rd" -ge 1 ] 2>/dev/null && [ "$rd" -gt "$now_day" ]; then
            init_ym=""
        fi
        jset "$STATE" --arg p "$t" --arg ym "$init_ym"             '.[$p] = {total_in:0, total_out:0, last_in:0, last_out:0, blocked:false, last_reset_ym:$ym}'
        nft_ensure_port "$t"
        [ "$kbps" -gt 0 ] && alloc_tc_id "$t" >/dev/null
        echo -e "${GRN}端口 $t 已加入监控${NC}"
    done
    tc_ensure_all
    ) 8>>"$LOCK"
    pause
}

menu_del_ports() {
    echo -e "${BLU}=== 删除端口监控 ===${NC}"
    list_ports || { echo "暂无监控端口"; pause; return; }
    echo
    read -rp "输入要删除的序号(逗号分隔, all=全部): " input
    local targets=() p
    while IFS= read -r p; do [ -n "$p" ] && targets+=("$p"); done < <(pick_indices "$input")
    [ ${#targets[@]} -eq 0 ] && { echo "未选择任何端口"; pause; return; }
    ( flock -w 60 8 || exit 1
    for p in "${targets[@]}"; do
        archive_and_zero "$p" "删除监控(存档)"
        tc_remove_port "$p"
        nft_delete_port "$p"
        jset "$CONF"  --arg p "$p" 'del(.ports[$p])'
        jset "$STATE" --arg p "$p" 'del(.[$p])'
        echo -e "${GRN}已删除端口 $p${NC}"
    done
    nft_rebuild_blocks
    tc_ensure_all
    ) 8>>"$LOCK"
    pause
}

menu_remark() {
    echo -e "${BLU}=== 备注管理 ===${NC}"
    list_ports || { echo "暂无监控端口"; pause; return; }
    echo
    local p; p=$(pick_port)
    [ -z "$p" ] && { echo -e "${RED}无效选择${NC}"; pause; return; }
    local cur; cur=$(jq -r --arg p "$p" '.ports[$p].remark // ""' "$CONF")
    echo "端口 $p 当前备注: ${cur:-（无）}"
    echo "输入新备注 (输入 - 删除备注; 回车保持原样)"
    read -rp "> " r
    if [ -z "$r" ]; then
        echo "已保持原样"
    elif [ "$r" = "-" ]; then
        ( flock -w 60 8 || exit 1; jset "$CONF" --arg p "$p" '.ports[$p].remark = ""'; ) 8>>"$LOCK"
        echo -e "${GRN}已删除端口 $p 的备注${NC}"
    else
        ( flock -w 60 8 || exit 1; jset "$CONF" --arg p "$p" --arg r "$r" '.ports[$p].remark = $r'; ) 8>>"$LOCK"
        echo -e "${GRN}端口 $p 备注已更新为: $r${NC}"
    fi
    pause
}

menu_quota() {
    echo -e "${BLU}=== 配额管理 ===${NC}"
    list_ports || { echo "暂无监控端口"; pause; return; }
    echo
    local p; p=$(pick_port)
    [ -z "$p" ] && { echo -e "${RED}无效选择${NC}"; pause; return; }
    local old_qb old_rd
    old_qb=$(jq -r --arg p "$p" '.ports[$p].quota_bytes // 0' "$CONF")
    old_rd=$(jq -r --arg p "$p" '.ports[$p].reset_day // 0' "$CONF")
    
    local old_q_str
    if [ "$old_qb" -eq 0 ]; then old_q_str="无"; else old_q_str=$(fmt_bytes "$old_qb"); fi
    
    read -rp "端口 $p 新配额(原: $old_q_str, 回车保持原样, 0=取消): " q
    local qb="$old_qb"
    if [ -n "$q" ]; then
        if [ "$q" = "0" ]; then
            qb=0
        else
            qb=$(parse_size "$q")
            [ "$qb" -eq 0 ] && { echo -e "${RED}格式无效${NC}"; pause; return; }
        fi
    fi
    
    local rd="$old_rd"
    if [ "$qb" -gt 0 ]; then
        local old_rd_str="$old_rd"
        [ "$old_rd" -eq 0 ] && old_rd_str="不自动"
        read -rp "每月自动重置日(1-31, 原: $old_rd_str, 回车保持原样, 0=不自动): " input_rd
        if [ -n "$input_rd" ]; then
            rd="$input_rd"
            [[ "$rd" =~ ^[0-9]+$ ]] && [ "$rd" -le 31 ] || rd=1
        fi
    else
        rd=0
    fi
    ( flock -w 60 8 || exit 1
    jset "$CONF" --arg p "$p" --argjson q "$qb" --argjson r "$rd" \
        '.ports[$p].quota_bytes = $q | .ports[$p].reset_day = $r'
    
    local now_ym now_day cur_ym
    now_ym=$(bj_date +%Y-%m)
    now_day=$(bj_date +%-d)
    cur_ym=$(jq -r --arg p "$p" '.[$p].last_reset_ym // ""' "$STATE")
    if [ "$rd" -gt 0 ] && [ "$rd" -gt "$now_day" ] && [ "$cur_ym" = "$now_ym" ]; then
        jset "$STATE" --arg p "$p" '.[$p].last_reset_ym = ""'
    fi
    ) 8>>"$LOCK"
    # 立即重算：调低配额低于已用量时当场阻断
    do_tick
    local used blocked
    used=$(port_total "$p")
    blocked=$(jq -r --arg p "$p" '.[$p].blocked // false' "$STATE")
    echo -e "${GRN}已更新${NC} 当前已用 $(fmt_bytes "$used")$( [ "$blocked" = "true" ] && echo -e " ${RED}[已触发阻断]${NC}" )"
    pause
}

menu_rate() {
    echo -e "${BLU}=== 带宽限速管理 (出站方向) ===${NC}"
    echo -e "限速网卡: ${GRN}$(get_iface)${NC} (可在 $CONF 的 tc_iface 字段指定)"
    list_ports || { echo "暂无监控端口"; pause; return; }
    echo
    local p; p=$(pick_port)
    [ -z "$p" ] && { echo -e "${RED}无效选择${NC}"; pause; return; }
    local old_kbps old_kbps_str
    old_kbps=$(jq -r --arg p "$p" '.ports[$p].rate_kbps // 0' "$CONF")
    if [ "$old_kbps" -eq 0 ]; then old_kbps_str="无"; else old_kbps_str=$(fmt_rate "$old_kbps"); fi
    read -rp "端口 $p 新限速(原: $old_kbps_str, 回车保持原样, 0=取消): " rt
    local kbps="$old_kbps"
    if [ -n "$rt" ]; then
        if [ "$rt" = "0" ]; then
            kbps=0
        else
            kbps=$(parse_rate_kbps "$rt")
            [ "$kbps" -eq 0 ] && { echo -e "${RED}格式无效${NC}"; pause; return; }
        fi
    fi
    if [ "$kbps" -eq 0 ]; then
        ( flock -w 60 8 || exit 1
        tc_remove_port "$p"
        jset "$CONF" --arg p "$p" '.ports[$p].rate_kbps = 0'
        ) 8>>"$LOCK"
        echo -e "${GRN}端口 $p 已取消限速${NC}"
    else
        ( flock -w 60 8 || exit 1
        jset "$CONF" --arg p "$p" --argjson k "$kbps" '.ports[$p].rate_kbps = $k'
        alloc_tc_id "$p" >/dev/null
        ) 8>>"$LOCK"
        echo -e "${GRN}端口 $p 限速已设为 $(fmt_rate "$kbps") (burst $(fmt_bytes "$(calc_burst "$kbps")"))${NC}"
    fi
    ( flock -w 60 8 || exit 1; tc_ensure_all; ) 8>>"$LOCK"
    pause
}

menu_reset() {
    echo -e "${BLU}=== 流量重置 ===${NC}"
    list_ports || { echo "暂无监控端口"; pause; return; }
    echo
    read -rp "输入要重置的序号(逗号分隔, all=全部): " input
    local targets=() p
    while IFS= read -r p; do [ -n "$p" ] && targets+=("$p"); done < <(pick_indices "$input")
    [ ${#targets[@]} -eq 0 ] && { echo "未选择"; pause; return; }
    ( flock -w 60 8 || exit 1
    for p in "${targets[@]}"; do
        archive_and_zero "$p" "手动重置"
        echo -e "${GRN}端口 $p 已重置${NC}"
    done
    nft_rebuild_blocks
    ) 8>>"$LOCK"
    pause
}

menu_history() {
    echo -e "${BLU}=== 最近 20 条历史记录 ===${NC}"
    tail -20 "$HIST" 2>/dev/null || echo "暂无记录"
    pause
}

notify_channel_menu() {  # $1=渠道key(tg/wecom) $2=渠道名 $3=发送函数
    local ch="$1" cname="$2" sender="$3"
    while true; do
        clear 2>/dev/null || true
        local on cfg itv st_on st_cfg
        on=$(jq -r ".${ch}.enabled" "$CONF")
        itv=$(jq -r ".${ch}.interval_min // 60" "$CONF")
        if [ "$ch" = "tg" ]; then
            cfg=$(jq -r '.tg.bot_token // ""' "$CONF")
        else
            cfg=$(jq -r '.wecom.webhook_url // ""' "$CONF")
        fi
        st_on="$([ "$on" = "true" ] && echo -e "${GRN}[开启]${NC}" || echo -e "${YEL}[关闭]${NC}")"
        st_cfg="$([ -n "$cfg" ] && echo "[已配置]" || echo "[未配置]")"
        echo -e "${BLU}=== ${cname}通知配置 ===${NC}"
        echo -e "当前状态: $st_on | $st_cfg | 状态通知: 每$(fmt_interval "$itv")"
        echo
        if [ "$ch" = "tg" ]; then
            echo "1. 配置Bot信息 (Token + Chat ID + 服务器名称)"
        else
            echo "1. 配置Webhook信息 (URL + 服务器名称)"
        fi
        echo "2. 通知设置管理"
        echo "3. 发送测试消息"
        echo "4. 查看通知日志"
        echo "0. 返回上级菜单"
        echo
        read -rp "请选择操作 [0-4]: " s
        case "$s" in
            1)
                if [ "$ch" = "tg" ]; then
                    read -rp "Bot Token: " token
                    read -rp "Chat ID: " chat
                    read -rp "服务器名称(回车用主机名): " name
                    jset "$CONF" --arg t "$token" --arg c "$chat" --arg n "$name" \
                        '.tg.bot_token=$t | .tg.chat_id=$c | .tg.server_name=$n | .tg.enabled=true'
                else
                    read -rp "Webhook URL: " url
                    read -rp "服务器名称(回车用主机名): " name
                    jset "$CONF" --arg u "$url" --arg n "$name" \
                        '.wecom.webhook_url=$u | .wecom.server_name=$n | .wecom.enabled=true'
                fi
                echo -e "${GRN}已保存并开启${NC}"; sleep 1
                ;;
            2) notify_settings_menu "$ch" "$cname" ;;
            3)
                if $sender "$(build_status_message "$ch")" "测试消息"; then
                    echo -e "${GRN}测试消息已发送${NC}"
                else
                    echo -e "${RED}发送失败，请检查配置/网络，详情见通知日志${NC}"
                fi
                pause
                ;;
            4)
                echo -e "${BLU}=== 最近 20 条通知日志 ===${NC}"
                tail -20 "$NLOG" 2>/dev/null || echo "暂无记录"
                pause
                ;;
            0) return ;;
        esac
    done
}

notify_settings_menu() {  # $1=渠道key $2=渠道名
    local ch="$1" cname="$2"
    while true; do
        echo -e "${BLU}=== ${cname}通知设置管理 ===${NC}"
        echo "1. 状态通知间隔"
        echo "2. 开启/关闭切换"
        echo "0. 返回上级菜单"
        echo
        read -rp "请选择操作 [0-2]: " s
        case "$s" in
            1)
                local itv; itv=$(jq -r ".${ch}.interval_min // 60" "$CONF")
                echo -e "${BLU}=== 状态通知间隔设置 ===${NC}"
                echo "当前间隔: $(fmt_interval "$itv")"
                echo
                echo "请选择状态通知发送间隔:"
                echo "1. 1分钟    2. 15分钟   3. 30分钟   4. 1小时"
                echo "5. 2小时    6. 6小时    7. 12小时   8. 24小时"
                read -rp "请选择(回车保持原样) [1-8]: " iv
                local mins="$itv"
                case "$iv" in
                    1) mins=1 ;;    2) mins=15 ;;  3) mins=30 ;;   4) mins=60 ;;
                    5) mins=120 ;;  6) mins=360 ;; 7) mins=720 ;;  8) mins=1440 ;;
                    "") mins="$itv" ;;
                esac
                jset "$CONF" --argjson i "$mins" ".${ch}.interval_min = \$i"
                echo -e "${GRN}状态通知间隔已设置为: $(fmt_interval "$mins")${NC}"
                ;;
            2)
                local on; on=$(jq -r ".${ch}.enabled" "$CONF")
                if [ "$on" = "true" ]; then
                    jset "$CONF" ".${ch}.enabled = false"
                    echo -e "${YEL}${cname}通知已关闭${NC}"
                else
                    jset "$CONF" ".${ch}.enabled = true"
                    echo -e "${GRN}${cname}通知已开启${NC}"
                fi
                ;;
            0) return ;;
        esac
    done
}

menu_notify() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${BLU}=== 通知管理 ===${NC}"
        local tg_on wc_on
        tg_on=$(jq -r '.tg.enabled' "$CONF"); wc_on=$(jq -r '.wecom.enabled' "$CONF")
        echo -e "1. Telegram机器人通知 $([ "$tg_on" = "true" ] && echo -e "${GRN}[开启]${NC}" || echo "[关闭]")"
        echo -e "2. 企业微信机器人通知 $([ "$wc_on" = "true" ] && echo -e "${GRN}[开启]${NC}" || echo "[关闭]")"
        echo "0. 返回主菜单"
        echo
        read -rp "请选择操作 [0-2]: " c
        case "$c" in
            1) notify_channel_menu tg "Telegram" tg_send ;;
            2) notify_channel_menu wecom "企业微信" wecom_send ;;
            0) return ;;
        esac
    done
}

menu_export_import() {
    echo -e "${BLU}=== 导出 / 导入 ===${NC}"
    echo "1. 导出配置与流量数据"
    echo "2. 导入配置与流量数据"
    echo "3. 从\"端口流量狗\"一键迁移"
    echo "0. 返回"
    read -rp "选择: " c
    case "$c" in
        1)
            local f="/root/ptk-backup-$(bj_date +%Y%m%d-%H%M%S).json"
            jq -n --arg v "$VERSION" --slurpfile c "$CONF" --slurpfile s "$STATE" \
                  --arg h "$(tail -200 "$HIST" 2>/dev/null || true)" \
                '{app:"ptk", version:$v, exported:(now|todate), config:$c[0], state:$s[0], history:$h}' > "$f" \
                && echo -e "${GRN}已导出: $f${NC}" \
                || echo -e "${RED}导出失败${NC}"
            ;;
        2)
            read -rp "备份文件路径: " f
            if [ ! -f "$f" ] || ! jq -e '.app == "ptk"' "$f" >/dev/null 2>&1; then
                echo -e "${RED}文件不存在或不是有效的 ptk 备份${NC}"; pause; return
            fi
            ( flock -w 60 8 || exit 1
            jq '.config' "$f" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
            jq '.state'  "$f" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
            jq -r '.history // ""' "$f" >> "$HIST"
            calibrate_baselines
            ) 8>>"$LOCK"
            do_tick
            echo -e "${GRN}导入完成${NC}"
            ;;
        3) migrate_from_dog ;;
    esac
    pause
}

# 导入后基线校准：把 last_in/out 对齐到当前内核计数器，防止产生虚假增量
calibrate_baselines() {
    local p cur ci co
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        nft_ensure_port "$p" 2>/dev/null || true
        cur=$(nft_read_counter "$p"); ci=${cur% *}; co=${cur#* }
        jset "$STATE" --arg p "$p" --argjson ci "$ci" --argjson co "$co" \
            '.[$p].last_in = $ci | .[$p].last_out = $co'
    done < <(jq -r '.ports | keys[]' "$CONF" 2>/dev/null)
}

# 从端口流量狗迁移：端口配置 + 当前已统计流量
migrate_from_dog() {
    if [ ! -f "$DOG_CONF" ]; then
        echo -e "${RED}未找到端口流量狗配置 ($DOG_CONF)${NC}"; return
    fi
    local dog_tbl dog_fam
    dog_tbl=$(jq -r '.nftables.table_name // "port_traffic_monitor"' "$DOG_CONF")
    dog_fam=$(jq -r '.nftables.family // "inet"' "$DOG_CONF")
    local now_ym; now_ym=$(bj_date +%Y-%m)
    local now_day; now_day=$(bj_date +%-d)
    local p count=0
    ( flock -w 60 8 || exit 1
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if jq -e --arg p "$p" '.ports[$p]' "$CONF" >/dev/null 2>&1; then
            echo -e "${YEL}端口 $p 已存在于本脚本，跳过${NC}"; continue
        fi
        local billing quota_str qb rd rate_str kbps remark s ti to
        billing=$(jq -r --arg p "$p" '.ports[$p].billing_mode // "double"' "$DOG_CONF")
        quota_str=$(jq -r --arg p "$p" '.ports[$p].quota.monthly_limit // "unlimited"' "$DOG_CONF")
        qb=0; [ "$quota_str" != "unlimited" ] && qb=$(parse_size "$quota_str")
        rd=$(jq -r --arg p "$p" '.ports[$p].quota.reset_day // 0' "$DOG_CONF")
        [[ "$rd" =~ ^[0-9]+$ ]] || rd=0
        rate_str=$(jq -r --arg p "$p" '.ports[$p].bandwidth_limit.rate // "unlimited"' "$DOG_CONF")
        kbps=0; [ "$rate_str" != "unlimited" ] && kbps=$(parse_rate_kbps "$rate_str")
        remark=$(jq -r --arg p "$p" '.ports[$p].remark // ""' "$DOG_CONF")
        [ "$remark" = "null" ] && remark=""

        # 读取原版当前已统计流量：优先内核计数器，其次其备份文件
        s=$(safe_name "$p")
        ti=$(nft list counter "$dog_fam" "$dog_tbl" "port_${s}_in" 2>/dev/null | grep -oE 'bytes [0-9]+' | awk '{print $2}')
        to=$(nft list counter "$dog_fam" "$dog_tbl" "port_${s}_out" 2>/dev/null | grep -oE 'bytes [0-9]+' | awk '{print $2}')
        if [ -z "${ti:-}" ] && [ -z "${to:-}" ] && [ -f "$DOG_DATA" ]; then
            ti=$(jq -r --arg p "$p" '.[$p].input // 0' "$DOG_DATA" 2>/dev/null)
            to=$(jq -r --arg p "$p" '.[$p].output // 0' "$DOG_DATA" 2>/dev/null)
        fi
        ti=${ti:-0}; to=${to:-0}
        [[ "$ti" =~ ^[0-9]+$ ]] || ti=0
        [[ "$to" =~ ^[0-9]+$ ]] || to=0
        # 原版双向模式的计数器在规则层面已×2，导入时还原为真实字节，
        # 否则本脚本计费层再×2会变成×4
        if [ "$billing" = "double" ]; then
            ti=$((ti / 2)); to=$((to / 2))
        fi

        jset "$CONF" --arg p "$p" --arg b "$billing" --argjson q "$qb" --argjson r "$rd" \
             --argjson k "$kbps" --arg rm "$remark" \
            '.ports[$p] = {billing:$b, quota_bytes:$q, reset_day:$r, rate_kbps:$k, remark:$rm}'
        
        local init_ym="$now_ym"
        if [ "$rd" -ge 1 ] 2>/dev/null && [ "$rd" -gt "$now_day" ]; then
            init_ym=""
        fi
        jset "$STATE" --arg p "$p" --arg ym "$init_ym" --argjson ti "$ti" --argjson to "$to" \
            '.[$p] = {total_in:$ti, total_out:$to, last_in:0, last_out:0, blocked:false, last_reset_ym:$ym}'
        nft_ensure_port "$p"
        [ "$kbps" -gt 0 ] && alloc_tc_id "$p" >/dev/null
        echo -e "${GRN}已迁移端口 $p (入 $(fmt_bytes "$ti") / 出 $(fmt_bytes "$to"))${NC}"
        count=$((count+1))
    done < <(jq -r '.ports | keys[]' "$DOG_CONF" 2>/dev/null)

    if [ "$count" -gt 0 ]; then
        calibrate_baselines
    fi
    ) 8>>"$LOCK"

    if [ "$count" -gt 0 ]; then
        do_tick
        echo
        echo -e "${GRN}迁移完成，共 $count 个端口${NC}"
        echo -e "${YEL}重要：请尽快卸载端口流量狗(原脚本菜单6)，否则它残留的配额阻断/限速规则仍会生效，可能干扰本脚本${NC}"
    else
        echo "没有迁移任何端口"
    fi
}

menu_uninstall() {
    echo -e "${RED}=== 卸载 ===${NC}"
    read -rp "确认卸载？将移除监控规则/限速/定时任务/systemd (yes 确认): " c
    [ "$c" = "yes" ] || { echo "已取消"; pause; return; }
    do_tick 2>/dev/null || true   # 最后存一次
    local iface; iface=$(get_iface)
    if [ -n "$iface" ] && [ "$(jq -r '.tc_root_owned // false' "$STATE" 2>/dev/null)" = "true" ] \
       && tc qdisc show dev "$iface" 2>/dev/null | grep -q "htb 1:"; then
        tc qdisc del dev "$iface" root 2>/dev/null || true
    fi
    nft delete table inet $TBL 2>/dev/null || true
    crontab -l 2>/dev/null | grep -vF "$INSTALL_PATH" | crontab - 2>/dev/null || true
    systemctl disable --now ptk-save.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_UNIT"; systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f "/usr/local/bin/$SHORTCUT"
    read -rp "是否同时删除配置与流量数据? (yes=删除, 回车保留): " d
    if [ "$d" = "yes" ]; then rm -rf "$CONF_DIR"; echo "配置数据已删除"; else echo "配置数据保留在 $CONF_DIR"; fi
    rm -f "$INSTALL_PATH"
    echo -e "${GRN}卸载完成${NC}"
    exit 0
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        do_tick   # 进主界面先采集，保证显示实时数据
        echo -e "${BLU}=== 端口流量管家 v$VERSION ===${NC}"
        echo -e "${GRN}每一字节都记在账上 | 快捷命令: $SHORTCUT${NC}"
        echo
        local _pc _sum
        read -r _pc _sum < <(jq -r --slurpfile state "$STATE" '
            .ports | to_entries | length as $pc |
            (map(
                .key as $p |
                ($state[0][$p] // {}) as $s |
                (.value.billing // "double") as $mode |
                ($s.total_in // 0) as $ti |
                ($s.total_out // 0) as $to |
                if $mode == "double" then ($ti + $to) * 2 else $to end
            ) | add // 0) as $sum |
            "\($pc) \($sum)"
        ' "$CONF" 2>/dev/null)
        
        echo -e "${GRN}状态: 监控中${NC} | ${BLU}守护端口: ${_pc}个${NC} | ${YEL}端口总流量: $(fmt_bytes "$_sum")${NC}"
        echo "────────────────────────────────────────────────────────"
        if ! list_ports; then
            echo -e "${YEL}暂无监控端口${NC}"
        fi
        echo "────────────────────────────────────────────────────────"
        echo -e "${BLU}1.${NC} 添加端口监控      ${BLU}2.${NC} 删除端口监控"
        echo -e "${BLU}3.${NC} 备注管理(增改删)  ${BLU}4.${NC} 配额管理"
        echo -e "${BLU}5.${NC} 带宽限速管理      ${BLU}6.${NC} 流量重置"
        echo -e "${BLU}7.${NC} 历史记录          ${BLU}8.${NC} 通知管理(TG/企业微信)"
        echo -e "${BLU}9.${NC} 导出/导入/迁移    ${BLU}10.${NC} 卸载"
        echo -e "${BLU}0.${NC} 退出"
        echo
        read -rp "请选择 [0-10]: " choice
        case "$choice" in
            1) menu_add_ports ;;
            2) menu_del_ports ;;
            3) menu_remark ;;
            4) menu_quota ;;
            5) menu_rate ;;
            6) menu_reset ;;
            7) menu_history ;;
            8) menu_notify ;;
            9) menu_export_import ;;
            10) menu_uninstall ;;
            0) do_tick; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------
# 自动更新 (从 GitHub 获取最新脚本)
# ---------------------------------------------------------------
do_update() {
    local REPO_URL="https://raw.githubusercontent.com/shangusl/port-traffic-keeper/main/ptk.sh"
    
    echo -e "${BLU}正在检查更新并下载最新版本...${NC}"
    
    local tmp_file="/tmp/ptk_update_$$.sh"
    if ! curl -sSL "$REPO_URL" -o "$tmp_file"; then
        echo -e "${RED}下载失败，请检查网络或 URL 是否正确。${NC}"
        rm -f "$tmp_file"
        exit 1
    fi
    
    # 简单的完整性检查
    if ! grep -q "端口流量管家" "$tmp_file"; then
        echo -e "${RED}下载的文件内容似乎不正确，更新终止。${NC}"
        rm -f "$tmp_file"
        exit 1
    fi
    
    # 版本对比检查
    local new_ver; new_ver=$(grep "^readonly VERSION=" "$tmp_file" | cut -d'"' -f2)
    if [ "$new_ver" = "$VERSION" ]; then
        echo -e "${GRN}当前已是最新版本 (v$VERSION)，无需更新。${NC}"
        rm -f "$tmp_file"
        exit 0
    fi

    # 替换当前脚本
    chmod +x "$tmp_file"
    mv -f "$tmp_file" "$INSTALL_PATH"
    
    # 同步刷新定时任务及自启配置
    install_self
    
    echo -e "${GRN}更新成功！当前版本已替换为 GitHub 上的最新版 (v$new_ver)。${NC}"
    echo -e "${YEL}请重新运行 ptk 命令进入主菜单。${NC}"
}

# ---------------------------------------------------------------
# 入口
# ---------------------------------------------------------------
case "${1:-}" in
    --selftest)
        [ "$(fmt_bytes 1073741824)" = "1.00GB" ]        || { echo "fmt_bytes FAIL"; exit 1; }
        [ "$(fmt_bytes 1536)" = "1.50KB" ]              || { echo "fmt_bytes FAIL"; exit 1; }
        [ "$(fmt_bytes 0)" = "0B" ]                     || { echo "fmt_bytes FAIL"; exit 1; }
        [ "$(parse_size 100GB)" = "107374182400" ]      || { echo "parse_size FAIL"; exit 1; }
        [ "$(parse_size 1T)" = "1099511627776" ]        || { echo "parse_size FAIL"; exit 1; }
        [ "$(parse_size 500MB)" = "524288000" ]         || { echo "parse_size FAIL"; exit 1; }
        [ "$(parse_size abc)" = "0" ]                   || { echo "parse_size FAIL"; exit 1; }
        [ "$(parse_rate_kbps 10Mbps)" = "10000" ]       || { echo "parse_rate FAIL"; exit 1; }
        [ "$(parse_rate_kbps 500Kbps)" = "500" ]        || { echo "parse_rate FAIL"; exit 1; }
        [ "$(parse_rate_kbps 1Gbps)" = "1000000" ]      || { echo "parse_rate FAIL"; exit 1; }
        [ "$(parse_rate_kbps xyz)" = "0" ]              || { echo "parse_rate FAIL"; exit 1; }
        [ "$(fmt_rate 10000)" = "10Mbps" ]              || { echo "fmt_rate FAIL"; exit 1; }
        [ "$(fmt_rate 1000000)" = "1Gbps" ]             || { echo "fmt_rate FAIL"; exit 1; }
        [ "$(calc_burst 10000)" = "62500" ]             || { echo "calc_burst FAIL"; exit 1; }
        [ "$(calc_burst 100)" = "3000" ]                || { echo "calc_burst FAIL"; exit 1; }
        valid_port_token 443                            || { echo "valid_port FAIL"; exit 1; }
        valid_port_token 100-200                        || { echo "valid_port FAIL"; exit 1; }
        ! valid_port_token 200-100                      || { echo "valid_port FAIL"; exit 1; }
        ! valid_port_token 70000                        || { echo "valid_port FAIL"; exit 1; }
        [ "$(safe_name 100-200)" = "100_200" ]          || { echo "safe_name FAIL"; exit 1; }
        echo "selftest OK"
        exit 0
        ;;
    --tick)
        check_root
        [ -f "$CONF" ] || exit 0
        # 非阻塞短锁：上一轮还没跑完就跳过本轮，避免任务堆积
        ( flock -n 8 || exit 0; _tick_body ) 8>>"$LOCK"
        exit 0
        ;;
    --status)
        check_root
        [ -f "$CONF" ] || { echo "尚未初始化"; exit 0; }
        do_tick
        list_ports || echo "暂无监控端口"
        exit 0
        ;;
    update)
        check_root
        do_update
        exit 0
        ;;
    "")
        check_root
        check_deps
        init_files
        install_self
        nft_ensure_base
        main_menu
        ;;
    *)
        echo "用法: $0 [--tick|--status|--selftest|update]"
        exit 1
        ;;
esac
