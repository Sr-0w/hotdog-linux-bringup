#!/bin/sh
# Cycle de suspend sur; usage: suspend-safe.sh <secondes>
#
# Corrige le defaut qui a impose deux reveils manuels : l'alarme RTC etait
# armee en relatif ("+2") alors que la seule phase dpm_suspend prend 3,3 s,
# donc l'echeance etait deja depassee quand le sommeil commencait.
#
# Ici l'alarme est calculee en absolu depuis l'horloge du RTC lui-meme, puis
# relue et comparee a l'heure courante du RTC. Si la marge est insuffisante,
# aucun sommeil n'est declenche.

set -u
D=${1:-25}
MIN=15   # plancher: doit depasser dpm_suspend (~3,3 s) avec une large marge

if [ "$D" -lt "$MIN" ]; then
	echo "REFUS: duree ${D}s sous le plancher de ${MIN}s"
	exit 1
fi

RTC=/sys/class/rtc/rtc0
IRQ=$(grep "GICv3 298" /proc/interrupts | cut -d: -f1 | tr -d " ")
[ -n "$IRQ" ] || { echo "REFUS: IRQ watchdog modem introuvable"; exit 1; }
wd() { awk -v i="$IRQ:" '$1==i {print $2}' /proc/interrupts; }

# etat de depart : modem vivant et wifi monte, sinon la mesure ne vaut rien
i=0
while [ $i -lt 20 ]; do
	[ "$(cat /sys/class/remoteproc/remoteproc1/state)" = "running" ] && break
	i=$((i+1)); sleep 2
done
if [ "$(cat /sys/class/remoteproc/remoteproc1/state)" != "running" ]; then
	echo "REFUS: modem pas running"
	exit 1
fi
if ! ip -br addr show wlan0 2>/dev/null | grep -q UP; then
	echo "ATTENTION: wlan0 down, rechargement"
	rmmod ath10k_snoc 2>/dev/null; sleep 3; modprobe ath10k_snoc; sleep 16
fi
echo "depart: modem=$(cat /sys/class/remoteproc/remoteproc1/state) wlan0=$(ip -br addr show wlan0 2>/dev/null | awk '{print $2}')"

# alarme absolue, calculee sur l'horloge du RTC
echo 0 > "$RTC/wakealarm"
NOW=$(cat "$RTC/since_epoch")
TARGET=$((NOW + D))
echo "$TARGET" > "$RTC/wakealarm"
SET=$(cat "$RTC/wakealarm")
NOW2=$(cat "$RTC/since_epoch")
MARGE=$((SET - NOW2))
echo "alarme=[$SET] maintenant=[$NOW2] marge=${MARGE}s"

if [ -z "$SET" ] || [ "$SET" = "0" ]; then
	echo "REFUS: alarme non armee, aucun sommeil declenche"
	exit 1
fi
if [ "$MARGE" -lt 10 ]; then
	echo "REFUS: marge ${MARGE}s insuffisante, aucun sommeil declenche"
	echo 0 > "$RTC/wakealarm"
	exit 1
fi

W0=$(wd)
S0=$(head -1 /sys/kernel/debug/qcom_stats/modem 2>/dev/null | sed 's/Count: //')
U0=$(cut -d' ' -f1 /proc/uptime)
echo mem > /sys/power/state
U1=$(cut -d' ' -f1 /proc/uptime)
sleep 6
W1=$(wd)
S1=$(head -1 /sys/kernel/debug/qcom_stats/modem 2>/dev/null | sed 's/Count: //')
echo 0 > "$RTC/wakealarm"

printf 'alarme=%ss  cycle_total=%.1fs  WATCHDOG=%s  island=%s  modem=%s\n' \
	"$D" "$(awk -v a="$U0" -v b="$U1" 'BEGIN{print b-a}')" \
	"$((W1-W0))" "$((S1-S0))" "$(cat /sys/class/remoteproc/remoteproc1/state)"
