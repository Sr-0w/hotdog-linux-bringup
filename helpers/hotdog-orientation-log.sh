#!/bin/sh
# Enregistre chaque changement d'orientation rapporte par SensorProxy et la
# rotation d'ecran qui s'ensuit. Sert a constater, quand le telephone est
# souleve, si KWin suit -- et si le sens est le bon.
LOG=/var/log/hotdog-orientation.log
exec </dev/null >>"$LOG" 2>&1
U=$(id -u user); RT=/run/user/$U
# kscreen-doctor parle a KScreen par D-Bus et n'a pas besoin d'un ecran,
# mais Qt tente xcb par defaut et avorte. offscreen evite cela.
E="XDG_RUNTIME_DIR=$RT DBUS_SESSION_BUS_ADDRESS=unix:path=$RT/bus WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=offscreen"
prev=""
echo "--- $(date '+%F %T') en ecoute"
i=0
while [ "$i" -lt 2400 ]; do
	o=$(busctl --system get-property net.hadess.SensorProxy /net/hadess/SensorProxy \
		net.hadess.SensorProxy AccelerometerOrientation 2>/dev/null | tr -d 's "')
	if [ -n "$o" ] && [ "$o" != "$prev" ]; then
		# kscreen-doctor colore sa sortie : le nombre suit un code ANSI, donc
		# on saute tout ce qui n'est pas un chiffre apres l'etiquette.
		# borne dure : kscreen-doctor se bloque parfois hors session, et la
		# boucle ne doit pas se figer dessus. Colonne vide plutot qu'arret.
		rot=$(timeout 5 su user -c "$E kscreen-doctor -o" 2>/dev/null \
			| sed -n 's/.*Rotation:[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -1)
		echo "$(date '+%T')  orientation=$o  rotation_ecran=$rot"
		prev=$o
	fi
	i=$((i + 1)); sleep 1
done
echo "--- fin"
