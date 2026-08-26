#!/usr/bin/env bash
# Porte physique pour la base SM8150 6.17.
#
# Elle couvre ce que la porte non physique laisse dehors par construction :
# tout ce dont la preuve est un mouvement, une lumiere, une vibration ou un
# geste. Aucun de ces points ne se decide depuis un registre -- il faut un
# oeil et une main, et c'est pour cela qu'ils etaient restes groupes pour la
# fin de la migration.
#
# Elle pose donc des questions. La reponse de l'operateur fait foi : le script
# n'affirme jamais qu'une lampe s'est allumee, il declenche et demande. Ce qu'il
# verifie seul, ce sont les effets de bord constatables -- code d'erreur du
# moteur, defaut de flash, transitions IIO -- et il les affiche a cote de la
# question pour que la reponse soit eclairee.
#
# La camera escamotable bouge une piece mecanique. Le pilote est borne par les
# capteurs a effet Hall et s'arrete de lui-meme sur obstruction, mais laissez
# le telephone degage pendant ce test.
#
# Usage:
#   gate-sm8150-617-physical.sh                sur 172.16.42.1
#   PMOS_HOST=… gate-sm8150-617-physical.sh    ailleurs
#   SKIP="popup flash" gate-sm8150-617-physical.sh   sauter des epreuves
set -Eeuo pipefail

HOST="${PMOS_HOST:-172.16.42.1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STAMP="$(date +%F-%H%M%S)"
REPORT="${REPORT:-$ROOT/build/gate-physique-$STAMP.txt}"
SKIP="${SKIP:-}"
POPUP="/sys/devices/platform/camera-popup"
PASS=0
FAIL=0
SKIPPED=0

mkdir -p "$(dirname "$REPORT")"

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; printf 'PASS  %s\n' "$*" >> "$REPORT"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; printf 'FAIL  %s\n' "$*" >> "$REPORT"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; printf 'SKIP  %s\n' "$*" >> "$REPORT"; SKIPPED=$((SKIPPED + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; printf '\n== %s ==\n' "$*" >> "$REPORT"; }
note() { printf '        %s\n' "$*"; printf '      %s\n' "$*" >> "$REPORT"; }

R() { timeout 90 ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@$HOST" "$1" 2>/dev/null; }

# Les invites passent par /dev/tty : la sortie du script peut etre redirigee
# sans que les questions disparaissent dans le fichier.
ask() {
	local reponse
	printf '\033[33m  ?  %s [o/n] \033[0m' "$1" > /dev/tty
	read -r reponse < /dev/tty
	[ "${reponse,,}" = "o" ] || [ "${reponse,,}" = "oui" ] || [ "${reponse,,}" = "y" ]
}

skipped() { printf ' %s ' "$SKIP" | grep -q " $1 "; }

R true >/dev/null || { printf 'telephone injoignable sur %s\n' "$HOST" >&2; exit 2; }

printf 'Porte physique  %s  %s\n' "$STAMP" "$(R 'uname -r')" > "$REPORT"
printf '\033[1mPorte physique SM8150 6.17\033[0m  --  noyau %s\n' "$(R 'uname -r')"
printf 'Rapport : %s\n' "$REPORT"

# ---------------------------------------------------------------- camera popup
if skipped popup; then
	head_ "Camera escamotable"; skip "camera escamotable (demande)"
else
	head_ "Camera escamotable"
	champ() { R "cat $POPUP/status" | tr ' ' '\n' | sed -n "s/^$1=//p"; }

	if [ "$(champ error)" != "0" ]; then
		bad "moteur deja en erreur avant l'epreuve (error=$(champ error))"
	else
		note "avant : endpoint=$(champ endpoint) hall_up=$(champ hall_up) hall_down=$(champ hall_down)"
		printf '  Degagez le haut du telephone.\n'
		R "echo 1 > $POPUP/open" || true
		sleep 4
		err="$(champ error)"; ep="$(champ endpoint)"
		note "apres ouverture : endpoint=$ep error=$err last_steps=$(champ last_steps)"
		if [ "$err" != "0" ]; then
			bad "sortie : le pilote signale error=$err"
			R "echo 1 > $POPUP/close" >/dev/null 2>&1 || true
		elif ask "La camera est-elle sortie ?"; then
			ok "camera escamotable : sortie"
		else
			bad "camera escamotable : sortie (rien observe)"
		fi

		R "echo 1 > $POPUP/close" || true
		sleep 4
		err="$(champ error)"
		note "apres fermeture : endpoint=$(champ endpoint) error=$err"
		if [ "$err" != "0" ]; then
			bad "rentree : le pilote signale error=$err"
		elif ask "Est-elle rentree completement ?"; then
			ok "camera escamotable : rentree"
		else
			bad "camera escamotable : rentree (incomplete)"
		fi
	fi
fi

# ------------------------------------------------------------------ torche/flash
if skipped flash; then
	head_ "Torche et flash"; skip "torche et flash (demande)"
else
	head_ "Torche et flash"
	R "echo 80 > /sys/class/leds/white:torch/brightness" || true
	if ask "La torche est-elle allumee ?"; then ok "torche"; else bad "torche"; fi
	R "echo 0 > /sys/class/leds/white:torch/brightness" || true

	R "echo 500000 > /sys/class/leds/white:flash-1/flash_timeout
	   echo 300000 > /sys/class/leds/white:flash-1/flash_brightness" >/dev/null 2>&1 || true
	printf '  Regardez le dos du telephone.\n'
	R "echo 1 > /sys/class/leds/white:flash-1/flash_strobe" || true
	sleep 1
	faute="$(R 'cat /sys/class/leds/white:flash-1/flash_fault' || echo '?')"
	note "flash_fault=$faute"
	if [ "$faute" != "0" ] && [ "$faute" != "?" ]; then
		bad "flash : defaut materiel signale ($faute)"
	elif ask "Le flash a-t-il emis un eclair ?"; then
		ok "flash"
	else
		bad "flash (aucun eclair)"
	fi
fi

# --------------------------------------------------------------------- haptique
if skipped haptics; then
	head_ "Haptique"; skip "haptique (demande)"
else
	head_ "Haptique"
	OUTIL="$ROOT/build/hotdog-haptics-pulse-aarch64"
	if [ ! -s "$OUTIL" ]; then
		if command -v zig >/dev/null 2>&1; then
			"$HERE/build-hotdog-haptics-pulse.sh" >/dev/null 2>&1 || true
		fi
	fi
	if [ ! -s "$OUTIL" ]; then
		skip "haptique : outil absent et zig indisponible"
	else
		# L'outil reste dans /tmp : c'est un diagnostic, il n'a pas a
		# entrer dans l'image ni a apparaitre a l'audit des orphelins.
		scp -q -o BatchMode=yes -o StrictHostKeyChecking=no \
			"$OUTIL" "root@$HOST:/tmp/hotdog-haptics-pulse"
		R "chmod +x /tmp/hotdog-haptics-pulse"
		EV="$(R 'for e in /dev/input/event*; do
			n=$(cat /sys/class/input/$(basename $e)/device/name 2>/dev/null)
			case "$n" in *haptic*|*AW8697*) echo $e; break;; esac; done')"
		if [ -z "$EV" ]; then
			bad "haptique : aucun peripherique de retour de force trouve"
		else
			note "peripherique : $EV"
			R "/tmp/hotdog-haptics-pulse $EV 70 400" >/dev/null 2>&1 || true
			if ask "Avez-vous senti une vibration ?"; then ok "haptique"; else bad "haptique"; fi
		fi
		R "rm -f /tmp/hotdog-haptics-pulse"
	fi
fi

# -------------------------------------------------------------------- proximite
if skipped proximity; then
	head_ "Proximite ultrasonique"; skip "proximite (demande)"
else
	head_ "Proximite ultrasonique"
	SMOKE="$ROOT/helpers/elliptic-proximity-smoke.py"
	if [ ! -s "$SMOKE" ]; then
		skip "proximite : $SMOKE absent"
	else
		scp -q -o BatchMode=yes -o StrictHostKeyChecking=no "$SMOKE" "root@$HOST:/tmp/prox-smoke.py"
		printf '  Portez le telephone a l'\''oreille cinq secondes, eloignez-le cinq\n'
		printf '  secondes, et repetez pendant 45 s.\n'
		R "PYTHONDONTWRITEBYTECODE=1 python3 /tmp/prox-smoke.py --record 45 --log /tmp/prox-gate.log" >/dev/null 2>&1 || true
		PRES="$(R "grep -c 'near' /tmp/prox-gate.log 2>/dev/null" || echo 0)"
		LOIN="$(R "grep -c 'far' /tmp/prox-gate.log 2>/dev/null" || echo 0)"
		note "transitions relevees : near=$PRES far=$LOIN"
		if [ "${PRES:-0}" -gt 0 ] && [ "${LOIN:-0}" -gt 0 ]; then
			ok "proximite : les deux sens ont ete vus"
		else
			bad "proximite : un sens manque (near=$PRES far=$LOIN)"
		fi
		R "rm -f /tmp/prox-smoke.py"
	fi
fi

# ------------------------------------------------------- lumiere et orientation
if skipped sensors; then
	head_ "Lumiere ambiante et accelerometre"; skip "capteurs gestuels (demande)"
else
	head_ "Lumiere ambiante et accelerometre"
	printf '  Pendant 30 s : couvrez le haut de l'\''ecran avec la main, puis\n'
	printf '  tournez le telephone sur le cote.\n'
	SORTIE="$(R 'timeout 30 monitor-sensor 2>&1 | head -60' || true)"
	LUM="$(printf '%s' "$SORTIE" | grep -ci "light\|lux" || true)"
	ORI="$(printf '%s' "$SORTIE" | grep -ci "orientation" || true)"
	note "lignes de luminosite=$LUM, lignes d'orientation=$ORI"
	if [ "${LUM:-0}" -gt 1 ]; then ok "lumiere ambiante : la valeur varie"; else bad "lumiere ambiante : aucune variation"; fi
	if [ "${ORI:-0}" -gt 1 ]; then ok "accelerometre : l'orientation change"; else bad "accelerometre : aucun changement"; fi
fi

printf '\n\033[1mResultat : %d PASS, %d FAIL, %d SKIP\033[0m\n' "$PASS" "$FAIL" "$SKIPPED"
printf '\nResultat : %d PASS, %d FAIL, %d SKIP\n' "$PASS" "$FAIL" "$SKIPPED" >> "$REPORT"
printf 'Rapport : %s\n' "$REPORT"
[ "$FAIL" -eq 0 ] || exit 1
