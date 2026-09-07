#ifndef CHID_BRIDGE_H
#define CHID_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum mp_hid_result {
    MP_HID_OK = 0,
    MP_HID_NOT_FOUND = 1,
    MP_HID_MULTIPLE_DEVICES = 2,
    MP_HID_OPEN_FAILED = 3,
    MP_HID_OUTPUT_REPORT_FAILED = 4,
    MP_HID_INPUT_REPORT_TIMEOUT = 5,
    MP_HID_INVALID_ARGUMENT = 6,
    MP_HID_STALE_STATE = 7,
    MP_HID_VERIFICATION_FAILED = 8,
    MP_HID_ROLLBACK_FAILED = 9
};

int mp_hid_discover(
    int *matching_count,
    char *serial,
    size_t serial_capacity,
    char *product,
    size_t product_capacity,
    char *transport,
    size_t transport_capacity);

int mp_hid_read_layer(
    int layer,
    const uint8_t *request,
    size_t request_length,
    uint8_t *reports,
    size_t reports_capacity);

int mp_hid_read_led(
    const uint8_t *request,
    size_t request_length,
    uint8_t *report,
    size_t report_capacity);

int mp_hid_program_slot(
    int layer,
    int slot,
    const uint8_t *expected,
    size_t expected_length,
    const uint8_t *replacement,
    size_t replacement_length,
    int *changed,
    int *reports_written,
    int *restore_attempted,
    int *restore_verified);

int mp_hid_program_led(
    uint8_t expected_mode,
    const uint8_t *expected_colors,
    size_t expected_colors_length,
    uint8_t target_mode,
    const uint8_t *target_colors,
    size_t target_colors_length,
    int *changed,
    int *reports_written,
    int *restore_attempted,
    int *restore_verified);

const char *mp_hid_result_message(int result);

#ifdef __cplusplus
}
#endif

#endif
