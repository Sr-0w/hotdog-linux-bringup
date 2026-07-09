#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

struct font {
	unsigned int width;
	unsigned int height;
	unsigned int glyphs;
	unsigned int bytes_per_glyph;
	unsigned char *data;
};

struct dumb_fb {
	uint32_t handle;
	uint32_t fb_id;
	uint32_t pitch;
	uint64_t size;
	uint32_t *map;
};

struct drm_state {
	int fd;
	uint32_t connector_id;
	uint32_t crtc_id;
	drmModeModeInfo mode;
	struct dumb_fb fb[2];
	unsigned int front;
	bool active;
};

struct terminal {
	char *cells;
	unsigned int rows;
	unsigned int cols;
	unsigned int row;
	unsigned int col;
	int esc;
};

static volatile sig_atomic_t running = 1;

static void on_signal(int sig)
{
	(void)sig;
	running = 0;
}

static void die(const char *msg)
{
	fprintf(stderr, "hotdog-drm-console: %s: %s\n", msg, strerror(errno));
	exit(1);
}

static uint32_t rd32(const unsigned char *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int load_psf(const char *path, struct font *font)
{
	unsigned char hdr[32];
	FILE *fp = fopen(path, "rb");
	if (!fp)
		return -1;

	if (fread(hdr, 1, sizeof(hdr), fp) != sizeof(hdr)) {
		fclose(fp);
		errno = EINVAL;
		return -1;
	}

	memset(font, 0, sizeof(*font));

	if (hdr[0] == 0x36 && hdr[1] == 0x04) {
		unsigned int mode = hdr[2];
		font->glyphs = (mode & 0x01) ? 512 : 256;
		font->bytes_per_glyph = hdr[3];
		font->height = hdr[3];
		font->width = 8;
		fseek(fp, 4, SEEK_SET);
	} else if (rd32(hdr) == 0x864ab572) {
		unsigned int header_size = rd32(hdr + 8);
		font->glyphs = rd32(hdr + 16);
		font->bytes_per_glyph = rd32(hdr + 20);
		font->height = rd32(hdr + 24);
		font->width = rd32(hdr + 28);
		fseek(fp, (long)header_size, SEEK_SET);
	} else {
		fclose(fp);
		errno = EINVAL;
		return -1;
	}

	if (!font->glyphs || !font->bytes_per_glyph || !font->width || !font->height) {
		fclose(fp);
		errno = EINVAL;
		return -1;
	}

	size_t bytes = (size_t)font->glyphs * font->bytes_per_glyph;
	font->data = calloc(1, bytes);
	if (!font->data) {
		fclose(fp);
		return -1;
	}

	if (fread(font->data, 1, bytes, fp) != bytes) {
		fclose(fp);
		free(font->data);
		memset(font, 0, sizeof(*font));
		errno = EINVAL;
		return -1;
	}

	fclose(fp);
	return 0;
}

static int choose_connector(struct drm_state *drm, drmModeRes *res, drmModeConnector **out,
			    uint32_t wanted)
{
	for (int i = 0; i < res->count_connectors; i++) {
		drmModeConnector *conn = drmModeGetConnector(drm->fd, res->connectors[i]);
		if (!conn)
			continue;
		if ((wanted && conn->connector_id == wanted) ||
		    (!wanted && conn->connection == DRM_MODE_CONNECTED && conn->count_modes > 0)) {
			*out = conn;
			return 0;
		}
		drmModeFreeConnector(conn);
	}
	errno = ENODEV;
	return -1;
}

static uint32_t choose_crtc(struct drm_state *drm, drmModeRes *res, drmModeConnector *conn,
			    uint32_t wanted)
{
	if (wanted)
		return wanted;

	if (conn->encoder_id) {
		drmModeEncoder *enc = drmModeGetEncoder(drm->fd, conn->encoder_id);
		if (enc) {
			uint32_t crtc = enc->crtc_id;
			drmModeFreeEncoder(enc);
			if (crtc)
				return crtc;
		}
	}

	for (int e = 0; e < conn->count_encoders; e++) {
		drmModeEncoder *enc = drmModeGetEncoder(drm->fd, conn->encoders[e]);
		if (!enc)
			continue;
		for (int c = 0; c < res->count_crtcs; c++) {
			if (enc->possible_crtcs & (1 << c)) {
				uint32_t crtc = res->crtcs[c];
				drmModeFreeEncoder(enc);
				return crtc;
			}
		}
		drmModeFreeEncoder(enc);
	}

	return 0;
}

static void create_fb(struct drm_state *drm, struct dumb_fb *fb)
{
	struct drm_mode_create_dumb creq;
	struct drm_mode_map_dumb mreq;

	memset(&creq, 0, sizeof(creq));
	creq.width = drm->mode.hdisplay;
	creq.height = drm->mode.vdisplay;
	creq.bpp = 32;
	if (ioctl(drm->fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0)
		die("DRM_IOCTL_MODE_CREATE_DUMB");

	fb->handle = creq.handle;
	fb->pitch = creq.pitch;
	fb->size = creq.size;

	if (drmModeAddFB(drm->fd, creq.width, creq.height, 24, 32, fb->pitch,
			 fb->handle, &fb->fb_id) != 0)
		die("drmModeAddFB");

	memset(&mreq, 0, sizeof(mreq));
	mreq.handle = fb->handle;
	if (ioctl(drm->fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0)
		die("DRM_IOCTL_MODE_MAP_DUMB");

	fb->map = mmap(NULL, fb->size, PROT_READ | PROT_WRITE, MAP_SHARED,
		       drm->fd, (off_t)mreq.offset);
	if (fb->map == MAP_FAILED)
		die("mmap dumb fb");
}

static void destroy_fb(struct drm_state *drm, struct dumb_fb *fb)
{
	struct drm_mode_destroy_dumb dreq;

	if (fb->map && fb->map != MAP_FAILED)
		munmap(fb->map, fb->size);
	if (fb->fb_id)
		drmModeRmFB(drm->fd, fb->fb_id);
	if (fb->handle) {
		memset(&dreq, 0, sizeof(dreq));
		dreq.handle = fb->handle;
		ioctl(drm->fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
	}
	memset(fb, 0, sizeof(*fb));
}

static int drm_init(struct drm_state *drm, const char *device, uint32_t connector_id,
		    uint32_t crtc_id, unsigned int mode_index)
{
	drmModeRes *res;
	drmModeConnector *conn = NULL;

	memset(drm, 0, sizeof(*drm));
	drm->fd = open(device, O_RDWR | O_CLOEXEC);
	if (drm->fd < 0)
		return -1;

	res = drmModeGetResources(drm->fd);
	if (!res)
		return -1;

	if (choose_connector(drm, res, &conn, connector_id) != 0)
		return -1;

	if (mode_index >= (unsigned int)conn->count_modes)
		mode_index = 0;

	drm->connector_id = conn->connector_id;
	drm->crtc_id = choose_crtc(drm, res, conn, crtc_id);
	if (!drm->crtc_id) {
		errno = ENODEV;
		return -1;
	}
	drm->mode = conn->modes[mode_index];

	create_fb(drm, &drm->fb[0]);
	create_fb(drm, &drm->fb[1]);

	drmModeFreeConnector(conn);
	drmModeFreeResources(res);
	return 0;
}

static void drm_cleanup(struct drm_state *drm)
{
	if (drm->active)
		drmModeSetCrtc(drm->fd, drm->crtc_id, 0, 0, 0, NULL, 0, NULL);
	destroy_fb(drm, &drm->fb[0]);
	destroy_fb(drm, &drm->fb[1]);
	if (drm->fd >= 0)
		close(drm->fd);
}

static uint32_t rgb(unsigned int r, unsigned int g, unsigned int b)
{
	return ((r & 0xff) << 16) | ((g & 0xff) << 8) | (b & 0xff);
}

static void clear_fb(struct drm_state *drm, struct dumb_fb *fb, uint32_t color)
{
	unsigned int width = drm->mode.hdisplay;
	unsigned int height = drm->mode.vdisplay;
	unsigned int stride = fb->pitch / 4;

	for (unsigned int y = 0; y < height; y++) {
		uint32_t *row = fb->map + y * stride;
		for (unsigned int x = 0; x < width; x++)
			row[x] = color;
	}
}

static void draw_glyph(struct drm_state *drm, struct dumb_fb *fb, struct font *font,
		       unsigned int x, unsigned int y, unsigned char ch,
		       uint32_t fg, uint32_t bg)
{
	unsigned int stride = fb->pitch / 4;
	unsigned int bytes_per_row = (font->width + 7) / 8;
	unsigned int glyph = ch < font->glyphs ? ch : '?';
	unsigned char *src = font->data + glyph * font->bytes_per_glyph;

	for (unsigned int gy = 0; gy < font->height; gy++) {
		if (y + gy >= drm->mode.vdisplay)
			break;
		uint32_t *dst = fb->map + (y + gy) * stride + x;
		for (unsigned int gx = 0; gx < font->width; gx++) {
			if (x + gx >= drm->mode.hdisplay)
				break;
			unsigned char byte = src[gy * bytes_per_row + gx / 8];
			bool on = byte & (0x80 >> (gx % 8));
			dst[gx] = on ? fg : bg;
		}
	}
}

static void term_init(struct terminal *term, unsigned int cols, unsigned int rows)
{
	memset(term, 0, sizeof(*term));
	term->cols = cols;
	term->rows = rows;
	term->cells = malloc((size_t)cols * rows);
	if (!term->cells)
		die("malloc terminal cells");
	memset(term->cells, ' ', (size_t)cols * rows);
}

static void term_scroll(struct terminal *term)
{
	memmove(term->cells, term->cells + term->cols, (size_t)term->cols * (term->rows - 1));
	memset(term->cells + (size_t)term->cols * (term->rows - 1), ' ', term->cols);
	if (term->row)
		term->row--;
}

static void term_put(struct terminal *term, unsigned char ch)
{
	if (term->esc) {
		if (term->esc == 1 && ch == '[') {
			term->esc = 2;
			return;
		}
		if (term->esc == 2) {
			if (ch >= '@' && ch <= '~')
				term->esc = 0;
			return;
		}
		if ((ch >= '@' && ch <= '~') || ch == '\n')
			term->esc = 0;
		return;
	}
	if (ch == 0x1b) {
		term->esc = 1;
		return;
	}
	if (ch == '\r') {
		term->col = 0;
		return;
	}
	if (ch == '\n') {
		term->col = 0;
		term->row++;
		if (term->row >= term->rows)
			term_scroll(term);
		return;
	}
	if (ch == '\b' || ch == 0x7f) {
		if (term->col > 0)
			term->col--;
		term->cells[(size_t)term->row * term->cols + term->col] = ' ';
		return;
	}
	if (ch == '\t') {
		unsigned int next = (term->col + 8) & ~7U;
		while (term->col < next)
			term_put(term, ' ');
		return;
	}
	if (ch < 32)
		return;

	term->cells[(size_t)term->row * term->cols + term->col] = (char)ch;
	term->col++;
	if (term->col >= term->cols) {
		term->col = 0;
		term->row++;
		if (term->row >= term->rows)
			term_scroll(term);
	}
}

static void term_write(struct terminal *term, const char *buf, ssize_t len)
{
	for (ssize_t i = 0; i < len; i++)
		term_put(term, (unsigned char)buf[i]);
}

static void term_write_cstr(struct terminal *term, const char *s)
{
	term_write(term, s, (ssize_t)strlen(s));
}

static void render(struct drm_state *drm, struct font *font, struct terminal *term)
{
	struct dumb_fb *fb = &drm->fb[0];
	unsigned int margin_x = 16;
	unsigned int margin_y = 16;
	uint32_t bg = rgb(0, 0, 0);
	uint32_t fg = rgb(225, 255, 225);
	uint32_t header = rgb(120, 255, 120);

	clear_fb(drm, fb, bg);
	for (unsigned int row = 0; row < term->rows; row++) {
		for (unsigned int col = 0; col < term->cols; col++) {
			unsigned char ch = (unsigned char)term->cells[(size_t)row * term->cols + col];
			uint32_t color = row < 3 ? header : fg;
			draw_glyph(drm, fb, font, margin_x + col * font->width,
				   margin_y + row * font->height, ch, color, bg);
		}
	}

	drmModeDirtyFB(drm->fd, fb->fb_id, NULL, 0);
	if (!drm->active) {
		if (drmModeSetCrtc(drm->fd, drm->crtc_id, fb->fb_id, 0, 0,
				   &drm->connector_id, 1, &drm->mode) != 0)
			die("drmModeSetCrtc");
		drm->active = true;
	}
}

static int spawn_shell(int *pty_master)
{
	pid_t pid = forkpty(pty_master, NULL, NULL, NULL);
	if (pid < 0)
		return -1;
	if (pid == 0) {
		setenv("TERM", "dumb", 1);
		execl("/bin/sh", "sh", "-i", NULL);
		_exit(127);
	}
	return pid;
}

static void write_all(int fd, const char *s)
{
	size_t len = strlen(s);
	while (len) {
		ssize_t n = write(fd, s, len);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return;
		}
		s += n;
		len -= (size_t)n;
	}
}

static void write_fd_all(int fd, const char *buf, size_t len)
{
	while (len) {
		ssize_t n = write(fd, buf, len);
		if (n < 0) {
			if (errno == EINTR || errno == EAGAIN)
				continue;
			return;
		}
		buf += n;
		len -= (size_t)n;
	}
}

static void transcript_write(FILE *fp, const char *buf, ssize_t len)
{
	if (!fp || len <= 0)
		return;
	fwrite(buf, 1, (size_t)len, fp);
	fflush(fp);
}

static void transcript_write_cstr(FILE *fp, const char *s)
{
	transcript_write(fp, s, (ssize_t)strlen(s));
}

int main(int argc, char **argv)
{
	const char *device = "/dev/dri/card0";
	const char *font_path = "/tmp/hotdog-ter-v32n.psf";
	const char *fifo_path = "/tmp/hotdog-drm-console.in";
	const char *transcript_path = "/tmp/hotdog-drm-console.transcript";
	uint32_t connector_id = 28;
	uint32_t crtc_id = 136;
	unsigned int mode_index = 0;
	struct drm_state drm;
	struct font font;
	struct terminal term;
	FILE *transcript = NULL;
	int pty_master;
	int fifo_fd = -1;
	int shell_pid;
	char buf[4096];
	time_t last_render = 0;
	const char *boot_script = NULL;
	const char *default_boot_script =
		"export TERM=dumb; PS1='hotdog# '; export PS1; "
		"printf '\\n--- hotdog pmOS command shell via DRM ---\\n'; "
		"printf 'boot_id: '; cat /proc/sys/kernel/random/boot_id; "
		"uname -a; "
		"printf '\\n--- recent display messages ---\\n'; dmesg | grep -i -E 'drm|dsi|fb|console' | tail -20; "
		"printf '\\n--- ready: commands are read from /tmp/hotdog-drm-console.in ---\\n'\n";

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--device") && i + 1 < argc)
			device = argv[++i];
		else if (!strcmp(argv[i], "--font") && i + 1 < argc)
				font_path = argv[++i];
			else if (!strcmp(argv[i], "--fifo") && i + 1 < argc)
				fifo_path = argv[++i];
			else if (!strcmp(argv[i], "--transcript") && i + 1 < argc)
				transcript_path = argv[++i];
			else if (!strcmp(argv[i], "--command") && i + 1 < argc)
				boot_script = argv[++i];
			else if (!strcmp(argv[i], "--connector") && i + 1 < argc)
				connector_id = (uint32_t)strtoul(argv[++i], NULL, 0);
			else if (!strcmp(argv[i], "--crtc") && i + 1 < argc)
				crtc_id = (uint32_t)strtoul(argv[++i], NULL, 0);
			else if (!strcmp(argv[i], "--mode-index") && i + 1 < argc)
				mode_index = (unsigned int)strtoul(argv[++i], NULL, 0);
			else {
				fprintf(stderr, "usage: %s [--device PATH] [--font PSF] [--fifo PATH] [--transcript PATH] [--command SHELL] [--connector ID] [--crtc ID] [--mode-index N]\n", argv[0]);
				return 2;
			}
		}
	if (!boot_script)
		boot_script = default_boot_script;

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	if (load_psf(font_path, &font) != 0)
		die("load PSF font");
	if (drm_init(&drm, device, connector_id, crtc_id, mode_index) != 0)
		die("init DRM");

	unsigned int cols = (drm.mode.hdisplay - 32) / font.width;
	unsigned int rows = (drm.mode.vdisplay - 32) / font.height;
	if (cols < 20 || rows < 10) {
		fprintf(stderr, "screen/font geometry too small\n");
		return 1;
	}
	term_init(&term, cols, rows);

	unlink(fifo_path);
		if (mkfifo(fifo_path, 0600) != 0 && errno != EEXIST)
			die("mkfifo");
	fifo_fd = open(fifo_path, O_RDONLY | O_NONBLOCK);
	if (fifo_fd < 0)
		die("open fifo");
	transcript = fopen(transcript_path, "w");
	if (transcript)
		setvbuf(transcript, NULL, _IOLBF, 0);

	shell_pid = spawn_shell(&pty_master);
	if (shell_pid < 0)
		die("spawn shell");
	fcntl(pty_master, F_SETFL, fcntl(pty_master, F_GETFL, 0) | O_NONBLOCK);

	term_write_cstr(&term, "hotdog DRM boot console\n");
	term_write_cstr(&term, "render: /dev/dri/card0 -> DSI-1, command FIFO: /tmp/hotdog-drm-console.in\n");
	term_write_cstr(&term, "host input: scripts/install-hotdog-drm-console.sh send '<command>'\n\n");
	render(&drm, &font, &term);

	write_all(pty_master, boot_script);

	while (running) {
		struct pollfd fds[2] = {
			{ .fd = pty_master, .events = POLLIN },
			{ .fd = fifo_fd, .events = POLLIN | POLLHUP },
		};
		int ret = poll(fds, 2, 100);
		bool dirty = false;
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			die("poll");
		}
		if (fds[0].revents & POLLIN) {
				ssize_t n;
				while ((n = read(pty_master, buf, sizeof(buf))) > 0) {
					term_write(&term, buf, n);
					transcript_write(transcript, buf, n);
					dirty = true;
				}
			}
			if (fds[1].revents & POLLIN) {
				ssize_t n;
				while ((n = read(fifo_fd, buf, sizeof(buf))) > 0) {
					transcript_write(transcript, "\n[host-input] ", 14);
					transcript_write(transcript, buf, n);
					write_fd_all(pty_master, buf, (size_t)n);
				}
			}
		if (fds[1].revents & POLLHUP) {
			close(fifo_fd);
			fifo_fd = open(fifo_path, O_RDONLY | O_NONBLOCK);
		}

		time_t now = time(NULL);
		if (dirty || now != last_render) {
			render(&drm, &font, &term);
			last_render = now;
		}

			if (waitpid(shell_pid, NULL, WNOHANG) == shell_pid) {
				close(pty_master);
				term_write_cstr(&term, "\n--- shell exited; respawning ---\n");
				transcript_write_cstr(transcript, "\n--- shell exited; respawning ---\n");
				shell_pid = spawn_shell(&pty_master);
				if (shell_pid < 0) {
					running = 0;
					continue;
				}
				fcntl(pty_master, F_SETFL, fcntl(pty_master, F_GETFL, 0) | O_NONBLOCK);
				write_all(pty_master, boot_script);
				render(&drm, &font, &term);
			}
	}

	kill(shell_pid, SIGTERM);
	close(pty_master);
	close(fifo_fd);
	if (transcript)
		fclose(transcript);
	unlink(fifo_path);
	drm_cleanup(&drm);
	free(term.cells);
	free(font.data);
	return 0;
}
