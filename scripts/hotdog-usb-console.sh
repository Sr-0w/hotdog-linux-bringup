#!/usr/bin/env bash
# Envoie une commande au telephone par la console root USB, sans SSH.
#
# device-oneplus-hotdog fait tourner un getty a connexion automatique sur
# ttyGS0, exporte cote hote comme /dev/ttyACM0. Ce chemin ne depend ni de
# sshd, ni du reseau, ni du gestionnaire de services : il survit a tout
# demarrage qui atteint l'espace utilisateur.
#
# Il existe parce qu'un soir sshd n'a pas demarre et que ce port n'avait aucun
# moyen d'agir a distance. La console etait pourtant la ; c'est la
# configuration du port qui etait fausse -- remettre c_cflag a zero met la
# vitesse a B0, et B0 raccroche la ligne. Une lecture vide ne prouve donc
# jamais l'absence d'une console.
#
# Usage:
#   hotdog-usb-console.sh 'uname -r'
#   hotdog-usb-console.sh 'rc-service sshd restart' 15
#   PORT=/dev/ttyACM1 hotdog-usb-console.sh 'ls /'
set -Eeuo pipefail

PORT="${PORT:-/dev/ttyACM0}"
CMD="${1:-}"
ATTENTE="${2:-8}"

[ -n "$CMD" ] || { printf 'Usage: %s <commande> [secondes]\n' "$0" >&2; exit 2; }
[ -c "$PORT" ] || { printf '%s absent : le telephone est-il branche et demarre ?\n' "$PORT" >&2; exit 2; }

# clocal est le reglage qui compte : sans lui l'ouverture attend une porteuse
# que le gadget USB ne presente pas, et tout se fige.
stty -F "$PORT" 115200 clocal cread raw -echo -crtscts

SORTIE="$(mktemp)"
trap 'rm -f "$SORTIE"' EXIT

# Un marqueur unique borne la reponse : la console porte aussi les messages
# noyau, et sans borne on ne sait pas ou s'arrete ce qu'on a demande.
MARQUE="__hotdog_$$_$(date +%s)__"

( timeout "$((ATTENTE + 4))" cat "$PORT" > "$SORTIE" 2>/dev/null & )
sleep 1
printf '\r\n' > "$PORT"
sleep 1
printf '%s; echo %s\r\n' "$CMD" "$MARQUE" > "$PORT"
sleep "$ATTENTE"

# On coupe apres l'echo de la commande pour ne pas rendre la commande
# elle-meme, et avant le marqueur pour ne pas le rendre non plus.
tr -d '\000' < "$SORTIE" \
	| sed -n "/echo $MARQUE/,/^$MARQUE/p" \
	| sed '1d;$d' \
	| grep -avE '^\[[0-9 .]+\]' \
	| sed 's/\r$//'
