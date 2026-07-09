# Source and build status

Date: 2026-07-09

## Repos utilises

| Repo | Chemin | Etat |
|---|---|---|
| pmbootstrap | `/home/srobin/dev/hotdog/src/postmarketos/pmbootstrap` | `pmbootstrap 3.10.1` |
| pmaports SM8150 | `/home/srobin/dev/hotdog/src/postmarketos/pmaports-sm8150` | `ffed2c841 Add device-oneplus-hotdog`, branche locale `main` ajoutee pour pmbootstrap |
| pmaports officiel | `/home/srobin/dev/hotdog/src/postmarketos/pmaports` | `0f9084b74` du 2026-07-07; contient `linux-postmarketos-qcom-sm8150` v6.17.0-r2. |
| kernel SM8150 6.8.7 | `/home/srobin/dev/hotdog/src/kernel/linux-sm8150-6.8.7` | `55916b64f2a1` |
| kernel qcom-sm8150 v6.17 | `/home/srobin/dev/hotdog/src/kernel/linux-postmarketos-qcom-sm8150-v6.17.0-sm8150` | tag `v6.17.0-sm8150`, commit `379d8fe35c7c`; patches pmOS officiels appliques + DTS hotdog local. |
| firmware hotdog | `/home/srobin/dev/hotdog/src/firmware/firmware-oneplus-hotdog` | `5e5c534 Add Modem firmware` |
| bkerler EDL | `/home/srobin/dev/hotdog/src/qualcomm/edl` | `51e1102`, Loaders submodule initialise, wrapper `tools/bin/edl` |
| linux-msm qdl | `/home/srobin/dev/hotdog/src/qualcomm/qdl` | `57a1ae9`, build Meson local, wrapper `tools/bin/qdl` |
| Linux mainline | `/home/srobin/dev/hotdog/src/kernel/linux-mainline` | clone complet |
| linux-next | `/home/srobin/dev/hotdog/src/kernel/linux-next` | clone complet |

## Correctifs locaux pmaports

| Fichier | Pourquoi |
|---|---|
| `device/testing/firmware-oneplus-hotdog/APKBUILD` | Nouveau paquet local firmware hotdog avec sous-paquets adreno/adsp/bluetooth/cdsp/modem/venus/wlan. |
| `device/testing/linux-postmarketos-sm8150-staging/APKBUILD` | `pkgname`, `_flavor`, `pkgrel=1`, patch DTB hotdog, et installation de `Image` non compresse comme `/boot/vmlinuz`. |
| `device/testing/linux-postmarketos-sm8150-staging/0001-arm64-dts-qcom-add-oneplus-hotdog.patch` | Ajoute `sm8150-oneplus-hotdog.dts` minimal, reserved memory stock `param_mem`/`mtp_mem`, et l'entree Makefile DTB. |
| `arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog-hwplus-usbc.dts` | Variante kernel-tree experimentale pour test: Type-C role-switch USB2 + Volume Up, sans USB3/GPU/display/touch/remoteproc. |
| `linux-postmarketos-qcom-sm8150-v6.17.0-sm8150/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dts` | DTS hotdog v6.17 derive de `sm8150-oneplus-guacamole.dts` + common: simplefb 1440x3120, touch S6SY761, reserved memory stock. |
| `linux-postmarketos-qcom-sm8150-v6.17.0-sm8150/arch/arm64/kernel/head.S` | Variante locale testee: `text_offset=0x80000` pour rapprocher l'Image ARM64 du kernel stock. |
| `device/testing/device-oneplus-hotdog/APKBUILD` | Ajout du script post-install manquant, exposition du sous-paquet wireplumber, shim `/usr/sbin/losetup`, correction `install_if` mainline firmware, `pkgrel=1`. |
| `device/testing/device-oneplus-hotdog/device-oneplus-hotdog.post-install` | Cree le shim `losetup` attendu par `postmarketos-mkinitfs` edge. |
| `device/testing/device-oneplus-hotdog/device-oneplus-hotdog-nonfree-firmware.post-install` | Active `tqftpserv` et `pd-mapper` au boot OpenRC. |

## Paquets construits

```text
device-oneplus-hotdog-1-r1.apk
device-oneplus-hotdog-mainline-firmware-1-r1.apk
device-oneplus-hotdog-nonfree-firmware-1-r1.apk
device-oneplus-hotdog-wireplumber-1-r1.apk
firmware-oneplus-hotdog-20241212-r0.apk
firmware-oneplus-hotdog-adreno-20241212-r0.apk
firmware-oneplus-hotdog-adsp-20241212-r0.apk
firmware-oneplus-hotdog-bluetooth-20241212-r0.apk
firmware-oneplus-hotdog-cdsp-20241212-r0.apk
firmware-oneplus-hotdog-modem-20241212-r0.apk
firmware-oneplus-hotdog-venus-20241212-r0.apk
firmware-oneplus-hotdog-wlan-20241212-r0.apk
linux-postmarketos-sm8150-staging-6.8.7-r1.apk
linux-oneplus-hotdog-lineage414-4.14.357_git20260703-r2.apk
```

Paquets dans:

```text
/home/srobin/dev/hotdog/pmbootstrap-work/packages/edge/aarch64
```

Mise a jour 2026-07-10 01:20 : le paquet local
`linux-oneplus-hotdog-lineage414` a ete reconstruit en `r2` apres promotion du
DTB pack entry12 simplefb avec `ranges;` sous `/chosen`.

```text
apk: /home/srobin/dev/hotdog/pmbootstrap-work/packages/edge/aarch64/linux-oneplus-hotdog-lineage414-4.14.357_git20260703-r2.apk
sha256: f50f98ee251f1f4658aba1ea6bfc8141db79359485e0b15076370c19702482ff
validation: ./scripts/pmbootstrap-hotdog.sh checksum linux-oneplus-hotdog-lineage414
build: ./scripts/pmbootstrap-hotdog.sh build --arch aarch64 linux-oneplus-hotdog-lineage414
```

## Etat `pmbootstrap install`

Commande testee :

```bash
/home/srobin/dev/hotdog/scripts/pmbootstrap-hotdog.sh install --zap --password 147147
```

Resultat :

```text
OK
Artifacts exportes vers /tmp/postmarketOS-export
Artifacts persistants copies vers images/pmos/2026-07-08-070531-console-uncompressed-ramoops
```

DTB SM8150 disponibles dans le paquet kernel :

```text
qcom/sm8150-hdk.dtb
qcom/sm8150-microsoft-surface-duo.dtb
qcom/sm8150-mtp.dtb
qcom/sm8150-oneplus-hotdog.dtb
qcom/sm8150-oneplus-hotdog-hwplus-usbc.dtb
qcom/sm8150-realme-x3.dtb
qcom/sm8150-sony-xperia-kumano-bahamut.dtb
qcom/sm8150-sony-xperia-kumano-griffin.dtb
```

Conclusion : le pipeline host/pmbootstrap est pret jusqu'a generation d'image
et le dump stock critique existe. Le travail actuel est le debug du retour
fastboot precoce avant initramfs. Les variantes 6.8 minimal, 6.8 hwplus-usbc,
v6.17 wiki-lineage et v6.17 no-EFI/android-header retournent toutes en fastboot
vers 6-7 secondes, avec `boot_b` restaure et recovery OK. La piste "kernel
payload EFI/MZ uniquement" est donc eliminee par l'essai v6.17 no-EFI avec
`text_offset=0x80000`. Le DTB stock12/DTBO5 bloque plus loin mais sans canal USB
exploitable; ne pas le retenter sans mecanisme de retour plus robuste.

Mise a jour 23:45 : l'enveloppe stock kernel+DTB avec ramdisk pmOS atteint
maintenant l'initramfs USB NCM (`172.16.42.1` pingable), mais pas encore SSH.
`pmos.debug-shell` standard a donne un port 23 fugace; une variante
direct-telnet-only a donc ete preparee avec telnet lance explicitement apres
`start_unudhcpd`, sans `pmos.debug-shell`, et watchdog `reboot -f`. La derniere
variante ajoute aussi un fallback `tcpsvd` sur le port 2323.

Mise a jour 2026-07-09 00:32 : l'enveloppe stock kernel+DTB avec ramdisk pmOS
depasse maintenant le stade NCM/telnet et boote le rootfs pmOS avec SSH USB
stable sur `172.16.42.1`. Le rootfs dans `super` est agrandi a ~13.1G,
`/dev/ptmx`/`devpts` sont corriges, et `sudo -n` comme `doas -n` donnent root.
`sudo` est le shim `doas-sudo-shim` sur ce rootfs; les scripts peuvent donc
utiliser `sudo -n`, mais la politique reste celle de `doas`.

## Verifications postmarketOS edge du 2026-07-09

Sources primaires consultees :

```text
https://postmarketos.org/edge/
https://postmarketos.org/edge/2026/05/15/losetup-option-removal-leading-to-boot-failure/
https://postmarketos.org/edge/2026/02/10/mkinitfs-2.8.0-break-boot/
https://postmarketos.org/edge/2026/03/18/sudo-rs-instead-of-doas/
https://raw.githubusercontent.com/sm8150-linux-mainline/pmaports/master/device/testing/device-oneplus-hotdog/deviceinfo
```

Constats :

```text
deviceinfo hotdog externe: header_version=0, append_dtb=true, flash_method=fastboot, system->super
postmarketOS edge 2026-05-15: regression losetup -v -> boot failure, corrigee par postmarketos-initramfs 3.10.2
postmarketOS edge 2026-02-10: mkinitfs 2.8.0 a cree des Android boot images incompatibles sur certains appareils; corrige par mkinitfs 2.9.0 / boot-deploy 0.23.0
postmarketOS edge 2026-03-18: nouvelles installations en sudo-rs, mais installs existantes gardent doas sans perte de fonctionnalite
```

Impact local :

```text
L'image external-style header0 append-DTB est le meilleur test "suivre l'externe au plus proche".
Le shim losetup local reste utile/defensif pour les initramfs edge Android-device.
Le rootfs actuel doas-sudo-shim n'exige pas de reflash sudo-rs; sudo -n et doas -n sont deja OK.
```

Artefact stock-kernel actuellement valide sur `boot_b` :

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-002100-stockkernel-pmosramdisk-superloop-grow-ptmx-rootwatchdog/boot-noefi-pmosdtb-watchdog-600s.img
sha256: 0f9df5f1b5347374958cfbafb82be5ab1dccce8e6674029db4979157c83e4408
log boot: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-002240
log SSH: /home/srobin/dev/hotdog/logs/pmos-usb-ssh-2026-07-09-002256
```

Le nouveau chemin de flash privilegie, sans repasser par fastboot tant que SSH
pmOS repond :

```text
/home/srobin/dev/hotdog/scripts/flash-boot-b-from-pmos-ssh.sh
log test valide: /home/srobin/dev/hotdog/logs/flash-boot-b-from-pmos-ssh-2026-07-09-003222
cycle reboot valide: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-004142
```

Les variantes direct-telnet restent des outils de secours historiques si SSH ne
revient pas apres un test mainline.

Artefacts v6.17 recents :

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-221528-noefi-617-wiki-lineage-watchdog
/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-221852
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-222900-noefi-617-android-header-watchdog
/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-223012
```

Artefact debug stock-kernel prioritaire :

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-235800-stockkernel-pmosramdisk-direct-telnet-dualport-rootwatchdog/boot-stockkernel-pmosramdisk-direct-telnet-dualport-rootwatchdog-600s-stockos-avb.img
sha256: d96d5740dc5ece7a9504e490be98fc44fc427fe020c8914e36d7f1e54e8f71a3
ports: 23/telnetd, 2323/tcpsvd fallback
```

Artefact mainline survival prepare ensuite :

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-000000-mainline617-survival-v2dtb-dualport-rootwatchdog/boot-mainline617-survival-v2dtb-dualport-rootwatchdog-600s-stockos-avb.img
sha256: 3785d41b5dd092cdb3bff1e0960a99b44917754003cbdeba0860eb35c73e3d98
format: Android boot header v2, DTB separe, page 4096, os 15.0.0/2025-08, AVB footer algorithm NONE
DTB: oneplus,hotdog / qcom,sm8150, msm-id 0x153 0x20000, board-id 8 0, oplus dtsi 0x4d59, pcb_range 0..0x37
ports: 23/telnetd, 2323/tcpsvd fallback
test telephone: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-004408 -> fastboot immediat
rollback: restore automatique boot_b stock-kernel pmOS, set_active b, reboot system, SSH revenu dans /home/srobin/dev/hotdog/logs/pmos-usb-ssh-2026-07-09-004438
```

Mise a jour 2026-07-09 01:30 : les variantes v6.17 mainline avec DTB
mainline unique continuent de revenir en fastboot immediat, meme avec l'entree
ARM64 stock-like (`branch`, `code1=0`, `text_offset=0x80000`) et une config
LLVM conservatrice (`RANDOMIZE_BASE=n`, `ARM64_BTI_KERNEL=n`, `ARM64_MTE=n`).
En revanche, le meme kernel mainline conservateur avec le pack DTB stock complet
dans le champ DTB du boot image ne revient plus en fastboot immediat : le
telephone reste sans USB/ADB/fastboot pendant 720 s, et le watchdog initramfs
n'est pas observe. Cela deplace la piste principale vers le handoff
DTB/DTBO : le bootloader accepte le pack stock, mais Linux mainline ne peut pas
progresser avec un DTB downstream stock.

Etat recovery actuel apres ce test : `boot_b` contient encore le candidat
hybride qui hang, le telephone n'est pas enumere USB, et un watcher de secours
tourne :

```text
/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-011334 -> timeout
/home/srobin/dev/hotdog/logs/rescue-boot-b-when-visible-2026-07-09-012749
watcher: restaure automatiquement boot_b vers l'image stock-kernel pmOS si fastboot/recovery ADB reapparait
```

Artefacts prepares mais a ne pas flasher avant restauration de `boot_b` :

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-014500-mainline617-external-appenddtb-header0-watchdog60/boot-mainline617-external-appenddtb-header0-watchdog60-stockos-avb.img
  image mainline v6.17 conservatrice au format du pmaports externe: header v0, Image+DTB appendu, pas de DTB separe
  source verifiee: https://raw.githubusercontent.com/sm8150-linux-mainline/pmaports/master/device/testing/device-oneplus-hotdog/deviceinfo
  sha256 90d350e4c5d6cf6e68965149ce41b089aec178b9c5f1338213b7b16f4c37b15e

/home/srobin/dev/hotdog/build/experiments/2026-07-09-013000-stockpack-index12-mainline/stockpack-index12-mainline.dtb
  pack stock 20-FDT, index 12 remplace par sm8150-oneplus-hotdog.dtb mainline + metadata hotdog
  sha256 ebd56c04d4703756850ee881b0e7c19bac7320519c441727d3d51b95a2e53a31

/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-013200-mainline617-conservative-stockpack-index12-mainline-watchdog120/boot-mainline617-conservative-stockpack-index12-mainline-watchdog120-stockos-avb.img
  boot image AVB stock-size, watchdog 120s
  sha256 95dd764f5758a4faf7eaebef6f875b76d13b4fe1c5eb05bb62578d20111494fb

/home/srobin/dev/hotdog/build/experiments/2026-07-09-013000-noop-dtbo-entry5/dtbo_b-entry5-noop-partition-padded.img
  dtbo_b stock-size, entree 5 remplacee par overlay no-op hotdog
  sha256 972ea319caf9940dea1384ca2a26fedbe75b1045062b2c1cc760288409e41d09

restore dtbo_b stock si besoin :
/home/srobin/dev/hotdog/logs/partition-read-vbmeta-dtbo-clean-2026-07-08-230943/dtbo_b.img
sha256 95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672
```

Check rapide :

```bash
/home/srobin/dev/hotdog/scripts/check-dtb-status.sh
```

Mise a jour 2026-07-09 01:45 : `test-boot-b-image.sh` accepte maintenant
`--start-rescue-watcher`, `--rescue-watch-timeout` et `--rescue-watch-poll`.
Pour tout prochain test susceptible de couper USB, prearmer ce watcher; si le
test finit sans fastboot/ADB/telnet/SSH, le watcher reste vivant et restaurera
`boot_b` des que le telephone reapparait.

Commande wrapper preparee pour le prochain cycle apres restauration et retour
pmOS SSH :

```bash
/home/srobin/dev/hotdog/scripts/test-next-mainline-external-style.sh
```

Mise a jour 2026-07-09 08:20 : les trois tests DTB/DTBO prepares ont ete
executes et tous reviennent en fastboot immediat, avec restauration automatique
et retour pmOS SSH OK :

```text
external-style header0 append-DTB:
  log /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-081405
  result fastboot, restore boot_b OK, SSH /home/srobin/dev/hotdog/logs/pmos-usb-ssh-2026-07-09-081440

stockpack index12 remplace par mainline:
  log /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-081515
  result fastboot, restore boot_b OK, SSH /home/srobin/dev/hotdog/logs/pmos-usb-ssh-2026-07-09-081624

dtbo_b no-op entree 5 + DTB mainline unique:
  log /home/srobin/dev/hotdog/logs/test-mainline-noop-dtbo-2026-07-09-081929
  result fastboot, restore dtbo_b stock + boot_b stock OK, SSH /home/srobin/dev/hotdog/logs/pmos-usb-ssh-2026-07-09-082008
```

Conclusion locale : le probleme mainline n'est pas corrige par le format
bootimage pmaports externe, par la forme stockpack avec index 12 mainline, ni
par un DTBO no-op. Le prochain axe doit comparer plus directement le kernel
Image stock/downstream vs mainline, ou construire un kernel downstream minimal
qui conserve l'ABI de boot OnePlus mais remplace progressivement le ramdisk et
les options Linux.
