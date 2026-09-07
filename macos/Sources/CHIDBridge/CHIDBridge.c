#include "CHIDBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDDeviceKeys.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/USBSpec.h>

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    MP_VENDOR_ID = 0x514c,
    MP_PRODUCT_ID = 0x8850,
    MP_USAGE_PAGE = 0xff00,
    MP_REPORT_ID = 0x03,
    MP_REPORT_LENGTH = 64,
    MP_OUTPUT_REPORT_LENGTH = 65,
    MP_SLOT_COUNT = 25,
    MP_LED_COLOR_BYTES = 36
};

static const char *MP_LED_REPORT_TEMPLATES[3] = {
    "03feb000010000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ffff0000ffff0000ffff0000ff000000000000000000000000",
    "03feb00100ff0000ff8030ffff3000ff0000ffff0000ff8000808b0000ffa500ffff967dff00008b8b00008bff00ffff6666ffc864000000000000000000000000",
    "03feb00200ff0000ff8030ffff3000ff0000ffff0000ff8000808b0000ffa500ffff967dff00008b8b00008bff00ffff6666ffc864000000000000000000000000"
};

typedef struct {
    uint8_t *reports;
    size_t report_capacity;
    size_t expected_count;
    size_t received_count;
    IOReturn last_result;
    CFRunLoopRef run_loop;
} mp_input_context;

static void mp_copy_cf_string(CFTypeRef value, char *buffer, size_t capacity) {
    if (!buffer || capacity == 0) {
        return;
    }
    buffer[0] = '\0';
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return;
    }
    if (!CFStringGetCString((CFStringRef)value, buffer, (CFIndex)capacity, kCFStringEncodingUTF8)) {
        buffer[0] = '\0';
    }
}

static CFMutableDictionaryRef mp_create_matching_dictionary(void) {
    CFMutableDictionaryRef dictionary = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (!dictionary) {
        return NULL;
    }

    int vendor_id = MP_VENDOR_ID;
    int product_id = MP_PRODUCT_ID;
    CFNumberRef vendor = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor_id);
    CFNumberRef product = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product_id);
    if (!vendor || !product) {
        if (vendor) CFRelease(vendor);
        if (product) CFRelease(product);
        CFRelease(dictionary);
        return NULL;
    }

    CFDictionarySetValue(dictionary, CFSTR(kIOHIDVendorIDKey), vendor);
    CFDictionarySetValue(dictionary, CFSTR(kIOHIDProductIDKey), product);
    CFRelease(vendor);
    CFRelease(product);
    return dictionary;
}

static bool mp_copy_int_property(CFTypeRef value, int *result) {
    if (!value || !result || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }
    return CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, result);
}

static bool mp_device_has_usage_page(IOHIDDeviceRef device, int expected_usage_page) {
    int primary_usage_page = 0;
    if (mp_copy_int_property(
            IOHIDDeviceGetProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey)),
            &primary_usage_page) &&
        primary_usage_page == expected_usage_page) {
        return true;
    }

    CFTypeRef pairs_value =
        IOHIDDeviceGetProperty(device, CFSTR(kIOHIDDeviceUsagePairsKey));
    if (!pairs_value || CFGetTypeID(pairs_value) != CFArrayGetTypeID()) {
        return false;
    }

    CFArrayRef pairs = (CFArrayRef)pairs_value;
    for (CFIndex index = 0; index < CFArrayGetCount(pairs); ++index) {
        CFTypeRef pair_value = CFArrayGetValueAtIndex(pairs, index);
        if (!pair_value || CFGetTypeID(pair_value) != CFDictionaryGetTypeID()) {
            continue;
        }
        CFTypeRef usage_value = CFDictionaryGetValue(
            (CFDictionaryRef)pair_value,
            CFSTR(kIOHIDDeviceUsagePageKey));
        int usage_page = 0;
        if (mp_copy_int_property(usage_value, &usage_page) &&
            usage_page == expected_usage_page) {
            return true;
        }
    }
    return false;
}

static int mp_usb_interface_number(IOHIDDeviceRef device) {
    int interface_number = -1;
    if (mp_copy_int_property(
            IOHIDDeviceGetProperty(device, CFSTR(kUSBInterfaceNumber)),
            &interface_number)) {
        return interface_number;
    }

    io_service_t service = IOHIDDeviceGetService(device);
    io_registry_entry_t current = IO_OBJECT_NULL;
    if (service == MACH_PORT_NULL ||
        IORegistryEntryGetParentEntry(service, kIOServicePlane, &current) != KERN_SUCCESS) {
        return -1;
    }

    for (int depth = 0; depth < 3 && current != IO_OBJECT_NULL; ++depth) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(
            current,
            CFSTR(kUSBInterfaceNumber),
            kCFAllocatorDefault,
            0);
        bool found = mp_copy_int_property(value, &interface_number);
        if (value) CFRelease(value);
        if (found) {
            IOObjectRelease(current);
            return interface_number;
        }

        io_registry_entry_t parent = IO_OBJECT_NULL;
        kern_return_t parent_result =
            IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        IOObjectRelease(current);
        current = parent_result == KERN_SUCCESS ? parent : IO_OBJECT_NULL;
    }

    if (current != IO_OBJECT_NULL) IOObjectRelease(current);
    return -1;
}

static int mp_copy_matching_devices(
    IOHIDManagerRef *manager_out,
    CFSetRef *devices_out,
    IOHIDDeviceRef *single_device_out,
    int *count_out) {
    if (!manager_out || !devices_out || !single_device_out || !count_out) {
        return MP_HID_INVALID_ARGUMENT;
    }

    *manager_out = NULL;
    *devices_out = NULL;
    *single_device_out = NULL;
    *count_out = 0;

    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef matching = mp_create_matching_dictionary();
    if (!manager || !matching) {
        if (matching) CFRelease(matching);
        if (manager) CFRelease(manager);
        return MP_HID_OPEN_FAILED;
    }

    IOHIDManagerSetDeviceMatching(manager, matching);
    CFRelease(matching);
    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    CFIndex candidate_count = devices ? CFSetGetCount(devices) : 0;
    IOHIDDeviceRef selected_device = NULL;
    int count = 0;
    if (candidate_count > 0) {
        const void **candidates = calloc((size_t)candidate_count, sizeof(*candidates));
        if (!candidates) {
            CFRelease(devices);
            CFRelease(manager);
            return MP_HID_OPEN_FAILED;
        }
        CFSetGetValues(devices, candidates);
        for (CFIndex index = 0; index < candidate_count; ++index) {
            IOHIDDeviceRef candidate = (IOHIDDeviceRef)candidates[index];
            if (candidate &&
                mp_device_has_usage_page(candidate, MP_USAGE_PAGE) &&
                mp_usb_interface_number(candidate) == 0) {
                ++count;
                if (count == 1) selected_device = candidate;
            }
        }
        free(candidates);
    }
    *count_out = count;
    *manager_out = manager;
    *devices_out = devices;

    if (count == 0) {
        return MP_HID_NOT_FOUND;
    }
    if (count > 1) {
        return MP_HID_MULTIPLE_DEVICES;
    }

    *single_device_out = selected_device;
    return MP_HID_OK;
}

static void mp_release_enumeration(IOHIDManagerRef manager, CFSetRef devices) {
    if (devices) CFRelease(devices);
    if (manager) CFRelease(manager);
}

typedef struct {
    IOHIDManagerRef manager;
    CFSetRef devices;
    IOHIDDeviceRef device;
} mp_open_device;

static int mp_open_single_device(mp_open_device *opened, IOOptionBits options) {
    if (!opened) return MP_HID_INVALID_ARGUMENT;
    memset(opened, 0, sizeof(*opened));
    int count = 0;
    int result = mp_copy_matching_devices(
        &opened->manager, &opened->devices, &opened->device, &count);
    if (result != MP_HID_OK) {
        mp_release_enumeration(opened->manager, opened->devices);
        memset(opened, 0, sizeof(*opened));
        return result;
    }
    if (IOHIDDeviceOpen(opened->device, options) != kIOReturnSuccess) {
        mp_release_enumeration(opened->manager, opened->devices);
        memset(opened, 0, sizeof(*opened));
        return MP_HID_OPEN_FAILED;
    }
    return MP_HID_OK;
}

static void mp_close_single_device(mp_open_device *opened) {
    if (!opened) return;
    if (opened->device) IOHIDDeviceClose(opened->device, kIOHIDOptionsTypeNone);
    mp_release_enumeration(opened->manager, opened->devices);
    memset(opened, 0, sizeof(*opened));
}

int mp_hid_discover(
    int *matching_count,
    char *serial,
    size_t serial_capacity,
    char *product,
    size_t product_capacity,
    char *transport,
    size_t transport_capacity) {
    if (!matching_count) {
        return MP_HID_INVALID_ARGUMENT;
    }
    *matching_count = 0;
    mp_copy_cf_string(NULL, serial, serial_capacity);
    mp_copy_cf_string(NULL, product, product_capacity);
    mp_copy_cf_string(NULL, transport, transport_capacity);

    IOHIDManagerRef manager = NULL;
    CFSetRef devices = NULL;
    IOHIDDeviceRef device = NULL;
    int count = 0;
    int result = mp_copy_matching_devices(&manager, &devices, &device, &count);
    *matching_count = count;
    if (result == MP_HID_OK) {
        mp_copy_cf_string(
            IOHIDDeviceGetProperty(device, CFSTR(kIOHIDSerialNumberKey)),
            serial,
            serial_capacity);
        mp_copy_cf_string(
            IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey)),
            product,
            product_capacity);
        mp_copy_cf_string(
            IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey)),
            transport,
            transport_capacity);
    }
    mp_release_enumeration(manager, devices);
    return result;
}

static void mp_input_report_callback(
    void *context_pointer,
    IOReturn result,
    void *sender,
    IOHIDReportType type,
    uint32_t report_id,
    uint8_t *report,
    CFIndex report_length) {
    (void)sender;
    (void)type;
    mp_input_context *context = (mp_input_context *)context_pointer;
    if (!context || context->received_count >= context->expected_count) {
        return;
    }
    context->last_result = result;
    if (result != kIOReturnSuccess || !report) {
        if (context->run_loop) CFRunLoopStop(context->run_loop);
        return;
    }

    uint8_t *destination = context->reports + context->received_count * MP_REPORT_LENGTH;
    if (report_length >= MP_REPORT_LENGTH && report[0] == MP_REPORT_ID) {
        memcpy(destination, report, MP_REPORT_LENGTH);
    } else if (report_length >= MP_REPORT_LENGTH - 1 && report_id == MP_REPORT_ID) {
        destination[0] = MP_REPORT_ID;
        memcpy(destination + 1, report, MP_REPORT_LENGTH - 1);
    } else {
        return;
    }

    context->received_count += 1;
    if (context->run_loop) CFRunLoopStop(context->run_loop);
}

static int mp_exchange_on_device(
    IOHIDDeviceRef device,
    const uint8_t request[MP_OUTPUT_REPORT_LENGTH],
    uint8_t *reports,
    size_t reports_capacity,
    size_t expected_count) {
    if (!request || !reports || expected_count == 0 ||
        reports_capacity < expected_count * MP_REPORT_LENGTH) {
        return MP_HID_INVALID_ARGUMENT;
    }

    if (!device) return MP_HID_INVALID_ARGUMENT;
    int result = MP_HID_OK;

    uint8_t callback_buffer[MP_OUTPUT_REPORT_LENGTH] = {0};
    mp_input_context context = {
        .reports = reports,
        .report_capacity = reports_capacity,
        .expected_count = expected_count,
        .received_count = 0,
        .last_result = kIOReturnSuccess,
        .run_loop = CFRunLoopGetCurrent()
    };
    IOHIDDeviceRegisterInputReportCallback(
        device,
        callback_buffer,
        sizeof(callback_buffer),
        mp_input_report_callback,
        &context);
    IOHIDDeviceScheduleWithRunLoop(device, context.run_loop, kCFRunLoopDefaultMode);

    IOReturn write_result = IOHIDDeviceSetReport(
        device,
        kIOHIDReportTypeOutput,
        MP_REPORT_ID,
        request,
        MP_OUTPUT_REPORT_LENGTH);
    if (write_result != kIOReturnSuccess) {
        result = MP_HID_OUTPUT_REPORT_FAILED;
    } else {
        while (context.received_count < expected_count && context.last_result == kIOReturnSuccess) {
            size_t count_before_wait = context.received_count;
            CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 1.5;
            while (context.received_count == count_before_wait &&
                   context.last_result == kIOReturnSuccess) {
                CFTimeInterval remaining = deadline - CFAbsoluteTimeGetCurrent();
                if (remaining <= 0) break;
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining, true);
            }
            if (context.received_count == count_before_wait) break;
        }
        if (context.received_count != expected_count || context.last_result != kIOReturnSuccess) {
            result = MP_HID_INPUT_REPORT_TIMEOUT;
        }
    }

    IOHIDDeviceUnscheduleFromRunLoop(device, context.run_loop, kCFRunLoopDefaultMode);
    return result;
}

static int mp_exchange(
    const uint8_t request[MP_OUTPUT_REPORT_LENGTH],
    uint8_t *reports,
    size_t reports_capacity,
    size_t expected_count) {
    mp_open_device opened;
    int result = mp_open_single_device(&opened, kIOHIDOptionsTypeNone);
    if (result == MP_HID_OK) {
        result = mp_exchange_on_device(
            opened.device, request, reports, reports_capacity, expected_count);
    }
    mp_close_single_device(&opened);
    return result;
}

static bool mp_bytes_are_zero(const uint8_t *bytes, size_t start, size_t length) {
    for (size_t index = start; index < length; ++index) {
        if (bytes[index] != 0) return false;
    }
    return true;
}

int mp_hid_read_layer(
    int layer,
    const uint8_t *request,
    size_t request_length,
    uint8_t *reports,
    size_t reports_capacity) {
    if (layer < 1 || layer > 3 || !request ||
        request_length != MP_OUTPUT_REPORT_LENGTH ||
        request[0] != MP_REPORT_ID || request[1] != 0xfa ||
        request[2] != 0x19 || request[3] != 0x00 ||
        request[4] != (uint8_t)layer ||
        !mp_bytes_are_zero(request, 5, request_length)) {
        return MP_HID_INVALID_ARGUMENT;
    }
    return mp_exchange(request, reports, reports_capacity, MP_SLOT_COUNT);
}

int mp_hid_read_led(
    const uint8_t *request,
    size_t request_length,
    uint8_t *report,
    size_t report_capacity) {
    if (!request || request_length != MP_OUTPUT_REPORT_LENGTH ||
        request[0] != MP_REPORT_ID || request[1] != 0xfa || request[2] != 0xb0 ||
        !mp_bytes_are_zero(request, 3, request_length)) {
        return MP_HID_INVALID_ARGUMENT;
    }
    return mp_exchange(request, report, report_capacity, 1);
}

static bool mp_is_allowed_regular_key(uint8_t code) {
    return (code >= 0x04 && code <= 0x31) ||
        (code >= 0x33 && code <= 0x57) ||
        (code >= 0x59 && code <= 0x63) || code == 0x65 ||
        (code >= 0x68 && code <= 0x73);
}

static bool mp_validate_current_report(const uint8_t *report, int layer, int slot) {
    if (!report || layer < 1 || layer > 3 || slot < 1 || slot > MP_SLOT_COUNT ||
        report[0] != MP_REPORT_ID || report[1] != 0xfa ||
        report[2] != (uint8_t)slot || report[3] != (uint8_t)layer ||
        report[4] != 0x01 || report[5] > 0x01 || report[7] != 0 || report[8] != 0 ||
        report[60] != 0 || report[61] != 0 || report[62] != 0 || report[63] != 0) {
        return false;
    }
    int count = report[6];
    if (count < 1 || count > 5) return false;
    bool seen[256] = {false};
    int regular_count = 0;
    for (int index = 0; index < 17; ++index) {
        int offset = 9 + index * 3;
        uint8_t code = report[offset];
        if (report[offset + 1] != 0 ||
            (report[offset + 2] != 0 && report[offset + 2] != 0x32)) return false;
        if (index >= count) {
            if (code != 0) return false;
            continue;
        }
        if (code == 0) {
            if (count != 1 || index != 0) return false;
            continue;
        }
        if (seen[code]) return false;
        seen[code] = true;
        if (code >= 0xf1 && code <= 0xf4) continue;
        if (!mp_is_allowed_regular_key(code) || ++regular_count > 1) return false;
    }
    return true;
}

static int mp_read_layer_on_device(IOHIDDeviceRef device, int layer, uint8_t *reports) {
    uint8_t request[MP_OUTPUT_REPORT_LENGTH] = {0};
    request[0] = MP_REPORT_ID;
    request[1] = 0xfa;
    request[2] = 0x19;
    request[4] = (uint8_t)layer;
    return mp_exchange_on_device(
        device, request, reports, MP_SLOT_COUNT * MP_REPORT_LENGTH, MP_SLOT_COUNT);
}

static uint8_t *mp_find_slot(uint8_t *reports, int layer, int slot) {
    bool seen[MP_SLOT_COUNT + 1] = {false};
    uint8_t *found = NULL;
    for (int index = 0; index < MP_SLOT_COUNT; ++index) {
        uint8_t *report = reports + index * MP_REPORT_LENGTH;
        int current_slot = report[2];
        if (report[0] != MP_REPORT_ID || report[1] != 0xfa ||
            report[3] != (uint8_t)layer || current_slot < 1 ||
            current_slot > MP_SLOT_COUNT || seen[current_slot]) return NULL;
        seen[current_slot] = true;
        if (current_slot == slot) found = report;
    }
    return found;
}

static bool mp_write_output(IOHIDDeviceRef device, const uint8_t *report) {
    return IOHIDDeviceSetReport(
        device, kIOHIDReportTypeOutput, MP_REPORT_ID,
        report, MP_OUTPUT_REPORT_LENGTH) == kIOReturnSuccess;
}

static bool mp_write_slot_and_commit(IOHIDDeviceRef device, const uint8_t *read_format) {
    uint8_t write_report[MP_OUTPUT_REPORT_LENGTH] = {0};
    memcpy(write_report, read_format, MP_REPORT_LENGTH);
    write_report[1] = 0xfd;
    if (!mp_write_output(device, write_report)) return false;
    usleep(30000);
    uint8_t commit[MP_OUTPUT_REPORT_LENGTH] = {0};
    commit[0] = MP_REPORT_ID;
    commit[1] = 0xfd;
    commit[2] = 0xfe;
    commit[3] = 0xff;
    if (!mp_write_output(device, commit)) return false;
    usleep(30000);
    return true;
}

static bool mp_restore_slot(
    IOHIDDeviceRef device, int layer, int slot, const uint8_t *original) {
    if (!mp_write_slot_and_commit(device, original)) return false;
    uint8_t reports[MP_SLOT_COUNT * MP_REPORT_LENGTH] = {0};
    if (mp_read_layer_on_device(device, layer, reports) != MP_HID_OK) return false;
    uint8_t *restored = mp_find_slot(reports, layer, slot);
    return restored && memcmp(restored, original, MP_REPORT_LENGTH) == 0;
}

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
    int *restore_verified) {
    if (!changed || !reports_written || !restore_attempted || !restore_verified) {
        return MP_HID_INVALID_ARGUMENT;
    }
    *changed = 0;
    *reports_written = 0;
    *restore_attempted = 0;
    *restore_verified = 1;
    if (expected_length != MP_REPORT_LENGTH || replacement_length != MP_REPORT_LENGTH ||
        !mp_validate_current_report(expected, layer, slot) ||
        !mp_validate_current_report(replacement, layer, slot)) {
        return MP_HID_INVALID_ARGUMENT;
    }

    mp_open_device opened;
    int result = mp_open_single_device(&opened, kIOHIDOptionsTypeSeizeDevice);
    if (result != MP_HID_OK) return result;
    uint8_t reports[MP_SLOT_COUNT * MP_REPORT_LENGTH] = {0};
    result = mp_read_layer_on_device(opened.device, layer, reports);
    uint8_t *current = result == MP_HID_OK ? mp_find_slot(reports, layer, slot) : NULL;
    if (result == MP_HID_OK && !current) result = MP_HID_INPUT_REPORT_TIMEOUT;
    if (result == MP_HID_OK && memcmp(current, expected, MP_REPORT_LENGTH) != 0) {
        result = MP_HID_STALE_STATE;
    } else if (result == MP_HID_OK && memcmp(expected, replacement, MP_REPORT_LENGTH) == 0) {
        result = MP_HID_OK;
    } else if (result == MP_HID_OK) {
        *changed = 1;
        if (mp_write_slot_and_commit(opened.device, replacement)) {
            *reports_written = 2;
            memset(reports, 0, sizeof(reports));
            int verify_result = mp_read_layer_on_device(opened.device, layer, reports);
            uint8_t *verified = verify_result == MP_HID_OK
                ? mp_find_slot(reports, layer, slot) : NULL;
            if (verified && memcmp(verified, replacement, MP_REPORT_LENGTH) == 0) {
                result = MP_HID_OK;
            } else {
                result = MP_HID_VERIFICATION_FAILED;
            }
        } else {
            result = MP_HID_OUTPUT_REPORT_FAILED;
        }
        if (result != MP_HID_OK) {
            *restore_attempted = 1;
            *restore_verified = mp_restore_slot(opened.device, layer, slot, expected) ? 1 : 0;
            if (!*restore_verified) result = MP_HID_ROLLBACK_FAILED;
        }
    }
    mp_close_single_device(&opened);
    return result;
}

static bool mp_hex_nibble(char value, uint8_t *nibble) {
    if (value >= '0' && value <= '9') *nibble = (uint8_t)(value - '0');
    else if (value >= 'a' && value <= 'f') *nibble = (uint8_t)(value - 'a' + 10);
    else if (value >= 'A' && value <= 'F') *nibble = (uint8_t)(value - 'A' + 10);
    else return false;
    return true;
}

static bool mp_build_led_report(
    int report_index, uint8_t mode, const uint8_t *colors, uint8_t *report) {
    if (report_index < 0 || report_index > 2 || mode > 5 || !colors || !report) return false;
    const char *source = MP_LED_REPORT_TEMPLATES[report_index];
    for (int index = 0; index < MP_OUTPUT_REPORT_LENGTH; ++index) {
        uint8_t high = 0;
        uint8_t low = 0;
        if (!mp_hex_nibble(source[index * 2], &high) ||
            !mp_hex_nibble(source[index * 2 + 1], &low)) return false;
        report[index] = (uint8_t)((high << 4) | low);
    }
    if (report_index == 0) {
        report[4] = mode;
        memcpy(report + 5, colors, MP_LED_COLOR_BYTES);
    }
    return true;
}

static int mp_read_led_on_device(IOHIDDeviceRef device, uint8_t *report) {
    uint8_t request[MP_OUTPUT_REPORT_LENGTH] = {0};
    request[0] = MP_REPORT_ID;
    request[1] = 0xfa;
    request[2] = 0xb0;
    return mp_exchange_on_device(device, request, report, MP_REPORT_LENGTH, 1);
}

static bool mp_led_matches(const uint8_t *report, uint8_t mode, const uint8_t *colors) {
    return report && report[0] == MP_REPORT_ID && report[1] == 0xfa &&
        report[2] == mode && memcmp(report + 3, colors, MP_LED_COLOR_BYTES) == 0;
}

static int mp_write_led_reports(IOHIDDeviceRef device, uint8_t mode, const uint8_t *colors) {
    int written = 0;
    for (int index = 0; index < 3; ++index) {
        uint8_t report[MP_OUTPUT_REPORT_LENGTH] = {0};
        if (!mp_build_led_report(index, mode, colors, report) ||
            !mp_write_output(device, report)) break;
        ++written;
        usleep(2000);
    }
    if (written == 3) usleep(5000);
    return written;
}

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
    int *restore_verified) {
    if (!expected_colors || !target_colors || expected_colors_length != MP_LED_COLOR_BYTES ||
        target_colors_length != MP_LED_COLOR_BYTES || expected_mode > 5 || target_mode > 5 ||
        !changed || !reports_written || !restore_attempted || !restore_verified) {
        return MP_HID_INVALID_ARGUMENT;
    }
    *changed = 0;
    *reports_written = 0;
    *restore_attempted = 0;
    *restore_verified = 1;
    mp_open_device opened;
    int result = mp_open_single_device(&opened, kIOHIDOptionsTypeSeizeDevice);
    if (result != MP_HID_OK) return result;
    uint8_t current[MP_REPORT_LENGTH] = {0};
    result = mp_read_led_on_device(opened.device, current);
    if (result == MP_HID_OK && !mp_led_matches(current, expected_mode, expected_colors)) {
        result = MP_HID_STALE_STATE;
    } else if (result == MP_HID_OK && expected_mode == target_mode &&
               memcmp(expected_colors, target_colors, MP_LED_COLOR_BYTES) == 0) {
        result = MP_HID_OK;
    } else if (result == MP_HID_OK) {
        *changed = 1;
        int written = mp_write_led_reports(opened.device, target_mode, target_colors);
        *reports_written = written;
        uint8_t verification[MP_REPORT_LENGTH] = {0};
        if (written == 3 && mp_read_led_on_device(opened.device, verification) == MP_HID_OK &&
            mp_led_matches(verification, target_mode, target_colors)) {
            result = MP_HID_OK;
        } else {
            result = written == 3 ? MP_HID_VERIFICATION_FAILED : MP_HID_OUTPUT_REPORT_FAILED;
            *restore_attempted = 1;
            *reports_written += mp_write_led_reports(opened.device, expected_mode, expected_colors);
            uint8_t restored[MP_REPORT_LENGTH] = {0};
            *restore_verified = mp_read_led_on_device(opened.device, restored) == MP_HID_OK &&
                mp_led_matches(restored, expected_mode, expected_colors);
            if (!*restore_verified) result = MP_HID_ROLLBACK_FAILED;
        }
    }
    mp_close_single_device(&opened);
    return result;
}

const char *mp_hid_result_message(int result) {
    switch (result) {
        case MP_HID_OK: return "ok";
        case MP_HID_NOT_FOUND: return "device_not_found";
        case MP_HID_MULTIPLE_DEVICES: return "multiple_matching_devices";
        case MP_HID_OPEN_FAILED: return "device_open_failed";
        case MP_HID_OUTPUT_REPORT_FAILED: return "output_report_failed";
        case MP_HID_INPUT_REPORT_TIMEOUT: return "input_report_timeout";
        case MP_HID_INVALID_ARGUMENT: return "invalid_argument";
        case MP_HID_STALE_STATE: return "stale_device_state";
        case MP_HID_VERIFICATION_FAILED: return "verification_failed";
        case MP_HID_ROLLBACK_FAILED: return "rollback_failed";
        default: return "unknown_hid_error";
    }
}
