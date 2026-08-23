#!/bin/sh
# Amene le coeur capteurs SLPI, puis iio-sensor-proxy, avant que la session ne
# s'ouvre.
#
# Pourquoi l'ordre compte
# -----------------------
# iio-sensor-proxy enumere les capteurs SEE une seule fois, a son demarrage, et
# ne recommence jamais. Il prend surtout son nom D-Bus *avant* d'enumerer. Toute
# reclamation arrivee entre les deux est acceptee puis perdue : elle occupe le
# passage 0->1 du compteur de clients sans pilote a activer, si bien que les
# reclamations suivantes ne sont plus que 1->2 et n'activent rien. Le capteur
# reste muet pour toute la vie du processus.
#
# KWin reclame l'accelerometre des qu'il voit le nom apparaitre, et ne reessaie
# jamais. L'enumeration, elle, demande de 75 ms a une quinzaine de secondes
# selon la charge du SLPI au demarrage. Relancer le demon ne repare donc rien :
# KWin guette le nom et regagne la course a chaque fois. La seule issue fiable
# est que le demon soit entierement enumere avant que KWin n'existe.
#
# Pourquoi ce script amene aussi le SLPI
# --------------------------------------
# Ce travail vivait dans /etc/local.d, mais le service local d'OpenRC declare
# "after *" : il s'execute en dernier, apres le gestionnaire de session. Un
# service qui en depend ne peut pas s'ordonner avant la session -- la
# contrainte forme un cycle, qu'OpenRC casse en abandonnant l'ordre demande.
# La barriere amene donc elle-meme la chaine, tot, et le gestionnaire de
# session attend qu'elle rende la main.

LOG=/var/log/hotdog-sensor-gate.log
exec </dev/null >>"$LOG" 2>&1

uptime_s() { cut -d. -f1 /proc/uptime; }

echo "--- $(date '+%F %T') depart a $(uptime_s)s"

# 1. Laisser remoteproc amener le SLPI.
i=0
while [ "$i" -lt 30 ]; do
	for r in /sys/class/remoteproc/remoteproc*; do
		[ "$(cat "$r/name" 2>/dev/null)" = slpi ] || continue
		[ "$(cat "$r/state" 2>/dev/null)" = running ] && break 2
	done
	i=$((i + 1)); sleep 1
done
echo "slpi a $(uptime_s)s"

# 1bis. Liberer la broche d'interruption du SAR.
#
# sm8150 declare mmc@8804000, le controleur de carte SD, avec
# cd-gpios = <&tlmm 96 ACTIVE_LOW>. Le OnePlus 7T Pro n'a pas de lecteur de
# carte, mais GPIO 96 est le dri_irq_num du SX9324 : Linux prend donc la ligne
# d'interruption du capteur SAR pour detecter une carte qui ne peut pas exister.
# Mesure : gpioinfo montre la ligne 96 avec consumer="cd", et delier le pilote
# la rend libre.
#
# Il faut la liberer avant que le SLPI n'arme ses interruptions, sinon il arme
# sur une ligne deja prise et ne recoit rien. La vraie correction est dans le
# device tree -- desactiver sdhc_2 sur cet appareil -- mais elle demande une
# reconstruction ; ceci vaut en attendant et ne coute rien.
if [ -e /sys/bus/platform/drivers/sdhci_msm/8804000.mmc ]; then
	echo 8804000.mmc > /sys/bus/platform/drivers/sdhci_msm/unbind 2>/dev/null \
		&& echo "sdhci_msm delie, GPIO 96 libere a $(uptime_s)s"
fi

# 2. Le PD capteurs resout son entree de registre de services a sa creation, et
# echoue si personne ne sert ce registre. pd-mapper doit donc preceder tout
# attachement FastRPC.
i=0
while [ "$i" -lt 20 ]; do
	pgrep -x pd-mapper >/dev/null && break
	rc-service pd-mapper start >/dev/null 2>&1
	i=$((i + 1)); sleep 1
done
echo "pd-mapper: $(pgrep -x pd-mapper >/dev/null && echo actif || echo ABSENT) a $(uptime_s)s"

# 3. Le service de fichiers du DSP. Le PD capteurs ne se cree qu'au premier
# attachement FastRPC et un attachement rate le laisse inerte, sans redemarrage
# a chaud possible : hexagonrpcd doit etre la du premier coup.
/root/run-hexagonrpcd.sh
echo "hexagonrpcd a $(uptime_s)s"

# 4. Attendre que SEE publie l'accelerometre.
i=0
while [ "$i" -lt 40 ]; do
	if timeout 5 python3 /root/ssc-client.py accel 2>/dev/null | grep -q "data-type"; then
		echo "accel publie a $(uptime_s)s (essai $i)"
		break
	fi
	i=$((i + 1)); sleep 1
done
[ "$i" -ge 40 ] && echo "accel jamais publie a $(uptime_s)s, on demarre quand meme"

# 5. Le demon, retire du niveau par defaut : c'est ici qu'il demarre.
rc-service iio-sensor-proxy start

# 6. Ne rendre la main qu'une fois l'enumeration terminee. C'est tout l'objet de
# la barriere : la session ne doit pas partir sur un demon a moitie pret.
j=0
while [ "$j" -lt 40 ]; do
	has=$(busctl --system get-property net.hadess.SensorProxy \
		/net/hadess/SensorProxy net.hadess.SensorProxy HasAccelerometer \
		2>/dev/null | awk '{print $2}')
	if [ "$has" = "true" ]; then
		echo "HasAccelerometer=true a $(uptime_s)s"
		exit 0
	fi
	j=$((j + 1)); sleep 1
done

echo "HasAccelerometer toujours faux a $(uptime_s)s"
