#include "CoreAudioCalls.h"

OSStatus lt_audio_object_add_property_listener_block(AudioObjectID object, const AudioObjectPropertyAddress *address, dispatch_queue_t queue, const void *block) {
    return AudioObjectAddPropertyListenerBlock(object, address, queue, (AudioObjectPropertyListenerBlock)block);
}

OSStatus lt_audio_object_remove_property_listener_block(AudioObjectID object, const AudioObjectPropertyAddress *address, dispatch_queue_t queue, const void *block) {
    return AudioObjectRemovePropertyListenerBlock(object, address, queue, (AudioObjectPropertyListenerBlock)block);
}
