#!/bin/busybox sh

hotdog_v34_usb_log() {
	printf '<6>HOTDOG_V34_%s\n' "$*" > /dev/kmsg 2>/dev/null || true
}

hotdog_v34_usb_bound() {
	[ -L "/sys/bus/platform/devices/$1/driver" ] && printf 1 || printf 0
}

hotdog_v34_usb_setup() {
	local qcom_bound hsphy_bound core_bound udc wait_sec candidate

	qcom_bound="$(hotdog_v34_usb_bound a6f8800.usb)"
	hsphy_bound="$(hotdog_v34_usb_bound 88e2000.phy)"
	core_bound="$(hotdog_v34_usb_bound a600000.usb)"
	hotdog_v34_usb_log "DWC3_STATE qcom=$qcom_bound hsphy=$hsphy_bound core=$core_bound"
	hotdog_v34_usb_log "USB_WAIT_BEGIN"

	udc=""
	wait_sec=0
	while [ "$wait_sec" -lt 15 ]; do
		for candidate in /sys/class/udc/*; do
			[ -e "$candidate" ] || continue
			udc="${candidate##*/}"
			break
		done
		[ -n "$udc" ] && break
		sleep 1
		wait_sec=$((wait_sec + 1))
	done

	if [ -z "$udc" ]; then
		hotdog_v34_usb_log "USB_NO_UDC_AFTER_${wait_sec}S"
		return 0
	fi

	hotdog_v34_usb_log "USB_UDC=$udc AFTER_${wait_sec}S"
	setup_usb_network
	start_unudhcpd
	if [ -r "$CONFIGFS/g1/UDC" ]; then
		hotdog_v34_usb_log "USB_CONFIGURED UDC=$(cat "$CONFIGFS/g1/UDC" 2>/dev/null)"
	else
		hotdog_v34_usb_log "USB_CONFIGFS_G1_MISSING"
	fi
}
