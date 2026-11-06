#ifndef ACL_ORT_H
#define ACL_ORT_H
#include <stddef.h>
#include <stdint.h>

/* onnxruntime's C API, loaded at run time (dlopen): nothing links against
 * libonnxruntime, so a server without it still runs (the rules pass only).
 * Every call returns 0 on success, or -1 with a message in err. */

/* Load the library (path, or the default soname when NULL) and take the
 * API table at the version these headers are (ORT_API_VERSION); a library
 * that can't serve it is refused. Idempotent once it succeeded. */
int acl_ort_load(const char *path, char *err, size_t errlen);
/* The loaded library's version ("1.23.2"), or NULL before a load. */
const char *acl_ort_version(void);
/* The API version these headers ask for. */
uint32_t acl_ort_api_version(void);

typedef struct acl_ort_session acl_ort_session;
/* A CPU session over the model at model_path, graph optimisations on. */
acl_ort_session *acl_ort_session_create(const char *model_path, int intra_threads, char *err, size_t errlen);
void acl_ort_session_release(acl_ort_session *s);
size_t acl_ort_input_count(const acl_ort_session *s);
const char *acl_ort_input_name(const acl_ort_session *s, size_t i);
/* Run with int64 inputs of one shape (rank `rank`), named as the model
 * declares them; the first output as float32 into out (up to outcap
 * values), its element count in *outlen. */
int acl_ort_run_int64(acl_ort_session *s, const char *const *names, const int64_t *const *data, size_t ninputs,
                      const int64_t *shape, size_t rank, float *out, size_t outcap, size_t *outlen,
                      char *err, size_t errlen);
#endif
