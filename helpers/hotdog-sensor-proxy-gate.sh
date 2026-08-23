#!/bin/sh
# Demarre iio-sensor-proxy une fois que SEE a publie l'accelerometre, et avant
# que la session ne s'ouvre.
#
# Le demon enumere les capteurs SEE une seule fois, a son demarrage, et ne
# recommence jamais. Il prend surtout son nom D-Bus *avant* d'enumerer : mesure
# sur ce telephone, KWin reclame 48 ms apres l'apparition du nom, l'enumeration
# en demande 75. Toute reclamation arrivee trop tot est acceptee puis perdue --
# elle occupe le passage 0->1 du compteur de clients sans pilote a activer, si
# bien que les reclamations suivantes ne sont plus que 1->2 et n'activent rien.
# Le capteur reste muet pour toute la vie du processus, et KWin ne reessaie
# jamais.
#
# Relancer le demon ne repare pas cela : KWin guette le nom et regagne la course
# a chaque fois. La seule issue fiable est que le demon soit entierement
# enumere avant que KWin n'existe. D'ou l'ordonnancement : le service local
# amene hexagonrpcd, cette barriere attend la publication de 'accel', demarre le
# demon, et seulement ensuite le gestionnaire de session est autorise a partir.
#
# Le demon est retire du niveau d'execution par defaut : c'est cette barriere
# qui le demarre, jamais l'inverse.

LOG=/var/log/hotdog-sensor-gate.log
exec </dev/null >>"$LOG" 2>&1

uptime_s() { cut -d. -f1 /proc/uptime; }

echo "--- $(date '+%F %T') depart a $(uptime_s)s"

# Attendre la publication. 40 essais a 1 s couvrent largement la dizaine de
# secondes que prend le SLPI, sans bloquer le demarrage indefiniment si le
# coeur capteurs ne monte pas.
i=0
while [ "$i" -lt 40 ]; do
	if timeout 5 python3 /root/ssc-client.py accel 2>/dev/null | grep -q "data-type"; then
		echo "accel publie a $(uptime_s)s (essai $i)"
		break
	fi
	i=$((i + 1))
	sleep 1
done

[ "$i" -ge 40 ] && echo "accel jamais publie a $(uptime_s)s, on demarre quand meme"

rc-service iio-sensor-proxy start

# Confirmer que l'enumeration a vu l'accelerometre avant de rendre la main : la
# session ne doit pas partir sur un demon a moitie pret.
j=0
while [ "$j" -lt 15 ]; do
	has=$(busctl --system get-property net.hadess.SensorProxy \
		/net/hadess/SensorProxy net.hadess.SensorProxy HasAccelerometer \
		2>/dev/null | awk '{print $2}')
	if [ "$has" = "true" ]; then
		echo "HasAccelerometer=true a $(uptime_s)s"
		exit 0
	fi
	j=$((j + 1))
	sleep 1
done

echo "HasAccelerometer toujours faux a $(uptime_s)s"
