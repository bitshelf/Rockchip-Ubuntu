#!/usr/bin/env python3
import ctypes
import glob
import json
import os
import subprocess
import sys
from pathlib import Path


def fail(message, **details):
    print(json.dumps({"schema": "ubuntu-gpu-headless-egl-v1", "result": "fail",
                      "error": message, **details}, sort_keys=True))
    raise SystemExit(1)


egl = ctypes.CDLL("libEGL.so.1", mode=ctypes.RTLD_GLOBAL)
gles = ctypes.CDLL("libGLESv2.so.2", mode=ctypes.RTLD_GLOBAL)
gbm = ctypes.CDLL("libgbm.so.1", mode=ctypes.RTLD_GLOBAL)

c_int_p = ctypes.POINTER(ctypes.c_int32)
egl.eglGetPlatformDisplay.argtypes = [ctypes.c_uint32, ctypes.c_void_p,
                                      c_int_p]
egl.eglGetPlatformDisplay.restype = ctypes.c_void_p
egl.eglInitialize.argtypes = [ctypes.c_void_p, c_int_p, c_int_p]
egl.eglInitialize.restype = ctypes.c_uint32
egl.eglChooseConfig.argtypes = [ctypes.c_void_p, c_int_p,
                                ctypes.POINTER(ctypes.c_void_p),
                                ctypes.c_int32, c_int_p]
egl.eglChooseConfig.restype = ctypes.c_uint32
egl.eglBindAPI.argtypes = [ctypes.c_uint32]
egl.eglBindAPI.restype = ctypes.c_uint32
egl.eglCreatePbufferSurface.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                        c_int_p]
egl.eglCreatePbufferSurface.restype = ctypes.c_void_p
egl.eglCreateContext.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                 ctypes.c_void_p, c_int_p]
egl.eglCreateContext.restype = ctypes.c_void_p
egl.eglMakeCurrent.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                               ctypes.c_void_p, ctypes.c_void_p]
egl.eglMakeCurrent.restype = ctypes.c_uint32
egl.eglQueryString.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
egl.eglQueryString.restype = ctypes.c_char_p
egl.eglGetError.restype = ctypes.c_uint32
egl.eglDestroyContext.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
egl.eglDestroySurface.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
egl.eglTerminate.argtypes = [ctypes.c_void_p]
gbm.gbm_create_device.argtypes = [ctypes.c_int]
gbm.gbm_create_device.restype = ctypes.c_void_p
gbm.gbm_device_destroy.argtypes = [ctypes.c_void_p]
gles.glClearColor.argtypes = [ctypes.c_float] * 4
gles.glClear.argtypes = [ctypes.c_uint32]
gles.glReadPixels.argtypes = [ctypes.c_int32, ctypes.c_int32,
                              ctypes.c_int32, ctypes.c_int32,
                              ctypes.c_uint32, ctypes.c_uint32,
                              ctypes.c_void_p]
gles.glFinish.argtypes = []
gles.glGetString.argtypes = [ctypes.c_uint32]
gles.glGetString.restype = ctypes.c_char_p

EGL_PLATFORM_GBM_KHR = 0x31D7
EGL_NONE = 0x3038
EGL_SURFACE_TYPE = 0x3033
EGL_PBUFFER_BIT = 0x0001
EGL_RENDERABLE_TYPE = 0x3040
EGL_OPENGL_ES2_BIT = 0x0004
EGL_RED_SIZE, EGL_GREEN_SIZE = 0x3024, 0x3023
EGL_BLUE_SIZE, EGL_ALPHA_SIZE = 0x3022, 0x3021
EGL_WIDTH, EGL_HEIGHT = 0x3057, 0x3056
EGL_CONTEXT_CLIENT_VERSION = 0x3098
EGL_OPENGL_ES_API = 0x30A0
EGL_VENDOR = 0x3053
GL_COLOR_BUFFER_BIT = 0x00004000
GL_RGBA, GL_UNSIGNED_BYTE = 0x1908, 0x1401
GL_VENDOR, GL_RENDERER = 0x1F00, 0x1F01


def text(value):
    return value.decode(errors="replace") if value else "unknown"


fd = -1
device = display = surface = context = None
card = None
errors = []
mesa = os.environ.get("GPU_STACK") == "panfrost"
candidates = sorted(glob.glob("/dev/dri/renderD*" if mesa else "/dev/dri/card*"))
for candidate in candidates:
    if mesa:
        driver = os.path.realpath("/sys/class/drm/"+os.path.basename(candidate)+"/device/driver")
        if os.path.basename(driver) != "panfrost":
            continue
    try:
        candidate_fd = os.open(candidate, os.O_RDWR | os.O_CLOEXEC)
    except OSError as exc:
        errors.append(f"{candidate}: open: {exc}")
        continue
    candidate_device = gbm.gbm_create_device(candidate_fd)
    if not candidate_device:
        os.close(candidate_fd)
        errors.append(f"{candidate}: gbm_create_device failed")
        continue
    candidate_display = egl.eglGetPlatformDisplay(
        EGL_PLATFORM_GBM_KHR, candidate_device, None)
    major = ctypes.c_int32()
    minor = ctypes.c_int32()
    if candidate_display and egl.eglInitialize(candidate_display,
                                                ctypes.byref(major),
                                                ctypes.byref(minor)):
        fd, device, display, card = (candidate_fd, candidate_device,
                                     candidate_display, candidate)
        egl_version = f"{major.value}.{minor.value}"
        break
    errors.append(f"{candidate}: eglInitialize: 0x{egl.eglGetError():04x}")
    gbm.gbm_device_destroy(candidate_device)
    os.close(candidate_fd)

if not display:
    fail("no DRM card initialized the GBM EGL platform", attempts=errors)

attributes = (ctypes.c_int32 * 15)(
    EGL_SURFACE_TYPE, 0 if mesa else EGL_PBUFFER_BIT,
    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
    EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
    EGL_NONE, EGL_NONE, EGL_NONE)
config = ctypes.c_void_p()
count = ctypes.c_int32()
if not egl.eglChooseConfig(display, attributes, ctypes.byref(config), 1,
                           ctypes.byref(count)) or count.value != 1:
    fail("eglChooseConfig failed", egl_error=f"0x{egl.eglGetError():04x}")
if not egl.eglBindAPI(EGL_OPENGL_ES_API):
    fail("eglBindAPI failed", egl_error=f"0x{egl.eglGetError():04x}")

pbuffer = (ctypes.c_int32 * 5)(EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE)
surface = None if mesa else egl.eglCreatePbufferSurface(display, config, pbuffer)
context_attributes = (ctypes.c_int32 * 3)(EGL_CONTEXT_CLIENT_VERSION, 2,
                                          EGL_NONE)
context = egl.eglCreateContext(display, config, None, context_attributes)
if (not mesa and not surface) or not context or not egl.eglMakeCurrent(
        display, surface, surface, context):
    fail("EGL ES2 pbuffer/context creation failed",
         egl_error=f"0x{egl.eglGetError():04x}")

framebuffer = renderbuffer = None
if mesa:
    # GBM supports surfaceless contexts. Render to an explicit FBO so no
    # physical connector, compositor, or default window framebuffer is needed.
    uint_p = ctypes.POINTER(ctypes.c_uint32)
    gles.glGenFramebuffers.argtypes = [ctypes.c_int32, uint_p]
    gles.glGenRenderbuffers.argtypes = [ctypes.c_int32, uint_p]
    gles.glBindFramebuffer.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    gles.glBindRenderbuffer.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    gles.glRenderbufferStorage.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32, ctypes.c_int32]
    gles.glFramebufferRenderbuffer.argtypes = [ctypes.c_uint32]*4
    gles.glCheckFramebufferStatus.argtypes = [ctypes.c_uint32]
    gles.glCheckFramebufferStatus.restype = ctypes.c_uint32
    framebuffer, renderbuffer = ctypes.c_uint32(), ctypes.c_uint32()
    gles.glGenFramebuffers(1, ctypes.byref(framebuffer))
    gles.glGenRenderbuffers(1, ctypes.byref(renderbuffer))
    gles.glBindFramebuffer(0x8D40, framebuffer.value)
    gles.glBindRenderbuffer(0x8D41, renderbuffer.value)
    gles.glRenderbufferStorage(0x8D41, 0x8056, 16, 16)  # RGBA4
    gles.glFramebufferRenderbuffer(0x8D40, 0x8CE0, 0x8D41, renderbuffer.value)
    if gles.glCheckFramebufferStatus(0x8D40) != 0x8CD5:
        fail("offscreen framebuffer is incomplete")

gles.glClearColor(0.0 if mesa else 1.0, 0.0, 0.0, 1.0)
gles.glClear(GL_COLOR_BUFFER_BIT)
if mesa:
    gles.glCreateShader.argtypes = [ctypes.c_uint32]
    gles.glCreateShader.restype = ctypes.c_uint32
    gles.glShaderSource.argtypes = [ctypes.c_uint32, ctypes.c_int32, ctypes.POINTER(ctypes.c_char_p), c_int_p]
    gles.glCompileShader.argtypes = [ctypes.c_uint32]
    gles.glGetShaderiv.argtypes = [ctypes.c_uint32, ctypes.c_uint32, c_int_p]
    gles.glCreateProgram.restype = ctypes.c_uint32
    gles.glAttachShader.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    gles.glBindAttribLocation.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_char_p]
    gles.glLinkProgram.argtypes = [ctypes.c_uint32]
    gles.glGetProgramiv.argtypes = [ctypes.c_uint32, ctypes.c_uint32, c_int_p]
    shaders = []
    for kind, code in (
        (0x8B31, b'attribute vec2 position; void main(){gl_Position=vec4(position,0.0,1.0);}'),
        (0x8B30, b'precision mediump float; void main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}'),
    ):
        shader = gles.glCreateShader(kind)
        sources = (ctypes.c_char_p*1)(code)
        gles.glShaderSource(shader, 1, sources, None)
        gles.glCompileShader(shader)
        status = ctypes.c_int32()
        gles.glGetShaderiv(shader, 0x8B81, ctypes.byref(status))
        if not status.value:
            fail('GPU shader compilation failed', shader_kind=kind)
        shaders.append(shader)
    program = gles.glCreateProgram()
    for shader in shaders:
        gles.glAttachShader(program, shader)
    gles.glBindAttribLocation(program, 0, b'position')
    gles.glLinkProgram(program)
    status = ctypes.c_int32()
    gles.glGetProgramiv(program, 0x8B82, ctypes.byref(status))
    if not status.value:
        fail('GPU shader linking failed')
    gles.glUseProgram.argtypes = [ctypes.c_uint32]
    gles.glViewport.argtypes = [ctypes.c_int32]*4
    gles.glVertexAttribPointer.argtypes = [ctypes.c_uint32, ctypes.c_int32, ctypes.c_uint32, ctypes.c_ubyte, ctypes.c_int32, ctypes.c_void_p]
    vertices = (ctypes.c_float*6)(-1, -1, 1, -1, 0, 1)
    gles.glUseProgram(program)
    gles.glViewport(0, 0, 16, 16)
    gles.glEnableVertexAttribArray(0)
    gles.glVertexAttribPointer(0, 2, 0x1406, 0, 0, ctypes.cast(vertices, ctypes.c_void_p))
    gles.glDrawArrays(0x0004, 0, 3)
gles.glFinish()
pixel = (ctypes.c_ubyte * 4)()
gles.glReadPixels(8 if mesa else 0, 8 if mesa else 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel)
rgba = list(pixel)
corner = None
if mesa:
    gles.glReadPixels(0, 15, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel)
    corner = list(pixel)
    if corner != [0, 0, 0, 255]:
        fail('triangle background did not remain black', corner_rgba=corner)
egl_vendor = text(egl.eglQueryString(display, EGL_VENDOR))
gl_vendor = text(gles.glGetString(GL_VENDOR))
gl_renderer = text(gles.glGetString(GL_RENDERER))
vendor_identity = " ".join((egl_vendor, gl_vendor, gl_renderer)).lower()
if "arm" not in vendor_identity and "mali" not in vendor_identity:
    fail("rendering used a non-Mali implementation", egl_vendor=egl_vendor,
         gl_vendor=gl_vendor, gl_renderer=gl_renderer, rgba=rgba)
if rgba[0] < 240 or rgba[1] > 15 or rgba[2] > 15 or rgba[3] < 240:
    fail("rendered pixel did not match the red clear color", rgba=rgba,
         egl_vendor=egl_vendor, gl_renderer=gl_renderer)

package = "libegl-mesa0" if mesa else os.environ["LIBMALI_PACKAGE"]
package_version = subprocess.check_output(
    ["dpkg-query", "-W", "-f=${Version}",
     package], text=True).strip()
print(json.dumps({
    "schema": "ubuntu-gpu-headless-egl-v1",
    "result": "pass",
    "marker": "GPU_HEADLESS_EGL_OK",
    "drm_card": card,
    "egl_version": egl_version,
    "egl_vendor": egl_vendor,
    "gl_vendor": gl_vendor,
    "gl_renderer": gl_renderer,
    "rgba": rgba,
    "probe": "shader-triangle" if mesa else "red-clear",
    "corner_rgba": corner,
    "graphics_stack": "panfrost" if mesa else "vendor",
    "graphics_package": package,
    "graphics_version": package_version,
    "kernel_release": os.uname().release,
    "runtime_pm_control": (
        Path("/sys/class/drm/"+os.path.basename(card)+"/device/power/control").read_text().strip()
        if mesa else None),
    **({"libmali_package": package, "libmali_version": package_version}
       if not mesa else {}),
}, sort_keys=True))

egl.eglMakeCurrent(display, None, None, None)
egl.eglDestroyContext(display, context)
if surface:
    egl.eglDestroySurface(display, surface)
egl.eglTerminate(display)
gbm.gbm_device_destroy(device)
os.close(fd)
