// license:BSD-3-Clause
//============================================================
//
//  state.cpp - libmame machine state access for the host app
//
//  Lets the host read emulated memory (shares, regions, address
//  spaces) and override analog inputs.  Only valid on the MAME
//  thread, from inside a myosd callback; see libmame.h.
//
//============================================================

// MAME headers
#include "emu.h"
#include "emumem.h"
#include "ioport.h"

// IOS headers
#include "iososd.h"

running_machine *g_ios_machine = nullptr;

//============================================================
//  helpers
//============================================================

// the running machine, if it's far enough along for its memory and
// input ports to exist, and not being torn down
static running_machine *state_machine()
{
    running_machine *const machine = g_ios_machine;
    if (machine == nullptr)
        return nullptr;
    machine_phase const phase = machine->phase();
    if (phase != machine_phase::RESET && phase != machine_phase::RUNNING)
        return nullptr;
    return machine;
}

static int fill_block(myosd_memory_block *block, void *base, size_t bytes, int bitwidth, endianness_t endian)
{
    if (base == nullptr)
        return -1;
    block->base = base;
    block->bytes = bytes;
    block->bitwidth = bitwidth;
    block->big_endian = (endian == ENDIANNESS_BIG) ? 1 : 0;
    return 0;
}

static analog_field *find_analog(running_machine &machine, const char *port_tag, uint32_t mask)
{
    // ports are keyed by their full path (":P1"); accept "P1" too
    auto const found = machine.ioport().ports().find(machine.root_device().subtag(port_tag));
    if (found == machine.ioport().ports().end())
        return nullptr;
    for (ioport_field &field : found->second->fields())
        if (field.mask() == mask && field.is_analog() && field.live().analog != nullptr)
            return field.live().analog;
    return nullptr;
}

//============================================================
//  myosd_get_memory_share / myosd_get_memory_region
//============================================================

extern "C" int myosd_get_memory_share(const char *tag, myosd_memory_block *block)
{
    running_machine *const machine = state_machine();
    if (machine == nullptr || tag == nullptr || block == nullptr)
        return -1;
    memory_share *const share = machine->root_device().memshare(tag);
    if (share == nullptr)
        return -1;
    return fill_block(block, share->ptr(), share->bytes(), share->bitwidth(), share->endianness());
}

extern "C" int myosd_get_memory_region(const char *tag, myosd_memory_block *block)
{
    running_machine *const machine = state_machine();
    if (machine == nullptr || tag == nullptr || block == nullptr)
        return -1;
    memory_region *const region = machine->root_device().memregion(tag);
    if (region == nullptr)
        return -1;
    return fill_block(block, region->base(), region->bytes(), region->bitwidth(), region->endianness());
}

//============================================================
//  myosd_get_state_item
//============================================================

extern "C" int myosd_get_state_item(const char *device_tag, const char *name, myosd_memory_block *block)
{
    running_machine *const machine = state_machine();
    if (machine == nullptr || device_tag == nullptr || name == nullptr || block == nullptr)
        return -1;

    // entries are named "<module>/<tag>/<index>/<name>" (see save_manager::save_memory)
    std::string const tag = std::string("/") + machine->root_device().subtag(device_tag) + "/";
    std::string const suffix = std::string("/") + name;
    save_manager &save = machine->save();
    for (int i = 0; i < save.registration_count(); i++)
    {
        void *base;
        u32 valsize, valcount, blockcount, stride;
        const char *const entry = save.indexed_item(i, base, valsize, valcount, blockcount, stride);
        if (entry == nullptr)
            continue;
        std::string_view const full(entry);
        if (full.size() <= suffix.size() || full.substr(full.size() - suffix.size()) != suffix || full.find(tag) == std::string_view::npos)
            continue;
        // only the first block of a strided array is contiguous
        size_t const bytes = size_t(valsize) * valcount * ((blockcount > 1 && stride == valcount) ? blockcount : 1);
        return fill_block(block, base, bytes, valsize * 8, ENDIANNESS_NATIVE);
    }
    return -1;
}

//============================================================
//  myosd_read_memory
//============================================================

extern "C" size_t myosd_read_memory(const char *device_tag, int spacenum, uint32_t address, void *buffer, size_t length)
{
    running_machine *const machine = state_machine();
    if (machine == nullptr || device_tag == nullptr || buffer == nullptr)
        return 0;
    static_assert(MYOSD_AS_PROGRAM == AS_PROGRAM && MYOSD_AS_DATA == AS_DATA && MYOSD_AS_IO == AS_IO && MYOSD_AS_OPCODES == AS_OPCODES);

    device_t *const device = machine->root_device().subdevice(device_tag);
    device_memory_interface *memory = nullptr;
    if (device == nullptr || !device->interface(memory) || !memory->has_space(spacenum))
        return 0;

    address_space &space = memory->space(spacenum);
    if (space.addr_shift() != 0)
        return 0;

    // the debugger's way: devices are asked not to change state on these reads
    auto dis = machine->disable_side_effects();
    uint8_t *const dst = static_cast<uint8_t *>(buffer);
    offs_t const mask = space.addrmask();
    for (size_t i = 0; i < length; i++)
        dst[i] = space.read_byte((address + offs_t(i)) & mask);
    return length;
}

//============================================================
//  myosd_set_analog_input / myosd_clear_analog_input
//============================================================

extern "C" int myosd_set_analog_input(const char *port_tag, uint32_t mask, int32_t value)
{
    running_machine *const machine = state_machine();
    if (machine == nullptr || port_tag == nullptr)
        return -1;
    analog_field *const analog = find_analog(*machine, port_tag, mask);
    if (analog == nullptr)
        return -1;
    analog->set_value(value);
    return 0;
}

extern "C" int myosd_clear_analog_input(const char *port_tag, uint32_t mask)
{
    running_machine *const machine = state_machine();
    if (machine == nullptr || port_tag == nullptr)
        return -1;
    analog_field *const analog = find_analog(*machine, port_tag, mask);
    if (analog == nullptr)
        return -1;
    analog->clear_value();
    return 0;
}
