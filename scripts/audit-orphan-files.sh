#!/usr/bin/env bash
# Cherche sur le telephone les fichiers qu'aucun paquet ne possede.
#
# Un port n'est pas reproductible s'il depend de fichiers poses a la main : ils
# marchent jusqu'a la premiere reinstallation, puis disparaissent sans bruit.
# Ca s'est produit deux fois ici -- les soixante-cinq descriptions SEE et
# l'outil de mode de redemarrage -- et dans les deux cas le symptome etait
# ailleurs que la cause.
#
# On n'inspecte que les repertoires ou vit l'integration de l'appareil. /etc et
# /home sont pleins d'etat legitime cree a l'execution ; les inclure noierait
# le signal.
#
# Usage:
#   audit-orphan-files.sh                 sur 172.16.42.1
#   PMOS_HOST=… audit-orphan-files.sh     ailleurs
set -Eeuo pipefail

HOST="${PMOS_HOST:-172.16.42.1}"

R() { timeout 120 ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@$HOST" "$1" 2>/dev/null; }

R true >/dev/null || { printf 'telephone injoignable sur %s\n' "$HOST" >&2; exit 2; }

# Repertoires ou un fichier non possede est forcement suspect.
DIRS='/usr/libexec /usr/local/bin /usr/local/sbin /usr/share/qcom /lib/firmware/qcom/sm8150 /usr/lib/udev/rules.d /etc/udev/rules.d /etc/init.d'

printf 'Audit des fichiers sans paquet sur %s\n\n' "$HOST"

orphans="$(R "
for d in $DIRS; do
	[ -d \"\$d\" ] || continue
	find \"\$d\" -type f -o -type l 2>/dev/null
done | sort -u | while read -r f; do
	apk info --who-owns \"\$f\" >/dev/null 2>&1 || printf '%s\n' \"\$f\"
done
")"

# Etat legitime propre a l'exemplaire : ecrit au demarrage depuis le materiel
# lui-meme, jamais livrable. L'etalonnage Elliptic et le registre capteurs
# viennent de persist ; l'identite OPPO est lue sur l'appareil. Livrer les
# valeurs d'une unite sur une autre serait pire que n'en livrer aucune.
EXPECTED='^/lib/firmware/qcom/sm8150/hotdog/elliptic_calibration_v2\.bin$
^/usr/share/qcom/oppoVersion/(pcbVersion|prjName)$
^/usr/share/qcom/sensors/registry/'

expected_only="$(printf '%s\n' "$orphans" | grep -vE "$(printf '%s' "$EXPECTED" | paste -sd'|')" || true)"
if [ -n "$orphans" ] && [ -z "$expected_only" ]; then
	printf 'Aucun orphelin inattendu.\n\n'
	printf 'Etat propre a l%sexemplaire, normal :\n' "'"
	printf '%s\n' "$orphans" | sed 's/^/  /'
	exit 0
fi
orphans="$expected_only"

if [ -z "$orphans" ]; then
	printf 'Aucun orphelin.\n'
	exit 0
fi

count="$(printf '%s\n' "$orphans" | grep -c .)"
printf '%s fichier(s) qu%s aucun paquet ne possede :\n\n' "$count" "'"
printf '%s\n' "$orphans" | sed 's/^/  /'
printf '\nChacun doit finir dans un paquet, ou etre supprime.\n'
exit 1
