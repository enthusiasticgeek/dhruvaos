/* Host-side ASAN/UBSAN test driver for DharaFS + crypto/bignum logic
 * lifted directly from kernel_main.vani (via kernel_gen_patched.c --
 * see unstatic.py's own comment for why the generated file needs
 * patching before a separate translation unit can call into it).
 *
 * Deliberately calls the CORE logic functions (the _raw variants, and
 * dharafs_list_dir_raw only ever in "classify" mode with query_len >
 * 0), never the existing `_self_test` wrapper functions -- those call
 * uart_puts/uart_putc, which lower to raw MMIO pointer dereferences
 * baked directly into the generated C (compiler builtins, not
 * interceptable extern calls) and would segfault dereferencing an
 * unmapped hardware address on a host process. dharafs_list_dir_raw
 * itself has this same trap in its OTHER mode (query_len == 0 prints
 * the listing via uart_puts/uart_putc) -- never call it that way here.
 *
 * Storage goes through the dev==2 host_virtual_disk_read/write
 * backend (host_stubs.c) -- an in-memory array standing in for a real
 * SD card, so DharaFS's actual on-disk format/recovery/compaction
 * logic runs for real, just against host memory instead of hardware.
 *
 * Build/run via build_and_run.sh, which regenerates kernel_gen.c from
 * the CURRENT kernel_main.vani every time -- this harness tests
 * whatever the source currently says, not a stale snapshot.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>

/* ---- vani-defined functions this harness calls directly (see
 * unstatic.py's WHITELIST -- these are exactly the functions patched
 * from `static` to external linkage in kernel_gen_patched.c). ---- */
int64_t fn_dharafs_check_permission(uint32_t owner_uid, uint32_t owner_gid, uint32_t mode, uint32_t req_uid, uint32_t req_gid, int64_t want_read, int64_t want_write, int64_t want_exec);
int64_t fn_dharafs_init(void);
int64_t fn_dharafs_append_raw(int64_t *path_buf, int64_t path_len, int64_t *data_buf, int64_t data_len, uint32_t owner_uid, uint32_t owner_gid, uint32_t mode);
int64_t fn_dharafs_append(const char *path, const char *data);
int64_t fn_dharafs_read_raw_checked(int64_t *path_buf, int64_t path_len, int64_t *out_buf, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_write_raw_checked(int64_t *path_buf, int64_t path_len, int64_t *data_buf, int64_t data_len, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_delete_raw_checked(int64_t *path_buf, int64_t path_len, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_find_latest_block_raw(int64_t *path_buf, int64_t path_len);
int64_t fn_dharafs_compact(int64_t *buf, int64_t *path_buf, int64_t *data_buf);
int64_t fn_dharafs_stat_raw(int64_t *path_buf, int64_t path_len, int64_t *meta_buf);
int64_t fn_dharafs_stat(const char *path, int64_t *meta_buf);
int64_t fn_dharafs_read_raw(int64_t *path_buf, int64_t path_len, int64_t *out_buf);
int64_t fn_dharafs_read(const char *path, int64_t *out_buf);
int64_t fn_dharafs_delete_raw(int64_t *path_buf, int64_t path_len);
int64_t fn_dharafs_rename_raw(int64_t *old_path_buf, int64_t old_path_len, int64_t *new_path_buf, int64_t new_path_len);
int64_t fn_dharafs_tx_begin_raw(int64_t block_count);
uint32_t fn_dharafs_tx_begin_sentinel(void);
int64_t fn_dharafs_rename_raw_checked(int64_t *old_path_buf, int64_t old_path_len, int64_t *new_path_buf, int64_t new_path_len, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_verified_companion_path_raw(int64_t *path_buf, int64_t path_len, int64_t *out_buf);
int64_t fn_dharafs_log_rollover_threshold(void);
int64_t fn_dharafs_log_record_max_len(void);
int64_t fn_dharafs_log_path_raw(int64_t *name_buf, int64_t name_len, uint32_t index, int64_t *out_buf);
int64_t fn_dharafs_log_header_path_raw(int64_t *name_buf, int64_t name_len, int64_t *out_buf);
int64_t fn_dharafs_log_append_raw(int64_t *name_buf, int64_t name_len, int64_t *record_buf, int64_t record_len, uint32_t owner_uid, uint32_t owner_gid, uint32_t mode);
int64_t fn_dharafs_log_retention_count(void);
uint32_t fn_dharafs_attr_immutable(void);
uint32_t fn_dharafs_attr_append_only(void);
uint32_t fn_dharafs_attr_system(void);
int64_t fn_dharafs_mode_is_immutable(uint32_t mode);
int64_t fn_dharafs_mode_is_append_only(uint32_t mode);
int64_t fn_dharafs_is_valid_append_only_write(int64_t *old_buf, int64_t old_len, int64_t *new_buf, int64_t new_len);
int64_t fn_dharafs_set_attr_raw(int64_t *path_buf, int64_t path_len, uint32_t new_attr_bits, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_get_attr_raw(int64_t *path_buf, int64_t path_len);
int64_t fn_dharafs_chmod_checked(int64_t *path_buf, int64_t path_len, uint32_t new_mode, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_chown_checked(int64_t *path_buf, int64_t path_len, uint32_t new_uid, uint32_t new_gid, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_write_verified_raw(int64_t *path_buf, int64_t path_len, int64_t *data_buf, int64_t data_len, uint32_t owner_uid, uint32_t owner_gid, uint32_t mode);
int64_t fn_dharafs_write_verified_checked(int64_t *path_buf, int64_t path_len, int64_t *data_buf, int64_t data_len, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_read_verified_checked(int64_t *path_buf, int64_t path_len, int64_t *out_buf, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_delete(const char *path);
int64_t fn_dharafs_dirlist_seen_contains(int64_t *seen, int64_t count, int64_t *path_buf, int64_t seg_start, int64_t seg_len);
int64_t fn_dharafs_dirlist_segment_equals(int64_t *query_buf, int64_t query_len, int64_t *path_buf, int64_t seg_start, int64_t seg_len);
int64_t fn_dharafs_list_dir_raw(int64_t *dir_buf, int64_t dir_len, int64_t *query_buf, int64_t query_len);
int64_t fn_dharafs_block_payload_cap(void);
int64_t fn_dharafs_file_max_len(void);
uint32_t fn_dharafs_default_mode(void);
int64_t fn_sha256_hash(int64_t *msg, int64_t msg_len, int64_t *out);
int64_t fn_sha256_bytes_equal(int64_t *a, int64_t *b, int64_t n);
int64_t fn_hmac_sha256(int64_t *key, int64_t key_len, int64_t *msg, int64_t msg_len, int64_t *out);
int64_t fn_hmac_sha256_bytes_equal(int64_t *a, int64_t *b, int64_t n);
int64_t fn_pbkdf2_hmac_sha256(int64_t *password, int64_t password_len, int64_t *salt, int64_t salt_len, int64_t iterations, int64_t *out);
int64_t fn_chacha20_encrypt(int64_t *key, int64_t *nonce, uint32_t initial_counter, int64_t *in_buf, int64_t in_len, int64_t *state_buf, int64_t *working_buf, int64_t *keystream_buf, int64_t *out_buf);
int64_t fn_chacha20_bytes_equal(int64_t *a, int64_t *b, int64_t n);
int64_t fn_dharafs_crypto_transform_block(int64_t block_num, int64_t *in_buf, int64_t *out_buf);
int64_t fn_dharafs_block_read(int64_t block_num, int64_t *buf);
int64_t fn_dharafs_block_write(int64_t block_num, int64_t *buf);
uint32_t dharafs_crypto_get_enabled(void);
int64_t dharafs_crypto_set_enabled(uint32_t v);
int64_t *dharafs_crypto_key_ptr(void);
uint32_t fn_fault_write_maybe_inject(void);
uint32_t fn_fault_irqburst_take(void);
uint32_t fn_fault_netdrop_maybe_inject(void);
uint32_t fault_write_countdown_get(void);
int64_t fault_write_countdown_set(uint32_t v);
uint32_t fault_irqburst_countdown_get(void);
int64_t fault_irqburst_countdown_set(uint32_t v);
uint32_t fault_netdrop_countdown_get(void);
int64_t fault_netdrop_countdown_set(uint32_t v);
uint32_t fn_bignum_add_raw(int64_t *a, int64_t *b, int64_t *out, int64_t n);
uint32_t fn_bignum_sub_raw(int64_t *a, int64_t *b, int64_t *out, int64_t n);
int64_t fn_bignum_mul_raw(int64_t *a, int64_t *b, int64_t *out, int64_t n);
int64_t fn_bignum_cmp_raw(int64_t *a, int64_t *b, int64_t n);
int64_t fn_bignum_limbs_equal(int64_t *a, int64_t *b, int64_t n);
int64_t fn_bignum_set_limbs4(int64_t *buf, uint32_t l0, uint32_t l1, uint32_t l2, uint32_t l3);
int64_t fn_lan9512_build_tx_header(int64_t *out_buf, uint32_t frame_len);
uint32_t fn_lan9512_rx_status_has_error(uint32_t rx_status);
uint32_t fn_lan9512_rx_status_frame_len(uint32_t rx_status);
uint32_t fn_hci_build_opcode(uint32_t ogf, uint32_t ocf);
int64_t fn_hci_build_command(int64_t *out_buf, uint32_t opcode, int64_t *params_buf, uint32_t params_len);
int64_t fn_hci_build_reset_command(int64_t *out_buf);
int64_t fn_hci_build_le_set_scan_parameters_command(int64_t *out_buf, uint32_t scan_type, uint32_t scan_interval, uint32_t scan_window, uint32_t own_addr_type, uint32_t filter_policy);
int64_t fn_hci_build_le_set_scan_enable_command(int64_t *out_buf, uint32_t scan_enable, uint32_t filter_duplicates);
uint32_t fn_hci_event_code(int64_t *event_buf);
uint32_t fn_hci_event_param_len(int64_t *event_buf);
uint32_t fn_hci_event_is_command_complete(int64_t *event_buf);
uint32_t fn_hci_cmd_complete_opcode(int64_t *event_buf);
uint32_t fn_hci_cmd_complete_status(int64_t *event_buf);
int64_t fn_hci_build_le_create_connection_command(int64_t *out_buf, uint32_t scan_interval, uint32_t scan_window, uint32_t filter_policy, uint32_t peer_addr_type, int64_t *peer_addr, uint32_t own_addr_type, uint32_t conn_interval_min, uint32_t conn_interval_max, uint32_t conn_latency, uint32_t supervision_timeout);
uint32_t fn_hci_event_is_command_status(int64_t *event_buf);
uint32_t fn_hci_cmd_status_status(int64_t *event_buf);
uint32_t fn_hci_cmd_status_opcode(int64_t *event_buf);
uint32_t fn_hci_event_is_le_meta(int64_t *event_buf);
uint32_t fn_hci_le_meta_subevent_code(int64_t *event_buf);
uint32_t fn_hci_le_conn_complete_status(int64_t *event_buf);
uint32_t fn_hci_le_conn_complete_handle(int64_t *event_buf);
uint32_t fn_hci_le_conn_complete_role(int64_t *event_buf);
uint32_t fn_hci_le_conn_complete_peer_addr_type(int64_t *event_buf);
int64_t fn_hci_le_conn_complete_peer_addr(int64_t *event_buf, int64_t *out_addr);
uint32_t fn_hci_acl_pb_flag_first(void);
uint32_t fn_hci_acl_bc_flag_point_to_point(void);
int64_t fn_hci_acl_build_header(int64_t *out_buf, uint32_t handle, uint32_t pb_flag, uint32_t bc_flag, uint32_t data_len);
uint32_t fn_hci_acl_get_handle(int64_t *buf);
uint32_t fn_hci_acl_get_pb_flag(int64_t *buf);
uint32_t fn_hci_acl_get_data_len(int64_t *buf);
uint32_t fn_l2cap_att_channel_id(void);
uint32_t fn_l2cap_signaling_channel_id(void);
int64_t fn_l2cap_build_header(int64_t *out_buf, uint32_t length, uint32_t channel_id);
uint32_t fn_l2cap_get_length(int64_t *buf);
uint32_t fn_l2cap_get_channel_id(int64_t *buf);
uint32_t fn_att_opcode_error_response(void);
uint32_t fn_att_opcode_exchange_mtu_request(void);
uint32_t fn_att_opcode_exchange_mtu_response(void);
uint32_t fn_att_opcode_read_request(void);
uint32_t fn_att_opcode_read_response(void);
uint32_t fn_att_opcode_write_request(void);
uint32_t fn_att_opcode_write_response(void);
uint32_t fn_att_get_opcode(int64_t *buf);
int64_t fn_att_build_error_response(int64_t *out_buf, uint32_t request_opcode, uint32_t handle, uint32_t error_code);
uint32_t fn_att_error_request_opcode(int64_t *buf);
uint32_t fn_att_error_handle(int64_t *buf);
uint32_t fn_att_error_code(int64_t *buf);
int64_t fn_att_build_exchange_mtu_request(int64_t *out_buf, uint32_t client_rx_mtu);
uint32_t fn_att_exchange_mtu_request_get_mtu(int64_t *buf);
int64_t fn_att_build_exchange_mtu_response(int64_t *out_buf, uint32_t server_rx_mtu);
uint32_t fn_att_exchange_mtu_response_get_mtu(int64_t *buf);
int64_t fn_att_build_read_request(int64_t *out_buf, uint32_t handle);
uint32_t fn_att_read_request_get_handle(int64_t *buf);
int64_t fn_att_build_read_response(int64_t *out_buf, int64_t *value, int64_t value_len);
int64_t fn_att_read_response_get_value(int64_t *buf, int64_t pdu_len, int64_t *out_value);
int64_t fn_att_build_write_request(int64_t *out_buf, uint32_t handle, int64_t *value, int64_t value_len);
uint32_t fn_att_write_request_get_handle(int64_t *buf);
int64_t fn_att_write_request_get_value(int64_t *buf, int64_t pdu_len, int64_t *out_value);
int64_t fn_att_build_write_response(int64_t *out_buf);
uint32_t fn_att_error_invalid_handle(void);
uint32_t fn_att_error_read_not_permitted(void);
uint32_t fn_att_error_write_not_permitted(void);
uint32_t fn_att_error_invalid_pdu(void);
uint32_t fn_att_error_insufficient_authentication(void);
uint32_t fn_att_error_request_not_supported(void);
uint32_t fn_att_error_invalid_offset(void);
uint32_t fn_att_error_insufficient_authorization(void);
uint32_t fn_att_error_prepare_queue_full(void);
uint32_t fn_att_error_attribute_not_found(void);
uint32_t fn_att_error_attribute_not_long(void);
uint32_t fn_att_error_insufficient_encryption_key_size(void);
uint32_t fn_att_error_invalid_attribute_value_length(void);
uint32_t fn_att_error_unlikely_error(void);
uint32_t fn_att_error_insufficient_encryption(void);
uint32_t fn_att_error_unsupported_group_type(void);
uint32_t fn_att_error_insufficient_resources(void);
uint32_t fn_att_opcode_find_information_request(void);
uint32_t fn_att_opcode_find_information_response(void);
int64_t fn_att_build_find_information_request(int64_t *out_buf, uint32_t starting_handle, uint32_t ending_handle);
uint32_t fn_att_find_information_response_get_format(int64_t *buf);
int64_t fn_att_find_information_entry_size(uint32_t format);
int64_t fn_att_find_information_response_count(int64_t *buf, int64_t pdu_len);
uint32_t fn_att_find_information_response_get_handle_at(int64_t *buf, int64_t index);
uint32_t fn_att_find_information_response_get_uuid16_at(int64_t *buf, int64_t index);
uint32_t fn_att_opcode_read_by_type_request(void);
uint32_t fn_att_opcode_read_by_type_response(void);
int64_t fn_att_build_read_by_type_request_uuid16(int64_t *out_buf, uint32_t starting_handle, uint32_t ending_handle, uint32_t attribute_type_uuid16);
uint32_t fn_att_read_by_type_response_get_entry_len(int64_t *buf);
int64_t fn_att_read_by_type_response_count(int64_t *buf, int64_t pdu_len);
uint32_t fn_att_read_by_type_response_get_handle_at(int64_t *buf, int64_t index);
int64_t fn_att_read_by_type_response_get_value_len(int64_t *buf);
int64_t fn_att_read_by_type_response_get_value_at(int64_t *buf, int64_t index, int64_t *out_value);
uint32_t fn_att_opcode_read_by_group_type_request(void);
uint32_t fn_att_opcode_read_by_group_type_response(void);
int64_t fn_att_build_read_by_group_type_request_uuid16(int64_t *out_buf, uint32_t starting_handle, uint32_t ending_handle, uint32_t group_type_uuid16);
uint32_t fn_att_read_by_group_type_response_get_entry_len(int64_t *buf);
int64_t fn_att_read_by_group_type_response_count(int64_t *buf, int64_t pdu_len);
uint32_t fn_att_read_by_group_type_response_get_start_handle_at(int64_t *buf, int64_t index);
uint32_t fn_att_read_by_group_type_response_get_end_handle_at(int64_t *buf, int64_t index);
int64_t fn_att_read_by_group_type_response_get_value_len(int64_t *buf);
int64_t fn_att_read_by_group_type_response_get_value_at(int64_t *buf, int64_t index, int64_t *out_value);
uint32_t fn_gatt_uuid_primary_service(void);
uint32_t fn_gatt_uuid_secondary_service(void);
uint32_t fn_gatt_uuid_include(void);
uint32_t fn_gatt_uuid_characteristic(void);
uint32_t fn_gatt_uuid_char_extended_properties(void);
uint32_t fn_gatt_uuid_char_user_description(void);
uint32_t fn_gatt_uuid_client_char_configuration(void);
uint32_t fn_gatt_uuid_server_char_configuration(void);
uint32_t fn_gatt_uuid_char_presentation_format(void);
uint32_t fn_gatt_uuid_char_aggregate_format(void);
int64_t gatt_service_get_count(void);
int64_t gatt_service_set_count(uint32_t count);
int64_t gatt_service_get_start_handle_at(uint32_t i);
int64_t gatt_service_set_start_handle_at(uint32_t i, uint32_t v);
int64_t gatt_service_get_end_handle_at(uint32_t i);
int64_t gatt_service_set_end_handle_at(uint32_t i, uint32_t v);
int64_t gatt_service_get_uuid16_at(uint32_t i);
int64_t gatt_service_set_uuid16_at(uint32_t i, uint32_t v);
int64_t gatt_char_get_count(void);
int64_t gatt_char_set_count(uint32_t count);
int64_t gatt_char_get_decl_handle_at(uint32_t i);
int64_t gatt_char_set_decl_handle_at(uint32_t i, uint32_t v);
int64_t gatt_char_get_properties_at(uint32_t i);
int64_t gatt_char_set_properties_at(uint32_t i, uint32_t v);
int64_t gatt_char_get_value_handle_at(uint32_t i);
int64_t gatt_char_set_value_handle_at(uint32_t i, uint32_t v);
int64_t gatt_char_get_uuid16_at(uint32_t i);
int64_t gatt_char_set_uuid16_at(uint32_t i, uint32_t v);
int64_t gatt_char_get_service_index_at(uint32_t i);
int64_t gatt_char_set_service_index_at(uint32_t i, uint32_t v);
int64_t gatt_server_attr_get_count(void);
int64_t gatt_server_attr_set_count(uint32_t count);
int64_t gatt_server_attr_get_uuid16_at(uint32_t i);
int64_t gatt_server_attr_set_uuid16_at(uint32_t i, uint32_t v);
int64_t gatt_server_attr_get_value_len_at(uint32_t i);
int64_t gatt_server_attr_set_value_len_at(uint32_t i, uint32_t v);
int64_t gatt_server_attr_get_writable_at(uint32_t i);
int64_t gatt_server_attr_set_writable_at(uint32_t i, uint32_t v);
int64_t gatt_server_attr_get_value_byte(uint32_t combined_index);
int64_t gatt_server_attr_set_value_byte(uint32_t combined_index, uint32_t v);
int64_t fn_gatt_server_reset(void);
int64_t fn_gatt_server_add_service(uint32_t uuid16);
int64_t fn_gatt_server_add_characteristic(uint32_t properties, uint32_t char_uuid16, int64_t *initial_value, int64_t initial_value_len);
int64_t fn_gatt_server_find_index_for_handle(uint32_t handle);
int64_t fn_gatt_server_handle_request(int64_t *req, int64_t req_len, int64_t *out_rsp);
int64_t gatt_service_get_is_uuid128_at(uint32_t i);
int64_t gatt_service_set_is_uuid128_at(uint32_t i, uint32_t v);
int64_t gatt_service_get_uuid128_byte(uint32_t combined_index);
int64_t gatt_service_set_uuid128_byte(uint32_t combined_index, uint32_t v);
int64_t gatt_char_get_is_uuid128_at(uint32_t i);
int64_t gatt_char_set_is_uuid128_at(uint32_t i, uint32_t v);
int64_t gatt_char_get_uuid128_byte(uint32_t combined_index);
int64_t gatt_char_set_uuid128_byte(uint32_t combined_index, uint32_t v);
int64_t fn_att_find_information_response_get_uuid128_at(int64_t *buf, int64_t index, int64_t *out_uuid128);
int64_t fn_uuid128_equal(int64_t *a, int64_t *b);
int64_t fn_att_build_read_by_type_request_uuid128(int64_t *out_buf, uint32_t starting_handle, uint32_t ending_handle, int64_t *attribute_type_uuid128);
int64_t fn_att_build_read_by_group_type_request_uuid128(int64_t *out_buf, uint32_t starting_handle, uint32_t ending_handle, int64_t *group_type_uuid128);
uint32_t fn_att_opcode_handle_value_notification(void);
uint32_t fn_att_opcode_handle_value_indication(void);
uint32_t fn_att_opcode_handle_value_confirmation(void);
int64_t fn_att_build_handle_value_notification(int64_t *out_buf, uint32_t handle, int64_t *value, int64_t value_len);
int64_t fn_att_build_handle_value_indication(int64_t *out_buf, uint32_t handle, int64_t *value, int64_t value_len);
uint32_t fn_att_handle_value_get_handle(int64_t *buf);
int64_t fn_att_handle_value_get_value(int64_t *buf, int64_t pdu_len, int64_t *out_value);
int64_t fn_att_build_handle_value_confirmation(int64_t *out_buf);
uint32_t fn_l2cap_sig_code_connection_parameter_update_request(void);
uint32_t fn_l2cap_sig_code_connection_parameter_update_response(void);
uint32_t fn_l2cap_conn_param_update_result_accepted(void);
uint32_t fn_l2cap_conn_param_update_result_rejected(void);
uint32_t fn_l2cap_sig_get_code(int64_t *buf);
uint32_t fn_l2cap_sig_get_identifier(int64_t *buf);
uint32_t fn_l2cap_sig_get_length(int64_t *buf);
uint32_t fn_l2cap_conn_param_update_request_get_interval_min(int64_t *buf);
uint32_t fn_l2cap_conn_param_update_request_get_interval_max(int64_t *buf);
uint32_t fn_l2cap_conn_param_update_request_get_slave_latency(int64_t *buf);
uint32_t fn_l2cap_conn_param_update_request_get_timeout_multiplier(int64_t *buf);
int64_t fn_l2cap_build_conn_param_update_response(int64_t *out_buf, uint32_t identifier, uint32_t result);
int64_t gatt_char_get_cccd_handle_at(uint32_t i);
int64_t gatt_char_set_cccd_handle_at(uint32_t i, uint32_t v);
int64_t gatt_last_notify_handle_get(void);
int64_t gatt_last_notify_handle_set(uint32_t v);
uint32_t fn_gatt_char_descriptor_range_end(int64_t char_index);
int64_t fn_gatt_client_find_char_index_for_value_handle(uint32_t handle);
uint32_t fn_gatt_client_last_notify_handle(void);
int64_t fn_gatt_discover_reset(void);
int64_t fn_buf_write_u16_le(int64_t *buf, int64_t offset, uint32_t value);
uint32_t fn_buf_read_u16_le(int64_t *buf, int64_t offset);
int64_t diag_ring_push(uint32_t tick, uint32_t ctxsw, uint32_t irqs, uint32_t priolock);
int64_t diag_ring_get_head(void);
int64_t diag_ring_get_count(void);
int64_t diag_ring_get_tick_at(int64_t i);
int64_t fn_diag_ring_physical_index(int64_t logical_index);
int64_t fn_dwc2_build_rtl_reg_read_setup(uint32_t reg_addr, uint32_t want_len);
int64_t fn_dwc2_build_rtl_reg_write_setup(uint32_t reg_addr, uint32_t data_len);
int64_t *dwc2_dma_scratch_get(void);
int64_t dwc2_dma_scratch_set(int64_t *addr);
uint32_t fn_filter_check_frame(int64_t *frame, int64_t frame_len);
int64_t fn_filter_build_test_frame(int64_t *frame, uint32_t proto, uint32_t src_ip, uint32_t dst_port);
int64_t fn_dirindex_max_slots(void);
int64_t fn_dirindex_max_path_bytes(void);
int64_t fn_dharafs_dirindex_reset(void);
uint32_t fn_dharafs_dirindex_hash(int64_t *buf, int64_t path_offset, int64_t path_len);
int64_t fn_dharafs_dirindex_find_slot(int64_t *buf, int64_t path_offset, int64_t path_len, uint32_t h);
int64_t fn_dharafs_dirindex_lookup_raw(int64_t *path_buf, int64_t path_len);
int64_t fn_dharafs_dirindex_upsert_raw(int64_t *path_buf, int64_t path_len, int64_t block);
int64_t dirindex_get_valid_at(uint32_t i);
int64_t dirindex_set_valid_at(uint32_t i, uint32_t v);
int64_t dirindex_get_block_at(uint32_t i);
int64_t fn_fsqueue_max_slots(void);
int64_t fn_fsqueue_max_data_bytes(void);
int64_t fn_dharafs_queue_reset(void);
int64_t fn_dharafs_queue_submit_write_raw(uint32_t priority, uint32_t task_id, int64_t *path_buf, int64_t path_len, int64_t *data_buf, int64_t data_len, uint32_t owner_uid, uint32_t owner_gid, uint32_t mode);
int64_t fn_dharafs_queue_submit_delete_raw(uint32_t priority, uint32_t task_id, int64_t *path_buf, int64_t path_len);
int64_t fn_dharafs_queue_submit(const char *path, const char *data);
int64_t fn_dharafs_queue_pick_next(void);
int64_t fn_dharafs_queue_dispatch_one(void);
int64_t fn_dharafs_queue_pending_count(void);
int64_t fsqueue_valid_get_at(uint32_t i);
int64_t fsqueue_priority_get_at(uint32_t i);
int64_t fsqueue_result_get_at(uint32_t i);
int64_t fsqueue_path_scratch_set(int64_t *addr);
int64_t fsqueue_data_scratch_set(int64_t *addr);
int64_t fn_dharafs_read_from_block_raw(int64_t blk, int64_t *out_buf);
int64_t fn_dharafs_find_block_as_of_raw(int64_t *path_buf, int64_t path_len, uint32_t max_seq);
int64_t fn_snapshot_max_slots(void);
int64_t fn_dharafs_snapshot_reset(void);
int64_t fn_dharafs_snapshot_find_by_name_raw(int64_t *name_buf, int64_t name_len);
int64_t fn_dharafs_snapshot_create_raw(int64_t *name_buf, int64_t name_len);
int64_t fn_dharafs_snapshot_delete_raw(int64_t *name_buf, int64_t name_len);
int64_t fn_dharafs_snapshot_pinned_seq_raw(int64_t *name_buf, int64_t name_len);
int64_t fn_dharafs_snapshot_read_raw(int64_t *path_buf, int64_t path_len, int64_t *name_buf, int64_t name_len, int64_t *out_buf);
int64_t fn_dharafs_snapshot_create(const char *name);
int64_t fn_dharafs_snapshot_delete(const char *name);
int64_t fn_dharafs_snapshot_read(const char *path, const char *name, int64_t *out_buf);
int64_t fn_poly1305_mac(int64_t *key, int64_t *msg, int64_t msg_len, int64_t *block_scratch, int64_t *out_tag);
int64_t fn_poly1305_verify_constant_time(int64_t *a, int64_t *b, int64_t n);
int64_t fn_bignum_mul_small_raw(int64_t *a, int64_t *out, int64_t n, uint32_t small);
int64_t fn_field25519_init(void);
uint32_t fn_field25519_get_bit(int64_t *buf, int64_t bit_index);
int64_t fn_field25519_add(int64_t *a, int64_t *b, int64_t *out);
int64_t fn_field25519_sub(int64_t *a, int64_t *b, int64_t *out);
int64_t fn_field25519_mul(int64_t *a, int64_t *b, int64_t *out);
int64_t fn_field25519_sqr(int64_t *a, int64_t *out);
int64_t fn_field25519_invert(int64_t *a, int64_t *out);
int64_t fn_x25519_clamp_scalar(int64_t *k);
int64_t fn_x25519_scalarmult(int64_t *k, int64_t *u_in, int64_t *out);
int64_t x25519_x1_set(int64_t *addr);
int64_t x25519_x2_set(int64_t *addr);
int64_t x25519_z2_set(int64_t *addr);
int64_t x25519_x3_set(int64_t *addr);
int64_t x25519_z3_set(int64_t *addr);
int64_t x25519_a_set(int64_t *addr);
int64_t x25519_aa_set(int64_t *addr);
int64_t x25519_b_set(int64_t *addr);
int64_t x25519_bb_set(int64_t *addr);
int64_t x25519_e_set(int64_t *addr);
int64_t x25519_c_set(int64_t *addr);
int64_t x25519_d_set(int64_t *addr);
int64_t x25519_da_set(int64_t *addr);
int64_t x25519_cb_set(int64_t *addr);
int64_t x25519_a24e_set(int64_t *addr);
int64_t x25519_product_scratch_set(int64_t *addr);
int64_t x25519_invert_base_set(int64_t *addr);
int64_t x25519_invert_result_set(int64_t *addr);
int64_t x25519_p_bytes_set(int64_t *addr);
int64_t x25519_p_minus_2_bytes_set(int64_t *addr);
int64_t x25519_p9_bytes_set(int64_t *addr);
int64_t x25519_fold_t_set(int64_t *addr);
int64_t x25519_fold_s_set(int64_t *addr);
int64_t x25519_a24_bytes_set(int64_t *addr);

/* ---- host_stubs.c helpers ---- */
int64_t *dhruva_alloc_bytes(int64_t n);
uint32_t buf_read_byte(int64_t *buf, uint32_t offset);
uint32_t buf_write_byte(int64_t *buf, uint32_t offset, uint32_t value);
uint32_t buf_read_u32(int64_t *buf, uint32_t offset);
uint32_t buf_write_u32(int64_t *buf, uint32_t offset, uint32_t value);
uint32_t buf_checksum(int64_t *buf, uint32_t start_offset, uint32_t byte_len);
uint32_t dharafs_state_set_block_dev(uint32_t dev);
int64_t host_virtual_disk_read(int64_t block_num, int64_t *buf);
int64_t host_virtual_disk_write(int64_t block_num, int64_t *buf);
void host_virtual_disk_reset(void);
uint32_t fw_get_rule_count(void);
uint32_t fw_get_default_policy(void);
uint32_t fw_set_default_policy(uint32_t value);
uint32_t fw_flush(void);
uint32_t fw_add_rule(uint32_t proto, uint32_t src_ip, uint32_t src_ip_valid, uint32_t dst_port, uint32_t dst_port_valid, uint32_t action);

static int g_pass = 0, g_fail = 0;

#define CHECK(cond, desc)                                                 \
    do {                                                                 \
        if (cond) {                                                      \
            g_pass++;                                                    \
        } else {                                                         \
            g_fail++;                                                    \
            printf("FAIL: %s (%s:%d)\n", desc, __FILE__, __LINE__);      \
        }                                                                \
    } while (0)

/* Scratch buffers, sized EXACTLY like the real boot sequence
 * (kernel_main.vani's own dharafs_sd_scratch_set(dhruva_alloc_bytes(512))
 * etc.) so ASAN's redzones sit at the real production boundary. */
static int64_t *g_sd_scratch, *g_path_scratch, *g_data_scratch, *g_stat_scratch, *g_dir_scratch;

extern int64_t dharafs_sd_scratch_set(int64_t *addr);
extern int64_t dharafs_path_scratch_set(int64_t *addr);
extern int64_t dharafs_data_scratch_set(int64_t *addr);
extern int64_t dharafs_stat_scratch_set(int64_t *addr);
extern int64_t dharafs_dir_scratch_set(int64_t *addr);
extern int64_t dharafs_log_path_scratch_set(int64_t *addr);
extern int64_t dharafs_log_header_path_scratch_set(int64_t *addr);
extern int64_t dharafs_log_header_data_scratch_set(int64_t *addr);
extern int64_t dharafs_log_existing_scratch_set(int64_t *addr);
extern int64_t dharafs_log_combined_scratch_set(int64_t *addr);
extern int64_t dharafs_verified_companion_scratch_set(int64_t *addr);
extern int64_t dharafs_verified_digest_a_scratch_set(int64_t *addr);
extern int64_t dharafs_verified_digest_b_scratch_set(int64_t *addr);
extern int64_t dharafs_appendonly_check_scratch_set(int64_t *addr);
extern int64_t sha256_padded_scratch_set(int64_t *addr);
extern int64_t sha256_h_scratch_set(int64_t *addr);
extern int64_t sha256_k_scratch_set(int64_t *addr);
extern int64_t sha256_w_scratch_set(int64_t *addr);
extern int64_t fn_sha256_k_init(int64_t *k);

static void reset_fs(void) {
    host_virtual_disk_reset();
    dharafs_state_set_block_dev(2);
    g_sd_scratch = dhruva_alloc_bytes(512);
    g_path_scratch = dhruva_alloc_bytes(32);
    g_data_scratch = dhruva_alloc_bytes(4096);
    g_stat_scratch = dhruva_alloc_bytes(12);
    g_dir_scratch = dhruva_alloc_bytes(32);
    dharafs_sd_scratch_set(g_sd_scratch);
    dharafs_path_scratch_set(g_path_scratch);
    dharafs_data_scratch_set(g_data_scratch);
    dharafs_stat_scratch_set(g_stat_scratch);
    dharafs_dir_scratch_set(g_dir_scratch);
    dharafs_log_path_scratch_set(dhruva_alloc_bytes(32));
    dharafs_log_header_path_scratch_set(dhruva_alloc_bytes(32));
    dharafs_log_header_data_scratch_set(dhruva_alloc_bytes(8));
    dharafs_log_existing_scratch_set(dhruva_alloc_bytes(4096));
    dharafs_log_combined_scratch_set(dhruva_alloc_bytes(4096));
    dharafs_verified_companion_scratch_set(dhruva_alloc_bytes(32));
    dharafs_verified_digest_a_scratch_set(dhruva_alloc_bytes(32));
    dharafs_verified_digest_b_scratch_set(dhruva_alloc_bytes(32));
    dharafs_appendonly_check_scratch_set(dhruva_alloc_bytes(4096));
    sha256_padded_scratch_set(dhruva_alloc_bytes(4168));
    sha256_h_scratch_set(dhruva_alloc_bytes(32));
    int64_t *k_scratch = dhruva_alloc_bytes(256);
    sha256_k_scratch_set(k_scratch);
    fn_sha256_k_init(k_scratch);
    sha256_w_scratch_set(dhruva_alloc_bytes(256));
    fsqueue_path_scratch_set(dhruva_alloc_bytes(32));
    fsqueue_data_scratch_set(dhruva_alloc_bytes(448));
    fn_dharafs_queue_reset();
    fn_dharafs_init();
}

static int64_t *mkbuf(const char *bytes, int64_t len) {
    int64_t *b = dhruva_alloc_bytes(len);
    for (int64_t i = 0; i < len; i++) {
        buf_write_byte(b, (uint32_t)i, (uint32_t)(unsigned char)bytes[i]);
    }
    return b;
}

/* ================= DharaFS: basic round trip ================= */

static void test_basic_round_trip(void) {
    reset_fs();
    int64_t *path = mkbuf("/a", 2);
    int64_t *data = mkbuf("hello", 5);
    int64_t st = fn_dharafs_append_raw(path, 2, data, 5, 0, 0, fn_dharafs_default_mode());
    CHECK(st == 0, "basic_round_trip: append succeeds");

    int64_t *out = dhruva_alloc_bytes(5);
    int64_t rd = fn_dharafs_read_raw(path, 2, out);
    CHECK(rd == 5, "basic_round_trip: read returns correct length");
    CHECK(memcmp(out, "hello", 5) == 0, "basic_round_trip: read returns correct bytes");
}

/* ================= Path length boundary: 32 ok, 33 rejected ================= */

static void test_path_length_boundary(void) {
    reset_fs();
    char path32[32];
    memset(path32, 'p', 32);
    int64_t *pbuf = mkbuf(path32, 32);
    int64_t *data = mkbuf("x", 1);
    int64_t st = fn_dharafs_append_raw(pbuf, 32, data, 1, 0, 0, fn_dharafs_default_mode());
    CHECK(st == 0, "path_length: exactly 32 bytes accepted");

    char path33[33];
    memset(path33, 'q', 33);
    int64_t *pbuf2 = mkbuf(path33, 33);
    int64_t st2 = fn_dharafs_append_raw(pbuf2, 33, data, 1, 0, 0, fn_dharafs_default_mode());
    CHECK(st2 == 1, "path_length: 33 bytes rejected");

    int64_t st3 = fn_dharafs_append_raw(pbuf, 0, data, 1, 0, 0, fn_dharafs_default_mode());
    CHECK(st3 == 1, "path_length: zero-length path rejected (continuation sentinel)");
}

/* ================= File size boundary: 4096 ok, 4097 rejected ================= */

static void test_file_size_boundary(void) {
    reset_fs();
    int64_t *path = mkbuf("/big", 4);
    int64_t max_len = fn_dharafs_file_max_len();
    CHECK(max_len == 4096, "file_size: dharafs_file_max_len() is 4096");

    int64_t *data4096 = dhruva_alloc_bytes(4096);
    for (int64_t i = 0; i < 4096; i++) buf_write_byte(data4096, (uint32_t)i, (uint32_t)(i & 0xff));
    int64_t st = fn_dharafs_append_raw(path, 4, data4096, 4096, 0, 0, fn_dharafs_default_mode());
    CHECK(st == 0, "file_size: exactly 4096 bytes accepted");

    int64_t *out = dhruva_alloc_bytes(4096);
    int64_t rd = fn_dharafs_read_raw(path, 4, out);
    CHECK(rd == 4096, "file_size: 4096-byte multi-block file reads back correct length");
    CHECK(memcmp(out, data4096, 4096) == 0, "file_size: 4096-byte multi-block file reads back correct bytes");

    int64_t *data4097 = dhruva_alloc_bytes(4097);
    int64_t st2 = fn_dharafs_append_raw(path, 4, data4097, 4097, 0, 0, fn_dharafs_default_mode());
    CHECK(st2 == 1, "file_size: 4097 bytes rejected");
}

/* ================= Zero-length data ================= */

static void test_zero_length_data(void) {
    reset_fs();
    int64_t *path = mkbuf("/empty", 6);
    int64_t *data = dhruva_alloc_bytes(1); /* never read since data_len==0 */
    int64_t st = fn_dharafs_append_raw(path, 6, data, 0, 0, 0, fn_dharafs_default_mode());
    CHECK(st == 0, "zero_length_data: append with data_len=0 succeeds");

    int64_t *out = dhruva_alloc_bytes(1);
    int64_t rd = fn_dharafs_read_raw(path, 6, out);
    CHECK(rd == 0, "zero_length_data: read back returns length 0");
}

/* ================= Overwrite: newest record wins ================= */

static void test_overwrite(void) {
    reset_fs();
    int64_t *path = mkbuf("/f", 2);
    int64_t *data1 = mkbuf("version-one", 11);
    int64_t *data2 = mkbuf("version-two-updated", 19);
    CHECK(fn_dharafs_append_raw(path, 2, data1, 11, 0, 0, fn_dharafs_default_mode()) == 0, "overwrite: first write succeeds");
    CHECK(fn_dharafs_append_raw(path, 2, data2, 19, 0, 0, fn_dharafs_default_mode()) == 0, "overwrite: second write succeeds");

    int64_t *out = dhruva_alloc_bytes(19);
    int64_t rd = fn_dharafs_read_raw(path, 2, out);
    CHECK(rd == 19, "overwrite: read returns NEWEST length");
    CHECK(memcmp(out, "version-two-updated", 19) == 0, "overwrite: read returns NEWEST bytes");
}

/* ================= Delete -> tombstone -> read fails ================= */

static void test_delete(void) {
    reset_fs();
    int64_t *path = mkbuf("/gone", 5);
    int64_t *data = mkbuf("x", 1);
    CHECK(fn_dharafs_append_raw(path, 5, data, 1, 0, 0, fn_dharafs_default_mode()) == 0, "delete: append succeeds");
    CHECK(fn_dharafs_delete_raw(path, 5) == 0, "delete: delete succeeds");

    int64_t *out = dhruva_alloc_bytes(1);
    int64_t rd = fn_dharafs_read_raw(path, 5, out);
    CHECK(rd == -1, "delete: read after delete returns -1 (tombstone)");

    int64_t blk = fn_dharafs_find_latest_block_raw(path, 5);
    CHECK(blk >= 0, "delete: tombstone record itself is still findable as the latest block");
}

/* ================= Rename (round 47) ================= */

static void test_rename(void) {
    reset_fs();
    int64_t *old_path = mkbuf("/a", 2);
    int64_t *new_path = mkbuf("/b", 2);
    int64_t *data = mkbuf("hello-world", 11);
    CHECK(fn_dharafs_append_raw(old_path, 2, data, 11, 7, 8, 0644) == 0, "rename: create /a succeeds");
    CHECK(fn_dharafs_rename_raw(old_path, 2, new_path, 2) == 0, "rename: /a -> /b succeeds");

    int64_t *out = dhruva_alloc_bytes(11);
    CHECK(fn_dharafs_read_raw(old_path, 2, out) == -1, "rename: old path no longer readable");
    int64_t rd = fn_dharafs_read_raw(new_path, 2, out);
    CHECK(rd == 11, "rename: new path readable with correct length");
    CHECK(memcmp(out, "hello-world", 11) == 0, "rename: new path has correct bytes");

    int64_t *meta = dhruva_alloc_bytes(12);
    CHECK(fn_dharafs_stat_raw(new_path, 2, meta) == 0, "rename: new path stat succeeds");
    CHECK(buf_read_u32(meta, 0) == 7, "rename: owner_uid preserved across rename");
    CHECK(buf_read_u32(meta, 4) == 8, "rename: owner_gid preserved across rename");

    /* Rename to self is a no-op success, not a self-tombstone. */
    CHECK(fn_dharafs_rename_raw(new_path, 2, new_path, 2) == 0, "rename: /b -> /b (self) succeeds");
    CHECK(fn_dharafs_read_raw(new_path, 2, out) == 11, "rename: self-rename did not delete the file");

    /* Renaming a path that doesn't exist fails cleanly. */
    int64_t *missing = mkbuf("/nope", 5);
    int64_t *dest = mkbuf("/dest", 5);
    CHECK(fn_dharafs_rename_raw(missing, 5, dest, 5) == -1, "rename: nonexistent source returns -1");

    /* Path length boundaries, same 32-byte limit as every other entry point. */
    char path33[33];
    memset(path33, 'z', 33);
    int64_t *huge = mkbuf(path33, 33);
    CHECK(fn_dharafs_rename_raw(new_path, 2, huge, 33) == 1, "rename: new path > 32 bytes rejected");
    CHECK(fn_dharafs_rename_raw(huge, 33, new_path, 2) == 1, "rename: old path > 32 bytes rejected");

    /* Permission model: owner may rename; a non-owner may not, even
     * onto a path that doesn't exist yet (write permission is checked
     * on the OLD path, which is what's actually being removed). */
    reset_fs();
    int64_t *owned = mkbuf("/owned", 6);
    int64_t *stolen = mkbuf("/stolen", 7);
    int64_t *d2 = mkbuf("secret", 6);
    CHECK(fn_dharafs_append_raw(owned, 6, d2, 6, 42, 42, 0644) == 0, "rename_perm: create /owned as uid 42");
    CHECK(fn_dharafs_rename_raw_checked(owned, 6, stolen, 7, 99, 99) == -2, "rename_perm: non-owner rename denied");
    CHECK(fn_dharafs_rename_raw_checked(owned, 6, stolen, 7, 42, 42) == 0, "rename_perm: owner rename succeeds");

    /* Renaming onto an EXISTING file owned by someone else, without
     * permission on that destination, must also be denied -- renaming
     * shouldn't be a backdoor around dharafs_write_raw_checked's own
     * overwrite-permission check. */
    reset_fs();
    int64_t *mine = mkbuf("/mine", 5);
    int64_t *theirs = mkbuf("/theirs", 7);
    int64_t *d3 = mkbuf("m", 1);
    int64_t *d4 = mkbuf("t", 1);
    CHECK(fn_dharafs_append_raw(mine, 5, d3, 1, 42, 42, 0644) == 0, "rename_dest_perm: create /mine as uid 42");
    CHECK(fn_dharafs_append_raw(theirs, 7, d4, 1, 7, 7, 0644) == 0, "rename_dest_perm: create /theirs as uid 7 (world-readable, not world-writable)");
    CHECK(fn_dharafs_rename_raw_checked(mine, 5, theirs, 7, 42, 42) == -2, "rename_dest_perm: renaming onto someone else's file without write permission on it is denied");
}

/* ================= Rename transaction crash consistency (round 52) =================
 * dharafs_rename_raw's own append+delete pair is now bracketed by a
 * dharafs_tx_begin_raw marker (see its own comment for the on-disk
 * design). These tests simulate a REAL crash at each point a genuine
 * power failure could land -- not just "does a normal rename work"
 * (test_rename already covers that), but "does an INTERRUPTED one
 * recover to old-or-new, never a mixed state." */

static void test_rename_transaction_crash_consistency(void) {
    extern uint32_t dharafs_state_get_next_block(void);
    extern uint32_t dharafs_state_get_next_seq(void);

    /* Case 1: crash immediately after tx_begin, before either the
     * append or the delete happens at all. */
    reset_fs();
    int64_t *old_path = mkbuf("/a", 2);
    int64_t *new_path = mkbuf("/b", 2);
    int64_t *data = mkbuf("original", 8);
    CHECK(fn_dharafs_append_raw(old_path, 2, data, 8, 0, 0, 0644) == 0, "tx_crash1: create /a");
    uint32_t tx_block = dharafs_state_get_next_block();
    CHECK(fn_dharafs_tx_begin_raw(2) == 0, "tx_crash1: tx_begin succeeds");
    /* Simulate the crash: re-run recovery right now, with NEITHER of
     * the 2 promised follow-up blocks ever written. */
    CHECK(fn_dharafs_init() == 0, "tx_crash1: recovery runs");
    CHECK(dharafs_state_get_next_block() == tx_block, "tx_crash1: next_block rolled back to the tx_begin's own block, abandoning it");
    int64_t *out = dhruva_alloc_bytes(8);
    CHECK(fn_dharafs_read_raw(old_path, 2, out) == 8, "tx_crash1: old path is completely untouched");
    CHECK(memcmp(out, "original", 8) == 0, "tx_crash1: old path content is unchanged");
    CHECK(fn_dharafs_find_latest_block_raw(new_path, 2) == -1, "tx_crash1: new path was never created");
    /* The abandoned tx_begin block gets silently overwritten by the
     * next real append, exactly like any other reclaimed log-
     * structured block -- prove it doesn't jam future writes. */
    int64_t *data2 = mkbuf("still-works", 11);
    CHECK(fn_dharafs_append_raw(mkbuf("/c", 2), 2, data2, 11, 0, 0, 0644) == 0, "tx_crash1: normal appends still work after an abandoned transaction");

    /* Case 2: crash after the append half completes but before the
     * delete -- the harder case, since one of the two promised blocks
     * really was written successfully. */
    reset_fs();
    int64_t *old_path2 = mkbuf("/x", 2);
    int64_t *new_path2 = mkbuf("/y", 2);
    int64_t *data3 = mkbuf("keep-me", 7);
    CHECK(fn_dharafs_append_raw(old_path2, 2, data3, 7, 0, 0, 0644) == 0, "tx_crash2: create /x");
    uint32_t tx_block2 = dharafs_state_get_next_block();
    CHECK(fn_dharafs_tx_begin_raw(2) == 0, "tx_crash2: tx_begin succeeds");
    int64_t *data4 = mkbuf("moved", 5);
    CHECK(fn_dharafs_append_raw(new_path2, 2, data4, 5, 0, 0, 0644) == 0, "tx_crash2: the append half succeeds (crash happens right after this)");
    /* Deliberately skip the delete -- this IS the simulated crash. */
    CHECK(fn_dharafs_init() == 0, "tx_crash2: recovery runs");
    CHECK(dharafs_state_get_next_block() == tx_block2, "tx_crash2: next_block STILL rolls back to tx_begin, even though the append half genuinely succeeded");
    int64_t *out2 = dhruva_alloc_bytes(7);
    CHECK(fn_dharafs_read_raw(old_path2, 2, out2) == 7, "tx_crash2: old path is still fully intact (never touched)");
    CHECK(memcmp(out2, "keep-me", 7) == 0, "tx_crash2: old path content unchanged");
    CHECK(fn_dharafs_find_latest_block_raw(new_path2, 2) == -1, "tx_crash2: new path does NOT exist -- the half-completed append is invisible, not a partial/mixed state");

    /* Case 3: the transaction actually completes -- recovery must
     * recognize it as done and advance state past ALL of it, not
     * treat a genuinely finished transaction as incomplete. */
    reset_fs();
    int64_t *old_path3 = mkbuf("/p", 2);
    int64_t *new_path3 = mkbuf("/q", 2);
    int64_t *data5 = mkbuf("payload", 7);
    CHECK(fn_dharafs_append_raw(old_path3, 2, data5, 7, 0, 0, 0644) == 0, "tx_complete: create /p");
    CHECK(fn_dharafs_rename_raw(old_path3, 2, new_path3, 2) == 0, "tx_complete: full rename via the real wrapper succeeds");
    uint32_t next_block_before_recovery = dharafs_state_get_next_block();
    uint32_t next_seq_before_recovery = dharafs_state_get_next_seq();
    CHECK(fn_dharafs_init() == 0, "tx_complete: recovery runs after a genuinely completed transaction");
    CHECK(dharafs_state_get_next_block() == next_block_before_recovery, "tx_complete: next_block is UNCHANGED by recovery (transaction recognized as complete, nothing rolled back)");
    CHECK(dharafs_state_get_next_seq() == next_seq_before_recovery, "tx_complete: next_seq is also unchanged");
    int64_t *out3 = dhruva_alloc_bytes(7);
    CHECK(fn_dharafs_read_raw(new_path3, 2, out3) == 7, "tx_complete: new path readable after recovery");
    CHECK(memcmp(out3, "payload", 7) == 0, "tx_complete: new path content correct after recovery");
    CHECK(fn_dharafs_read_raw(old_path3, 2, out3) == -1, "tx_complete: old path still gone after recovery (tombstone recognized correctly)");

    /* Sentinel sanity: confirm it's outside the valid path_len range
     * (1-32) and distinct from the continuation marker (0), so no
     * real path could ever collide with it. */
    uint32_t sentinel = fn_dharafs_tx_begin_sentinel();
    CHECK(sentinel > 32, "tx_sentinel: sentinel value is outside the valid path_len range");
    CHECK(sentinel != 0, "tx_sentinel: sentinel is distinct from the continuation marker");
}

/* ================= Permission model boundaries ================= */

static void test_permission_boundaries(void) {
    /* mode 0644: owner rw, group r, other r. */
    uint32_t mode = 0x1A4;
    /* Owner (uid match): read allowed, write allowed. */
    CHECK(fn_dharafs_check_permission(100, 200, mode, 100, 999, 1, 0, 0) == 1, "perm: owner can read");
    CHECK(fn_dharafs_check_permission(100, 200, mode, 100, 999, 0, 1, 0) == 1, "perm: owner can write");
    /* Group (gid match, uid mismatch): read allowed, write denied. */
    CHECK(fn_dharafs_check_permission(100, 200, mode, 999, 200, 1, 0, 0) == 1, "perm: group can read");
    CHECK(fn_dharafs_check_permission(100, 200, mode, 999, 200, 0, 1, 0) == 0, "perm: group cannot write (mode 0644)");
    /* Other (neither match): read allowed, write denied. */
    CHECK(fn_dharafs_check_permission(100, 200, mode, 999, 999, 1, 0, 0) == 1, "perm: other can read (mode 0644)");
    CHECK(fn_dharafs_check_permission(100, 200, mode, 999, 999, 0, 1, 0) == 0, "perm: other cannot write");
    /* Root (uid 0) always bypasses, even against mode 0. */
    CHECK(fn_dharafs_check_permission(100, 200, 0, 0, 999, 0, 1, 0) == 1, "perm: root bypasses even mode 0");
    /* mode 0 (rwx for nobody): owner itself is denied too. */
    CHECK(fn_dharafs_check_permission(100, 200, 0, 100, 200, 1, 0, 0) == 0, "perm: mode 0 denies even the owner");

    /* End-to-end through the checked wrappers. */
    reset_fs();
    int64_t *path = mkbuf("/secret", 7);
    int64_t *data = mkbuf("s", 1);
    CHECK(fn_dharafs_write_raw_checked(path, 7, data, 1, 42, 42) == 0, "perm_e2e: uid 42 creates /secret (mode defaults to 0644)");
    int64_t *out = dhruva_alloc_bytes(1);
    CHECK(fn_dharafs_read_raw_checked(path, 7, out, 999, 999) == 1, "perm_e2e: any uid can read (mode 0644 world-readable)");
    int64_t *data2 = mkbuf("t", 1);
    CHECK(fn_dharafs_write_raw_checked(path, 7, data2, 1, 999, 999) == -2, "perm_e2e: non-owner write denied (-2)");
    CHECK(fn_dharafs_delete_raw_checked(path, 7, 999, 999) == -2, "perm_e2e: non-owner delete denied (-2)");
    CHECK(fn_dharafs_delete_raw_checked(path, 7, 42, 42) == 0, "perm_e2e: owner delete succeeds");
    CHECK(fn_dharafs_read_raw_checked(path, 7, out, 42, 42) == -1, "perm_e2e: read after owner-delete returns -1 (not found)");

    int64_t *missing = mkbuf("/nope", 5);
    CHECK(fn_dharafs_read_raw_checked(missing, 5, out, 999, 999) == -1, "perm_e2e: read of never-written path returns -1, not -2");
}

/* ================= Directory hierarchy classify mode ================= */

static void test_directory_hierarchy(void) {
    reset_fs();
    CHECK(fn_dharafs_append("/config/mode", "auto") == 0, "dirhier: create /config/mode");
    CHECK(fn_dharafs_append("/config/sub/deep", "x") == 0, "dirhier: create /config/sub/deep");
    CHECK(fn_dharafs_append("/config/other", "y") == 0, "dirhier: create /config/other");

    int64_t *dir = mkbuf("/config", 7);
    int64_t *q_mode = mkbuf("mode", 4);
    int64_t r1 = fn_dharafs_list_dir_raw(dir, 7, q_mode, 4);
    CHECK(r1 == 1, "dirhier: classify('mode') under /config is a FILE (1)");

    int64_t *q_sub = mkbuf("sub", 3);
    int64_t r2 = fn_dharafs_list_dir_raw(dir, 7, q_sub, 3);
    CHECK(r2 == 2, "dirhier: classify('sub') under /config is a SUBDIRECTORY (2)");

    int64_t *q_missing = mkbuf("nope", 4);
    int64_t r3 = fn_dharafs_list_dir_raw(dir, 7, q_missing, 4);
    CHECK(r3 == 0, "dirhier: classify('nope') under /config is NEITHER (0)");
}

/* ================= Hashed directory index ================= */

static void test_dirindex(void) {
    /* Unit-level: bypass dharafs entirely, drive the index directly. */
    fn_dharafs_dirindex_reset();
    int64_t *pa = mkbuf("/a", 2);
    int64_t *pb = mkbuf("/b", 2);
    int64_t *pc = mkbuf("/c", 2);
    CHECK(fn_dharafs_dirindex_lookup_raw(pa, 2) == -1, "dirindex: miss on empty table");

    fn_dharafs_dirindex_upsert_raw(pa, 2, 10);
    CHECK(fn_dharafs_dirindex_lookup_raw(pa, 2) == 10, "dirindex: hit after insert");
    CHECK(fn_dharafs_dirindex_lookup_raw(pb, 2) == -1, "dirindex: unrelated path still misses");

    fn_dharafs_dirindex_upsert_raw(pb, 2, 11);
    fn_dharafs_dirindex_upsert_raw(pc, 2, 12);
    CHECK(fn_dharafs_dirindex_lookup_raw(pa, 2) == 10, "dirindex: /a unaffected by later inserts");
    CHECK(fn_dharafs_dirindex_lookup_raw(pb, 2) == 11, "dirindex: /b correct");
    CHECK(fn_dharafs_dirindex_lookup_raw(pc, 2) == 12, "dirindex: /c correct");

    fn_dharafs_dirindex_upsert_raw(pa, 2, 20);
    CHECK(fn_dharafs_dirindex_lookup_raw(pa, 2) == 20, "dirindex: re-upsert updates block in place");
    CHECK(fn_dharafs_dirindex_lookup_raw(pb, 2) == 11, "dirindex: sibling entries untouched by /a's update");

    /* Hash determinism -- same bytes, same offset, same result every time. */
    uint32_t h1 = fn_dharafs_dirindex_hash(pa, 0, 2);
    uint32_t h2 = fn_dharafs_dirindex_hash(pa, 0, 2);
    CHECK(h1 == h2, "dirindex: hash is deterministic for identical input");
    uint32_t hb = fn_dharafs_dirindex_hash(pb, 0, 2);
    CHECK(h1 != hb, "dirindex: distinct 2-byte paths hash differently (no trivial collision)");

    /* Bulk load past a realistic file count -- correctness contract is
     * "every HIT is exactly right, a MISS is always safe (never a
     * wrong answer)," not "every path fits." Exercises real open-
     * addressing probing/collision handling, not just the 3-entry
     * happy path above. */
    fn_dharafs_dirindex_reset();
    enum { N = 300 };
    static char bulk_paths[N][16];
    int64_t expected_block[N];
    for (int i = 0; i < N; i++) {
        snprintf(bulk_paths[i], sizeof(bulk_paths[i]), "/f%d", i);
        expected_block[i] = 1000 + i;
        int64_t *pb2 = mkbuf(bulk_paths[i], (int64_t)strlen(bulk_paths[i]));
        fn_dharafs_dirindex_upsert_raw(pb2, (int64_t)strlen(bulk_paths[i]), expected_block[i]);
    }
    int found = 0;
    int all_correct = 1;
    for (int i = 0; i < N; i++) {
        int64_t *pb2 = mkbuf(bulk_paths[i], (int64_t)strlen(bulk_paths[i]));
        int64_t got = fn_dharafs_dirindex_lookup_raw(pb2, (int64_t)strlen(bulk_paths[i]));
        if (got >= 0) {
            found++;
            if (got != expected_block[i]) all_correct = 0;
        }
    }
    CHECK(all_correct == 1, "dirindex: every hit under bulk load (300 paths, 256 slots) is byte-exact correct, never wrong");
    CHECK(found >= 200, "dirindex: bulk load fits a large majority of realistic-scale file counts (>=200/300 indexed)");
    CHECK(found <= 256, "dirindex: table never reports more entries indexed than its own fixed 256-slot capacity");

    /* Integration: real dharafs_append_raw/find_latest_block_raw path
     * actually populates and uses the index, not just the fallback
     * scan -- confirmed by reading the slot directly after a write. */
    reset_fs();
    CHECK(fn_dharafs_append("/idx/one", "hello") == 0, "dirindex: real append succeeds");
    int64_t *p_one = mkbuf("/idx/one", 8);
    int64_t via_index = fn_dharafs_dirindex_lookup_raw(p_one, 8);
    CHECK(via_index >= 0, "dirindex: a real append_raw write is indexed (hit, not a miss)");
    int64_t via_scan = fn_dharafs_find_latest_block_raw(p_one, 8);
    CHECK(via_index == via_scan, "dirindex: fast-path index and linear-scan fallback agree exactly");

    CHECK(fn_dharafs_append("/idx/one", "updated") == 0, "dirindex: overwrite succeeds");
    int64_t via_index2 = fn_dharafs_dirindex_lookup_raw(p_one, 8);
    CHECK(via_index2 == fn_dharafs_find_latest_block_raw(p_one, 8), "dirindex: index stays in sync after overwrite");
    CHECK(via_index2 != via_index, "dirindex: overwrite actually advanced to a new block");

    CHECK(fn_dharafs_delete("/idx/one") == 0, "dirindex: delete (tombstone) succeeds");
    int64_t via_index3 = fn_dharafs_dirindex_lookup_raw(p_one, 8);
    CHECK(via_index3 == fn_dharafs_find_latest_block_raw(p_one, 8), "dirindex: index stays in sync after delete's tombstone");
    CHECK(fn_dharafs_read("/idx/one", g_data_scratch) == -1, "dirindex: deleted path still correctly reads as gone (tombstone semantics unaffected)");

    /* Boot-time rebuild: dharafs_init's own scan must repopulate the
     * index identically to what live writes already produced (this is
     * the ONLY init path in this project -- there's no persisted
     * on-disk index, so a fresh boot must re-derive it from the log). */
    fn_dharafs_dirindex_reset();
    fn_dharafs_init();
    int64_t after_reinit = fn_dharafs_dirindex_lookup_raw(p_one, 8);
    CHECK(after_reinit == via_index3, "dirindex: dharafs_init's scan rebuilds the exact same mapping a live boot already had");
}

/* ================= Priority-aware FS request queue ================= */

static void test_fsqueue(void) {
    reset_fs(); /* also resets the queue via fn_dharafs_queue_reset() */

    CHECK(fn_dharafs_queue_pending_count() == 0, "fsqueue: empty after reset");
    CHECK(fn_dharafs_queue_dispatch_one() == -1, "fsqueue: dispatch on empty queue returns -1");

    /* Priority ordering: a LOW-priority (numerically high) write
     * submitted first must still be dispatched AFTER a HIGH-priority
     * (numerically low) one submitted later -- the whole point of the
     * queue, not just FIFO. */
    int64_t *p_low = mkbuf("/q/low", 6);
    int64_t *d_low = mkbuf("low-data", 8);
    int64_t slot_low = fn_dharafs_queue_submit_write_raw(2, 1, p_low, 6, d_low, 8, 0, 0, 0644);
    CHECK(slot_low >= 0, "fsqueue: low-priority submit succeeds");

    int64_t *p_high = mkbuf("/q/high", 7);
    int64_t *d_high = mkbuf("hi", 2);
    int64_t slot_high = fn_dharafs_queue_submit_write_raw(0, 2, p_high, 7, d_high, 2, 0, 0, 0644);
    CHECK(slot_high >= 0, "fsqueue: high-priority submit succeeds");

    CHECK(fn_dharafs_queue_pending_count() == 2, "fsqueue: 2 pending after 2 submits");
    CHECK(fn_dharafs_queue_pick_next() == slot_high, "fsqueue: pick_next picks the higher-priority (lower number) entry first, regardless of submit order");

    int64_t r1 = fn_dharafs_queue_dispatch_one();
    CHECK(r1 == 0, "fsqueue: first dispatch (the high-priority one) succeeds");
    CHECK(fn_dharafs_read("/q/high", g_data_scratch) == 2, "fsqueue: high-priority file is readable immediately after its dispatch");
    CHECK(fn_dharafs_read("/q/low", g_data_scratch) == -1, "fsqueue: low-priority file NOT yet written -- still queued behind it");

    int64_t r2 = fn_dharafs_queue_dispatch_one();
    CHECK(r2 == 0, "fsqueue: second dispatch (the low-priority one) succeeds");
    CHECK(fn_dharafs_read("/q/low", g_data_scratch) == 8, "fsqueue: low-priority file readable once its turn comes");
    CHECK(fn_dharafs_queue_dispatch_one() == -1, "fsqueue: queue drained, dispatch returns -1 again");

    /* FIFO tie-break among equal priorities. */
    int64_t *pa = mkbuf("/q/tie_a", 8);
    int64_t *pb = mkbuf("/q/tie_b", 8);
    int64_t *td = mkbuf("t", 1);
    int64_t slot_a = fn_dharafs_queue_submit_write_raw(1, 5, pa, 8, td, 1, 0, 0, 0644);
    int64_t slot_b = fn_dharafs_queue_submit_write_raw(1, 5, pb, 8, td, 1, 0, 0, 0644);
    CHECK(fn_dharafs_queue_pick_next() == slot_a, "fsqueue: equal priority -- earlier submission (FIFO) wins the tie");
    fn_dharafs_queue_dispatch_one();
    CHECK(fn_dharafs_queue_pick_next() == slot_b, "fsqueue: after draining the first tied entry, the second is next");
    fn_dharafs_queue_dispatch_one();

    /* Delete via the queue. */
    CHECK(fn_dharafs_append("/q/todelete", "gone-soon") == 0, "fsqueue: real synchronous write for the delete test");
    int64_t *p_del = mkbuf("/q/todelete", 11);
    int64_t slot_del = fn_dharafs_queue_submit_delete_raw(0, 3, p_del, 11);
    CHECK(slot_del >= 0, "fsqueue: delete submit succeeds");
    CHECK(fn_dharafs_queue_dispatch_one() == 0, "fsqueue: queued delete dispatches successfully");
    CHECK(fn_dharafs_read("/q/todelete", g_data_scratch) == -1, "fsqueue: file is gone after its queued delete is dispatched");

    /* Oversized data rejected outright, queue untouched. */
    int64_t before_count = fn_dharafs_queue_pending_count();
    int64_t *p_big = mkbuf("/q/big", 6);
    static int64_t big_data[64]; /* > 448 bytes worth of i64 slots, content irrelevant */
    int64_t slot_big = fn_dharafs_queue_submit_write_raw(0, 1, p_big, 6, big_data, 500, 0, 0, 0644);
    CHECK(slot_big == -1, "fsqueue: data_len > 448 (block payload cap) is rejected");
    CHECK(fn_dharafs_queue_pending_count() == before_count, "fsqueue: a rejected submit doesn't consume a slot");

    /* Queue-full behavior: fill all 8 slots, confirm the 9th is
     * rejected cleanly (never a crash, never silently overwrites). */
    fn_dharafs_queue_reset();
    int64_t last_slot = -2;
    for (int i = 0; i < 8; i++) {
        char namebuf[16];
        snprintf(namebuf, sizeof(namebuf), "/q/f%d", i);
        int64_t *pf = mkbuf(namebuf, (int64_t)strlen(namebuf));
        last_slot = fn_dharafs_queue_submit_write_raw(0, 1, pf, (int64_t)strlen(namebuf), td, 1, 0, 0, 0644);
        CHECK(last_slot >= 0, "fsqueue: fill loop -- slot 0..7 all accepted");
    }
    CHECK(fn_dharafs_queue_pending_count() == 8, "fsqueue: queue reports exactly full (8/8) after filling every slot");
    int64_t *p9 = mkbuf("/q/overflow", 11);
    CHECK(fn_dharafs_queue_submit_write_raw(0, 1, p9, 11, td, 1, 0, 0, 0644) == -1, "fsqueue: 9th submit on a full 8-slot queue is rejected, not silently dropped or overwritten");
    CHECK(fn_dharafs_queue_pending_count() == 8, "fsqueue: rejected 9th submit leaves the 8 real entries untouched");

    /* Str convenience wrapper -- basic functional smoke test (host
     * harness stubs current_eff_prio()/current_task_get() to a fixed
     * 0, so priority tagging itself isn't exercised here, only that
     * the wrapper correctly builds and submits a real request). */
    fn_dharafs_queue_reset();
    reset_fs();
    CHECK(fn_dharafs_queue_submit("/q/wrapper", "via-wrapper") >= 0, "fsqueue: Str convenience wrapper submits successfully");
    CHECK(fn_dharafs_queue_dispatch_one() == 0, "fsqueue: wrapper-submitted request dispatches successfully");
    CHECK(fn_dharafs_read("/q/wrapper", g_data_scratch) == 11, "fsqueue: wrapper-submitted file readable after dispatch");
}

/* ================= DharaFS named snapshots ================= */

static void test_snapshot(void) {
    reset_fs(); /* fn_dharafs_init() inside also calls fn_dharafs_snapshot_reset() */

    CHECK(fn_dharafs_append("/snap/a", "version1") == 0, "snapshot: write v1");
    CHECK(fn_dharafs_snapshot_create("s1") >= 0, "snapshot: create s1 after v1");

    CHECK(fn_dharafs_append("/snap/b", "born-after-s1") == 0, "snapshot: /snap/b written after s1, before s2");

    CHECK(fn_dharafs_append("/snap/a", "version2!") == 0, "snapshot: overwrite to v2");
    CHECK(fn_dharafs_snapshot_create("s2") >= 0, "snapshot: create s2 after v2 and after /snap/b");

    CHECK(fn_dharafs_delete("/snap/a") == 0, "snapshot: delete /snap/a (current state)");
    CHECK(fn_dharafs_read("/snap/a", g_data_scratch) == -1, "snapshot: /snap/a correctly gone in CURRENT state");

    int64_t len_s1 = fn_dharafs_snapshot_read("/snap/a", "s1", g_data_scratch);
    CHECK(len_s1 == 8, "snapshot: s1 still sees /snap/a with its v1 length, despite the later delete");
    CHECK(memcmp(g_data_scratch, "version1", 8) == 0, "snapshot: s1's content is byte-exact v1");

    int64_t len_s2 = fn_dharafs_snapshot_read("/snap/a", "s2", g_data_scratch);
    CHECK(len_s2 == 9, "snapshot: s2 sees /snap/a with its v2 length");
    CHECK(memcmp(g_data_scratch, "version2!", 9) == 0, "snapshot: s2's content is byte-exact v2, not v1");

    CHECK(fn_dharafs_snapshot_read("/snap/b", "s1", g_data_scratch) == -1, "snapshot: s1 correctly does NOT see /snap/b (didn't exist yet as of s1)");
    CHECK(fn_dharafs_snapshot_read("/snap/b", "s2", g_data_scratch) >= 0, "snapshot: s2 DOES see /snap/b (existed by then)");

    CHECK(fn_dharafs_snapshot_read("/snap/a", "no-such-snapshot", g_data_scratch) == -1, "snapshot: unknown snapshot name returns -1, not a crash");

    CHECK(fn_dharafs_snapshot_create("s1") == -1, "snapshot: duplicate name is rejected outright");
    CHECK(fn_dharafs_snapshot_delete("s1") == 0, "snapshot: delete s1");
    CHECK(fn_dharafs_snapshot_create("s1") >= 0, "snapshot: name is reusable once deleted");
    CHECK(fn_dharafs_snapshot_read("/snap/a", "s1", g_data_scratch) == -1, "snapshot: the NEW s1 (created after the delete) correctly does NOT see the old v1 content");

    /* The real point of this feature: a snapshot survives dharafs_compact
     * reclaiming the block its own data physically lived in -- because
     * compact only ever advances the in-RAM log_start optimization, it
     * never erases bytes already on disk (see snapshot_state.S's own
     * header comment). */
    fn_dharafs_snapshot_delete("s1");
    reset_fs();
    CHECK(fn_dharafs_append("/snap/x", "old-value") == 0, "snapshot+compact: write old value");
    CHECK(fn_dharafs_snapshot_create("before_overwrite") >= 0, "snapshot+compact: pin it");
    CHECK(fn_dharafs_append("/snap/x", "new-value!") == 0, "snapshot+compact: overwrite");
    CHECK(fn_dharafs_append("/snap/y", "filler1") == 0, "snapshot+compact: filler write 1 (compact needs >=4 blocks of headroom to do real work)");
    CHECK(fn_dharafs_append("/snap/z", "filler2") == 0, "snapshot+compact: filler write 2");
    int64_t *compact_buf = dhruva_alloc_bytes(512);
    int64_t *compact_path_buf = dhruva_alloc_bytes(32);
    int64_t *compact_data_buf = dhruva_alloc_bytes(4096);
    fn_dharafs_compact(compact_buf, compact_path_buf, compact_data_buf);
    CHECK(fn_dharafs_read("/snap/x", g_data_scratch) == 10, "snapshot+compact: current read of /snap/x still sees new-value! after compaction");
    int64_t len_before = fn_dharafs_snapshot_read("/snap/x", "before_overwrite", g_data_scratch);
    CHECK(len_before == 9, "snapshot+compact: the snapshot STILL sees the pre-overwrite old-value length after compact() ran and reclaimed that block from ordinary lookups");
    CHECK(memcmp(g_data_scratch, "old-value", 9) == 0, "snapshot+compact: and the content is still byte-exact old-value");

    /* Table-full behavior. */
    fn_dharafs_snapshot_reset();
    for (int i = 0; i < 8; i++) {
        char namebuf[16];
        snprintf(namebuf, sizeof(namebuf), "snap%d", i);
        CHECK(fn_dharafs_snapshot_create(namebuf) >= 0, "snapshot: fill loop -- 0..7 all accepted");
    }
    CHECK(fn_dharafs_snapshot_create("snap_overflow") == -1, "snapshot: 9th create on a full 8-slot table is rejected cleanly");
}

/* ================= dirlist_seen_contains / segment_equals unit tests ================= */

static void test_dirlist_helpers(void) {
    int64_t *seen = dhruva_alloc_bytes(128 * 32);
    buf_write_byte(seen, 0, 3);
    buf_write_byte(seen, 1, 'f'); buf_write_byte(seen, 2, 'o'); buf_write_byte(seen, 3, 'o');

    int64_t *path = mkbuf("xxfooyy", 7);
    CHECK(fn_dharafs_dirlist_seen_contains(seen, 1, path, 2, 3) == 1, "dirlist_helpers: seen_contains finds exact match");
    CHECK(fn_dharafs_dirlist_seen_contains(seen, 1, path, 0, 2) == 0, "dirlist_helpers: seen_contains rejects different segment");
    CHECK(fn_dharafs_dirlist_seen_contains(seen, 0, path, 2, 3) == 0, "dirlist_helpers: seen_contains with count=0 always false");

    int64_t *query = mkbuf("foo", 3);
    CHECK(fn_dharafs_dirlist_segment_equals(query, 3, path, 2, 3) == 1, "dirlist_helpers: segment_equals matches");
    CHECK(fn_dharafs_dirlist_segment_equals(query, 3, path, 0, 2) == 0, "dirlist_helpers: segment_equals length mismatch rejects");
}

/* ================= Malformed on-disk records ================= */

/* Writes a fully-formed 512-byte record straight to the virtual disk,
 * bypassing dharafs_append_raw entirely -- lets us construct records
 * no real append path would ever produce, to test recovery/read
 * against genuinely corrupted or adversarial disk contents. */
static void write_raw_record(int64_t block, uint32_t seq, const char *path, int64_t path_len,
                              uint32_t data_len_field, uint32_t next_block_field,
                              const char *data, int64_t data_len, int corrupt_checksum) {
    int64_t *b = dhruva_alloc_bytes(512);
    buf_write_u32(b, 4, seq);
    buf_write_u32(b, 8, (uint32_t)path_len);
    for (int64_t i = 0; i < path_len; i++) buf_write_byte(b, (uint32_t)(12 + i), (uint32_t)(unsigned char)path[i]);
    buf_write_u32(b, 44, data_len_field);
    buf_write_u32(b, 48, next_block_field);
    for (int64_t i = 0; i < data_len; i++) buf_write_byte(b, (uint32_t)(64 + i), (uint32_t)(unsigned char)data[i]);
    uint32_t csum = buf_checksum(b, 4, 508);
    if (corrupt_checksum) csum ^= 0xdeadbeef;
    buf_write_u32(b, 0, csum);
    host_virtual_disk_write(block, b);
}

static void test_corrupted_checksum_skipped(void) {
    reset_fs();
    /* Block 1 with a deliberately WRONG checksum -- recovery/find_latest
     * must skip it, not trust the (corrupted) length/path fields. */
    write_raw_record(1, 1, "/x", 2, 5, 0, "hello", 5, /*corrupt=*/1);
    fn_dharafs_init(); /* re-run recovery scan against the corrupted disk */
    int64_t blk = fn_dharafs_find_latest_block_raw(mkbuf("/x", 2), 2);
    CHECK(blk == -1, "corrupted_checksum: record with bad checksum is never found");
}

static void test_oversized_data_len_field_rejected(void) {
    reset_fs();
    /* A record whose on-disk data_len field claims more than
     * dharafs_file_max_len() -- dharafs_read_raw must reject this
     * outright rather than using it as a copy-loop bound (this is
     * exactly the round-2026-08-27 audit fix noted in kernel_main.
     * vani's own comment on dharafs_read_raw; re-verifying it here). */
    write_raw_record(1, 1, "/y", 2, 0xFFFFFFF0u, 0, "z", 1, /*corrupt=*/0);
    /* dharafs_state_set: next_block must be > 1 for the scan to see block 1. */
    extern uint32_t dharafs_state_set(uint32_t, uint32_t);
    dharafs_state_set(2, 2);
    int64_t *out = dhruva_alloc_bytes(16);
    int64_t rd = fn_dharafs_read_raw(mkbuf("/y", 2), 2, out);
    CHECK(rd == -1, "oversized_data_len: absurd on-disk data_len field is rejected, not used as a copy bound");
}

/* Runs `fn` in a child process with a wall-clock timeout, so a
 * genuine infinite loop in the code under test can be detected and
 * reported instead of hanging the whole harness forever. Returns 1 if
 * the child exited within the timeout, 0 if it had to be killed
 * (i.e. a hang was detected). */
static int run_with_timeout(void (*fn)(void), int timeout_sec) {
    pid_t pid = fork();
    if (pid == 0) {
        fn();
        _exit(0);
    }
    for (int waited = 0; waited < timeout_sec * 10; waited++) {
        int status;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) return 1;
        usleep(100 * 1000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    return 0;
}

static void do_self_referential_continuation_read(void) {
    reset_fs();
    /* HEAD record: total data_len=500 (> 448-byte cap, so this is a
     * genuine multi-block file), next_block=2. */
    write_raw_record(1, 1, "/loop", 5, 500, 2, "", 0, /*corrupt=*/0);
    /* Continuation record at block 2: path_len=0 (continuation
     * marker, required to pass dharafs_read_raw's own check) but
     * data_len(field 44)=0 -- a length no REAL append path would ever
     * write (every real continuation chunk's length is > 0), and
     * next_block points back to ITSELF. */
    write_raw_record(2, 2, "", 0, 0, 2, "", 0, /*corrupt=*/0);
    extern uint32_t dharafs_state_set(uint32_t, uint32_t);
    dharafs_state_set(3, 3);
    int64_t *out = dhruva_alloc_bytes(500);
    fn_dharafs_read_raw(mkbuf("/loop", 5), 5, out);
}

static void test_self_referential_continuation_chain(void) {
    int ok = run_with_timeout(do_self_referential_continuation_read, 2);
    CHECK(ok == 1,
          "self_referential_chain: dharafs_read_raw terminates on a "
          "malformed disk with a zero-length self-pointing continuation "
          "block (a chain no real append path produces, but a corrupted/"
          "adversarial disk image could) -- if this FAILS, it's a real "
          "hang/DoS bug: the read loop's `remaining` never decreases "
          "when a continuation record's own data_len field is 0, so it "
          "never reaches the loop's only exit condition");
}

/* ================= Verified (SHA-256 companion digest) I/O (round 48) ================= */

extern uint32_t dharafs_state_get_next_block(void);
extern uint32_t dharafs_state_get_next_seq(void);

static void test_verified_integrity(void) {
    reset_fs();
    int64_t *path = mkbuf("/secure", 7);
    int64_t *data = mkbuf("top-secret-config", 17);
    CHECK(fn_dharafs_write_verified_checked(path, 7, data, 17, 0, 0) == 0, "verified: writev succeeds");

    int64_t *out = dhruva_alloc_bytes(17);
    int64_t rd = fn_dharafs_read_verified_checked(path, 7, out, 0, 0);
    CHECK(rd == 17, "verified: readv returns correct length when digest matches");
    CHECK(memcmp(out, "top-secret-config", 17) == 0, "verified: readv returns correct bytes when digest matches");

    int64_t *companion = dhruva_alloc_bytes(32);
    int64_t companion_len = fn_dharafs_verified_companion_path_raw(path, 7, companion);
    CHECK(companion_len == 14, "verified: companion path is path + \".sha256\" (14 bytes)");
    CHECK(memcmp(companion, "/secure.sha256", 14) == 0, "verified: companion path bytes are correct");

    int64_t *out2 = dhruva_alloc_bytes(17);
    CHECK(fn_dharafs_read_raw(path, 7, out2) == 17, "verified: plain dharafs_read_raw still works on a verified file");

    /* Verification is opt-in per path: a plain (non-verified) write
     * has no companion digest, and readv on it must not error. */
    int64_t *plain_path = mkbuf("/plain", 6);
    int64_t *plain_data = mkbuf("nothing-special", 15);
    CHECK(fn_dharafs_append_raw(plain_path, 6, plain_data, 15, 0, 0, 0644) == 0, "verified: plain (non-verified) write succeeds");
    int64_t *out3 = dhruva_alloc_bytes(15);
    CHECK(fn_dharafs_read_verified_checked(plain_path, 6, out3, 0, 0) == 15, "verified: readv on a file with no companion digest just returns plain data length");

    /* Path length boundary: 25 bytes + 7-byte suffix fits exactly in
     * the 32-byte path cap; 26 does not. */
    char path25[25];
    memset(path25, 'p', 25);
    int64_t *out4 = dhruva_alloc_bytes(32);
    CHECK(fn_dharafs_verified_companion_path_raw(mkbuf(path25, 25), 25, out4) == 32, "verified: 25-byte path fits exactly a companion digest path (32 bytes)");
    char path26[26];
    memset(path26, 'q', 26);
    CHECK(fn_dharafs_verified_companion_path_raw(mkbuf(path26, 26), 26, out4) == -1, "verified: 26-byte path has no room for a companion digest");
    CHECK(fn_dharafs_write_verified_checked(mkbuf(path26, 26), 26, data, 17, 0, 0) == -1, "verified: writev on a 26-byte path is rejected (-1), not silently written without a digest");

    /* Tamper detection: directly corrupt the companion digest RECORD
     * on the virtual disk (simulating an attacker or corruption event
     * touching the digest sidecar independently of the data it
     * protects) -- readv must detect the mismatch, not trust it. */
    reset_fs();
    int64_t *path2 = mkbuf("/firmware", 9);
    int64_t *data2 = mkbuf("real-firmware-bytes", 19);
    uint32_t block_before = dharafs_state_get_next_block();
    uint32_t seq_before = dharafs_state_get_next_seq();
    CHECK(fn_dharafs_write_verified_checked(path2, 9, data2, 19, 0, 0) == 0, "tamper: writev succeeds");

    char wrong_digest[32];
    memset(wrong_digest, 0xAB, 32);
    write_raw_record(block_before + 1, seq_before + 2, "/firmware.sha256", 16, 32, 0, wrong_digest, 32, /*corrupt_checksum=*/0);
    extern uint32_t dharafs_state_set(uint32_t, uint32_t);
    dharafs_state_set(block_before + 2, seq_before + 3);

    int64_t *out5 = dhruva_alloc_bytes(19);
    int64_t rd2 = fn_dharafs_read_verified_checked(path2, 9, out5, 0, 0);
    CHECK(rd2 == -3, "tamper: readv detects a companion digest that doesn't match the data");
}

/* ================= Append-only log API (round 49) ================= */

static void test_log_append(void) {
    reset_fs();

    int64_t *name = mkbuf("sensor", 6);
    int64_t *log_path = dhruva_alloc_bytes(32);
    int64_t log_path_len = fn_dharafs_log_path_raw(name, 6, 1, log_path);
    CHECK(log_path_len == 21, "log: path for index 1 is 21 bytes");
    CHECK(memcmp(log_path, "/logs/sensor-0001.log", 21) == 0, "log: path bytes are correct (zero-padded 4-digit index)");

    int64_t *header_path = dhruva_alloc_bytes(32);
    int64_t header_path_len = fn_dharafs_log_header_path_raw(name, 6, header_path);
    CHECK(header_path_len == 16, "log: header path is 16 bytes");
    CHECK(memcmp(header_path, "/logs/sensor.hdr", 16) == 0, "log: header path bytes are correct");

    /* First-ever append to a brand-new log name always rolls over to
     * index 1, regardless of size. */
    char record[400];
    memset(record, 'x', 400);
    int64_t *record_buf = mkbuf(record, 400);
    CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 400, 0, 0, 0644) == 0, "log: first append succeeds (rolls over to index 1)");

    int64_t *out = dhruva_alloc_bytes(4096);
    int64_t rd = fn_dharafs_read_raw(log_path, log_path_len, out);
    CHECK(rd == 400, "log: file 1 has exactly the first record's bytes");
    CHECK(memcmp(out, record, 400) == 0, "log: file 1 content matches the record written");

    /* 7 more 400-byte appends (total 8 records, 3200 bytes) stay
     * within the rollover threshold (3584) and accumulate into the
     * SAME file. */
    for (int k = 0; k < 7; k++) {
        CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 400, 0, 0, 0644) == 0, "log: accumulating append succeeds");
    }
    int64_t rd2 = fn_dharafs_read_raw(log_path, log_path_len, out);
    CHECK(rd2 == 3200, "log: file 1 accumulated to 8 * 400 = 3200 bytes, no rollover yet");

    /* The 9th append (3200 + 400 = 3600 > 3584) must roll over to a
     * NEW file, index 2, containing ONLY the new record -- file 1
     * stays at 3200 bytes, untouched. */
    CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 400, 0, 0, 0644) == 0, "log: 9th append succeeds (triggers rollover)");
    int64_t *log_path2 = dhruva_alloc_bytes(32);
    int64_t log_path2_len = fn_dharafs_log_path_raw(name, 6, 2, log_path2);
    int64_t rd3 = fn_dharafs_read_raw(log_path2, log_path2_len, out);
    CHECK(rd3 == 400, "log: file 2 (post-rollover) has exactly the 9th record's bytes");
    int64_t rd4 = fn_dharafs_read_raw(log_path, log_path_len, out);
    CHECK(rd4 == 3200, "log: file 1 is UNCHANGED after rollover (still 3200 bytes)");

    /* Header tracks the CURRENT file correctly after rollover. */
    int64_t *hdr_out = dhruva_alloc_bytes(8);
    int64_t hdr_rd = fn_dharafs_read_raw(header_path, header_path_len, hdr_out);
    CHECK(hdr_rd == 8, "log: header file is exactly 8 bytes");
    CHECK(buf_read_u32(hdr_out, 0) == 2, "log: header's current_index is 2 after rollover");
    CHECK(buf_read_u32(hdr_out, 4) == 400, "log: header's current_size is 400 (just the new file's content)");

    /* A record over the 512-byte per-record cap is rejected. */
    char big_record[513];
    memset(big_record, 'y', 513);
    int64_t *big_record_buf = mkbuf(big_record, 513);
    CHECK(fn_dharafs_log_append_raw(name, 6, big_record_buf, 513, 0, 0, 0644) == 1, "log: record over 512 bytes is rejected");
    CHECK(fn_dharafs_log_record_max_len() == 512, "log: record_max_len() is 512");
    CHECK(fn_dharafs_log_rollover_threshold() == 3584, "log: rollover_threshold() is 3584");

    /* A log name long enough that "/logs/" + name + ".hdr" fits (<=32)
     * but "/logs/" + name + "-0001.log" does NOT (> 32) is rejected
     * with -1, not a half-written, inconsistent state. */
    char long_name[20];
    memset(long_name, 'n', 20);
    int64_t *long_name_buf = mkbuf(long_name, 20);
    int64_t status = fn_dharafs_log_append_raw(long_name_buf, 20, record_buf, 400, 0, 0, 0644);
    CHECK(status == -1, "log: name too long for the log file path (though short enough for the header path) is rejected");

    /* Empty name / empty record rejected. */
    CHECK(fn_dharafs_log_append_raw(name, 0, record_buf, 400, 0, 0, 0644) == 1, "log: empty name rejected");
    CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 0, 0, 0, 0644) == 1, "log: empty record rejected");
}

/* ================= Log GC of old generations (round 66) ================= */

static void test_log_gc(void) {
    reset_fs();

    int64_t retention = fn_dharafs_log_retention_count();
    CHECK(retention == 5, "log_gc: retention_count() is 5");

    int64_t *name = mkbuf("sensor", 6);
    char record[400];
    memset(record, 'x', 400);
    int64_t *record_buf = mkbuf(record, 400);
    int64_t *out = dhruva_alloc_bytes(4096);

    /* Drive the log through 7 rollovers (index 1 -> 8): the very first
     * append always rolls to index 1, then each subsequent rollover
     * needs 8 accumulating appends (8*400=3200, under the 3584
     * threshold) plus a 9th that pushes it over. */
    CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 400, 0, 0, 0644) == 0, "log_gc: initial append rolls to index 1");
    for (int gen = 0; gen < 7; gen++) {
        for (int k = 0; k < 8; k++) {
            CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 400, 0, 0, 0644) == 0, "log_gc: accumulating append succeeds");
        }
        CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 400, 0, 0, 0644) == 0, "log_gc: rollover-triggering append succeeds");
    }

    /* Now at index 8 (1 initial rollover + 7 more). Retention is 5, so
     * generations 1-3 (8 - 5 = 3, everything at or below that) must be
     * reclaimed; 4 through 8 (the current one) must still exist. */
    for (int idx = 1; idx <= 3; idx++) {
        int64_t *p = dhruva_alloc_bytes(32);
        int64_t plen = fn_dharafs_log_path_raw(name, 6, idx, p);
        int64_t rd = fn_dharafs_read_raw(p, plen, out);
        char msg[64];
        snprintf(msg, sizeof(msg), "log_gc: generation %d was reclaimed (not readable)", idx);
        CHECK(rd == -1, msg);
    }
    for (int idx = 4; idx <= 8; idx++) {
        int64_t *p = dhruva_alloc_bytes(32);
        int64_t plen = fn_dharafs_log_path_raw(name, 6, idx, p);
        int64_t rd = fn_dharafs_read_raw(p, plen, out);
        char msg[64];
        snprintf(msg, sizeof(msg), "log_gc: generation %d was kept (still readable)", idx);
        CHECK(rd >= 0, msg);
    }

    /* Header still correctly tracks the current (8th) generation --
     * GC reclaiming old files must never disturb where new appends go. */
    int64_t *header_path = dhruva_alloc_bytes(32);
    int64_t header_path_len = fn_dharafs_log_header_path_raw(name, 6, header_path);
    int64_t *hdr_out = dhruva_alloc_bytes(8);
    int64_t hdr_rd = fn_dharafs_read_raw(header_path, header_path_len, hdr_out);
    CHECK(hdr_rd == 8, "log_gc: header file still exactly 8 bytes after GC");
    CHECK(buf_read_u32(hdr_out, 0) == 8, "log_gc: header's current_index is still 8 after GC");

    /* A different log name's own generations are untouched by this
     * one's GC -- reclaiming is scoped per log name, not global. */
    int64_t *other_name = mkbuf("other", 5);
    CHECK(fn_dharafs_log_append_raw(other_name, 5, record_buf, 400, 0, 0, 0644) == 0, "log_gc: unrelated log name append succeeds");
    int64_t *other_path = dhruva_alloc_bytes(32);
    int64_t other_path_len = fn_dharafs_log_path_raw(other_name, 5, 1, other_path);
    CHECK(fn_dharafs_read_raw(other_path, other_path_len, out) == 400, "log_gc: unrelated log name's own generation 1 is untouched");
}

/* ================= File attributes (round 50) ================= */

static void test_attributes(void) {
    reset_fs();

    /* Basic set/get round trip, owner setting immutable on their own file. */
    int64_t *path = mkbuf("/firmware.bin", 13);
    int64_t *data = mkbuf("v1", 2);
    CHECK(fn_dharafs_append_raw(path, 13, data, 2, 42, 42, 0644) == 0, "attr: create /firmware.bin as uid 42");
    CHECK(fn_dharafs_get_attr_raw(path, 13) == 0, "attr: new file has no attributes set");
    uint32_t immutable = fn_dharafs_attr_immutable();
    CHECK(fn_dharafs_set_attr_raw(path, 13, immutable, 42, 42) == 0, "attr: owner sets immutable");
    CHECK(fn_dharafs_get_attr_raw(path, 13) == (int64_t)immutable, "attr: get_attr reflects the immutable bit");

    /* Immutable blocks write, delete, and being a rename source or destination. */
    int64_t *data2 = mkbuf("v2", 2);
    CHECK(fn_dharafs_write_raw_checked(path, 13, data2, 2, 42, 42) == -4, "attr: write to immutable file is blocked (-4)");
    CHECK(fn_dharafs_delete_raw_checked(path, 13, 42, 42) == -4, "attr: delete of immutable file is blocked (-4)");
    int64_t *dest = mkbuf("/renamed.bin", 12);
    CHECK(fn_dharafs_rename_raw_checked(path, 13, dest, 12, 42, 42) == -4, "attr: renaming an immutable file (as source) is blocked (-4)");
    int64_t *other = mkbuf("/other.bin", 10);
    int64_t *odata = mkbuf("o", 1);
    CHECK(fn_dharafs_append_raw(other, 10, odata, 1, 42, 42, 0644) == 0, "attr: create /other.bin");
    CHECK(fn_dharafs_rename_raw_checked(other, 10, path, 13, 42, 42) == -4, "attr: renaming ONTO an immutable file (as destination) is blocked (-4)");

    /* A non-root owner cannot clear immutable once set; root can. */
    CHECK(fn_dharafs_set_attr_raw(path, 13, 0, 42, 42) == -2, "attr: non-root owner cannot clear immutable (-2)");
    CHECK(fn_dharafs_set_attr_raw(path, 13, 0, 0, 0) == 0, "attr: root CAN clear immutable");
    CHECK(fn_dharafs_get_attr_raw(path, 13) == 0, "attr: immutable is actually cleared after root's change");
    /* Now that it's cleared, normal operations work again. */
    CHECK(fn_dharafs_write_raw_checked(path, 13, data2, 2, 42, 42) == 0, "attr: write succeeds again once immutable is cleared");

    /* A non-owner, non-root caller cannot set attributes at all. */
    CHECK(fn_dharafs_set_attr_raw(path, 13, immutable, 99, 99) == -2, "attr: non-owner cannot set attributes (-2)");

    /* Append-only: valid extensions succeed, anything else is blocked. */
    reset_fs();
    int64_t *apath = mkbuf("/audit.log", 10);
    int64_t *a1 = mkbuf("event1;", 7);
    CHECK(fn_dharafs_append_raw(apath, 10, a1, 7, 7, 7, 0644) == 0, "attr_append: create /audit.log");
    uint32_t append_only = fn_dharafs_attr_append_only();
    CHECK(fn_dharafs_set_attr_raw(apath, 10, append_only, 7, 7) == 0, "attr_append: owner sets append-only");

    int64_t *a2 = mkbuf("event1;event2;", 14);
    CHECK(fn_dharafs_write_raw_checked(apath, 10, a2, 14, 7, 7) == 0, "attr_append: valid extension (old content as exact prefix) succeeds");
    int64_t *out = dhruva_alloc_bytes(14);
    CHECK(fn_dharafs_read_raw(apath, 10, out) == 14, "attr_append: content actually extended");
    CHECK(memcmp(out, "event1;event2;", 14) == 0, "attr_append: extended content is correct");

    int64_t *bad_not_prefix = mkbuf("totally-different", 17);
    CHECK(fn_dharafs_write_raw_checked(apath, 10, bad_not_prefix, 17, 7, 7) == -4, "attr_append: a write that doesn't start with the old content is blocked (-4)");
    int64_t *bad_shorter = mkbuf("event1", 6);
    CHECK(fn_dharafs_write_raw_checked(apath, 10, bad_shorter, 6, 7, 7) == -4, "attr_append: a SHORTER write (truncation) is blocked (-4)");
    int64_t *bad_same = mkbuf("event1;event2;", 14);
    CHECK(fn_dharafs_write_raw_checked(apath, 10, bad_same, 14, 7, 7) == 0, "attr_append: re-writing the exact same content is a valid (zero-length) extension");

    /* Append-only also blocks delete, but NOT rename (real chattr +a semantics). */
    CHECK(fn_dharafs_delete_raw_checked(apath, 10, 7, 7) == -4, "attr_append: delete of append-only file is blocked (-4)");
    int64_t *arenamed = mkbuf("/audit-renamed.log", 18);
    CHECK(fn_dharafs_rename_raw_checked(apath, 10, arenamed, 18, 7, 7) == 0, "attr_append: rename of an append-only file (as source) DOES succeed");
    int64_t *out2 = dhruva_alloc_bytes(14);
    CHECK(fn_dharafs_read_raw(arenamed, 18, out2) == 14, "attr_append: content survives the rename intact");

    /* Direct unit tests of the pure prefix-check helper. */
    int64_t *old_c = mkbuf("abc", 3);
    int64_t *new_c1 = mkbuf("abcdef", 6);
    int64_t *new_c2 = mkbuf("abd", 3);
    int64_t *new_c3 = mkbuf("ab", 2);
    CHECK(fn_dharafs_is_valid_append_only_write(old_c, 3, new_c1, 6) == 1, "append_only_helper: real extension is valid");
    CHECK(fn_dharafs_is_valid_append_only_write(old_c, 3, new_c2, 3) == 0, "append_only_helper: same-length but different content is invalid");
    CHECK(fn_dharafs_is_valid_append_only_write(old_c, 3, new_c3, 2) == 0, "append_only_helper: shorter content is invalid");

    /* System attribute: settable/queryable, no enforcement of its own. */
    reset_fs();
    int64_t *spath = mkbuf("/marker", 7);
    int64_t *sdata = mkbuf("s", 1);
    CHECK(fn_dharafs_append_raw(spath, 7, sdata, 1, 3, 3, 0644) == 0, "attr_system: create /marker");
    uint32_t system_attr = fn_dharafs_attr_system();
    CHECK(fn_dharafs_set_attr_raw(spath, 7, system_attr, 3, 3) == 0, "attr_system: owner sets system attribute");
    CHECK(fn_dharafs_get_attr_raw(spath, 7) == (int64_t)system_attr, "attr_system: get_attr reflects it");
    int64_t *sdata2 = mkbuf("t", 1);
    CHECK(fn_dharafs_write_raw_checked(spath, 7, sdata2, 1, 3, 3) == 0, "attr_system: write still works (no enforcement for this attribute)");
    CHECK(fn_dharafs_delete_raw_checked(spath, 7, 3, 3) == 0, "attr_system: delete still works (no enforcement for this attribute)");
    /* Non-root CAN clear system (only immutable/append-only are protected from clearing). */
    reset_fs();
    int64_t *spath2 = mkbuf("/marker2", 8);
    CHECK(fn_dharafs_append_raw(spath2, 8, sdata, 1, 5, 5, 0644) == 0, "attr_system2: create /marker2");
    CHECK(fn_dharafs_set_attr_raw(spath2, 8, system_attr, 5, 5) == 0, "attr_system2: owner sets system");
    CHECK(fn_dharafs_set_attr_raw(spath2, 8, 0, 5, 5) == 0, "attr_system2: non-root owner CAN clear system");
}

/* ================= chmod/chown permission checks (bug fix) ================= */

static void test_chmod_chown_permissions(void) {
    reset_fs();
    int64_t *path = mkbuf("/owned42", 8);
    int64_t *data = mkbuf("x", 1);
    CHECK(fn_dharafs_append_raw(path, 8, data, 1, 42, 42, 0644) == 0, "chmod_perm: create /owned42 as uid 42");

    /* chmod: owner may change mode; a non-owner, non-root may not. */
    CHECK(fn_dharafs_chmod_checked(path, 8, 0600, 99, 99) == -2, "chmod_perm: non-owner chmod denied");
    CHECK(fn_dharafs_chmod_checked(path, 8, 0600, 42, 42) == 0, "chmod_perm: owner chmod succeeds");
    int64_t *meta = dhruva_alloc_bytes(12);
    CHECK(fn_dharafs_stat_raw(path, 8, meta) == 0, "chmod_perm: stat after chmod succeeds");
    CHECK(buf_read_u32(meta, 8) == 0600, "chmod_perm: mode actually changed to 0600");
    /* root may always chmod, regardless of ownership. */
    CHECK(fn_dharafs_chmod_checked(path, 8, 0644, 0, 0) == 0, "chmod_perm: root chmod succeeds regardless of ownership");
    /* A third, unrelated uid (neither the real owner 42 nor root) is
     * still denied, confirming the check is by real ownership, not
     * just "not uid 99 from the earlier check". */
    CHECK(fn_dharafs_chmod_checked(path, 8, 0644, 7, 7) == -2, "chmod_perm: a third unrelated uid is also denied");

    /* chmod of a nonexistent path returns -1, not -2 or a crash. */
    int64_t *missing = mkbuf("/nope", 5);
    CHECK(fn_dharafs_chmod_checked(missing, 5, 0644, 0, 0) == -1, "chmod_perm: chmod of nonexistent path returns -1");

    /* chown: ROOT ONLY -- even the owner may not chown their own file
     * to someone else (real strict POSIX default, no owner exemption
     * unlike chmod). */
    reset_fs();
    int64_t *path2 = mkbuf("/owned7", 7);
    int64_t *data2 = mkbuf("y", 1);
    CHECK(fn_dharafs_append_raw(path2, 7, data2, 1, 7, 7, 0644) == 0, "chown_perm: create /owned7 as uid 7");
    CHECK(fn_dharafs_chown_checked(path2, 7, 99, 99, 7, 7) == -2, "chown_perm: owner (non-root) cannot chown their own file");
    CHECK(fn_dharafs_chown_checked(path2, 7, 99, 99, 42, 42) == -2, "chown_perm: an unrelated non-root uid cannot chown either");
    CHECK(fn_dharafs_chown_checked(path2, 7, 99, 99, 0, 0) == 0, "chown_perm: root CAN chown");
    int64_t *meta2 = dhruva_alloc_bytes(12);
    CHECK(fn_dharafs_stat_raw(path2, 7, meta2) == 0, "chown_perm: stat after chown succeeds");
    CHECK(buf_read_u32(meta2, 0) == 99, "chown_perm: owner_uid actually changed to 99");
    CHECK(buf_read_u32(meta2, 4) == 99, "chown_perm: owner_gid actually changed to 99");
    CHECK(fn_dharafs_chown_checked(missing, 5, 1, 1, 0, 0) == -1, "chown_perm: chown of nonexistent path returns -1");
}

/* ================= Crypto / bignum smoke tests through the real
 * on-disk-adjacent entry points (byte-for-byte correctness matters
 * here just as much as for DharaFS, since these back the security-
 * hardening roadmap's planned encrypted-storage work). ================= */

static void test_sha256_boundaries(void) {
    /* FIPS 180-4 empty-string vector. */
    int64_t *msg0 = dhruva_alloc_bytes(1);
    int64_t *out0 = dhruva_alloc_bytes(32);
    fn_sha256_hash(msg0, 0, out0);
    static const unsigned char expect_empty[32] = {
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8,
        0x99, 0x6f, 0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55};
    int64_t *exp0 = mkbuf((const char *)expect_empty, 32);
    CHECK(fn_sha256_bytes_equal(out0, exp0, 32) == 1, "sha256: empty-string vector matches FIPS 180-4");

    /* Message length exactly at the 55/56/64-byte padding boundaries. */
    for (int64_t len = 54; len <= 65; len++) {
        int64_t *msg = dhruva_alloc_bytes(len > 0 ? len : 1);
        for (int64_t i = 0; i < len; i++) buf_write_byte(msg, (uint32_t)i, (uint32_t)('a' + (i % 26)));
        int64_t *out = dhruva_alloc_bytes(32);
        int64_t st = fn_sha256_hash(msg, len, out);
        char desc[80];
        snprintf(desc, sizeof(desc), "sha256: len=%lld does not crash/corrupt (padding boundary)", (long long)len);
        CHECK(st == 0, desc);
    }
}

/* Real authentication's own crypto layer: HMAC-SHA256 (RFC 2104) and
 * PBKDF2-HMAC-SHA256 (RFC 8018), same KATs as kernel_main.vani's own
 * hmac_sha256_self_test/pbkdf2_hmac_sha256_self_test -- independently
 * verified against Python's hmac/hashlib before either test was
 * written, not hand-derived. Gives this new crypto code the same
 * ASAN/UBSAN sanitizer coverage every other primitive here already
 * gets, not just the on-target self-test. */
static void test_hmac_pbkdf2_boundaries(void) {
    /* RFC 4231 test case 1's own key shape: 20 bytes of 0x0b, "Hi There". */
    static const unsigned char key1_bytes[20] = {
        0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,
        0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b};
    int64_t *key1 = mkbuf((const char *)key1_bytes, 20);
    int64_t *msg1 = mkbuf("Hi There", 8);
    int64_t *out1 = dhruva_alloc_bytes(32);
    fn_hmac_sha256(key1, 20, msg1, 8, out1);
    static const unsigned char exp1_bytes[32] = {
        0xb0,0x34,0x4c,0x61,0xd8,0xdb,0x38,0x53,0x5c,0xa8,0xaf,0xce,0xaf,0x0b,0xf1,0x2b,
        0x88,0x1d,0xc2,0x00,0xc9,0x83,0x3d,0xa7,0x26,0xe9,0x37,0x6c,0x2e,0x32,0xcf,0xf7};
    int64_t *exp1 = mkbuf((const char *)exp1_bytes, 32);
    CHECK(fn_hmac_sha256_bytes_equal(out1, exp1, 32) == 1, "hmac-sha256: RFC-4231-shaped key vector matches");

    /* PBKDF2-HMAC-SHA256("password","salt",1,32) -- verified against
     * Python's hashlib.pbkdf2_hmac before writing this. */
    int64_t *password = mkbuf("password", 8);
    int64_t *salt = mkbuf("salt", 4);
    int64_t *pout1 = dhruva_alloc_bytes(32);
    fn_pbkdf2_hmac_sha256(password, 8, salt, 4, 1, pout1);
    static const unsigned char pexp1_bytes[32] = {
        0x12,0x0f,0xb6,0xcf,0xfc,0xf8,0xb3,0x2c,0x43,0xe7,0x22,0x52,0x56,0xc4,0xf8,0x37,
        0xa8,0x65,0x48,0xc9,0x2c,0xcc,0x35,0x48,0x08,0x05,0x98,0x7c,0xb7,0x0b,0xe1,0x7b};
    int64_t *pexp1 = mkbuf((const char *)pexp1_bytes, 32);
    CHECK(fn_hmac_sha256_bytes_equal(pout1, pexp1, 32) == 1, "pbkdf2-hmac-sha256: iterations=1 KAT matches");

    /* PBKDF2-HMAC-SHA256("password","salt",4096,32) -- a real,
     * non-trivial iteration count, confirming the loop is correct at
     * scale, not just for the first step. */
    int64_t *pout2 = dhruva_alloc_bytes(32);
    fn_pbkdf2_hmac_sha256(password, 8, salt, 4, 4096, pout2);
    static const unsigned char pexp2_bytes[32] = {
        0xc5,0xe4,0x78,0xd5,0x92,0x88,0xc8,0x41,0xaa,0x53,0x0d,0xb6,0x84,0x5c,0x4c,0x8d,
        0x96,0x28,0x93,0xa0,0x01,0xce,0x4e,0x11,0xa4,0x96,0x38,0x73,0xaa,0x98,0x13,0x4a};
    int64_t *pexp2 = mkbuf((const char *)pexp2_bytes, 32);
    CHECK(fn_hmac_sha256_bytes_equal(pout2, pexp2, 32) == 1, "pbkdf2-hmac-sha256: iterations=4096 KAT matches");
}

/* Media (at-rest) encryption: the in-memory transform (encrypt !=
 * plaintext, decrypt reproduces plaintext) plus the real
 * dharafs_block_write/dharafs_block_read integration against the
 * host-harness's own in-memory "SD card" (host_virtual_disk_*,
 * block_dev==2 by default here) -- a safe, deterministic place to get
 * real ASAN/UBSAN coverage of the SAME encrypt-then-store/fetch-then-
 * decrypt path kernel_main.vani's own on-target self-check
 * deliberately does NOT exercise on every boot (see its own comment:
 * doing real SD I/O at boot was found, live, to intermittently
 * corrupt unrelated state minutes later -- a separate, pre-existing
 * bug, not a flaw in this transform). No such hazard exists in this
 * host process (no IRQs, no real SD controller), so this is the right
 * place to verify the real integration continuously. */
static void test_media_crypto(void) {
    int64_t *key = dharafs_crypto_key_ptr();
    for (int i = 0; i < 32; i++) buf_write_byte(key, (uint32_t)i, (uint32_t)(i * 3 + 1));

    int64_t *plaintext = dhruva_alloc_bytes(512);
    for (int i = 0; i < 512; i++) buf_write_byte(plaintext, (uint32_t)i, (uint32_t)((i * 7 + 11) & 255));

    int64_t *ciphertext = dhruva_alloc_bytes(512);
    fn_dharafs_crypto_transform_block(42, plaintext, ciphertext);
    CHECK(fn_chacha20_bytes_equal(ciphertext, plaintext, 512) == 0,
          "media-crypto: transform is not the identity (real encryption happened)");

    int64_t *decrypted = dhruva_alloc_bytes(512);
    fn_dharafs_crypto_transform_block(42, ciphertext, decrypted);
    CHECK(fn_chacha20_bytes_equal(decrypted, plaintext, 512) == 1,
          "media-crypto: in-memory transform round trip reproduces plaintext");

    /* Different block_num must derive a different nonce -- encrypting
     * the SAME plaintext at a different block must not produce the
     * same ciphertext (the whole point of a per-block nonce). */
    int64_t *ciphertext_other_block = dhruva_alloc_bytes(512);
    fn_dharafs_crypto_transform_block(43, plaintext, ciphertext_other_block);
    CHECK(fn_chacha20_bytes_equal(ciphertext, ciphertext_other_block, 512) == 0,
          "media-crypto: different block_num produces different ciphertext (per-block nonce)");

    /* Real dharafs_block_write/dharafs_block_read integration against
     * the host virtual disk -- proves the actual feature (not just
     * the transform in isolation) works end-to-end. */
    dharafs_crypto_set_enabled(1);
    int64_t wr = fn_dharafs_block_write(100, plaintext);
    CHECK(wr == 0, "media-crypto: dharafs_block_write with encryption enabled succeeds");

    int64_t *raw = dhruva_alloc_bytes(512);
    host_virtual_disk_read(100, raw);
    CHECK(fn_chacha20_bytes_equal(raw, plaintext, 512) == 0,
          "media-crypto: on-disk bytes differ from plaintext (real encryption at rest)");

    int64_t *readback = dhruva_alloc_bytes(512);
    int64_t rd = fn_dharafs_block_read(100, readback);
    CHECK(rd == 0, "media-crypto: dharafs_block_read with encryption enabled succeeds");
    CHECK(fn_chacha20_bytes_equal(readback, plaintext, 512) == 1,
          "media-crypto: dharafs_block_read decrypts back to the original plaintext");
    dharafs_crypto_set_enabled(0);

    /* Encryption OFF (the default) must be a byte-for-byte passthrough
     * -- the existing regression suite's own safety net. */
    int64_t wr2 = fn_dharafs_block_write(101, plaintext);
    CHECK(wr2 == 0, "media-crypto: dharafs_block_write with encryption disabled succeeds");
    int64_t *raw2 = dhruva_alloc_bytes(512);
    host_virtual_disk_read(101, raw2);
    CHECK(fn_chacha20_bytes_equal(raw2, plaintext, 512) == 1,
          "media-crypto: on-disk bytes match plaintext exactly when encryption is disabled");
}

/* Fault-injection framework completion (round 62): the "Nth call
 * fails" countdown logic itself (fault_write_maybe_inject/
 * fault_netdrop_maybe_inject) and the "take the armed burst size"
 * logic (fault_irqburst_take) -- the actual NEW code this round adds,
 * independent of the hardware-touching call sites (sdhost_write_block/
 * netif_send_frame/irq_dispatch) that aren't meaningful to exercise on
 * a host process. */
static void test_fault_injection(void) {
    /* Disarmed (0) is always a no-op. */
    fault_write_countdown_set(0);
    CHECK(fn_fault_write_maybe_inject() == 0, "fault-write: disarmed never injects");
    CHECK(fn_fault_write_maybe_inject() == 0, "fault-write: disarmed stays disarmed");

    /* Armed to 3: first two calls decrement without injecting, the
     * third injects and leaves it disarmed afterward. */
    fault_write_countdown_set(3);
    CHECK(fn_fault_write_maybe_inject() == 0, "fault-write: 1st of 3 does not inject");
    CHECK(fault_write_countdown_get() == 2, "fault-write: countdown decremented to 2");
    CHECK(fn_fault_write_maybe_inject() == 0, "fault-write: 2nd of 3 does not inject");
    CHECK(fn_fault_write_maybe_inject() == 1, "fault-write: 3rd of 3 injects");
    CHECK(fault_write_countdown_get() == 0, "fault-write: auto-disarmed after injecting");
    CHECK(fn_fault_write_maybe_inject() == 0, "fault-write: stays disarmed, no repeat injection");

    /* Same shape for netdrop -- a separate, independent countdown. */
    fault_netdrop_countdown_set(1);
    CHECK(fn_fault_netdrop_maybe_inject() == 1, "fault-netdrop: armed to 1 injects on the 1st call");
    CHECK(fault_netdrop_countdown_get() == 0, "fault-netdrop: auto-disarmed after injecting");

    /* irqburst: take() returns the armed value once, then clears it --
     * a "take", not a "peek". */
    fault_irqburst_countdown_set(0);
    CHECK(fn_fault_irqburst_take() == 0, "fault-irqburst: disarmed take() returns 0");
    fault_irqburst_countdown_set(50);
    CHECK(fn_fault_irqburst_take() == 50, "fault-irqburst: armed take() returns the burst size");
    CHECK(fault_irqburst_countdown_get() == 0, "fault-irqburst: self-disarms after being taken");
    CHECK(fn_fault_irqburst_take() == 0, "fault-irqburst: a second take() returns 0, not 50 again");
}

static void test_chacha20_boundaries(void) {
    int64_t *key = dhruva_alloc_bytes(32);
    int64_t *nonce = dhruva_alloc_bytes(12);
    int64_t *state_buf = dhruva_alloc_bytes(64);
    int64_t *working_buf = dhruva_alloc_bytes(64);
    int64_t *keystream_buf = dhruva_alloc_bytes(64);

    /* Zero-length message: must not touch keystream/out at all. */
    int64_t *in0 = dhruva_alloc_bytes(1);
    int64_t *out0 = dhruva_alloc_bytes(1);
    int64_t st0 = fn_chacha20_encrypt(key, nonce, 0, in0, 0, state_buf, working_buf, keystream_buf, out0);
    CHECK(st0 == 0, "chacha20: zero-length message handled cleanly");

    /* Exact block boundary (64 bytes) and one-past (65 bytes). */
    for (int64_t len = 63; len <= 65; len++) {
        int64_t *in = dhruva_alloc_bytes(len);
        int64_t *out = dhruva_alloc_bytes(len);
        for (int64_t i = 0; i < len; i++) buf_write_byte(in, (uint32_t)i, (uint32_t)(i & 0xff));
        int64_t st = fn_chacha20_encrypt(key, nonce, 0, in, len, state_buf, working_buf, keystream_buf, out);
        char desc[96];
        snprintf(desc, sizeof(desc), "chacha20: len=%lld encrypts without corruption at block boundary", (long long)len);
        CHECK(st == 0, desc);
        /* Round trip: decrypting the ciphertext with the same
         * keystream must recover the original plaintext exactly
         * (ChaCha20 is XOR-based, so encrypt == decrypt). */
        int64_t *roundtrip = dhruva_alloc_bytes(len);
        fn_chacha20_encrypt(key, nonce, 0, out, len, state_buf, working_buf, keystream_buf, roundtrip);
        char desc2[96];
        snprintf(desc2, sizeof(desc2), "chacha20: len=%lld round-trips back to plaintext", (long long)len);
        CHECK(memcmp(in, roundtrip, (size_t)len) == 0, desc2);
    }
}

static void test_poly1305(void) {
    static const unsigned char key_bytes[32] = {
        0x85,0xd6,0xbe,0x78,0x57,0x55,0x6d,0x33,0x7f,0x44,0x52,0xfe,0x42,0xd5,0x06,0xa8,
        0x01,0x03,0x80,0x8a,0xfb,0x0d,0xb2,0xfd,0x4a,0xbf,0xf6,0xaf,0x41,0x49,0xf5,0x1b,
    };
    static const unsigned char expected_tag[16] = {
        0xa8,0x06,0x1d,0xc1,0x30,0x51,0x36,0xc6,0xc2,0x2b,0x8b,0xaf,0x0c,0x01,0x27,0xa9,
    };
    const char *msg_text = "Cryptographic Forum Research Group";
    int64_t msg_len = (int64_t)strlen(msg_text);

    int64_t *key = mkbuf((const char *)key_bytes, 32);
    int64_t *msg = mkbuf(msg_text, msg_len);
    int64_t *block_scratch = dhruva_alloc_bytes(16);
    int64_t *tag = dhruva_alloc_bytes(16);

    fn_poly1305_mac(key, msg, msg_len, block_scratch, tag);
    CHECK(memcmp(tag, expected_tag, 16) == 0, "poly1305: RFC 8439 section 2.5.2 KAT matches byte-exact");
    CHECK(fn_poly1305_verify_constant_time(tag, (int64_t *)expected_tag, 16) == 1, "poly1305: verify accepts the correct tag");

    /* Empty message: mac must equal s (key[16..32)) exactly. */
    int64_t *empty_tag = dhruva_alloc_bytes(16);
    fn_poly1305_mac(key, msg, 0, block_scratch, empty_tag);
    unsigned char s_bytes[16];
    memcpy(s_bytes, key_bytes + 16, 16);
    CHECK(memcmp(empty_tag, s_bytes, 16) == 0, "poly1305: empty message -> mac == s exactly");

    /* A single flipped bit anywhere in the message must change the tag. */
    int64_t *msg2 = mkbuf(msg_text, msg_len);
    buf_write_byte(msg2, 0, buf_read_byte(msg2, 0) ^ 1);
    int64_t *tag2 = dhruva_alloc_bytes(16);
    fn_poly1305_mac(key, msg2, msg_len, block_scratch, tag2);
    CHECK(memcmp(tag, tag2, 16) != 0, "poly1305: a single flipped message bit changes the tag");
    CHECK(fn_poly1305_verify_constant_time(tag, tag2, 16) == 0, "poly1305: verify correctly rejects a mismatched tag");

    /* A single flipped bit in the KEY must also change the tag
     * (nothing about r/s clamping should make the tag key-independent). */
    unsigned char key2_bytes[32];
    memcpy(key2_bytes, key_bytes, 32);
    key2_bytes[31] ^= 1;
    int64_t *key2 = mkbuf((const char *)key2_bytes, 32);
    int64_t *tag3 = dhruva_alloc_bytes(16);
    fn_poly1305_mac(key2, msg, msg_len, block_scratch, tag3);
    CHECK(memcmp(tag, tag3, 16) != 0, "poly1305: a single flipped key bit changes the tag");

    /* Length boundaries around the 16-byte block size -- exact
     * multiples (0, 16, 32) never touch the partial-block/leftover
     * path at all; 15/17/33 do. Just checking these don't crash and
     * produce a real, non-degenerate 16-byte tag (a full independent
     * KAT for each length isn't warranted -- the RFC vector above
     * already validates the core multiply-reduce math; this is purely
     * about the block-boundary bookkeeping). */
    for (int64_t len = 0; len <= 33; len++) {
        int64_t *m = dhruva_alloc_bytes(len > 0 ? len : 1);
        for (int64_t i = 0; i < len; i++) buf_write_byte(m, (uint32_t)i, (uint32_t)((i * 31) & 0xff));
        int64_t *t = dhruva_alloc_bytes(16);
        int64_t st = fn_poly1305_mac(key, m, len, block_scratch, t);
        char desc[80];
        snprintf(desc, sizeof(desc), "poly1305: len=%lld handled cleanly (no crash)", (long long)len);
        CHECK(st == 0, desc);
    }

    /* Two different messages of the exact same length must (almost
     * certainly) produce different tags -- a degenerate implementation
     * that e.g. only looked at message length would pass every check
     * above but fail this one. */
    int64_t *m32a = dhruva_alloc_bytes(32);
    int64_t *m32b = dhruva_alloc_bytes(32);
    for (int64_t i = 0; i < 32; i++) { buf_write_byte(m32a, (uint32_t)i, 0xAA); buf_write_byte(m32b, (uint32_t)i, 0x55); }
    int64_t *ta = dhruva_alloc_bytes(16);
    int64_t *tb = dhruva_alloc_bytes(16);
    fn_poly1305_mac(key, m32a, 32, block_scratch, ta);
    fn_poly1305_mac(key, m32b, 32, block_scratch, tb);
    CHECK(memcmp(ta, tb, 16) != 0, "poly1305: two different same-length messages produce different tags");
}

static void x25519_init_scratch(void) {
    x25519_x1_set(dhruva_alloc_bytes(32));
    x25519_x2_set(dhruva_alloc_bytes(32));
    x25519_z2_set(dhruva_alloc_bytes(32));
    x25519_x3_set(dhruva_alloc_bytes(32));
    x25519_z3_set(dhruva_alloc_bytes(32));
    x25519_a_set(dhruva_alloc_bytes(32));
    x25519_aa_set(dhruva_alloc_bytes(32));
    x25519_b_set(dhruva_alloc_bytes(32));
    x25519_bb_set(dhruva_alloc_bytes(32));
    x25519_e_set(dhruva_alloc_bytes(32));
    x25519_c_set(dhruva_alloc_bytes(32));
    x25519_d_set(dhruva_alloc_bytes(32));
    x25519_da_set(dhruva_alloc_bytes(32));
    x25519_cb_set(dhruva_alloc_bytes(32));
    x25519_a24e_set(dhruva_alloc_bytes(32));
    x25519_product_scratch_set(dhruva_alloc_bytes(64));
    x25519_invert_base_set(dhruva_alloc_bytes(32));
    x25519_invert_result_set(dhruva_alloc_bytes(32));
    x25519_p_bytes_set(dhruva_alloc_bytes(32));
    x25519_p_minus_2_bytes_set(dhruva_alloc_bytes(32));
    x25519_p9_bytes_set(dhruva_alloc_bytes(36));
    x25519_fold_t_set(dhruva_alloc_bytes(36));
    x25519_fold_s_set(dhruva_alloc_bytes(36));
    x25519_a24_bytes_set(dhruva_alloc_bytes(32));
    fn_field25519_init();
}

static void test_x25519(void) {
    x25519_init_scratch();

    static const unsigned char k1_bytes[32] = {0x60, 0xb7, 0xb2, 0xc0, 0xd9, 0x51, 0x1c, 0xbd, 0x53, 0x2b, 0xda, 0xdd, 0xdf, 0xd5, 0xb5, 0xa8, 0x5d, 0x0b, 0x49, 0xab, 0x55, 0x03, 0x9f, 0xd3, 0x21, 0xba, 0x87, 0xda, 0xe8, 0x63, 0x8e, 0x4c};
    static const unsigned char expected1_bytes[32] = {0xe0, 0x7a, 0xe4, 0x20, 0x24, 0x0d, 0x20, 0xa2, 0x7d, 0xf3, 0xc1, 0x96, 0xf7, 0x3b, 0x54, 0xb6, 0x43, 0x58, 0xbd, 0x16, 0x19, 0x9f, 0x97, 0x76, 0x26, 0x26, 0x82, 0x42, 0x05, 0xe1, 0x7f, 0x69};
    static const unsigned char u2_bytes[32] = {0x20, 0xc9, 0xb8, 0x13, 0x92, 0xa4, 0x6b, 0x37, 0xd9, 0xa5, 0xd5, 0xc1, 0xf5, 0x73, 0x7c, 0xca, 0x4f, 0xc9, 0x71, 0x21, 0x89, 0xc0, 0xf1, 0x84, 0x23, 0x35, 0xec, 0x89, 0xbd, 0xeb, 0xca, 0x0d};
    static const unsigned char expected2_bytes[32] = {0x12, 0x8e, 0x3d, 0x71, 0x61, 0x9e, 0x52, 0x72, 0x04, 0x99, 0x1f, 0x8a, 0x5c, 0x80, 0x68, 0x2d, 0x74, 0xea, 0xa2, 0xda, 0x8a, 0xde, 0x5c, 0xcc, 0xaa, 0xdb, 0x7a, 0xfa, 0xc3, 0xcc, 0xc6, 0x66};
    unsigned char basepoint_bytes[32] = {9};

    /* Test 1: base-point scalar mult (public key derivation), against
     * a real, independently-verified (cryptography library) result --
     * see kernel_main.vani's own header comment for the full
     * verification chain this value came from. */
    int64_t *k1 = mkbuf((const char *)k1_bytes, 32);
    int64_t *basepoint = mkbuf((const char *)basepoint_bytes, 32);
    int64_t *out1 = dhruva_alloc_bytes(32);
    fn_x25519_scalarmult(k1, basepoint, out1);
    CHECK(memcmp(out1, expected1_bytes, 32) == 0, "x25519: base-point mult matches independently-verified reference");

    /* Test 2: arbitrary u-coordinate mult (DH agreement step), same
     * verified source. */
    int64_t *k1b = mkbuf((const char *)k1_bytes, 32); /* fresh copy -- x25519_scalarmult clamps k in place */
    int64_t *u2 = mkbuf((const char *)u2_bytes, 32);
    int64_t *out2 = dhruva_alloc_bytes(32);
    fn_x25519_scalarmult(k1b, u2, out2);
    CHECK(memcmp(out2, expected2_bytes, 32) == 0, "x25519: DH agreement matches independently-verified reference");

    /* DH symmetry, using ONLY this implementation on both sides --
     * the actual mathematical property ECDHE depends on: A(a, B_pub)
     * == A(b, A_pub) where A_pub = A(a, basepoint), B_pub = A(b, basepoint). */
    unsigned char a_priv[32], b_priv[32];
    for (int i = 0; i < 32; i++) { a_priv[i] = (unsigned char)(i * 7 + 3); b_priv[i] = (unsigned char)(i * 13 + 11); }

    int64_t *a_priv_buf = mkbuf((const char *)a_priv, 32);
    int64_t *bp1 = mkbuf((const char *)basepoint_bytes, 32);
    int64_t *a_pub = dhruva_alloc_bytes(32);
    fn_x25519_scalarmult(a_priv_buf, bp1, a_pub);

    int64_t *b_priv_buf = mkbuf((const char *)b_priv, 32);
    int64_t *bp2 = mkbuf((const char *)basepoint_bytes, 32);
    int64_t *b_pub = dhruva_alloc_bytes(32);
    fn_x25519_scalarmult(b_priv_buf, bp2, b_pub);

    int64_t *a_priv_buf2 = mkbuf((const char *)a_priv, 32);
    int64_t *shared_ab = dhruva_alloc_bytes(32);
    fn_x25519_scalarmult(a_priv_buf2, b_pub, shared_ab);

    int64_t *b_priv_buf2 = mkbuf((const char *)b_priv, 32);
    int64_t *shared_ba = dhruva_alloc_bytes(32);
    fn_x25519_scalarmult(b_priv_buf2, a_pub, shared_ba);

    CHECK(memcmp(shared_ab, shared_ba, 32) == 0, "x25519: DH agreement is symmetric (A(a,B_pub) == A(b,A_pub))");

    /* A degenerate "ignores its input" implementation would still
     * pass every check above by coincidence if shared_ab/shared_ba
     * both happened to be some constant -- rule that out explicitly:
     * a different key pair must produce a DIFFERENT shared secret. */
    unsigned char c_priv[32];
    for (int i = 0; i < 32; i++) c_priv[i] = (unsigned char)(i * 5 + 17);
    int64_t *c_priv_buf = mkbuf((const char *)c_priv, 32);
    int64_t *shared_ac = dhruva_alloc_bytes(32);
    fn_x25519_scalarmult(c_priv_buf, a_pub, shared_ac);
    CHECK(memcmp(shared_ab, shared_ac, 32) != 0, "x25519: a different private key produces a different shared secret");

    /* field25519 arithmetic unit checks, independent of the full ladder. */
    unsigned char one_bytes[32] = {1};
    unsigned char zero_bytes[32] = {0};
    int64_t *one = mkbuf((const char *)one_bytes, 32);
    int64_t *zero = mkbuf((const char *)zero_bytes, 32);
    int64_t *sum = dhruva_alloc_bytes(32);
    fn_field25519_add(one, zero, sum);
    CHECK(memcmp(sum, one_bytes, 32) == 0, "field25519: 1 + 0 == 1");

    int64_t *inv_one = dhruva_alloc_bytes(32);
    fn_field25519_invert(one, inv_one);
    CHECK(memcmp(inv_one, one_bytes, 32) == 0, "field25519: 1^-1 == 1");

    /* a * a^-1 == 1 for a real (non-trivial) value -- the actual
     * property field25519_invert exists for. */
    unsigned char five_bytes[32] = {5};
    int64_t *five = mkbuf((const char *)five_bytes, 32);
    int64_t *five_inv = dhruva_alloc_bytes(32);
    fn_field25519_invert(five, five_inv);
    int64_t *should_be_one = dhruva_alloc_bytes(32);
    fn_field25519_mul(five, five_inv, should_be_one);
    CHECK(memcmp(should_be_one, one_bytes, 32) == 0, "field25519: 5 * 5^-1 == 1");
}

int64_t fn_sha512_hash(int64_t *msg, int64_t msg_len, int64_t *out);
int64_t fn_sha512_bytes_equal(int64_t *a, int64_t *b, int64_t n);
int64_t sha512_h_scratch_set(int64_t *addr);
int64_t sha512_k_scratch_set(int64_t *addr);
int64_t sha512_w_scratch_set(int64_t *addr);
int64_t sha512_padded_scratch_set(int64_t *addr);
int64_t fn_sha512_k_init(int64_t *k);

static void sha512_init_scratch(void) {
    sha512_h_scratch_set(dhruva_alloc_bytes(64));
    int64_t *k = dhruva_alloc_bytes(640);
    sha512_k_scratch_set(k);
    sha512_w_scratch_set(dhruva_alloc_bytes(640));
    sha512_padded_scratch_set(dhruva_alloc_bytes(4224));
    fn_sha512_k_init(k);
}

static void test_sha512_boundaries(void) {
    sha512_init_scratch();

    static const unsigned char expect_empty[64] = {0xcf, 0x83, 0xe1, 0x35, 0x7e, 0xef, 0xb8, 0xbd, 0xf1, 0x54, 0x28, 0x50, 0xd6, 0x6d, 0x80, 0x07, 0xd6, 0x20, 0xe4, 0x05, 0x0b, 0x57, 0x15, 0xdc, 0x83, 0xf4, 0xa9, 0x21, 0xd3, 0x6c, 0xe9, 0xce, 0x47, 0xd0, 0xd1, 0x3c, 0x5d, 0x85, 0xf2, 0xb0, 0xff, 0x83, 0x18, 0xd2, 0x87, 0x7e, 0xec, 0x2f, 0x63, 0xb9, 0x31, 0xbd, 0x47, 0x41, 0x7a, 0x81, 0xa5, 0x38, 0x32, 0x7a, 0xf9, 0x27, 0xda, 0x3e};
    int64_t *msg0 = dhruva_alloc_bytes(1);
    int64_t *out0 = dhruva_alloc_bytes(64);
    fn_sha512_hash(msg0, 0, out0);
    int64_t *exp0 = mkbuf((const char *)expect_empty, 64);
    CHECK(fn_sha512_bytes_equal(out0, exp0, 64) == 1, "sha512: empty-string vector matches hashlib.sha512");

    static const unsigned char expect_abc[64] = {0xdd, 0xaf, 0x35, 0xa1, 0x93, 0x61, 0x7a, 0xba, 0xcc, 0x41, 0x73, 0x49, 0xae, 0x20, 0x41, 0x31, 0x12, 0xe6, 0xfa, 0x4e, 0x89, 0xa9, 0x7e, 0xa2, 0x0a, 0x9e, 0xee, 0xe6, 0x4b, 0x55, 0xd3, 0x9a, 0x21, 0x92, 0x99, 0x2a, 0x27, 0x4f, 0xc1, 0xa8, 0x36, 0xba, 0x3c, 0x23, 0xa3, 0xfe, 0xeb, 0xbd, 0x45, 0x4d, 0x44, 0x23, 0x64, 0x3c, 0xe8, 0x0e, 0x2a, 0x9a, 0xc9, 0x4f, 0xa5, 0x4c, 0xa4, 0x9f};
    int64_t *msg1 = mkbuf("abc", 3);
    int64_t *out1 = dhruva_alloc_bytes(64);
    fn_sha512_hash(msg1, 3, out1);
    int64_t *exp1 = mkbuf((const char *)expect_abc, 64);
    CHECK(fn_sha512_bytes_equal(out1, exp1, 64) == 1, "sha512: \"abc\" vector matches hashlib.sha512");

    /* Message length sweep around the 111/112/128 padding boundaries
     * (SHA-512's own 128-byte block, 112-byte pad threshold, 16-byte
     * length trailer -- different constants from SHA-256's 64/56/8,
     * so this is a genuinely separate boundary to check, not a copy
     * of the SHA-256 sweep). */
    for (int64_t len = 108; len <= 130; len++) {
        int64_t *msg = dhruva_alloc_bytes(len > 0 ? len : 1);
        for (int64_t i = 0; i < len; i++) buf_write_byte(msg, (uint32_t)i, (uint32_t)('a' + (i % 26)));
        int64_t *out = dhruva_alloc_bytes(64);
        int64_t st = fn_sha512_hash(msg, len, out);
        char desc[80];
        snprintf(desc, sizeof(desc), "sha512: len=%lld does not crash/corrupt (padding boundary)", (long long)len);
        CHECK(st == 0, desc);
    }

    /* Cross-check every boundary-sweep length against hashlib
     * directly, not just "didn't crash" -- computed here at C-compile
     * time is not possible, so instead spot-check 3 representative
     * lengths (111, 112, 128) against fixed, hashlib-derived vectors,
     * same discipline as kernel_main.vani's own sha512_self_test. */

    {
        static const unsigned char expect_111[64] = {0xa4, 0x67, 0x69, 0x80, 0x69, 0xea, 0xe8, 0xed, 0x1e, 0x0c, 0x6d, 0xbf, 0xd1, 0xb4, 0xa2, 0x47, 0xa9, 0xf1, 0xe7, 0xff, 0x4e, 0x3a, 0xf6, 0x21, 0x45, 0xed, 0x26, 0xf4, 0x46, 0x8b, 0xc0, 0x94, 0x61, 0x08, 0x78, 0xb7, 0x64, 0x40, 0x91, 0x14, 0x13, 0x70, 0xa4, 0x7a, 0x76, 0x38, 0xbd, 0xdc, 0x95, 0xdb, 0xfe, 0x89, 0x71, 0xc3, 0x4d, 0x13, 0xc4, 0x81, 0x5d, 0x4b, 0xb1, 0xb3, 0xe7, 0xf2};
        int64_t *msg = dhruva_alloc_bytes(111);
        for (int64_t i = 0; i < 111; i++) buf_write_byte(msg, (uint32_t)i, (uint32_t)('a' + (i % 26)));
        int64_t *out = dhruva_alloc_bytes(64);
        fn_sha512_hash(msg, 111, out);
        int64_t *exp = mkbuf((const char *)expect_111, 64);
        CHECK(fn_sha512_bytes_equal(out, exp, 64) == 1, "sha512: len=111 byte-exact match vs hashlib.sha512");
    }
    {
        static const unsigned char expect_112[64] = {0xa4, 0x73, 0xc9, 0x37, 0x32, 0xee, 0xf6, 0x27, 0xd0, 0x2e, 0x86, 0xd1, 0x90, 0x47, 0xa4, 0x22, 0xb5, 0x86, 0x11, 0x08, 0x48, 0xec, 0x17, 0xdc, 0xea, 0x13, 0xaf, 0x28, 0x2a, 0x15, 0x2f, 0x76, 0x54, 0xb0, 0xc7, 0x11, 0xe2, 0x77, 0xfd, 0x42, 0xc1, 0xd9, 0x4b, 0xea, 0x8b, 0x7f, 0xed, 0x61, 0x5c, 0x52, 0xbb, 0x0f, 0x84, 0x92, 0x27, 0xe1, 0x62, 0x40, 0xaf, 0xff, 0xc7, 0xc5, 0x6e, 0x29};
        int64_t *msg = dhruva_alloc_bytes(112);
        for (int64_t i = 0; i < 112; i++) buf_write_byte(msg, (uint32_t)i, (uint32_t)('a' + (i % 26)));
        int64_t *out = dhruva_alloc_bytes(64);
        fn_sha512_hash(msg, 112, out);
        int64_t *exp = mkbuf((const char *)expect_112, 64);
        CHECK(fn_sha512_bytes_equal(out, exp, 64) == 1, "sha512: len=112 byte-exact match vs hashlib.sha512");
    }
    {
        static const unsigned char expect_128[64] = {0x21, 0x7d, 0x3d, 0x9c, 0x09, 0x52, 0xc3, 0xe4, 0x90, 0x7f, 0x06, 0xd4, 0xfb, 0xf3, 0x44, 0x60, 0xee, 0x85, 0x2c, 0x6a, 0xf5, 0x91, 0xb0, 0x7c, 0x2f, 0xa1, 0xc5, 0xe1, 0x64, 0x55, 0x83, 0x63, 0x74, 0xc9, 0x5a, 0xe3, 0x3e, 0x18, 0x42, 0x27, 0x91, 0x3f, 0x8a, 0x2e, 0x22, 0x7e, 0x3b, 0xbd, 0x51, 0x87, 0xce, 0x57, 0xaa, 0x1b, 0xad, 0x11, 0xa8, 0x0f, 0x62, 0x24, 0x12, 0xeb, 0x08, 0x84};
        int64_t *msg = dhruva_alloc_bytes(128);
        for (int64_t i = 0; i < 128; i++) buf_write_byte(msg, (uint32_t)i, (uint32_t)('a' + (i % 26)));
        int64_t *out = dhruva_alloc_bytes(64);
        fn_sha512_hash(msg, 128, out);
        int64_t *exp = mkbuf((const char *)expect_128, 64);
        CHECK(fn_sha512_bytes_equal(out, exp, 64) == 1, "sha512: len=128 byte-exact match vs hashlib.sha512");
    }
}

static void test_bignum_boundaries(void) {
    /* Multiply by zero. */
    int64_t *a = dhruva_alloc_bytes(16);
    int64_t *zero = dhruva_alloc_bytes(16);
    int64_t *prod = dhruva_alloc_bytes(32);
    fn_bignum_set_limbs4(a, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff);
    fn_bignum_set_limbs4(zero, 0, 0, 0, 0);
    fn_bignum_mul_raw(a, zero, prod, 4);
    int64_t *expect_zero8 = dhruva_alloc_bytes(32);
    CHECK(fn_bignum_limbs_equal(prod, expect_zero8, 8) == 1, "bignum: max_value * 0 == 0 (8 limbs)");

    /* Borrow-on-subtract: 0 - 1 must wrap to all-0xff and report a borrow. */
    int64_t *one = dhruva_alloc_bytes(16);
    fn_bignum_set_limbs4(one, 1, 0, 0, 0);
    int64_t *diff = dhruva_alloc_bytes(16);
    uint32_t borrow = fn_bignum_sub_raw(zero, one, diff, 4);
    CHECK(borrow == 1, "bignum: 0 - 1 reports a borrow");
    int64_t *expect_allff = dhruva_alloc_bytes(16);
    fn_bignum_set_limbs4(expect_allff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff);
    CHECK(fn_bignum_limbs_equal(diff, expect_allff, 4) == 1, "bignum: 0 - 1 wraps to 0xff...ff");

    /* Carry-on-add: max_value + 1 must wrap to 0 and report a carry. */
    int64_t *sum = dhruva_alloc_bytes(16);
    uint32_t carry = fn_bignum_add_raw(a, one, sum, 4);
    CHECK(carry == 1, "bignum: max_value + 1 reports a carry");
    int64_t *expect_zero4 = dhruva_alloc_bytes(16);
    CHECK(fn_bignum_limbs_equal(sum, expect_zero4, 4) == 1, "bignum: max_value + 1 wraps to 0");

    /* Comparison boundary. */
    CHECK(fn_bignum_cmp_raw(a, one, 4) == 1, "bignum: max_value > 1");
    CHECK(fn_bignum_cmp_raw(one, a, 4) == -1, "bignum: 1 < max_value");
    CHECK(fn_bignum_cmp_raw(a, a, 4) == 0, "bignum: a == a");
}

/* Round 56: LAN9512 TX/RX wire-framing math, checked against hand-
 * computed byte layouts from smsc95xx.h's own register/bit
 * definitions -- the part of the real LAN9512 backend that doesn't
 * need actual chip I/O to verify (see lan9512_build_tx_header's own
 * comment in kernel_main.vani for why the register-init sequence
 * itself can't be covered here or under QEMU). */
static void test_lan9512_framing(void) {
    /* TX_CMD_A = frame_len | FIRST_SEG_(0x2000) | LAST_SEG_(0x1000);
     * TX_CMD_B = frame_len. Both little-endian 32-bit words. */
    int64_t *hdr = dhruva_alloc_bytes(8);
    fn_lan9512_build_tx_header(hdr, 64);
    CHECK(buf_read_byte(hdr, 0) == 0x40, "lan9512 tx header: TX_CMD_A byte0");
    CHECK(buf_read_byte(hdr, 1) == 0x30, "lan9512 tx header: TX_CMD_A byte1 (FIRST_SEG_|LAST_SEG_|len)");
    CHECK(buf_read_byte(hdr, 2) == 0x00, "lan9512 tx header: TX_CMD_A byte2");
    CHECK(buf_read_byte(hdr, 3) == 0x00, "lan9512 tx header: TX_CMD_A byte3");
    CHECK(buf_read_byte(hdr, 4) == 0x40, "lan9512 tx header: TX_CMD_B byte0 (== frame_len)");
    CHECK(buf_read_byte(hdr, 5) == 0x00, "lan9512 tx header: TX_CMD_B byte1");
    CHECK(buf_read_byte(hdr, 6) == 0x00, "lan9512 tx header: TX_CMD_B byte2");
    CHECK(buf_read_byte(hdr, 7) == 0x00, "lan9512 tx header: TX_CMD_B byte3");

    /* A larger, non-power-of-two length exercises more than just the
     * low byte -- 590 = 0x24E, matching this project's own real
     * live-captured DHCPOFFER frame size (see docs/TODO.md's own note
     * on the pre-existing 512-byte netif cap this same frame exposed). */
    int64_t *hdr2 = dhruva_alloc_bytes(8);
    fn_lan9512_build_tx_header(hdr2, 590);
    uint32_t cmd_a = (uint32_t)buf_read_byte(hdr2, 0) | ((uint32_t)buf_read_byte(hdr2, 1) << 8) |
                     ((uint32_t)buf_read_byte(hdr2, 2) << 16) | ((uint32_t)buf_read_byte(hdr2, 3) << 24);
    uint32_t cmd_b = (uint32_t)buf_read_byte(hdr2, 4) | ((uint32_t)buf_read_byte(hdr2, 5) << 8) |
                     ((uint32_t)buf_read_byte(hdr2, 6) << 16) | ((uint32_t)buf_read_byte(hdr2, 7) << 24);
    CHECK(cmd_a == (590u | 0x2000u | 0x1000u), "lan9512 tx header: TX_CMD_A for a 590-byte frame");
    CHECK(cmd_b == 590u, "lan9512 tx header: TX_CMD_B for a 590-byte frame");

    /* RX_STS_ES_ (error summary, bit 15) gates whether a received
     * frame is trusted at all. */
    CHECK(fn_lan9512_rx_status_has_error(0x00008000) == 1, "lan9512 rx status: RX_STS_ES_ set is detected");
    CHECK(fn_lan9512_rx_status_has_error(0x00000000) == 0, "lan9512 rx status: no error bits is clean");
    CHECK(fn_lan9512_rx_status_has_error(0xFFFF7FFFu) == 0, "lan9512 rx status: every OTHER bit set, ES_ clear, still clean");

    /* RX_STS_FL_ (frame length, bits 29:16) -- a real 590-byte frame's
     * status word, plus other real status bits (RX_STS_BF_=broadcast,
     * RX_STS_CRC_) that must NOT leak into the extracted length. */
    uint32_t rx_status_590 = (590u << 16) | 0x00002000u | 0x00000002u;
    CHECK(fn_lan9512_rx_status_frame_len(rx_status_590) == 590u, "lan9512 rx status: 590-byte length extracted correctly, unaffected by other bits");
    /* Max representable 14-bit length (0x3FFF). */
    CHECK(fn_lan9512_rx_status_frame_len(0x3FFF0000u) == 0x3FFFu, "lan9512 rx status: max 14-bit length field (0x3FFF)");
    CHECK(fn_lan9512_rx_status_frame_len(0x00000000u) == 0u, "lan9512 rx status: zero length");
}

/* Round 57: HCI command/event packet building/parsing, checked against
 * hand-computed byte layouts from the Bluetooth Core Specification's
 * own field definitions -- the part of the USB Bluetooth HCI backend
 * that doesn't need actual hardware to verify (see hci_reset_and_
 * scan's own comment in kernel_main.vani for why the transport itself
 * can't be covered here or under QEMU). */
static void test_hci_framing(void) {
    /* Opcode = (OGF << 10) | OCF. */
    CHECK(fn_hci_build_opcode(0x03, 0x0003) == 0x0C03, "hci opcode: HCI_Reset (OGF=0x03,OCF=0x0003) == 0x0C03");
    CHECK(fn_hci_build_opcode(0x08, 0x000B) == 0x200B, "hci opcode: LE_Set_Scan_Parameters (OGF=0x08,OCF=0x000B) == 0x200B");
    CHECK(fn_hci_build_opcode(0x08, 0x000C) == 0x200C, "hci opcode: LE_Set_Scan_Enable (OGF=0x08,OCF=0x000C) == 0x200C");

    /* Generic command builder: opcode LE, param length, params verbatim. */
    int64_t *params = dhruva_alloc_bytes(3);
    buf_write_byte(params, 0, 0xAA);
    buf_write_byte(params, 1, 0xBB);
    buf_write_byte(params, 2, 0xCC);
    int64_t *cmd = dhruva_alloc_bytes(6);
    int64_t cmd_len = fn_hci_build_command(cmd, 0x1234, params, 3);
    CHECK(cmd_len == 6, "hci build_command: total length == 3 (header) + 3 (params)");
    CHECK(buf_read_byte(cmd, 0) == 0x34, "hci build_command: opcode LE byte0");
    CHECK(buf_read_byte(cmd, 1) == 0x12, "hci build_command: opcode LE byte1");
    CHECK(buf_read_byte(cmd, 2) == 0x03, "hci build_command: param length byte");
    CHECK(buf_read_byte(cmd, 3) == 0xAA, "hci build_command: param 0 verbatim");
    CHECK(buf_read_byte(cmd, 4) == 0xBB, "hci build_command: param 1 verbatim");
    CHECK(buf_read_byte(cmd, 5) == 0xCC, "hci build_command: param 2 verbatim");

    /* HCI_Reset: opcode 0x0C03, no params. */
    int64_t *reset_cmd = dhruva_alloc_bytes(3);
    int64_t reset_len = fn_hci_build_reset_command(reset_cmd);
    CHECK(reset_len == 3, "hci reset: total length == 3 (no params)");
    CHECK(buf_read_byte(reset_cmd, 0) == 0x03, "hci reset: opcode LE byte0");
    CHECK(buf_read_byte(reset_cmd, 1) == 0x0C, "hci reset: opcode LE byte1");
    CHECK(buf_read_byte(reset_cmd, 2) == 0x00, "hci reset: param length == 0");

    /* LE_Set_Scan_Parameters: opcode 0x200B, 7 params. */
    int64_t *scan_params_cmd = dhruva_alloc_bytes(10);
    int64_t scan_params_len = fn_hci_build_le_set_scan_parameters_command(scan_params_cmd, 0x00, 0x0010, 0x0010, 0x00, 0x00);
    CHECK(scan_params_len == 10, "hci scan params: total length == 3 (header) + 7 (params)");
    CHECK(buf_read_byte(scan_params_cmd, 0) == 0x0B, "hci scan params: opcode LE byte0");
    CHECK(buf_read_byte(scan_params_cmd, 1) == 0x20, "hci scan params: opcode LE byte1");
    CHECK(buf_read_byte(scan_params_cmd, 2) == 0x07, "hci scan params: param length == 7");
    CHECK(buf_read_byte(scan_params_cmd, 3) == 0x00, "hci scan params: scan_type");
    CHECK(buf_read_byte(scan_params_cmd, 4) == 0x10, "hci scan params: interval LE byte0");
    CHECK(buf_read_byte(scan_params_cmd, 5) == 0x00, "hci scan params: interval LE byte1");
    CHECK(buf_read_byte(scan_params_cmd, 6) == 0x10, "hci scan params: window LE byte0");
    CHECK(buf_read_byte(scan_params_cmd, 7) == 0x00, "hci scan params: window LE byte1");
    CHECK(buf_read_byte(scan_params_cmd, 8) == 0x00, "hci scan params: own_addr_type");
    CHECK(buf_read_byte(scan_params_cmd, 9) == 0x00, "hci scan params: filter_policy");

    /* LE_Set_Scan_Enable: opcode 0x200C, 2 params. */
    int64_t *scan_enable_cmd = dhruva_alloc_bytes(5);
    int64_t scan_enable_len = fn_hci_build_le_set_scan_enable_command(scan_enable_cmd, 1, 0);
    CHECK(scan_enable_len == 5, "hci scan enable: total length == 3 (header) + 2 (params)");
    CHECK(buf_read_byte(scan_enable_cmd, 0) == 0x0C, "hci scan enable: opcode LE byte0");
    CHECK(buf_read_byte(scan_enable_cmd, 1) == 0x20, "hci scan enable: opcode LE byte1");
    CHECK(buf_read_byte(scan_enable_cmd, 2) == 0x02, "hci scan enable: param length == 2");
    CHECK(buf_read_byte(scan_enable_cmd, 3) == 0x01, "hci scan enable: scan_enable");
    CHECK(buf_read_byte(scan_enable_cmd, 4) == 0x00, "hci scan enable: filter_duplicates");

    /* Event parsing: event_code (byte0), param_len (byte1). */
    int64_t *disc_event = dhruva_alloc_bytes(2);
    buf_write_byte(disc_event, 0, 0x05); /* Disconnection Complete */
    buf_write_byte(disc_event, 1, 0x04);
    CHECK(fn_hci_event_code(disc_event) == 0x05, "hci event: event_code extracted correctly");
    CHECK(fn_hci_event_param_len(disc_event) == 0x04, "hci event: param_len extracted correctly");
    CHECK(fn_hci_event_is_command_complete(disc_event) == 0, "hci event: Disconnection Complete is not Command Complete");

    /* A real Command Complete event for HCI_Reset: event_code=0x0E,
     * param_len=4, num_hci_command_packets=1, opcode=0x0C03 (LE),
     * status=0x00. */
    int64_t *cc_event = dhruva_alloc_bytes(6);
    buf_write_byte(cc_event, 0, 0x0E);
    buf_write_byte(cc_event, 1, 0x04);
    buf_write_byte(cc_event, 2, 0x01);
    buf_write_byte(cc_event, 3, 0x03);
    buf_write_byte(cc_event, 4, 0x0C);
    buf_write_byte(cc_event, 5, 0x00);
    CHECK(fn_hci_event_is_command_complete(cc_event) == 1, "hci event: Command Complete recognized");
    CHECK(fn_hci_cmd_complete_opcode(cc_event) == 0x0C03, "hci event: Command Complete opcode extracted (matches HCI_Reset)");
    CHECK(fn_hci_cmd_complete_status(cc_event) == 0x00, "hci event: Command Complete status == success");
}

/* Round 66: connection establishment + HCI ACL/L2CAP/ATT framing --
 * the layers above HCI transport docs/TODO.md's own BLE entry called
 * "not started". */
static void test_ble_connection_and_att(void) {
    /* 16-bit LE helpers, added this round. */
    int64_t *le16 = dhruva_alloc_bytes(2);
    fn_buf_write_u16_le(le16, 0, 0xBEEF);
    CHECK(buf_read_byte(le16, 0) == 0xEF, "u16_le: low byte first");
    CHECK(buf_read_byte(le16, 1) == 0xBE, "u16_le: high byte second");
    CHECK(fn_buf_read_u16_le(le16, 0) == 0xBEEF, "u16_le: round trip");

    /* LE_Create_Connection: opcode 0x200D, 25 params. */
    int64_t *peer_addr = mkbuf("\x01\x02\x03\x04\x05\x06", 6);
    int64_t *cc_cmd = dhruva_alloc_bytes(28);
    int64_t cc_cmd_len = fn_hci_build_le_create_connection_command(cc_cmd, 0x0010, 0x0010, 0x00, 0x00, peer_addr, 0x00, 0x0018, 0x0028, 0x0000, 0x01F4);
    CHECK(cc_cmd_len == 28, "le_create_connection: total length == 3 (header) + 25 (params)");
    CHECK(buf_read_byte(cc_cmd, 0) == 0x0D, "le_create_connection: opcode LE byte0");
    CHECK(buf_read_byte(cc_cmd, 1) == 0x20, "le_create_connection: opcode LE byte1");
    CHECK(buf_read_byte(cc_cmd, 2) == 25, "le_create_connection: param length == 25");
    CHECK(buf_read_byte(cc_cmd, 9) == 0x01, "le_create_connection: peer_addr byte0 verbatim");
    CHECK(buf_read_byte(cc_cmd, 14) == 0x06, "le_create_connection: peer_addr byte5 verbatim");
    CHECK(fn_buf_read_u16_le(cc_cmd, 16) == 0x0018, "le_create_connection: conn_interval_min LE round trip");
    CHECK(fn_buf_read_u16_le(cc_cmd, 22) == 0x01F4, "le_create_connection: supervision_timeout LE round trip");

    /* Command Status (0x0F): [Status][Num_Packets][Opcode LE]. */
    int64_t *cs_event = dhruva_alloc_bytes(6);
    buf_write_byte(cs_event, 0, 0x0F);
    buf_write_byte(cs_event, 1, 4);
    buf_write_byte(cs_event, 2, 0x00); /* status = success */
    buf_write_byte(cs_event, 3, 0x01);
    buf_write_byte(cs_event, 4, 0x0D);
    buf_write_byte(cs_event, 5, 0x20);
    CHECK(fn_hci_event_is_command_status(cs_event) == 1, "command status: recognized");
    CHECK(fn_hci_cmd_status_status(cs_event) == 0, "command status: status == success");
    CHECK(fn_hci_cmd_status_opcode(cs_event) == 0x200D, "command status: opcode matches LE_Create_Connection");

    /* LE Meta Event (0x3E) / LE Connection Complete (subevent 0x01):
     * [Status][Handle LE][Role][Peer_Addr_Type][Peer_Addr(6)]
     * [Conn_Interval LE][Conn_Latency LE][Supervision_Timeout LE]
     * [Master_Clock_Accuracy]. */
    int64_t *lcc_event = dhruva_alloc_bytes(3 + 19);
    buf_write_byte(lcc_event, 0, 0x3E);
    buf_write_byte(lcc_event, 1, 19);
    buf_write_byte(lcc_event, 2, 0x01); /* subevent: connection complete */
    buf_write_byte(lcc_event, 3, 0x00); /* status = success */
    buf_write_byte(lcc_event, 4, 0x40); /* handle LE lo */
    buf_write_byte(lcc_event, 5, 0x00); /* handle LE hi */
    buf_write_byte(lcc_event, 6, 0x00); /* role = master */
    buf_write_byte(lcc_event, 7, 0x00); /* peer addr type = public */
    for (int i = 0; i < 6; i++) buf_write_byte(lcc_event, 8 + i, 0xA0 + i);
    CHECK(fn_hci_event_is_le_meta(lcc_event) == 1, "le meta: recognized");
    CHECK(fn_hci_le_meta_subevent_code(lcc_event) == 0x01, "le meta: subevent is connection complete");
    CHECK(fn_hci_le_conn_complete_status(lcc_event) == 0, "conn complete: status == success");
    CHECK(fn_hci_le_conn_complete_handle(lcc_event) == 0x0040, "conn complete: handle LE round trip");
    CHECK(fn_hci_le_conn_complete_role(lcc_event) == 0, "conn complete: role == master");
    CHECK(fn_hci_le_conn_complete_peer_addr_type(lcc_event) == 0, "conn complete: peer addr type == public");
    int64_t *peer_out = dhruva_alloc_bytes(6);
    fn_hci_le_conn_complete_peer_addr(lcc_event, peer_out);
    CHECK(buf_read_byte(peer_out, 0) == 0xA0, "conn complete: peer addr byte0");
    CHECK(buf_read_byte(peer_out, 5) == 0xA5, "conn complete: peer addr byte5");

    /* HCI ACL Data header: [Handle:12|PB:2|BC:2 LE][Data_Total_Len LE]. */
    int64_t *acl_hdr = dhruva_alloc_bytes(4);
    int64_t acl_hdr_len = fn_hci_acl_build_header(acl_hdr, 0x0040, fn_hci_acl_pb_flag_first(), fn_hci_acl_bc_flag_point_to_point(), 7);
    CHECK(acl_hdr_len == 4, "acl header: length == 4");
    CHECK(fn_hci_acl_get_handle(acl_hdr) == 0x0040, "acl header: handle round trip");
    CHECK(fn_hci_acl_get_pb_flag(acl_hdr) == fn_hci_acl_pb_flag_first(), "acl header: pb_flag round trip");
    CHECK(fn_hci_acl_get_data_len(acl_hdr) == 7, "acl header: data_len round trip");
    /* Handle 0x0FFF is the max 12-bit value -- confirms flags don't leak
     * into the handle field or vice versa. */
    int64_t acl_hdr2_len = fn_hci_acl_build_header(acl_hdr, 0x0FFF, 0x1, 0x1, 0);
    CHECK(acl_hdr2_len == 4, "acl header: max handle length == 4");
    CHECK(fn_hci_acl_get_handle(acl_hdr) == 0x0FFF, "acl header: max handle (0xFFF) round trip, no bleed from flags");
    CHECK(fn_hci_acl_get_pb_flag(acl_hdr) == 1, "acl header: pb_flag round trip with max handle");

    /* L2CAP B-frame header: [Length LE][Channel_ID LE]. */
    int64_t *l2cap_hdr = dhruva_alloc_bytes(4);
    int64_t l2cap_hdr_len = fn_l2cap_build_header(l2cap_hdr, 3, fn_l2cap_att_channel_id());
    CHECK(l2cap_hdr_len == 4, "l2cap header: length == 4");
    CHECK(fn_l2cap_get_length(l2cap_hdr) == 3, "l2cap header: length field round trip");
    CHECK(fn_l2cap_get_channel_id(l2cap_hdr) == 0x0004, "l2cap header: ATT channel ID (0x0004) round trip");
    CHECK(fn_l2cap_signaling_channel_id() == 0x0005, "l2cap: signaling channel ID is 0x0005");

    /* ATT opcodes match spec values directly. */
    CHECK(fn_att_opcode_error_response() == 0x01, "att opcode: error response");
    CHECK(fn_att_opcode_exchange_mtu_request() == 0x02, "att opcode: exchange mtu request");
    CHECK(fn_att_opcode_exchange_mtu_response() == 0x03, "att opcode: exchange mtu response");
    CHECK(fn_att_opcode_read_request() == 0x0A, "att opcode: read request");
    CHECK(fn_att_opcode_read_response() == 0x0B, "att opcode: read response");
    CHECK(fn_att_opcode_write_request() == 0x12, "att opcode: write request");
    CHECK(fn_att_opcode_write_response() == 0x13, "att opcode: write response");

    /* Error Response. */
    int64_t *att_err = dhruva_alloc_bytes(5);
    int64_t att_err_len = fn_att_build_error_response(att_err, fn_att_opcode_read_request(), 0x0012, 0x0A);
    CHECK(att_err_len == 5, "att error: length == 5");
    CHECK(fn_att_get_opcode(att_err) == fn_att_opcode_error_response(), "att error: opcode");
    CHECK(fn_att_error_request_opcode(att_err) == fn_att_opcode_read_request(), "att error: request_opcode_in_error");
    CHECK(fn_att_error_handle(att_err) == 0x0012, "att error: handle_in_error");
    CHECK(fn_att_error_code(att_err) == 0x0A, "att error: error_code (0x0A == Attribute Not Found)");

    /* Exchange MTU request/response. */
    int64_t *mtu_req = dhruva_alloc_bytes(3);
    int64_t mtu_req_len = fn_att_build_exchange_mtu_request(mtu_req, 185);
    CHECK(mtu_req_len == 3, "att mtu req: length == 3");
    CHECK(fn_att_get_opcode(mtu_req) == fn_att_opcode_exchange_mtu_request(), "att mtu req: opcode");
    CHECK(fn_att_exchange_mtu_request_get_mtu(mtu_req) == 185, "att mtu req: mtu round trip");

    int64_t *mtu_rsp = dhruva_alloc_bytes(3);
    int64_t mtu_rsp_len = fn_att_build_exchange_mtu_response(mtu_rsp, 247);
    CHECK(mtu_rsp_len == 3, "att mtu rsp: length == 3");
    CHECK(fn_att_get_opcode(mtu_rsp) == fn_att_opcode_exchange_mtu_response(), "att mtu rsp: opcode");
    CHECK(fn_att_exchange_mtu_response_get_mtu(mtu_rsp) == 247, "att mtu rsp: mtu round trip");

    /* Read request/response. */
    int64_t *read_req = dhruva_alloc_bytes(3);
    int64_t read_req_len = fn_att_build_read_request(read_req, 0x002A);
    CHECK(read_req_len == 3, "att read req: length == 3");
    CHECK(fn_att_get_opcode(read_req) == fn_att_opcode_read_request(), "att read req: opcode");
    CHECK(fn_att_read_request_get_handle(read_req) == 0x002A, "att read req: handle round trip");

    int64_t *read_value = mkbuf("hi!", 3);
    int64_t *read_rsp = dhruva_alloc_bytes(4);
    int64_t read_rsp_len = fn_att_build_read_response(read_rsp, read_value, 3);
    CHECK(read_rsp_len == 4, "att read rsp: length == 1 (opcode) + 3 (value)");
    CHECK(fn_att_get_opcode(read_rsp) == fn_att_opcode_read_response(), "att read rsp: opcode");
    int64_t *read_value_out = dhruva_alloc_bytes(3);
    int64_t read_value_out_len = fn_att_read_response_get_value(read_rsp, read_rsp_len, read_value_out);
    CHECK(read_value_out_len == 3, "att read rsp: extracted value length == 3");
    CHECK(memcmp(read_value_out, "hi!", 3) == 0, "att read rsp: extracted value bytes match");

    /* Write request/response. */
    int64_t *write_value = mkbuf("ok", 2);
    int64_t *write_req = dhruva_alloc_bytes(5);
    int64_t write_req_len = fn_att_build_write_request(write_req, 0x002B, write_value, 2);
    CHECK(write_req_len == 5, "att write req: length == 3 (header) + 2 (value)");
    CHECK(fn_att_get_opcode(write_req) == fn_att_opcode_write_request(), "att write req: opcode");
    CHECK(fn_att_write_request_get_handle(write_req) == 0x002B, "att write req: handle round trip");
    int64_t *write_value_out = dhruva_alloc_bytes(2);
    int64_t write_value_out_len = fn_att_write_request_get_value(write_req, write_req_len, write_value_out);
    CHECK(write_value_out_len == 2, "att write req: extracted value length == 2");
    CHECK(memcmp(write_value_out, "ok", 2) == 0, "att write req: extracted value bytes match");

    int64_t *write_rsp = dhruva_alloc_bytes(1);
    int64_t write_rsp_len = fn_att_build_write_response(write_rsp);
    CHECK(write_rsp_len == 1, "att write rsp: length == 1 (opcode only)");
    CHECK(fn_att_get_opcode(write_rsp) == fn_att_opcode_write_response(), "att write rsp: opcode");
}

/* Round 66 follow-up: ATT discovery PDUs (Find Information, Read By
 * Type, Read By Group Type) -- GATT discovery's own building blocks. */
static void test_att_discovery(void) {
    /* Error codes match spec values. */
    CHECK(fn_att_error_attribute_not_found() == 0x0A, "att error: attribute not found == 0x0A");
    CHECK(fn_att_error_invalid_handle() == 0x01, "att error: invalid handle == 0x01");
    CHECK(fn_att_error_unsupported_group_type() == 0x10, "att error: unsupported group type == 0x10");
    CHECK(fn_att_error_insufficient_resources() == 0x11, "att error: insufficient resources == 0x11");

    /* Find Information Request: opcode 0x04, starting/ending handle LE. */
    int64_t *fi_req = dhruva_alloc_bytes(5);
    int64_t fi_req_len = fn_att_build_find_information_request(fi_req, 0x0001, 0xFFFF);
    CHECK(fi_req_len == 5, "find info req: length == 5");
    CHECK(fn_att_get_opcode(fi_req) == fn_att_opcode_find_information_request(), "find info req: opcode");
    CHECK(fn_att_opcode_find_information_request() == 0x04, "find info: request opcode == 0x04");
    CHECK(fn_att_opcode_find_information_response() == 0x05, "find info: response opcode == 0x05");
    CHECK(fn_buf_read_u16_le(fi_req, 1) == 0x0001, "find info req: starting_handle round trip");
    CHECK(fn_buf_read_u16_le(fi_req, 3) == 0xFFFF, "find info req: ending_handle round trip");

    /* Find Information Response, format 1 (16-bit UUIDs): 3 handle/UUID
     * pairs, e.g. discovering 3 descriptors. */
    int64_t *fi_rsp = dhruva_alloc_bytes(2 + 3 * 4);
    buf_write_byte(fi_rsp, 0, 0x05);
    buf_write_byte(fi_rsp, 1, 0x01); /* format = 16-bit UUIDs */
    fn_buf_write_u16_le(fi_rsp, 2, 0x0010);  /* handle 0x10 */
    fn_buf_write_u16_le(fi_rsp, 4, 0x2902);  /* CCCD UUID */
    fn_buf_write_u16_le(fi_rsp, 6, 0x0011);  /* handle 0x11 */
    fn_buf_write_u16_le(fi_rsp, 8, 0x2901);  /* Characteristic User Description UUID */
    fn_buf_write_u16_le(fi_rsp, 10, 0x0012); /* handle 0x12 */
    fn_buf_write_u16_le(fi_rsp, 12, 0x2904); /* Characteristic Presentation Format UUID */
    int64_t fi_rsp_len = 2 + 3 * 4;
    CHECK(fn_att_find_information_response_get_format(fi_rsp) == 1, "find info rsp: format == 1 (16-bit)");
    CHECK(fn_att_find_information_entry_size(1) == 4, "find info: 16-bit entry size == 4");
    CHECK(fn_att_find_information_entry_size(2) == 18, "find info: 128-bit entry size == 18");
    CHECK(fn_att_find_information_response_count(fi_rsp, fi_rsp_len) == 3, "find info rsp: count == 3 entries");
    CHECK(fn_att_find_information_response_get_handle_at(fi_rsp, 0) == 0x0010, "find info rsp: entry 0 handle");
    CHECK(fn_att_find_information_response_get_uuid16_at(fi_rsp, 0) == 0x2902, "find info rsp: entry 0 UUID (CCCD)");
    CHECK(fn_att_find_information_response_get_handle_at(fi_rsp, 1) == 0x0011, "find info rsp: entry 1 handle");
    CHECK(fn_att_find_information_response_get_uuid16_at(fi_rsp, 1) == 0x2901, "find info rsp: entry 1 UUID");
    CHECK(fn_att_find_information_response_get_handle_at(fi_rsp, 2) == 0x0012, "find info rsp: entry 2 handle");
    CHECK(fn_att_find_information_response_get_uuid16_at(fi_rsp, 2) == 0x2904, "find info rsp: entry 2 UUID");

    /* Read By Type Request: opcode 0x08, range + 16-bit attribute type. */
    int64_t *rbt_req = dhruva_alloc_bytes(7);
    int64_t rbt_req_len = fn_att_build_read_by_type_request_uuid16(rbt_req, 0x0001, 0xFFFF, 0x2803);
    CHECK(rbt_req_len == 7, "read by type req: length == 7");
    CHECK(fn_att_get_opcode(rbt_req) == fn_att_opcode_read_by_type_request(), "read by type req: opcode");
    CHECK(fn_att_opcode_read_by_type_request() == 0x08, "read by type: request opcode == 0x08");
    CHECK(fn_att_opcode_read_by_type_response() == 0x09, "read by type: response opcode == 0x09");
    CHECK(fn_buf_read_u16_le(rbt_req, 5) == 0x2803, "read by type req: attribute_type (Characteristic Declaration) round trip");

    /* Read By Type Response: 2 characteristic declarations, each entry
     * = handle(2) + value(5: properties(1)+value_handle(2)+uuid16(2)). */
    int64_t *rbt_rsp = dhruva_alloc_bytes(2 + 2 * 7);
    buf_write_byte(rbt_rsp, 0, 0x09);
    buf_write_byte(rbt_rsp, 1, 7); /* entry_len = 2 (handle) + 5 (value) */
    fn_buf_write_u16_le(rbt_rsp, 2, 0x0003);  /* char decl handle */
    buf_write_byte(rbt_rsp, 4, 0x0A);          /* properties: read */
    fn_buf_write_u16_le(rbt_rsp, 5, 0x0004);  /* value handle */
    fn_buf_write_u16_le(rbt_rsp, 7, 0xFEED);  /* char UUID (fictitious) */
    fn_buf_write_u16_le(rbt_rsp, 9, 0x0005);  /* char decl handle 2 */
    buf_write_byte(rbt_rsp, 11, 0x02);         /* properties: write */
    fn_buf_write_u16_le(rbt_rsp, 12, 0x0006); /* value handle 2 */
    fn_buf_write_u16_le(rbt_rsp, 14, 0xBEEF); /* char UUID 2 */
    int64_t rbt_rsp_len = 2 + 2 * 7;
    CHECK(fn_att_read_by_type_response_get_entry_len(rbt_rsp) == 7, "read by type rsp: entry_len == 7");
    CHECK(fn_att_read_by_type_response_count(rbt_rsp, rbt_rsp_len) == 2, "read by type rsp: count == 2 entries");
    CHECK(fn_att_read_by_type_response_get_handle_at(rbt_rsp, 0) == 0x0003, "read by type rsp: entry 0 handle");
    CHECK(fn_att_read_by_type_response_get_value_len(rbt_rsp) == 5, "read by type rsp: value_len == 5");
    int64_t *rbt_val0 = dhruva_alloc_bytes(5);
    int64_t rbt_val0_len = fn_att_read_by_type_response_get_value_at(rbt_rsp, 0, rbt_val0);
    CHECK(rbt_val0_len == 5, "read by type rsp: entry 0 value length == 5");
    CHECK(buf_read_byte(rbt_val0, 0) == 0x0A, "read by type rsp: entry 0 properties");
    CHECK(fn_buf_read_u16_le(rbt_val0, 1) == 0x0004, "read by type rsp: entry 0 value_handle");
    CHECK(fn_buf_read_u16_le(rbt_val0, 3) == 0xFEED, "read by type rsp: entry 0 char UUID");
    CHECK(fn_att_read_by_type_response_get_handle_at(rbt_rsp, 1) == 0x0005, "read by type rsp: entry 1 handle");
    int64_t *rbt_val1 = dhruva_alloc_bytes(5);
    fn_att_read_by_type_response_get_value_at(rbt_rsp, 1, rbt_val1);
    CHECK(buf_read_byte(rbt_val1, 0) == 0x02, "read by type rsp: entry 1 properties");
    CHECK(fn_buf_read_u16_le(rbt_val1, 1) == 0x0006, "read by type rsp: entry 1 value_handle");
    CHECK(fn_buf_read_u16_le(rbt_val1, 3) == 0xBEEF, "read by type rsp: entry 1 char UUID");

    /* Read By Group Type Request: opcode 0x10, same shape as Read By Type. */
    int64_t *rbgt_req = dhruva_alloc_bytes(7);
    int64_t rbgt_req_len = fn_att_build_read_by_group_type_request_uuid16(rbgt_req, 0x0001, 0xFFFF, 0x2800);
    CHECK(rbgt_req_len == 7, "read by group type req: length == 7");
    CHECK(fn_att_get_opcode(rbgt_req) == fn_att_opcode_read_by_group_type_request(), "read by group type req: opcode");
    CHECK(fn_att_opcode_read_by_group_type_request() == 0x10, "read by group type: request opcode == 0x10");
    CHECK(fn_att_opcode_read_by_group_type_response() == 0x11, "read by group type: response opcode == 0x11");
    CHECK(fn_buf_read_u16_le(rbgt_req, 5) == 0x2800, "read by group type req: group_type (Primary Service) round trip");

    /* Read By Group Type Response: 2 services, each entry = start(2) +
     * end(2) + value(2: a 16-bit service UUID). */
    int64_t *rbgt_rsp = dhruva_alloc_bytes(2 + 2 * 6);
    buf_write_byte(rbgt_rsp, 0, 0x11);
    buf_write_byte(rbgt_rsp, 1, 6); /* entry_len = 4 (handles) + 2 (value) */
    fn_buf_write_u16_le(rbgt_rsp, 2, 0x0001);  /* service 1 start handle */
    fn_buf_write_u16_le(rbgt_rsp, 4, 0x0005);  /* service 1 end handle */
    fn_buf_write_u16_le(rbgt_rsp, 6, 0x180F);  /* Battery Service UUID */
    fn_buf_write_u16_le(rbgt_rsp, 8, 0x0006);  /* service 2 start handle */
    fn_buf_write_u16_le(rbgt_rsp, 10, 0x000C); /* service 2 end handle */
    fn_buf_write_u16_le(rbgt_rsp, 12, 0x180D); /* Heart Rate Service UUID */
    int64_t rbgt_rsp_len = 2 + 2 * 6;
    CHECK(fn_att_read_by_group_type_response_get_entry_len(rbgt_rsp) == 6, "read by group type rsp: entry_len == 6");
    CHECK(fn_att_read_by_group_type_response_count(rbgt_rsp, rbgt_rsp_len) == 2, "read by group type rsp: count == 2 groups");
    CHECK(fn_att_read_by_group_type_response_get_start_handle_at(rbgt_rsp, 0) == 0x0001, "read by group type rsp: group 0 start handle");
    CHECK(fn_att_read_by_group_type_response_get_end_handle_at(rbgt_rsp, 0) == 0x0005, "read by group type rsp: group 0 end handle");
    CHECK(fn_att_read_by_group_type_response_get_value_len(rbgt_rsp) == 2, "read by group type rsp: value_len == 2");
    int64_t *rbgt_val0 = dhruva_alloc_bytes(2);
    fn_att_read_by_group_type_response_get_value_at(rbgt_rsp, 0, rbgt_val0);
    CHECK(fn_buf_read_u16_le(rbgt_val0, 0) == 0x180F, "read by group type rsp: group 0 service UUID (Battery Service)");
    CHECK(fn_att_read_by_group_type_response_get_start_handle_at(rbgt_rsp, 1) == 0x0006, "read by group type rsp: group 1 start handle");
    CHECK(fn_att_read_by_group_type_response_get_end_handle_at(rbgt_rsp, 1) == 0x000C, "read by group type rsp: group 1 end handle");
    int64_t *rbgt_val1 = dhruva_alloc_bytes(2);
    fn_att_read_by_group_type_response_get_value_at(rbgt_rsp, 1, rbgt_val1);
    CHECK(fn_buf_read_u16_le(rbgt_val1, 0) == 0x180D, "read by group type rsp: group 1 service UUID (Heart Rate Service)");
}

/* Round 66: GATT's own UUID constants and discovered-services/
 * characteristics tables. Deliberately does NOT call gatt_att_send/
 * gatt_att_recv/gatt_discover_* -- those reach mmio_read_u32/
 * mmio_write_u32, which compile to raw `*(volatile uint32_t*)addr`
 * dereferences of real Raspberry Pi peripheral addresses (confirmed
 * by reading kernel_gen_patched.c directly); calling them on the host
 * would segfault, the same reason hci_send_command_and_wait_complete/
 * hci_reset_and_scan aren't directly host-tested either -- only their
 * pure packet-building/parsing pieces are, matching this project's
 * own established scope for anything that ultimately touches real
 * hardware registers. */
static void test_gatt_state(void) {
    CHECK(fn_gatt_uuid_primary_service() == 0x2800, "gatt uuid: primary service");
    CHECK(fn_gatt_uuid_secondary_service() == 0x2801, "gatt uuid: secondary service");
    CHECK(fn_gatt_uuid_include() == 0x2802, "gatt uuid: include");
    CHECK(fn_gatt_uuid_characteristic() == 0x2803, "gatt uuid: characteristic declaration");
    CHECK(fn_gatt_uuid_char_extended_properties() == 0x2900, "gatt uuid: char extended properties");
    CHECK(fn_gatt_uuid_char_user_description() == 0x2901, "gatt uuid: char user description");
    CHECK(fn_gatt_uuid_client_char_configuration() == 0x2902, "gatt uuid: client char configuration (CCCD)");
    CHECK(fn_gatt_uuid_server_char_configuration() == 0x2903, "gatt uuid: server char configuration");
    CHECK(fn_gatt_uuid_char_presentation_format() == 0x2904, "gatt uuid: char presentation format");
    CHECK(fn_gatt_uuid_char_aggregate_format() == 0x2905, "gatt uuid: char aggregate format");

    fn_gatt_discover_reset();
    CHECK(gatt_service_get_count() == 0, "gatt discover_reset: service count cleared");
    CHECK(gatt_char_get_count() == 0, "gatt discover_reset: char count cleared");

    /* Service table round trip -- as if gatt_discover_primary_services
     * had just recorded one discovered Battery Service. */
    gatt_service_set_start_handle_at(0, 0x0001);
    gatt_service_set_end_handle_at(0, 0x0005);
    gatt_service_set_uuid16_at(0, 0x180F);
    gatt_service_set_count(1);
    CHECK(gatt_service_get_count() == 1, "gatt service table: count round trip");
    CHECK(gatt_service_get_start_handle_at(0) == 0x0001, "gatt service table: start handle round trip");
    CHECK(gatt_service_get_end_handle_at(0) == 0x0005, "gatt service table: end handle round trip");
    CHECK(gatt_service_get_uuid16_at(0) == 0x180F, "gatt service table: uuid16 round trip");

    /* Characteristic table round trip, with a back-reference to the
     * service above -- as if gatt_discover_characteristics_for_
     * service had just recorded one characteristic within it. */
    gatt_char_set_decl_handle_at(0, 0x0002);
    gatt_char_set_properties_at(0, 0x0A);
    gatt_char_set_value_handle_at(0, 0x0003);
    gatt_char_set_uuid16_at(0, 0x2A19);
    gatt_char_set_service_index_at(0, 0);
    gatt_char_set_count(1);
    CHECK(gatt_char_get_count() == 1, "gatt char table: count round trip");
    CHECK(gatt_char_get_decl_handle_at(0) == 0x0002, "gatt char table: decl handle round trip");
    CHECK(gatt_char_get_properties_at(0) == 0x0A, "gatt char table: properties round trip");
    CHECK(gatt_char_get_value_handle_at(0) == 0x0003, "gatt char table: value handle round trip");
    CHECK(gatt_char_get_uuid16_at(0) == 0x2A19, "gatt char table: uuid16 round trip (Battery Level)");
    CHECK(gatt_char_get_service_index_at(0) == 0, "gatt char table: service_index back-reference round trip");

    /* gatt_discover_reset clears both tables again, confirming a
     * fresh connection's discovery never sees a prior one's leftovers. */
    fn_gatt_discover_reset();
    CHECK(gatt_service_get_count() == 0, "gatt discover_reset: service count cleared again");
    CHECK(gatt_char_get_count() == 0, "gatt discover_reset: char count cleared again");
}

/* Round 66 follow-up: GATT SERVER role -- attribute database
 * construction (gatt_server_add_service/_add_characteristic) plus
 * request dispatch (gatt_server_handle_request) against synthetic ATT
 * request PDUs, entirely pure logic (no MMIO), safe to host-test in
 * full unlike gatt_server_poll itself (reaches gatt_att_send/_recv,
 * same real-hardware boundary as gatt_discover_ and gatt_att_send in
 * test_gatt_state's own comment above -- gatt_server_poll is
 * deliberately never called from here). Builds a small 2-service demo
 * database (Battery Service + Device Information, matching real
 * Bluetooth SIG-assigned services/characteristics) and dispatches one
 * request of each handled type against it, plus two rejection paths
 * (write to a non-writable value, an unresolvable handle) and one
 * genuinely unsupported opcode. */
static void test_gatt_server(void) {
    fn_gatt_server_reset();
    CHECK(gatt_server_attr_get_count() == 0, "gatt server: reset clears attribute count");

    /* Service 1: Battery Service (0x180F) -> handle 1. */
    int64_t svc1_handle = fn_gatt_server_add_service(0x180F);
    CHECK(svc1_handle == 1, "gatt server: service 1 (Battery Service) gets handle 1");

    /* Characteristic 1: Battery Level (0x2A19), Read|Notify (0x12),
     * initial value = one byte (77%). Declaration at handle 2, value
     * at handle 3. */
    int64_t *batt_val = dhruva_alloc_bytes(1);
    buf_write_byte(batt_val, 0, 77);
    int64_t batt_value_handle = fn_gatt_server_add_characteristic(0x12, 0x2A19, batt_val, 1);
    CHECK(batt_value_handle == 3, "gatt server: Battery Level value handle == 3 (decl=2, value=3)");

    /* Service 2: Device Information (0x180A) -> handle 4. */
    int64_t svc2_handle = fn_gatt_server_add_service(0x180A);
    CHECK(svc2_handle == 4, "gatt server: service 2 (Device Information) gets handle 4");

    /* Characteristic 2: Manufacturer Name String (0x2A29), Read|Write
     * (0x0A), initial value = "AB". Declaration at handle 5, value at
     * handle 6 -- the table's own last attribute. */
    int64_t *mfg_val = dhruva_alloc_bytes(2);
    buf_write_byte(mfg_val, 0, 'A');
    buf_write_byte(mfg_val, 1, 'B');
    int64_t mfg_value_handle = fn_gatt_server_add_characteristic(0x0A, 0x2A29, mfg_val, 2);
    CHECK(mfg_value_handle == 6, "gatt server: Manufacturer Name value handle == 6 (decl=5, value=6)");
    CHECK(gatt_server_attr_get_count() == 6, "gatt server: 6 attributes total (2 services + 2*2 characteristic entries)");

    int64_t *req = dhruva_alloc_bytes(256);
    int64_t *rsp = dhruva_alloc_bytes(256);

    /* Exchange MTU -- server always answers with its own fixed 247. */
    int64_t mtu_req_len = fn_att_build_exchange_mtu_request(req, 185);
    int64_t mtu_rsp_len = fn_gatt_server_handle_request(req, mtu_req_len, rsp);
    CHECK(fn_att_get_opcode(rsp) == fn_att_opcode_exchange_mtu_response(), "gatt server: exchange mtu -> response opcode");
    CHECK(fn_att_exchange_mtu_response_get_mtu(rsp) == 247, "gatt server: exchange mtu -> server_rx_mtu == 247");
    CHECK(mtu_rsp_len == 3, "gatt server: exchange mtu response length == 3");

    /* Read By Group Type (Primary Service) -- discovers both services,
     * each group's own end handle computed from the NEXT service's
     * own start handle (or the table's own last handle for the last
     * service). */
    int64_t rbgt_req_len = fn_att_build_read_by_group_type_request_uuid16(req, 1, 0xFFFF, 0x2800);
    int64_t rbgt_rsp_len = fn_gatt_server_handle_request(req, rbgt_req_len, rsp);
    CHECK(fn_att_get_opcode(rsp) == fn_att_opcode_read_by_group_type_response(), "gatt server: read by group type -> response opcode");
    CHECK(fn_att_read_by_group_type_response_count(rsp, rbgt_rsp_len) == 2, "gatt server: read by group type -> 2 services discovered");
    CHECK(fn_att_read_by_group_type_response_get_start_handle_at(rsp, 0) == 1, "gatt server: service 1 start handle == 1");
    CHECK(fn_att_read_by_group_type_response_get_end_handle_at(rsp, 0) == 3, "gatt server: service 1 end handle == 3 (right before service 2's own start)");
    int64_t *svc0_val = dhruva_alloc_bytes(2);
    fn_att_read_by_group_type_response_get_value_at(rsp, 0, svc0_val);
    CHECK(fn_buf_read_u16_le(svc0_val, 0) == 0x180F, "gatt server: service 1 UUID == Battery Service");
    CHECK(fn_att_read_by_group_type_response_get_start_handle_at(rsp, 1) == 4, "gatt server: service 2 start handle == 4");
    CHECK(fn_att_read_by_group_type_response_get_end_handle_at(rsp, 1) == 6, "gatt server: service 2 end handle == 6 (table's own last attribute)");

    /* Read By Type (Characteristic Declaration) within service 1's own
     * range [1,3] -- discovers Battery Level's own declaration. */
    int64_t rbt_req_len = fn_att_build_read_by_type_request_uuid16(req, 1, 3, 0x2803);
    int64_t rbt_rsp_len = fn_gatt_server_handle_request(req, rbt_req_len, rsp);
    CHECK(fn_att_get_opcode(rsp) == fn_att_opcode_read_by_type_response(), "gatt server: read by type -> response opcode");
    CHECK(fn_att_read_by_type_response_count(rsp, rbt_rsp_len) == 1, "gatt server: read by type -> 1 characteristic in service 1");
    CHECK(fn_att_read_by_type_response_get_handle_at(rsp, 0) == 2, "gatt server: Battery Level declaration handle == 2");
    int64_t *char0_val = dhruva_alloc_bytes(5);
    fn_att_read_by_type_response_get_value_at(rsp, 0, char0_val);
    CHECK(buf_read_byte(char0_val, 0) == 0x12, "gatt server: Battery Level properties == 0x12 (Read|Notify)");
    CHECK(fn_buf_read_u16_le(char0_val, 1) == 3, "gatt server: Battery Level value_handle == 3");
    CHECK(fn_buf_read_u16_le(char0_val, 3) == 0x2A19, "gatt server: Battery Level UUID round trip");

    /* Read Request on the Battery Level value itself. */
    int64_t rd_req_len = fn_att_build_read_request(req, 3);
    int64_t rd_rsp_len = fn_gatt_server_handle_request(req, rd_req_len, rsp);
    CHECK(fn_att_get_opcode(rsp) == fn_att_opcode_read_response(), "gatt server: read battery level -> response opcode");
    CHECK(rd_rsp_len == 2, "gatt server: read battery level -> response length == 1 (opcode) + 1 (value)");
    CHECK(buf_read_byte(rsp, 1) == 77, "gatt server: read battery level -> value == 77");

    /* Write Request on Battery Level -- rejected, no Write property bit. */
    int64_t *bad_write_val = dhruva_alloc_bytes(1);
    buf_write_byte(bad_write_val, 0, 50);
    int64_t bad_wr_req_len = fn_att_build_write_request(req, 3, bad_write_val, 1);
    int64_t bad_wr_rsp_len = fn_gatt_server_handle_request(req, bad_wr_req_len, rsp);
    CHECK(fn_att_get_opcode(rsp) == fn_att_opcode_error_response(), "gatt server: write to read-only battery level -> error response");
    CHECK(fn_att_error_request_opcode(rsp) == fn_att_opcode_write_request(), "gatt server: rejected write -> error names write request");
    CHECK(fn_att_error_handle(rsp) == 3, "gatt server: rejected write -> error names handle 3");
    CHECK(fn_att_error_code(rsp) == fn_att_error_write_not_permitted(), "gatt server: rejected write -> Write Not Permitted (0x03)");
    CHECK(bad_wr_rsp_len == 5, "gatt server: error response length == 5");

    /* Write Request on Manufacturer Name -- accepted (Write property
     * bit set), then read back to confirm the value actually changed. */
    int64_t *new_mfg_val = dhruva_alloc_bytes(2);
    buf_write_byte(new_mfg_val, 0, 'X');
    buf_write_byte(new_mfg_val, 1, 'Y');
    int64_t wr_req_len = fn_att_build_write_request(req, 6, new_mfg_val, 2);
    int64_t wr_rsp_len = fn_gatt_server_handle_request(req, wr_req_len, rsp);
    CHECK(fn_att_get_opcode(rsp) == fn_att_opcode_write_response(), "gatt server: write manufacturer name -> write response");
    CHECK(wr_rsp_len == 1, "gatt server: write response length == 1 (opcode only)");
    int64_t rd2_req_len = fn_att_build_read_request(req, 6);
    fn_gatt_server_handle_request(req, rd2_req_len, rsp);
    CHECK(buf_read_byte(rsp, 1) == 'X', "gatt server: manufacturer name read-back byte 0 == 'X'");
    CHECK(buf_read_byte(rsp, 2) == 'Y', "gatt server: manufacturer name read-back byte 1 == 'Y'");

    /* Read Request on a handle that doesn't exist -> Invalid Handle. */
    int64_t bad_rd_req_len = fn_att_build_read_request(req, 99);
    fn_gatt_server_handle_request(req, bad_rd_req_len, rsp);
    CHECK(fn_att_get_opcode(rsp) == fn_att_opcode_error_response(), "gatt server: read unresolvable handle -> error response");
    CHECK(fn_att_error_code(rsp) == fn_att_error_invalid_handle(), "gatt server: read unresolvable handle -> Invalid Handle (0x01)");
    CHECK(fn_att_error_handle(rsp) == 99, "gatt server: read unresolvable handle -> error names handle 99");

    /* A genuinely unsupported opcode (Find Information, 0x04 --
     * discovery-of-descriptors isn't dispatched by this server) ->
     * Request Not Supported. */
    buf_write_byte(req, 0, 0x04);
    fn_gatt_server_handle_request(req, 5, rsp);
    CHECK(fn_att_get_opcode(rsp) == fn_att_opcode_error_response(), "gatt server: unsupported opcode -> error response");
    CHECK(fn_att_error_code(rsp) == fn_att_error_request_not_supported(), "gatt server: unsupported opcode -> Request Not Supported (0x06)");

    fn_gatt_server_reset();
}

/* Round 66 follow-up: 128-bit custom UUID support -- request builders,
 * the Find Information response's own 128-bit accessor, the byte-
 * compare helper, and the gatt_state.S storage round trip. Deliberately
 * does NOT call gatt_discover_primary_services/_characteristics_for_
 * service themselves (reach MMIO, same boundary as test_gatt_state's
 * own comment) -- instead pokes the table directly, exactly as that
 * function's own 16-bit round-trip test already does, just exercising
 * the new is_uuid128/uuid128 fields instead. */
static void test_uuid128(void) {
    /* A real 128-bit vendor UUID, byte 0 first (as it appears on the
     * wire, little-endian like everything else in ATT). */
    int64_t *uuid_a = dhruva_alloc_bytes(16);
    int64_t *uuid_b = dhruva_alloc_bytes(16);
    for (int i = 0; i < 16; i++) {
        buf_write_byte(uuid_a, i, 0xA0 + i);
        buf_write_byte(uuid_b, i, 0xA0 + i);
    }
    CHECK(fn_uuid128_equal(uuid_a, uuid_b) == 1, "uuid128_equal: identical UUIDs compare equal");
    buf_write_byte(uuid_b, 15, 0xFF);
    CHECK(fn_uuid128_equal(uuid_a, uuid_b) == 0, "uuid128_equal: a single differing byte compares unequal");
    buf_write_byte(uuid_b, 15, 0xA0 + 15); /* restore */

    /* Read By Type Request, 128-bit attribute type -- opcode + range +
     * 16 raw UUID bytes, length 21. */
    int64_t *rbt128_req = dhruva_alloc_bytes(21);
    int64_t rbt128_len = fn_att_build_read_by_type_request_uuid128(rbt128_req, 0x0001, 0xFFFF, uuid_a);
    CHECK(rbt128_len == 21, "read by type req (128-bit): length == 21");
    CHECK(fn_att_get_opcode(rbt128_req) == fn_att_opcode_read_by_type_request(), "read by type req (128-bit): opcode");
    CHECK(fn_buf_read_u16_le(rbt128_req, 1) == 0x0001, "read by type req (128-bit): starting_handle round trip");
    CHECK(fn_buf_read_u16_le(rbt128_req, 3) == 0xFFFF, "read by type req (128-bit): ending_handle round trip");
    int match = 1;
    for (int i = 0; i < 16; i++) {
        if (buf_read_byte(rbt128_req, 5 + i) != (uint32_t)(0xA0 + i)) match = 0;
    }
    CHECK(match, "read by type req (128-bit): all 16 UUID bytes round trip at offset 5");

    /* Read By Group Type Request, 128-bit group type -- identical shape. */
    int64_t *rbgt128_req = dhruva_alloc_bytes(21);
    int64_t rbgt128_len = fn_att_build_read_by_group_type_request_uuid128(rbgt128_req, 0x0001, 0xFFFF, uuid_a);
    CHECK(rbgt128_len == 21, "read by group type req (128-bit): length == 21");
    CHECK(fn_att_get_opcode(rbgt128_req) == fn_att_opcode_read_by_group_type_request(), "read by group type req (128-bit): opcode");
    match = 1;
    for (int i = 0; i < 16; i++) {
        if (buf_read_byte(rbgt128_req, 5 + i) != (uint32_t)(0xA0 + i)) match = 0;
    }
    CHECK(match, "read by group type req (128-bit): all 16 UUID bytes round trip at offset 5");

    /* Find Information Response, format 2 (128-bit UUIDs): 2 entries,
     * each (handle(2), uuid128(16)) = 18 bytes. */
    int64_t *fi_rsp = dhruva_alloc_bytes(2 + 2 * 18);
    buf_write_byte(fi_rsp, 0, 0x05);
    buf_write_byte(fi_rsp, 1, 0x02); /* format = 128-bit UUIDs */
    fn_buf_write_u16_le(fi_rsp, 2, 0x0020); /* entry 0 handle */
    for (int i = 0; i < 16; i++) buf_write_byte(fi_rsp, 4 + i, 0xB0 + i);
    fn_buf_write_u16_le(fi_rsp, 20, 0x0021); /* entry 1 handle */
    for (int i = 0; i < 16; i++) buf_write_byte(fi_rsp, 22 + i, 0xC0 + i);
    CHECK(fn_att_find_information_response_get_format(fi_rsp) == 2, "find info rsp (128-bit): format == 2");
    CHECK(fn_att_find_information_entry_size(2) == 18, "find info: 128-bit entry size == 18");
    int64_t fi_rsp_len = 2 + 2 * 18;
    CHECK(fn_att_find_information_response_count(fi_rsp, fi_rsp_len) == 2, "find info rsp (128-bit): count == 2 entries");
    CHECK(fn_att_find_information_response_get_handle_at(fi_rsp, 0) == 0x0020, "find info rsp (128-bit): entry 0 handle");
    int64_t *got_uuid0 = dhruva_alloc_bytes(16);
    fn_att_find_information_response_get_uuid128_at(fi_rsp, 0, got_uuid0);
    match = 1;
    for (int i = 0; i < 16; i++) {
        if (buf_read_byte(got_uuid0, i) != (uint32_t)(0xB0 + i)) match = 0;
    }
    CHECK(match, "find info rsp (128-bit): entry 0 UUID bytes round trip");
    CHECK(fn_att_find_information_response_get_handle_at(fi_rsp, 1) == 0x0021, "find info rsp (128-bit): entry 1 handle");
    int64_t *got_uuid1 = dhruva_alloc_bytes(16);
    fn_att_find_information_response_get_uuid128_at(fi_rsp, 1, got_uuid1);
    CHECK(fn_uuid128_equal(got_uuid0, got_uuid1) == 0, "find info rsp (128-bit): entries 0 and 1 have different UUIDs");

    /* gatt_state.S storage round trip, as if gatt_discover_primary_
     * services had just recorded one custom-UUID service. */
    fn_gatt_discover_reset();
    gatt_service_set_start_handle_at(0, 0x0001);
    gatt_service_set_end_handle_at(0, 0x0004);
    gatt_service_set_uuid16_at(0, 0);
    gatt_service_set_is_uuid128_at(0, 1);
    for (int i = 0; i < 16; i++) gatt_service_set_uuid128_byte(0 * 16 + i, 0xD0 + i);
    gatt_service_set_count(1);
    CHECK(gatt_service_get_is_uuid128_at(0) == 1, "gatt service table: is_uuid128 flag round trip");
    match = 1;
    for (int i = 0; i < 16; i++) {
        if (gatt_service_get_uuid128_byte(0 * 16 + i) != (uint32_t)(0xD0 + i)) match = 0;
    }
    CHECK(match, "gatt service table: uuid128 bytes round trip");

    /* Same for the characteristic table, as if gatt_discover_
     * characteristics_for_service had just recorded one custom-UUID
     * characteristic within that service. */
    gatt_char_set_decl_handle_at(0, 0x0002);
    gatt_char_set_properties_at(0, 0x0A);
    gatt_char_set_value_handle_at(0, 0x0003);
    gatt_char_set_uuid16_at(0, 0);
    gatt_char_set_is_uuid128_at(0, 1);
    for (int i = 0; i < 16; i++) gatt_char_set_uuid128_byte(0 * 16 + i, 0xE0 + i);
    gatt_char_set_service_index_at(0, 0);
    gatt_char_set_count(1);
    CHECK(gatt_char_get_is_uuid128_at(0) == 1, "gatt char table: is_uuid128 flag round trip");
    match = 1;
    for (int i = 0; i < 16; i++) {
        if (gatt_char_get_uuid128_byte(0 * 16 + i) != (uint32_t)(0xE0 + i)) match = 0;
    }
    CHECK(match, "gatt char table: uuid128 bytes round trip");

    fn_gatt_discover_reset();
}

/* Round 66 follow-up: notifications/indications (PDU builders/parsers,
 * pure logic) + L2CAP Signaling (Connection Parameter Update
 * Request/Response, pure logic) + the descriptor-discovery/
 * subscription helper functions that don't themselves touch MMIO
 * (gatt_char_descriptor_range_end, gatt_client_find_char_index_for_
 * value_handle, the CCCD-handle table, the last-notify-handle slot).
 * Deliberately does NOT call gatt_discover_descriptors_for_
 * characteristic/gatt_client_write_cccd/gatt_client_poll_
 * notifications/l2cap_sig_send/_recv/_poll/gatt_server_notify_value --
 * all reach gatt_att_send/_recv or dwc2_bt_bulk_*, the same real-
 * hardware MMIO boundary as every other orchestration function this
 * project keeps out of host_harness. */
static void test_notifications_and_l2cap_sig(void) {
    CHECK(fn_att_opcode_handle_value_notification() == 0x1B, "att opcode: handle value notification == 0x1B");
    CHECK(fn_att_opcode_handle_value_indication() == 0x1D, "att opcode: handle value indication == 0x1D");
    CHECK(fn_att_opcode_handle_value_confirmation() == 0x1E, "att opcode: handle value confirmation == 0x1E");

    /* Handle Value Notification: opcode + handle(2, LE) + value. */
    int64_t *notify_val = dhruva_alloc_bytes(3);
    buf_write_byte(notify_val, 0, 0x2A);
    buf_write_byte(notify_val, 1, 0x2B);
    buf_write_byte(notify_val, 2, 0x2C);
    int64_t *notify_pdu = dhruva_alloc_bytes(6);
    int64_t notify_len = fn_att_build_handle_value_notification(notify_pdu, 0x0010, notify_val, 3);
    CHECK(notify_len == 6, "handle value notification: length == 3 (header) + 3 (value)");
    CHECK(fn_att_get_opcode(notify_pdu) == fn_att_opcode_handle_value_notification(), "handle value notification: opcode");
    CHECK(fn_att_handle_value_get_handle(notify_pdu) == 0x0010, "handle value notification: handle round trip");
    int64_t *notify_out = dhruva_alloc_bytes(3);
    int64_t notify_out_len = fn_att_handle_value_get_value(notify_pdu, notify_len, notify_out);
    CHECK(notify_out_len == 3, "handle value notification: value length round trip");
    CHECK(buf_read_byte(notify_out, 0) == 0x2A && buf_read_byte(notify_out, 1) == 0x2B && buf_read_byte(notify_out, 2) == 0x2C, "handle value notification: value bytes round trip");

    /* Handle Value Indication: identical shape, different opcode. */
    int64_t *indicate_pdu = dhruva_alloc_bytes(6);
    int64_t indicate_len = fn_att_build_handle_value_indication(indicate_pdu, 0x0011, notify_val, 3);
    CHECK(indicate_len == 6, "handle value indication: length == 6");
    CHECK(fn_att_get_opcode(indicate_pdu) == fn_att_opcode_handle_value_indication(), "handle value indication: opcode");
    CHECK(fn_att_handle_value_get_handle(indicate_pdu) == 0x0011, "handle value indication: handle round trip");

    /* Handle Value Confirmation -- just the opcode, 1 byte. */
    int64_t *confirm_pdu = dhruva_alloc_bytes(1);
    int64_t confirm_len = fn_att_build_handle_value_confirmation(confirm_pdu);
    CHECK(confirm_len == 1, "handle value confirmation: length == 1");
    CHECK(fn_att_get_opcode(confirm_pdu) == fn_att_opcode_handle_value_confirmation(), "handle value confirmation: opcode");

    /* L2CAP Signaling: Connection Parameter Update Request/Response
     * codes and result constants. */
    CHECK(fn_l2cap_sig_code_connection_parameter_update_request() == 0x12, "l2cap sig: conn param update request code == 0x12");
    CHECK(fn_l2cap_sig_code_connection_parameter_update_response() == 0x13, "l2cap sig: conn param update response code == 0x13");
    CHECK(fn_l2cap_conn_param_update_result_accepted() == 0x0000, "l2cap sig: result accepted == 0x0000");
    CHECK(fn_l2cap_conn_param_update_result_rejected() == 0x0001, "l2cap sig: result rejected == 0x0001");

    /* A synthetic Connection Parameter Update Request, hand-built as
     * if received over the wire: [Code=0x12][Identifier][Length=8, LE]
     * [Interval_Min][Interval_Max][Slave_Latency][Timeout_Multiplier]. */
    int64_t *cpu_req = dhruva_alloc_bytes(12);
    buf_write_byte(cpu_req, 0, 0x12);
    buf_write_byte(cpu_req, 1, 0x07); /* identifier */
    fn_buf_write_u16_le(cpu_req, 2, 8);
    fn_buf_write_u16_le(cpu_req, 4, 0x0006);  /* interval_min */
    fn_buf_write_u16_le(cpu_req, 6, 0x000C);  /* interval_max */
    fn_buf_write_u16_le(cpu_req, 8, 0x0000);  /* slave_latency */
    fn_buf_write_u16_le(cpu_req, 10, 0x0064); /* timeout_multiplier */
    CHECK(fn_l2cap_sig_get_code(cpu_req) == 0x12, "l2cap sig: conn param update request code round trip");
    CHECK(fn_l2cap_sig_get_identifier(cpu_req) == 0x07, "l2cap sig: identifier round trip");
    CHECK(fn_l2cap_sig_get_length(cpu_req) == 8, "l2cap sig: length round trip");
    CHECK(fn_l2cap_conn_param_update_request_get_interval_min(cpu_req) == 0x0006, "l2cap sig: interval_min round trip");
    CHECK(fn_l2cap_conn_param_update_request_get_interval_max(cpu_req) == 0x000C, "l2cap sig: interval_max round trip");
    CHECK(fn_l2cap_conn_param_update_request_get_slave_latency(cpu_req) == 0x0000, "l2cap sig: slave_latency round trip");
    CHECK(fn_l2cap_conn_param_update_request_get_timeout_multiplier(cpu_req) == 0x0064, "l2cap sig: timeout_multiplier round trip");

    /* Connection Parameter Update Response, built for the same
     * identifier, Accepted. */
    int64_t *cpu_rsp = dhruva_alloc_bytes(6);
    int64_t cpu_rsp_len = fn_l2cap_build_conn_param_update_response(cpu_rsp, 0x07, fn_l2cap_conn_param_update_result_accepted());
    CHECK(cpu_rsp_len == 6, "l2cap sig: conn param update response length == 6");
    CHECK(fn_l2cap_sig_get_code(cpu_rsp) == 0x13, "l2cap sig: conn param update response code round trip");
    CHECK(fn_l2cap_sig_get_identifier(cpu_rsp) == 0x07, "l2cap sig: conn param update response identifier matches request");
    CHECK(fn_l2cap_sig_get_length(cpu_rsp) == 2, "l2cap sig: conn param update response length field == 2");
    CHECK(fn_buf_read_u16_le(cpu_rsp, 4) == 0x0000, "l2cap sig: conn param update response result == Accepted");

    /* gatt_char_descriptor_range_end -- two characteristics in the
     * same service (char 0 ends right before char 1's own decl
     * handle), then a third characteristic alone in a second service
     * (ends at the service's own end handle, the table's own last
     * attribute in this synthetic setup). */
    fn_gatt_discover_reset();
    gatt_service_set_start_handle_at(0, 0x0001);
    gatt_service_set_end_handle_at(0, 0x0008);
    gatt_service_set_count(1);
    gatt_char_set_decl_handle_at(0, 0x0002);
    gatt_char_set_value_handle_at(0, 0x0003);
    gatt_char_set_service_index_at(0, 0);
    gatt_char_set_decl_handle_at(1, 0x0005);
    gatt_char_set_value_handle_at(1, 0x0006);
    gatt_char_set_service_index_at(1, 0);
    gatt_char_set_count(2);
    CHECK(fn_gatt_char_descriptor_range_end(0) == 0x0004, "gatt char descriptor range: char 0 ends right before char 1's decl handle (0x0005-1)");
    CHECK(fn_gatt_char_descriptor_range_end(1) == 0x0008, "gatt char descriptor range: last char in service ends at the service's own end handle");

    /* gatt_client_find_char_index_for_value_handle -- table lookup by
     * VALUE handle, matching how a Notification/Indication's own
     * handle field needs to be resolved. */
    CHECK(fn_gatt_client_find_char_index_for_value_handle(0x0003) == 0, "gatt client: find char index for value handle 0x0003 -> index 0");
    CHECK(fn_gatt_client_find_char_index_for_value_handle(0x0006) == 1, "gatt client: find char index for value handle 0x0006 -> index 1");
    CHECK(fn_gatt_client_find_char_index_for_value_handle(0x00FF) == -1, "gatt client: unknown value handle -> -1");

    /* CCCD handle table + last-notify-handle slot round trips. */
    CHECK(gatt_char_get_cccd_handle_at(0) == 0, "gatt char table: cccd handle starts at 0 (not discovered)");
    gatt_char_set_cccd_handle_at(0, 0x0004);
    CHECK(gatt_char_get_cccd_handle_at(0) == 0x0004, "gatt char table: cccd handle round trip");
    gatt_last_notify_handle_set(0x0003);
    CHECK(gatt_last_notify_handle_get() == 0x0003, "gatt last notify handle: native stub round trip");
    CHECK(fn_gatt_client_last_notify_handle() == 0x0003, "gatt client: last_notify_handle wrapper round trip");

    fn_gatt_discover_reset();
}

/* Round 66: diag_ring_state.S's wraparound math (via the native stub
 * added this round to fix a real host_harness link break the ring
 * buffer's own original commit introduced -- see host_stubs.c's own
 * comment). Only live-QEMU-verified before this (a ~25-real-second
 * wait to accumulate 32+ ticks); this gives the same coverage
 * instantly and repeatably. */
static void test_diag_ring(void) {
    int64_t start_count = diag_ring_get_count();

    /* Unwrapped case: logical index N is always physical slot N when
     * the ring hasn't filled yet. */
    diag_ring_push(100, 1, 1, 0);
    diag_ring_push(101, 2, 2, 1);
    int64_t count_after_2 = diag_ring_get_count();
    CHECK(count_after_2 == start_count + 2, "diag_ring: count advances by 2 after 2 pushes");
    if (count_after_2 < 32) {
        int64_t last_phys = fn_diag_ring_physical_index(count_after_2 - 1);
        CHECK(diag_ring_get_tick_at(last_phys) == 101, "diag_ring: newest sample's tick is the last one pushed");
    }

    /* Wrapped case: push enough more to guarantee the ring has filled
     * and wrapped at least once, regardless of how many samples
     * existed before this test ran. */
    for (int i = 0; i < 40; i++) {
        diag_ring_push(200 + i, i, i, i);
    }
    CHECK(diag_ring_get_count() == 32, "diag_ring: count caps at 32 once the ring fills");
    /* The newest sample (logical index 31, the last one pushed above)
     * must be tick 239 (200 + 39), regardless of wraparound. */
    int64_t newest_phys = fn_diag_ring_physical_index(31);
    CHECK(diag_ring_get_tick_at(newest_phys) == 239, "diag_ring: newest logical sample after wraparound is the most recent push");
    /* The oldest sample (logical index 0) must be exactly 31 ticks
     * behind the newest one -- 32 consecutive pushes, one per tick,
     * always span exactly 31 ticks end to end. */
    int64_t oldest_phys = fn_diag_ring_physical_index(0);
    CHECK(diag_ring_get_tick_at(oldest_phys) == 239 - 31, "diag_ring: oldest logical sample after wraparound is exactly 31 ticks behind the newest");
    /* head now points at the slot the NEXT push will overwrite --
     * physical_index(0) (the current oldest) must be exactly there. */
    CHECK(oldest_phys == diag_ring_get_head(), "diag_ring: oldest sample's physical slot is where head currently points (about to be overwritten next)");
}

/* Round 58: RTL8188CU/RTL8192CU vendor register SETUP-packet encoding,
 * checked against hand-computed bytes matching Linux's rtl8xxxu driver
 * (REALTEK_USB_CMD_REQ=0x05, REALTEK_USB_READ=0xc0, REALTEK_USB_
 * WRITE=0x40, register address in wValue, not wIndex -- see this
 * project's own comment in kernel_main.vani for the full citation). */
static void test_rtl_reg_setup_framing(void) {
    int64_t *scratch = dhruva_alloc_bytes(8);
    dwc2_dma_scratch_set(scratch);

    fn_dwc2_build_rtl_reg_read_setup(0x0002, 2); /* REG_SYS_FUNC, u16 read */
    int64_t *dma = dwc2_dma_scratch_get();
    CHECK(buf_read_byte(dma, 0) == 0xC0, "rtl reg read setup: bmRequestType == 0xC0 (IN|VENDOR|DEVICE)");
    CHECK(buf_read_byte(dma, 1) == 0x05, "rtl reg read setup: bRequest == 0x05 (REALTEK_USB_CMD_REQ)");
    CHECK(buf_read_byte(dma, 2) == 0x02, "rtl reg read setup: wValue LE byte0 == register address low byte");
    CHECK(buf_read_byte(dma, 3) == 0x00, "rtl reg read setup: wValue LE byte1");
    CHECK(buf_read_byte(dma, 4) == 0x00, "rtl reg read setup: wIndex byte0 == 0 (unlike LAN9512, addr is NOT here)");
    CHECK(buf_read_byte(dma, 5) == 0x00, "rtl reg read setup: wIndex byte1 == 0");
    CHECK(buf_read_byte(dma, 6) == 0x02, "rtl reg read setup: wLength LE byte0 == 2 (u16 read)");
    CHECK(buf_read_byte(dma, 7) == 0x00, "rtl reg read setup: wLength LE byte1");

    fn_dwc2_build_rtl_reg_write_setup(0x0100, 4); /* MAC_CR-style register, u32 write */
    CHECK(buf_read_byte(dma, 0) == 0x40, "rtl reg write setup: bmRequestType == 0x40 (OUT|VENDOR|DEVICE)");
    CHECK(buf_read_byte(dma, 1) == 0x05, "rtl reg write setup: bRequest == 0x05");
    CHECK(buf_read_byte(dma, 2) == 0x00, "rtl reg write setup: wValue LE byte0 == register address low byte");
    CHECK(buf_read_byte(dma, 3) == 0x01, "rtl reg write setup: wValue LE byte1 == register address high byte");
    CHECK(buf_read_byte(dma, 6) == 0x04, "rtl reg write setup: wLength LE byte0 == 4 (u32 write)");
    CHECK(buf_read_byte(dma, 7) == 0x00, "rtl reg write setup: wLength LE byte1");
}

/* Round 60: independent host-side check of filter_check_frame's rule
 * matching, in addition to (not a replacement for) kernel_main.vani's
 * own filter_self_test() which runs on real target boot -- this one
 * runs under ASAN/UBSAN, catching any OOB read into the synthetic
 * frame buffer that a target-only run wouldn't surface. */
static void test_packet_filter(void) {
    uint32_t ip_a = 0x0A000001; /* 10.0.0.1 */
    uint32_t ip_b = 0x0A000002; /* 10.0.0.2 */

    fw_flush();
    fw_set_default_policy(0);
    int64_t *f1 = dhruva_alloc_bytes(64);
    int64_t l1 = fn_filter_build_test_frame(f1, 6, ip_a, 80);
    CHECK(fn_filter_check_frame(f1, l1) == 0, "fw: no rules -> default deny");

    fw_set_default_policy(1);
    fw_add_rule(6, ip_a, 1, 80, 1, 0); /* deny TCP from ip_a:80 */
    int64_t *f2 = dhruva_alloc_bytes(64);
    int64_t l2 = fn_filter_build_test_frame(f2, 6, ip_a, 80);
    CHECK(fn_filter_check_frame(f2, l2) == 0, "fw: specific deny rule matches");
    int64_t *f3 = dhruva_alloc_bytes(64);
    int64_t l3 = fn_filter_build_test_frame(f3, 6, ip_b, 80);
    CHECK(fn_filter_check_frame(f3, l3) == 1, "fw: different src_ip falls through to allow default");

    int64_t *f4 = dhruva_alloc_bytes(64);
    int64_t l4 = fn_filter_build_test_frame(f4, 17, ip_a, 80);
    CHECK(fn_filter_check_frame(f4, l4) == 1, "fw: TCP rule does not match UDP on the same ip/port");

    fw_flush();
    fw_add_rule(0, 0, 0, 0, 0, 0);      /* deny everything */
    fw_add_rule(6, 0, 0, 443, 1, 1);    /* allow TCP/443 -- shadowed */
    int64_t *f5 = dhruva_alloc_bytes(64);
    int64_t l5 = fn_filter_build_test_frame(f5, 6, ip_a, 443);
    CHECK(fn_filter_check_frame(f5, l5) == 0, "fw: first-match-wins -- earlier wildcard deny shadows later specific allow");

    fw_flush();
    fw_add_rule(0, 0, 0, 80, 1, 0); /* deny port 80 */
    fw_set_default_policy(1);
    int64_t *f6 = dhruva_alloc_bytes(64);
    int64_t l6 = fn_filter_build_test_frame(f6, 1, ip_a, 80); /* ICMP: portless */
    CHECK(fn_filter_check_frame(f6, l6) == 1, "fw: port-specific rule never matches a portless protocol (ICMP)");

    fw_set_default_policy(0);
    int64_t *f7 = dhruva_alloc_bytes(64);
    buf_write_byte(f7, 12, 0x08);
    buf_write_byte(f7, 13, 0x06); /* ethertype: ARP, not IPv4 */
    CHECK(fn_filter_check_frame(f7, 38) == 1, "fw: non-IPv4 traffic passes through regardless of policy/rules");

    fw_flush();
    fw_set_default_policy(0);
}

int main(void) {
    test_basic_round_trip();
    test_path_length_boundary();
    test_file_size_boundary();
    test_zero_length_data();
    test_overwrite();
    test_delete();
    test_rename();
    test_rename_transaction_crash_consistency();
    test_permission_boundaries();
    test_directory_hierarchy();
    test_dirindex();
    test_fsqueue();
    test_snapshot();
    test_dirlist_helpers();
    test_corrupted_checksum_skipped();
    test_oversized_data_len_field_rejected();
    test_self_referential_continuation_chain();
    test_verified_integrity();
    test_log_append();
    test_log_gc();
    test_attributes();
    test_chmod_chown_permissions();
    test_sha256_boundaries();
    test_hmac_pbkdf2_boundaries();
    test_media_crypto();
    test_fault_injection();
    test_chacha20_boundaries();
    test_poly1305();
    test_x25519();
    test_sha512_boundaries();
    test_bignum_boundaries();
    test_lan9512_framing();
    test_hci_framing();
    test_ble_connection_and_att();
    test_att_discovery();
    test_gatt_state();
    test_gatt_server();
    test_uuid128();
    test_notifications_and_l2cap_sig();
    test_diag_ring();
    test_rtl_reg_setup_framing();
    test_packet_filter();

    printf("\n%d PASS, %d FAIL\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
