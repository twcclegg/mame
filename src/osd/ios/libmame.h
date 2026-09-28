//============================================================
//
//  libmame.h - PUBLIC interface to the LIBMAME core/library
//
//  Copyright (c) 1996-2007, Nicola Salmoria and the MAME Team.
//  Visit http://mamedev.org for licensing and usage restrictions.
//
//  MAME4DROID MAME4iOS by David Valdeita (Seleuco)
//
//  this is the PUBLIC interface used by MAME4iOS to talk to the MAME core
//  for historical reasons this interface is refered to as MYOSD
//  if it makes you feel better, just pretend MYOSD stands for
//  [M]ame e[Y]e[OS] [D]river (aka MAME-iOS-DRIVER)
//
//  FUNCTIONS:
//      myosd_main
//      myosd_get
//      myosd_set
//      myosd_get_memory_share, myosd_get_memory_region,
//      myosd_read_memory, myosd_set/clear_analog_input
//
//============================================================

#include <stddef.h>
#include <stdint.h>

#ifndef __LIBMAME_H__
#define __LIBMAME_H__

#if defined(__cplusplus)
extern "C" {
#endif

enum MYOSD_STATUS {
    MYOSD_UP=0x1,       MYOSD_LEFT=0x4,       MYOSD_DOWN=0x10,   MYOSD_RIGHT=0x40,
    MYOSD_START=1<<8,   MYOSD_SELECT=1<<9,    MYOSD_L1=1<<10,    MYOSD_R1=1<<11,
    MYOSD_A=1<<12,      MYOSD_B=1<<13,        MYOSD_X=1<<14,     MYOSD_Y=1<<15,
    MYOSD_L3=1<<16,     MYOSD_R3=1<<17,       MYOSD_L2=1<<18,    MYOSD_R2=1<<19,
    MYOSD_EXIT=1<<20,   MYOSD_OPTION=1<<21,   MYOSD_HOME=1<<22,  MYOSD_MENU=1<<23,
};

enum MYOSD_AXIS {
    MYOSD_AXIS_LX,
    MYOSD_AXIS_LY,
    MYOSD_AXIS_RX,
    MYOSD_AXIS_RY,
    MYOSD_AXIS_LZ,
    MYOSD_AXIS_RZ,
    MYOSD_AXIS_NUM
};

#define MYOSD_NUM_JOY 4
#define MYOSD_NUM_MICE 4
#define MYOSD_NUM_GUN 4
#define MYOSD_NUM_KEYS 256

// MYOSD INPUT STATE
typedef struct {
    // keyboard
    unsigned char keyboard[MYOSD_NUM_KEYS];

    // joystick(s)
    unsigned long joy_status[MYOSD_NUM_JOY];
    float joy_analog[MYOSD_NUM_JOY][MYOSD_AXIS_NUM];

    // mice
    unsigned long mouse_status[MYOSD_NUM_MICE];
    float mouse_x[MYOSD_NUM_MICE];
    float mouse_y[MYOSD_NUM_MICE];
    float mouse_z[MYOSD_NUM_MICE];

    // lightgun(s)
    unsigned long lightgun_status[MYOSD_NUM_GUN];
    float lightgun_x[MYOSD_NUM_GUN];
    float lightgun_y[MYOSD_NUM_GUN];
    
    // input profile for current machine
    int num_buttons;
    int num_ways;
    int num_players;
    int num_coins;
    int num_inputs;
    int num_mouse;
    int num_lightgun;
    int num_keyboard;
    
    // current input mode
    int input_mode;

}   myosd_input_state;

// myosd input mode
enum myosd_input_mode
{
    MYOSD_INPUT_MODE_NORMAL,
    MYOSD_INPUT_MODE_MENU,
    MYOSD_INPUT_MODE_KEYBOARD
};

// myosd output
enum myosd_output_channel
{
    MYOSD_OUTPUT_ERROR,
    MYOSD_OUTPUT_WARNING,
    MYOSD_OUTPUT_INFO,
    MYOSD_OUTPUT_DEBUG,
    MYOSD_OUTPUT_VERBOSE,
    MYOSD_OUTPUT_LOG,
};

// subset of a internal game_driver structure we pass up to the UI/OSD layer
typedef struct
{
    unsigned int        type;                       /* game type */
    unsigned int        flags;                      /* MYOSD_GAME_INFO_ flags */
    const char *        source_file;                /* set this to __FILE__ */
    const char *        parent;                     /* if this is a clone, the name of the parent */
    const char *        name;                       /* short (16-character) name of the game */
    const char *        description;                /* full name of the game */
    const char *        year;                       /* year the game was released */
    const char *        manufacturer;               /* manufacturer of the game */
    const void *        rom_list;                   /* list of ROMs */
    const void *        input_list;                 /* machine input */
    const char *        software_list;              /* list of software */
} myosd_game_info;

enum MYOSD_GAME_TYPE
{
    MYOSD_GAME_TYPE_ARCADE,       // coin-operated machine for public use
    MYOSD_GAME_TYPE_CONSOLE,      // console system
    MYOSD_GAME_TYPE_COMPUTER,     // any kind of computer including home computers, minis, calculators, ...
    MYOSD_GAME_TYPE_OTHER,        // any other emulated system (e.g. clock, satellite receiver, ...)
};

enum MYOSD_GAME_INFO
{
    MYOSD_GAME_INFO_VERTICAL            = 1<<0,     // vertical video (aka TATE)
    MYOSD_GAME_INFO_NOT_WORKING         = 1<<1,     // not working
    MYOSD_GAME_INFO_IMPERFECT_GRAPHICS  = 1<<2,     // imperfect video
    MYOSD_GAME_INFO_IMPERFECT_SOUND     = 1<<3,     // imperfect sound
    MYOSD_GAME_INFO_BIOS                = 1<<4,     // this driver entry is a BIOS root
    MYOSD_GAME_INFO_SUPPORTS_SAVE       = 1<<5,     // system supports save states
    MYOSD_GAME_INFO_VECTOR              = 1<<6,     // SCREEN is VECTOR
    MYOSD_GAME_INFO_LCD                 = 1<<7,     // SCREEN is LCD
};

// this is copy/clone of the render_primitive in render.h passed up to UI/OSD layer in myosd_video_draw
typedef struct _myosd_render_primitive myosd_render_primitive;
struct _myosd_render_primitive
{
    myosd_render_primitive* next;               /* pointer to next element */
    int                   type;                 /* type of primitive */
//  render_bounds         bounds;               /* bounds or positions */
    float                 bounds_x0;
    float                 bounds_y0;
    float                 bounds_x1;
    float                 bounds_y1;
//  render_color          color;                /* RGBA values */
    float                 color_a;
    float                 color_r;
    float                 color_g;
    float                 color_b;
    union {
        uint32_t          flags;                /* flags */
        struct {
            uint32_t      texorient:4;          /* MYOSD_ORIENTATION_ */
            uint32_t      texformat:4;          /* MYOSD_TEXFORMAT_ */
            uint32_t      blendmode:4;          /* MYOSD_BLENDMODE_ */
            uint32_t      antialias:1;          /* antialias flag */
            uint32_t      screentex:1;          /* SCREEN flag */
            uint32_t      texwrap:1;            /* texture wrap */
            uint32_t      unused:17;
        };
    };
    float                 width;                /* width (for line primitives) */
//  render_texinfo        texture;              /* texture info (for quad primitives) */
    void *                texture_base;         /* base of the data */
    uint32_t              texture_rowpixels;    /* pixels per row */
    uint32_t              texture_width;        /* width of the image */
    uint32_t              texture_height;       /* height of the image */
    const void*           texture_palette;      /* palette for PALETTE16 textures, LUTs for RGB15/RGB32 */
    uint32_t              texture_seqid;        /* sequence ID */
    uint32_t              texture_junk;         /* padding */
//  render_quad_texuv     texcoords;            /* texture coordinates (for quad primitives) */
    struct {float u,v;}   texcoords[4];
};

/* render primitive types */
enum
{
    MYOSD_RENDER_PRIMITIVE_LINE,          /* a single line */
    MYOSD_RENDER_PRIMITIVE_QUAD           /* a rectilinear quad */
};

/* texture formats */
enum
{
    MYOSD_TEXFORMAT_UNDEFINED = 0,        /* require a format to be specified */
    MYOSD_TEXFORMAT_PALETTE16,            /* 16bpp palettized, alpha ignored */
    MYOSD_TEXFORMAT_PALETTEA16,           /* 16bpp palettized, alpha respected */
    MYOSD_TEXFORMAT_RGB15,                /* 16bpp 5-5-5 RGB */
    MYOSD_TEXFORMAT_RGB32,                /* 32bpp 8-8-8 RGB */
    MYOSD_TEXFORMAT_ARGB32,               /* 32bpp 8-8-8-8 ARGB */
    MYOSD_TEXFORMAT_YUY16,                /* 16bpp 8-8 Y/Cb, Y/Cr in sequence */
    MYOSD_TEXFORMAT_MASK = 0x00F0,
};

/* blending modes */
enum : int
{
    MYOSD_BLENDMODE_NONE = 0,             /* no blending */
    MYOSD_BLENDMODE_ALPHA,                /* standard alpha blend */
    MYOSD_BLENDMODE_RGB_MULTIPLY,         /* apply source alpha to source pix, then multiply RGB values */
    MYOSD_BLENDMODE_ADD,                  /* apply source alpha to source pix, then add to destination */
    MYOSD_BLENDMODE_MASK = 0x0F00,
};

/* texorient */
enum
{
    MYOSD_ORIENTATION_FLIP_X  = 0x0001,  /* mirror everything in the X direction */
    MYOSD_ORIENTATION_FLIP_Y  = 0x0002,  /* mirror everything in the Y direction */
    MYOSD_ORIENTATION_SWAP_XY = 0x0004,  /* mirror along the top-left/bottom-right diagonal */
    MYOSD_ORIENTATION_MASK    = 0x000F,

    MYOSD_ORIENTATION_ROT0    = 0,
    MYOSD_ORIENTATION_ROT90   = (MYOSD_ORIENTATION_SWAP_XY | MYOSD_ORIENTATION_FLIP_X),   /* rotate clockwise 90 degrees */
    MYOSD_ORIENTATION_ROT180  = (MYOSD_ORIENTATION_FLIP_X  | MYOSD_ORIENTATION_FLIP_Y),   /* rotate 180 degrees */
    MYOSD_ORIENTATION_ROT270  = (MYOSD_ORIENTATION_SWAP_XY | MYOSD_ORIENTATION_FLIP_Y),   /* rotate counter-clockwise 90 degrees */
};

// MYOSD KEY CODES
enum myosd_keycode
{
    MYOSD_KEY_INVALID,
    MYOSD_KEY_A,
    MYOSD_KEY_B,
    MYOSD_KEY_C,
    MYOSD_KEY_D,
    MYOSD_KEY_E,
    MYOSD_KEY_F,
    MYOSD_KEY_G,
    MYOSD_KEY_H,
    MYOSD_KEY_I,
    MYOSD_KEY_J,
    MYOSD_KEY_K,
    MYOSD_KEY_L,
    MYOSD_KEY_M,
    MYOSD_KEY_N,
    MYOSD_KEY_O,
    MYOSD_KEY_P,
    MYOSD_KEY_Q,
    MYOSD_KEY_R,
    MYOSD_KEY_S,
    MYOSD_KEY_T,
    MYOSD_KEY_U,
    MYOSD_KEY_V,
    MYOSD_KEY_W,
    MYOSD_KEY_X,
    MYOSD_KEY_Y,
    MYOSD_KEY_Z,
    MYOSD_KEY_0,
    MYOSD_KEY_1,
    MYOSD_KEY_2,
    MYOSD_KEY_3,
    MYOSD_KEY_4,
    MYOSD_KEY_5,
    MYOSD_KEY_6,
    MYOSD_KEY_7,
    MYOSD_KEY_8,
    MYOSD_KEY_9,
    MYOSD_KEY_F1,
    MYOSD_KEY_F2,
    MYOSD_KEY_F3,
    MYOSD_KEY_F4,
    MYOSD_KEY_F5,
    MYOSD_KEY_F6,
    MYOSD_KEY_F7,
    MYOSD_KEY_F8,
    MYOSD_KEY_F9,
    MYOSD_KEY_F10,
    MYOSD_KEY_F11,
    MYOSD_KEY_F12,
    MYOSD_KEY_F13,
    MYOSD_KEY_F14,
    MYOSD_KEY_F15,
    MYOSD_KEY_ESC,
    MYOSD_KEY_TILDE,
    MYOSD_KEY_MINUS,
    MYOSD_KEY_EQUALS,
    MYOSD_KEY_BACKSPACE,
    MYOSD_KEY_TAB,
    MYOSD_KEY_OPENBRACE,
    MYOSD_KEY_CLOSEBRACE,
    MYOSD_KEY_ENTER,
    MYOSD_KEY_COLON,
    MYOSD_KEY_QUOTE,
    MYOSD_KEY_BACKSLASH,
    MYOSD_KEY_BACKSLASH2,
    MYOSD_KEY_COMMA,
    MYOSD_KEY_STOP,
    MYOSD_KEY_SLASH,
    MYOSD_KEY_SPACE,
    MYOSD_KEY_INSERT,
    MYOSD_KEY_DEL,
    MYOSD_KEY_HOME,
    MYOSD_KEY_END,
    MYOSD_KEY_PGUP,
    MYOSD_KEY_PGDN,
    MYOSD_KEY_LEFT,
    MYOSD_KEY_RIGHT,
    MYOSD_KEY_UP,
    MYOSD_KEY_DOWN,
    MYOSD_KEY_0_PAD,
    MYOSD_KEY_1_PAD,
    MYOSD_KEY_2_PAD,
    MYOSD_KEY_3_PAD,
    MYOSD_KEY_4_PAD,
    MYOSD_KEY_5_PAD,
    MYOSD_KEY_6_PAD,
    MYOSD_KEY_7_PAD,
    MYOSD_KEY_8_PAD,
    MYOSD_KEY_9_PAD,
    MYOSD_KEY_SLASH_PAD,
    MYOSD_KEY_ASTERISK,
    MYOSD_KEY_MINUS_PAD,
    MYOSD_KEY_PLUS_PAD,
    MYOSD_KEY_DEL_PAD,
    MYOSD_KEY_ENTER_PAD,
    MYOSD_KEY_PRTSCR,
    MYOSD_KEY_PAUSE,
    MYOSD_KEY_LSHIFT,
    MYOSD_KEY_RSHIFT,
    MYOSD_KEY_LCONTROL,
    MYOSD_KEY_RCONTROL,
    MYOSD_KEY_LALT,
    MYOSD_KEY_RALT,
    MYOSD_KEY_SCRLOCK,
    MYOSD_KEY_NUMLOCK,
    MYOSD_KEY_CAPSLOCK,
    MYOSD_KEY_LCMD,
    MYOSD_KEY_RCMD,
    MYOSD_KEY_MENU,
    MYOSD_KEY_CANCEL,
    // special key alias(s)
    MYOSD_KEY_FIRST = MYOSD_KEY_A,
    MYOSD_KEY_LAST = MYOSD_KEY_CANCEL,
    MYOSD_KEY_CONFIGURE = MYOSD_KEY_TAB,
    MYOSD_KEY_SERVICE = MYOSD_KEY_F2,
    MYOSD_KEY_LOADSAVE = MYOSD_KEY_F7,      // LOAD or SAVE
    MYOSD_KEY_SNAP = MYOSD_KEY_F12,         // SNAPSHOT or RECORD
    MYOSD_KEY_UIMODE = MYOSD_KEY_SCRLOCK,
    // special non-mapped keys
    MYOSD_KEY_EXIT,
    MYOSD_KEY_RESET,
};

// myosd_get and myosd_set - get and set global state from the MAME driver.

enum {
    MYOSD_VERSION,              // GET: MAME version number (ie 139 or 229)
    MYOSD_VERSION_STRING,       // GET: MAME version string (ie "0.139u1 (date)")
    MYOSD_DISPLAY_WIDTH,        // SET: maximum width and height of "screen" to display
    MYOSD_DISPLAY_HEIGHT,
    MYOSD_FPS,                  // GET, SET: show framerate
    MYOSD_SPEED,                // GET, SET: emulation speed (100 = 100%)
};
extern intptr_t myosd_get(int var);
extern void myosd_set(int var, intptr_t value);

// a finished frame for the video_draw_pixels callback
typedef struct {
    const uint32_t* pixels;     // 32-bit 0x--RRGGBB (MTLPixelFormatBGRA8Unorm in memory), alpha byte undefined
    int width;                  // framebuffer size in pixels: source_width/height times an integer scale
    int height;
    int pitch;                  // row stride in pixels
    int source_width;           // the machine's native resolution (e.g. 224x288 for Pac-Man);
    int source_height;          //   pixels are integer multiples of this, for scanline/mask effects
    float aspect;               // intended display aspect ratio (width / height); pixels need not be square
} myosd_video_frame;            // only valid for the duration of the callback

// passed to the machine_frame callback, once per emulated frame
typedef struct {
    uint64_t frame_number;      // frame counter of the machine's first screen (0 if it has none)
    int skipped;                // 1 if this frame will not be drawn (frameskip); state is still valid
    int paused;                 // 1 while the emulation is paused (the same frame repeats)
} myosd_frame_info;

// MYOSD app callback functions
typedef struct {

    void (*output_init)(void);
    void (*output_text)(int channel, const char* text);
    void (*output_exit)(void);

    void (*game_init)(myosd_game_info *info);
    void (*game_list)(myosd_game_info *games, int count);
    void (*game_exit)(void);
    
    void (*video_init)(int width, int height, int min_width, int min_height);
    void (*video_draw)(myosd_render_primitive* prim_list, int width, int height);
    void (*video_exit)(void);

    void (*input_init)(myosd_input_state* input, size_t state_size);
    void (*input_poll)(myosd_input_state* input, size_t state_size);
    void (*input_exit)(void);

    void (*sound_init)(int rate, int stereo);
    void (*sound_play)(void *buff, int len);
    void (*sound_exit)(void);

    // OPTIONAL (added for the visionOS port, keep at the end for ABI compatibility):
    // if set, MAME rasterizes each frame itself with its software renderer and
    // passes the result here instead of calling video_draw.  See myosd_video_frame.
    void (*video_draw_pixels)(const myosd_video_frame* frame);

    // OPTIONAL (appended after video_draw_pixels, keep at the end for ABI compatibility):
    // called on the MAME thread once per emulated frame while a game runs,
    // after the machine has produced the frame and before it is drawn (also
    // on skipped frames and with -video none).  The emulated CPUs are stopped
    // for the duration, so this is the place to read machine state with the
    // myosd_*_memory functions below and get a consistent snapshot, and to
    // set analog inputs for the next frame.  Keep it short: the emulation
    // waits for it.
    void (*machine_frame)(const myosd_frame_info* info);

}   myosd_callbacks;

// main entry point
extern int myosd_main(int argc, char** argv, myosd_callbacks* callbacks, size_t callbacks_size);

//============================================================
//  machine state access (added for the visionOS port)
//
//  Lets a host read emulated memory and drive analog inputs, e.g. to present
//  a game's state differently (a 3D playfield built from video RAM).
//
//  THREADING: only call these on the MAME thread, from inside a callback
//  (machine_frame is the intended one; input_poll and video_draw* also
//  work).  Outside a running game (no machine, or during startup/exit) they
//  fail harmlessly.
//
//  TAGS are MAME device paths.  A leading ':' is optional; ":maincpu",
//  "maincpu", ":videoram" and "videoram" all work.  Shares and regions are
//  named in the driver's address map / ROM definitions
//  (e.g. map(0xe000, 0xe7ff).ram().share("videoram")).
//============================================================

// a block of emulated memory (a memory share or a ROM/memory region)
typedef struct {
    void*    base;              // live pointer into the emulated machine's memory
    size_t   bytes;             // size in bytes
    int      bitwidth;          // width of the memory: 8, 16, 32 or 64
    int      big_endian;        // 1 if multi-byte units are stored big-endian
} myosd_memory_block;

// address spaces for myosd_read_memory (same numbering as MAME's AS_*)
enum {
    MYOSD_AS_PROGRAM = 0,
    MYOSD_AS_DATA    = 1,
    MYOSD_AS_IO      = 2,
    MYOSD_AS_OPCODES = 3,
};

// Look up a memory share (RAM declared with .share("name") in an address map).
// On success fills *block and returns 0; returns -1 if there is no running
// machine or no such share.  block->base stays valid, and keeps tracking the
// live contents, until the game exits (game_exit callback); reading it from
// another thread is possible but gives no consistency guarantee.
extern int myosd_get_memory_share(const char* tag, myosd_memory_block* block);

// Same for a memory region (usually ROM, e.g. "maincpu" or "gfx1").
extern int myosd_get_memory_region(const char* tag, myosd_memory_block* block);

// Look up a variable a device registered for save states (save_item), e.g.
// myosd_get_state_item(":", "m_flip_screen_x", &b) for the driver's flip
// flag.  This reaches state that lives in no memory share, such as
// write-only registers the driver latches into member variables.  `name` is
// the registered name (the member name for save_item(NAME(m_x))).  Stored in
// host byte order.  Returns 0 and fills *block, or -1.  Same lifetime as
// myosd_get_memory_share.  Save-item names are internal to each driver and
// may change between MAME versions.
extern int myosd_get_state_item(const char* device_tag, const char* name, myosd_memory_block* block);

// Read `length` bytes from a device's address space, as the CPU would see
// them, starting at `address`, into `buffer`.  Uses MAME's debugger
// convention (side effects disabled), so reading I/O ports does not
// acknowledge interrupts, pop FIFOs and so on, as far as each device honours
// it.  Addresses are byte addresses and wrap at the end of the space; spaces
// that aren't byte-addressed (address shift != 0) are refused.  Returns the
// number of bytes read: `length` on success, 0 on failure.
extern size_t myosd_read_memory(const char* device_tag, int spacenum, uint32_t address, void* buffer, size_t length);

// Override the value an analog input field reads (a dial, paddle, pedal,
// ...), replacing whatever the mapped controls would produce.  `port_tag` is
// the input port (e.g. ":P1"), `mask` selects the field in it (e.g. 0xff),
// and `value` is the raw field value, clamped to the field's range.  For a
// relative control such as a dial, the host keeps its own counter and
// sets it here, e.g. to move a paddle to an absolute position in a closed
// loop.  The override lasts until myosd_clear_analog_input.  Returns 0, or -1
// if there is no such analog field.
extern int myosd_set_analog_input(const char* port_tag, uint32_t mask, int32_t value);
extern int myosd_clear_analog_input(const char* port_tag, uint32_t mask);

#if defined(__cplusplus)
}
#endif

#endif
