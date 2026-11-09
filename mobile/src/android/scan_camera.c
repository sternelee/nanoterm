// nanoterm's Android QR scanner: the camera's frames, straight to quirc.
//
// A NativeActivity can't ask Java for a barcode, so the camera runs here: the
// NDK's camera2 (ACameraManager/ACameraDevice) feeds an AImageReader's Y plane
// to quirc, whose decode is handed back to Zig (nanoterm_qr_found). A thread of
// its own carries the camera's looper: the callbacks the NDK posts (device,
// session, a new frame) arrive on it.
//
// Threading: qr_scan_start() spawns that thread and returns; the app keeps
// rendering. qr_scan_stop() stops it and joins. The Zig side polls the decoded
// string (see scan_android.zig) on its own (UI) thread each frame.
#include <android/looper.h>
#include <android/log.h>
#include <camera/NdkCameraDevice.h>
#include <camera/NdkCameraManager.h>
#include <camera/NdkCaptureRequest.h>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#include "quirc.h"

#define LOG_TAG "nanoterm-scan"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#ifndef AIMAGE_FORMAT_YUV_420_888
#define AIMAGE_FORMAT_YUV_420_888 0x23
#endif

// Zig's side of a decode: it copies the string and stops the scan.
extern void nanoterm_qr_found(const char *payload, int len);

static ACameraManager *g_mgr;
static ACameraDevice *g_dev;
static ACameraCaptureSession *g_session;
static ACaptureSessionOutputContainer *g_container;
static ACaptureSessionOutput *g_output;
static ACaptureRequest *g_request;
static ACameraOutputTarget *g_target;
static AImageReader *g_reader;
static ANativeWindow *g_window;
static struct quirc *g_qr;
static pthread_t g_thread;
static atomic_int g_running = 0;
static int g_thread_live = 0;
static int g_qw = 0, g_qh = 0;

static void image_available(void *ctx, AImageReader *reader) {
    (void)ctx;
    if (!atomic_load(&g_running)) return;
    AImage *img = NULL;
    if (AImageReader_acquireNextImage(reader, &img) != AMEDIA_OK || img == NULL) return;

    int32_t w = 0, h = 0;
    if (AImage_getWidth(img, &w) == AMEDIA_OK && AImage_getHeight(img, &h) == AMEDIA_OK && w > 0 && h > 0) {
        uint8_t *y = NULL;
        int32_t ylen = 0, stride = 0;
        if (AImage_getPlaneData(img, 0, &y, &ylen) == AMEDIA_OK && y != NULL &&
            AImage_getPlaneRowStride(img, 0, &stride) == AMEDIA_OK) {
            if (w != g_qw || h != g_qh) {
                if (quirc_resize(g_qr, w, h) == 0) {
                    g_qw = w;
                    g_qh = h;
                }
            }
            if (w == g_qw && h == g_qh) {
                int bw = 0, bh = 0;
                uint8_t *buf = quirc_begin(g_qr, &bw, &bh);
                if (buf && bw == w && bh == h) {
                    for (int row = 0; row < h; row++)
                        memcpy(buf + (size_t)row * w, y + (size_t)row * stride, (size_t)w);
                    quirc_end(g_qr);
                    int n = quirc_count(g_qr);
                    for (int i = 0; i < n; i++) {
                        struct quirc_code code;
                        struct quirc_data data;
                        quirc_extract(g_qr, i, &code);
                        if (quirc_decode(&code, &data) == QUIRC_SUCCESS) {
                            int len = data.payload_len;
                            if (len < 0) len = 0;
                            if (len > 1023) len = 1023;
                            nanoterm_qr_found((const char *)data.payload, len);
                            break;
                        }
                    }
                }
            }
        }
    }
    AImage_delete(img);
}

static void on_session_ready(void *ctx, ACameraCaptureSession *session) {
    (void)ctx;
    if (g_request) ACameraCaptureSession_setRepeatingRequest(session, NULL, 1, &g_request, NULL);
}
static void on_session_active(void *ctx, ACameraCaptureSession *s) { (void)ctx; (void)s; }
static void on_session_closed(void *ctx, ACameraCaptureSession *s) { (void)ctx; (void)s; }
static void on_dev_disconnected(void *ctx, ACameraDevice *d) { (void)ctx; (void)d; LOGI("camera disconnected"); }
static void on_dev_error(void *ctx, ACameraDevice *d, int err) { (void)ctx; (void)d; LOGE("camera error %d", err); }

static void teardown(void) {
    if (g_session) { ACameraCaptureSession_close(g_session); g_session = NULL; }
    if (g_request) { ACaptureRequest_free(g_request); g_request = NULL; }
    if (g_target) { ACameraOutputTarget_free(g_target); g_target = NULL; }
    if (g_output) { ACaptureSessionOutput_free(g_output); g_output = NULL; }
    if (g_container) { ACaptureSessionOutputContainer_free(g_container); g_container = NULL; }
    if (g_window) { ANativeWindow_release(g_window); g_window = NULL; }
    if (g_reader) { AImageReader_delete(g_reader); g_reader = NULL; }
    if (g_dev) { ACameraDevice_close(g_dev); g_dev = NULL; }
    if (g_mgr) { ACameraManager_delete(g_mgr); g_mgr = NULL; }
    if (g_qr) { quirc_destroy(g_qr); g_qr = NULL; }
    g_qw = g_qh = 0;
}

static void *worker(void *arg) {
    (void)arg;
    // This thread's looper: the camera posts its callbacks here.
    ALooper *looper = ALooper_prepare(0);
    (void)looper;

    g_qr = quirc_new();
    g_mgr = ACameraManager_create();
    if (!g_qr || !g_mgr) { LOGE("init failed"); goto done; }

    ACameraIdList *ids = NULL;
    if (ACameraManager_getCameraIdList(g_mgr, &ids) != ACAMERA_OK || ids == NULL || ids->numCameras <= 0) {
        LOGE("no camera");
        if (ids) ACameraManager_deleteCameraIdList(ids);
        goto done;
    }
    ACameraDevice_StateCallbacks dev_cbs = {
        .context = NULL, .onDisconnected = on_dev_disconnected, .onError = on_dev_error,
    };
    // Prefer the back camera: the "0" id is the primary on phones.
    const char *camera_id = ids->cameraIds[0];
    if (ACameraManager_openCamera(g_mgr, camera_id, &dev_cbs, &g_dev) != ACAMERA_OK || !g_dev) {
        LOGE("open camera failed");
        ACameraManager_deleteCameraIdList(ids);
        goto done;
    }
    ACameraManager_deleteCameraIdList(ids);

    if (AImageReader_new(1280, 720, AIMAGE_FORMAT_YUV_420_888, 2, &g_reader) != AMEDIA_OK || !g_reader) {
        LOGE("image reader failed");
        goto done;
    }
    {
        AImageReader_ImageListener listener = { .context = NULL, .onImageAvailable = image_available };
        AImageReader_setImageListener(g_reader, &listener);
    }
    if (AImageReader_getWindow(g_reader, &g_window) != AMEDIA_OK || !g_window) {
        LOGE("reader window failed");
        goto done;
    }
    if (ACaptureSessionOutputContainer_create(&g_container) != ACAMERA_OK ||
        ACaptureSessionOutput_create(g_window, &g_output) != ACAMERA_OK ||
        ACameraOutputTarget_create(g_window, &g_target) != ACAMERA_OK) {
        LOGE("output setup failed");
        goto done;
    }
    ACaptureSessionOutputContainer_add(g_container, g_output);

    if (ACameraDevice_createCaptureRequest(g_dev, TEMPLATE_PREVIEW, &g_request) != ACAMERA_OK || !g_request) {
        LOGE("capture request failed");
        goto done;
    }
    ACaptureRequest_addTarget(g_request, g_target);

    {
        ACameraCaptureSession_stateCallbacks sess_cbs = {
            .context = NULL,
            .onClosed = on_session_closed,
            .onReady = on_session_ready,
            .onActive = on_session_active,
        };
        if (ACameraDevice_createCaptureSession(g_dev, g_container, &sess_cbs, &g_session) != ACAMERA_OK || !g_session) {
            LOGE("capture session failed");
            goto done;
        }
    }

    LOGI("scanning");
    while (atomic_load(&g_running)) {
        int events = 0;
        void *data = NULL;
        ALooper_pollOnce(1000, NULL, &events, &data);
    }

done:
    teardown();
    return NULL;
}

int qr_scan_start(void) {
    if (atomic_load(&g_running)) return 0;
    atomic_store(&g_running, 1);
    if (pthread_create(&g_thread, NULL, worker, NULL) != 0) {
        atomic_store(&g_running, 0);
        return -1;
    }
    g_thread_live = 1;
    return 0;
}

void qr_scan_stop(void) {
    if (!g_thread_live) return;
    atomic_store(&g_running, 0);
    // Wake the worker's looper so pollOnce returns and it sees the flag.
    ALooper *l = ALooper_forThread();
    (void)l;
    pthread_join(g_thread, NULL);
    g_thread_live = 0;
}
