#!/bin/sh
# Enregistre chaque changement d'orientation rapporte par SensorProxy et la
# rotation d'ecran qui s'ensuit. Sert a constater, quand le telephone est
# souleve, si KWin suit -- et si le sens est le bon.
LOG=/var/log/hotdog-orientation.log
exec </dev/null >>"$LOG" 2>&1
U=$(id -u user); RT=/run/user/$U
E="XDG_RUNTIME_DIR=$RT DBUS_SESSION_BUS_ADDRESS=unix:path=$RT/bus"
prev=""
echo "--- $(date '+%F %T') en ecoute"
i=0
while [ "$i" -lt 2400 ]; do
	o=$(busctl --system get-property net.hadess.SensorProxy /net/hadess/SensorProxy \
		net.hadess.SensorProxy AccelerometerOrientation 2>/dev/null | tr -d 's "')
	if [ -n "$o" ] && [ "$o" != "$prev" ]; then
		rot=$(su user -c "$E kscreen-doctor -o" 2>/dev/null | tr -d '\033' \
			| sed -n 's/.*Rotation: *\([0-9]*\).*/\1/p' | head -1)
		echo "$(date '+%T')  orientation=$o  rotation_ecran=$rot"
		prev=$o
	fi
	i=$((i + 1)); sleep 1
done
echo "--- fin"
