#ifndef _iososd_h_
#define _iososd_h_

#include "modules/lib/osdobj_common.h"
#include "modules/osdmodule.h"
#include "modules/font/font_module.h"
#include "../frontend/mame/ui/menuitem.h"

#include "libmame.h"

#include "geomexport.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

//============================================================
//  ios_geometry_sink - collects the 3D geometry drivers export
//  during a frame (src/emu/geomexport.h) for the host's
//  geometry_frame callback
//============================================================

class ios_geometry_sink : public emu::geometry_export::sink
{
public:
    virtual void polygons(const emu::geometry_export::projection &proj, const emu::geometry_export::polygon *polys, std::size_t count) override
    {
        batch &b = m_batches.emplace_back();
        b.proj = proj;
        b.polys.reserve(count);
        for (std::size_t i = 0; i < count; i++)
        {
            const emu::geometry_export::polygon &in = polys[i];
            myosd_polygon &out = b.polys.emplace_back();
            for (int j = 0; j < 4; j++)
                out.v[j] = myosd_vertex{ in.v[j].x, in.v[j].y, in.v[j].z };
            out.count = in.count;
            out.rgb = in.rgb;
            out.flags = ((in.flags & emu::geometry_export::POLY_FLAG_MOIRE) ? MYOSD_POLY_MOIRE : 0)
                    | ((in.flags & emu::geometry_export::POLY_FLAG_WIREFRAME) ? MYOSD_POLY_WIREFRAME : 0);
            out.sort_z = in.sort_z;
        }
    }

    virtual bool suppress_native_rendering() const override { return m_suppress; }
    void set_suppress(bool suppress) { m_suppress = suppress; }

    // hand everything collected since the last call to the host, then clear
    void send(void (*callback)(const myosd_geometry_frame *))
    {
        std::vector<myosd_geometry_batch> out;
        out.reserve(m_batches.size());
        for (const batch &b : m_batches)
        {
            myosd_geometry_batch &o = out.emplace_back();
            o.center_x = b.proj.center_x;
            o.center_y = b.proj.center_y;
            o.scale_x = b.proj.scale_x;
            o.scale_y = b.proj.scale_y;
            o.offset_x = b.proj.offset_x;
            o.offset_y = b.proj.offset_y;
            o.clip_min_x = b.proj.clip_min_x;
            o.clip_min_y = b.proj.clip_min_y;
            o.clip_max_x = b.proj.clip_max_x;
            o.clip_max_y = b.proj.clip_max_y;
            o.screen_width = b.proj.screen_width;
            o.screen_height = b.proj.screen_height;
            o.polygons = b.polys.data();
            o.count = int(b.polys.size());
        }
        myosd_geometry_frame frame;
        frame.batches = out.data();
        frame.count = int(out.size());
        callback(&frame);
        m_batches.clear();
    }

private:
    struct batch
    {
        emu::geometry_export::projection proj;
        std::vector<myosd_polygon> polys;
    };
    std::vector<batch> m_batches;
    bool m_suppress = false;
};

//============================================================
// DebugLog
//============================================================
#define DebugLog 0
#if DebugLog == 0
#define osd_printf_debug(...) (void)0
#endif
#if DebugLog <= 1
#define osd_printf_verbose(...) (void)0
#endif

//============================================================
// MYOSD globals
//============================================================
extern int myosd_display_width;
extern int myosd_display_height;
extern std::atomic<int> myosd_pause_request;
extern std::atomic<bool> myosd_host_paused;
extern std::atomic<int> myosd_zoom_request;
extern std::atomic<bool> myosd_zoom_to_screen;
extern std::atomic<bool> myosd_suppress_native_3d;
extern std::atomic<int> myosd_throttle_request;
extern std::atomic<bool> myosd_throttled;
extern std::mutex myosd_state_request_lock;
extern std::string myosd_state_request;
extern bool myosd_state_request_save;

// the running machine, between osd init() and machine exit (state.cpp)
extern running_machine *g_ios_machine;

//============================================================
//  OPTIONS
//============================================================

#define OPTION_HISCORE  "hiscore"
#define OPTION_BEAM     "beam"
#define OPTION_BENCH    "bench"
#define OPTION_SOUND    "sound"
#define OPTION_VIDEO    "video"
#define OPTION_NUMPROCESSORS "numprocessors"

//============================================================
//  TYPE DEFINITIONS
//============================================================

// forward references
class input_type_entry;
namespace osd { class midi_input_port; class midi_output_port; }
namespace ui { class menu_item; }

class ios_osd_interface : public osd_interface, osd_output
{
public:
	// construction/destruction
	ios_osd_interface(emu_options &options, myosd_callbacks &callbacks);
	virtual ~ios_osd_interface();

    // general overridables
    virtual void init(running_machine &machine) override;
    virtual void update(bool skip_redraw) override;
    virtual void input_update(bool relative_reset) override;
    virtual void check_osd_inputs() override;
    virtual void set_verbose(bool verbose) override { m_verbose = verbose; }

    // debugger overridables
    virtual void init_debugger() override {}
    virtual void wait_for_debugger(device_t &device, bool firststop) override {}

    // audio overridables
    virtual bool no_sound() override;
    virtual bool sound_external_per_channel_volume() override;
    virtual bool sound_split_streams_per_source() override;
    virtual uint32_t sound_get_generation() override;
    virtual osd::audio_info sound_get_information() override;
    virtual uint32_t sound_stream_sink_open(uint32_t node, std::string name, uint32_t rate) override;
    virtual uint32_t sound_stream_source_open(uint32_t node, std::string name, uint32_t rate) override;
    virtual void sound_stream_close(uint32_t id) override;
    virtual void sound_stream_sink_update(uint32_t id, const int16_t *buffer, int samples_this_frame) override;
    virtual void sound_stream_source_update(uint32_t id, int16_t *buffer, int samples_this_frame) override;
    virtual void sound_stream_set_volumes(uint32_t id, const std::vector<float> &db) override;
    virtual void sound_begin_update() override;
    virtual void sound_end_update() override;    

    // input overridables
    virtual void customize_input_type_list(std::vector<input_type_entry> &typelist) override;

    // video overridables
    virtual void add_audio_to_recording(const int16_t *buffer, int samples_this_frame) override {}
    virtual std::vector<ui::menu_item> get_slider_list() override {
        return std::vector<ui::menu_item>();
    }

    // font interface
    virtual osd_font::ptr font_alloc() override { return nullptr; }
    virtual bool get_font_families(std::string const &font_path, std::vector<std::pair<std::string, std::string> > &result) override { return false; }

    // command option overrides
    virtual bool execute_command(const char *command) override {return true;}

    // midi interface
    virtual std::unique_ptr<osd::midi_input_port> create_midi_input(std::string_view name) override {return nullptr;}
    virtual std::unique_ptr<osd::midi_output_port> create_midi_output(std::string_view name) override {return nullptr;}
    virtual std::vector<osd::midi_port_info> list_midi_ports() override { return std::vector<osd::midi_port_info>(); }
    
    // osd_output
    virtual void output_callback(osd_output_channel channel, const util::format_argument_pack<char> &args) override;
    
    // network
    virtual std::unique_ptr<osd::network_device> open_network_device(int id, osd::network_handler &handler) override { return nullptr; }
    virtual std::vector<osd::network_device_info> list_network_devices() override { return std::vector<osd::network_device_info>(); }

    // getters
    running_machine &machine() const { assert(m_machine != nullptr); return *m_machine; }
    render_target *target() const { assert(m_target != nullptr); return m_target; }
    void apply_host_requests();
    void send_geometry();
    emu_options &options() { return m_options; }

private:
    void video_init();
    void video_exit();
    
    void input_init();
    void input_exit();

    void sound_init();
    void sound_exit();

    void machine_exit();

    // internal state
    running_machine *m_machine;
    emu_options &m_options;
    bool m_verbose;

    // video
    render_target * m_target;
    int m_min_width, m_min_height;
    int m_vis_width, m_vis_height;
    int m_video_none;
    std::vector<uint32_t> m_pixels;         // framebuffer for video_draw_pixels
    std::unique_ptr<class ios_geometry_sink> m_geometry_sink; // forwards driver geometry to geometry_frame

    // audio
    int m_attenuation;
    int m_sample_rate;

    // host ios app callbacks
    myosd_callbacks m_callbacks;
};

//============================================================
//  work.cpp
//============================================================

extern int osd_num_processors;

#endif
