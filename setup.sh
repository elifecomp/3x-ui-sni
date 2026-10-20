
#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}   УНИВЕРСАЛЬНЫЙ АВТОПИЛОТ СЕРВЕРА (BBR + SNI)      ${NC}"
echo -e "${CYAN}====================================================${NC}"

# 1. Определение IP и страны
IP=$(curl -s4m 5 icanhazip.com || curl -s4m 5 ifconfig.me)
COUNTRY=$(curl -s4m 5 "http://ip-api.com/line/${IP}?fields=countryCode" | tr -d '\r')
ISP_INFO=$(curl -s4m 5 "http://ip-api.com/line/${IP}?fields=country,org" | tr '\n' ' ')

echo -e "📍 Внешний IP: ${YELLOW}${IP}${NC}"
echo -e "🌍 Определена страна: ${GREEN}${COUNTRY}${NC} (${ISP_INFO})"
echo "----------------------------------------------------"

# 2. Авто-включение BBR и FQ
echo -e "${CYAN}[1/3] Проверка и активация сетевого стека (BBR)...${NC}"
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)

if [[ "$CC" == "bbr" && "$QDISC" == "fq" ]]; then
    echo -e "  ✅ Алгоритм BBR и планировщик fq: ${GREEN}Активны${NC}"
else
    echo -e "  ⚠️ BBR не активен ($CC / $QDISC). ${YELLOW}Включаем...${NC}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo -e "  ✅ BBR успешно активирован!"
fi

# 3. Синхронизация времени
NTP_SYNC=$(timedatectl status | grep "System clock synchronized" | awk '{print $4}')
if [[ "$NTP_SYNC" != "yes" ]]; then
    timedatectl set-ntp true >/dev/null 2>&1
    echo -e "  ✅ Синхронизация времени NTP включена"
fi

# 4. Подбор кандидатов SNI под страну
echo -e "\n${CYAN}[2/3] Подбор лучших SNI под геопозицию (${COUNTRY})...${NC}"

CANDIDATES=()

case "$COUNTRY" in
    "PL")
        CANDIDATES=("www.nask.pl" "www.gov.pl" "www.wp.pl" "www.onet.pl" "www.orange.pl")
        ;;
    "NL")
        CANDIDATES=("www.ripe.net" "www.ams-ix.net" "www.knmi.nl" "www.sidn.nl")
        ;;
    "SE")
        CANDIDATES=("www.iis.se" "www.Kth.se" "www.val.se" "www.sverigesradio.se")
        ;;
    "DE")
        CANDIDATES=("www.bund.de" "www.heise.de" "www.tagesschau.de" "www.dw.com")
        ;;
    *)
        CANDIDATES=("www.ripe.net" "www.cloudflare.com" "www.intel.com" "www.microsoft.com")
        ;;
esac

# Сканирование соседей в подсети /24
SUBNET=$(echo "$IP" | cut -d'.' -f1-3)
for i in {1..30}; do
    T_IP="${SUBNET}.${i}"
    [[ "$T_IP" == "$IP" ]] && continue
    DOMAIN=$(timeout 1 openssl s_client -connect "${T_IP}:443" 2>/dev/null </dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -oP 'DNS:\K[^\s,]+' | grep -v '\*' | head -n 1)
    if [[ -n "$DOMAIN" ]]; then
        CANDIDATES+=("$DOMAIN")
    fi
done

# 5. Тестирование и вывод
echo -e "\n${CYAN}[3/3] Тестирование доменов на TLS 1.3 + HTTP/2...${NC}"
echo "----------------------------------------------------"

BEST_SNI=""
VALID_LIST=()

for dom in "${CANDIDATES[@]}"; do
    [[ " ${VALID_LIST[*]} " =~ " ${dom} " ]] && continue
    
    HEADERS=$(curl -sI -m 2 --tlsv1.3 --http2 "https://${dom}" 2>/dev/null)
    if [[ $? -eq 0 ]] && ! echo "$HEADERS" | grep -qi "cloudflare"; then
        PING_MS=$(ping -c 2 -W 1 "$dom" 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
        echo -e "  ✅ Домен: ${GREEN}${dom}${NC} | Пинг: ${YELLOW}${PING_MS:-<2} ms${NC} | TLS 1.3: ${GREEN}OK${NC}"
        if [[ -z "$BEST_SNI" ]]; then
            BEST_SNI="$dom"
        fi
        VALID_LIST+=("$dom")
    fi
done

echo -e "----------------------------------------------------"
if [[ -n "$BEST_SNI" ]]; then
    echo -e "🎯 ${GREEN}Рекомендация для 3X-UI:${NC}"
    echo -e "   • ${CYAN}Dest (Target):${NC}    ${BEST_SNI}:443"
    echo -e "   • ${CYAN}SNI (ServerNames):${NC} ${BEST_SNI}"
else
    echo -e "⚠️ ${YELLOW}Используйте проверенный вариант: www.intel.com${NC}"
fi
echo -e "${CYAN}====================================================${NC}"
