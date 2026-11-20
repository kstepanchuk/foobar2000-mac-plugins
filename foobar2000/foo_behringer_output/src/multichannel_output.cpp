#include "predef.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/AudioHardware.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace {
constexpr uint32_t kRingFrames = 1u << 16;
constexpr uint32_t kRingMask = kRingFrames - 1;

uint32_t outputChannelCount(AudioDeviceID device) {
    AudioObjectPropertyAddress address{kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr || size == 0) return 0;
    std::vector<uint8_t> storage(size);
    auto *list = reinterpret_cast<AudioBufferList *>(storage.data());
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, list) != noErr) return 0;
    uint32_t count = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) count += list->mBuffers[i].mNumberChannels;
    return count;
}

pfc::string8 deviceName(AudioDeviceID device) {
    CFStringRef name = nullptr;
    AudioObjectPropertyAddress address{kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(name);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &name) != noErr || !name) return "Audio device";
    char buffer[512] = {};
    CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8);
    CFRelease(name);
    return buffer;
}

std::vector<AudioDeviceID> outputDevices() {
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size) != noErr || size == 0) return {};
    std::vector<AudioDeviceID> devices(size / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, devices.data()) != noErr) return {};
    return devices;
}

GUID deviceGuid(AudioDeviceID device, uint32_t firstChannel) {
    return {device, static_cast<uint16_t>(firstChannel), 0x4F42, {0xA1, 0x19, 0x81, 0x2C, 0x7B, 0x58, 0x14, 0xE3}};
}

struct Ring {
    std::vector<float> samples = std::vector<float>(size_t(kRingFrames) * 2, 0.0f);
    std::atomic<uint64_t> write{0};
    std::atomic<uint64_t> read{0};
    std::atomic<float> gain{1.0f};
    uint32_t firstChannel = 0;
};

OSStatus renderAudio(void *context, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                     UInt32, UInt32 frames, AudioBufferList *output) {
    auto *ring = static_cast<Ring *>(context);
    if (!ring || !output) return noErr;
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
        if (output->mBuffers[b].mData) std::memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }

    const uint64_t readStart = ring->read.load(std::memory_order_relaxed);
    const uint64_t writeEnd = ring->write.load(std::memory_order_acquire);
    const uint64_t available = std::min<uint64_t>(writeEnd - readStart, frames);
    const float gain = ring->gain.load(std::memory_order_relaxed);
    for (uint32_t i = 0; i < available; ++i) {
        const size_t source = size_t((readStart + i) & kRingMask) * 2;
        const float left = ring->samples[source] * gain;
        const float right = ring->samples[source + 1] * gain;
        uint32_t channelBase = 0;
        for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
            auto &buffer = output->mBuffers[b];
            if (!buffer.mData) { channelBase += buffer.mNumberChannels; continue; }
            const uint32_t channels = buffer.mNumberChannels;
            auto *data = static_cast<float *>(buffer.mData);
            const uint32_t leftChannel = ring->firstChannel;
            if (leftChannel >= channelBase && leftChannel < channelBase + channels)
                data[size_t(i) * channels + leftChannel - channelBase] = left;
            if (leftChannel + 1 >= channelBase && leftChannel + 1 < channelBase + channels)
                data[size_t(i) * channels + leftChannel + 1 - channelBase] = right;
            channelBase += channels;
        }
    }
    ring->read.store(readStart + available, std::memory_order_release);
    return noErr;
}
}

// Implementation follows below; the render callback's channel map is kept in this object.
namespace foo_behringer {
class MultiChannelOutput : public output_impl {
public:
    static constexpr GUID class_guid = {0xE986CE12, 0x8E28, 0x4D70, {0x98, 0x33, 0x2A, 0x87, 0xC2, 0xB6, 0x11, 0x01}};
    static GUID g_get_guid() { return class_guid; }
    static const char *g_get_name() { return "CoreAudio Mixer Output"; }
    static bool g_is_high_latency() { return false; }
    static bool g_supports_multiple_streams() { return false; }
    static bool g_advanced_settings_query() { return false; }
    static bool g_needs_bitdepth_config() { return false; }
    static bool g_needs_dither_config() { return false; }
    static bool g_needs_device_list_prefixes() { return false; }

    static void g_enum_devices(output_device_enum_callback &callback) {
        for (AudioDeviceID device : outputDevices()) {
            const uint32_t channels = outputChannelCount(device);
            if (channels < 4) continue;
            const auto name = deviceName(device);
            for (uint32_t first = 0; first + 1 < channels; first += 2) {
                pfc::string_formatter label;
                label << name << " — " << (first + 1) << "/" << (first + 2);
                const auto id = deviceGuid(device, first);
                callback.on_device(id, label.c_str(), label.length());
            }
        }
    }

    MultiChannelOutput(const GUID &device, double, bool, t_uint32)
        : m_device(device.Data1), m_firstChannel(device.Data2), m_channels(outputChannelCount(m_device)) {
        AudioComponentDescription desc{kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
            kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent component = AudioComponentFindNext(nullptr, &desc);
        if (!component || AudioComponentInstanceNew(component, &m_unit) != noErr) throw exception_output_device_not_found();
        UInt32 enabled = 1, disabled = 0;
        AudioUnitSetProperty(m_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, sizeof(enabled));
        AudioUnitSetProperty(m_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled, sizeof(disabled));
        if (AudioUnitSetProperty(m_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &m_device, sizeof(m_device)) != noErr) {
            AudioComponentInstanceDispose(m_unit); m_unit = nullptr; throw exception_output_device_not_found();
        }
        AURenderCallbackStruct callback{renderAudio, &m_ring};
        if (AudioUnitSetProperty(m_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                 &callback, sizeof(callback)) != noErr) {
            AudioComponentInstanceDispose(m_unit); m_unit = nullptr; throw exception_output_device_not_found();
        }
        if (m_channels < 2 || m_firstChannel + 1 >= m_channels) {
            AudioComponentInstanceDispose(m_unit); m_unit = nullptr; throw exception_output_device_not_found();
        }
        m_ring.firstChannel = m_firstChannel;
    }

    ~MultiChannelOutput() { stopUnit(); if (m_unit) AudioComponentInstanceDispose(m_unit); }
    unsigned get_forced_channel_mask() override { return audio_chunk::channel_config_stereo; }

protected:
    void on_update() override {}
    void open(const audio_chunk::spec_t &spec) override {
        stopUnit();
        m_sampleRate = spec.sampleRate;
        AudioStreamBasicDescription format{};
        format.mSampleRate = m_sampleRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) |
                              static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
        format.mBytesPerPacket = sizeof(float);
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = sizeof(float);
        format.mChannelsPerFrame = m_channels;
        format.mBitsPerChannel = 32;
        if (AudioUnitSetProperty(m_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                 &format, sizeof(format)) != noErr || AudioUnitInitialize(m_unit) != noErr ||
            AudioOutputUnitStart(m_unit) != noErr) {
            AudioUnitUninitialize(m_unit);
            throw exception_output_unsupported_stream_format();
        }
        m_running = true;
        m_ring.read.store(0, std::memory_order_relaxed);
        m_ring.write.store(0, std::memory_order_relaxed);
    }
    void write(const audio_chunk &chunk) override {
        const uint32_t channels = chunk.get_channels();
        if (!channels) return;
        const size_t frames = chunk.get_sample_count();
        const auto *src = chunk.get_data();
        uint64_t w = m_ring.write.load(std::memory_order_relaxed);
        const uint64_t r = m_ring.read.load(std::memory_order_acquire);
        const size_t count = std::min<uint64_t>(frames, kRingFrames - (w - r));
        for (size_t i = 0; i < count; ++i) {
            const size_t dst = size_t((w + i) & kRingMask) * 2;
            m_ring.samples[dst] = float(src[i * channels]);
            m_ring.samples[dst + 1] = float(src[i * channels + (channels > 1 ? 1 : 0)]);
        }
        m_ring.write.store(w + count, std::memory_order_release);
    }
    t_size can_write_samples() override {
        const uint64_t w = m_ring.write.load(std::memory_order_relaxed);
        const uint64_t r = m_ring.read.load(std::memory_order_acquire);
        return m_running ? kRingFrames - (w - r) : 0;
    }
    t_size get_latency_samples() override {
        const uint64_t w = m_ring.write.load(std::memory_order_acquire);
        const uint64_t r = m_ring.read.load(std::memory_order_relaxed);
        return t_size(w - r);
    }
    void on_flush() override { m_ring.read.store(m_ring.write.load(std::memory_order_acquire), std::memory_order_release); }
    void on_force_play() override {}
    void pause(bool state) override { if (state) stopUnit(); else startUnit(); }
    void volume_set(double value) override { m_ring.gain.store(float(std::pow(10.0, value / 20.0)), std::memory_order_relaxed); }
    bool is_progressing() override { return m_running; }

private:
    void stopUnit() { if (m_running) { AudioOutputUnitStop(m_unit); AudioUnitUninitialize(m_unit); m_running = false; } }
    void startUnit() { if (!m_running && m_unit && m_sampleRate > 0) { if (AudioUnitInitialize(m_unit) == noErr && AudioOutputUnitStart(m_unit) == noErr) m_running = true; } }

    AudioDeviceID m_device;
    uint32_t m_firstChannel;
    uint32_t m_channels;
    AudioUnit m_unit = nullptr;
    Ring m_ring;
    double m_sampleRate = 0;
    bool m_running = false;
};
}

static output_factory_t<foo_behringer::MultiChannelOutput> g_multichannel_output;
