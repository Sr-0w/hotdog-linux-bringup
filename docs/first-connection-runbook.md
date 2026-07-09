# First connection runbook

Objectif : reprendre vite quand le OnePlus 7T Pro revient en fastboot, dumper les partitions stock utiles depuis une recovery ADB patchée, puis tenter le premier boot postmarketOS console.

## 0. Avant de brancher

```bash
/home/srobin/dev/hotdog/scripts/check-host-tools.sh
/home/srobin/dev/hotdog/scripts/check-host-tools.sh --autopilot
```

Verifier que `adb`, `fastboot`, `b4`, `dtc` et les outils Android repondent.
Le mode `--autopilot` rend strictes les dependances du chemin complet
watchers/dump/flash/SSH.

Etat pmbootstrap attendu :

```text
Channel: edge
Device: oneplus-hotdog (aarch64)
UI: console
```

## 1. Etat actuel

Etat observe le 2026-07-09 00:32 :

```text
pmOS SSH USB       -> user@172.16.42.1, mot de passe 147147
kernel live        -> 4.14.356-openela-rc1-perf-gdd6ca02fc3f9
rootfs             -> /dev/loop1, 13.1G, ~11.8G libres
privileges         -> sudo -n et doas -n OK
PTY                -> /dev/ptmx -> pts/ptmx, devpts ptmxmode=666
boot_b courant     -> stock kernel+DTB + ramdisk pmOS superloop grow/ptmx
boot_b sha256      -> 0f9df5f1b5347374958cfbafb82be5ab1dccce8e6674029db4979157c83e4408
flash SSH boot_b   -> valide, ecriture + readback SHA OK
cycle SSH/reboot   -> valide, log test-boot-b-image-2026-07-09-004142
mainline 004408    -> fastboot immediat, rollback auto OK, SSH revenu
```

Image actuellement validee sur `boot_b` :

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-002100-stockkernel-pmosramdisk-superloop-grow-ptmx-rootwatchdog/boot-noefi-pmosdtb-watchdog-600s.img
```

Le chemin prioritaire n'est plus fastboot/recovery : tant que pmOS SSH reste
joignable, utiliser le flash local depuis le telephone vers `boot_b` :

```bash
/home/srobin/dev/hotdog/scripts/flash-boot-b-from-pmos-ssh.sh \
  --image /chemin/vers/boot.img
```

Ajouter `--reboot` seulement quand l'image a ete verifiee et que le test doit
commencer. Le script prend `logs/phone-operation.lock`, copie l'image sur pmOS,
utilise `sudo -n`, ecrit seulement `boot_b`, puis verifie le SHA relu depuis le
bloc. Le reboot force utilise maintenant `sync; echo b > /proc/sysrq-trigger`,
car `reboot -f` peut laisser une session SSH bloquee cote host. `sudo` est le
shim `doas-sudo-shim` sur ce rootfs; la politique effective reste donc celle de
`doas`, mais `sudo -n` fonctionne pour les scripts.

Historique recovery/fastboot utile :

Etat observe le 2026-07-08 22:30 :

```text
adb devices -l      -> b6bd2252 recovery usb:4-1 product:OnePlus7TPro model:HD1911
ro.boot.slot_suffix -> _b
ro.bootmode         -> recovery
boot_b sha256       -> d964e34f841a13a84d201cd44736f12ef105c96eea4fc72e428e05f8627f5f3f
fastboot devices -l -> aucun appareil
```

Le PC a de nouveau un recovery ADB exploitable. Toute nouvelle tentative de boot
Linux doit partir d'un script de test/recovery qui restaure `boot_b` et collecte
les artefacts au retour. Ne pas lancer Android normal tant que l'etat `boot_b`
n'a pas ete reverifie.

Collecte recovery la plus recente, avec probe pstore/ramoops et tentative
`/dev/mem` non fatale :

```text
/home/srobin/dev/hotdog/logs/recovery-collector-v2-2026-07-08-214300
```

Constat important : `a9800000.ramoops` existe dans recovery, mais `pstore` ne se
monte pas et `/dev/mem` n'existe pas, donc ce recovery ne permet pas encore de
lire directement la zone ramoops physique apres un boot bloque.

Constats stock/boot image ajoutes apres les essais v6.17 :

```text
boot_b stock: Android boot image header v2, page size 4096, dtb offset 0x01f00000
stock DTB blob: 20 FDT concatennes; l'index 12 correspond a dtsi 0x4d59/19801
stock DTB idx 12: msm-id 0x153 0x20000, board-id 8 0, pcb_range 0 0x37
kernel stock: pas de signature MZ, text_offset ARM64 0x80000
kernel v6.17 EFI initial: signature MZ, text_offset different -> suspect elimine
kernel v6.17 no-EFI/android-header: pas de MZ, text_offset 0x80000, mais meme retour fastboot ~6s
```

Etat observe sur photo le 2026-07-08 06:22 :

```text
Recovery 23.2 (20260703)
Product name: OnePlus7TPro
Active slot: b
Message: Can't load Android system
Reason: init_user0_failed
Options visibles: Try again, Factory data reset
```

Cet ecran a ete depasse manuellement par reset vers recovery. Si un prochain
essai coupe tous les canaux USB, le PC ne pourra de nouveau pas piloter le menu;
ne pas retenter les images connues bloquantes sans meilleure piste.

Commande d'armement recommandee :

```bash
/home/srobin/dev/hotdog/scripts/start-autopilot-watchers.sh --restart --serial b6bd2252 --timeout 604800 --state-poll 5 --stall-poll 30 --health-poll 60 --health-cooldown 300 --flash-timeout 900 --ssh-timeout 1200 --handoff-timeout 180
```

Watchers automatiques armes :

```bash
/home/srobin/dev/hotdog/scripts/watch-fastboot-dump.sh --timeout 604800 --sideload /home/srobin/dev/hotdog/tools/recovery-zips/build/hotdog-reboot-bootloader.zip --serial b6bd2252
/home/srobin/dev/hotdog/scripts/watch-edl-dump-critical.sh --timeout 604800
/home/srobin/dev/hotdog/scripts/continue-after-dump-to-pmos.sh --timeout 604800 --flash-timeout 900 --ssh-timeout 1200 --handoff-timeout 180 --serial b6bd2252
/home/srobin/dev/hotdog/scripts/watch-phone-state.sh --timeout 604800 --poll 5
/home/srobin/dev/hotdog/scripts/watch-stall-summary.sh --timeout 604800 --poll 30
/home/srobin/dev/hotdog/scripts/watch-adb-scrcpy.sh --timeout 604800 --poll 3 --serial b6bd2252
/home/srobin/dev/hotdog/scripts/watch-autopilot-health.sh --timeout 604800 --poll 60 --serial b6bd2252
```

Le serial cible de l'autopilot est le HD1911 observe `b6bd2252`.

Le watcher fastboot/ADB :

- si fastboot apparait, convertit d'abord fastbootd vers bootloader si necessaire, puis flashe la recovery ADB patchée et dumpe les blocs ;
- si ADB devient `device` ou `recovery`, reboot bootloader puis continue ;
- si ADB devient `sideload`, pousse le ZIP local `hotdog-reboot-bootloader.zip`.

Le watcher EDL :

- attend seulement `05c6:9008` ;
- utilise `tools/bin/edl` + le loader OnePlus OP7T local ;
- collecte GPT/storage info et tente `boot_a boot_b dtbo_a dtbo_b vbmeta_a vbmeta_b recovery_a recovery_b` en lecture seule.

Le watcher de continuation :

- attend un dump `*-recovery-root-blocks` ou `*-edl-critical-blocks` termine par `Done` ;
- exige `MANIFEST.txt`, `SHA256SUMS`, `sha256sum -c` OK, et les 8 images critiques non vides ;
- refuse un dump EDL si `failed-partitions.txt` contient une partition ;
- prend `logs/phone-operation.lock`, stoppe les watchers concurrents, sort d'EDL par `edl reset` si le telephone y reste, tente un handoff ADB/sideload/fastboot, puis lance le flash pmOS et l'attente SSH USB.

Le watcher d'etat :

- ne touche pas au telephone ;
- archive les transitions `adb`, `fastboot`, `lsusb`, descriptors USB et udev ;
- ecrit le resume courant dans `logs/watch-phone-state-*/latest-summary.txt`.

Le watcher de resume incident :

- ne touche pas au telephone ;
- rafraichit `logs/current-stall-summary.txt` ;
- garde un historique seulement quand l'etat live ou le diagnostic change.

Le watcher scrcpy :

- ne lance rien tant que l'appareil est `unauthorized`, `recovery`, `sideload`, fastboot ou EDL ;
- importe l'environnement KDE/Wayland de `kwin_wayland`, `plasmashell` ou `kded6` ;
- ouvre `scrcpy` automatiquement quand ADB passe en etat Android `device`.

Le watcher de sante autopilot :

- ne touche pas au telephone ;
- surveille que les six watchers principaux restent vivants ;
- ne redemarre rien pendant qu'un `logs/phone-operation.lock` est tenu ;
- rearme les six watchers principaux via `start-autopilot-watchers.sh --restart --no-health` si un watcher meurt hors operation telephone.

Statut synthetique :

```bash
/home/srobin/dev/hotdog/scripts/current-autopilot-status.sh
/home/srobin/dev/hotdog/scripts/summarize-stall.sh
```

Validation et controle non destructifs :

```bash
/home/srobin/dev/hotdog/scripts/validate-stock-dump.sh
/home/srobin/dev/hotdog/scripts/watch-autopilot-health.sh --check-once
/home/srobin/dev/hotdog/scripts/stop-autopilot-watchers.sh
```

## 2. Si SSH pmOS est perdu

Fastboot/recovery/telnet sont maintenant des chemins de secours. Si l'image
testee ne rend pas SSH, attendre d'abord les signaux initramfs `172.16.42.1:23`
ou `:2323`; si rien ne revient et que fastboot/recovery reapparait, restaurer
un boot stock-kernel pmOS connu bon avant de poursuivre.

## 3. Des que fastboot revient

Si le telephone revient apres le blocage ping-only du 2026-07-08 23:27, le
prochain test prioritaire n'est plus le flash recovery/dump stock : les dumps
critiques existent deja. Flasher d'abord l'image de debug direct-telnet :

```bash
/home/srobin/dev/hotdog/scripts/wait-and-test-direct-telnet.sh
```

Commande equivalente :

```bash
/home/srobin/dev/hotdog/scripts/test-boot-b-image.sh \
  --serial b6bd2252 \
  --image /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-235800-stockkernel-pmosramdisk-direct-telnet-dualport-rootwatchdog/boot-stockkernel-pmosramdisk-direct-telnet-dualport-rootwatchdog-600s-stockos-avb.img \
  --restore-boot-b /home/srobin/dev/hotdog/android-dumps/stock-before-flash/2026-07-08-062801-recovery-root-blocks/block-images/boot_b.img \
  --boot-wait 720 \
  --poll 2 \
  --fastboot-timeout 12
```

Le script sait maintenant distinguer `pmos-ping`, `pmos-telnet` et `pmos-ssh`.
Ne pas pre-scanner `172.16.42.1:23` avec `/dev/tcp` avant la collecte : utiliser
la connexion telnet de collecte du script pour ne pas consommer la premiere
session.

Lancer :

```bash
/home/srobin/dev/hotdog/scripts/flash-adb-recovery-and-dump-blocks.sh
```

Le script :

- attend fastboot ;
- refuse de flasher la recovery depuis fastbootd/userspace fastboot et tente d'abord `fastboot reboot bootloader` ;
- verifie le serial fastboot, `product` (`msmnile` ou `hotdog`), et refuse si fastboot rapporte un bootloader verrouille ;
- detecte le slot courant ;
- flashe `recovery_<slot>` avec `recovery-adb-unsecure.img` ;
- redemarre en recovery ;
- exige ADB autorise + root ;
- dumpe `boot_a boot_b dtbo_a dtbo_b vbmeta_a vbmeta_b recovery_a recovery_b`.

Sortie attendue :

```text
/home/srobin/dev/hotdog/android-dumps/stock-before-flash/<timestamp>-recovery-root-blocks
```

Si le telephone part en EDL Qualcomm, sortie attendue :

```text
/home/srobin/dev/hotdog/android-dumps/stock-before-flash/<timestamp>-edl-critical-blocks
```

## 4. Maintenance depuis pmOS SSH

L'objectif initial "boot minimal + SSH USB stable" est atteint avec le kernel
stock Android/Lineage et le rootfs pmOS dans `super`. Checks rapides :

```bash
sshpass -p 147147 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null user@172.16.42.1 \
  'uname -a; df -h /; mount | grep devpts; sudo -n id; doas -n id; ls -l /dev/disk/by-partlabel/boot_b /dev/sde38'
```

Etat attendu :

```text
/dev/loop1 sur /, taille ~13.1G
/dev/ptmx -> pts/ptmx
devpts avec ptmxmode=666
sudo -n id et doas -n id -> uid=0(root)
/dev/disk/by-partlabel/boot_b -> ../../sde38
```

## 5. Premier boot postmarketOS historique

Image console prete :

```text
/home/srobin/dev/hotdog/images/pmos/2026-07-08-070531-console-uncompressed-ramoops
```

Artifacts principaux :

```text
boot.img
boot-avb.img
oneplus-hotdog.img
dtbs/sm8150-oneplus-hotdog.dtb
SHA256SUMS
```

Chemin automatique arme :

```bash
/home/srobin/dev/hotdog/scripts/continue-after-dump-to-pmos.sh --timeout 604800 --flash-timeout 900 --ssh-timeout 1200 --handoff-timeout 180
```

Chemin manuel, seulement apres dump stock complet valide :

```bash
/home/srobin/dev/hotdog/scripts/flash-rootfs-and-boot-pmos.sh
```

Le script refuse de flasher tant qu'il ne trouve pas un dump complet. Il lance
`pmbootstrap flasher flash_rootfs`, puis `pmbootstrap flasher boot` pour un boot
temporaire. Il accepte fastbootd pour `flash_rootfs` vers `super`, mais convertit
fastbootd vers bootloader avant `flash_kernel` ou `fastboot boot`.
Avant d'attendre fastboot, il verifie aussi les hashes de
`images/pmos/2026-07-08-070531-console-uncompressed-ramoops/SHA256SUMS` et copie le manifest pmOS
dans son dossier de run.
Avant `flash_rootfs`, `flash_kernel` ou `boot`, il verifie aussi le serial
fastboot, `product` (`msmnile` ou `hotdog`), et refuse si fastboot rapporte un
bootloader verrouille.
Le verdict "dump complet" est centralise dans `scripts/stock-dump-lib.sh` et
peut etre inspecte avec `scripts/validate-stock-dump.sh`.
L'attente SSH pmOS est en mode `--host auto` par defaut : elle essaie
`172.16.42.1` et les voisins `172.16.42.*` visibles cote host, puis journalise
l'hote retenu.

Commandes pmbootstrap sous-jacentes si un debug manuel est necessaire :

```bash
/home/srobin/dev/hotdog/scripts/pmbootstrap-hotdog.sh flasher flash_rootfs
/home/srobin/dev/hotdog/scripts/pmbootstrap-hotdog.sh flasher boot
```

## 6. Verification host

```bash
/home/srobin/dev/hotdog/scripts/check-host-tools.sh
/home/srobin/dev/hotdog/scripts/check-dtb-status.sh
/home/srobin/dev/hotdog/scripts/pmbootstrap-hotdog.sh status
```

Paquets clefs actuels :

```text
linux-postmarketos-sm8150-staging-6.8.7-r1.apk
device-oneplus-hotdog-1-r1.apk
firmware-oneplus-hotdog-20241212-r0.apk
```

Premier objectif Linux : boot minimal + SSH USB stable. L'ecran noir ou le logo
OnePlus persistant peut etre normal tant que display/touch ne sont pas actifs,
mais l'absence complete de gadget USB/SSH reste un echec exploitable seulement
si le telephone revient seul en recovery/fastboot.

## 7. Etat des derniers essais

```text
2026-07-09 01:30:
  mainline v6.17 + DTB mainline unique:
    fastboot immediat, meme avec header Image stock-like et config conservatrice.
  mainline v6.17 + pack DTB stock complet:
    plus de fastboot immediat, mais hang sans USB pendant 720s.
    boot_b non restaure automatiquement car fastboot n'est pas revenu.
    watcher secours actif:
      /home/srobin/dev/hotdog/logs/rescue-boot-b-when-visible-2026-07-09-012749
  Ne pas flasher un nouveau boot avant restauration du boot_b stock-kernel pmOS.

2026-07-09 01:45:
  test-boot-b-image.sh peut maintenant prearmer un watcher compagnon:
    --start-rescue-watcher --rescue-watch-timeout 21600 --rescue-watch-poll 5
  Si le test time out sans canal USB, le watcher reste vivant et restaure boot_b
  des que fastboot ou recovery ADB reapparait. Toute image mainline risquee doit
  utiliser cette option.

  Artefact mainline a tester en premier apres restauration boot_b:
    /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-014500-mainline617-external-appenddtb-header0-watchdog60/boot-mainline617-external-appenddtb-header0-watchdog60-stockos-avb.img
    sha256 90d350e4c5d6cf6e68965149ce41b089aec178b9c5f1338213b7b16f4c37b15e
  Raison: suit le pmaports externe au plus proche avec le kernel v6.17 courant:
    Android boot header v0, Image+DTB appendu, pas de champ DTB separe.

  Commande wrapper preparee pour ce prochain cycle, a lancer seulement quand
  pmOS SSH est revenu apres restauration:
    /home/srobin/dev/hotdog/scripts/test-next-mainline-external-style.sh

2026-07-09 08:20:
  pmOS SSH stock-kernel est toujours la base saine. Apres chaque essai mainline,
  boot_b a ete restaure et SSH est revenu.

  Tests executes:
    external-style header0 append-DTB -> fastboot immediat
      /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-081405
    stockpack index12 remplace par DTB mainline -> fastboot immediat
      /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-081515
    dtbo_b entree 5 no-op + DTB mainline unique -> fastboot immediat
      /home/srobin/dev/hotdog/logs/test-mainline-noop-dtbo-2026-07-09-081929

  Restores verifies:
    boot_b stock-kernel pmOS restaure apres chaque test
    dtbo_b stock restaure apres le test no-op DTBO
    dernier SSH OK: /home/srobin/dev/hotdog/logs/pmos-usb-ssh-2026-07-09-082008

  Interpretation:
    Le probleme mainline ne vient pas seulement du header v2 vs header v0,
    du pack DTB, ou de l'overlay DTBO stock. La suite doit isoler le kernel
    Image/ABI OnePlus ou partir d'un kernel downstream fonctionnel et converger
    vers mainline progressivement.

no-EFI + DTB pmOS local + watchdog:
  retour fastboot en ~7s, pas de SSH USB.

no-EFI + DTB pmOS symbols + watchdog:
  retour fastboot en ~7s, pas de SSH USB.

no-EFI + kernel mainline + DTB stock12/DTBO5 + watchdog:
  blocage logo OnePlus, pas d'ADB/fastboot/USB reseau/SSH.
  Le watchdog initramfs n'a pas ete observe.

mainline-resmem + watchdog:
  QEMU OK.
  Telephone -> fastboot en ~6s, restore boot_b stock, retour recovery OK.
  /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-213349-noefi-mainline-resmem-watchdog/boot-noefi-pmosdtb-watchdog-90s.img
  /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-214627

hwplus-usbc + watchdog:
  QEMU OK.
  Telephone -> fastboot en ~6s, restore boot_b stock, retour recovery OK.
  Support ajoute: Type-C role-switch USB2 + Volume Up, sans USB3/GPU/display/touch.
  /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-215000-noefi-hwplus-usbc-watchdog/boot-noefi-pmosdtb-watchdog-90s.img
  /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-214720

v6.17 wiki-lineage + DTB derive guacamole/common + watchdog:
  QEMU OK.
  Telephone -> fastboot en ~6s, restore boot_b stock, retour recovery OK.
  Support ajoute par rapport aux 6.8 minimal/hwplus-usbc: base kernel postmarketOS qcom-sm8150 v6.17,
  simplefb 1440x3120, touch S6SY761 comme guacamole, reserved memory stock.
  /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-221528-noefi-617-wiki-lineage-watchdog/boot-noefi-pmosdtb-watchdog-90s.img
  /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-221852

v6.17 no-EFI/android-header + DTB derive guacamole/common + watchdog:
  QEMU OK.
  Telephone -> fastboot en ~6s, restore boot_b stock, retour recovery OK.
  Kernel payload rapproche du stock: pas de MZ EFI, text_offset ARM64 0x80000.
  Ce resultat elimine l'hypothese "rejet uniquement a cause du header kernel EFI".
  /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-222900-noefi-617-android-header-watchdog/boot-noefi-pmosdtb-watchdog-90s.img
  /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-223012

hwplus USB3/GPU + watchdog:
  QEMU OK, non teste telephone, plus risque.
  /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-213645-noefi-hwplus-watchdog/boot-noefi-pmosdtb-watchdog-90s.img
```

Collecte apres reset manuel :

```text
/home/srobin/dev/hotdog/logs/manual-recovery-after-reset-2026-07-08-212433
```

Verifier cette collecte :

```bash
sha256sum -c /home/srobin/dev/hotdog/logs/manual-recovery-after-reset-2026-07-08-212433/SHA256SUMS
sha256sum -c /home/srobin/dev/hotdog/logs/recovery-collector-v2-2026-07-08-214300/SHA256SUMS
sha256sum -c /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-214627/recovery-crash-after-fastboot-return/SHA256SUMS
sha256sum -c /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-214720/recovery-crash-after-fastboot-return/SHA256SUMS
sha256sum -c /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-221852/recovery-crash-after-fastboot-return/SHA256SUMS
sha256sum -c /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-223012/recovery-crash-after-fastboot-return/SHA256SUMS
```
