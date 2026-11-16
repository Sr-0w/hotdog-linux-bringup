#!/bin/sh
# Le firmware capteur OnePlus lit /proc/oppoVersion/{prjName,pcbVersion} pour
# identifier la carte. Mainline ne cree pas ce repertoire, et hexagonrpcd fait
# correspondre le prefixe /oppoVersion/ a $ADSP_LIBRARY_PATH/oppoVersion/.
# Le chargeur d amorçage passe deja les deux valeurs sur la ligne de commande,
# donc on les en derive plutot que de les figer : androidboot.prjname et
# androidboot.hw_version. Le parseur du firmware exige 1 a 7 octets, sans
# retour a la ligne.
D=/usr/share/qcom/oppoVersion
mkdir -p "$D"
for pair in "prjname:prjName" "hw_version:pcbVersion"; do
	key=${pair%%:*}; out=${pair##*:}
	val=$(tr " " "\n" < /proc/cmdline | sed -n "s/^androidboot\.$key=//p" | head -1)
	case "$val" in
		"" ) continue ;;
		*[!0-9]* ) continue ;;
	esac
	[ ${#val} -ge 1 ] && [ ${#val} -le 7 ] && printf "%s" "$val" > "$D/$out"
done
echo "oppoVersion: prjName=$(cat $D/prjName 2>/dev/null) pcbVersion=$(cat $D/pcbVersion 2>/dev/null)"
