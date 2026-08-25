/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-mcfg-runtime.h"
#include "hotdog-radio-readiness.h"
#include "hotdog-radio-supervisor.h"

#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <libqrtr-glib.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define DEFAULT_READINESS_PATH "/run/hotdog-radio/readiness"
#define DEFAULT_BOOT_ID_PATH "/proc/sys/kernel/random/boot_id"
#define DEFAULT_RUNTIME_MANIFEST "/usr/share/hotdog-radio/mcfg/MANIFEST"
#define DEFAULT_MCFG_ROOT "/usr/share/hotdog-radio/mcfg/mcfg_sw"
#define DEFAULT_BOOTSTRAP "/usr/libexec/hotdog-radio-bootstrapd"
#define DEFAULT_RC_SERVICE "/sbin/rc-service"

enum child_kind {
	CHILD_NONE,
	CHILD_START_MODEMMANAGER,
	CHILD_STOP_MODEMMANAGER,
	CHILD_REATTEST,
};

struct lifecycle {
	GMainLoop *loop;
	GCancellable *cancellable;
	QrtrBus *bus;
	GSubprocess *child;
	struct hotdog_radio_supervisor supervisor;
	char *readiness_path;
	char *boot_id_path;
	char *runtime_manifest;
	char *approval;
	char *bootstrap_path;
	char *rc_service_path;
	unsigned int node;
	unsigned int failure_limit;
	enum child_kind child_kind;
	gulong node_added_handler;
	gulong node_removed_handler;
	guint poll_id;
	bool attestation_attempted;
	bool approval_wait_logged;
	bool quitting;
	int result;
};

static void dispatch(struct lifecycle *lifecycle,
		     enum hotdog_supervisor_event event);
static void inspect_readiness(struct lifecycle *lifecycle, bool allow_reattest);

static void maybe_quit(struct lifecycle *lifecycle)
{
	if (lifecycle->quitting && !lifecycle->child &&
	    lifecycle->supervisor.phase == HOTDOG_SUPERVISOR_BLOCKED)
		g_main_loop_quit(lifecycle->loop);
}

static int read_line(const char *path, char *line, size_t size)
{
	struct stat status;
	FILE *stream;
	int descriptor;
	size_t length;

	descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (descriptor < 0)
		return -errno;
	if (fstat(descriptor, &status)) {
		int result = -errno;

		close(descriptor);
		return result;
	}
	if (!S_ISREG(status.st_mode)) {
		close(descriptor);
		return -EPERM;
	}
	stream = fdopen(descriptor, "r");
	if (!stream) {
		int result = -errno;

		close(descriptor);
		return result;
	}
	if (!fgets(line, size, stream)) {
		fclose(stream);
		return -EIO;
	}
	if (fclose(stream))
		return -EIO;
	length = strcspn(line, "\r\n");
	if (line[length] == '\0' && length == size - 1)
		return -EOVERFLOW;
	line[length] = '\0';
	return line[0] ? 0 : -ENODATA;
}

static int verify_readiness(struct lifecycle *lifecycle)
{
	struct hotdog_radio_readiness readiness;
	struct hotdog_mcfg_runtime runtime;
	char boot_id[HOTDOG_READINESS_BOOT_ID_SIZE + 2];
	int result;

	result = hotdog_radio_readiness_read(
		lifecycle->readiness_path, &readiness);
	if (result)
		return result;
	result = read_line(lifecycle->boot_id_path, boot_id, sizeof(boot_id));
	if (result)
		return result;
	if (strcmp(readiness.boot_id, boot_id))
		return -ESTALE;
	result = hotdog_mcfg_runtime_read(lifecycle->runtime_manifest, &runtime);
	if (result)
		return result;
	if (strcmp(readiness.modem_sha256, runtime.modem_sha256) ||
	    strcmp(readiness.mcfg_sha256, runtime.archive_sha256))
		return -ESTALE;
	return 0;
}

static int revoke_readiness(struct lifecycle *lifecycle)
{
	if (!unlink(lifecycle->readiness_path) || errno == ENOENT)
		return 0;
	g_printerr("readiness revoke failed: %s\n", g_strerror(errno));
	return -errno;
}

static void child_done(GObject *source, GAsyncResult *res, gpointer user_data)
{
	struct lifecycle *lifecycle = user_data;
	enum child_kind kind = lifecycle->child_kind;
	GError *error = NULL;
	bool successful;

	(void)source;
	successful = g_subprocess_wait_finish(lifecycle->child, res, &error) &&
		g_subprocess_get_successful(lifecycle->child);
	if (error) {
		g_printerr("child wait failed: %s\n", error->message);
		g_clear_error(&error);
	}
	g_clear_object(&lifecycle->child);
	lifecycle->child_kind = CHILD_NONE;
	switch (kind) {
	case CHILD_START_MODEMMANAGER:
		dispatch(lifecycle, successful ?
			 HOTDOG_SUPERVISOR_MODEMMANAGER_STARTED :
			 HOTDOG_SUPERVISOR_MODEMMANAGER_START_FAILED);
		break;
	case CHILD_STOP_MODEMMANAGER:
		if (!successful)
			lifecycle->result = 1;
		dispatch(lifecycle, successful ?
			 HOTDOG_SUPERVISOR_MODEMMANAGER_STOPPED :
			 HOTDOG_SUPERVISOR_MODEMMANAGER_STOP_FAILED);
		break;
	case CHILD_REATTEST:
		if (successful)
			inspect_readiness(lifecycle, false);
		else {
			lifecycle->result = 1;
			dispatch(lifecycle, HOTDOG_SUPERVISOR_FATAL);
		}
		break;
	case CHILD_NONE:
		lifecycle->result = 1;
		dispatch(lifecycle, HOTDOG_SUPERVISOR_FATAL);
		break;
	}
	maybe_quit(lifecycle);
}

static void child_spawn_failed(struct lifecycle *lifecycle, enum child_kind kind,
			       GError *error)
{
	g_printerr("child spawn failed: %s\n", error->message);
	g_clear_error(&error);
	switch (kind) {
	case CHILD_START_MODEMMANAGER:
		dispatch(lifecycle, HOTDOG_SUPERVISOR_MODEMMANAGER_START_FAILED);
		break;
	case CHILD_STOP_MODEMMANAGER:
		lifecycle->result = 1;
		dispatch(lifecycle, HOTDOG_SUPERVISOR_MODEMMANAGER_STOP_FAILED);
		break;
	case CHILD_REATTEST:
	case CHILD_NONE:
		lifecycle->result = 1;
		dispatch(lifecycle, HOTDOG_SUPERVISOR_FATAL);
		break;
	}
}

static void spawn_service(struct lifecycle *lifecycle, bool start)
{
	GError *error = NULL;
	enum child_kind kind = start ?
		CHILD_START_MODEMMANAGER : CHILD_STOP_MODEMMANAGER;

	if (lifecycle->child) {
		g_printerr("refusing overlapping child operation\n");
		lifecycle->result = 1;
		dispatch(lifecycle, HOTDOG_SUPERVISOR_FATAL);
		return;
	}
	lifecycle->child = g_subprocess_new(
		G_SUBPROCESS_FLAGS_NONE, &error, lifecycle->rc_service_path,
		"modemmanager", start ? "start" : "stop", NULL);
	if (!lifecycle->child) {
		child_spawn_failed(lifecycle, kind, error);
		return;
	}
	lifecycle->child_kind = kind;
	g_subprocess_wait_async(lifecycle->child, lifecycle->cancellable,
				child_done, lifecycle);
}

static bool approval_available(const struct lifecycle *lifecycle)
{
	return lifecycle->approval && lifecycle->approval[0] &&
		access(lifecycle->approval, R_OK) == 0;
}

static void spawn_reattest(struct lifecycle *lifecycle)
{
	char node[16];
	GError *error = NULL;

	if (!approval_available(lifecycle)) {
		if (!lifecycle->approval_wait_logged) {
			printf("reattest=waiting-for-approval\n");
			lifecycle->approval_wait_logged = true;
		}
		return;
	}
	lifecycle->approval_wait_logged = false;
	if (lifecycle->attestation_attempted || lifecycle->child)
		return;
	lifecycle->attestation_attempted = true;
	snprintf(node, sizeof(node), "%u", lifecycle->node);
	lifecycle->child = g_subprocess_new(
		G_SUBPROCESS_FLAGS_NONE, &error, lifecycle->bootstrap_path,
		"--node", node, "--mcfg-root", DEFAULT_MCFG_ROOT,
		"--apply-pdc", lifecycle->approval, "--defer-handoff", NULL);
	if (!lifecycle->child) {
		child_spawn_failed(lifecycle, CHILD_REATTEST, error);
		return;
	}
	lifecycle->child_kind = CHILD_REATTEST;
	printf("reattest=started generation=%u\n", lifecycle->supervisor.generation);
	g_subprocess_wait_async(lifecycle->child, lifecycle->cancellable,
				child_done, lifecycle);
}

static void execute_actions(struct lifecycle *lifecycle, uint32_t actions)
{
	if (actions & HOTDOG_SUPERVISOR_ACTION_REVOKE_READINESS)
		if (revoke_readiness(lifecycle)) {
			lifecycle->result = 1;
			lifecycle->supervisor.readiness_valid = false;
			dispatch(lifecycle, HOTDOG_SUPERVISOR_FATAL);
			return;
		}
	if (actions & HOTDOG_SUPERVISOR_ACTION_STOP_MODEMMANAGER)
		spawn_service(lifecycle, false);
	else if (actions & HOTDOG_SUPERVISOR_ACTION_START_MODEMMANAGER)
		spawn_service(lifecycle, true);
	else if (actions & HOTDOG_SUPERVISOR_ACTION_REATTEST)
		spawn_reattest(lifecycle);
	else if (actions & HOTDOG_SUPERVISOR_ACTION_READ_READINESS)
		inspect_readiness(lifecycle, true);
}

static void dispatch(struct lifecycle *lifecycle,
		     enum hotdog_supervisor_event event)
{
	uint32_t actions;
	int result;

	result = hotdog_radio_supervisor_reduce(
		&lifecycle->supervisor, event, &actions);
	printf("supervisor=phase:%s event:%u result:%d generation:%u actions:0x%x\n",
	       hotdog_supervisor_phase_name(lifecycle->supervisor.phase), event,
	       result, lifecycle->supervisor.generation, actions);
	if (!result)
		execute_actions(lifecycle, actions);
	else if (result != -EALREADY && result != -ESHUTDOWN) {
		lifecycle->result = 1;
		dispatch(lifecycle, HOTDOG_SUPERVISOR_FATAL);
	}
	maybe_quit(lifecycle);
}

static void inspect_readiness(struct lifecycle *lifecycle, bool allow_reattest)
{
	int result;

	if (!lifecycle->supervisor.qrtr_up || lifecycle->child)
		return;
	result = verify_readiness(lifecycle);
	if (!result) {
		if (lifecycle->supervisor.phase == HOTDOG_SUPERVISOR_WAIT_READINESS)
			dispatch(lifecycle, HOTDOG_SUPERVISOR_READINESS_VALID);
		return;
	}
	if (result == -ENOENT) {
		if (lifecycle->supervisor.phase == HOTDOG_SUPERVISOR_ACTIVE ||
		    lifecycle->supervisor.phase ==
			HOTDOG_SUPERVISOR_STARTING_MODEMMANAGER)
			dispatch(lifecycle, HOTDOG_SUPERVISOR_READINESS_REMOVED);
		else if (allow_reattest)
			spawn_reattest(lifecycle);
		return;
	}
	g_printerr("readiness verification failed: %d\n", result);
	dispatch(lifecycle, HOTDOG_SUPERVISOR_READINESS_INVALID);
}

static gboolean poll_readiness(gpointer user_data)
{
	struct lifecycle *lifecycle = user_data;

	if (!lifecycle->quitting &&
	    lifecycle->supervisor.phase != HOTDOG_SUPERVISOR_BLOCKED)
		inspect_readiness(lifecycle, true);
	return G_SOURCE_CONTINUE;
}

static void node_added(QrtrBus *bus, guint node_id, gpointer user_data)
{
	struct lifecycle *lifecycle = user_data;

	(void)bus;
	if (node_id != lifecycle->node)
		return;
	lifecycle->attestation_attempted = false;
	lifecycle->approval_wait_logged = false;
	dispatch(lifecycle, HOTDOG_SUPERVISOR_QRTR_UP);
}

static void node_removed(QrtrBus *bus, guint node_id, gpointer user_data)
{
	struct lifecycle *lifecycle = user_data;

	(void)bus;
	if (node_id != lifecycle->node)
		return;
	lifecycle->attestation_attempted = false;
	dispatch(lifecycle, HOTDOG_SUPERVISOR_QRTR_DOWN);
}

static void bus_ready(GObject *source, GAsyncResult *res, gpointer user_data)
{
	struct lifecycle *lifecycle = user_data;
	GError *error = NULL;

	(void)source;
	lifecycle->bus = qrtr_bus_new_finish(res, &error);
	if (!lifecycle->bus) {
		g_printerr("QRTR bus discovery failed: %s\n", error->message);
		g_clear_error(&error);
		lifecycle->result = 1;
		g_main_loop_quit(lifecycle->loop);
		return;
	}
	lifecycle->node_added_handler = g_signal_connect(
		lifecycle->bus, QRTR_BUS_SIGNAL_NODE_ADDED,
		G_CALLBACK(node_added), lifecycle);
	lifecycle->node_removed_handler = g_signal_connect(
		lifecycle->bus, QRTR_BUS_SIGNAL_NODE_REMOVED,
		G_CALLBACK(node_removed), lifecycle);
	if (qrtr_bus_peek_node(lifecycle->bus, lifecycle->node))
		dispatch(lifecycle, HOTDOG_SUPERVISOR_QRTR_UP);
}

static gboolean terminate(gpointer user_data)
{
	struct lifecycle *lifecycle = user_data;

	if (lifecycle->quitting)
		return G_SOURCE_REMOVE;
	lifecycle->quitting = true;
	if (lifecycle->child && lifecycle->child_kind == CHILD_REATTEST)
		g_subprocess_force_exit(lifecycle->child);
	dispatch(lifecycle, HOTDOG_SUPERVISOR_FATAL);
	maybe_quit(lifecycle);
	return G_SOURCE_REMOVE;
}

int main(int argc, char **argv)
{
	struct lifecycle lifecycle = {
		.node = 0,
		.failure_limit = 3,
	};
	GOptionContext *options;
	GError *error = NULL;
	GOptionEntry entries[] = {
		{ "node", 'n', 0, G_OPTION_ARG_INT, &lifecycle.node, "QRTR node", "ID" },
		{ "approval", 0, 0, G_OPTION_ARG_FILENAME, &lifecycle.approval,
		  "Boot-bound approval used for automatic re-attestation", "FILE" },
		{ "readiness", 0, 0, G_OPTION_ARG_FILENAME, &lifecycle.readiness_path,
		  "Readiness record", "FILE" },
		{ "boot-id", 0, 0, G_OPTION_ARG_FILENAME, &lifecycle.boot_id_path,
		  "Kernel boot ID", "FILE" },
		{ "runtime-manifest", 0, 0, G_OPTION_ARG_FILENAME,
		  &lifecycle.runtime_manifest, "Packaged MCFG manifest", "FILE" },
		{ "bootstrap", 0, 0, G_OPTION_ARG_FILENAME, &lifecycle.bootstrap_path,
		  "Radio bootstrap executable", "FILE" },
		{ "rc-service", 0, 0, G_OPTION_ARG_FILENAME, &lifecycle.rc_service_path,
		  "OpenRC service executable", "FILE" },
		{ "failure-limit", 0, 0, G_OPTION_ARG_INT, &lifecycle.failure_limit,
		  "Maximum consecutive ModemManager start failures", "COUNT" },
		{ NULL }
	};
	int result;

	options = g_option_context_new("- supervise Hotdog radio readiness");
	g_option_context_add_main_entries(options, entries, NULL);
	if (!g_option_context_parse(options, &argc, &argv, &error)) {
		g_printerr("option parsing failed: %s\n", error->message);
		g_clear_error(&error);
		g_option_context_free(options);
		result = 2;
		goto out;
	}
	g_option_context_free(options);
	if (!lifecycle.readiness_path)
		lifecycle.readiness_path = g_strdup(DEFAULT_READINESS_PATH);
	if (!lifecycle.boot_id_path)
		lifecycle.boot_id_path = g_strdup(DEFAULT_BOOT_ID_PATH);
	if (!lifecycle.runtime_manifest)
		lifecycle.runtime_manifest = g_strdup(DEFAULT_RUNTIME_MANIFEST);
	if (!lifecycle.bootstrap_path)
		lifecycle.bootstrap_path = g_strdup(DEFAULT_BOOTSTRAP);
	if (!lifecycle.rc_service_path)
		lifecycle.rc_service_path = g_strdup(DEFAULT_RC_SERVICE);
	if (!lifecycle.readiness_path || !lifecycle.boot_id_path ||
	    !lifecycle.runtime_manifest || !lifecycle.bootstrap_path ||
	    !lifecycle.rc_service_path || lifecycle.node > UINT16_MAX ||
	    !lifecycle.failure_limit || lifecycle.failure_limit > 10) {
		g_printerr("invalid supervisor configuration\n");
		result = 2;
		goto out;
	}
	hotdog_radio_supervisor_init(&lifecycle.supervisor, lifecycle.failure_limit);
	lifecycle.loop = g_main_loop_new(NULL, FALSE);
	lifecycle.cancellable = g_cancellable_new();
	lifecycle.poll_id = g_timeout_add_seconds(1, poll_readiness, &lifecycle);
	g_unix_signal_add(SIGINT, terminate, &lifecycle);
	g_unix_signal_add(SIGTERM, terminate, &lifecycle);
	qrtr_bus_new(1000, lifecycle.cancellable, bus_ready, &lifecycle);
	g_main_loop_run(lifecycle.loop);
	result = lifecycle.result;
	if (lifecycle.poll_id)
		g_source_remove(lifecycle.poll_id);
	if (lifecycle.bus && lifecycle.node_added_handler)
		g_signal_handler_disconnect(lifecycle.bus, lifecycle.node_added_handler);
	if (lifecycle.bus && lifecycle.node_removed_handler)
		g_signal_handler_disconnect(lifecycle.bus, lifecycle.node_removed_handler);
	if (lifecycle.child)
		g_subprocess_force_exit(lifecycle.child);
	g_clear_object(&lifecycle.child);
	g_clear_object(&lifecycle.bus);
	g_clear_object(&lifecycle.cancellable);
	g_main_loop_unref(lifecycle.loop);
out:
	g_free(lifecycle.readiness_path);
	g_free(lifecycle.boot_id_path);
	g_free(lifecycle.runtime_manifest);
	g_free(lifecycle.approval);
	g_free(lifecycle.bootstrap_path);
	g_free(lifecycle.rc_service_path);
	return result;
}
