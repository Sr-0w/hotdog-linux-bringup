# OnePlus 7T Pro hotdog Linux bring-up

Espace de travail operationnel pour preparer le OnePlus 7T Pro avant branchement.

Latest state, 2026-07-09 20:38 CEST:

- stable pmOS boot exists on the downstream Lineage/OpenELA 4.14.357 kernel
- USB SSH works on the stable image at `user@172.16.42.1`
- DSI-1 can be held enabled from userspace with the DRM/Plymouth hook
- the latest mainline 6.17 test timed out without USB, fastboot, or recovery ADB
- a rescue watcher is armed to restore the stable image when the phone reappears

Canonical live status:

```text
docs/current-boot-cycle.md
```

Ce dossier sert aussi de base a un repo GitHub de continuation. Le futur repo
doit rester centre sur les notes, les scripts locaux, les patches texte et les
manifestes d'artefacts. Les gros arbres generes ou synchronises localement
restent hors Git:

Dans un clone sur un autre PC, lance les commandes depuis la racine du repo
avec les chemins relatifs ci-dessous.

- `src/` contient des checkouts externes, dont plusieurs ont leur propre `.git`
- `build/`, `downloads/`, `images/`, `logs/`, `reports/`, `pmbootstrap-work/`
  et `android-dumps/` restent des artefacts locaux
- `patches/` peut rester versionne parce que ce sont des diffs texte legers

Racine projet notes :

```text
/home/srobin/Projects/OnePlus 7T Pro - Linux
```

Racine travail :

```text
/home/srobin/dev/hotdog
```

## Commandes utiles

Verification de l'hote :

```bash
./scripts/check-host-tools.sh
./scripts/check-host-tools.sh --autopilot
```

Quand le telephone demarre Android normalement et que le debogage USB est autorise :

```bash
./scripts/collect-adb-reference.sh
```

Pour ajouter les fichiers vendor/odm non destructifs au dump Android :

```bash
./scripts/collect-adb-reference.sh --vendor-etc
```

Quand le telephone est en bootloader/fastboot :

```bash
./scripts/collect-fastboot-reference.sh
```

Precharger ou mettre a jour les sources utiles :

```bash
./scripts/bootstrap-sources.sh
```

Installer les outils extra hors Portage :

```bash
./scripts/install-extra-tools.sh
```

Outils Qualcomm locaux disponibles :

```text
tools/bin/edl
tools/bin/qdl
```

Verifier pmbootstrap :

```bash
cp pmbootstrap_v3.cfg.example pmbootstrap_v3.cfg
./scripts/pmbootstrap-hotdog.sh status
```

Les paquets firmware/device/kernel sont deja construits dans :

```text
/home/srobin/dev/hotdog/pmbootstrap-work/packages/edge/aarch64
```

Etat detaille des sources et du build :

```text
/home/srobin/dev/hotdog/docs/source-status.md
```

Etat courant du cycle de boot en cours :

```text
/home/srobin/dev/hotdog/docs/current-boot-cycle.md
```

Verifier le blocage DTB :

```bash
./scripts/check-dtb-status.sh
```

Quand le telephone revient en fastboot, flasher la recovery ADB patchée puis dumper
les partitions stock utiles :

```bash
./scripts/flash-adb-recovery-and-dump-blocks.sh
```

Commande d'armement recommandee :

```bash
./scripts/start-autopilot-watchers.sh --restart --serial b6bd2252 --timeout 604800 --state-poll 5 --stall-poll 30 --health-poll 60 --health-cooldown 300 --flash-timeout 900 --ssh-timeout 1200 --handoff-timeout 180
```

Watchers lances par cette commande :

```bash
./scripts/watch-fastboot-dump.sh --timeout 604800 --sideload ./tools/recovery-zips/build/hotdog-reboot-bootloader.zip --serial b6bd2252
./scripts/watch-edl-dump-critical.sh --timeout 604800
./scripts/continue-after-dump-to-pmos.sh --timeout 604800 --flash-timeout 900 --ssh-timeout 1200 --handoff-timeout 180 --serial b6bd2252
./scripts/watch-phone-state.sh --timeout 604800 --poll 5
./scripts/watch-stall-summary.sh --timeout 604800 --poll 30
./scripts/watch-adb-scrcpy.sh --timeout 604800 --poll 3 --serial b6bd2252
./scripts/watch-autopilot-health.sh --timeout 604800 --poll 60 --serial b6bd2252
```

Le lanceur cible explicitement le serial HD1911 observe `b6bd2252` pour eviter
d'agir sur un autre appareil ADB/fastboot. Le premier agit si fastboot,
ADB autorise, recovery ADB ou ADB sideload
apparait; s'il voit fastbootd/userspace fastboot, le script de flash tente
d'abord `fastboot reboot bootloader`, puis verifie `serialno`, `product`
(`msmnile` ou `hotdog`) et refuse si fastboot rapporte un bootloader verrouille.
Le second est read-only
et agit seulement si Qualcomm EDL `05c6:9008` apparait. Le troisieme attend un
dump stock complet et valide avant de prendre le relais : si besoin il sort
d'EDL par `edl reset`, exploite une fenetre ADB/sideload/fastboot, stoppe les
watchers concurrents, flashe le rootfs postmarketOS, accepte fastbootd pour
`super`, convertit vers bootloader avant le boot temporaire `boot.img`, verifie
aussi `serialno`, `product` (`msmnile` ou `hotdog`) et l'etat verrouillage avant
les actions fastboot, puis attend SSH USB. Le
quatrieme est passif et archive les transitions ADB/fastboot/USB. Le cinquieme
rafraichit `logs/current-stall-summary.txt` sans toucher au telephone. Le
sixieme lance `scrcpy` automatiquement si Android expose enfin un ADB autorise
en etat `device`. Le septieme surveille les six premiers et les rearme hors
operation telephone, sans se redemarrer lui-meme, si un watcher meurt.

Statut synthetique :

```bash
./scripts/current-autopilot-status.sh
./scripts/summarize-stall.sh
```

Verifier le dernier dump stock complet sans toucher au telephone :

```bash
./scripts/validate-stock-dump.sh
```

Controler les watchers sans envoyer de commande au telephone :

```bash
./scripts/watch-autopilot-health.sh --check-once
./scripts/stop-autopilot-watchers.sh
```

L'attente SSH postmarketOS utilise `--host auto` par defaut et reste limitee au
reseau USB postmarketOS `172.16.42.*`.

Image postmarketOS console prete :

```text
/home/srobin/dev/hotdog/images/pmos/2026-07-08-070531-console-uncompressed-ramoops
```

## Regle actuelle

Les scripts de collecte ne flashent rien par defaut. Le script
`flash-adb-recovery-and-dump-blocks.sh` flashe uniquement la recovery patchée
sur le slot fastboot courant apres avoir converti fastbootd vers bootloader si
necessaire, puis dumpe `boot`, `dtbo`, `vbmeta` et `recovery` si ADB
recovery/root devient disponible. Son manifest note les
empreintes SHA256 de la recovery patchée et des cles ADB publiques, sans
logger le contenu des cles.

Etat actuel cote telephone au 2026-07-08 22:30 :

```text
adb devices -l -> b6bd2252 recovery usb:4-1 product:OnePlus7TPro model:HD1911
slot actif     -> _b
bootmode       -> recovery
boot_b stock   -> d964e34f841a13a84d201cd44736f12ef105c96eea4fc72e428e05f8627f5f3f
```

Le dernier essai hybride no-EFI kernel mainline + DTB stock12/DTBO5 a bloque
sur le logo OnePlus sans ADB, fastboot, USB reseau postmarketOS ni SSH. Le
telephone a ete remis manuellement en recovery, `boot_b` a ete restaure et une
collecte recovery verifiee est disponible dans :

```text
/home/srobin/dev/hotdog/logs/manual-recovery-after-reset-2026-07-08-212433
```

La recovery expose bien `a9800000.ramoops`, mais `pstore` ne se monte pas
(`No such device`) et les dumps `rawdump/logdump/logfs` ne prouvent pas encore
que le kernel 6.8/postmarketOS a atteint `/init`. La collecte v2 a confirme
que `/dev/mem` n'est pas expose dans recovery, donc la zone physique ramoops ne
peut pas etre lue directement depuis cet environnement :

```text
/home/srobin/dev/hotdog/logs/recovery-collector-v2-2026-07-08-214300
```

Ne pas retester cette famille d'image bloquante sans piste de retour plus
robuste. Les operations telephone passent par le verrou partagé
`logs/phone-operation.lock` pour eviter deux actions concurrentes sur le meme
appareil.

## Continuation GitHub

Pour repartir sur un autre PC, le point d'entree conseille est
`./scripts/bootstrap-host.sh`. Il ne touche ni au telephone ni aux sous-repos et
sert seulement a verifier le terrain local, les docs de reprise et les chemins
d'artefacts les plus utiles.

Reprise rapide sur une machine neuve:

1. `git clone <url-du-repo>`
2. `cd <clone>`
3. `./scripts/bootstrap-host.sh`
4. Restitue seulement les artefacts dont tu as besoin depuis
   `docs/artifact-manifest.md`, ou regenere-les via les scripts du repo
5. `./scripts/bootstrap-host.sh --check-host`

Les documents de reference sont:

- `docs/repo-continuation.md`
- `docs/artifact-manifest.md`
- `docs/source-status.md`
- `docs/host-prep-status.md`
- `docs/current-boot-cycle.md`
- `pmbootstrap_v3.cfg.example`

Candidats testes/valides recents :

```text
1. mainline-resmem
   /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-213349-noefi-mainline-resmem-watchdog/boot-noefi-pmosdtb-watchdog-90s.img
   QEMU OK; telephone -> fastboot en ~6s; restore boot_b stock OK.
   Logs: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-214627

2. hwplus-usbc
   /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-215000-noefi-hwplus-usbc-watchdog/boot-noefi-pmosdtb-watchdog-90s.img
   QEMU OK; telephone -> fastboot en ~6s; restore boot_b stock OK.
   Logs: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-214720

3. v6.17 wiki-lineage
   /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-221528-noefi-617-wiki-lineage-watchdog/boot-noefi-pmosdtb-watchdog-90s.img
   Kernel postmarketOS qcom-sm8150 v6.17 + DTB hotdog derive guacamole/common.
   QEMU OK; telephone -> fastboot en ~6s; restore boot_b stock OK.
   Logs: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-221852

4. v6.17 no-EFI/android-header
   /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-222900-noefi-617-android-header-watchdog/boot-noefi-pmosdtb-watchdog-90s.img
   Kernel sans MZ EFI et ARM64 text_offset 0x80000 comme stock.
   QEMU OK; telephone -> fastboot en ~6s; restore boot_b stock OK.
   Logs: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-08-223012

5. hwplus USB3/GPU, QEMU OK mais plus risque, non teste telephone
   /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-08-213645-noefi-hwplus-watchdog/boot-noefi-pmosdtb-watchdog-90s.img
```

Constats qui evitent de repartir dans une mauvaise direction :

```text
boot_b stock: header Android boot v2, DTB field a 0x01f00000
DTB stock: 20 FDT concatennes; index 12 = dtsi 0x4d59/19801, msm-id 0x153 0x20000, board-id 8 0
kernel stock: pas de MZ EFI, text_offset 0x80000
kernel v6.17 no-EFI/android-header: pas de MZ EFI, text_offset 0x80000, mais fastboot ~6s quand meme
```

Cas recovery manuel observe : si l'ecran affiche `init_user0_failed` avec
`Factory data reset` et que le host ne voit plus aucun USB, le PC ne peut pas
piloter le menu. Laisser les watchers actifs et utiliser le menu physique pour
atteindre soit `Factory data reset`, soit un chemin bootloader/fastboot si
disponible.
