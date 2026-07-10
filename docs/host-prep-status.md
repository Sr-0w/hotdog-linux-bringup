# Host preparation status

Date : 2026-07-09

Machine : Gentoo Linux, OpenRC, x86_64, kernel `7.1.3-gentoo-dist-bin`.

## Pret

| Item | Etat | Note |
|---|---|---|
| Espace disque | OK | Environ 1.5 Tio libres sur `/home`. |
| Git | OK | `/usr/bin/git`. |
| Android tools | OK | `adb`, `fastboot`, `mkbootimg`, `unpack_bootimg`, `repack_bootimg`, `avbtool`, `mkdtboimg`, `lpunpack`. Reinstalle avec `USE=python` pour exposer les helpers Python. |
| Regles udev Android | OK | `51-android.rules` installees et udev recharge. |
| Groupe Android | OK | `srobin` ajoute au groupe `android`. Une nouvelle session utilisateur peut etre necessaire pour que les permissions USB soient visibles partout. |
| Device tree compiler | OK | `dtc` present. |
| Kernel build basics | OK | `make`, `bc`, `bison`, `flex`, `openssl`, `rsync`, `cpio`, `xz`. |
| LLVM/Clang | OK | Clang present, utilisable pour build ARM64 avec `LLVM=1`. |
| b4 | OK | `b4 0.14.3` installe via Portage. |
| git send-email | OK | Disponible via `git send-email`. |
| Go | OK | Disponible pour installer `payload-dumper-go`. |
| pmbootstrap | OK | `tools/bin/pmbootstrap`, config locale `pmbootstrap_v3.cfg`, workdir `pmbootstrap-work`. |
| pmbootstrap host deps | OK | `kpartx` et `losetup` disponibles. |
| payload-dumper-go | OK | Installe localement dans `tools/bin/payload-dumper-go`. |
| bkerler EDL | OK | Installe localement dans `src/qualcomm/edl`, wrapper `tools/bin/edl`, Loaders initialises. |
| linux-msm qdl | OK | Installe localement dans `src/qualcomm/qdl`, build Meson dans `tools/qdl-install`, wrapper `tools/bin/qdl`. |
| Regles udev EDL | OK | `/etc/udev/rules.d/52-hotdog-edl.rules` pour `05c6:9008`, `900e`, `9006` via groupe `plugdev`. |
| ModemManager | OK | Service OpenRC arrete; pas de conflit observe. |
| Serial console tools | OK | `picocom` et `minicom` installes. |
| Network debug tools | OK | `tcpdump` et `nmap` installes pour USB networking/SSH. |
| Cross-GCC AArch64 | OK via pmbootstrap | La toolchain Alpine a compile le kernel `linux-postmarketos-sm8150-staging`. |

## Build postmarketOS local

| Item | Etat | Note |
|---|---|---|
| Config pmbootstrap | OK | `edge`, `oneplus-hotdog`, `aarch64`, UI `console`, OpenRC. |
| Firmware hotdog | OK | Paquet local `firmware-oneplus-hotdog` cree et build. |
| Device package | OK | `device-oneplus-hotdog-1-r1.apk` build apres correctifs locaux. |
| Kernel package | OK | `linux-postmarketos-sm8150-staging-6.8.7-r1.apk` rebuild avec `/boot/vmlinuz` en `Image` ARM64 non compresse et `sm8150-oneplus-hotdog.dtb` avec `ramoops`. |
| Kernel v6.17 qcom-sm8150 | OK local | Clone officiel postmarketOS `v6.17.0-sm8150` build en variantes EFI et no-EFI/android-header; QEMU OK, telephone fastboot ~6s. |
| Image install | OK | `pmbootstrap install --zap --password 147147` termine. |
| Export image | OK | Artifacts persistants dans `images/pmos/2026-07-08-070531-console-uncompressed-ramoops`. |

## Etat telephone live

| Item | Etat | Action |
|---|---|---|
| Telephone | pmOS SSH USB | `user@172.16.42.1`, mot de passe `147147`, kernel stock Android/Lineage `4.14.356-openela-rc1-perf-gdd6ca02fc3f9`. |
| Ecran telephone | Non fiable pour le succes | Le logo/ecran noir ne suffit pas a juger; le signal de boot actuel est SSH USB. |
| Fastboot/recovery | Secours seulement | Ne les demander que si SSH/telnet/watchdog ne reviennent pas. |
| Flash boot_b depuis pmOS | OK | `flash-boot-b-from-pmos-ssh.sh` a reflashe l'image courante et verifie le SHA relu depuis `boot_b`. Utiliser ce flux en priorite. |
| Cycle test depuis pmOS | OK | `test-boot-b-image.sh --from-pmos-ssh` valide: image connue bonne -> reboot -> `pmos-ssh` (`logs/test-boot-b-image-2026-07-09-004142`). |
| Rollback mainline | OK | `mainline617 survival` -> fastboot immediat -> restore boot_b stock-kernel pmOS -> reboot system -> SSH revenu (`logs/test-boot-b-image-2026-07-09-004408`). |
| Rootfs pmOS | OK | `/dev/loop1` sur `/`, ~13.1G, ~11.8G libres. |
| Privileges pmOS | OK | `sudo -n` et `doas -n` fonctionnent; `sudo` est le shim `doas-sudo-shim`. |
| PTY pmOS | OK | `/dev/ptmx -> pts/ptmx`, `devpts` avec `ptmxmode=666`; SSH TTY OK. |
| Recovery patchée | Prete | `images/lineage/hotdog-20260703/recovery-adb-unsecure.img`, SHA256 `99f04ece06877cf30224e103f0e5099a1bd991174ca5c5aa1199b04eacc297d7`. |
| Lanceur autopilot | Disponible | Ne pas supposer qu'un background survive; preferer un watcher foreground pendant un essai risqué. |
| Watcher fastboot/ADB/sideload | Disponible | `watch-fastboot-dump.sh --timeout 604800 --sideload tools/recovery-zips/build/hotdog-reboot-bootloader.zip --serial b6bd2252`; loggue explicitement le plateau ADB `unauthorized`; le script de flash convertit fastbootd vers bootloader avant recovery, puis verifie `serialno`, `product` (`msmnile` ou `hotdog`) et bootloader non verrouille si rapporte. |
| Watcher EDL read-only | Disponible | `watch-edl-dump-critical.sh --timeout 604800`; utilise le loader OnePlus OP7T `000a50e100514985_2acf3a85fde334e2_fhprg_op7t.bin`. |
| Watcher continuation pmOS | Disponible | `continue-after-dump-to-pmos.sh --timeout 604800 --flash-timeout 900 --ssh-timeout 1200 --handoff-timeout 180 --serial b6bd2252`; attendre un candidat boot plus sûr avant de relancer. |
| Watcher etat passif | Disponible | `watch-phone-state.sh --timeout 604800 --poll 5`; archive ADB/fastboot/USB/descripteurs et lignes kernel USB host sans prendre le verrou telephone. |
| Watcher resume incident | Disponible | `watch-stall-summary.sh --timeout 604800 --poll 30`; rafraichit `logs/current-stall-summary.txt` sans prendre le verrou telephone. |
| Watcher scrcpy | Disponible | `watch-adb-scrcpy.sh --timeout 604800 --poll 3 --serial b6bd2252`; ouvre scrcpy automatiquement quand Android expose ADB `device`. |
| Watcher sante autopilot | Disponible | `watch-autopilot-health.sh --timeout 604800 --poll 60 --serial b6bd2252`; rearme les six watchers principaux si l'un meurt et si aucun verrou telephone n'est tenu; `--check-once` verifie sans redemarrer. |
| Controle watchers | Pret | `stop-autopilot-watchers.sh` stoppe health puis les six watchers sans commande telephone; refuse si `phone-operation.lock` est actif sauf `--force`. |
| Validation dump stock | Pret | `validate-stock-dump.sh` utilise la meme logique que continuation/flash pour exiger `MANIFEST.txt`, `Done`, `SHA256SUMS` OK et 8 images critiques. |
| Preflight autopilot | Pret | `check-host-tools.sh --autopilot` echoue si `lsusb`, `udevadm`, `sshpass`, `scrcpy`, EDL, recovery patchée, ZIP sideload ou images pmOS ne sont pas utilisables. |
| Attente SSH pmOS | Validee | `wait-pmos-usb-ssh.sh` a collecte le premier boot dans `logs/pmos-usb-ssh-2026-07-09-002256`. |
| Collecte crash recovery | Pret | `collect-recovery-crash-artifacts.sh` capture maintenant aussi `/proc/iomem`, support pstore/ramoops kernel, kallsyms, `/dev/mem`, et tente non fatalement la lecture brute `a9800000` si disponible. |
| Verrou operations telephone | OK | `logs/phone-operation.lock`; evite les chevauchements entre dump, EDL et flash pmOS. |
| SSH key pmOS | Optionnel | Aucune cle publique SSH trouvee pendant `pmbootstrap init`; ajouter une cle avant une image de boot si SSH immediat est voulu. |

## Garder prudent avant dump complet

- Tant que SSH pmOS repond, preferer `flash-boot-b-from-pmos-ssh.sh` a fastboot/recovery.
- Eviter de relancer l'hybride no-EFI + DTB stock12/DTBO5 sans meilleure hypothese de debug ou retour automatique.
- Les candidats `mainline-resmem`, `hwplus-usbc`, `v6.17 wiki-lineage` et `v6.17 no-EFI/android-header` retournent tous fastboot en ~6s; ne plus varier seulement Type-C/header kernel.
- Garder l'overlay USB3/GPU pour apres une preuve que le boot depasse le retour fastboot precoce.
- Eviter de flasher `boot`, `dtbo`, `vbmeta` ou `super` sans restore/rollback documente et image stock valide.
- Ne pas changer de slot sans noter le slot actif.
- Ne pas supposer que l'ecran, le tactile ou le dock USB-C marchent sous Linux avant les premiers bootlogs.
- Le watcher EDL est read-only. Ne pas lancer de commande `edl w`, `e`, `ws`, `wl`, `qfil` ou `setactiveslot` sans decision explicite.
