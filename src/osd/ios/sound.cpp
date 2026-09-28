//============================================================
//
//  sound.cpp - iOS sound handling
//
//============================================================

// MAME headers
#include "emu.h"

// iOS headers
#include "iososd.h"

// Audio interface headers
#include "interface/audio.h"

#include <memory>
#include <map>
#include <mutex>
#include <atomic>

static void myosd_sound_init(int rate, int stereo);
static void myosd_sound_play(void *buff, int len);
static void myosd_sound_exit(void);

namespace osd {

std::string channel_position::name() const
{
    if (*this == FC()) return "FC";
    if (*this == FL()) return "FL";
    if (*this == FR()) return "FR";
    if (*this == RC()) return "RC";
    if (*this == RL()) return "RL";
    if (*this == RR()) return "RR";
    if (*this == HC()) return "HC";
    if (*this == HL()) return "HL";
    if (*this == HR()) return "HR";
    if (*this == BACKREST()) return "BACKREST";
    if (*this == LFE()) return "LFE";
    if (*this == ONREQ()) return "ONREQ";
    if (*this == UNKNOWN()) return "UNKNOWN";
    
   // For custom positions, return coordinates
    return "(" + std::to_string(m_x) + "," + std::to_string(m_y) + "," + std::to_string(m_z) + ")";
}

} // namespace osd


//============================================================
//  ios_audio_stream - manages a single audio stream
//============================================================

class ios_audio_stream
{
public:
    ios_audio_stream(int channels, int sample_rate, float latency) :
        m_channels(channels),
        m_sample_rate(sample_rate),
        m_latency(latency),
        m_buffer_size(0),
        m_buffer(nullptr),
        m_playpos(0),
        m_writepos(0),
        m_in_underrun(false),
        m_overflows(0),
        m_underflows(0)
    {
        // Calculate buffer size based on latency
        // Ensure we have at least 3 frames worth of buffer at 60fps
        int min_frames = (sample_rate / 60) * 3;
        int latency_frames = (int)(m_sample_rate * m_latency * 20e-3f);
        int frames_per_buffer = std::max(min_frames, latency_frames);
        
        m_buffer_size = frames_per_buffer * m_channels * sizeof(int16_t);
        m_buffer = std::make_unique<uint8_t[]>(m_buffer_size);
        
        // Start with some headroom (1/3 of buffer)
        m_writepos = m_buffer_size / 3;
        
        osd_printf_verbose("ios_audio_stream: created buffer size %d bytes for %d Hz\n", 
                          m_buffer_size, sample_rate);
    }
    
    void update(const int16_t *buffer, int samples_this_frame)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        
        uint32_t bytes_this_frame = samples_this_frame * m_channels * sizeof(int16_t);
        
        // Check for overflow
        uint32_t space_available = buffer_avail();
        if (bytes_this_frame > space_available)
        {
            m_overflows++;
            osd_printf_verbose("iOS audio: buffer overflow (%d bytes needed, %d available)\n", 
                             bytes_this_frame, space_available);
            return;
        }
        
        // Copy data to circular buffer
        uint32_t chunk = std::min(m_buffer_size - m_writepos, bytes_this_frame);
        memcpy(&m_buffer[m_writepos], buffer, chunk);
        m_writepos = (m_writepos + chunk) % m_buffer_size;
        
        if (chunk < bytes_this_frame)
        {
            memcpy(&m_buffer[0], ((uint8_t*)buffer) + chunk, bytes_this_frame - chunk);
            m_writepos = bytes_this_frame - chunk;
        }
        
        m_in_underrun = false;
    }
    
    void get_buffer(void *dest, int bytes_requested)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        
        uint32_t bytes_available = buffer_used();
        
        if (m_in_underrun && bytes_available < (m_buffer_size / 3))
        {
            // Still in underrun, output silence
            memset(dest, 0, bytes_requested);
            return;
        }
        
        if (bytes_requested > bytes_available)
        {
            // Underrun
            m_underflows++;
            m_in_underrun = true;
            memset(dest, 0, bytes_requested);
            osd_printf_verbose("iOS audio: buffer underrun (%d bytes requested, %d available)\n",
                             bytes_requested, bytes_available);
            return;
        }
        
        // Copy from circular buffer
        uint32_t chunk = std::min(m_buffer_size - m_playpos, (uint32_t)bytes_requested);
        memcpy(dest, &m_buffer[m_playpos], chunk);
        m_playpos = (m_playpos + chunk) % m_buffer_size;
        
        if (chunk < bytes_requested)
        {
            memcpy(((uint8_t*)dest) + chunk, &m_buffer[0], bytes_requested - chunk);
            m_playpos = bytes_requested - chunk;
        }
    }
    
    int get_sample_rate() const { return m_sample_rate; }
    int get_channels() const { return m_channels; }
    
private:
    uint32_t buffer_avail() const 
    { 
        if (m_writepos >= m_playpos)
            return m_buffer_size - (m_writepos - m_playpos) - 1;
        else
            return m_playpos - m_writepos - 1;
    }
    
    uint32_t buffer_used() const 
    { 
        if (m_writepos >= m_playpos)
            return m_writepos - m_playpos;
        else
            return m_buffer_size - (m_playpos - m_writepos);
    }
    
    std::mutex m_mutex;
    int m_channels;
    int m_sample_rate;
    float m_latency;
    uint32_t m_buffer_size;
    std::unique_ptr<uint8_t[]> m_buffer;
    uint32_t m_playpos;
    uint32_t m_writepos;
    bool m_in_underrun;
    unsigned m_overflows;
    unsigned m_underflows;
};

//============================================================
//  ios_osd_interface sound implementation
//============================================================

// Stream management
static std::map<uint32_t, std::shared_ptr<ios_audio_stream>> s_streams;
static std::mutex s_stream_mutex;
static std::atomic<uint32_t> s_next_stream_id(1);
static int s_audio_sample_rate = 0;
static float s_audio_latency = 2.0f;

//============================================================
//  sound_init
//============================================================

void ios_osd_interface::sound_init()
{
    osd_printf_verbose("ios_osd_interface::sound_init\n");
    
    // if the host does not want to handle audio, do a default
    if (m_callbacks.sound_play == NULL)
    {
        m_callbacks.sound_init = myosd_sound_init;
        m_callbacks.sound_play = myosd_sound_play;
        m_callbacks.sound_exit = myosd_sound_exit;
    }

    s_audio_sample_rate = options().sample_rate();
    // iOS doesn't have configurable audio latency in MAME options
    // Use a reasonable default of 2.0 (40ms at 48kHz)
    s_audio_latency = 2.0f;

    if (strcmp(options().value(OPTION_SOUND), "none") == 0)
        s_audio_sample_rate = 0;
    
    // Force a common sample rate for iOS if not disabled
    if (s_audio_sample_rate != 0)
    {
        // iOS typically works best with 48000 Hz
        if (s_audio_sample_rate != 11025 && s_audio_sample_rate != 22050 && 
            s_audio_sample_rate != 44100 && s_audio_sample_rate != 48000)
        {
            osd_printf_warning("ios_osd_interface: Adjusting sample rate from %d to 48000\n", 
                              s_audio_sample_rate);
            s_audio_sample_rate = 48000;
        }
        
        m_callbacks.sound_init(s_audio_sample_rate, 1);
    }
}

//============================================================
//  sound_exit
//============================================================

void ios_osd_interface::sound_exit()
{
    osd_printf_verbose("ios_osd_interface::sound_exit\n");
    
    // Close all streams
    {
        std::lock_guard<std::mutex> lock(s_stream_mutex);
        s_streams.clear();
    }
    
    if (s_audio_sample_rate != 0)
    {
        m_callbacks.sound_exit();
    }
}

//============================================================
//  New OSD interface implementation
//============================================================

bool ios_osd_interface::no_sound()
{
    return s_audio_sample_rate == 0;
}

bool ios_osd_interface::sound_external_per_channel_volume()
{
    return false;
}

bool ios_osd_interface::sound_split_streams_per_source()
{
    return false;
}

uint32_t ios_osd_interface::sound_get_generation()
{
    // iOS doesn't have dynamic audio device changes like macOS
    return 1;
}

osd::audio_info ios_osd_interface::sound_get_information()
{
    osd::audio_info info;
    info.m_generation = 1;
    info.m_default_sink = 1;  // iOS has one audio output
    info.m_default_source = 0; // No audio input support
    
    // Add single iOS audio output node
    osd::audio_info::node_info node;
    node.m_id = 1;
    node.m_name = "iOS Audio";
    node.m_display_name = "iOS Audio Output";
    node.m_sinks = 2;  // Stereo output
    node.m_sources = 0;
    node.m_rate.m_default_rate = s_audio_sample_rate;
    node.m_rate.m_min_rate = 8000;
    node.m_rate.m_max_rate = 48000;
    
    // iOS is always stereo
    node.m_port_names.push_back("Left");
    node.m_port_names.push_back("Right");
    node.m_port_positions.push_back(osd::channel_position::FL());
    node.m_port_positions.push_back(osd::channel_position::FR());
    
    info.m_nodes.push_back(node);
    
    // Add stream info
    {
        std::lock_guard<std::mutex> lock(s_stream_mutex);
        for (const auto& [id, stream] : s_streams)
        {
            osd::audio_info::stream_info stream_info;
            stream_info.m_id = id;
            stream_info.m_node = 1;
            info.m_streams.push_back(stream_info);
        }
    }
    
    return info;
}

uint32_t ios_osd_interface::sound_stream_sink_open(uint32_t node, std::string name, uint32_t rate)
{
    if (node != 1 || s_audio_sample_rate == 0)
        return 0;
    
    osd_printf_verbose("ios_osd_interface::sound_stream_sink_open: node=%d name=%s rate=%d\n", 
                      node, name.c_str(), rate);
    
    // iOS always outputs at the system sample rate
    // For now, we'll create the stream at the iOS sample rate, not the requested rate
    // This avoids resampling issues
    auto stream = std::make_shared<ios_audio_stream>(2, s_audio_sample_rate, s_audio_latency);
    
    uint32_t stream_id = s_next_stream_id++;
    {
        std::lock_guard<std::mutex> lock(s_stream_mutex);
        s_streams[stream_id] = stream;
    }
    
    osd_printf_verbose("ios_osd_interface: Created stream %d (requested rate %d, actual rate %d)\n", 
                      stream_id, rate, s_audio_sample_rate);
    
    return stream_id;
}

uint32_t ios_osd_interface::sound_stream_source_open(uint32_t node, std::string name, uint32_t rate)
{
    // iOS doesn't support audio input in MAME
    return 0;
}

void ios_osd_interface::sound_stream_close(uint32_t id)
{
    osd_printf_verbose("ios_osd_interface::sound_stream_close: id=%d\n", id);
    
    std::lock_guard<std::mutex> lock(s_stream_mutex);
    s_streams.erase(id);
}

void ios_osd_interface::sound_stream_sink_update(uint32_t id, const int16_t *buffer, int samples_this_frame)
{
    std::lock_guard<std::mutex> lock(s_stream_mutex);
    auto it = s_streams.find(id);
    if (it != s_streams.end())
    {
        it->second->update(buffer, samples_this_frame);
    }
}

void ios_osd_interface::sound_stream_source_update(uint32_t id, int16_t *buffer, int samples_this_frame)
{
    // Not implemented for iOS
}

void ios_osd_interface::sound_stream_set_volumes(uint32_t id, const std::vector<float> &db)
{
    // iOS uses system volume control
    // Could implement per-stream volume if needed
}

void ios_osd_interface::sound_begin_update()
{
    // Nothing needed for iOS
}

void ios_osd_interface::sound_end_update()
{
    // Nothing needed for iOS
}

//============================================================
//  default sound impl - AudioQueue/AudioUnit support
//============================================================

#import <AudioToolbox/AudioQueue.h>
#import <AudioToolbox/AudioToolbox.h>

/* Audio Resources */
//minimum required buffers for iOS AudioQueue

#define AUDIO_BUFFERS 3

static int soundInit = 0;

typedef struct AQCallbackStruct {
    AudioQueueRef queue;
    UInt32 frameCount;
    AudioQueueBufferRef mBuffers[AUDIO_BUFFERS];
    AudioStreamBasicDescription mDataFormat;
} AQCallbackStruct;

AQCallbackStruct in;

// static pthread_mutex_t sound_mutex = PTHREAD_MUTEX_INITIALIZER;

static int global_low_latency_sound  = 1;

int sound_close_AudioQueue(void);
int sound_open_AudioQueue(int rate, int bits, int stereo);
int sound_close_AudioUnit(void);
int sound_open_AudioUnit(int rate, int bits, int stereo);

static void myosd_sound_init(int rate, int stereo)
{
    if (soundInit == 0)
    {
        if(global_low_latency_sound)
        {
            osd_printf_debug("myosd_openSound LOW LATENCY rate:%d stereo:%d \n",rate,stereo);
            sound_open_AudioUnit(rate, 16, stereo);
        }
        else
        {
            osd_printf_debug("myosd_openSound NORMAL rate:%d stereo:%d \n",rate,stereo);
            sound_open_AudioQueue(rate, 16, stereo);
        }
       
        soundInit = 1;
    }
}

static void myosd_sound_exit(void)
{
    if( soundInit == 1 )
    {
        osd_printf_debug("myosd_closeSound\n");

        if(global_low_latency_sound)
           sound_close_AudioUnit();
        else
           sound_close_AudioQueue();

        soundInit = 0;
    }
}

static void myosd_sound_play(void *buff, int len)
{
    // This is called by the AudioQueue/AudioUnit callbacks
    // We need to mix all active streams
    std::lock_guard<std::mutex> lock(s_stream_mutex);
    
    if (s_streams.empty())
    {
        memset(buff, 0, len);
        return;
    }
    
    // Clear the output buffer first
    memset(buff, 0, len);
    
    // Mix all active streams
    int16_t *output = (int16_t *)buff;
    int samples = len / sizeof(int16_t);
    
    // Temporary buffer for each stream
    std::vector<int16_t> temp_buffer(samples);
    
    for (auto& [id, stream] : s_streams)
    {
        // Get audio from this stream
        stream->get_buffer(temp_buffer.data(), len);
        
        // Mix into output buffer
        for (int i = 0; i < samples; i++)
        {
            int32_t mixed = (int32_t)output[i] + (int32_t)temp_buffer[i];
            // Clamp to int16 range
            if (mixed > 32767) mixed = 32767;
            if (mixed < -32768) mixed = -32768;
            output[i] = (int16_t)mixed;
        }
    }
}

void checkStatus(OSStatus status){}

static void AQBufferCallback(void *userdata,
                             AudioQueueRef outQ,
                             AudioQueueBufferRef outQB)
{
    unsigned char *coreAudioBuffer;
    coreAudioBuffer = (unsigned char*) outQB->mAudioData;

    myosd_sound_play(coreAudioBuffer, in.mDataFormat.mBytesPerFrame * in.frameCount);
    outQB->mAudioDataByteSize = in.mDataFormat.mBytesPerFrame * in.frameCount;

    AudioQueueEnqueueBuffer(outQ, outQB, 0, NULL);
}

int sound_close_AudioQueue(){

    if( soundInit == 1 )
    {
        AudioQueueDispose(in.queue, true);
        soundInit = 0;
    }
    return 1;
}

int sound_open_AudioQueue(int rate, int bits, int stereo){

    Float64 sampleRate = 48000.0;
    int i;
    UInt32 err;
    int fps;
    int bufferSize;

    if(rate==44100)
        sampleRate = 44100.0;
    if(rate==32000)
        sampleRate = 32000.0;
    else if(rate==22050)
        sampleRate = 22050.0;
    else if(rate==11025)
        sampleRate = 11025.0;

    fps = 60;

    if( soundInit == 1 )
    {
        sound_close_AudioQueue();
    }

    soundInit = 0;
    memset (&in.mDataFormat, 0, sizeof (in.mDataFormat));
    in.mDataFormat.mSampleRate = sampleRate;
    in.mDataFormat.mFormatID = kAudioFormatLinearPCM;
    in.mDataFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger  | kAudioFormatFlagIsPacked;
    in.mDataFormat.mBytesPerPacket =  (stereo == 1 ? 4 : 2 );
    in.mDataFormat.mFramesPerPacket = 1;
    in.mDataFormat.mBytesPerFrame = (stereo ==  1? 4 : 2);
    in.mDataFormat.mChannelsPerFrame = (stereo == 1 ? 2 : 1);
    in.mDataFormat.mBitsPerChannel = 16;
    in.frameCount = rate / fps;

    err = AudioQueueNewOutput(&in.mDataFormat,
                              AQBufferCallback,
                              NULL,
                              NULL,
                              kCFRunLoopCommonModes,
                              0,
                              &in.queue);

    bufferSize = in.frameCount * in.mDataFormat.mBytesPerFrame;

    for (i=0; i<AUDIO_BUFFERS; i++)
    {
        err = AudioQueueAllocateBuffer(in.queue, bufferSize, &in.mBuffers[i]);
        in.mBuffers[i]->mAudioDataByteSize = bufferSize;
        AudioQueueEnqueueBuffer(in.queue, in.mBuffers[i], 0, NULL);
    }

    soundInit = 1;
    err = AudioQueueStart(in.queue, NULL);

    return err;
}

///////// AUDIO UNIT
#define kOutputBus 0
static AudioComponentInstance audioUnit;

static OSStatus playbackCallback(void *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData) {
    
    unsigned char *coreAudioBuffer;
    
    int i;
    for (i = 0 ; i < ioData->mNumberBuffers; i++)
    {
        coreAudioBuffer = (unsigned char*) ioData->mBuffers[i].mData;
        myosd_sound_play(coreAudioBuffer, inNumberFrames * 4);
        ioData->mBuffers[i].mDataByteSize = inNumberFrames * 4;
    }
    
    return noErr;
}

int sound_close_AudioUnit(){
    
    if( soundInit == 1 )
    {
        OSStatus status = AudioOutputUnitStop(audioUnit);
        checkStatus(status);
        
        AudioUnitUninitialize(audioUnit);
        soundInit = 0;
    }
    
    return 1;
}

int sound_open_AudioUnit(int rate, int bits, int stereo){
    Float64 sampleRate = 48000.0;

    if( soundInit == 1 )
    {
        sound_close_AudioUnit();
    }
    
    if(rate==44100)
        sampleRate = 44100.0;
    if(rate==32000)
        sampleRate = 32000.0;
    else if(rate==22050)
        sampleRate = 22050.0;
    else if(rate==11025)
        sampleRate = 11025.0;
    
    OSStatus status;
    
    // Describe audio component
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Get component
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
    
    // Get audio units
    status = AudioComponentInstanceNew(inputComponent, &audioUnit);
    checkStatus(status);
    
    UInt32 flag = 1;
    // Enable IO for playback
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Output,
                                  kOutputBus,
                                  &flag,
                                  sizeof(flag));
    checkStatus(status);
    
    AudioStreamBasicDescription audioFormat;
    
    memset (&audioFormat, 0, sizeof (audioFormat));
    
    audioFormat.mSampleRate = sampleRate;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger  | kAudioFormatFlagIsPacked;
    audioFormat.mBytesPerPacket =  (stereo == 1 ? 4 : 2 );
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mBytesPerFrame = (stereo ==  1? 4 : 2);
    audioFormat.mChannelsPerFrame = (stereo == 1 ? 2 : 1);
    audioFormat.mBitsPerChannel = 16;
    
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  kOutputBus,
                                  &audioFormat,
                                  sizeof(audioFormat));
    checkStatus(status);
    
    struct AURenderCallbackStruct callbackStruct;
    // Set output callback
    callbackStruct.inputProc = playbackCallback;
    callbackStruct.inputProcRefCon = NULL;
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Global,
                                  kOutputBus,
                                  &callbackStruct,
                                  sizeof(callbackStruct));
    checkStatus(status);
    
    status = AudioUnitInitialize(audioUnit);
    checkStatus(status);
    
    //ARRANCAR
    soundInit = 1;
    status = AudioOutputUnitStart(audioUnit);
    checkStatus(status);
    
    return 1;
}
