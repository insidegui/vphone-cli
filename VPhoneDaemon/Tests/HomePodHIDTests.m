#import <Foundation/Foundation.h>
#include <assert.h>
#include "../Native/vphoned_touch.m"

static bool expectedDown;
static unsigned fields;
static unsigned dispatched;

static IOHIDEventRef keyboard(CFAllocatorRef allocator, uint64_t timestamp,
                              uint32_t page, uint32_t usage, boolean_t down, uint32_t options) {
    (void)allocator;
    assert(timestamp && page == 0x0C && usage == 0xCD && down == expectedDown && options == 0);
    return (void *)CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
}

static void setInt(IOHIDEventRef event, uint32_t field, int value) {
    assert(event && value == 1);
    if (field == 4) fields |= 1;
    else if (field == 0x30005) fields |= 2;
    else assert(false);
}

static void setSender(IOHIDEventRef event, uint64_t sender) {
    assert(event && sender == 0x8000000817319372ULL && fields == 3);
    fields |= 4;
}

static void dispatch(IOHIDEventSystemClientRef client, IOHIDEventRef event) {
    assert(client == gTouchClient && event && fields == 7);
    dispatched++;
}

int main(void) {
    @autoreleasepool {
        // Use the real encoder/dispatch function with captured IOKit calls.
        gTouchClient = (void *)1;
        gTouchQueue = dispatch_queue_create("homepod-hid-tests", DISPATCH_QUEUE_SERIAL);
        pKeyboard = keyboard;
        pSetInt = setInt;
        pSetSender = setSender;
        pDispatch = dispatch;
        for (unsigned index = 0; index < 2; index++) {
            fields = 0;
            expectedDown = index == 0;
            assert(vp_hid_keyboard_hold(0x0C, 0xCD, expectedDown));
            assert(dispatched == index + 1); // Dispatch precedes the RPC reply.
        }
        pKeyboard = NULL;
        assert(!vp_hid_keyboard_hold(0x0C, 0xCD, true));
        assert(dispatched == 2);
        puts("HomePod HID long-press encoding, paired release and unavailable-symbol tests passed");
    }
}
