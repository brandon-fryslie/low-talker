#ifndef CORE_AUDIO_CALLS_H
#define CORE_AUDIO_CALLS_H

#include <CoreAudio/AudioHardware.h>

// CoreAudio's property listener block calls, with the block passed as a pointer. Swift
// imports AudioObjectPropertyListenerBlock as a Swift closure and bridges it to a fresh
// block at every call, and CoreAudio removes a listener only when handed the very block it
// was added with - so from Swift a removal matches nothing, answers noErr anyway, and the
// listener keeps firing. Through these, the block Swift passes is the block CoreAudio gets.
// Each is a pass-through, so the meaning stays with the Swift that calls it.

OSStatus lt_audio_object_add_property_listener_block(AudioObjectID object, const AudioObjectPropertyAddress *address, dispatch_queue_t queue, const void *block);

OSStatus lt_audio_object_remove_property_listener_block(AudioObjectID object, const AudioObjectPropertyAddress *address, dispatch_queue_t queue, const void *block);

#endif
