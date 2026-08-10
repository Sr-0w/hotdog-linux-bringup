#!/bin/sh
set -eu

out="$1"
media=/dev/media0
physical_link='"msm_csiphy2":1 -> "msm_csid0":0'
sensor_entity='imx471 7-0010'
exposure="${IMX471_EXPOSURE:-1786}"
analogue_gain="${IMX471_ANALOGUE_GAIN:-0}"
hold_after_streamon_ms="${IMX471_HOLD_AFTER_STREAMON_MS:-0}"

cleanup() {
	set +e
	media-ctl -d "$media" -r
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$out"
dmesg > "$out/dmesg-before.txt"
media-ctl -d "$media" -p > "$out/media-before.txt"
sensor_node="$(media-ctl -d "$media" -e "$sensor_entity")"

for phy in 0 1 2 3; do
	media-ctl -d "$media" \
		-l "\"msm_csiphy${phy}\":1 -> \"msm_csid0\":0 [0]" || true
done
media-ctl -d "$media" -l "$physical_link [1]"
media-ctl -d "$media" \
	-l '"msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]'
if v4l2-ctl -d "$sensor_node" --list-ctrls | grep -q '^ *test_pattern '; then
	v4l2-ctl -d "$sensor_node" --set-ctrl=test_pattern=0
fi

format='fmt:SRGGB10_1X10/1748x1748'
media-ctl -d "$media" -V "\"$sensor_entity\":0 [$format]"
media-ctl -d "$media" -V "\"msm_csiphy2\":0 [$format]"
media-ctl -d "$media" -V "\"msm_csiphy2\":1 [$format]"
media-ctl -d "$media" -V "\"msm_csid0\":0 [$format]"
media-ctl -d "$media" -V "\"msm_csid0\":1 [$format]"
media-ctl -d "$media" -V "\"msm_vfe0_rdi0\":0 [$format]"
v4l2-ctl -d /dev/video0 \
	--set-fmt-video='width=1748,height=1748,pixelformat=pRAA'
v4l2-ctl -d "$sensor_node" \
	--set-ctrl="exposure=$exposure,analogue_gain=$analogue_gain"
v4l2-ctl -d "$sensor_node" --get-ctrl=exposure,analogue_gain \
	> "$out/controls.txt"

media-ctl -d "$media" -p > "$out/media-test.txt"
v4l2-ctl -d /dev/video0 --get-fmt-video > "$out/video-format.txt"
python3 /tmp/camera-prefill-capture.py \
	--device /dev/video0 \
	--buffers 2 \
	--frames 3 \
	--poll-timeout-ms 10000 \
	--hold-after-streamon-ms "$hold_after_streamon_ms" \
	--fill 0xaa \
	--dump-first "$out/first-frame.raw" \
	> "$out/capture.txt" 2>&1
dmesg > "$out/dmesg-after.txt"
cat "$out/capture.txt"
chmod -R a+rX "$out"
