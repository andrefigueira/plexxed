import AppKit
import Cmpv
import OpenGL.GL3
import QuartzCore

/// Hosts the mpv video layer. Clicks pass straight through to the SwiftUI controls on top.
final class MPVVideoView: NSView {
    let videoLayer: MPVVideoLayer

    init(mpv: OpaquePointer) {
        videoLayer = MPVVideoLayer(mpv: mpv)
        super.init(frame: .zero)
        layer = videoLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        videoLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        videoLayer.setNeedsDisplay()
    }

    func teardown() { videoLayer.teardown() }
}

/// Renders mpv frames through libmpv's OpenGL render API. Frames are drawn on a private
/// queue only when mpv reports one is ready, so a paused video costs nothing.
final class MPVVideoLayer: CAOpenGLLayer, @unchecked Sendable {
    private let pixelFormat: CGLPixelFormatObj
    private let glContext: CGLContextObj
    private let ownsContext: Bool
    private var renderContext: OpaquePointer?
    private let renderQueue = DispatchQueue(label: "app.plexxed.mpv.render", qos: .userInteractive)
    private let lock = NSLock()
    private var isTornDown = false
    private let apiType: UnsafeMutablePointer<CChar>? = strdup("opengl")

    init(mpv: OpaquePointer) {
        pixelFormat = Self.makePixelFormat()
        var context: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &context)
        glContext = context!
        ownsContext = true
        var swapInterval: GLint = 1
        CGLSetParameter(glContext, kCGLCPSwapInterval, &swapInterval)
        CGLEnable(glContext, kCGLCEMPEngine)
        super.init()
        isOpaque = true
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        createRenderContext(mpv)
    }

    /// Core Animation copies layers for presentation. Copies share the GL objects but never draw.
    override init(layer: Any) {
        let other = layer as! MPVVideoLayer
        pixelFormat = other.pixelFormat
        glContext = other.glContext
        ownsContext = false
        isTornDown = true
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        free(apiType)
        if ownsContext {
            CGLReleaseContext(glContext)
            CGLReleasePixelFormat(pixelFormat)
        }
    }

    private static func makePixelFormat() -> CGLPixelFormatObj {
        let core = CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue))
        let candidates: [[CGLPixelFormatAttribute]] = [
            [kCGLPFAOpenGLProfile, core, kCGLPFAAccelerated, kCGLPFADoubleBuffer,
             kCGLPFAAllowOfflineRenderers, kCGLPFASupportsAutomaticGraphicsSwitching, CGLPixelFormatAttribute(0)],
            [kCGLPFAOpenGLProfile, core, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers, CGLPixelFormatAttribute(0)],
            [kCGLPFADoubleBuffer, CGLPixelFormatAttribute(0)],
        ]
        for attributes in candidates {
            var format: CGLPixelFormatObj?
            var count: GLint = 0
            if CGLChoosePixelFormat(attributes, &format, &count) == kCGLNoError, let format {
                return format
            }
        }
        fatalError("No usable OpenGL pixel format")
    }

    private func createRenderContext(_ mpv: OpaquePointer) {
        CGLLockContext(glContext)
        defer { CGLUnlockContext(glContext) }
        CGLSetCurrentContext(glContext)

        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
                let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                return CFBundleGetFunctionPointerForName(bundle, symbol)
            },
            get_proc_address_ctx: nil
        )
        withUnsafeMutablePointer(to: &initParams) { initPointer in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
                mpv_render_param(),
            ]
            var context: OpaquePointer?
            let status = mpv_render_context_create(&context, mpv, &params)
            if status < 0 {
                Log.error("mpv render context failed: \(String(cString: mpv_error_string(status)))")
            } else {
                renderContext = context
            }
        }
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, { context in
            guard let context else { return }
            Unmanaged<MPVVideoLayer>.fromOpaque(context).takeUnretainedValue().scheduleFrame()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Called by mpv from its own threads. Must not call back into mpv here.
    private func scheduleFrame() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            let alive = self.lock.withLock { !self.isTornDown }
            guard alive else { return }
            self.display()
            CATransaction.flush()
        }
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj { pixelFormat }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj { glContext }

    override func canDraw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) -> Bool { true }

    override func draw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let renderContext, !isTornDown else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            return
        }
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        _ = mpv_render_context_update(renderContext)
        var target = mpv_opengl_fbo(fbo: Int32(fbo), w: viewport[2], h: viewport[3], internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &target) { targetPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(targetPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                    mpv_render_param(),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
        glFlush()
        mpv_render_context_report_swap(renderContext)
    }

    /// Frees the render context. Must run before the mpv handle is destroyed.
    /// Lock order matches the draw path: Core Animation holds the GL context lock, then `lock`.
    func teardown() {
        CGLLockContext(glContext)
        lock.lock()
        defer {
            lock.unlock()
            CGLUnlockContext(glContext)
        }
        guard !isTornDown else { return }
        isTornDown = true
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        CGLSetCurrentContext(glContext)
        mpv_render_context_free(renderContext)
        CGLSetCurrentContext(nil)
        self.renderContext = nil
    }
}
