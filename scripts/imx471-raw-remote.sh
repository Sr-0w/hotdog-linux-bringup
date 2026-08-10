#!/bin/sh
set -eu

out="$1"
media=/dev/media0
physical_link='"msm_csiphy2":1 -> "msm_csid0":0'

cleanup() {
	set +e
	media-ctl -d "$media" -r
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$out"
dmesg > "$out/dmesg-before.txt"
media-ctl -d "$media" -p > "$out/media-before.txt"

for phy in 0 1 2 3; do
	media-ctl -d "$media" \
		-l "\"msm_csiphy${phy}\":1 -> \"msm_csid0\":0 [0]" || true
done
media-ctl -d "$media" -l "$physical_link [1]"
media-ctl -d "$media" \
	-l '"msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]'
v4l2-ctl -d /dev/v4l-subdev4 --set-ctrl=test_pattern=0

format='fmt:SRGGB10_1X10/1748x1748'
media-ctl -d "$media" -V "\"imx471 7-0010\":0 [$format]"
media-ctl -d "$media" -V "\"msm_csiphy2\":0 [$format]"
media-ctl -d "$media" -V "\"msm_csiphy2\":1 [$format]"
media-ctl -d "$media" -V "\"msm_csid0\":0 [$format]"
media-ctl -d "$media" -V "\"msm_csid0\":1 [$format]"
media-ctl -d "$media" -V "\"msm_vfe0_rdi0\":0 [$format]"
v4l2-ctl -d /dev/video0 \
	--set-fmt-video='width=1748,height=1748,pixelformat=pRAA'
v4l2-ctl -d /dev/v4l-subdev16 \
	--set-ctrl=exposure=1786,analogue_gain=0

media-ctl -d "$media" -p > "$out/media-test.txt"
v4l2-ctl -d /dev/video0 --get-fmt-video > "$out/video-format.txt"
python3 /tmp/camera-prefill-capture.py \
	--device /dev/video0 \
	--buffers 2 \
	--frames 3 \
	--poll-timeout-ms 10000 \
	--fill 0xaa \
	--dump-first "$out/first-frame.raw" \
	> "$out/capture.txt" 2>&1
dmesg > "$out/dmesg-after.txt"
cat "$out/capture.txt"
chmod -R a+rX "$out"
