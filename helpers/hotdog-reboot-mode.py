#!/usr/bin/env python3
"""Redemarre en demandant un mode, par l'appel systeme qui le transporte.

busybox reboot n'accepte que [-d DELAY] [-nf] : il appelle reboot(RB_AUTOBOOT)
et ne transmet aucune chaine. Un `reboot bootloader` avec lui ne demande donc
rien du tout, et l'echec qui en resulte ne dit rien du materiel -- c'est le
piege dans lequel ce port est deja tombe une fois.

Le mode ne voyage que par LINUX_REBOOT_CMD_RESTART2, dont le quatrieme
argument est la chaine. Le noyau la remet au reboot-mode enregistre, qui
l'ecrit ou le bootloader la lira : ici le cookie IMEM a 0x146bf65c, plus la
raison PON du PMIC.

Usage:
    hotdog-reboot-mode.py bootloader
    hotdog-reboot-mode.py recovery
    hotdog-reboot-mode.py --dry-run bootloader    n'ecrit rien, montre l'appel
"""
import ctypes
import os
import sys

LINUX_REBOOT_MAGIC1 = 0xFEE1DEAD
LINUX_REBOOT_MAGIC2 = 672274793
LINUX_REBOOT_CMD_RESTART2 = 0xA1B2C3D4

# Ce que msm-poweroff.c ecrit en downstream, pour memoire : le cookie IMEM
# accompagne toujours une raison PON.
COOKIES = {
    "bootloader": 0x77665500,
    "recovery": 0x77665502,
    "rtc": 0x77665503,
}


def main():
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry = "--dry-run" in sys.argv
    if len(args) != 1:
        sys.exit(__doc__.strip().splitlines()[0])
    mode = args[0]

    cookie = COOKIES.get(mode)
    print("mode=%s%s" % (mode,
                         "  cookie IMEM attendu=0x%08x" % cookie if cookie else
                         "  (pas de cookie connu, le noyau decidera)"))
    if dry:
        print("dry-run : reboot(RESTART2, %r) non emis" % mode)
        return 0
    if os.geteuid() != 0:
        sys.exit("a lancer en root")

    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    libc.reboot.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int,
                            ctypes.c_char_p]
    os.sync()
    rc = libc.reboot(LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                     LINUX_REBOOT_CMD_RESTART2, mode.encode())
    # On n'arrive ici que si l'appel a echoue.
    err = ctypes.get_errno()
    sys.exit("reboot(RESTART2, %r) a echoue: rc=%d errno=%d (%s)"
             % (mode, rc, err, os.strerror(err)))


if __name__ == "__main__":
    sys.exit(main())
