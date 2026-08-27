#!/usr/bin/env bash
# Redemarre le telephone en laissant OpenRC arreter ses services d'abord.
#
# `reboot` de busybox depuis SSH ne suffit pas ici. Il a laisse le systeme de
# fichiers racine rejouer son journal au demarrage suivant -- preuve que rien
# n'avait ete demonte -- et deux de ces redemarrages ont fini en EDL, chaque
# fois avec un besoin d'intervention physique. Le seul redemarrage propre
# constate est celui lance depuis fastboot : aucun rejeu de journal.
#
# Ce script arrete donc explicitement le niveau d'execution avant de rendre la
# main au noyau, et verifie ensuite que le journal n'a pas ete rejoue. Cette
# verification est le point important : sans elle, un arret sale se rattrape
# silencieusement et on ne l'apprend qu'a la panne suivante.
#
# Usage:
#   hotdog-reboot.sh                 sur 172.16.42.1
#   PMOS_HOST=192.168.0.207 …        ailleurs
set -Eeuo pipefail

HOST="${PMOS_HOST:-172.16.42.1}"
ATTENTE="${ATTENTE:-420}"

R() { timeout 60 ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@$HOST" "$1" 2>/dev/null; }

R true >/dev/null || { printf 'telephone injoignable sur %s\n' "$HOST" >&2; exit 2; }

AVANT="$(R 'cat /proc/sys/kernel/random/boot_id')"
printf 'boot_id avant : %s\n' "$AVANT"

# setsid detache la sequence de la session SSH : sans cela elle meurt avec la
# connexion, et le telephone ne redemarre pas du tout -- vu une fois, uptime
# intact apres une attente complete.
timeout 30 ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@$HOST" \
	'setsid sh -c "openrc shutdown >/dev/null 2>&1; sync; sleep 2; reboot -f" >/dev/null 2>&1 &' \
	2>/dev/null || true

printf 'sequence d arret envoyee, attente du retour\n'
sleep 20
fin=$((SECONDS + ATTENTE))
while [ "$SECONDS" -lt "$fin" ]; do
	sleep 10
	APRES="$(R 'cat /proc/sys/kernel/random/boot_id' || true)"
	[ -n "$APRES" ] && [ "$APRES" != "$AVANT" ] && break
done

[ -n "${APRES:-}" ] && [ "$APRES" != "$AVANT" ] || {
	printf 'pas de nouveau boot_id apres %ds : le telephone n est pas revenu\n' "$ATTENTE" >&2
	exit 1
}

printf 'boot_id apres : %s\n' "$APRES"

REJEU="$(R 'dmesg | grep -ci "recovering journal"' || echo '?')"
if [ "$REJEU" = "0" ]; then
	printf 'arret propre : aucun rejeu de journal\n'
else
	printf 'ARRET SALE : le journal a ete rejoue (%s), la sequence n a pas demonte\n' "$REJEU" >&2
	exit 1
fi
