/*
 * vphoned_touch — multi-finger digitizer injection.
 *
 * icli's `input.touch` carries a single finger, so a pinch (two fingers moving
 * together) cannot be expressed through it. This builds one hand event holding
 * several fingers and dispatches it, the shape WebKit's HIDEventGenerator and
 * TrollVNC's STHIDEventGenerator use.
 *
 * Every entry point is resolved with dlsym, so a base without the private
 * digitizer symbols still starts; injection then logs once and stays a no-op.
 *
 * Coordinates are normalized to 0..1 with the origin at the top-left, matching
 * what `GuestAPI` hands a gesture.
 */

#import "Include/VphonedNative.h"

#include <dlfcn.h>
#include <mach/mach_time.h>

typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;
typedef double IOHIDFloat;

static IOHIDEventSystemClientRef (*pCreate)(CFAllocatorRef);
static void (*pSetSender)(IOHIDEventRef, uint64_t);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);

static IOHIDEventRef (*pDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                   uint32_t, uint32_t, uint32_t, IOHIDFloat,
                                   IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                   boolean_t, boolean_t, uint32_t);
static IOHIDEventRef (*pFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, uint32_t);
static void (*pAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*pSetInt)(IOHIDEventRef, uint32_t, int);
static IOHIDEventRef (*pKeyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, boolean_t, uint32_t);

static IOHIDEventSystemClientRef gTouchClient;
static dispatch_queue_t gTouchQueue;
static bool gTouchUnavailableLogged;

// Digitizer event-mask bits and transducer types (IOHIDEventTypes.h).
#define VP_DIG_RANGE 0x00000001u
#define VP_DIG_TOUCH 0x00000002u
#define VP_DIG_POSITION 0x00000004u
#define VP_DIG_IDENTITY 0x00000020u
// Edge flags as touch firmware reports them for a touch that starts at a screen
// edge. UIKit (_UIEventHIDTouchEdgeTypeForHIDEvent) maps 0x800 to edge type 1,
// which UIScreenEdgePanGestureRecognizer requires to begin, and bits 24-27 to
// the edge aim (1 bottom, 2 top, 4 right, 8 left). Without them SpringBoard's
// bottom-edge home gesture (and Control Center / Notification Center from the
// top) never starts. The VZ USB touchscreen reports none of this: its HID
// report has only index, range, touch, x and y per finger.
#define VP_DIG_FROM_EDGE 0x00000800u
#define VP_DIG_AIM_SHIFT 24
#define VP_TRANSDUCER_HAND 1
// kIOHIDEventFieldDigitizerIsDisplayIntegrated: (kIOHIDEventTypeDigitizer << 16) | offset.
#define VP_FIELD_IS_DISPLAY_INTEGRATED ((((uint32_t)11) << 16) | 25)

bool vp_hid_load(void) {
    if (gTouchClient) return true;

    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!ioKit) {
        NSLog(@"vphoned: dlopen IOKit failed, touch injection disabled");
        return false;
    }

    pCreate = dlsym(ioKit, "IOHIDEventSystemClientCreate");
    pSetSender = dlsym(ioKit, "IOHIDEventSetSenderID");
    pDispatch = dlsym(ioKit, "IOHIDEventSystemClientDispatchEvent");
    pDigitizer = dlsym(ioKit, "IOHIDEventCreateDigitizerEvent");
    pFinger = dlsym(ioKit, "IOHIDEventCreateDigitizerFingerEvent");
    pAppend = dlsym(ioKit, "IOHIDEventAppendEvent");
    pSetInt = dlsym(ioKit, "IOHIDEventSetIntegerValue");
    pKeyboard = dlsym(ioKit, "IOHIDEventCreateKeyboardEvent");

    if (!pCreate || !pSetSender || !pDispatch || !pDigitizer || !pFinger || !pAppend || !pSetInt) {
        NSLog(@"vphoned: digitizer symbols missing, touch injection disabled");
        return false;
    }

    gTouchClient = pCreate(kCFAllocatorDefault);
    if (!gTouchClient) {
        NSLog(@"vphoned: IOHIDEventSystemClientCreate returned NULL");
        return false;
    }

    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    gTouchQueue = dispatch_queue_create("com.vphone.vphoned.touch", attributes);
    return true;
}

bool vp_hid_keyboard_hold(uint16_t page, uint16_t usage, bool down) {
    if (!vp_hid_load() || !pKeyboard) return false;
    IOHIDEventRef event = pKeyboard(kCFAllocatorDefault, mach_absolute_time(), page, usage, down, 0);
    if (!event) return false;
    // The same built-in marker and sender as IcliKit's ordinary key events.
    pSetInt(event, 4, 1);
    // kIOHIDEventFieldKeyboardLongPress. SBHPIOHID reads this field for Center.
    pSetInt(event, (3u << 16) | 5u, 1);
    pSetSender(event, 0x8000000817319372);
    // Input RPCs are ordered; finish dispatch before acknowledging the hold.
    dispatch_sync(gTouchQueue, ^{ pDispatch(gTouchClient, event); });
    CFRelease(event);
    return true;
}

// One hand event carrying `count` fingers, dispatched as a single gesture.
static void dispatch_digitizer_points(const double *xs, const double *ys,
                                      int count, boolean_t range, boolean_t touch,
                                      uint32_t mask) {
    if (!gTouchClient || !pDigitizer || !pFinger || !pAppend || !pSetInt || count <= 0) return;

    uint64_t timestamp = mach_absolute_time();
    IOHIDEventRef hand = pDigitizer(kCFAllocatorDefault, timestamp, VP_TRANSDUCER_HAND,
                                    0, 0, mask, 0, xs[0], ys[0], 0, 0, 0, range, touch, 0);
    if (!hand) return;
    pSetInt(hand, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);

    for (int index = 0; index < count; index++) {
        // Finger 0 keeps index 1 / identity 2 so the single-finger path is
        // unchanged; extra fingers carry their own identity so the guest tracks
        // them as separate touches instead of collapsing them into one.
        IOHIDEventRef finger = pFinger(kCFAllocatorDefault, timestamp, (uint32_t)(index + 1),
                                       (uint32_t)(index + 2), mask, xs[index], ys[index],
                                       0, 0, 0, range, touch, 0);
        if (!finger) continue;
        pSetInt(finger, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);
        pAppend(hand, finger, 0);
        CFRelease(finger);
    }

    IOHIDEventRef strong = (IOHIDEventRef)CFRetain(hand);
    dispatch_async(gTouchQueue, ^{
        pSetSender(strong, 0x8000000817319372);
        pDispatch(gTouchClient, strong);
        CFRelease(strong);
    });
    CFRelease(hand);
}

void vp_hid_touch2(int phase, double x1, double y1, double x2, double y2) {
    if (!gTouchClient) {
        if (!vp_hid_load() && !gTouchUnavailableLogged) {
            gTouchUnavailableLogged = true;
            NSLog(@"vphoned: two-finger injection unavailable on this base");
        }
        if (!gTouchClient) return;
    }

    const double xs[2] = {x1, x2};
    const double ys[2] = {y1, y2};
    switch (phase) {
        case 0: // down
            dispatch_digitizer_points(xs, ys, 2, 1, 1, VP_DIG_TOUCH | VP_DIG_IDENTITY);
            break;
        case 1: // move
            dispatch_digitizer_points(xs, ys, 2, 1, 1, VP_DIG_POSITION);
            break;
        case 3: // up
        default:
            dispatch_digitizer_points(xs, ys, 2, 0, 0, VP_DIG_TOUCH | VP_DIG_IDENTITY);
            break;
    }
}

// Host edge code (`_VZTouch` swipeAim: 1 top, 2 bottom, 4 right, 8 left) to the
// HID edge flags, kept for the whole touch like real firmware does.
static uint32_t edge_flags(int edge) {
    uint32_t aim = 0;
    if (edge & 1) aim |= 2; // top
    if (edge & 2) aim |= 1; // bottom
    if (edge & 4) aim |= 4; // right
    if (edge & 8) aim |= 8; // left
    return aim ? (VP_DIG_FROM_EDGE | (aim << VP_DIG_AIM_SHIFT)) : 0;
}

void vp_hid_touch_edge(int phase, double x, double y, int edge) {
    if (!gTouchClient) {
        if (!vp_hid_load() && !gTouchUnavailableLogged) {
            gTouchUnavailableLogged = true;
            NSLog(@"vphoned: edge touch injection unavailable on this base");
        }
        if (!gTouchClient) return;
    }

    const uint32_t flags = edge_flags(edge);
    const double xs[1] = {x};
    const double ys[1] = {y};
    switch (phase) {
        case 0: // down
            dispatch_digitizer_points(xs, ys, 1, 1, 1, VP_DIG_TOUCH | VP_DIG_IDENTITY | flags);
            break;
        case 1: // move
            dispatch_digitizer_points(xs, ys, 1, 1, 1, VP_DIG_POSITION | flags);
            break;
        case 3: // up
        default:
            dispatch_digitizer_points(xs, ys, 1, 0, 0, VP_DIG_TOUCH | VP_DIG_IDENTITY | flags);
            break;
    }
}
