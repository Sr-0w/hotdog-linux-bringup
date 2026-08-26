// SPDX-License-Identifier: GPL-2.0-only
/*
 * Redemarre en demandant un mode au bootloader.
 *
 * busybox reboot n'accepte que [-d DELAY] [-nf] : il appelle reboot(RB_AUTOBOOT)
 * et ne transmet aucune chaine. Un « reboot bootloader » avec lui ne demande
 * donc rien, et l'echec qui en resulte ne dit rien du materiel. Ce port s'y est
 * laisse prendre une fois.
 *
 * Le mode ne voyage que par LINUX_REBOOT_CMD_RESTART2, dont le quatrieme
 * argument est la chaine. Le noyau la remet au reboot-mode enregistre, qui
 * l'ecrit la ou le bootloader la lira -- sur SM8150, le cookie IMEM a
 * 0x146bf65c et la raison PON du PMIC.
 *
 * Volontairement sans prefixe d'appareil : rien ici n'est propre au Hotdog, et
 * tout port Qualcomm sous busybox a le meme manque.
 *
 * Ce n'est pas un remplacant de reboot(8). Il ne demonte rien et ne previent
 * personne ; c'est au gestionnaire de services de le faire avant de l'appeler.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

/* ABI noyau. <sys/reboot.h> n'expose que les noms RB_*, et pas les memes selon
 * glibc ou musl ; les poser ici garde l'hote et la cible d'accord. */
#define LINUX_REBOOT_MAGIC1		0xfee1dead
#define LINUX_REBOOT_MAGIC2		672274793
#define LINUX_REBOOT_CMD_RESTART2	0xa1b2c3d4

static int usage(const char *argv0, int code)
{
	fprintf(code ? stderr : stdout,
		"Usage: %s <mode>\n"
		"\n"
		"  bootloader   entre dans fastboot au prochain demarrage\n"
		"  recovery     entre en recovery\n"
		"  <autre>      transmis tel quel au noyau\n"
		"\n"
		"Le systeme de fichiers n'est pas demonte : appelez ceci depuis\n"
		"le gestionnaire de services, ou synchronisez d'abord.\n",
		argv0);
	return code;
}

int main(int argc, char **argv)
{
	const char *mode;

	if (argc != 2)
		return usage(argv[0], 1);
	mode = argv[1];
	if (!strcmp(mode, "-h") || !strcmp(mode, "--help"))
		return usage(argv[0], 0);
	if (!*mode)
		return usage(argv[0], 1);

	sync();

	/* La fonction reboot() de la libc ne prend qu'un argument : lui passer
	 * les quatre de l'appel systeme rend EINVAL, et cet EINVAL ne dirait
	 * rien du materiel. Seul l'appel systeme transporte la chaine. */
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, mode);

	/* On n'arrive ici que si l'appel a echoue. */
	fprintf(stderr, "reboot(RESTART2, \"%s\"): %s\n", mode, strerror(errno));
	return 1;
}
