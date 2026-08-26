#!/usr/bin/env bash
# Porte d'execution non physique pour la base SM8150 6.17.
#
# Elle verifie tout ce qui se constate sans toucher au telephone. Ce qui exige
# un geste -- popup, flash, haptique, capteurs a la main -- reste dehors et
# groupe pour la fin, comme decide pendant la migration.
#
# Elle existe parce que la premiere porte globale a ete passee a la main : la
# regression des capteurs SSC n'a ete vue qu'une fois, et rien ne l'aurait
# rattrapee au boot suivant.
#
# Usage:
#   gate-sm8150-617-runtime.sh                 sur 172.16.42.1
#   PMOS_HOST=… gate-sm8150-617-runtime.sh     ailleurs
set -Eeuo pipefail

HOST="${PMOS_HOST:-172.16.42.1}"
EXPECT_KERNEL="${EXPECT_KERNEL:-6.17.0-sm8150-hotdog-clean}"
PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

R() { timeout 60 ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@$HOST" "$1" 2>/dev/null; }

check() {  # check <libelle> <commande distante> <motif attendu>
	local label="$1" cmd="$2" want="$3" out
	out="$(R "$cmd" || true)"
	if printf '%s' "$out" | grep -qE "$want"; then
		ok "$label"
	else
		bad "$label  (obtenu: ${out:-vide})"
	fi
}

R true >/dev/null || { printf 'telephone injoignable sur %s\n' "$HOST" >&2; exit 2; }

head_ "Identite"
check "noyau $EXPECT_KERNEL" "uname -r" "^${EXPECT_KERNEL}$"
check "rootfs en ecriture" "touch /root/.gate-probe && rm -f /root/.gate-probe && echo rw" "rw"

head_ "Stockage"
check "UFS present" "test -b /dev/sda && echo ok" "ok"
check "partitions Android visibles" "ls /dev/disk/by-partlabel/ | wc -l" "^([2-9][0-9]|[0-9]{3,})$"
check "ICE: profil blk-crypto" "ls /sys/block/sda/queue/crypto 2>/dev/null | tr '\\n' ' '" "num_keyslots"
check "ICE: AES-256-XTS annonce" "cat /sys/block/sda/queue/crypto/modes/AES-256-XTS 2>/dev/null" "0x"

head_ "Processeurs distants"
for rp in slpi modem adsp; do
	check "$rp en marche" \
		"for r in /sys/class/remoteproc/remoteproc*; do [ \"\$(cat \$r/name)\" = $rp ] && cat \$r/state; done" \
		"running"
done
check "rmtfs actif" "pgrep -x rmtfs >/dev/null && echo ok" "ok"
check "pd-mapper actif" "pgrep -x pd-mapper >/dev/null && echo ok" "ok"

head_ "Capteurs"
check "descriptions SEE servies" "ls /usr/share/qcom/sensors/config/*.json 2>/dev/null | wc -l" "^([6-9][0-9]|[0-9]{3,})$"
check "hexagonrpcd actif" "pgrep -x hexagonrpcd >/dev/null && echo ok" "ok"
for prop in HasAccelerometer HasAmbientLight HasProximity; do
	check "SensorProxy $prop" \
		"busctl --system get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy $prop" \
		"true"
done
check "peripherique IIO proximity" "grep -l elliptic_proximity /sys/bus/iio/devices/iio:device*/name >/dev/null && echo ok" "ok"

head_ "Affichage et GPU"
check "carte DRM" "ls /sys/class/drm/ | grep -c '^card0$'" "^1$"
check "connecteur DSI" "cat /sys/class/drm/card0-DSI-1/status 2>/dev/null" "connected"
check "GPU Adreno lie" "ls /sys/class/drm/card0/device/driver 2>/dev/null | head -1; readlink /sys/class/drm/card0/device/driver | sed 's|.*/||'" "msm"

head_ "Entrees"
for dev in s6sy761 "Alert slider" "Elliptic ultrasonic proximity" pm8941_pwrkey; do
	check "input: $dev" "grep -c '$dev' /proc/bus/input/devices" "^[1-9]"
done

head_ "Reseau"
check "usb0 monte" "ip -br addr show usb0 | grep -c UP" "^1$"
check "wlan0 avec adresse" "ip -br addr show wlan0" "UP .*[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"
check "console ACM" "test -e /dev/ttyGS0 && echo ok" "ok"

head_ "Audio, energie, camera"
check "carte audio" "grep -c 'OnePlus 7T Pro' /proc/asound/cards" "^[1-9]"
check "jauge batterie" "cat /sys/class/power_supply/bq27411-0/status 2>/dev/null" "Charging|Discharging|Full|Not charging"
check "graphe media" "test -e /dev/media0 && echo ok" "ok"
check "noeuds video" "ls /dev/video* 2>/dev/null | wc -l" "^[1-9]"

head_ "Modes de redemarrage"
check "syscon reboot-mode lie" "ls /sys/bus/platform/drivers/syscon-reboot-mode/ | grep -c reboot-mode" "^1$"
check "outil de mode present" "test -x /usr/local/bin/hotdog-reboot-mode.py -o -x /usr/libexec/hotdog-reboot-mode.py && echo ok" "ok"

head_ "Sante du chargement"
check "aucune erreur de section de module" "dmesg | grep -c 'section size must match'" "^0$"
check "modules charges" "lsmod | wc -l" "^([5-9][0-9]|[0-9]{3,})$"

printf '\n\033[1mResultat : %d PASS, %d FAIL\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
