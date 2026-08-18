#!/bin/sh
# Cycle de suspension court et reproductible ; usage: suspend-pm-test-cycle.sh [niveau] [repetitions]
#
# Toute l'enquete sur le crash du modem a longtemps souffert d'un protocole
# bruite : des cycles s2idle complets, une alarme RTC a armer, un reveil qui
# pouvait ne pas venir, et un taux d'echec variable qui a fait conclure trop
# vite plusieurs fois.
#
# /sys/power/pm_test donne un cycle beaucoup plus sain. Le noyau execute les
# phases jusqu'au niveau demande, attend cinq secondes, puis repart tout seul :
# pas d'alarme a armer, pas de reveil manuel possible, duree fixe.
#
#   freezer   gel de l'espace utilisateur seulement
#   devices   + dpm_prepare et dpm_suspend (les callbacks ->suspend())
#   platform  + suspend_late et suspend_noirq
#   processors, core   phases suivantes
#
# Mesure du 2026-08-18 sur ce port : freezer 0/2, devices 2/2, platform 2/2.
# Le modem meurt donc a cause d'un callback ->suspend(), et le cycle prend une
# vingtaine de secondes au lieu d'une minute.
#
# On compte les interruptions du watchdog modem plutot que de lire dmesg :
# l'horodatage de dmesg est celui du handler threade, pas celui de la mort.

set -u
NIVEAU=${1:-devices}
N=${2:-3}

case "$NIVEAU" in
	freezer|devices|platform|processors|core) ;;
	*) echo "REFUS: niveau inconnu '$NIVEAU'"; exit 1 ;;
esac
grep -qw "$NIVEAU" /sys/power/pm_test 2>/dev/null || {
	echo "REFUS: $NIVEAU absent de /sys/power/pm_test (CONFIG_PM_DEBUG ?)"; exit 1; }

IRQ=$(grep "GICv3 298" /proc/interrupts | cut -d: -f1 | tr -d " ")
[ -n "$IRQ" ] || { echo "REFUS: IRQ watchdog modem introuvable"; exit 1; }
wd() { awk -v i="$IRQ:" '$1==i {print $2}' /proc/interrupts; }

# Un cycle mesure a partir d'un modem deja mort ne vaut rien.
attendre_modem() {
	i=0
	while [ $i -lt 45 ]; do
		[ "$(cat /sys/class/remoteproc/remoteproc1/state)" = "running" ] && { sleep 4; return 0; }
		i=$((i+1)); sleep 2
	done
	return 1
}

morts=0
n=0
refus=0
while [ "$n" -lt "$N" ]; do
	attendre_modem || { echo "REFUS: le modem ne revient pas, arret apres $n cycles"; break; }
	W0=$(wd)
	echo "$NIVEAU" > /sys/power/pm_test 2>/dev/null

	# /sys/power/state rend EBUSY quand un evenement de reveil est deja en
	# attente. Ce n'est pas un cycle : il ne faut ni le compter ni s'arreter,
	# sinon une serie de dix se termine au deuxieme.
	if ! echo mem > /sys/power/state 2>/dev/null; then
		echo none > /sys/power/pm_test 2>/dev/null
		refus=$((refus+1))
		if [ "$refus" -ge 10 ]; then
			echo "REFUS: /sys/power/state occupe dix fois de suite, arret"
			break
		fi
		sleep 5
		continue
	fi
	refus=0

	sleep 3
	echo none > /sys/power/pm_test 2>/dev/null
	W1=$(wd)
	n=$((n+1))
	if [ "$W1" != "$W0" ]; then
		morts=$((morts+1))
		echo "  cycle $n: watchdog modem"
	else
		echo "  cycle $n: propre"
	fi
done

echo "niveau=$NIVEAU  morts=$morts/$n  modem=$(cat /sys/class/remoteproc/remoteproc1/state)"
[ "$morts" -eq 0 ]
