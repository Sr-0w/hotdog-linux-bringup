#!/bin/sh
cat > /etc/init.d/hotdog-proximite <<'INNER'
#!/sbin/openrc-run
description="Proximite derivee des canaux du TCS3701"

supervisor=supervise-daemon
command="/usr/bin/python3"
command_args="/usr/local/bin/hotdog-proximite"
output_log="/var/log/hotdog-proximite-sortie.log"
error_log="/var/log/hotdog-proximite-sortie.log"

depend() {
	after hotdog-sensor-gate
}
INNER
chmod +x /etc/init.d/hotdog-proximite
cp -f /root/proximite.py /usr/local/bin/hotdog-proximite
chmod +x /usr/local/bin/hotdog-proximite
# le module ssc-client doit etre trouvable depuis /usr/local/bin
cp -f /root/ssc-client.py /usr/local/bin/ssc-client.py
for p in $(pgrep -f "proximite.py|hotdog-proximite"); do kill "$p" 2>/dev/null; done
sleep 1
rc-update add hotdog-proximite default 2>/dev/null
rc-service hotdog-proximite start
sleep 8
echo "=== etat du service ==="
rc-service hotdog-proximite status 2>&1 | head -2
echo "etat proximite: $(cat /run/hotdog-proximite 2>/dev/null)"
echo "--- journal:"
tail -4 /var/log/hotdog-proximite.log
echo "--- sortie:"
tail -4 /var/log/hotdog-proximite-sortie.log 2>/dev/null
