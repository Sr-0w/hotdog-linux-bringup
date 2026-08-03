#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/phone-lock.sh"

VARIANT="${HOTDOG_CLEARSTAFF_VARIANT:-mainline617-d13-passive-replay}"
CANDIDATE_LABEL="ClearStaff Linux 6.16"
TARGET_KERNEL=6.16.0-sm8150+
case "$VARIANT" in
	direct-entry-v43-upstream-dwc3)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V43 upstream DWC3"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-214000-clearstaff616-direct-entry-v43-upstream-dwc3"
		BOOT_SHA=a77e789f4991483eddb1671d03895a504faf1e1a6b9e1a3e78daadab5b87c2fd
		BOOT_CMDLINE_SHA=de6f08f3690798e6ec3b20f5ca3b4683fd9efc15dd76ea5c970366afe2aeb4b3
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v42-clean-console)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V42 clean 16x32 console"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-201500-clearstaff616-direct-entry-v42-clean-console"
		BOOT_SHA=baeeeffc6a96f2416038a6468260b609950e63b8bd8b1f4c08d5980d812fe824
		BOOT_CMDLINE_SHA=de6f08f3690798e6ec3b20f5ca3b4683fd9efc15dd76ea5c970366afe2aeb4b3
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v41-translated-dwc3-iommu)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V41 translated DWC3 Apps SMMU"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-235000-clearstaff616-direct-entry-v41-translated-dwc3-iommu"
		BOOT_SHA=f7d2f9f51a3c7818df2148c1bf25c72cf7ee1545ac38c9c3847793820bf9b604
		BOOT_CMDLINE_SHA=7c88a4d3054577b7203f827950286c684759b229cce3c174e1d476320cf18f80
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v40-dwc3-iommu)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V40 DWC3 Apps SMMU stream"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-233000-clearstaff616-direct-entry-v40-dwc3-iommu"
		BOOT_SHA=478aae1ffe9c9159cac767e71813cf3e23085f5d1ef13b56d76d00071b6b1e15
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v39-ep0-iommu-trace)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V39 EP0 and IOMMU trace"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-230000-clearstaff616-direct-entry-v39-ep0-iommu-trace"
		BOOT_SHA=63512b5bc41aebf3b2252067151da4a343ecd854a4ad299bcdada5bb94cd0ee5
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v38-first-connect-no-reset)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V38 first-connect no-reset"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-223000-clearstaff616-direct-entry-v38-first-connect-no-reset"
		BOOT_SHA=eeda76d6b98a6eb021260f97360e3a4224ea902390c32faf15583781cd291930
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v37-usb-bind-trace)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V37 USB bind trace"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-220000-clearstaff616-direct-entry-v37-usb-bind-trace"
		BOOT_SHA=7d24d47d11154d54f27b0e0f7c3e84e6358d939dc8dbb3be41d0d13529939828
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v36-staged-usb)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V36 staged DWC3 gadget"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-213000-clearstaff616-direct-entry-v36-staged-usb"
		BOOT_SHA=a611368ce382b990868f7789e583eb4ab18309a288411ca8b56ba83f0056a0a3
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v35-dwc3-dma32)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V35 DWC3 32-bit DMA"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-210000-clearstaff616-direct-entry-v35-dwc3-dma32"
		BOOT_SHA=f4e5d957e1293b0cf4a746c0e28bf2228ac515b143c2210fed547fabf5ed6817
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v34-active-usb)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V34 bounded active USB"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-203000-clearstaff616-direct-entry-v34-active-usb"
		BOOT_SHA=872ac5c363d1e07cfb3a94acc23dba529d8ead3e01b730c5faf9e5770b6e9f19
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v33-ufs-dma32)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V33 UFS 32-bit DMA diagnostic"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-200000-clearstaff616-direct-entry-v33-ufs-dma32"
		BOOT_SHA=9f0abd8eb79f8b1f694a822bb537401958b879f5dec59339f6164751279c3adb
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v32-ufs-ordering-diag)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V32 UFS ordering + pre-clear diagnostics"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-194000-clearstaff616-direct-entry-v32-ufs-ordering-diag"
		BOOT_SHA=1629471c8b1e95b19cadb3eb3a4669a214ff631089ba8b2a00eb154b092c839f
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v31-static-console)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V31 static native display console"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-171720-clearstaff616-direct-entry-v31-static-console"
		BOOT_SHA=cacc4751e1b2f3ed8085c0db0d1ff443d75ecfb57b7c6295d8187f4048b70834
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v30-dynamic-pps)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V30 native panel dynamic DSC PPS"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-190000-clearstaff616-direct-entry-v30-dynamic-pps"
		BOOT_SHA=eb3934f588e77baba78fa524ec370f53d4308d18097009d07571609af56e97a2
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v29-dsc-slice-per-pkt)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V29 native panel DSC packetization"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-183000-clearstaff616-direct-entry-v29-dsc-slice-per-pkt"
		BOOT_SHA=64ea890a3a0231bc290d502bb5c925537c0d086c7451e87988c07dbbb56ee5d9
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v28-panel-te)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V28 native panel TE synchronization"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-180000-clearstaff616-direct-entry-v28-panel-te"
		BOOT_SHA=4f32deafe9c361c3d116a71b721d23572f1fdad26c10fa7d5599bdd473001c72
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v27-proven-contract-native-panel)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V27 proven direct-entry contract + native panel"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-173000-clearstaff616-direct-entry-v27-proven-contract-native-panel"
		BOOT_SHA=7811d2037e999b3625f4fd0a0fddedbfd3e8a744d68493ba88d6f384b24938ae
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v26-native-panel)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V26 native OnePlus panel driver"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-163000-clearstaff616-direct-entry-v26-native-panel"
		BOOT_SHA=ee6901edcce83aec44feab895574671e3bc1311f50cb73843287192a53f0bde3
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-160925-d3-noop-dtbo/dtbo_b-d3-entry5-noop.img"
		CANDIDATE_DTBO_SHA=339e55adaf591f114d8a39a86cb0a0e664e26bc7c7b7f2227e0bee794d10c5fb
		;;
	direct-entry-v25-native-display)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V25 native hotdog display graph"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-160000-clearstaff616-direct-entry-v25-native-display"
		BOOT_SHA=e8a15e07583185a03c09b4a126a41d041198721a0d79e1d9b0eb9c43cbc86091
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-160925-d3-noop-dtbo/dtbo_b-d3-entry5-noop.img"
		CANDIDATE_DTBO_SHA=339e55adaf591f114d8a39a86cb0a0e664e26bc7c7b7f2227e0bee794d10c5fb
		;;
	direct-entry-v24-panel-vddio)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V24 panel GPIO 130 + VDDIO retention"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-153000-clearstaff616-direct-entry-v24-panel-vddio"
		BOOT_SHA=b0bdaaa45aad84540906fd5dcf530d37cb311d75f2845393e43f27a70ce75df0
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v23-panel-gpio130)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V23 panel GPIO 130 retention"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-150000-clearstaff616-direct-entry-v23-panel-gpio130"
		BOOT_SHA=3958ce498107b5dd8365f5af8e143f2aea276efecdf8aa3d396f068901fe9ec1
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v22-regulator-retention)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V22 regulator retention"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-143000-clearstaff616-direct-entry-v22-regulator-retention"
		BOOT_SHA=6c4cd48213ee77b3a7c9a4aa07520db722bb767898a6aa5a46351e7461d160f6
		BOOT_CMDLINE_SHA=00e356443607007a6f0092f7c911dce691c558ecbb3dc6ecd3ec5a4f1a4fe42e
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v21-simplefb-mmcx)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V21 simplefb MMCX retention"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-140000-clearstaff616-direct-entry-v21-simplefb-mmcx"
		BOOT_SHA=f3aeca49d5c70345a7488b14c6710e3eec68e8bede7d59dc49643674f878fc95
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	mainline617-d13-passive-replay)
		CANDIDATE_LABEL="Linux 6.17 D13 passive replay"
		TARGET_KERNEL=6.17.0-sm8150
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-144522-mainline617-d13-passive-replay"
		BOOT_SHA=51b17d8daaefd4954508329e3ee68549cc91dcd378ba723b9aaa0b367ca1f9de
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	mainline617-postcpu-hold-control)
		CANDIDATE_LABEL="Linux 6.17 D13 post-CPU hold control"
		TARGET_KERNEL=6.17.0-sm8150
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-144239-mainline617-known-good-postcpu-hold"
		BOOT_SHA=db53b01f629447d0ac8d42e3d657e2766a2a7da07f14587c894ced9e93b4e7b5
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	mainline617-inline-canary-control)
		CANDIDATE_LABEL="Linux 6.17 D13 inline-entry canary control"
		TARGET_KERNEL=6.17.0-sm8150
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-143621-mainline617-known-good-inline-entry-canary"
		BOOT_SHA=bd04e49470c0cd0c4bd90a0c784beaac72fbaf7d8c09477167a8cbe848e8a5c4
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v20-simplefb-clocks-no-panic)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V20 simplefb clocks, passive failure"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-133000-clearstaff616-direct-entry-v20-simplefb-clocks-no-panic"
		BOOT_SHA=d9572b822adb96356bcd41684d0d5e20364a723af46b5731d6d5ccedda161a21
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v19-simplefb-clocks)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V19 simplefb GCC clocks"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-123000-clearstaff616-direct-entry-v19-simplefb-clocks"
		BOOT_SHA=fd42e10efeb09d36130bca078cd22ee17c53a50af82fb67e5600c80058416222
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v18-fb-heartbeat)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V18 framebuffer heartbeat"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-115000-clearstaff616-direct-entry-v18-fb-heartbeat"
		BOOT_SHA=c0dbc788da529b6975fb0fa5c7726a83fa17ae5815163037acf3e9b3b10b0e63
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v17-dispcc-off)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V17 retained firmware scanout"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-114000-clearstaff616-direct-entry-v17-dispcc-off"
		BOOT_SHA=f147ffa960a1a2c376137056636c9134b8b57394fd549e040e55c552ce2ee53e
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v16-firmware-pd)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V16 retained firmware power domain"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-012000-clearstaff616-direct-entry-v16-firmware-pd"
		BOOT_SHA=b3bc2c163ab20b48ade82b99dd74d101cb88a2bf6c199937d2a294af96814d1f
		BOOT_CMDLINE_SHA=0076bbd6f2247608e952594e066b0ed3a7026f4d0439ae2226f0de8ccf5b76ab
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v15-firmware-console)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V15 retained firmware console"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-225500-clearstaff616-direct-entry-v15-firmware-console"
		BOOT_SHA=dfc523b95c70cec09a458db4d3b19dab30d09bbc4d12710b4fe7ac9cc7ff46c4
		BOOT_CMDLINE_SHA=b5d1c8487b5c7d35f36d2b2ae89143b49199763c9aa01ac950192f1f80b4c689
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v14-simplefb-nomap)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V14 simplefb no-map"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-231500-clearstaff616-direct-entry-v14-simplefb-nomap"
		BOOT_SHA=ee7ffcb3e0087f2bc9c37c8af7d65ea7f2f25c8d079fda163f0a42e24300f79a
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v13-continue)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V13 continuing entry"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-221500-clearstaff616-direct-entry-v13-continue"
		BOOT_SHA=1f7d1216bbb4fb5274f4c63a6eb890995edebb1fc5be4a0a4f491089b7ff73c9
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v12-d13-protocol)
		CANDIDATE_LABEL="ClearStaff Linux 6.16 V9 entry canary with D13 boot protocol"
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-143322-clearstaff616-direct-entry-v11-working-dtb"
		BOOT_SHA=e0268f5131f3a5fedf894f456410f67ebc6fdc500f879f5ef380ce0e737bb5e5
		CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
		CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
		;;
	direct-entry-v11-working-dtb)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-143322-clearstaff616-direct-entry-v11-working-dtb"
		BOOT_SHA=e0268f5131f3a5fedf894f456410f67ebc6fdc500f879f5ef380ce0e737bb5e5
		;;
	direct-entry-v10-header-size)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-143119-clearstaff616-direct-entry-v10-header-size"
		BOOT_SHA=8dc635148fb3f55bc9ddc8a745e398cc130b67b49e9930f804c5381b9ad9f1ff
		;;
	direct-entry-v9-canary)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-142538-clearstaff616-direct-entry-v9-canary"
		BOOT_SHA=87238e746286980c055eebbc49f499088e8f805566b9aeeb3d1f30930efb3e90
		;;
	direct-entry-v8-pmsg-visual)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-140630-clearstaff616-direct-entry-v8-pmsg-visual"
		BOOT_SHA=4c2aa54f744ad296a88c6e3f8df70c3e058d53a958f2a5c92bc8c97c476c0f3a
		;;
	direct-entry-v7-ramonly)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-133100-clearstaff616-direct-entry-v7-ramonly"
		BOOT_SHA=7061fe8966d7aab699defb19465ff7e32a5f29dbd67cbbb3a87681ab17e1f76f
		;;
	direct-entry-v6-rammarkers)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-132100-clearstaff616-direct-entry-v6-rammarkers"
		BOOT_SHA=a751a7ba816f59686744d8a0d3793bbad453cc9fa576282db9392b88515c7042
		;;
	baseline)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-113800-clearstaff616-direct-baseline"
		BOOT_SHA=d722cdce7fd9363f73eb086ad8bf2eaafa78aacb76ade6fbb3a73cc07b30df43
		;;
	direct-entry-v1)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-120100-clearstaff616-direct-entry-v1"
		BOOT_SHA=6043142264216b497351649fb181c5e989ea1e6291c30fb7dfd9f41c44b4eaef
		;;
	direct-entry-v2)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-123000-clearstaff616-direct-entry-v2"
		BOOT_SHA=5a971311dbec7c7c4f73697e757de1ff78fcbaf0faf36d48dbe5490e33365d18
		;;
	direct-entry-v3)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-124000-clearstaff616-direct-entry-v3"
		BOOT_SHA=4fab682346dc492fd027999bc56b9fa24a6135ae39e115d9e34160e448acb6af
		;;
	direct-entry-v4)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-124905-clearstaff616-direct-entry-v4"
		BOOT_SHA=5f881d03fa288b37b0d65923085a325fe1484e9d9b4a4c702af7f524e0c9fcfb
		;;
	direct-entry-v5-nokvm)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-130240-clearstaff616-direct-entry-v5-nokvm"
		BOOT_SHA=6fca1806ed579ef664b959732ab0c0b142fa18276eb8623798fa904c5a7e7cba
		;;
	direct-entry-v3-workingdtb-control)
		BOOT_DIR="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-125000-clearstaff616-direct-entry-v3-workingdtb-control"
		BOOT_SHA=50c043fa3e720cac5b991e3935dc0760f97ffeee5355d70f9bf8095912a2249d
		;;
	*)
		printf 'Unsupported HOTDOG_CLEARSTAFF_VARIANT: %s\n' "$VARIANT" >&2
		exit 2
		;;
esac
BOOT_IMAGE="$BOOT_DIR/boot.img"
BOOT_CMDLINE="$BOOT_DIR/components/cmdline.txt"
CANDIDATE_DTBO="${CANDIDATE_DTBO:-$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-160925-d3-noop-dtbo/dtbo_b-d3-entry5-noop.img}"
RESTORE_DTBO="$HOTDOG_ROOT/logs/partition-read-vbmeta-dtbo-clean-2026-07-08-230943/dtbo_b.img"
RESTORE_BOOT="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-234100-lineage414-r6-nowdog-kexec-fbwait-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
REBOOT_HELPER="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"

BOOT_CMDLINE_SHA="${BOOT_CMDLINE_SHA:-902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6}"
CANDIDATE_DTBO_SHA="${CANDIDATE_DTBO_SHA:-339e55adaf591f114d8a39a86cb0a0e664e26bc7c7b7f2227e0bee794d10c5fb}"
RESTORE_DTBO_SHA=95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672
RESTORE_BOOT_SHA=e76c85a56cdbcc6ddd105844eb322cb854fb33b2b23077da12ff098adc8f2369
REBOOT_HELPER_SHA=045a3d9d696ddee6922e1ce506aeb82a77c261978ea6a3220fd114751952d711

SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
START_MODE="${HOTDOG_TEST_START_MODE:-pmos-ssh}"
SOURCE_KERNEL=4.14.357-openela-perf
SOURCE_SLOT_SUFFIX=_b
OBSERVE_SEC="${OBSERVE_SEC:-600}"
POLL_SEC="${POLL_SEC:-2}"
FASTBOOT_TIMEOUT_SEC="${FASTBOOT_TIMEOUT_SEC:-20}"
PREFLIGHT_ONLY="${HOTDOG_PREFLIGHT_ONLY:-0}"

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/clearstaff616-direct-$VARIANT-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

phone_dirty=0
acm_capture_pid=""
source_boot_id=""

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $1"
	exit "${2:-1}"
}

cleanup() {
	if [ -n "$acm_capture_pid" ]; then
		kill "$acm_capture_pid" 2>/dev/null || true
		wait "$acm_capture_pid" 2>/dev/null || true
	fi
	phone_lock_release || true
	if [ "$phone_dirty" -eq 1 ]; then
		log "Candidate partitions remain installed; no automatic restore or reboot was attempted."
		log "Pinned recovery artifacts: $RESTORE_DTBO and $RESTORE_BOOT"
	fi
}
trap cleanup EXIT INT TERM

usage() {
	cat <<'USAGE'
Usage: test-clearstaff616-direct.sh

Launch a pinned direct-boot candidate on slot B. The default
variant is mainline617-d13-passive-replay. It uses the unmodified kernel, DTB,
and ramdisk from the D13 artifact proven on hardware, with only the passive
command line replacing the historical userspace rescue timeout. The
direct-entry-v31-static-console variant keeps V30's kernel, DTB, command line,
and D7 bootloader-overlay contract byte-identical. It changes only rdinit: after
preserving dmesg in RAM, it draws five unique non-scrolling bands across tty0
and leaves an interactive BusyBox shell alive. This distinguishes native
scanout geometry faults from fbcon scrolling without any automatic reboot. The
direct-entry-v36-staged-usb variant uses V35's DWC3 DMA constraint but creates
the NCM configfs tree without binding it, waits two seconds, then performs one
UDC bind and starts DHCP only if that write returns. ACM reconfiguration is
disabled, so a failure identifies either the initial UDC bind or an earlier
configfs step. The
direct-entry-v35-dwc3-dma32 variant retains V34's bounded active-USB initramfs,
V33's validated DTB, and the working direct-mainline UFS path. Its only
functional kernel delta forces coherent DWC3 allocations below 4 GiB when the
SM8150 bring-up DT omits the failed Apps SMMU, and prints the resulting DMA
addresses before the gadget is configured. The
direct-entry-v34-active-usb variant keeps the hardware-validated V33 kernel,
DTB, command line, and complete ramdisk prefix byte-identical. Its appended
initramfs member replaces only the two passive USB markers with a bounded UDC
wait and the standard postmarketOS NCM/DHCP setup. A missing UDC is logged and
the successful V33 rootfs path continues without reset. The
direct-entry-v33-ufs-dma32 variant keeps every V32 boot component and diagnostic
unchanged except for the kernel's QCOM UFS DMA-mask callback. On SM8150 only,
and only while the temporary DT omits `iommus`, it forces coherent UFS request
lists below 4 GiB and reports their addresses in the retained timeout dump. The
direct-entry-v32-ufs-ordering-diag variant keeps V30's validated DTB,
initramfs, command line, D7 overlay, and native display path byte-identical. Its
kernel adds the UFS DMA/MMIO ordering used by the working downstream kernel and
prints one compact controller plus UPIU dump before clearing the first timed-out
NOP OUT. It never reboots automatically. The
direct-entry-v30-dynamic-pps variant keeps V29's corrected two-slice DSI
packetization and every boot artifact contract. After the vendor panel-on
sequence, it additionally sends the standard 128-byte PPS generated from the
calculated DSC configuration, matching the downstream DSI_CMD_SET_PPS path. The
direct-entry-v29-dsc-slice-per-pkt variant keeps the V28 DTB, D7 overlay,
initramfs, command line, and direct-entry Image contract. Its kernel adds the
MSM DSI support needed to send both 720-pixel DSC slices in one packet, matching
the downstream OnePlus panel configuration: 1440 bytes per packet, one packet
per line, and command-mode word count 1441. The
direct-entry-v28-panel-te variant changes only the V27 device tree: TLMM GPIO8
is muxed to mdp_vsync and selected as the native command-mode panel's default
pinctrl state. The DSI output endpoint is also explicitly enabled. The kernel,
initramfs, V13 base DTB, and D7 bootloader-overlay contract remain unchanged. The
direct-entry-v27-proven-contract-native-panel variant keeps the V26 native
panel driver but restores the exact V13 arm64 Image window, proven base DTB,
and D7 filtered-overlay contract. Its panel graph is applied as a native DT
overlay and replayed with D7 offline before packaging. The
direct-entry-v26-native-panel variant rebuilds ClearStaff Linux 6.16 with a
built-in DRM/MIPI-DSI driver generated from the downstream OnePlus panel
command table. Its native DTB wires PM8150 LDO14 VDDIO, GPIO130 AVDD, and
GPIO6 reset to the panel. It is the first candidate in which mainline Linux
owns the complete known panel power and initialization sequence. The
direct-entry-v25-native-display variant combines the V13 direct-entry fix with
the untouched ClearStaff hotdog DTB for the first time. That DTB enables the
native MDSS, DPU, DSI, PHY, and samsung,oneplus-dsc panel graph. It uses the
no-op DTBO and a passive initramfs without the simplefb heartbeat or diagnostic
panic. The
direct-entry-v24-panel-vddio variant extends V23 by making simplefb consume
PM8150 LDO14, the 1.8 V VDDIO rail named by the downstream OnePlus display
path. It retains both known OnePlus panel supplies without changing the kernel,
initramfs, command line, or any unrelated DT property. The
direct-entry-v23-panel-gpio130 variant keeps the V20 kernel, initramfs, and
command line byte-identical. It reproduces the downstream OnePlus fixed 1.8 V
panel AVDD regulator on TLMM GPIO 130 and gives simplefb a persistent
panel-supply consumer. The
direct-entry-v22-regulator-retention variant keeps every V20 executable and
DTB byte unchanged. It replaces the redundant ignore_loglevel token with
regulator_ignore_unused so the regulator core cannot disable firmware-enabled
panel supplies which the incomplete hotdog display description does not yet
claim. The prior
mainline617-postcpu-hold-control changes only three bytes in the
direct Linux 6.17 Image proven on hardware: the watchdog re-enable becomes a
disable and the branch after its two proven framebuffer stages becomes a local
hold. The prior mainline617-inline-canary-control branches from byte zero to the
V9 canary copied at offset 0x40; it is retained only as a negative control. The
direct-entry-v21-simplefb-mmcx additionally makes simplefb hold the SM8150 MMCX
power domain at its DISPCC low-SVS vote while DISPCC remains disabled. It keeps
the V20 passive failure behavior. The prior
direct-entry-v20-simplefb-clocks-no-panic keeps the V19 display-clock test but
removes the inherited 90-second diagnostic panic. Failed boots therefore stay
passive until one manual reset instead of entering Qualcomm crashdump. The prior
direct-entry-v19-simplefb-clocks adds only the SM8150 GCC display HF and SF AXI
clock dependencies to the V18 simple-framebuffer. The retained heartbeat makes
continued scanout camera-visible. The prior
direct-entry-v18-fb-heartbeat keeps the V17 kernel, DTB, command line, and boot
protocol unchanged. Its appended initramfs overlay starts a static AArch64
helper after the first userspace checkpoint; the helper continuously repaints
a large four-color band without requesting a reboot or writing phone storage.
This distinguishes framebuffer clearing from loss of firmware scanout. The
direct-entry-v17-dispcc-off adds only `status = "disabled"` to the SM8150
display clock controller in the V14 DTB. This prevents its probe from
reprogramming the firmware-owned display PLLs before native MDSS/DSI support
is enabled. The prior direct-entry-v16-firmware-pd variant keeps every V14 payload unchanged and
adds only `pd_ignore_unused`. This prevents late generic power-domain cleanup
from switching off the bootloader-initialized display path while MDSS/DPU/DSI
remain disabled. The prior direct-entry-v15-firmware-console variant keeps every V14 payload unchanged
and appends only `nomodeset`, which prevents MSM DRM from replacing the now
working firmware console before native panel support is ready. The prior
direct-entry-v14-simplefb-nomap variant keeps the V13 kernel, ramdisk, command
line, and D13 boot protocol unchanged. Its only semantic DTB change adds
`no-map` to the reserved splash framebuffer, allowing simplefb to create its
write-combining mapping instead of rejecting linear-mapped RAM. The prior
direct-entry-v13-continue variant changes the final canary barrier into a
branch over the intentional hold, allowing the validated entry state to
continue through the normal ClearStaff startup path. The
direct-entry-v12-d13-protocol variant combines the V9 ClearStaff canary, the
known-working D13 DTB, and the filtered DTBO required by the D13 boot protocol.
The
prior direct-entry-v11-working-dtb combines the unchanged V9 kernel canary
with the hash-pinned DTB already proven by direct Linux 6.17 boots. The
prior direct-entry-v10-header-size changes exactly one byte in the V9 kernel
payload so the arm64 Image size field matches the accepted 6.17 value
0x01c00000. The prior direct-entry-v9-canary disables the inherited APSS
watchdog at the first primary entry point when the MMU/cache contract is valid,
paints one large framebuffer block, and deliberately holds without resetting.
The prior
direct-entry-v8-pmsg-visual records a native pmsg checkpoint and draws eight
cumulative framebuffer blocks without changing display registers or delaying
entry. The prior direct-entry-v7-ramonly,
direct-entry-v6-rammarkers, and direct-entry-v5-nokvm candidates remain
available, while
HOTDOG_CLEARSTAFF_VARIANT=baseline reproduces the untouched external-kernel
control. The default source is the verified
R6 postmarketOS bridge. Set HOTDOG_TEST_START_MODE=fastboot only when the phone
is already in bootloader Fastboot.

Set HOTDOG_PREFLIGHT_ONLY=1 to validate every pinned host artifact without
opening a phone transport.

The operation writes only dtbo_b and boot_b, selects slot B, and performs the
single reboot required to enter the candidate. Observation is passive. There
is no rescue watcher, timeout reset, Sahara reset, fallback reboot, or automatic
partition restore. A failed candidate is deliberately left untouched for manual
inspection and recovery.
USAGE
}

check_positive_integer() {
	local name="$1" value="$2"
	case "$value" in
		''|*[!0-9]*) die "$name must be a positive integer" 2 ;;
	esac
	[ "$value" -gt 0 ] || die "$name must be a positive integer" 2
}

check_sha() {
	local label="$1" file="$2" expected="$3" actual=""
	[ -s "$file" ] || die "Missing $label: $file" 2
	actual="$(sha256sum "$file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] ||
		die "$label SHA256 mismatch: expected $expected, got $actual" 3
}

cmdline_has_token() {
	local cmdline="$1" token="$2"
	case " $cmdline " in
		*" $token "*) return 0 ;;
		*) return 1 ;;
	esac
}

pmos_ssh() {
	sshpass -p "$HOTDOG_PMOS_PASSWORD" ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$run_dir/known_hosts" \
		-o ConnectTimeout=5 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$HOTDOG_PMOS_USER@$HOTDOG_PMOS_HOST" "$@"
}

fastboot_do() {
	timeout --signal=TERM "$FASTBOOT_TIMEOUT_SEC" \
		fastboot -s "$SERIAL" "$@"
}

fastboot_visible() {
	hotdog_fastboot_usb_visible || return 1
	timeout --signal=TERM 5 fastboot devices -l 2>/dev/null |
		awk -v serial="$SERIAL" '$1 == serial { found=1 } END { exit found ? 0 : 1 }'
}

fastboot_getvar() {
	local name="$1" output="$2"
	fastboot_do getvar "$name" > "$output" 2>&1
}

capture_acm() {
	local deadline=$((SECONDS + OBSERVE_SEC)) dev=""
	: > "$run_dir/acm-console.raw"
	while [ "$SECONDS" -lt "$deadline" ]; do
		for dev in /dev/ttyACM*; do
			[ -c "$dev" ] || continue
			printf '\n[%s] opening %s\n' "$(date '+%F %T')" "$dev" >> "$run_dir/acm-events.txt"
			timeout --signal=TERM 3 cat "$dev" >> "$run_dir/acm-console.raw" 2>> "$run_dir/acm-errors.txt" || true
		done
		sleep 1
	done
}

attest_source_r6() {
	local probe="$run_dir/source-r6.txt" kernel="" cmdline=""
	pmos_ssh 'printf "BOOT_ID="; cat /proc/sys/kernel/random/boot_id; printf "KERNEL="; uname -r; printf "CMDLINE="; cat /proc/cmdline' \
		> "$probe" 2>&1 || die "R6 SSH attestation failed" 4
	source_boot_id="$(sed -n 's/^BOOT_ID=//p' "$probe" | head -n1)"
	kernel="$(sed -n 's/^KERNEL=//p' "$probe" | head -n1)"
	cmdline="$(sed -n 's/^CMDLINE=//p' "$probe" | head -n1)"
	[ -n "$source_boot_id" ] || die "R6 boot_id is missing" 4
	[ "$kernel" = "$SOURCE_KERNEL" ] ||
		die "Source kernel mismatch: expected $SOURCE_KERNEL, got ${kernel:-missing}" 4
	for token in \
		watchdog_v2.enable=0 \
		"androidboot.slot_suffix=$SOURCE_SLOT_SUFFIX" \
		"androidboot.serialno=$SERIAL"; do
		cmdline_has_token "$cmdline" "$token" ||
			die "R6 command line lacks $token" 4
	done
	log "Verified R6 source boot $source_boot_id on slot B"
}

handoff_r6_to_fastboot() {
	"$HOTDOG_ROOT/scripts/reboot-pmos-to-bootloader.sh" \
		--mode bootloader \
		--helper "$REBOOT_HELPER" \
		--helper-sha256 "$REBOOT_HELPER_SHA" \
		--serial "$SERIAL" \
		--expected-source-boot-id "$source_boot_id" \
		--expected-source-kernel "$SOURCE_KERNEL" \
		--expected-source-cmdline-token watchdog_v2.enable=0 \
		--expected-source-cmdline-token "androidboot.slot_suffix=$SOURCE_SLOT_SUFFIX" \
		--expected-source-cmdline-token "androidboot.serialno=$SERIAL" \
		--phone-lock-fd "$PHONE_LOCK_FD"
}

attest_fastboot() {
	local devices="$run_dir/fastboot-devices.txt"
	timeout --signal=TERM 5 fastboot devices -l > "$devices" 2>&1 || true
	awk -v serial="$SERIAL" '$1 == serial { found=1 } END { exit found ? 0 : 1 }' "$devices" ||
		die "Target serial is not visible in Fastboot" 4

	fastboot_getvar product "$run_dir/fastboot-product.txt" || die "Could not read Fastboot product" 4
	grep -Eq '(product: (msmnile|hotdog)|^Product: (msmnile|hotdog))' "$run_dir/fastboot-product.txt" ||
		die "Unexpected Fastboot product" 4
	fastboot_getvar unlocked "$run_dir/fastboot-unlocked.txt" || die "Could not read unlock state" 4
	grep -Eq '(unlocked: yes|^Unlocked: yes)' "$run_dir/fastboot-unlocked.txt" ||
		die "Bootloader is not reported unlocked" 4
	fastboot_getvar is-userspace "$run_dir/fastboot-userspace.txt" || true
	if grep -Eq '(is-userspace: yes|^Is-userspace: yes)' "$run_dir/fastboot-userspace.txt"; then
		die "fastbootd is visible instead of bootloader Fastboot" 4
	fi
	log "Verified bootloader Fastboot identity for $SERIAL"
}

flash_candidate() {
	check_sha "candidate dtbo_b" "$CANDIDATE_DTBO" "$CANDIDATE_DTBO_SHA"
	phone_dirty=1
	log "Flashing pinned candidate dtbo_b"
	fastboot_do flash dtbo_b "$CANDIDATE_DTBO" 2>&1 |
		tee "$run_dir/fastboot-flash-dtbo-b.txt"

	check_sha "candidate boot_b" "$BOOT_IMAGE" "$BOOT_SHA"
	log "Flashing pinned candidate boot_b"
	fastboot_do flash boot_b "$BOOT_IMAGE" 2>&1 |
		tee "$run_dir/fastboot-flash-boot-b.txt"

	log "Selecting slot B"
	fastboot_do set_active b 2>&1 | tee "$run_dir/fastboot-set-active-b.txt"
	log "Entering the candidate; this is the final automatic phone action"
	fastboot_do reboot 2>&1 | tee "$run_dir/fastboot-reboot.txt"
}

collect_candidate_ssh() {
	local probe="$run_dir/candidate-ssh.txt" kernel="" boot_id="" cmdline=""
	pmos_ssh 'printf "BOOT_ID="; cat /proc/sys/kernel/random/boot_id; printf "KERNEL="; uname -r; printf "CMDLINE="; cat /proc/cmdline' \
		> "$probe.tmp" 2>&1 || return 1
	mv "$probe.tmp" "$probe"
	boot_id="$(sed -n 's/^BOOT_ID=//p' "$probe" | head -n1)"
	kernel="$(sed -n 's/^KERNEL=//p' "$probe" | head -n1)"
	cmdline="$(sed -n 's/^CMDLINE=//p' "$probe" | head -n1)"
	[ "$kernel" = "$TARGET_KERNEL" ] || return 2
	[ "$boot_id" != "$source_boot_id" ] || return 3
	for token in rdinit=/hotdog-mainline-wrapper panic=0 console=ttyGS0,115200; do
		cmdline_has_token "$cmdline" "$token" || return 4
	done
	pmos_ssh 'uname -a; cat /proc/cmdline; printf "\n--- block ---\n"; ls -l /dev/disk/by-uuid 2>&1; printf "\n--- mounts ---\n"; mount; printf "\n--- net ---\n"; ip -br addr; printf "\n--- dmesg ---\n"; dmesg' \
		> "$run_dir/candidate-evidence.txt" 2>&1 || true
	return 0
}

observe_candidate() {
	local deadline=$((SECONDS + OBSERVE_SEC)) usb_now="" usb_last="" ssh_status=0
	capture_acm &
	acm_capture_pid=$!
	log "Passive observation started for ${OBSERVE_SEC}s"
	while [ "$SECONDS" -lt "$deadline" ]; do
		usb_now="$(lsusb 2>/dev/null | sort || true)"
		if [ "$usb_now" != "$usb_last" ]; then
			printf '\n[%s]\n%s\n' "$(date '+%F %T')" "$usb_now" >> "$run_dir/usb-transitions.txt"
			usb_last="$usb_now"
		fi
		if lsusb -d 05c6:900e 2>/dev/null | grep -q .; then
			log "Qualcomm 900e detected; leaving it untouched"
			printf 'qualcomm-900e\n' > "$run_dir/result.txt"
			return 6
		fi
		if fastboot_visible; then
			log "Candidate returned to Fastboot; no restore or reboot will be attempted"
			printf 'fastboot-returned\n' > "$run_dir/result.txt"
			return 5
		fi
		if ping -c 1 -W 1 "$HOTDOG_PMOS_HOST" >/dev/null 2>&1; then
			set +e
			collect_candidate_ssh
			ssh_status=$?
			set -e
			case "$ssh_status" in
				0)
					log "SUCCESS: $CANDIDATE_LABEL reached verified SSH userland"
					printf 'verified-mainline-ssh\n' > "$run_dir/result.txt"
					return 0
					;;
				2) log "USB networking answers, but SSH is not running $TARGET_KERNEL" ;;
				3) log "SSH boot_id did not change; refusing a false success" ;;
				4) log "Target kernel is present but its command line is not the pinned candidate" ;;
			esac
		fi
		sleep "$POLL_SEC"
	done
	log "Observation timed out; leaving the phone untouched for visual/manual diagnosis"
	printf 'observation-timeout\n' > "$run_dir/result.txt"
	return 7
}

main() {
	local image_size=""
	[ "${1:-}" != -h ] && [ "${1:-}" != --help ] || { usage; return 0; }
	[ "$#" -eq 0 ] || die "This pinned launcher accepts no arguments" 2
	case "$START_MODE" in
		pmos-ssh|fastboot) ;;
		*) die "HOTDOG_TEST_START_MODE must be pmos-ssh or fastboot" 2 ;;
	esac
	case "$PREFLIGHT_ONLY" in
		0|1) ;;
		*) die "HOTDOG_PREFLIGHT_ONLY must be 0 or 1" 2 ;;
	esac
	hotdog_require_target_serial
	hotdog_require_pmos_password
	check_positive_integer OBSERVE_SEC "$OBSERVE_SEC"
	check_positive_integer POLL_SEC "$POLL_SEC"
	check_positive_integer FASTBOOT_TIMEOUT_SEC "$FASTBOOT_TIMEOUT_SEC"
	for command in avbtool fastboot flock lsusb ping sha256sum ssh sshpass timeout; do
		command -v "$command" >/dev/null 2>&1 || die "Missing command: $command" 127
	done

	check_sha "$CANDIDATE_LABEL boot image" "$BOOT_IMAGE" "$BOOT_SHA"
	check_sha "$CANDIDATE_LABEL passive command line" "$BOOT_CMDLINE" "$BOOT_CMDLINE_SHA"
	check_sha "candidate dtbo_b" "$CANDIDATE_DTBO" "$CANDIDATE_DTBO_SHA"
	check_sha "stock recovery dtbo_b" "$RESTORE_DTBO" "$RESTORE_DTBO_SHA"
	check_sha "R6 recovery boot_b" "$RESTORE_BOOT" "$RESTORE_BOOT_SHA"
	check_sha "R6 reboot helper" "$REBOOT_HELPER" "$REBOOT_HELPER_SHA"
	image_size="$(stat -c %s "$BOOT_IMAGE")"
	[ "$image_size" = 100663296 ] || die "Unexpected boot image size: $image_size" 3
	avbtool verify_image --image "$BOOT_IMAGE" > "$run_dir/avb-verify.txt" 2>&1 ||
		die "AVB verification failed" 3
	if grep -Eq '(^|[[:space:]])hotdog_rescue_watchdog_sec=' "$BOOT_CMDLINE"; then
		die "Candidate command line arms an automatic rescue watchdog" 3
	fi
	grep -Eq '(^|[[:space:]])panic=0([[:space:]]|$)' "$BOOT_CMDLINE" ||
		die "Candidate command line does not pin panic=0" 3
	grep -Eq '(^|[[:space:]])console=ttyGS0,115200([[:space:]]|$)' "$BOOT_CMDLINE" ||
		die "Candidate command line lacks the USB serial console" 3

	log "Run directory: $run_dir"
	log "Pinned variant: $VARIANT"
	log "Candidate: $CANDIDATE_LABEL"
	log "All candidate and recovery artifacts are pinned and verified"
	log "Automatic recovery actions: none"
	if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
		log "Offline preflight complete; no phone transport was opened"
		return 0
	fi
	phone_lock_acquire "direct boot $VARIANT" 0 ||
		die "Could not acquire phone-operation lock" 3

	if [ "$START_MODE" = pmos-ssh ]; then
		attest_source_r6
		handoff_r6_to_fastboot
	else
		log "Starting from manually exposed Fastboot"
	fi
	attest_fastboot
	flash_candidate
	phone_lock_release || true
	observe_candidate
}

main "$@"
