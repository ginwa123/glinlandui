// glinlandui macOS window shim — Objective-C implementation.
//
// Deliberately dumb. This file owns the NSWindow, the NSView, and turning
// AppKit events into C callbacks. It makes no decisions: no layout, no
// rendering, no keycode translation, no coordinate flipping. Everything
// decision-shaped lives in Zig where it is unit-tested.
//
// Why Objective-C and not hand-rolled objc_msgSend: `zig build` compiles .m
// files, and messaging NSWindow/NSView directly is both far shorter and far
// less likely to contain a subtle runtime fault than casting every selector
// by hand.
//
// The handle is the plain C struct declared in cocoa shim header (mac/shim.h) — NOT an
// Objective-C class. Keeping one representation of the state (rather than a
// struct that is also an @interface) is what lets the view and the delegate
// helper both reach it with a plain pointer, and avoids the "incomplete type"
// trap that a forward-declared class would create.

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

#include "shim.h"

/// Bitmap info for the 32-bit context the blit buffer is copied into.
///
/// The byte-order flag is the whole ballgame, and it is easy to get exactly
/// backwards. `kCGBitmapByteOrder32Little` does NOT mean "little-endian RGBA in
/// memory"; it means the 32-bit pixel is a little-endian WORD, which
/// REVERSES the component order on a little-endian host. With
/// `kCGImageAlphaPremultipliedLast` the logical order is (R,G,B,A), so
/// `32Little` puts the bytes in memory as A, B, G, R.
///
/// The bug that cost a day: with `32Little`, a source pixel (R,G,B,A) is
/// DISPLAYED as (A,B,G,R). Every pixel in the window therefore came out with
/// its alpha in the red channel — the calculator's `0x101014` background
/// rendered as bright red (255,20,16) and the `=` key's accent blue
/// `0x2f6df6` rendered as yellow (255,246,109). Nothing errored, and every
/// byte-level test still passed, because they only ever compared the buffer
/// against itself.
///
/// `32Big` is what actually makes memory order (R,G,B,A) == displayed order
/// (R,G,B,A), which is the identity transform `mac/present.zig` produces.
/// `ci/check_macos_colors.c` measures this through CoreGraphics and fails the
/// build if the displayed colour is not the source colour.
static const CGBitmapInfo kGlinBitmapInfo =
    (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;

struct GlinCocoaWindow {
    NSWindow *window;
    void *view;         // GlinView*, unretained
    void *delegate_obj; // GlinWindowDelegate*, unretained

    GlinCocoaOnFrame on_frame;
    GlinCocoaOnPointer on_pointer;
    GlinCocoaOnScroll on_scroll;
    GlinCocoaOnKey on_key;
    GlinCocoaOnResize on_resize;
    GlinCocoaOnClose on_close;
    void *user;

    /// Owned pixel buffer + a bitmap context over it. Both are reallocated
    /// only when the size changes, so a steady-state frame is a memcpy.
    unsigned char *pixels;
    size_t pixels_len;
    CGContextRef bitmap_ctx;
    int buf_w;
    int buf_h;

    int frames_drawn;
    int max_frames;
};

@interface GlinView : NSView {
    GlinCocoaWindow *_owner;
}
- (instancetype)initWithFrame:(NSRect)frame owner:(GlinCocoaWindow *)owner;
- (GlinCocoaWindow *)owner;
@end

@implementation GlinView

- (instancetype)initWithFrame:(NSRect)frame owner:(GlinCocoaWindow *)owner {
    self = [super initWithFrame:frame];
    if (self) {
        _owner = owner;
    }
    return self;
}

- (GlinCocoaWindow *)owner {
    return _owner;
}

- (BOOL)isFlipped {
    // We do NOT flip the view. Keeping the standard bottom-left origin means
    // the point `glinForward:` hands the host is already in the space the
    // blit assumed, so there is exactly one flip (in Zig) rather than two
    // independent ones that could disagree.
    return NO;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

/// Pointer event kinds, mirroring mac/input.zig.
enum {
    GlinPointerMotion = 0,
    GlinPointerDown = 1,
    GlinPointerUp = 2,
};

- (void)mouseDown:(NSEvent *)event {
    // Reclaim key focus: a click can leave the window with no key window, and
    // the keyboard path then dies silently.
    [self.window makeFirstResponder:self];
    [self glinForward:event kind:GlinPointerDown];
}

- (void)mouseDragged:(NSEvent *)event {
    // A drag is MOTION with the button held. It must NOT be reported as a
    // fresh press: the dispatcher would re-arm the press on every move,
    // resetting the drag anchor so a drag could never start.
    [self glinForward:event kind:GlinPointerMotion];
}

- (void)mouseUp:(NSEvent *)event {
    [self glinForward:event kind:GlinPointerUp];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    [self glinForward:event kind:GlinPointerDown];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self glinForward:event kind:GlinPointerUp];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self glinForward:event kind:GlinPointerMotion];
}

- (void)otherMouseDown:(NSEvent *)event {
    [self glinForward:event kind:GlinPointerDown];
}

- (void)otherMouseUp:(NSEvent *)event {
    [self glinForward:event kind:GlinPointerUp];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self glinForward:event kind:GlinPointerMotion];
}

- (void)mouseMoved:(NSEvent *)event {
    [self glinForward:event kind:GlinPointerMotion];
}

- (void)mouseEntered:(NSEvent *)event {
    // Crossing into the window is motion; without this a pointer that entered
    // without moving would leave the hover state stale.
    [self glinForward:event kind:GlinPointerMotion];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
}

/// Forward one AppKit mouse event. The y axis (bottom-left origin) and the
/// button code are translated by the host, not here, so both are unit-tested.
///
/// WHY THIS IS NOT `[event locationInView:self]`
/// -----------------------------------------
/// `NSEvent` has NO `locationInView:` method. It declares exactly one
/// location accessor, `locationInWindow`, and everything else is a
/// `convertPoint:...` round trip. Messaging it anyway is a *warning*
/// (`'NSEvent' may not respond to 'locationInView:'`), the build still
/// succeeds, and the failure only shows up at runtime: every single
/// mouse event raised `NSInvalidArgumentException: -[NSEvent
/// locationInView:]: unrecognized selector`, which unwound straight out
/// of `mouseDown:`/`mouseUp:` BEFORE `o->on_pointer(...)` ever ran. The
/// whole macOS backend was therefore deaf: no press, no release, no
/// click, and the calculator looked completely inert while the Zig-side
/// state machine was perfectly healthy. `build.zig` now compiles this
/// file with `-Werror` so that mistake is a BUILD failure instead.
///
/// The correct conversion is window space -> view space, via the view
/// that is the window's content view (`self`): exactly the transform
/// `locationInView:` would have performed.
- (void)glinForward:(NSEvent *)event kind:(int)kind {
    GlinCocoaWindow *o = _owner;
    if (!o || !o->on_pointer) return;
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    o->on_pointer(o->user, kind, (int)event.buttonNumber, p.x, p.y, 0);
}

- (void)scrollWheel:(NSEvent *)event {
    GlinCocoaWindow *o = _owner;
    if (!o || !o->on_scroll) return;
    o->on_scroll(o->user, event.scrollingDeltaX, event.scrollingDeltaY);
}

- (void)keyDown:(NSEvent *)event {
    GlinCocoaWindow *o = _owner;
    if (o && o->on_key) o->on_key(o->user, (int)event.keyCode, 1);
}

- (void)keyUp:(NSEvent *)event {
    GlinCocoaWindow *o = _owner;
    if (o && o->on_key) o->on_key(o->user, (int)event.keyCode, 0);
}

- (void)drawRect:(NSRect)dirtyRect {
    GlinCocoaWindow *o = _owner;
    if (!o) return;

    // Ask the host to render. It renders its own surface and calls back into
    // glin_cocoa_present() with the converted bytes, so the pixels exist by
    // the time we composite below.
    if (o->on_frame) o->on_frame(o->user);

    NSGraphicsContext *nsctx = [NSGraphicsContext currentContext];
    if (!nsctx) return;
    CGContextRef cg = (CGContextRef)nsctx.CGContext;
    if (!cg) return;

    // Paint the window background first, so a frame the host failed to
    // produce leaves a clean surface rather than stale garbage.
    CGContextSetRGBFillColor(cg, 0.06, 0.06, 0.08, 1.0);
    CGContextFillRect(cg, dirtyRect);

    if (o->bitmap_ctx && o->buf_w > 0 && o->buf_h > 0) {
        CGImageRef img = CGBitmapContextCreateImage(o->bitmap_ctx);
        if (img) {
            // The bitmap's row 0 is the host's bottom row (it flipped in
            // mac/present.zig), and a non-flipped context's origin is also
            // bottom-left, so this draws the right way up.
            CGContextDrawImage(cg, CGRectMake(0, 0, o->buf_w, o->buf_h), img);
            CGImageRelease(img);
        }
    }
}

@end

/// Separate delegate object rather than a category on the window, so the
/// window itself stays an unmodified NSWindow.
@interface GlinWindowDelegate : NSObject <NSWindowDelegate> {
    GlinCocoaWindow *_owner;
}
- (instancetype)initWithOwner:(GlinCocoaWindow *)owner;
@end

@implementation GlinWindowDelegate

- (instancetype)initWithOwner:(GlinCocoaWindow *)owner {
    self = [super init];
    if (self) {
        _owner = owner;
    }
    return self;
}

- (void)windowWillClose:(NSNotification *)note {
    if (_owner && _owner->on_close) _owner->on_close(_owner->user);
}

- (void)windowDidResize:(NSNotification *)note {
    GlinCocoaWindow *o = _owner;
    if (!o || !o->on_resize) return;
    NSView *v = o->window.contentView;
    if (!v) return;
    NSRect r = v.bounds;
    o->on_resize(o->user, (int)r.size.width, (int)r.size.height);
    // Adopt the new size on the next draw, not here: AppKit can fire a dozen
    // of these per drag frame, and reallocating + relaying out on each one is
    // what makes a live resize stutter.
    [(GlinView *)o->view setNeedsDisplay:YES];
}

- (void)windowDidEndLiveResize:(NSNotification *)note {
    GlinCocoaWindow *o = _owner;
    if (o && o->view) [(GlinView *)o->view setNeedsDisplay:YES];
}

@end

// ============================== buffer ==============================

/// (Re)allocate the pixel buffer + bitmap context for a given size.
static BOOL glin_ensure_buffer(GlinCocoaWindow *win, int w, int h) {
    if (w <= 0 || h <= 0) return NO;
    if (win->bitmap_ctx && win->buf_w == w && win->buf_h == h) return YES;

    if (win->bitmap_ctx) {
        CGContextRelease(win->bitmap_ctx);
        win->bitmap_ctx = NULL;
    }
    if (win->pixels) {
        free(win->pixels);
        win->pixels = NULL;
    }
    win->buf_w = w;
    win->buf_h = h;
    win->pixels_len = (size_t)w * (size_t)h * 4;
    win->pixels = (unsigned char *)calloc(1, win->pixels_len);
    if (!win->pixels) {
        win->buf_w = 0;
        win->buf_h = 0;
        return NO;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    win->bitmap_ctx = CGBitmapContextCreate(win->pixels, (size_t)w, (size_t)h, 8,
                                            (size_t)w * 4, cs, kGlinBitmapInfo);
    CGColorSpaceRelease(cs);
    if (!win->bitmap_ctx) {
        free(win->pixels);
        win->pixels = NULL;
        win->pixels_len = 0;
        win->buf_w = 0;
        win->buf_h = 0;
        return NO;
    }
    return YES;
}

// ============================== C surface ==============================

GlinCocoaWindow *glin_cocoa_window_create(const char *title, int w, int h,
                                          int min_w, int min_h) {
    @autoreleasepool {
        if (w <= 0) w = 720;
        if (h <= 0) h = 480;

        GlinCocoaWindow *win = calloc(1, sizeof(GlinCocoaWindow));
        if (!win) return NULL;

        // A plain application window: titled, closable, resizable, and NOT a
        // panel, so it appears in the window list and can take key focus.
        NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
        win->window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, w, h)
                                                  styleMask:style
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        win->window.title = @"glinlandui";
        if (title && title[0]) win->window.title = @(title);
        if (min_w > 0 && min_h > 0) win->window.minSize = NSMakeSize(min_w, min_h);

        GlinWindowDelegate *dlg = [[GlinWindowDelegate alloc] initWithOwner:win];
        win->delegate_obj = dlg;
        win->window.delegate = dlg;

        // Needed for mouseMoved: without it hover repaint never fires.
        [win->window setAcceptsMouseMovedEvents:YES];

        GlinView *view = [[GlinView alloc] initWithFrame:NSMakeRect(0, 0, w, h)
                                                   owner:win];
        win->view = view;
        [win->window setContentView:view];
        [win->window makeKeyAndOrderFront:nil];
        [win->window makeFirstResponder:view];
        return win;
    }
}

void glin_cocoa_window_destroy(GlinCocoaWindow *win) {
    if (!win) return;
    @autoreleasepool {
        win->window.delegate = nil;
        [win->window close];
        if (win->bitmap_ctx) CGContextRelease(win->bitmap_ctx);
        if (win->pixels) free(win->pixels);
        free(win);
    }
}

void glin_cocoa_window_set_callbacks(GlinCocoaWindow *win,
                                     GlinCocoaOnFrame on_frame,
                                     GlinCocoaOnPointer on_pointer,
                                     GlinCocoaOnScroll on_scroll,
                                     GlinCocoaOnKey on_key,
                                     GlinCocoaOnResize on_resize,
                                     GlinCocoaOnClose on_close,
                                     void *user) {
    if (!win) return;
    win->on_frame = on_frame;
    win->on_pointer = on_pointer;
    win->on_scroll = on_scroll;
    win->on_key = on_key;
    win->on_resize = on_resize;
    win->on_close = on_close;
    win->user = user;
}

void glin_cocoa_present(GlinCocoaWindow *win, const unsigned char *bgra, int w, int h) {
    if (!win || !bgra || w <= 0 || h <= 0) return;
    @autoreleasepool {
        if (!glin_ensure_buffer(win, w, h)) return;
        // The host already converted channel order and row order; all this
        // does is copy the finished bytes into the bitmap.
        memcpy(win->pixels, bgra, (size_t)w * (size_t)h * 4);
        win->frames_drawn += 1;
        if (win->max_frames > 0 && win->frames_drawn >= win->max_frames) {
            [NSApp terminate:nil];
        } else if (win->max_frames > 0) {
            // A capped run must actually produce `max_frames` frames, but
            // AppKit only redraws when something marks the view dirty, and a
            // static window goes quiet after the first composite. Without
            // re-arming the display here, any cap above 1 is unreachable and
            // the run hangs until the CI job timeout instead of exiting.
            [(GlinView *)win->view setNeedsDisplay:YES];
        }
    }
}

void glin_cocoa_invalidate(GlinCocoaWindow *win) {
    if (!win || !win->view) return;
    @autoreleasepool {
        // setNeedsDisplay only marks it dirty; the run loop does the draw on
        // the next pass. Without this an event that changes state would never
        // reach the screen.
        [(GlinView *)win->view setNeedsDisplay:YES];
    }
}

void glin_cocoa_quit(GlinCocoaWindow *win) {
    (void)win;
    @autoreleasepool {
        [NSApp terminate:nil];
    }
}

void glin_cocoa_window_run(GlinCocoaWindow *win, int max_frames) {
    if (!win) return;
    @autoreleasepool {
        win->max_frames = max_frames;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [win->window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        // Force the first frame so a capped run always produces pixels.
        [(GlinView *)win->view setNeedsDisplay:YES];
        [NSApp run];
    }
}

void glin_cocoa_content_size(GlinCocoaWindow *win, int *out_w, int *out_h) {
    if (out_w) *out_w = 0;
    if (out_h) *out_h = 0;
    if (!win) return;
    @autoreleasepool {
        NSView *v = win->window.contentView;
        if (!v) return;
        NSRect r = v.bounds;
        if (out_w) *out_w = (int)r.size.width;
        if (out_h) *out_h = (int)r.size.height;
    }
}
