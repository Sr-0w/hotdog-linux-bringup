# Hardware status - OnePlus 7T Pro hotdog

Ce fichier est le suivi court et operationnel. La checklist complete reste dans :

```text
/home/srobin/Projects/OnePlus 7T Pro - Linux/oneplus_7t_pro_hwsupport.md
```

## Identite

| Item | Valeur |
|---|---|
| Appareil | OnePlus 7T Pro |
| Codename | `hotdog` |
| SoC | Qualcomm SM8150-AC / Snapdragon 855+ |
| Architecture | ARM64 |
| Objectif court | postmarketOS minimal + SSH USB |
| Objectif long | Gentoo ARM64 "pocket PC" dockable |

## Etat court

| Bloc | Etat | Prochaine preuve attendue |
|---|---|---|
| Android reference | partial | Dump ADB non-root dans `android-dumps/stock-before-flash/2026-07-07-225738-adb`. |
| Fastboot reference | partial | `android-dumps/stock-before-flash/2026-07-07-225936-fastboot`. |
| Slot A/B | known | Slot `b` actif pendant le boot pmOS SSH du 2026-07-09. Toujours verifier avant flash. |
| Bootloader unlocked | known | `unlocked: yes`, `secure: yes` via fastboot dump. |
| Panel | identified Android-side | Samsung SOFEF03F M FHD DSC cmd dans DTBO idx 5; non active mainline. |
| Touch | identified Android-side | `sec-s6sy761`, IRQ GPIO 122, reset GPIO 54; non active mainline. |
| USB gadget | SSH stable with stock kernel | Stock kernel+DTB + ramdisk pmOS expose NCM `172.16.42.1` et SSH; mainline candidates restent a valider. |
| Rootfs pmOS | OK stock-kernel | Root loop etendu a ~13.1G depuis `super`; ~11.8G libres apres premier boot. |
| PTY/devpts | OK stock-kernel | `/dev/ptmx -> pts/ptmx`, `devpts` monte avec `ptmxmode=666`; SSH TTY OK. |
| Privileges pmOS | OK | `sudo -n` et `doas -n` donnent root; `sudo` est le shim `doas-sudo-shim`. |
| boot_b depuis SSH | OK | `flash-boot-b-from-pmos-ssh.sh` a reflashe l'image courante et verifie le SHA relu depuis `boot_b`. |
| USB host/dock | unknown | test dock Android, puis Linux |
| Wi-Fi/BT firmware | unknown | `/vendor/firmware`, dmesg |
| Audio | unknown | `dumpsys audio`, vendor audio configs |
| Cameras | unknown | `dumpsys media.camera`, vendor camera files |
| Modem | unknown | Android props/baseband, later QRTR/QMI |
| Battery/charge | unknown | `dumpsys battery`, Linux power_supply |

## Etat Linux/mainline au 2026-07-09

| Bloc | Etat | Note |
|---|---|---|
| pmbootstrap config | OK | `edge`, `oneplus-hotdog`, `aarch64`, UI `console`. |
| Firmware packages | OK | `firmware-oneplus-hotdog-*` build depuis le depot firmware hotdog. |
| Device package | OK | `device-oneplus-hotdog-1-r1` build avec correctifs locaux. |
| Kernel package | OK | `linux-postmarketos-sm8150-staging-6.8.7-r1` rebuild avec kernel `Image` non compresse et DTB hotdog `ramoops`. |
| Kernel v6.17 qcom-sm8150 | built/tested | Clone officiel postmarketOS `v6.17.0-sm8150`, DTS hotdog derive de guacamole/common, QEMU OK; telephone retourne fastboot ~6s. |
| Initramfs | OK | `pmbootstrap install --zap --password 147147` termine. |
| DTB hotdog | first-pass OK | DTS minimal UFS + USB gadget + `ramoops@a9800000`, sans display/touch. |
| Image pmOS | OK | `images/pmos/2026-07-08-070531-console-uncompressed-ramoops`. |
| EDL tooling | OK | bkerler/edl local + loader OnePlus OP7T + udev `05c6:9008`. |
| Automation | OK pour boot_b SSH | Scripts de test/rescue/collecte prets; `flash-boot-b-from-pmos-ssh.sh` est le chemin prioritaire tant que SSH pmOS repond. |

DTB SM8150 construits actuellement :

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

Le DTB hotdog est un premier port local base sur `sm8150-mtp.dts`, ajoute via patch pmaports. Il inclut maintenant la zone `ramoops` vue dans le DTBO stock, mais il ne prouve pas encore que le boot Linux atteint USB ou UFS sur le telephone.
Le DTB experimental `sm8150-oneplus-hotdog-hwplus-usbc.dtb` reste base sur ce DTS minimal et ajoute seulement Type-C role-switch USB2 + Volume Up.

## Etat essais boot au 2026-07-09 00:32

| Candidate | Resultat | Note |
|---|---|---|
| stock kernel+DTB + ramdisk pmOS superloop grow/ptmx 002100 | SSH OK | `boot_b` courant; rootfs ~13.1G; `/dev/ptmx` OK; `sudo -n`/`doas -n` OK; SHA256 `0f9df5f1b5347374958cfbafb82be5ab1dccce8e6674029db4979157c83e4408`. |
| flash boot_b depuis pmOS SSH 003222 | OK | Reflash de l'image courante, ecriture `/dev/disk/by-partlabel/boot_b`, readback SHA OK; log `logs/flash-boot-b-from-pmos-ssh-2026-07-09-003222`. |
| cycle test depuis pmOS SSH 004142 | OK | Reflash image connue bonne, reboot sysrq, retour `pmos-ssh`; log `logs/test-boot-b-image-2026-07-09-004142`. |
| mainline617 survival v2dtb dualport 004408 | fastboot immediat | Image SHA256 `3785d41b5dd092cdb3bff1e0960a99b44917754003cbdeba0860eb35c73e3d98`; retour fastboot apres reboot, slot `b` retry-count `2`, restore automatique image stock-kernel pmOS, set_active b, reboot system, SSH revenu; log `logs/test-boot-b-image-2026-07-09-004408`. |
| mainline617 stock-entry LLVM 010226 | fastboot immediat | Header Image stock-like (`branch`, `code1=0`, `text_offset=0x80000`) avec DTB mainline unique; log `logs/test-boot-b-image-2026-07-09-010226`; rollback OK. |
| mainline617 noKASLR/noBTIK/noMTE 011159 | fastboot immediat | Config LLVM conservatrice + DTB mainline unique; log `logs/test-boot-b-image-2026-07-09-011159`; rollback OK. |
| mainline617 conservative + full stock DTB pack 011334 | timeout, pas USB | Le retour fastboot immediat disparait, mais aucun ADB/fastboot/NCM/SSH pendant 720s; watchdog initramfs non observe; `boot_b` non restaure par le script, watcher de rescue actif `logs/rescue-boot-b-when-visible-2026-07-09-012749`. |
| mainline617 external append-DTB header0 081405 | fastboot immediat | Suit le pmaports externe au plus proche: header v0, `Image+sm8150-oneplus-hotdog.dtb` appendu, pas de DTB separe, watchdog 60s, AVB footer `NONE`; SHA256 `90d350e4c5d6cf6e68965149ce41b089aec178b9c5f1338213b7b16f4c37b15e`; log `logs/test-boot-b-image-2026-07-09-081405`; restore boot_b OK, pmOS SSH revenu `logs/pmos-usb-ssh-2026-07-09-081440`. |
| mainline617 stockpack index12-mainline 081515 | fastboot immediat | Pack stock 20-FDT avec index 12 remplace par DTB mainline+metadata hotdog; SHA256 `95dd764f5758a4faf7eaebef6f875b76d13b4fe1c5eb05bb62578d20111494fb`; log `logs/test-boot-b-image-2026-07-09-081515`; restore boot_b OK, pmOS SSH revenu `logs/pmos-usb-ssh-2026-07-09-081624`. |
| mainline617 DTBO no-op entry5 + DTB mainline 081929 | fastboot immediat | `dtbo_b` remplace entree 5 par overlay no-op valide, puis boot_b mainline DTB unique; dtbo_b SHA256 `972ea319caf9940dea1384ca2a26fedbe75b1045062b2c1cc760288409e41d09`, boot SHA256 `874679ba67908da301570e23c1a593076236c7aa7d80609153af05cd446779c2`; log `logs/test-mainline-noop-dtbo-2026-07-09-081929`; restore dtbo_b stock + boot_b stock OK, pmOS SSH revenu `logs/pmos-usb-ssh-2026-07-09-082008`. |
| no-EFI + DTB pmOS local + watchdog | fastboot en ~7s | Rejet/retour tres tot, pas de SSH USB. |
| no-EFI + DTB pmOS symbols + watchdog | fastboot en ~7s | Meme comportement. |
| no-EFI + kernel mainline + DTB stock12/DTBO5 + watchdog | blocage logo OnePlus | Aucun ADB/fastboot/USB reseau/SSH. Watchdog initramfs non observe. |
| hybride stockDTB+ramoops 211953 | QEMU OK, non teste telephone | `/init`, pmOS stage 1/2 et watchdog observes en QEMU; ne prouve pas le hardware. |
| mainline-resmem 213349 | fastboot en ~6s | Test telephone `logs/test-boot-b-image-2026-07-08-214627`; `boot_b` restaure stock, retour recovery OK. |
| hwplus agressif 213645 | QEMU OK, non teste telephone | Overlay local active USB3/QMP/Type-C/GPU/GMU; plus risque, garder apres `hwplus-usbc`. |
| hwplus-usbc 215000 | fastboot en ~6s | Test telephone `logs/test-boot-b-image-2026-07-08-214720`; Type-C role-switch USB2 + Volume Up ne change pas le rejet precoce. |
| v6.17 wiki-lineage 221528 | fastboot en ~6s | Kernel postmarketOS qcom-sm8150 v6.17 + DTB hotdog derive guacamole/common, simplefb/touch/reserved-memory; QEMU OK; restore OK. |
| v6.17 no-EFI/android-header 222900 | fastboot en ~6s | Meme v6.17, mais kernel sans EFI/MZ et `text_offset=0x80000` comme stock; QEMU OK; restore OK. |
| external pmOS exact 001607 | fastboot en ~6s | Rootfs externe reflashee vers `super`; boot image header v0 append-DTB exact + variante AVB footer testees; toutes deux reviennent fastboot. |
| stock kernel+DTB + ramdisk pmOS 231438 | ping NCM, pas SSH | Header v2/stock kernel/stock DTB/AVB footer atteint `cdc_ncm`, host `172.16.42.2`, device ping `172.16.42.1`; pas de telnet/SSH. |
| stock kernel+DTB + ramdisk pmOS + `pmos.debug-shell` 232721 | ping NCM, telnet fugace | `172.16.42.1` ping stable; port 23 vu ouvert une fois puis ferme; pas de logs captures. Watchdog sysrq n'a pas reboot. |
| stock kernel direct-telnet rootwatchdog 233600 | pret, non flashe | Ajoute telnet direct via `/usr/bin/busybox-extras telnetd`, fallback `tcpsvd`, et `reboot -f` si rootfs non atteint. |
| stock kernel direct-telnet-only rootwatchdog 234800 | pret, prioritaire | Supprime `pmos.debug-shell`, garde telnet direct NCM, watchdog 600s et `reboot -f`; SHA256 `2fee6590f185f9a030eed0d40f3b6c611d55270fd468a827a105317accceee10`. |
| stock kernel direct-telnet dualport rootwatchdog 235800 | pret, prioritaire | Telnetd sur 23 + tcpsvd sur 2323, sans `pmos.debug-shell`, watchdog 600s; SHA256 `d96d5740dc5ece7a9504e490be98fc44fc427fe020c8914e36d7f1e54e8f71a3`. |
| mainline617 survival v2dtb direct-telnet 235200 | pret, non flashe | Header v2 + DTB separe dans enveloppe stock-like; modem/wifi/touch coupes; DTB symbols; SHA256 `2bc385eedeff3b5fecf2c2de4855f5b96943ba852aa3a0b80f54aaaa6aa91afa`. |
| mainline617 survival v2dtb dualport 000000 | teste 004408, fastboot immediat | Meme candidat mainline survival avec fallback tcpsvd 2323; SHA256 `3785d41b5dd092cdb3bff1e0960a99b44917754003cbdeba0860eb35c73e3d98`; rollback automatique OK. |

Collecte recovery validee apres reset manuel :

```text
/home/srobin/dev/hotdog/logs/manual-recovery-after-reset-2026-07-08-212433
/home/srobin/dev/hotdog/logs/recovery-collector-v2-2026-07-08-214300
/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-214627/recovery-crash-after-fastboot-return
/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-214720/recovery-crash-after-fastboot-return
```

Constats :

```text
pstore recovery: mount -t pstore -> No such device
ramoops recovery: /sys/devices/platform/a9800000.ramoops visible
support pstore recovery: symboles kmsg_dump visibles, aucun module pstore/ramoops expose
/dev/mem recovery: absent; dump physique a9800000 impossible depuis ce recovery
rawdump/logdump/logfs: pas de preuve claire de kernel 6.8/postmarketOS
rawdump: contient surtout un ancien panic Android "power key still pressed"
rawdump apres tests mainline-resmem/hwplus-usbc: SHA identique au dump recovery v2, donc pas de nouvelle trace exploitable
slot retry b: 7 -> 6 pendant chaque essai, puis 7 apres restore boot_b stock
```

Analyse stock utile :

```text
boot_b stock: Android boot image header v2, page size 4096, dtb address 0x01f00000
DTB stock extrait: 20 FDT concatennes, index 12 = dtsi 0x4d59/19801, msm-id 0x153 0x20000, board-id 8 0
DTB v6.17 local: DTB unique avec msm-id/board-id/dtsi_no correspondants
kernel stock: pas de MZ EFI, ARM64 text_offset 0x80000
kernel v6.17 no-EFI/android-header: pas de MZ EFI, ARM64 text_offset 0x80000, mais retour fastboot inchange
```

Validation rootfs externe 001607 :

```text
oneplus-hotdog.img sparse -> raw GPT 4096 OK
partition 1: ext2 LABEL=pmOS_boot UUID=d10f68cf-d261-401e-ac8f-dec17bd8a73e
partition 2: ext4 LABEL=pmOS_root UUID=95e0148f-5140-4acd-83ee-242b7eee8143
cmdline des boot images: pmos_boot_uuid=d10f68cf-d261-401e-ac8f-dec17bd8a73e pmos_root_uuid=95e0148f-5140-4acd-83ee-242b7eee8143
```

Conclusion actuelle :

```text
Changer recovery/bootloader/lk2nd n'est pas justifie par les sources publiques ni par les tests.
Le chemin externe canonique header v0 append-DTB ne boote pas sur ce boot stack: retour fastboot ~6s.
Le bootloader accepte en revanche une enveloppe stock kernel+DTB avec ramdisk pmOS: Linux/initramfs atteint USB NCM.
Le stock-kernel pmOS atteint maintenant le rootfs et SSH USB stable.
Priorite immediate: conserver le workflow de flash boot_b depuis pmOS SSH et ne revenir a fastboot/recovery qu'en secours.
Les tests du 2026-07-09 08:14-08:20 eliminent trois hypotheses :
1) le format external-style header v0 append-DTB ne suffit pas ;
2) conserver la forme pack stock 20-FDT mais remplacer index 12 par mainline ne suffit pas ;
3) neutraliser l'overlay DTBO stock entree 5 ne suffit pas.
Le retour fastboot est donc probablement plus proche du kernel Image/ABI de boot
OnePlus que d'un simple probleme de packaging DTB/DTBO.
Ne plus lancer de candidat susceptible de hang sans watcher de rescue.
```

Validation QEMU du dernier build :

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-211953-noefi-watchdog/qemu-watchdog-8s-nonic.log
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-213349-noefi-mainline-resmem-watchdog/qemu-watchdog-8s-nonic.log
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-213645-noefi-hwplus-watchdog/qemu-watchdog-8s-nonic.log
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-215000-noefi-hwplus-usbc-watchdog/qemu-watchdog-8s-nonic.log
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-221528-noefi-617-wiki-lineage-watchdog/qemu-watchdog-8s-nonic.log
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-222900-noefi-617-android-header-watchdog/qemu-watchdog-8s-nonic.log
```

## Premiere definition de succes

```text
1. recovery patchée boote avec ADB root autorise
2. dumps boot/dtbo/vbmeta/recovery sauvegardes
3. boot postmarketOS minimal sans flash permanent si possible
4. SSH USB stable
5. logs kernel/postmarketOS archives dans logs/
```
