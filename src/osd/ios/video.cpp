
//============================================================
//
//  video.c - IOS video handling
//
//============================================================

// MAME headers
#include "emu.h"
#include "drivenum.h"
#include "screen.h"
#include "render.h"
#include "rendlay.h"
#include "ui/uimain.h"
#include "rendersw.hxx"

// IOS headers
#include "iososd.h"

#define MIN(a,b) ((a)<(b) ? (a) : (b))
#define MAX(a,b) ((a)<(b) ? (b) : (a))

//============================================================
//  video_init
//============================================================

void ios_osd_interface::video_init()
{
    osd_printf_verbose("ios_osd_interface::video_init\n");

    // create our *single* render target, we dont do multiple windows or monitors
    m_target = machine().render().target_alloc();
    
    m_video_none = strcmp(options().value(OPTION_VIDEO), "none") == 0;

    m_min_width = 0;
    m_min_height = 0;
    m_vis_width = 0;
    m_vis_height = 0;

    // collect exported 3D geometry only if the host wants it
    if (m_callbacks.geometry_frame != NULL)
    {
        m_geometry_sink = std::make_unique<ios_geometry_sink>();
        emu::geometry_export::set_sink(m_geometry_sink.get());
    }
}

//============================================================
//  video_exit
//============================================================

void ios_osd_interface::video_exit()
{
    osd_printf_verbose("ios_osd_interface::video_exit\n");
    
    // free the render target
    machine().render().target_free(m_target);
    m_target = nullptr;

    if (m_geometry_sink)
    {
        emu::geometry_export::set_sink(nullptr);
        m_geometry_sink.reset();
    }
    
    if (m_callbacks.video_exit != NULL)
        m_callbacks.video_exit();
}

//============================================================
//  convert render_primitive to myosd_render_primitive
//============================================================
static void convert_prim(myosd_render_primitive &myosd_prim, const render_primitive &prim)
{
    myosd_prim.type = (prim.type-1);
    _Static_assert(MYOSD_RENDER_PRIMITIVE_LINE == render_primitive::primitive_type::LINE-1, "");
    _Static_assert(MYOSD_RENDER_PRIMITIVE_QUAD == render_primitive::primitive_type::QUAD-1, "");

    myosd_prim.bounds_x0 = prim.bounds.x0;
    myosd_prim.bounds_y0 = prim.bounds.y0;
    myosd_prim.bounds_x1 = prim.bounds.x1;
    myosd_prim.bounds_y1 = prim.bounds.y1;
    myosd_prim.color_a = prim.color.a;
    myosd_prim.color_r = prim.color.r;
    myosd_prim.color_g = prim.color.g;
    myosd_prim.color_b = prim.color.b;

    static int map_fmt[] = {MYOSD_TEXFORMAT_UNDEFINED, MYOSD_TEXFORMAT_PALETTE16, MYOSD_TEXFORMAT_RGB32, MYOSD_TEXFORMAT_ARGB32, MYOSD_TEXFORMAT_YUY16};
    _Static_assert(TEXFORMAT_UNDEFINED == 0, "");
    _Static_assert(TEXFORMAT_PALETTE16 == 1, "");
    _Static_assert(TEXFORMAT_RGB32     == 2, "");
    _Static_assert(TEXFORMAT_ARGB32    == 3, "");
    _Static_assert(TEXFORMAT_YUY16     == 4, "");
    myosd_prim.texformat = map_fmt[PRIMFLAG_GET_TEXFORMAT(prim.flags)];
    
    myosd_prim.texorient = PRIMFLAG_GET_TEXORIENT(prim.flags);
    _Static_assert(MYOSD_ORIENTATION_FLIP_X == ORIENTATION_FLIP_X, "");
    _Static_assert(MYOSD_ORIENTATION_FLIP_Y == ORIENTATION_FLIP_Y, "");
    _Static_assert(MYOSD_ORIENTATION_SWAP_XY == ORIENTATION_SWAP_XY, "");

    myosd_prim.blendmode = PRIMFLAG_GET_BLENDMODE(prim.flags);
    _Static_assert(MYOSD_BLENDMODE_NONE == +BLENDMODE_NONE, "");
    _Static_assert(MYOSD_BLENDMODE_ALPHA == +BLENDMODE_ALPHA, "");
    _Static_assert(MYOSD_BLENDMODE_RGB_MULTIPLY == +BLENDMODE_RGB_MULTIPLY, "");
    _Static_assert(MYOSD_BLENDMODE_ADD == +BLENDMODE_ADD, "");

    myosd_prim.antialias = PRIMFLAG_GET_ANTIALIAS(prim.flags);
    myosd_prim.screentex = PRIMFLAG_GET_SCREENTEX(prim.flags);
    myosd_prim.texwrap   = PRIMFLAG_GET_TEXWRAP(prim.flags);
    myosd_prim.unused    = 0;
    
    // TODO: what are these?
    PRIMFLAG_GET_TEXSHADE(prim.flags);
    PRIMFLAG_GET_VECTOR(prim.flags);
    PRIMFLAG_GET_VECTORBUF(prim.flags);
    
    myosd_prim.width = prim.width;
    myosd_prim.texture_base = prim.texture.base;
    myosd_prim.texture_rowpixels = prim.texture.rowpixels;
    myosd_prim.texture_width = prim.texture.width;
    myosd_prim.texture_height = prim.texture.height;
    myosd_prim.texture_palette = prim.texture.palette;
    myosd_prim.texture_seqid = prim.texture.seqid;
    
    // TODO: what is unique_id?? how is it different from seqid?
    prim.texture.unique_id;
    
    myosd_prim.texcoords[0].u = prim.texcoords.tl.u;
    myosd_prim.texcoords[0].v = prim.texcoords.tl.v;
    myosd_prim.texcoords[1].u = prim.texcoords.tr.u;
    myosd_prim.texcoords[1].v = prim.texcoords.tr.v;
    myosd_prim.texcoords[2].u = prim.texcoords.bl.u;
    myosd_prim.texcoords[2].v = prim.texcoords.bl.v;
    myosd_prim.texcoords[3].u = prim.texcoords.br.u;
    myosd_prim.texcoords[3].v = prim.texcoords.br.v;
}

//============================================================
//  apply_host_requests - myosd_set requests that must run on
//  the MAME thread (update() is called every frame, and keeps
//  being called while the machine is paused)
//============================================================

void ios_osd_interface::apply_host_requests()
{
    int const pause = myosd_pause_request.exchange(-1);
    if (pause == 1 && !myosd_host_paused)
    {
        // only take ownership of the pause if the machine wasn't already paused
        // (by the user, or a MAME menu), so resuming doesn't undo theirs
        bool const was_paused = machine().paused();
        if (!was_paused)
            machine().pause();
        myosd_host_paused = !was_paused;
        // the app may be killed while in the background: keep NVRAM (high scores etc.)
        machine().nvram_save();
    }
    else if (pause == 0 && myosd_host_paused)
    {
        myosd_host_paused = false;
        machine().resume();
    }

    int const zoom = myosd_zoom_request.exchange(-1);
    if (zoom >= 0 && m_target != nullptr)
    {
        target()->set_zoom_to_screen(zoom != 0);
        myosd_zoom_to_screen = zoom != 0;
    }
}

//============================================================
//  send_geometry - pass this frame's exported 3D geometry
//  (collected while the driver drew the screen) to the host
//============================================================

void ios_osd_interface::send_geometry()
{
    if (!m_geometry_sink)
        return;
    m_geometry_sink->set_suppress(myosd_suppress_native_3d);
    m_geometry_sink->send(m_callbacks.geometry_frame);
}

//============================================================
//  update
//============================================================

void ios_osd_interface::update(bool skip_redraw)
{
    osd_printf_verbose("ios_osd_interface::update\n");

    apply_host_requests();

    // let the host look at the machine's state once per emulated frame,
    // whether or not this frame gets drawn (see libmame.h)
    if (m_callbacks.machine_frame != NULL && machine().phase() == machine_phase::RUNNING &&
        &machine().system() != &GAME_NAME(___empty))
    {
        screen_device *const screen = screen_device_enumerator(machine().root_device()).first();
        myosd_frame_info info;
        info.frame_number = (screen != nullptr) ? screen->frame_number() : 0;
        info.skipped = skip_redraw ? 1 : 0;
        info.paused = machine().paused() ? 1 : 0;
        m_callbacks.machine_frame(&info);
    }

    send_geometry();

    // if skipping this redraw, bail
    if (skip_redraw || (m_callbacks.video_draw == NULL && m_callbacks.video_draw_pixels == NULL) || m_video_none)
        return;
    
    int vis_width, vis_height;
    int min_width, min_height;
    target()->compute_minimum_size(min_width, min_height);
    target()->compute_visible_area(MAX(640,myosd_display_width), MAX(480,myosd_display_height), 1.0, target()->orientation(), vis_width, vis_height);
     
    // check for a change in the min-size of render target *or* size of the vis screen
    if (min_width != m_min_width || min_height != m_min_height ||
        vis_width != m_vis_width || vis_height != m_vis_height) {
        
        m_min_width = min_width;
        m_min_height = min_height;
        m_vis_width = vis_width;
        m_vis_height = vis_height;
        
        if (m_callbacks.video_init != NULL)
            m_callbacks.video_init(vis_width, vis_height, min_width, min_height);
    }

    // host wants a finished frame: rasterize with MAME's software renderer at
    // the machine's native resolution times an integer scale (so the host's
    // scanline/mask shaders line up with real pixels, and MAME's own menus stay
    // legible), with non-square pixels so the layout fills the whole frame.
    if (m_callbacks.video_draw_pixels != NULL)
    {
        int src_width = min_width, src_height = min_height;
        if (src_width <= 0 || src_height <= 0)
        {
            src_width = vis_width;
            src_height = vis_height;
        }
        int const scale = MAX(1, MIN(MAX(640, myosd_display_width) / src_width, MAX(480, myosd_display_height) / src_height));
        int const width = src_width * scale, height = src_height * scale;
        float const aspect = float(vis_width) / float(vis_height);

        // pixel_aspect is pixel width / pixel height
        target()->set_bounds(width, height, aspect * float(height) / float(width));
        render_primitive_list &prims = target()->get_primitives();

        size_t const count = size_t(width) * size_t(height);
        if (m_pixels.size() < count)
            m_pixels.resize(count);

        prims.acquire_lock();
        software_renderer<uint32_t, 0,0,0, 16,8,0>::draw_primitives(prims, m_pixels.data(), width, height, width);
        prims.release_lock();

        myosd_video_frame frame;
        frame.pixels = m_pixels.data();
        frame.width = width;
        frame.height = height;
        frame.pitch = width;
        frame.source_width = src_width;
        frame.source_height = src_height;
        frame.aspect = aspect;
        m_callbacks.video_draw_pixels(&frame);
        return;
    }

    target()->set_bounds(vis_width, vis_height, 1.0);
    render_primitive_list *primlist = &target()->get_primitives();

    primlist->acquire_lock();

    // TODO: is 4K enough? make dynamic?
    static myosd_render_primitive myosd_prim[4096];
    int i = 0;
    
    // convert from render_primitive(s) to myosd_render_primitive(s)
    for (render_primitive &prim : *primlist)
    {
        if (i == sizeof(myosd_prim)/sizeof(myosd_prim[0]))
            break;

        convert_prim(myosd_prim[i], prim);
        myosd_prim[i].next = &myosd_prim[i+1];
        i++;
    }
    if (i > 0)
        myosd_prim[i-1].next = NULL;

    m_callbacks.video_draw(i > 0 ? myosd_prim : NULL, vis_width, vis_height);

    primlist->release_lock();
}


