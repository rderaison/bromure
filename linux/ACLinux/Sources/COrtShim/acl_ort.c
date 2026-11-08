#include "acl_ort.h"
#include "ort/onnxruntime_c_api.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const OrtApi *api;
static const char *version;
static OrtEnv *env;
static pthread_mutex_t load_lock = PTHREAD_MUTEX_INITIALIZER;

static void say(char *err, size_t errlen, const char *what, const char *detail) {
    if (err && errlen) snprintf(err, errlen, "%s%s%s", what, detail ? ": " : "", detail ? detail : "");
}

/* An OrtStatus into err (and released). 0 when there was none. */
static int failed(OrtStatus *st, char *err, size_t errlen, const char *what) {
    if (!st) return 0;
    say(err, errlen, what, api->GetErrorMessage(st));
    api->ReleaseStatus(st);
    return -1;
}

uint32_t acl_ort_api_version(void) { return ORT_API_VERSION; }
const char *acl_ort_version(void) { return version; }

int acl_ort_load(const char *path, char *err, size_t errlen) {
    pthread_mutex_lock(&load_lock);
    int rc = 0;
    if (api) goto out;
    void *h = dlopen(path ? path : "libonnxruntime.so.1.23", RTLD_NOW | RTLD_LOCAL);
    if (!h) { say(err, errlen, "can't load onnxruntime", dlerror()); rc = -1; goto out; }
    const OrtApiBase *(*base_fn)(void) = (const OrtApiBase *(*)(void))dlsym(h, "OrtGetApiBase");
    if (!base_fn) { say(err, errlen, "not onnxruntime (no OrtGetApiBase)", NULL); dlclose(h); rc = -1; goto out; }
    const OrtApiBase *base = base_fn();
    const OrtApi *a = base ? base->GetApi(ORT_API_VERSION) : NULL;
    if (!a) {
        char want[64];
        snprintf(want, sizeof want, "it is %s, API %u is needed", base ? base->GetVersionString() : "?", ORT_API_VERSION);
        say(err, errlen, "this onnxruntime can't serve the API", want);
        dlclose(h); rc = -1; goto out;
    }
    OrtEnv *e = NULL;
    OrtStatus *st = a->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "bromure", &e);
    if (st) {
        say(err, errlen, "onnxruntime env", a->GetErrorMessage(st));
        a->ReleaseStatus(st); dlclose(h); rc = -1; goto out;
    }
    api = a; env = e; version = base->GetVersionString();
out:
    pthread_mutex_unlock(&load_lock);
    return rc;
}

struct acl_ort_session {
    OrtSession *session;
    char **inputs; size_t ninputs;
    char *output;
};

void acl_ort_session_release(acl_ort_session *s) {
    if (!s) return;
    for (size_t i = 0; i < s->ninputs; i++) free(s->inputs[i]);
    free(s->inputs); free(s->output);
    if (s->session) api->ReleaseSession(s->session);
    free(s);
}

static char *take_name(OrtAllocator *al, char *name) {
    char *copy = strdup(name);
    al->Free(al, name);
    return copy;
}

acl_ort_session *acl_ort_session_create(const char *model_path, int intra_threads, char *err, size_t errlen) {
    if (!api) { say(err, errlen, "onnxruntime isn't loaded", NULL); return NULL; }
    acl_ort_session *s = calloc(1, sizeof *s);
    if (!s) { say(err, errlen, "out of memory", NULL); return NULL; }
    OrtSessionOptions *opt = NULL;
    OrtAllocator *al = NULL;
    if (failed(api->CreateSessionOptions(&opt), err, errlen, "session options")) goto fail;
    if (failed(api->SetSessionGraphOptimizationLevel(opt, ORT_ENABLE_ALL), err, errlen, "graph optimisation")) goto fail;
    if (intra_threads > 0 && failed(api->SetIntraOpNumThreads(opt, intra_threads), err, errlen, "threads")) goto fail;
    if (failed(api->CreateSession(env, model_path, opt, &s->session), err, errlen, "model")) goto fail;
    api->ReleaseSessionOptions(opt); opt = NULL;
    if (failed(api->GetAllocatorWithDefaultOptions(&al), err, errlen, "allocator")) goto fail;
    size_t n = 0, nout = 0;
    if (failed(api->SessionGetInputCount(s->session, &n), err, errlen, "inputs")) goto fail;
    s->inputs = calloc(n ? n : 1, sizeof(char *));
    for (size_t i = 0; i < n; i++) {
        char *name = NULL;
        if (failed(api->SessionGetInputName(s->session, i, al, &name), err, errlen, "input name")) goto fail;
        s->inputs[i] = take_name(al, name); s->ninputs = i + 1;
    }
    if (failed(api->SessionGetOutputCount(s->session, &nout), err, errlen, "outputs")) goto fail;
    if (nout == 0) { say(err, errlen, "the model has no output", NULL); goto fail; }
    char *out = NULL;
    if (failed(api->SessionGetOutputName(s->session, 0, al, &out), err, errlen, "output name")) goto fail;
    s->output = take_name(al, out);
    return s;
fail:
    if (opt) api->ReleaseSessionOptions(opt);
    acl_ort_session_release(s);
    return NULL;
}

int acl_ort_session_use_output(acl_ort_session *s, const char *name, char *err, size_t errlen) {
    if (!api || !s) { say(err, errlen, "no session", NULL); return -1; }
    OrtAllocator *al = NULL;
    size_t nout = 0;
    if (failed(api->GetAllocatorWithDefaultOptions(&al), err, errlen, "allocator")) return -1;
    if (failed(api->SessionGetOutputCount(s->session, &nout), err, errlen, "outputs")) return -1;
    for (size_t i = 0; i < nout; i++) {
        char *out = NULL;
        if (failed(api->SessionGetOutputName(s->session, i, al, &out), err, errlen, "output name")) return -1;
        char *copy = take_name(al, out);
        if (copy && strcmp(copy, name) == 0) { free(s->output); s->output = copy; return 0; }
        free(copy);
    }
    return 1;
}

size_t acl_ort_input_count(const acl_ort_session *s) { return s ? s->ninputs : 0; }
const char *acl_ort_input_name(const acl_ort_session *s, size_t i) { return s && i < s->ninputs ? s->inputs[i] : NULL; }

int acl_ort_run_int64(acl_ort_session *s, const char *const *names, const int64_t *const *data, size_t ninputs,
                      const int64_t *shape, size_t rank, float *out, size_t outcap, size_t *outlen,
                      char *err, size_t errlen) {
    if (!api || !s) { say(err, errlen, "no session", NULL); return -1; }
    size_t count = 1;
    for (size_t i = 0; i < rank; i++) {
        if (shape[i] <= 0) { say(err, errlen, "bad shape", NULL); return -1; }
        count *= (size_t)shape[i];
    }
    int rc = -1;
    OrtMemoryInfo *mem = NULL;
    OrtValue **in = calloc(ninputs ? ninputs : 1, sizeof(OrtValue *));
    OrtValue *result = NULL;
    if (!in) { say(err, errlen, "out of memory", NULL); return -1; }
    if (failed(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem), err, errlen, "memory info")) goto done;
    for (size_t i = 0; i < ninputs; i++) {
        if (failed(api->CreateTensorWithDataAsOrtValue(mem, (void *)data[i], count * sizeof(int64_t), shape, rank,
                                                       ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &in[i]),
                   err, errlen, "input tensor")) goto done;
    }
    const char *outname = s->output;
    if (failed(api->Run(s->session, NULL, names, (const OrtValue *const *)in, ninputs, &outname, 1, &result),
               err, errlen, "run")) goto done;
    OrtTensorTypeAndShapeInfo *info = NULL;
    if (failed(api->GetTensorTypeAndShape(result, &info), err, errlen, "output shape")) goto done;
    size_t n = 0;
    ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    OrtStatus *st = api->GetTensorShapeElementCount(info, &n);
    if (!st) st = api->GetTensorElementType(info, &type);
    api->ReleaseTensorTypeAndShapeInfo(info);
    if (failed(st, err, errlen, "output shape")) goto done;
    if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) { say(err, errlen, "the output isn't float32", NULL); goto done; }
    float *p = NULL;
    if (failed(api->GetTensorMutableData(result, (void **)&p), err, errlen, "output data")) goto done;
    *outlen = n;
    memcpy(out, p, (n < outcap ? n : outcap) * sizeof(float));
    rc = 0;
done:
    if (result) api->ReleaseValue(result);
    for (size_t i = 0; i < ninputs; i++) if (in[i]) api->ReleaseValue(in[i]);
    free(in);
    if (mem) api->ReleaseMemoryInfo(mem);
    return rc;
}
