
//============================================================
//
//  input.cpp - IOS input handling
//
//============================================================

// MAME headers
#include "emu.h"
#include "input.h"
#include "inputdev.h"
#include "ui/uimain.h"
//#include "emuopts.h"
//#include "uiinput.h"

// include this to get mame_ui_manager, sigh
//#include "../frontend/mame/ui/ui.h"


// MAMEOS headers
#include "iososd.h"

static input_item_id key_map(myosd_keycode key);

//============================================================
// global input state
//============================================================
static myosd_input_state g_input;

//============================================================
//  get_xxx
//============================================================

static int get_key(void *device, void *item)
{
    return *(uint8_t*)item != 0;
}

static int get_axis(void *device, void *item)
{
    float value = *(float*)item;
    return (int)(value * osd::input_device::ABSOLUTE_MAX);
}

static int get_axis_neg(void *device, void *item)
{
    float value = *(float*)item;
    return (int)(value * osd::input_device::ABSOLUTE_MIN);
}

static int get_mouse(void *device, void *item)
{
    float value = *(float*)item;
    return (int)round(value);
}

#define BTN(off,mask) (void*)(intptr_t)(((intptr_t)mask<<32) | offsetof(myosd_input_state,off))
static int get_button(void *device, void *item)
{
    _Static_assert(sizeof(intptr_t) == 8, "");
    intptr_t off  = (intptr_t)item & 0xFFFFFFFF;
    intptr_t mask = (intptr_t)item>>32;
    unsigned long status = *(unsigned long *)((uint8_t*)&g_input + off);
    return (status & mask) != 0;
}

//============================================================
//  init
//============================================================

void ios_osd_interface::input_init()
{
    osd_printf_verbose("ios_osd_interface::input_init\n");
    
    machine().input().device_class(DEVICE_CLASS_JOYSTICK).enable(true);
    machine().input().device_class(DEVICE_CLASS_MOUSE).enable(true);
    machine().input().device_class(DEVICE_CLASS_LIGHTGUN).enable(true);
    
    // clear input state, this will cause input_update_init to be called later
    memset(&g_input, 0, sizeof(g_input));
    
    char name[32];
    
    // keyboard
    snprintf(name, sizeof(name)-1, "Keyboard");
    input_device* keyboard = &machine().input().device_class(DEVICE_CLASS_KEYBOARD).add_device(name, name);
    
    // all keys
    for (int key = MYOSD_KEY_FIRST; key <= MYOSD_KEY_LAST; key++)
    {
        input_item_id itemid = key_map((myosd_keycode)key);

        if (itemid == ITEM_ID_INVALID)
            continue;

        const char* name = machine().input().standard_token(itemid);
        keyboard->add_item(name, "", itemid, get_key, &g_input.keyboard[key]);
    }
    
    // joystick
    for (int i=0; i<MYOSD_NUM_JOY; i++)
    {
        snprintf(name, sizeof(name)-1, "Joy %d", i+1);
        input_device* joystick = &machine().input().device_class(DEVICE_CLASS_JOYSTICK).add_device(name, name);
        
        joystick->add_item("LX Axis", "", ITEM_ID_XAXIS,  get_axis,     &g_input.joy_analog[i][MYOSD_AXIS_LX]);
        joystick->add_item("LY Axis", "", ITEM_ID_YAXIS,  get_axis_neg, &g_input.joy_analog[i][MYOSD_AXIS_LY]);
        joystick->add_item("LZ Axis", "", ITEM_ID_ZAXIS,  get_axis,     &g_input.joy_analog[i][MYOSD_AXIS_LZ]);
        joystick->add_item("RX Axis", "", ITEM_ID_RXAXIS, get_axis,     &g_input.joy_analog[i][MYOSD_AXIS_RX]);
        joystick->add_item("RY Axis", "", ITEM_ID_RYAXIS, get_axis_neg, &g_input.joy_analog[i][MYOSD_AXIS_RY]);
        joystick->add_item("RZ Axis", "", ITEM_ID_RZAXIS, get_axis,     &g_input.joy_analog[i][MYOSD_AXIS_RZ]);
     
        joystick->add_item("A", "", ITEM_ID_BUTTON1, get_button, BTN(joy_status[i], MYOSD_A));
        joystick->add_item("B", "", ITEM_ID_BUTTON2, get_button, BTN(joy_status[i], MYOSD_B));
        joystick->add_item("Y", "", ITEM_ID_BUTTON3, get_button, BTN(joy_status[i], MYOSD_Y));
        joystick->add_item("X", "", ITEM_ID_BUTTON4, get_button, BTN(joy_status[i], MYOSD_X));
        joystick->add_item("L", "", ITEM_ID_BUTTON5, get_button, BTN(joy_status[i], MYOSD_L1));
        joystick->add_item("R", "", ITEM_ID_BUTTON6, get_button, BTN(joy_status[i], MYOSD_R1));
        
        joystick->add_item("L2", "", ITEM_ID_BUTTON7, get_button, BTN(joy_status[i], MYOSD_L2));
        joystick->add_item("R2", "", ITEM_ID_BUTTON8, get_button, BTN(joy_status[i], MYOSD_R2));
        joystick->add_item("L3", "", ITEM_ID_BUTTON9, get_button, BTN(joy_status[i], MYOSD_L3));
        joystick->add_item("R3", "", ITEM_ID_BUTTON10,get_button, BTN(joy_status[i], MYOSD_R3));

        joystick->add_item("Select", "", ITEM_ID_SELECT, get_button, BTN(joy_status[i], MYOSD_SELECT));
        joystick->add_item("Start",  "", ITEM_ID_START,  get_button, BTN(joy_status[i], MYOSD_START));
        
        joystick->add_item("D-Pad Up",    "", ITEM_ID_HAT1UP,    get_button, BTN(joy_status[i], MYOSD_UP));
        joystick->add_item("D-Pad Down",  "", ITEM_ID_HAT1DOWN,  get_button, BTN(joy_status[i], MYOSD_DOWN));
        joystick->add_item("D-Pad Left",  "", ITEM_ID_HAT1LEFT,  get_button, BTN(joy_status[i], MYOSD_LEFT));
        joystick->add_item("D-Pad Right", "", ITEM_ID_HAT1RIGHT, get_button, BTN(joy_status[i], MYOSD_RIGHT));
    }
    
    // mice
    for (int i=0; i<MYOSD_NUM_MICE; i++)
    {
        snprintf(name, sizeof(name)-1, "Mouse %d", i+1);
        input_device* mouse = &machine().input().device_class(DEVICE_CLASS_MOUSE).add_device(name, name);

        mouse->add_item("X Axis", "", ITEM_ID_XAXIS, get_mouse, &g_input.mouse_x[i]);
        mouse->add_item("Y Axis", "", ITEM_ID_YAXIS, get_mouse, &g_input.mouse_y[i]);
        mouse->add_item("Z Axis", "", ITEM_ID_ZAXIS, get_mouse, &g_input.mouse_z[i]);
        mouse->add_item("Left",   "", ITEM_ID_BUTTON1, get_button, BTN(mouse_status[i], MYOSD_A));
        mouse->add_item("Middle", "", ITEM_ID_BUTTON2, get_button, BTN(mouse_status[i], MYOSD_Y));
        mouse->add_item("Right",  "", ITEM_ID_BUTTON3, get_button, BTN(mouse_status[i], MYOSD_B));
    }
    
    // lightgun
    for (int i=0; i<MYOSD_NUM_GUN; i++)
    {
        snprintf(name, sizeof(name)-1, "Lightgun %d", i+1);
        input_device* lightgun = &machine().input().device_class(DEVICE_CLASS_LIGHTGUN).add_device(name, name);
        
        lightgun->add_item("X Axis", "", ITEM_ID_XAXIS, get_axis, &g_input.lightgun_x[i]);
        lightgun->add_item("Y Axis", "", ITEM_ID_YAXIS, get_axis_neg, &g_input.lightgun_y[i]);
        lightgun->add_item("A", "", ITEM_ID_BUTTON1, get_button, BTN(lightgun_status[i], MYOSD_A));
        lightgun->add_item("B", "", ITEM_ID_BUTTON2, get_button, BTN(lightgun_status[i], MYOSD_B));
    }
}

//============================================================
//  exit
//============================================================

void ios_osd_interface::input_exit()
{
    osd_printf_verbose("ios_osd_interface::input_exit\n");
    
    if (m_callbacks.input_exit != NULL)
        m_callbacks.input_exit();
}

//============================================================
//  input init
//============================================================
void input_profile_init(running_machine &machine)
{
    osd_printf_verbose("input_profile_init: %d players=%d safe=%d\n", machine.ioport().ports().size(), machine.ioport().count_players(), machine.ioport().safe_to_read());

    if (machine.ioport().ports().size() == 0)
    {
        // default empty machine
        g_input.num_players = 0;
        g_input.num_coins = 0;
        g_input.num_inputs = 1;
        g_input.num_ways = 4;
        g_input.num_buttons = 0;
        g_input.num_mouse = 0;
        g_input.num_lightgun = 0;
        g_input.num_keyboard = 0;
    }
    else
    {
        // assume an 8way by default, unless we find a 4way
        g_input.num_ways = 8;
        for (auto &port : machine.ioport().ports())
        {
            for (ioport_field &field : port.second->fields())
            {
                if (field.way() == 4)
                    g_input.num_ways = 4;
            }
        }
    
        int way8 = 0;
        g_input.num_buttons = 0;
        g_input.num_lightgun = 0;
        g_input.num_mouse = 0;
        g_input.num_keyboard = 0;
        g_input.num_players = 0;
        g_input.num_coins = 0;
        g_input.num_inputs = 0;

        for (auto &port : machine.ioport().ports())
        {
            osd_printf_verbose("    PORT:%s\n", port.first);

            for (ioport_field &field : port.second->fields())
            {
                osd_printf_verbose("        FIELD:%s player=%d type=%d way=%d\n", field.name(), field.player(), field.type(), field.way());
                
                // walk the input seq and look for highest device/joystick
                if ((field.type() >= IPT_DIGITAL_JOYSTICK_FIRST && field.type() <= IPT_DIGITAL_JOYSTICK_LAST) ||
                    (field.type() >= IPT_BUTTON1 && field.type() <= IPT_BUTTON12))
                {
                    input_seq const seq = field.seq(SEQ_TYPE_STANDARD);
                    for (int i=0; seq[i] != input_seq::end_code; i++)
                    {
                        input_code code = seq[i];
                        if (code.device_index() >= g_input.num_inputs)
                            g_input.num_inputs = code.device_index()+1;
                    }
                }

                // walk the input seq and look for highest analog device/joystick
                if (field.type() >= IPT_ANALOG_FIRST && field.type() <= IPT_ANALOG_LAST)
                {
                    input_seq const seq = field.seq(SEQ_TYPE_STANDARD);
                    for (int i=0; seq[i] != input_seq::end_code; i++)
                    {
                        input_code code = seq[i];
                        if (code.device_class() == DEVICE_CLASS_JOYSTICK && code.device_index() >= g_input.num_inputs)
                            g_input.num_inputs = code.device_index()+1;
                        if (code.device_class() == DEVICE_CLASS_MOUSE && code.device_index() >= g_input.num_mouse)
                            g_input.num_mouse = code.device_index()+1;
                        if (code.device_class() == DEVICE_CLASS_LIGHTGUN && code.device_index() >= g_input.num_lightgun)
                            g_input.num_lightgun = code.device_index()+1;
                    }
                }

                // count the number of COIN buttons.
                if (field.type() == IPT_COIN1 && g_input.num_coins < 1)
                    g_input.num_coins = 1;
                if (field.type() == IPT_COIN2 && g_input.num_coins < 2)
                    g_input.num_coins = 2;
                if (field.type() == IPT_COIN3 && g_input.num_coins < 3)
                    g_input.num_coins = 3;
                if (field.type() == IPT_COIN4 && g_input.num_coins < 4)
                    g_input.num_coins = 4;
                if (field.type() == IPT_SELECT && g_input.num_coins < field.player()+1)
                    g_input.num_coins = field.player()+1;

                // count the number of players, by looking at the number of START buttons.
                if (field.type() == IPT_START1 && g_input.num_players < 1)
                    g_input.num_players = 1;
                if (field.type() == IPT_START2 && g_input.num_players < 2)
                    g_input.num_players = 2;
                if (field.type() == IPT_START3 && g_input.num_players < 3)
                    g_input.num_players = 3;
                if (field.type() == IPT_START4 && g_input.num_players < 4)
                    g_input.num_players = 4;
                if (field.type() == IPT_START && g_input.num_players < field.player()+1)
                    g_input.num_players = field.player()+1;

                if (field.player() != 0)
                    continue;   // only count ways and buttons for Player 1
                
                // count the number of buttons
                if(field.type() == IPT_BUTTON1)
                    if(g_input.num_buttons<1)g_input.num_buttons=1;
                if(field.type() == IPT_BUTTON2)
                    if(g_input.num_buttons<2)g_input.num_buttons=2;
                if(field.type() == IPT_BUTTON3)
                    if(g_input.num_buttons<3)g_input.num_buttons=3;
                if(field.type() == IPT_BUTTON4)
                    if(g_input.num_buttons<4)g_input.num_buttons=4;
                if(field.type() == IPT_BUTTON5)
                    if(g_input.num_buttons<5)g_input.num_buttons=5;
                if(field.type() == IPT_BUTTON6)
                    if(g_input.num_buttons<6)g_input.num_buttons=6;
                if(field.type() == IPT_JOYSTICKRIGHT_UP)//dual stick is mapped as buttons
                    if(g_input.num_buttons<4)g_input.num_buttons=4;
                if(field.type() == IPT_POSITIONAL)//positional is mapped with two last buttons
                    if(g_input.num_buttons<6)g_input.num_buttons=6;
                
                // count the number of ways (joystick directions)
                if(field.type() == IPT_JOYSTICK_UP || field.type() == IPT_JOYSTICK_DOWN || field.type() == IPT_JOYSTICKLEFT_UP || field.type() == IPT_JOYSTICKLEFT_DOWN)
                    way8=1;
                if(field.type() == IPT_AD_STICK_X || field.type() == IPT_LIGHTGUN_X || field.type() == IPT_MOUSE_X ||
                   field.type() == IPT_TRACKBALL_X || field.type() == IPT_PEDAL)
                    way8=1;
                
                // detect if mouse or lightgun input is wanted.
                if (g_input.num_mouse == 0 && (
                    field.type() == IPT_DIAL   || field.type() == IPT_PADDLE   || field.type() == IPT_POSITIONAL   || field.type() == IPT_TRACKBALL_X || field.type() == IPT_MOUSE_X ||
                    field.type() == IPT_DIAL_V || field.type() == IPT_PADDLE_V || field.type() == IPT_POSITIONAL_V || field.type() == IPT_TRACKBALL_Y || field.type() == IPT_MOUSE_Y ))
                    g_input.num_mouse = 1;
                if(g_input.num_lightgun == 0 && field.type() == IPT_LIGHTGUN_X)
                    g_input.num_lightgun = 1;
                if(field.type() == IPT_KEYBOARD)
                    g_input.num_keyboard = 1;
            }
        }

        // 8 if analog or lightgun or up or down
        if (g_input.num_ways != 4) {
            if (way8)
                g_input.num_ways = 8;
            else
                g_input.num_ways = 2;
        }
    }
    
    osd_printf_debug("Num Buttons %d\n",g_input.num_buttons);
    osd_printf_debug("Num WAYS %d\n",g_input.num_ways);
    osd_printf_debug("Num PLAYERS %d\n",g_input.num_players);
    osd_printf_debug("Num COINS %d\n",g_input.num_coins);
    osd_printf_debug("Num INPUTS %d\n",g_input.num_inputs);
    osd_printf_debug("Num MOUSE %d\n",g_input.num_mouse);
    osd_printf_debug("Num GUN %d\n",g_input.num_lightgun);
    osd_printf_debug("Num KEYBOARD %d\n",g_input.num_keyboard);
}

//============================================================
//  update
//============================================================
void ios_osd_interface::input_update(bool relative_reset)
{
    // TODO: handle relative_reset!!
    osd_printf_verbose("ios_osd_interface::input_update relative_reset=%d\n", relative_reset);
    
    // fill in the input profile the first time
    if (g_input.num_ways == 0) {
        
        if (!machine().ioport().safe_to_read())
            return;
        
        input_profile_init(machine());
        
        if (m_callbacks.input_init != NULL)
            m_callbacks.input_init(&g_input, sizeof(g_input));
    }

    bool in_menu = machine().phase() == machine_phase::RUNNING && machine().ui().is_menu_active();

    // determine if we should disable the rest of the UI
    bool has_keyboard = g_input.num_keyboard != 0; // machine_info().has_keyboard();
    
// TODO: need way to get ui_active() state, for NOW just assume ui_active==true
    //mame_ui_manager *ui = dynamic_cast<mame_ui_manager *>(&machine.ui());
    //bool ui_disabled = (has_keyboard && !ui->ui_active());
    bool ui_disabled = (has_keyboard && false);
// TODO: need way to get ui_active() state, for NOW just assume ui_active==true

    // set the current input mode
    g_input.input_mode = in_menu ? MYOSD_INPUT_MODE_MENU : (ui_disabled ? MYOSD_INPUT_MODE_KEYBOARD : MYOSD_INPUT_MODE_NORMAL);

    // and call host
    if (m_callbacks.input_poll != NULL)
        m_callbacks.input_poll(&g_input, sizeof(g_input));
    
    // see if host requested an exit or reset
    if (g_input.keyboard[MYOSD_KEY_EXIT] != 0 && !machine().exit_pending())
        machine().schedule_exit();
    
    if (g_input.keyboard[MYOSD_KEY_RESET] != 0 && !machine().hard_reset_pending())
        machine().schedule_hard_reset();
}

//============================================================
//  check_osd_inputs
//============================================================

void ios_osd_interface::check_osd_inputs()
{
}

//============================================================
//  customize_input_type_list
//============================================================

void ios_osd_interface::customize_input_type_list(std::vector<input_type_entry> &typelist)
{
    // This function is called on startup, before reading the
    // configuration from disk. Scan the list, and change the
    // default control mappings you want. It is quite possible
    // you won't need to change a thing.
    
    osd_printf_verbose("INPUT TYPE LIST\n");

    // loop over the defaults
    for (input_type_entry &entry : typelist) {
        
        osd_printf_verbose("  %s TYPE:%d PLAYER:%d\n", entry.name().c_str(), entry.type(), entry.player());
        
        switch (entry.type())
        {
            /*
            // Retro:  Select + X => UI_CONFIGURE (Menu)
            case IPT_UI_CONFIGURE:
                entry.defseq(SEQ_TYPE_STANDARD).set(KEYCODE_TAB, input_seq::or_code, JOYCODE_SELECT, JOYCODE_BUTTON3);
                break;

            // Retro:  Select + Start => CANCEL
            case IPT_UI_CANCEL:
                entry.defseq(SEQ_TYPE_STANDARD).set(KEYCODE_ESC, input_seq::or_code, JOYCODE_SELECT, JOYCODE_START);
                break;
            */
                    
            // make sure MYOSD_KEY_UIMODE is set right.
            case IPT_UI_TOGGLE_UI:
                _Static_assert(MYOSD_KEY_UIMODE == MYOSD_KEY_SCRLOCK, "");
                entry.defseq(SEQ_TYPE_STANDARD).set(KEYCODE_SCRLOCK, input_seq::not_code, KEYCODE_LSHIFT);
                break;
                
            case IPT_UI_PASTE:
                entry.defseq(SEQ_TYPE_STANDARD).set(KEYCODE_SCRLOCK, KEYCODE_LSHIFT);
                break;

            // allow the DPAD to move the UI
            case IPT_UI_UP:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_HAT1UP;
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_Y_UP_SWITCH;
                break;
            case IPT_UI_DOWN:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_HAT1DOWN;
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_Y_DOWN_SWITCH;
                break;
            case IPT_UI_LEFT:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_HAT1LEFT_INDEXED(0); // JOYCODE_HAT1LEFT
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_X_LEFT_SWITCH;
                break;
            case IPT_UI_RIGHT:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_HAT1RIGHT;
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_X_RIGHT_SWITCH;
                break;
            case IPT_UI_SELECT:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON1;
                break;
            //case IPT_UI_CANCEL:
            case IPT_UI_BACK:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON2;
                break;
                
            /* allow L1 and R1 to move pages in MAME UI */
            case IPT_UI_PAGE_UP:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON5;
                break;
            case IPT_UI_PAGE_DOWN:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON6;
                break;

            /* left joystick, these are mostly the same as MAME defaults, except we add dpad to them */
            case IPT_JOYSTICK_UP:
            case IPT_JOYSTICKLEFT_UP:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_HAT1UP_INDEXED(entry.player());
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_Y_UP_SWITCH_INDEXED(entry.player());
               break;
            case IPT_JOYSTICK_DOWN:
            case IPT_JOYSTICKLEFT_DOWN:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_HAT1DOWN_INDEXED(entry.player());
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_Y_DOWN_SWITCH_INDEXED(entry.player());
               break;
            case IPT_JOYSTICK_LEFT:
            case IPT_JOYSTICKLEFT_LEFT:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_HAT1LEFT_INDEXED(entry.player());
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_X_LEFT_SWITCH_INDEXED(entry.player());
                break;
            case IPT_JOYSTICK_RIGHT:
            case IPT_JOYSTICKLEFT_RIGHT:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_HAT1RIGHT_INDEXED(entry.player());
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_X_RIGHT_SWITCH_INDEXED(entry.player());
                break;

            // right joystick
            case IPT_JOYSTICKRIGHT_UP:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_U_NEG_SWITCH_INDEXED(entry.player());
                break;
            case IPT_JOYSTICKRIGHT_DOWN:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_U_POS_SWITCH_INDEXED(entry.player());
                break;
            case IPT_JOYSTICKRIGHT_RIGHT:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_V_POS_SWITCH_INDEXED(entry.player());
                break;
            case IPT_JOYSTICKRIGHT_LEFT:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_V_NEG_SWITCH_INDEXED(entry.player());
                break;
                
            // analog joystick
            case IPT_AD_STICK_X:
            case IPT_TRACKBALL_X:
            case IPT_LIGHTGUN_X:
            case IPT_PEDAL:
            case IPT_DIAL:
            case IPT_PADDLE:
            case IPT_POSITIONAL:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_X_INDEXED(entry.player());
                entry.defseq(SEQ_TYPE_DECREMENT) |= JOYCODE_HAT1LEFT_INDEXED(entry.player());
                entry.defseq(SEQ_TYPE_INCREMENT) |= JOYCODE_HAT1RIGHT_INDEXED(entry.player());
                break;
            case IPT_AD_STICK_Y:
            case IPT_TRACKBALL_Y:
            case IPT_LIGHTGUN_Y:
            case IPT_DIAL_V:
            case IPT_PADDLE_V:
            case IPT_POSITIONAL_V:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_Y_INDEXED(entry.player());
                entry.defseq(SEQ_TYPE_DECREMENT) |= JOYCODE_HAT1UP_INDEXED(entry.player());
                entry.defseq(SEQ_TYPE_INCREMENT) |= JOYCODE_HAT1DOWN_INDEXED(entry.player());
                break;

            case IPT_AD_STICK_Z:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_Z_INDEXED(entry.player());
                break;

            // A,B,X,Y
            case IPT_BUTTON1:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON1_INDEXED(entry.player());
                break;
            case IPT_BUTTON2:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON2_INDEXED(entry.player());
                break;
            case IPT_BUTTON3:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON3_INDEXED(entry.player());
                break;
            case IPT_BUTTON4:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON4_INDEXED(entry.player());
                break;
            // L,R
            case IPT_BUTTON5:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON5_INDEXED(entry.player());
                break;
            case IPT_BUTTON6:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON6_INDEXED(entry.player());
                break;
            // L2,R2,L3,R3
            case IPT_BUTTON7:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON7_INDEXED(entry.player());
                break;
            case IPT_BUTTON8:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON8_INDEXED(entry.player());
                break;
            case IPT_BUTTON9:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON9_INDEXED(entry.player());
                break;
            case IPT_BUTTON10:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_BUTTON10_INDEXED(entry.player());
                break;
            // Select, Start
            case IPT_SELECT:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_SELECT_INDEXED(entry.player());
                break;
            case IPT_START:
                entry.defseq(SEQ_TYPE_STANDARD) |= JOYCODE_START_INDEXED(entry.player());
                break;

            // leave everything else alone
            default:
                break;
        }
    }
}

//============================================================
//  osd_set_aggressive_input_focus
//============================================================

void osd_set_aggressive_input_focus(bool aggressive_focus)
{
    // dummy implementation for now?
}

//============================================================
//  convert myosd_keycode -> input_item_id
//============================================================

#define LERPKEY(key, key0, key1, item0, item1) \
    _Static_assert((key1 - key0) == ((int)item1 - (int)item0), ""); \
    if (key >= key0 && key <= key1) \
        return (input_item_id)((int)item0 + (key - key0));

#define MAPKEY(key, A, B) \
    LERPKEY(key, MYOSD_KEY_ ## A, MYOSD_KEY_ ## B, ITEM_ID_ ## A, ITEM_ID_ ## B)

static input_item_id key_map(myosd_keycode key)
{
    _Static_assert(MYOSD_KEY_FIRST == MYOSD_KEY_A, "");
    _Static_assert(MYOSD_KEY_LAST  == MYOSD_KEY_CANCEL, "");

    MAPKEY(key, A, F15)         // missing F16-F20
    MAPKEY(key, ESC, ENTER_PAD) // missing BS_PAD, TAB_PAD, 00_PAD, 000_PAD, COMMA_PAD, EQUALS_PAD
    MAPKEY(key, PRTSCR, CANCEL)
    
    return ITEM_ID_INVALID;
}






