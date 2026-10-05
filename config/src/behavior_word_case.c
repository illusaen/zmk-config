#include <zephyr/device.h>
#include <drivers/behavior.h>
#include <zmk/behavior.h>
#include <zmk/event_manager.h>
#include <zmk/events/keycode_state_changed.h>
#include <zmk/hid.h>
#include <zmk/keymap.h>
#include <zmk/keys.h>

struct word_case_state {
    bool active;
    bool pascal_cap_next;
    bool separator_down;
    uint8_t mode;
    uint8_t separator_mode;
};

static struct word_case_state state;

enum { MODE_SCREAM, MODE_SNAKE, MODE_KEBAB, MODE_PASCAL, MODE_PATH };

static int word_case_pressed(struct zmk_behavior_binding *binding,
                             struct zmk_behavior_binding_event) {
    uint8_t mode = binding->param1;
    if (state.active && state.mode == mode) {
        state.active = false;
        return ZMK_BEHAVIOR_OPAQUE;
    }
    state.mode = mode;
    state.active = true;
    state.pascal_cap_next = mode == MODE_PASCAL;
    return ZMK_BEHAVIOR_OPAQUE;
}

static int word_case_released(struct zmk_behavior_binding *binding,
                              struct zmk_behavior_binding_event) {
    return ZMK_BEHAVIOR_OPAQUE;
}

static const struct behavior_driver_api word_case_driver_api = {
    .binding_pressed = word_case_pressed,
    .binding_released = word_case_released,
#if IS_ENABLED(CONFIG_ZMK_BEHAVIOR_METADATA)
    .get_parameter_metadata = zmk_behavior_get_empty_param_metadata,
#endif
};

#define DT_DRV_COMPAT zmk_behavior_case_mode
#define DEFINE_MODE(inst)                                                                          \
    BEHAVIOR_DT_INST_DEFINE(inst, NULL, NULL, NULL, NULL, POST_KERNEL,                             \
                            CONFIG_KERNEL_INIT_PRIORITY_DEFAULT, &word_case_driver_api);
DT_INST_FOREACH_STATUS_OKAY(DEFINE_MODE)

#undef DT_DRV_COMPAT

static bool is_alpha(uint32_t key) {
    return key >= HID_USAGE_KEY_KEYBOARD_A && key <= HID_USAGE_KEY_KEYBOARD_Z;
}

static bool is_number(uint32_t key) {
    return key >= HID_USAGE_KEY_KEYBOARD_1_AND_EXCLAMATION &&
           key <= HID_USAGE_KEY_KEYBOARD_0_AND_RIGHT_PARENTHESIS;
}

static int rewrite_space(struct zmk_keycode_state_changed *ev, uint8_t mode) {
    if (mode == MODE_PASCAL) {
        return ZMK_EV_EVENT_HANDLED;
    }
    ev->usage_page = HID_USAGE_KEY;
    ev->implicit_modifiers = 0;
    if (mode == MODE_SCREAM || mode == MODE_SNAKE) {
        ev->keycode = HID_USAGE_KEY_KEYBOARD_MINUS_AND_UNDERSCORE;
        ev->implicit_modifiers = MOD_LSFT;
    } else if (mode == MODE_KEBAB) {
        ev->keycode = HID_USAGE_KEY_KEYBOARD_MINUS_AND_UNDERSCORE;
    } else {
        ev->keycode = HID_USAGE_KEY_KEYBOARD_SLASH_AND_QUESTION_MARK;
    }
    return ZMK_EV_EVENT_BUBBLE;
}

static int word_case_listener(const zmk_event_t *eh) {
    struct zmk_keycode_state_changed *ev = as_zmk_keycode_state_changed(eh);
    if (ev == NULL || ev->usage_page != HID_USAGE_KEY) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    if (ev->keycode == HID_USAGE_KEY_KEYBOARD_SPACEBAR) {
        if (!ev->state && state.separator_down) {
            state.separator_down = false;
            return rewrite_space(ev, state.separator_mode);
        }
        if (ev->state && state.active &&
            !((ev->implicit_modifiers | ev->explicit_modifiers | zmk_hid_get_explicit_mods()) &
              (MOD_LCTL | MOD_RCTL | MOD_LALT | MOD_RALT | MOD_LGUI | MOD_RGUI))) {
            state.separator_down = true;
            state.separator_mode = state.mode;
            if (state.mode == MODE_PASCAL) {
                state.pascal_cap_next = true;
            }
            return rewrite_space(ev, state.separator_mode);
        }
    }

    if (!state.active || !ev->state) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    if (ev->keycode == HID_USAGE_KEY_KEYBOARD_CANCEL) {
        state.active = false;
        return ZMK_EV_EVENT_BUBBLE;
    }

    if (is_mod(ev->usage_page, ev->keycode)) {
        return ZMK_EV_EVENT_BUBBLE;
    }
    if ((ev->implicit_modifiers | ev->explicit_modifiers | zmk_hid_get_explicit_mods()) &
        (MOD_LCTL | MOD_RCTL | MOD_LALT | MOD_RALT | MOD_LGUI | MOD_RGUI)) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    bool separator = (state.mode == MODE_SCREAM || state.mode == MODE_SNAKE) &&
                     ev->keycode == HID_USAGE_KEY_KEYBOARD_MINUS_AND_UNDERSCORE;
    separator |= state.mode == MODE_KEBAB && ev->keycode == HID_USAGE_KEY_KEYBOARD_MINUS_AND_UNDERSCORE;
    separator |= state.mode == MODE_PATH &&
                 ev->keycode == HID_USAGE_KEY_KEYBOARD_SLASH_AND_QUESTION_MARK;

    if (is_alpha(ev->keycode)) {
        if (state.mode == MODE_SCREAM &&
            !(ev->implicit_modifiers & (MOD_LCTL | MOD_RCTL | MOD_LALT | MOD_RALT | MOD_LGUI | MOD_RGUI))) {
            ev->implicit_modifiers |= MOD_LSFT;
        } else if (state.mode == MODE_PASCAL && state.pascal_cap_next) {
            ev->implicit_modifiers |= MOD_LSFT;
            state.pascal_cap_next = false;
        }
        return ZMK_EV_EVENT_BUBBLE;
    }

    if (is_number(ev->keycode) ||
        ev->keycode == HID_USAGE_KEY_KEYBOARD_DELETE_BACKSPACE ||
        ev->keycode == HID_USAGE_KEY_KEYBOARD_DELETE_FORWARD || separator) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    state.active = false;
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(case_mode, word_case_listener);
ZMK_SUBSCRIPTION(case_mode, zmk_keycode_state_changed);
