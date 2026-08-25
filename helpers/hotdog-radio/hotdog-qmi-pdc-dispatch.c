/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-pdc-dispatch.h"

#include "hotdog-qmi-pdc.h"
#include "hotdog-qmi-pdc-load.h"

#include <errno.h>
#include <string.h>

static const struct hotdog_pdc_config *find_config(
	const struct hotdog_pdc_catalog *catalog, const struct hotdog_pdc_id *id)
{
	size_t index;

	if (!catalog || !id || !id->length)
		return NULL;
	for (index = 0; index < catalog->count; index++)
		if (hotdog_pdc_id_equal(&catalog->configs[index].id, id))
			return &catalog->configs[index];
	return NULL;
}

static int prepare_load(struct hotdog_qmi_pdc_request *request,
			const struct hotdog_pdc_catalog *catalog,
			const char *mcfg_root, uint32_t token)
{
	const struct hotdog_pdc_config *config = find_config(catalog,
							      &request->operation.id);
	uint32_t offset, size;
	int result;

	if (!config || !mcfg_root)
		return -ENOENT;
	result = hotdog_mcfg_profile_open(mcfg_root, config, &request->profile);
	if (result)
		return result;
	result = hotdog_pdc_load_init(&request->load_state, &config->id,
				      request->profile.size);
	if (result)
		return result;
	result = hotdog_pdc_load_next(&request->load_state, token, &offset, &size);
	if (result)
		return result;
	request->token = token;
	return hotdog_qmi_pdc_load_input(token, &config->id, request->profile.size,
					 request->profile.data + offset, size,
					 &request->input.load);
}

int hotdog_qmi_pdc_request_prepare(
	struct hotdog_qmi_pdc_request *request,
	const struct hotdog_pdc_operation *operation,
	const struct hotdog_pdc_catalog *catalog, const char *mcfg_root,
	uint32_t token)
{
	int result = 0;

	if (!request || !operation)
		return -EINVAL;
	memset(request, 0, sizeof(*request));
	request->operation = *operation;
	request->token = token;
	switch (operation->type) {
	case HOTDOG_PDC_SAVE_ACTIVE:
		request->type = HOTDOG_QMI_PDC_REQUEST_LOCAL;
		break;
	case HOTDOG_PDC_LOAD_CONFIG:
		request->type = HOTDOG_QMI_PDC_REQUEST_LOAD;
		if (!token)
			result = -EINVAL;
		else
			result = prepare_load(request, catalog, mcfg_root, token);
		break;
	case HOTDOG_PDC_SET_SELECTED:
	case HOTDOG_PDC_RESTORE_SELECTED:
		request->type = HOTDOG_QMI_PDC_REQUEST_SET;
		result = !token ? -EINVAL : hotdog_qmi_pdc_set_selected_input(
			operation->subscription, token, &operation->id, &request->input.set);
		break;
	case HOTDOG_PDC_ACTIVATE:
		request->type = HOTDOG_QMI_PDC_REQUEST_ACTIVATE;
		result = !token ? -EINVAL : hotdog_qmi_pdc_activate_input(
			operation->subscription, token, &request->input.activate);
		break;
	case HOTDOG_PDC_DEACTIVATE:
		request->type = HOTDOG_QMI_PDC_REQUEST_DEACTIVATE;
		result = !token ? -EINVAL : hotdog_qmi_pdc_deactivate_input(
			operation->subscription, token, &request->input.deactivate);
		break;
	case HOTDOG_PDC_DELETE_CONFIG:
		request->type = HOTDOG_QMI_PDC_REQUEST_DELETE;
		result = !token ? -EINVAL : hotdog_qmi_pdc_delete_input(
			token, &operation->id, &request->input.delete_config);
		break;
	case HOTDOG_PDC_VERIFY_ACTIVE:
		request->type = HOTDOG_QMI_PDC_REQUEST_VERIFY;
		result = !token ? -EINVAL : hotdog_qmi_pdc_get_selected_input(
			operation->subscription, token, &request->input.verify);
		break;
	case HOTDOG_PDC_SWITCH_MODEM:
		request->type = HOTDOG_QMI_PDC_REQUEST_SWITCH;
		break;
	}
	if (result)
		hotdog_qmi_pdc_request_clear(request);
	return result;
}

int hotdog_qmi_pdc_request_load_next(struct hotdog_qmi_pdc_request *request,
				     uint32_t token)
{
	uint32_t offset, size;
	int result;

	if (!request || request->type != HOTDOG_QMI_PDC_REQUEST_LOAD || !token ||
	    request->load_state.awaiting || request->load_state.complete ||
	    request->load_state.cleanup_required)
		return -EINVAL;
	if (request->input.load) {
		qmi_message_pdc_load_config_input_unref(request->input.load);
		request->input.load = NULL;
	}
	result = hotdog_pdc_load_next(&request->load_state, token, &offset, &size);
	if (result)
		return result;
	request->token = token;
	return hotdog_qmi_pdc_load_input(token, &request->load_state.id,
					 request->profile.size,
					 request->profile.data + offset, size,
					 &request->input.load);
}

void hotdog_qmi_pdc_request_clear(struct hotdog_qmi_pdc_request *request)
{
	if (!request)
		return;
	switch (request->type) {
	case HOTDOG_QMI_PDC_REQUEST_LOAD:
		if (request->input.load)
			qmi_message_pdc_load_config_input_unref(request->input.load);
		break;
	case HOTDOG_QMI_PDC_REQUEST_SET:
		if (request->input.set)
			qmi_message_pdc_set_selected_config_input_unref(request->input.set);
		break;
	case HOTDOG_QMI_PDC_REQUEST_ACTIVATE:
		if (request->input.activate)
			qmi_message_pdc_activate_config_input_unref(request->input.activate);
		break;
	case HOTDOG_QMI_PDC_REQUEST_DEACTIVATE:
		if (request->input.deactivate)
			qmi_message_pdc_deactivate_config_input_unref(request->input.deactivate);
		break;
	case HOTDOG_QMI_PDC_REQUEST_DELETE:
		if (request->input.delete_config)
			qmi_message_pdc_delete_config_input_unref(request->input.delete_config);
		break;
	case HOTDOG_QMI_PDC_REQUEST_VERIFY:
		if (request->input.verify)
			qmi_message_pdc_get_selected_config_input_unref(request->input.verify);
		break;
	case HOTDOG_QMI_PDC_REQUEST_LOCAL:
	case HOTDOG_QMI_PDC_REQUEST_SWITCH:
		break;
	}
	hotdog_mcfg_profile_clear(&request->profile);
	memset(request, 0, sizeof(*request));
}
