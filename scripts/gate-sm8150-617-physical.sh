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
# Elle tourne des deux cotes. Depuis l'hote elle passe par SSH ; posee sur le
# telephone elle s'en apercoit et execute tout localement, parce que les gestes
# se font sur le telephone et qu'on a alors rarement un vrai clavier.
#
# La camera escamotable bouge une piece mecanique. Le pilote est borne par les
# capteurs a effet Hall et s'arrete de lui-meme sur obstruction, mais laissez
# le telephone degage pendant ce test.
#
# Usage:
#   ./test.sh                        sur le telephone, tout en local
#   gate-sm8150-617-physical.sh      depuis l'hote, via 172.16.42.1
#   PMOS_HOST=… …                    autre hote
#   SKIP="popup flash" …             sauter des epreuves
set -Eeuo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKIP="${SKIP:-}"
POPUP="/sys/devices/platform/camera-popup"
PASS=0
FAIL=0
SKIPPED=0

# Le telephone se reconnait a son propre materiel, pas a son nom d'hote : le
# moteur de la camera escamotable n'existe nulle part ailleurs.
if [ -z "${PMOS_HOST:-}" ] && [ -d "$POPUP" ]; then
	LOCAL=1
	HOST="local"
else
	LOCAL=0
	HOST="${PMOS_HOST:-172.16.42.1}"
fi

# Tout ce qui suit ecrit dans sysfs. Se relancer soi-meme sous sudo evite de
# decouvrir le probleme a la troisieme question.
if [ "$LOCAL" = 1 ] && [ "$(id -u)" != 0 ]; then
	exec sudo -E "$0" "$@"
fi

if [ "$LOCAL" = 1 ]; then
	REPORT="${REPORT:-$HOME/gate-physique-$(date +%F-%H%M%S).txt}"
else
	REPORT="${REPORT:-$(cd "$HERE/.." && pwd)/build/gate-physique-$(date +%F-%H%M%S).txt}"
fi
mkdir -p "$(dirname "$REPORT")"

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; printf 'PASS  %s\n' "$*" >> "$REPORT"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; printf 'FAIL  %s\n' "$*" >> "$REPORT"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; printf 'SKIP  %s\n' "$*" >> "$REPORT"; SKIPPED=$((SKIPPED + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; printf '\n== %s ==\n' "$*" >> "$REPORT"; }
note() { printf '        %s\n' "$*"; printf '      %s\n' "$*" >> "$REPORT"; }

R() {
	if [ "$LOCAL" = 1 ]; then
		sh -c "$1" 2>/dev/null
	else
		timeout 90 ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@$HOST" "$1" 2>/dev/null
	fi
}

DEPOSER() {  # DEPOSER <fichier ici> <chemin sur le telephone>
	if [ "$LOCAL" = 1 ]; then
		cp "$1" "$2"
	else
		scp -q -o BatchMode=yes -o StrictHostKeyChecking=no "$1" "root@$HOST:$2"
	fi
}

TROUVER() {  # TROUVER <nom> : a cote du script, puis dans l'arbre du depot
	local n="$1" p
	for p in "$HERE/$n" "$HERE/../helpers/$n" "$HERE/../build/$n"; do
		[ -s "$p" ] && { printf '%s' "$p"; return 0; }
	done
	return 1
}

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

printf 'Porte physique  %s  %s\n' "$(date +%F-%H%M%S)" "$(R 'uname -r')" > "$REPORT"
printf '\033[1mPorte physique SM8150 6.17\033[0m  --  noyau %s' "$(R 'uname -r')"
[ "$LOCAL" = 1 ] && printf '  (en local)\n' || printf '  (via %s)\n' "$HOST"
printf 'Rapport : %s\n' "$REPORT"

# ---------------------------------------------------------------- camera popup
if skipped popup; then
	head_ "Camera escamotable"; skip "camera escamotable (demande)"
else
	head_ "Camera escamotable"
	champ() { R "cat $POPUP/status" | tr ' ' '\n' | sed -n "s/^$1=//p"; }

	# open et close n'acceptent que la course complete -- kstrtouint puis
	# `limit != HOTDOG_FULL_COURSE_MICROSTEPS` rend -EINVAL pour tout le reste.
	# Ecrire 1 ne bougeait rien et laissait error=0 last_steps=0, ce qui se lit
	# comme un moteur muet alors que le refus venait du script. La valeur est
	# dans le statut, on la lit plutot que de la coder en dur.
	COURSE="$(champ course_limit)"

	if [ "$(champ error)" != "0" ]; then
		bad "moteur deja en erreur avant l'epreuve (error=$(champ error))"
	elif [ -z "$COURSE" ]; then
		bad "moteur : course_limit illisible dans le statut"
	elif [ "$(champ open_used)" = "1" ] || [ "$(champ close_used)" = "1" ]; then
		# Le pilote de bring-up n'autorise qu'une course par demarrage.
		skip "camera escamotable : course deja consommee, redemarrez pour rejouer"
	else
		note "avant : endpoint=$(champ endpoint) hall_up=$(champ hall_up) hall_down=$(champ hall_down)"
		note "course complete : $COURSE microsteps"
		printf '  Degagez le haut du telephone.\n'
		R "echo $COURSE > $POPUP/open" || true
		sleep 5
		err="$(champ error)"
		note "apres ouverture : endpoint=$(champ endpoint) error=$err last_steps=$(champ last_steps)"
		if [ "$err" != "0" ]; then
			bad "sortie : le pilote signale error=$err"
		elif ask "La camera est-elle sortie ?"; then
			ok "camera escamotable : sortie"
		else
			bad "camera escamotable : sortie (rien observe)"
		fi

		R "echo $COURSE > $POPUP/close" || true
		sleep 5
		err="$(champ error)"
		note "apres fermeture : endpoint=$(champ endpoint) error=$err last_steps=$(champ last_steps)"
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
	# flash_fault est une chaine ("flash-timeout-exceeded"), pas un nombre.
	# La comparer a 0 faisait echouer l'epreuve sans jamais poser la question,
	# ce qui contredit le principe du script : l'oeil tranche, le registre
	# eclaire. Le defaut est donc du contexte, affiche a cote de la question.
	faute="$(R 'cat /sys/class/leds/white:flash-1/flash_fault' | tr -d '\n' || true)"
	[ -n "$faute" ] && note "flash_fault=$faute"
	if ask "Le flash a-t-il emis un eclair ?"; then
		ok "flash"
	else
		bad "flash (aucun eclair${faute:+, flash_fault=$faute})"
	fi
fi

# --------------------------------------------------------------------- haptique
if skipped haptics; then
	head_ "Haptique"; skip "haptique (demande)"
else
	head_ "Haptique"
	OUTIL="$(TROUVER hotdog-haptics-pulse || TROUVER hotdog-haptics-pulse-aarch64 || true)"
	if [ -z "$OUTIL" ] && [ "$LOCAL" = 0 ] && command -v zig >/dev/null 2>&1; then
		"$HERE/build-hotdog-haptics-pulse.sh" >/dev/null 2>&1 || true
		OUTIL="$(TROUVER hotdog-haptics-pulse-aarch64 || true)"
	fi
	if [ -z "$OUTIL" ]; then
		skip "haptique : outil absent"
	else
		# L'outil reste dans /tmp : c'est un diagnostic, il n'a pas a
		# entrer dans l'image ni a apparaitre a l'audit des orphelins.
		DEPOSER "$OUTIL" /tmp/hotdog-haptics-pulse
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
	# On ne lance plus le diagnostic ici. Il arme le chemin audio lui-meme, et
	# depuis que hotdog-proximity-arm existe ce chemin est deja tenu : les deux
	# se disputaient les memes PCM et le test mourait en EBUSY avant meme
	# d'enregistrer. C'etait le symptome, pas le capteur.
	#
	# Le vrai chemin utilisateur est plus simple et se teste tel quel :
	# reclamer la proximite fait scruter in_proximity_raw, ce qui leve `demand`,
	# ce qui fait armer le service. monitor-sensor reclame exactement comme le
	# ferait une application, donc c'est lui qu'on ecoute.
	printf '  Portez le telephone a l'\''oreille comme pour telephoner, cinq\n'
	printf '  secondes, puis eloignez-le cinq secondes. Repetez pendant 45 s.\n'
	printf '  Un objet ne suffit pas : il faut la main ou le visage.\n'
	PROX="$(R 'timeout 45 monitor-sensor 2>&1 | grep -i proximity' || true)"
	if ! printf '%s' "$PROX" | grep -qi "has proximity"; then
		bad "proximite : SensorProxy n'annonce aucun capteur de proximite"
	else
		# Motif exact de monitor-sensor : "    Proximity value changed: %d".
		# S'y tenir evite de compter la ligne d'annonce, qui porte elle aussi
		# un "near: 0" et ferait croire a un eloignement jamais survenu.
		PRES="$(printf '%s\n' "$PROX" | grep -cE 'Proximity value changed: *1' || true)"
		LOIN="$(printf '%s\n' "$PROX" | grep -cE 'Proximity value changed: *0' || true)"
		note "transitions relevees : near=${PRES:-0} far=${LOIN:-0}"
		if [ "${PRES:-0}" -gt 0 ] && [ "${LOIN:-0}" -gt 0 ]; then
			ok "proximite : les deux sens ont ete vus"
		else
			bad "proximite : un sens manque (near=${PRES:-0} far=${LOIN:-0})"
		fi
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
