#!/bin/sh
# Prepare a bounded, user-paced transition to the physical fastboot sequence.

set -eu

EXPECTED_HOSTNAME=hotdog
EXPECTED_RELEASE=6.16.0-sm8150
LOG_DIR=${HOME:-/home/user}
LOG="$LOG_DIR/proximity-fastboot-prep-$(date -u +%Y%m%dT%H%M%SZ).log"

fail()
{
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

host=$(hostname)
release=$(uname -r)
[ "$host" = "$EXPECTED_HOSTNAME" ] || fail "hostname inattendu: $host"
[ "$release" = "$EXPECTED_RELEASE" ] || fail "kernel inattendu: $release"

{
	printf 'timestamp=%s\n' "$(date -u +%FT%TZ)"
	printf 'hostname=%s\n' "$host"
	printf 'kernel=%s\n' "$release"
	printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
	printf 'taint=%s\n' "$(cat /proc/sys/kernel/tainted)"
	printf '%s\n' 'module-hashes:'
	sha256sum \
		/lib/modules/$release/kernel/sound/soc/qcom/qdsp6/q6afe.ko \
		/lib/modules/$release/kernel/sound/soc/qcom/snd-soc-sm8150.ko
} > "$LOG"

cat <<EOF

Preparation du prochain test proximity

Le telephone est encore allume et rien ne va se passer tout seul.

1. Laisse le cable USB branche.
2. Quand tu as vraiment le temps, appuie sur Entree ci-dessous.
3. Le telephone va seulement s'eteindre proprement.
4. Une fois eteint, utilise la meme sequence PHYSIQUE qui t'a permis
   d'afficher Fastboot Mode tout a l'heure.
5. Ne lance aucune commande fastboot toi-meme. Dis-moi simplement quand
   l'ecran Fastboot Mode est affiche; le candidat sera boote temporairement.

Journal cree: $LOG
EOF

printf '\nAppuie sur Entree uniquement quand tu es pret a eteindre le telephone.\n'
IFS= read -r _
printf 'acknowledged=%s\n' "$(date -u +%FT%TZ)" >> "$LOG"
sync

if [ "$(id -u)" -eq 0 ]; then
	poweroff
else
	doas poweroff
fi
