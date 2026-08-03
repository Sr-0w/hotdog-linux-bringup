#!/bin/busybox sh

hotdog_v36_log() {
	printf '<6>HOTDOG_V36_%s\n' "$*" > /dev/kmsg 2>/dev/null || true
}

hotdog_v36_bound() {
	[ -L "/sys/bus/platform/devices/$1/driver" ] && printf 1 || printf 0
}

hotdog_v36_staged_usb_setup() {
	local qcom_bound hsphy_bound core_bound udc wait_sec candidate status

	qcom_bound="$(hotdog_v36_bound a6f8800.usb)"
	hsphy_bound="$(hotdog_v36_bound 88e2000.phy)"
	core_bound="$(hotdog_v36_bound a600000.usb)"
	hotdog_v36_log "STAGE0_ENTRY qcom=$qcom_bound hsphy=$hsphy_bound core=$core_bound"

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
		hotdog_v36_log "STAGE1_NO_UDC_AFTER_${wait_sec}S"
		return 0
	fi

	hotdog_v36_log "STAGE1_UDC_FOUND=$udc AFTER_${wait_sec}S"
	setup_usb_network_configfs skip_udc
	status=$?
	hotdog_v36_log "STAGE2_CONFIGFS_RETURN=$status"
	[ "$status" -eq 0 ] || return "$status"
	[ -r "$CONFIGFS/g1/UDC" ] || {
		hotdog_v36_log "STAGE2_CONFIGFS_G1_MISSING"
		return 0
	}

	sleep 2
	hotdog_v36_log "STAGE3_UDC_BIND_BEGIN=$udc"
	printf '%s' "$udc" > "$CONFIGFS/g1/UDC"
	status=$?
	hotdog_v36_log "STAGE4_UDC_BIND_RETURN=$status ACTIVE=$(cat "$CONFIGFS/g1/UDC" 2>/dev/null)"
	[ "$status" -eq 0 ] || return "$status"

	sleep 2
	hotdog_v36_log "STAGE5_DHCP_BEGIN"
	start_unudhcpd
	status=$?
	hotdog_v36_log "STAGE6_DHCP_RETURN=$status"
	return "$status"
}
