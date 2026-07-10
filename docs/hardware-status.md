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
| Panel | OK downstream DRM | Samsung SOFEF03F M FHD DSC cmd; `modetest -s 28@136:#0 -F smpte` affiche une mire visible sur le boot 4.14.357 stable; le helper DRM console affiche du texte sur l'image downstream courante; non active mainline. |
| Touch | identified Android-side | `sec-s6sy761`, IRQ GPIO 122, reset GPIO 54; non active mainline. |
| USB gadget | SSH stable with stock kernel | Stock kernel+DTB + ramdisk pmOS expose NCM `172.16.42.1` et SSH; mainline candidates restent a valider. |
| KMS display | OK downstream | `/dev/dri/card0`, driver `msm_drm`, connecteur DSI-1 id 28, CRTC 136, mode prefere `1440x3120`; helpers `scripts/show-stable-drm-pattern.sh` et `scripts/install-hotdog-drm-console.sh`. |
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
| Visual diagnostics | OK downstream | `--drm-console` injecte un helper DRM/KMS dans l'initramfs; `--drm-console-userspace` prepare en plus un service OpenRC `local.d` dans le rootfs pour retrouver un shell ecran apres `switch_root`. A porter ensuite vers les candidats mainline. |

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

## Etat essais boot au 2026-07-10 02:42

| Candidate | Resultat | Note |
|---|---|---|
| mainline617 pstorebuilt DRM console 224052 | timeout, pas USB, pstore vide | Kernel mainline reconstruit avec `CONFIG_PSTORE=y`, `CONFIG_PSTORE_RAM=y`, `CONFIG_PSTORE_CONSOLE=y`; image SHA256 `50b09d45c650ac6ba7234a53dbcdd064d425d7df8c524133652b36696148fb40`; aucun texte/USB/fastboot/recovery pendant 720s; fastboot manuel a `2026-07-10 00:17:58`, restore image `215005`, SSH revenu boot id `5a6cd93e-28c5-47dc-84fe-119534c8b2e1`; pstore monte mais reste vide. |
| lineage414 pmaports kernel screen shell 030600 | prepare, prochain test | Image SHA256 `c36b84a0299952569c6a21599a573aff123eee372b3417130f590eef274b91e4`; kernel pmaports `r2` SHA256 `c6411a83cc004d52209b39d9ac6fa552d93b5be719bbaa0536060c78e4d4266e`; initramfs SHA256 `e14c04d0e1b2ce580137c1aae6e37382308209e9aa92d5cb6af0a23233a448d7`; DTB pack SHA256 `9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040`; garde le chemin `024200`, ajoute `--visible-tty-shell` pour installer un shell/status follower sur tty1/tty0 apres `switch_root`, et active les args ramoops dans la cmdline. |
| lineage414 pmaports kernel fbcon buttons-rescan 024200 | prepare, depasse | Image SHA256 `1031e5b3e538e309facc3b024911e4845f6b42fa9768672d86d467e5f33893ca`; kernel pmaports `r2` SHA256 `c6411a83cc004d52209b39d9ac6fa552d93b5be719bbaa0536060c78e4d4266e`; initramfs SHA256 `c46832eb1141af0be82d1ee5ba0141a9a6d0308b8cbc5f6358f6370eec3ed4f3`; DTB pack SHA256 `9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040`; helper DRM SHA256 `4aec4bca3b6849fbb31a826adddce781146400bb3676b8503b387bc41dc8ffe8`; teste le kernel pmaports avec `VT`, `FB_SIMPLE`, `FRAMEBUFFER_CONSOLE`, `DRM_FBDEV_EMULATION`, plus le fixed DTB pack, le helper DRM auto-diagnostic, Vol+/Vol- et rescan local de `/dev/input/event*`; supersede par `030600`. |
| lineage414 pmaports kernel fbcon-only 025400 | prepare, test secondaire | Image SHA256 `aa176c852c3fe359839d18d80ff5d68f5ff0edaa2584c98e96362976083f8fca`; kernel pmaports `r2` SHA256 `c6411a83cc004d52209b39d9ac6fa552d93b5be719bbaa0536060c78e4d4266e`; initramfs SHA256 `496618344e3b3eda03c8bab22b33aec232c3a87613e08eebd401ae74e37c6a4a`; DTB pack SHA256 `9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040`; garde `--fb-test` mais strippe les hooks DRM herites pour isoler la sortie kernel/simplefb/fbcon. |
| lineage414 pmaports kernel fbcon 015500 | prepare, depasse | Image SHA256 `b50b29f7ea2a41e64b3a4bdb78ce2dc848f68915a75ec9d1ed4d7064c9727633`; kernel pmaports `r2` SHA256 `c6411a83cc004d52209b39d9ac6fa552d93b5be719bbaa0536060c78e4d4266e`; initramfs SHA256 `d9921ece8fb8b08ec593f16af1f3d9ac3d0410dc2f1511782eff38e7785a0201`; DTB pack SHA256 `9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040`; helper DRM SHA256 `fe8c9beea81e5e19c18affa1fc98252bc4adba81fa4b652df56cc24b9ce500e7`; supersede par `023410` puis `024200`, qui gardent le meme kernel/DTB et ajoutent les diagnostics locaux. |
| lineage414 simplefb ranges command-shell 014400 | prepare, fallback | Image SHA256 `f99529e3e626b44734e58bc16cb8df7fcbf5efbc76e144c27f19b43d5ea5cd3b`; initramfs SHA256 `899403669fdf5e9a42c8997cc648c66a4c7af9a67cd42bfb47611706e964a240`; base `215005`; DTB pack SHA256 `9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040`; helper DRM SHA256 `302fa020286d2c7941ad1d26c9d4d2ce775dad15665b49b56bdfde6f2b4b6b5b`; garde le kernel stable, ajoute `ranges;` sous `/chosen`, `--fb-test`, `--drm-console-userspace`, et un follower `dmesg` initramfs. |
| lineage414 simplefb ranges command-shell 013100 | prepare, non teste, depasse | Image SHA256 `bf7a6236e33a57f383d03daa490c054409b3529368c7b466dcd627199744faa2`; comportement proche de `014400`, mais sans follower `dmesg`, donc moins utile si l'ecran est le seul canal de sortie. |
| lineage414 simplefb ranges command-shell 011900 | prepare, non teste, depasse | Image SHA256 `2855c26423300eefca569c8f19f232494a5a84296af38441b43e161e1323e262`; comportement proche de `013100`, mais construit avant que le helper DRM soit reconstruisible depuis le repo. |
| lineage414 simplefb ranges 010900 | prepare, non teste, depasse | Image SHA256 `20ca331fd98c8f8a512574ed5984bc683716716b43348f977befac0dbe8f70fe`; base `215005`; meme DTB pack corrige, mais l'initramfs restait dans une boucle `dmesg`, donc moins utile pour le prochain test. |
| lineage414 DRM console userspace 005100 | prepare, non teste | Image SHA256 `646d5967ed6edfaf667209fa5601cf04ea69fd4bc0b4961f316f0b2a16cbeaf0`; base `215005`; ajoute l'option builder `--drm-console-userspace` pour copier `hotdog-drm-console` + police dans `/sysroot` et installer `/etc/local.d/hotdog-drm-console.start` avant `switch_root`. |
| mainline617 minramdisk DRM console 220520 | timeout, pas USB | Image SHA256 `aaf7ee6e4b9315369ba577d6a86d4e2a6111bdeaaf744902be0d3d24dad27af4`; ajoute helper DRM console au candidat minimal/pstore, mais aucun texte/USB/fastboot/recovery pendant 720s; fastboot manuel a 22:28:58, restore image `195300`, SSH revenu boot id `ce4726f0-952b-4571-bd9f-ab8eb4302648`, pstore vide, puis `boot_b` remis sur image `215005` sans reboot. |
| lineage414 DRM console initramfs 215020 | SSH OK + texte visible | Image downstream 4.14.357 avec helper DRM/KMS injecte dans l'initramfs; marqueur console a 2.029100s, `root-mounted` a 5.570778s, `switch-root` a 5.651583s; userspace visible via FIFO `/tmp/hotdog-drm-console.in`, preuve `POST_BOOT_DRM_CONSOLE_OK`, boot id `7854ea12-7415-41bc-8f2e-59d8865fd041`; SHA256 `1075757fe6c7a582b94c4a9f837cd71b830d36da8e29c60acba85c49e6c57019`. |
| stock kernel+DTB + ramdisk pmOS superloop grow/ptmx 002100 | SSH OK | Ancien jalon stable; rootfs ~13.1G; `/dev/ptmx` OK; `sudo -n`/`doas -n` OK; SHA256 `0f9df5f1b5347374958cfbafb82be5ab1dccce8e6674029db4979157c83e4408`. |
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
Le stock-kernel pmOS avec helper DRM console atteint aussi un affichage texte visible depuis l'initramfs, puis un shell userspace commande par FIFO apres `switch_root`; l'image preparee `005100` rend ce hook userspace auto-installable depuis le boot image.
Le `No memory resource` de simple-framebuffer a maintenant une hypothese concrete: le pack multi-DTB entry12 simplefb manquait `ranges;` sous `/chosen`; l'image preparee `030600` teste ce correctif avec le kernel pmaports configure pour VT/fbcon/simplefb, les diagnostics locaux Vol+/Vol-, et un shell/status follower tty1/tty0 apres `switch_root`, tandis que `014400` reste le fallback qui garde le kernel stable.
Le mainline 6.17 instrumente avec le meme helper DRM console ne donne toujours aucun signal visible/USB et ne laisse pas de pstore, meme avec `PSTORE_RAM` compile en dur; le blocage reste probablement avant initramfs utile, avant pstore exploitable, ou avant creation de `/dev/dri/card0`.
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
